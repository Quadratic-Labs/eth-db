#!/usr/bin/env python3
"""
Benchmark PrefixDB against an Ethereum-like workload.

Uses the same workload simulation as generate_kv_blocks.py but executes
operations directly on the database rather than recording them to a file.

At the end of each block:
  1. Computes a state_root (sha256 over sorted writes in the block).
  2. Triggers a compaction round.
  3. Emits per-block metrics.

Metrics collected
-----------------
  throughput     — reads/s, writes/s, total ops/s per block and overall
  latency        — mean, p50, p95, p99 (microseconds) for reads and writes
  read hit rate  — fraction of reads that returned a value (key was present)
  state_root     — latency of state-root computation per block
  compaction     — latency of the compaction round per block
  write amp      — total_put_calls / unique_keys_written
                   captures how many times the same logical key is overwritten.
                   Compaction-internal rewrites are not visible from Python.
  space amp      — bytes_ever_written / (unique_live_keys × 64)
                   approximates how much storage the DB uses relative to one
                   snapshot of the live key set.

Output
------
  JSON with:
    config  — all workload parameters
    blocks  — list of per-block metric dicts
    summary — aggregated totals and percentiles across all blocks

Usage examples
--------------
  python scripts/benchmark_kv.py -n 200 -o metrics.json --print-every 10
  python scripts/benchmark_kv.py -n 500 --pool-size 500 --alpha 1.5 -o out.json
"""

from __future__ import annotations

import argparse
import bisect
import hashlib
import json
import pathlib
import random
import sys
import time
from dataclasses import dataclass

# Allow running from any directory (repo root is one level up from scripts/).
_repo = pathlib.Path(__file__).parent.parent
sys.path.insert(0, str(_repo))
from bindings.prefixdb import PrefixDB  # noqa: E402

# ---------------------------------------------------------------------------
# Workload model — identical logic to generate_kv_blocks.py
# ---------------------------------------------------------------------------

_ZERO_VALUE = b'\x00' * 32


@dataclass
class Account:
    address: bytes
    hot_slots: list[bytes]
    warm_anchors: list[int]
    access_count: int = 0


class WorkloadGenerator:
    HOT_PROB  = 0.00
    WARM_PROB = 0.05

    def __init__(
        self,
        pool_size: int = 1000,
        alpha: float = 1.2,
        new_account_prob: float = 0.002,
        hot_slots_per_account: int = 4,
        warm_anchors_per_account: int = 3,
        spread: int = 64,
        min_block_size: int = 100,
        max_block_size: int = 800,
        read_prob: float = 0.85,
        seed: int | None = None,
    ):
        self.rng = random.Random(seed)
        self.alpha = alpha
        self.new_account_prob = new_account_prob
        self.hot_slots_per_account = hot_slots_per_account
        self.warm_anchors_per_account = warm_anchors_per_account
        self.spread = spread
        self.min_block_size = min_block_size
        self.max_block_size = max_block_size
        self.read_prob = read_prob

        self.pool: list[Account] = []
        self._prefix_sums: list[float] = []
        for _ in range(pool_size):
            self._append_account(self._make_account())

    def _rand_bytes(self, n: int) -> bytes:
        return self.rng.randbytes(n)

    def _make_account(self) -> Account:
        address = self._rand_bytes(20)
        hot_slots = [self._rand_bytes(32) for _ in range(self.hot_slots_per_account)]
        warm_anchors = [
            (int.from_bytes(self._rand_bytes(32), "big") // self.spread) * self.spread
            for _ in range(self.warm_anchors_per_account)
        ]
        return Account(address, hot_slots, warm_anchors)

    def _append_account(self, acct: Account) -> None:
        rank = len(self.pool) + 1
        w = 1.0 / rank ** self.alpha
        prev = self._prefix_sums[-1] if self._prefix_sums else 0.0
        self._prefix_sums.append(prev + w)
        self.pool.append(acct)

    def _sample_account(self) -> Account:
        if self.rng.random() < self.new_account_prob:
            acct = self._make_account()
            self._append_account(acct)
            return acct
        r = self.rng.uniform(0.0, self._prefix_sums[-1])
        idx = min(bisect.bisect_left(self._prefix_sums, r), len(self.pool) - 1)
        self.pool[idx].access_count += 1
        return self.pool[idx]

    def _sample_storage_key(self, acct: Account) -> bytes:
        r = self.rng.random()
        if r < self.HOT_PROB and acct.hot_slots:
            return self.rng.choice(acct.hot_slots)
        if r < self.WARM_PROB and acct.warm_anchors:
            anchor = self.rng.choice(acct.warm_anchors)
            offset = self.rng.randrange(self.spread)
            key_int = (anchor + offset) % (2 ** 256)
            return key_int.to_bytes(32, "big")
        return self._rand_bytes(32)

    def generate_blocks(self, num_blocks: int):
        """Yield (block_no, address, storage_key, op, value) for every access."""
        for block_no in range(1, num_blocks + 1):
            size = self.rng.randint(self.min_block_size, self.max_block_size)
            for _ in range(size):
                acct = self._sample_account()
                key = self._sample_storage_key(acct)
                if self.rng.random() < self.read_prob:
                    yield block_no, acct.address, key, 'r', _ZERO_VALUE
                else:
                    yield block_no, acct.address, key, 'w', self._rand_bytes(32)


# ---------------------------------------------------------------------------
# Key derivation: (account[20] || storage_key[32]) → db_key[32]
# ---------------------------------------------------------------------------

def derive_key(account: bytes, storage_key: bytes) -> bytes:
    """Compress (account, storage_key) to a single 32-byte DB key via sha256."""
    return hashlib.sha256(account + storage_key).digest()


# ---------------------------------------------------------------------------
# State root
# ---------------------------------------------------------------------------

def compute_state_root(writes: dict[bytes, bytes]) -> bytes:
    """Legacy Python-side root (sha256 over sorted block writes).  Not used in
    the main benchmark path — kept for reference / unit-testing only."""
    h = hashlib.sha256()
    for k in sorted(writes):
        h.update(k)
        h.update(writes[k])
    return h.digest()


# ---------------------------------------------------------------------------
# Latency statistics helpers
# ---------------------------------------------------------------------------

def _percentile(sorted_vals: list[float], p: float) -> float:
    if not sorted_vals:
        return 0.0
    idx = max(0, int(len(sorted_vals) * p / 100) - 1)
    return sorted_vals[idx]


def _latency_stats(lats: list[float]) -> dict:
    if not lats:
        return {"count": 0, "mean_us": 0.0, "p50_us": 0.0, "p95_us": 0.0, "p99_us": 0.0}
    s = sorted(lats)
    return {
        "count":   len(s),
        "mean_us": round(sum(s) / len(s) * 1e6, 2),
        "p50_us":  round(_percentile(s, 50) * 1e6, 2),
        "p95_us":  round(_percentile(s, 95) * 1e6, 2),
        "p99_us":  round(_percentile(s, 99) * 1e6, 2),
    }


# ---------------------------------------------------------------------------
# Per-block execution
# ---------------------------------------------------------------------------

def _run_block(
    db: PrefixDB,
    block_no: int,
    ops: list[tuple],
    live_keys: set[bytes],
    compaction_budget: int | None = 0,
) -> dict:
    """Execute one block's ops on `db`, compute state root and compact."""
    read_lats: list[float] = []
    write_lats: list[float] = []
    read_hits = 0
    block_writes: dict[bytes, bytes] = {}

    for _, account, storage_key, op, value in ops:
        k = derive_key(account, storage_key)
        if op == 'w':
            t0 = time.perf_counter()
            db.put(k, value)
            write_lats.append(time.perf_counter() - t0)
            block_writes[k] = value
            live_keys.add(k)
        else:
            t0 = time.perf_counter()
            result = db.get(k)
            read_lats.append(time.perf_counter() - t0)
            if result is not None:
                read_hits += 1

    # commit_block flushes L0 and recomputes the full Merkle commitment tree.
    # Latency comes from the Zig-side nanosecond timer stored in commit_block_ns.
    state_root = db.commit_block()

    t_cmp0 = time.perf_counter()
    db.compact(budget=compaction_budget)
    compaction_lat = time.perf_counter() - t_cmp0

    raw_metrics = db.get_metrics()
    db.reset_metrics()
    commit_ns = raw_metrics.commit_block_ns

    n_r = len(read_lats)
    n_w = len(write_lats)
    total_op_time = sum(read_lats) + sum(write_lats)

    # Derived amplification ratios (safe against division by zero).
    read_amp = round(raw_metrics.read_sst_loads / max(raw_metrics.read_ops, 1), 4)
    filter_selectivity = round(
        1.0 - raw_metrics.append_filter_hits / max(raw_metrics.append_filter_probes, 1), 4
    )
    sst_hits = raw_metrics.sst_cache_hits
    sst_total = raw_metrics.sst_cache_hits + raw_metrics.sst_cache_misses
    sst_cache_hit_rate = round(sst_hits / max(sst_total, 1), 4)
    write_amp = round(raw_metrics.compaction_sst_writes / max(raw_metrics.write_ops, 1), 4)

    m = raw_metrics.as_dict()
    elapsed_s = sum(read_lats) + sum(write_lats)
    disk_reads  = m.get("disk_node_reads", 0) + m.get("disk_sst_reads", 0)
    disk_writes = m.get("disk_node_writes", 0) + m.get("disk_sst_writes", 0)
    disk_read_iops  = disk_reads  / max(elapsed_s, 1e-12)
    disk_write_iops = disk_writes / max(elapsed_s, 1e-12)

    return {
        "block_no": block_no,
        "reads": n_r,
        "writes": n_w,
        "ops": n_r + n_w,
        "block_duration_ms": round((total_op_time + commit_ns / 1e9 + compaction_lat) * 1e3, 3),
        "read_throughput_ops_s":  round(n_r / max(sum(read_lats),  1e-12), 1),
        "write_throughput_ops_s": round(n_w / max(sum(write_lats), 1e-12), 1),
        "read_latency":  _latency_stats(read_lats),
        "write_latency": _latency_stats(write_lats),
        "read_hit_rate": round(read_hits / max(n_r, 1), 4),
        "block_unique_writes": len(block_writes),
        "state_root": state_root.hex(),
        "state_root_latency_us": round(commit_ns / 1e3, 2),
        "commit_nodes_processed": raw_metrics.commit_nodes_processed,
        "compaction_latency_ms": round(compaction_lat * 1e3, 3),
        # Internal metrics (non-zero only when built with -Denable_metrics=true).
        "metrics": raw_metrics.as_dict(),
        "read_amp": read_amp,
        "filter_selectivity": filter_selectivity,
        "sst_cache_hit_rate": sst_cache_hit_rate,
        "write_amp": write_amp,
        "disk_read_iops":  round(disk_read_iops, 1),
        "disk_write_iops": round(disk_write_iops, 1),
    }


# ---------------------------------------------------------------------------
# Progress output
# ---------------------------------------------------------------------------

def _print_progress(bm: dict, total_blocks: int, elapsed: float) -> None:
    bn = bm["block_no"]
    pct = bn / total_blocks * 100
    eta = (total_blocks - bn) / max(bn / elapsed, 1e-12)
    print(
        f"[{bn:>{len(str(total_blocks))}}/{total_blocks}] {pct:5.1f}%  "
        f"ops={bm['ops']}  "
        f"r_p99={bm['read_latency']['p99_us']:.1f}µs  "
        f"w_p99={bm['write_latency']['p99_us']:.1f}µs  "
        f"hit={bm['read_hit_rate']:.1%}  "
        f"commit={bm['state_root_latency_us']:.0f}µs  "
        f"cmp={bm['compaction_latency_ms']:.1f}ms  "
        f"elapsed={elapsed:.1f}s  eta={eta:.1f}s",
        file=sys.stderr,
    )


# ---------------------------------------------------------------------------
# Main benchmark loop
# ---------------------------------------------------------------------------

def run_benchmark(
    gen: WorkloadGenerator,
    num_blocks: int,
    print_every: int,
    node_cap: int | None = None,
    sst_cap: int | None = None,
    db_dir: str | None = None,
    compaction_budget: int | None = 0,
) -> tuple[list[dict], dict]:
    """Drive the workload against a single PrefixDB instance, collect metrics."""
    block_metrics: list[dict] = []
    live_keys: set[bytes] = set()

    bench_start = time.perf_counter()

    # Buffer ops per block, then flush at block boundary.
    current_block_ops: list[tuple] = []
    current_block_no = 1

    with PrefixDB(path=db_dir, node_cap=node_cap, sst_cap=sst_cap) as db:
        for record in gen.generate_blocks(num_blocks):
            block_no = record[0]
            if block_no != current_block_no:
                bm = _run_block(db, current_block_no, current_block_ops, live_keys, compaction_budget)
                block_metrics.append(bm)
                if print_every > 0 and (current_block_no % print_every == 0 or current_block_no == 1):
                    _print_progress(bm, num_blocks, time.perf_counter() - bench_start)
                current_block_ops = []
                current_block_no = block_no
            current_block_ops.append(record)

        # Flush the last block.
        if current_block_ops:
            bm = _run_block(db, current_block_no, current_block_ops, live_keys, compaction_budget)
            block_metrics.append(bm)
            if print_every > 0:
                _print_progress(bm, num_blocks, time.perf_counter() - bench_start)

    total_elapsed = time.perf_counter() - bench_start
    total_reads  = sum(m["reads"]  for m in block_metrics)
    total_writes = sum(m["writes"] for m in block_metrics)
    total_ops    = total_reads + total_writes
    unique_keys  = len(live_keys)

    # Amplification.
    # write_amp: each logical write issues one db.put(); overwriting the same
    # key N times counts as N puts. This ratio captures how "write-heavy" the
    # workload is relative to the live set.
    write_amp = round(total_writes / max(unique_keys, 1), 3)
    # space_amp: bytes ever written (total_writes × 64) vs minimum needed
    # to store the live set once (unique_keys × 64).
    space_amp = round(total_writes / max(unique_keys, 1), 3)   # same ratio; bytes cancel

    # Aggregate latency across blocks (weighted by op count).
    def _weighted_mean(metric: str, op_count_key: str) -> float:
        num = sum(m[metric]["mean_us"] * m[op_count_key] for m in block_metrics if m[op_count_key] > 0)
        den = sum(m[op_count_key] for m in block_metrics if m[op_count_key] > 0)
        return round(num / max(den, 1), 2)

    # Aggregate internal metrics across all blocks.
    def _sum_metric(field: str) -> int:
        return sum(m["metrics"][field] for m in block_metrics)

    total_read_sst   = _sum_metric("read_sst_loads")
    total_read_ops_m = _sum_metric("read_ops")
    total_cmp_writes = _sum_metric("compaction_sst_writes")
    total_write_ops_m = _sum_metric("write_ops")
    total_sst_hits   = _sum_metric("sst_cache_hits")
    total_sst_miss   = _sum_metric("sst_cache_misses")
    total_fp         = _sum_metric("append_filter_probes")
    total_fh         = _sum_metric("append_filter_hits")
    total_disk_node_reads  = _sum_metric("disk_node_reads")
    total_disk_node_writes = _sum_metric("disk_node_writes")
    total_disk_sst_reads   = _sum_metric("disk_sst_reads")
    total_disk_sst_writes  = _sum_metric("disk_sst_writes")

    summary = {
        "total_blocks":    num_blocks,
        "total_ops":       total_ops,
        "total_reads":     total_reads,
        "total_writes":    total_writes,
        "unique_keys_written": unique_keys,
        "total_elapsed_s": round(total_elapsed, 3),
        "overall_throughput_ops_s":       round(total_ops    / max(total_elapsed, 1e-12), 1),
        "overall_read_throughput_ops_s":  round(total_reads  / max(total_elapsed, 1e-12), 1),
        "overall_write_throughput_ops_s": round(total_writes / max(total_elapsed, 1e-12), 1),
        "weighted_mean_read_latency_us":  _weighted_mean("read_latency",  "reads"),
        "weighted_mean_write_latency_us": _weighted_mean("write_latency", "writes"),
        "write_amplification": write_amp,
        "space_amplification": space_amp,
        "compaction_total_ms":   round(sum(m["compaction_latency_ms"]   for m in block_metrics), 2),
        "state_root_total_us":   round(sum(m["state_root_latency_us"]   for m in block_metrics), 2),
        "compaction_fraction":   round(
            sum(m["compaction_latency_ms"] for m in block_metrics) /
            max(sum(m["block_duration_ms"] for m in block_metrics), 1e-12),
            4,
        ),
        # Internal metrics aggregated (non-zero only with -Denable_metrics=true).
        "internal": {
            "read_amp":           round(total_read_sst  / max(total_read_ops_m,  1), 4),
            "write_amp":          round(total_cmp_writes / max(total_write_ops_m, 1), 4),
            "sst_cache_hit_rate": round(total_sst_hits  / max(total_sst_hits + total_sst_miss, 1), 4),
            "filter_selectivity": round(1.0 - total_fh  / max(total_fp, 1), 4),
            "total_read_sst_loads":        total_read_sst,
            "total_compaction_sst_reads":  _sum_metric("compaction_sst_reads"),
            "total_compaction_sst_writes": total_cmp_writes,
            "total_l0_flushes":            _sum_metric("l0_flushes"),
            "total_compaction_ops":        _sum_metric("compaction_ops"),
            "total_disk_node_reads":         total_disk_node_reads,
            "total_disk_node_writes":        total_disk_node_writes,
            "total_disk_sst_reads":          total_disk_sst_reads,
            "total_disk_sst_writes":         total_disk_sst_writes,
            "total_commit_nodes_processed":  _sum_metric("commit_nodes_processed"),
            "total_commit_block_ns":         _sum_metric("commit_block_ns"),
        },
    }

    return block_metrics, summary


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    p.add_argument("-n", "--blocks", type=int, default=100,
                   help="Number of blocks to simulate (default: 100)")
    p.add_argument("--pool-size",      type=int,   default=1000)
    p.add_argument("--alpha",          type=float, default=1.2)
    p.add_argument("--new-prob",       type=float, default=0.002)
    p.add_argument("--hot-slots",      type=int,   default=4)
    p.add_argument("--warm-anchors",   type=int,   default=3)
    p.add_argument("--spread",         type=int,   default=64)
    p.add_argument("--min-block-size", type=int,   default=100)
    p.add_argument("--max-block-size", type=int,   default=800)
    p.add_argument("--read-prob",      type=float, default=0.85)
    p.add_argument("--seed",           type=int,   default=42)
    p.add_argument("-o", "--output",   default="metrics.json",
                   help="Output JSON file (default: metrics.json)")
    p.add_argument("--print-every", type=int, default=10,
                   help="Print progress every N blocks; 0 to disable (default: 10)")
    p.add_argument("--node-cache", type=int, default=None, metavar="N",
                   help="LRU capacity for routing-node pages (default: engine default = 1024)")
    p.add_argument("--sst-cache",  type=int, default=None, metavar="N",
                   help="LRU capacity for SST (KV) pages (default: engine default = 4096)")
    p.add_argument("--db-dir", default=None, metavar="PATH",
                   help="Directory for persistent database (enables disk I/O; auto-recovers on restart)")
    p.add_argument("--compaction-budget", type=int, default=0, metavar="N",
                   help="Max compaction procedures per block; 0 = engine default, -1 = unbounded drain (old behaviour)")
    return p.parse_args()


def main() -> None:
    args = parse_args()

    config = {
        "blocks":          args.blocks,
        "pool_size":       args.pool_size,
        "alpha":           args.alpha,
        "new_prob":        args.new_prob,
        "hot_slots":       args.hot_slots,
        "warm_anchors":    args.warm_anchors,
        "spread":          args.spread,
        "min_block_size":  args.min_block_size,
        "max_block_size":  args.max_block_size,
        "read_prob":       args.read_prob,
        "seed":            args.seed,
        "node_cache_cap":  args.node_cache,
        "sst_cache_cap":   args.sst_cache,
        "db_dir":          args.db_dir,
        "compaction_budget": args.compaction_budget,
    }

    cache_info = ""
    if args.node_cache is not None or args.sst_cache is not None:
        nc = args.node_cache if args.node_cache is not None else 1024
        sc = args.sst_cache  if args.sst_cache  is not None else 4096
        cache_info = f", node_cache={nc}, sst_cache={sc}"
    print(
        f"Starting benchmark: {args.blocks} blocks, "
        f"pool={args.pool_size}, alpha={args.alpha}, read_prob={args.read_prob:.0%}{cache_info}",
        file=sys.stderr,
    )

    gen = WorkloadGenerator(
        pool_size=args.pool_size,
        alpha=args.alpha,
        new_account_prob=args.new_prob,
        hot_slots_per_account=args.hot_slots,
        warm_anchors_per_account=args.warm_anchors,
        spread=args.spread,
        min_block_size=args.min_block_size,
        max_block_size=args.max_block_size,
        read_prob=args.read_prob,
        seed=args.seed,
    )

    block_metrics, summary = run_benchmark(
        gen, args.blocks, args.print_every,
        node_cap=args.node_cache,
        sst_cap=args.sst_cache,
        db_dir=args.db_dir,
        compaction_budget=None if args.compaction_budget < 0 else args.compaction_budget,
    )

    with open(args.output, "w") as f:
        json.dump({"config": config, "summary": summary, "blocks": block_metrics}, f, indent=2)

    print(f"\nResults written to {args.output}", file=sys.stderr)
    s = summary
    i = s["internal"]
    print(
        f"  ops={s['total_ops']}  elapsed={s['total_elapsed_s']:.2f}s  "
        f"throughput={s['overall_throughput_ops_s']:.0f} ops/s\n"
        f"  r_lat={s['weighted_mean_read_latency_us']:.1f}µs  "
        f"w_lat={s['weighted_mean_write_latency_us']:.1f}µs\n"
        f"  write_amp={s['write_amplification']}  space_amp={s['space_amplification']}  "
        f"cmp_frac={s['compaction_fraction']:.1%}\n"
        f"  commit_total={i['total_commit_block_ns']/1e6:.1f}ms  "
        f"commit_nodes={i['total_commit_nodes_processed']}  "
        f"state_root_total={s['state_root_total_us']/1e3:.1f}ms\n"
        f"  [internal] read_amp={i['read_amp']}  write_amp={i['write_amp']}  "
        f"sst_hit={i['sst_cache_hit_rate']:.1%}  filter_sel={i['filter_selectivity']:.1%}",
        file=sys.stderr,
    )


if __name__ == "__main__":
    main()
