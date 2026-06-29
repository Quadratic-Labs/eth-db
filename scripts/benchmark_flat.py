#!/usr/bin/env python3
"""
Benchmark the flat KV store (FlatDB) against an Ethereum-like workload.

This is the commitment-free counterpart of benchmark_kv.py: it reuses the *exact
same* WorkloadGenerator and key derivation, but drives the redesigned flat store
(src/flat_store.zig, via bindings/flatdb.py) and omits the per-block state-root /
commit step — the flat store is decoupled from the commitment tree, so at execution
time there is nothing to commit.

Differences from benchmark_kv.py
--------------------------------
  * Engine          — FlatDB (io_uring-batched windowed reads, in-RAM L0, streaming
                      compaction, native tombstones) instead of the legacy tree.
  * No commit       — no compute_state_root(); reads/writes only.
  * Block boundary  — `end_block(height)` (block-aligned freeze trigger) replaces the
                      tree's per-block compact(); compaction is then host-driven in the
                      "idle window" via a budgeted `compact_step(budget)` when due.
  * Metrics         — FlatDB exposes no internal counters, so the internal read_amp /
                      cache / filter section is dropped. write/space amplification are
                      the same logical (overwrite) ratios as benchmark_kv.py. (On-disk
                      WAF is not yet surfaced through the C API.)
  * Disk-backed     — FlatDB always uses a directory; a temp dir is used if --db-dir is
                      omitted (and removed at exit unless --keep).
  * --batch-reads   — optional: batch consecutive reads within a block through the
                      io_uring `get_many` path; reported read latency is then amortized
                      per key across each batch.

Usage examples
--------------
  python scripts/benchmark_flat.py -n 200 -o metrics_flat.json --print-every 20
  python scripts/benchmark_flat.py -n 500 --freeze-interval 8 --l0-threshold 4 --batch-reads
"""

from __future__ import annotations

import argparse
import json
import pathlib
import shutil
import sys
import tempfile
import time

# Repo root (for bindings) and scripts/ (to reuse the workload model).
_repo = pathlib.Path(__file__).parent.parent
sys.path.insert(0, str(_repo))
sys.path.insert(0, str(pathlib.Path(__file__).parent))

from bindings.flatdb import FlatDB  # noqa: E402
from benchmark_kv import (  # noqa: E402  (identical workload + helpers)
    WorkloadGenerator,
    derive_key,
    _latency_stats,
    _print_progress,
)


# ---------------------------------------------------------------------------
# Per-block execution (no commit)
# ---------------------------------------------------------------------------

def _run_block(
    db: FlatDB,
    block_no: int,
    ops: list[tuple],
    live_keys: set[bytes],
    compact_budget: int,
    batch_reads: bool,
    bal_prefetch: bool,
) -> dict:
    """Execute one block's ops on `db`, then end the block (freeze if due) and spend
    one idle-window compaction budget if a compaction is due. No state root."""
    read_lats: list[float] = []
    write_lats: list[float] = []
    read_hits = 0
    block_writes: dict[bytes, bytes] = {}

    # BAL mode: the whole block read set is known upfront, so prefetch it in ONE batched
    # io_uring pass (queue depth up to the ring), filling the prefetch map; execution then
    # reads from RAM. Writes during the block still shadow it (read-your-writes preserved).
    prefetch_lat = 0.0
    if bal_prefetch:
        read_keys = [derive_key(a, sk) for (_, a, sk, op, _) in ops if op == 'r']
        if read_keys:
            t0 = time.perf_counter()
            db.prefetch(read_keys)
            prefetch_lat = time.perf_counter() - t0

    # Pending run of consecutive reads, flushed as one io_uring batch (batch mode).
    pending_keys: list[bytes] = []

    def flush_reads() -> None:
        nonlocal read_hits
        if not pending_keys:
            return
        t0 = time.perf_counter()
        vals = db.get_many(pending_keys)
        dt = time.perf_counter() - t0
        per = dt / len(pending_keys)  # amortized per-key latency
        for v in vals:
            read_lats.append(per)
            if v is not None:
                read_hits += 1
        pending_keys.clear()

    # In BAL mode reads resolve from the prefetch map, so issue them serially (RAM-fast).
    use_batch = batch_reads and not bal_prefetch
    for _, account, storage_key, op, value in ops:
        k = derive_key(account, storage_key)
        if op == 'w':
            if use_batch:
                flush_reads()  # preserve read-your-writes ordering
            t0 = time.perf_counter()
            db.put(k, value)
            write_lats.append(time.perf_counter() - t0)
            block_writes[k] = value
            live_keys.add(k)
        else:
            if use_batch:
                pending_keys.append(k)
            else:
                t0 = time.perf_counter()
                result = db.get(k)
                read_lats.append(time.perf_counter() - t0)
                if result is not None:
                    read_hits += 1
    if use_batch:
        flush_reads()

    # Block boundary: freeze if due (NO commit / state root).
    h0 = db.covered_height()
    t_eb = time.perf_counter()
    db.end_block(block_no)
    end_block_lat = time.perf_counter() - t_eb
    froze = db.covered_height() != h0

    # Idle window: spend one compaction budget if a compaction is due / in progress.
    comp_status = "none"
    comp_lat = 0.0
    if db.compaction_due():
        t_c = time.perf_counter()
        comp_status = db.compact_step(compact_budget)
        comp_lat = time.perf_counter() - t_c

    n_r = len(read_lats)
    n_w = len(write_lats)
    op_time = sum(read_lats) + sum(write_lats)

    return {
        "block_no": block_no,
        "reads": n_r,
        "writes": n_w,
        "ops": n_r + n_w,
        "block_duration_ms": round((op_time + prefetch_lat + end_block_lat + comp_lat) * 1e3, 3),
        "read_throughput_ops_s":  round(n_r / max(sum(read_lats),  1e-12), 1),
        "write_throughput_ops_s": round(n_w / max(sum(write_lats), 1e-12), 1),
        "read_latency":  _latency_stats(read_lats),
        "write_latency": _latency_stats(write_lats),
        "read_hit_rate": round(read_hits / max(n_r, 1), 4),
        "block_unique_writes": len(block_writes),
        "froze": froze,
        "covered_height": db.covered_height(),
        "end_block_latency_us": round(end_block_lat * 1e6, 2),
        "compaction_status": comp_status,
        "compaction_latency_ms": round(comp_lat * 1e3, 3),
        "prefetch_latency_ms": round(prefetch_lat * 1e3, 3),
    }


# ---------------------------------------------------------------------------
# Main benchmark loop
# ---------------------------------------------------------------------------

def run_benchmark(
    gen: WorkloadGenerator,
    num_blocks: int,
    print_every: int,
    db_dir: str,
    *,
    prefix_bits: int,
    memtable_cap: int,
    l0_threshold: int,
    freeze_interval: int,
    compact_budget: int,
    batch_reads: bool,
    bal_prefetch: bool,
    o_direct: bool,
) -> tuple[list[dict], dict]:
    block_metrics: list[dict] = []
    live_keys: set[bytes] = set()
    bench_start = time.perf_counter()

    current_block_ops: list[tuple] = []
    current_block_no = 1

    with FlatDB(
        db_dir,
        prefix_bits=prefix_bits,
        memtable_cap=memtable_cap,
        l0_threshold=l0_threshold,
        freeze_interval=freeze_interval,
        o_direct=o_direct,
    ) as db:
        def finish(bno: int, ops: list[tuple]) -> None:
            bm = _run_block(db, bno, ops, live_keys, compact_budget, batch_reads, bal_prefetch)
            block_metrics.append(bm)
            if print_every > 0 and (bno % print_every == 0 or bno == 1):
                _print_progress(bm, num_blocks, time.perf_counter() - bench_start)

        for record in gen.generate_blocks(num_blocks):
            block_no = record[0]
            if block_no != current_block_no:
                finish(current_block_no, current_block_ops)
                current_block_ops = []
                current_block_no = block_no
            current_block_ops.append(record)
        if current_block_ops:
            finish(current_block_no, current_block_ops)

        final_covered = db.covered_height()

    total_elapsed = time.perf_counter() - bench_start
    total_reads  = sum(m["reads"]  for m in block_metrics)
    total_writes = sum(m["writes"] for m in block_metrics)
    total_ops    = total_reads + total_writes
    unique_keys  = len(live_keys)

    # Logical amplification (overwrite ratio); on-disk WAF is not exposed by FlatDB.
    write_amp = round(total_writes / max(unique_keys, 1), 3)
    space_amp = round(total_writes / max(unique_keys, 1), 3)

    def _weighted_mean(metric: str, op_count_key: str) -> float:
        num = sum(m[metric]["mean_us"] * m[op_count_key] for m in block_metrics if m[op_count_key] > 0)
        den = sum(m[op_count_key] for m in block_metrics if m[op_count_key] > 0)
        return round(num / max(den, 1), 2)

    num_freezes = sum(1 for m in block_metrics if m["froze"])
    num_compactions_done = sum(1 for m in block_metrics if m["compaction_status"] == "done")

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
        "compaction_total_ms": round(sum(m["compaction_latency_ms"] for m in block_metrics), 2),
        "compaction_fraction": round(
            sum(m["compaction_latency_ms"] for m in block_metrics) /
            max(sum(m["block_duration_ms"] for m in block_metrics), 1e-12),
            4,
        ),
        "num_freezes":          num_freezes,
        "num_compactions_done": num_compactions_done,
        "final_covered_height": final_covered,
        "batch_reads": batch_reads,
        "bal_prefetch": bal_prefetch,
        "o_direct": o_direct,
        "prefetch_total_ms": round(sum(m["prefetch_latency_ms"] for m in block_metrics), 2),
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
    # Workload (identical to benchmark_kv.py).
    p.add_argument("-n", "--blocks", type=int, default=100)
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
    p.add_argument("-o", "--output",   default="metrics_flat.json")
    p.add_argument("--print-every", type=int, default=10)
    # Flat-store knobs.
    p.add_argument("--prefix-bits",     type=int, default=16, help="Partition prefix width (1..32, default 16)")
    p.add_argument("--memtable-cap",    type=int, default=0,  help="Unique keys before freeze (0 = engine default 64K)")
    p.add_argument("--l0-threshold",    type=int, default=4,  help="Frozen runs before compaction is due (default 4)")
    p.add_argument("--freeze-interval", type=int, default=8,  help="Blocks between freezes (default 8)")
    p.add_argument("--compact-budget",  type=int, default=4 << 20, help="New-base output bytes per idle-window compaction step (default 4 MiB)")
    p.add_argument("--batch-reads", action="store_true", help="Batch consecutive reads via io_uring get_many (amortized read latency)")
    p.add_argument("--bal-prefetch", action="store_true", help="Block Access List mode: prefetch the whole block read set in one io_uring batch (deep queue), then execute from RAM")
    p.add_argument("--o-direct", action="store_true", help="Open the hot read fd with O_DIRECT (bypass page cache) to measure cold reads")
    p.add_argument("--db-dir", default=None, metavar="PATH", help="Directory for the store (default: a temp dir, removed at exit)")
    p.add_argument("--keep", action="store_true", help="Keep the temp db dir after the run")
    return p.parse_args()


def main() -> None:
    args = parse_args()

    tmp_created = False
    db_dir = args.db_dir
    if db_dir is None:
        db_dir = tempfile.mkdtemp(prefix="flatdb_bench_")
        tmp_created = True

    config = {
        "engine": "flatdb",
        "blocks": args.blocks, "pool_size": args.pool_size, "alpha": args.alpha,
        "new_prob": args.new_prob, "hot_slots": args.hot_slots, "warm_anchors": args.warm_anchors,
        "spread": args.spread, "min_block_size": args.min_block_size, "max_block_size": args.max_block_size,
        "read_prob": args.read_prob, "seed": args.seed,
        "prefix_bits": args.prefix_bits, "memtable_cap": args.memtable_cap,
        "l0_threshold": args.l0_threshold, "freeze_interval": args.freeze_interval,
        "compact_budget": args.compact_budget, "batch_reads": args.batch_reads,
        "bal_prefetch": args.bal_prefetch, "o_direct": args.o_direct,
        "db_dir": db_dir,
    }

    print(
        f"Starting flat-db benchmark: {args.blocks} blocks, pool={args.pool_size}, "
        f"alpha={args.alpha}, read_prob={args.read_prob:.0%}, prefix_bits={args.prefix_bits}, "
        f"freeze_interval={args.freeze_interval}, l0_threshold={args.l0_threshold}, "
        f"batch_reads={args.batch_reads}, bal_prefetch={args.bal_prefetch}, o_direct={args.o_direct}",
        file=sys.stderr,
    )

    gen = WorkloadGenerator(
        pool_size=args.pool_size, alpha=args.alpha, new_account_prob=args.new_prob,
        hot_slots_per_account=args.hot_slots, warm_anchors_per_account=args.warm_anchors,
        spread=args.spread, min_block_size=args.min_block_size, max_block_size=args.max_block_size,
        read_prob=args.read_prob, seed=args.seed,
    )

    try:
        block_metrics, summary = run_benchmark(
            gen, args.blocks, args.print_every, db_dir,
            prefix_bits=args.prefix_bits, memtable_cap=args.memtable_cap,
            l0_threshold=args.l0_threshold, freeze_interval=args.freeze_interval,
            compact_budget=args.compact_budget, batch_reads=args.batch_reads,
            bal_prefetch=args.bal_prefetch, o_direct=args.o_direct,
        )
        with open(args.output, "w") as f:
            json.dump({"config": config, "summary": summary, "blocks": block_metrics}, f, indent=2)
    finally:
        if tmp_created and not args.keep:
            shutil.rmtree(db_dir, ignore_errors=True)

    s = summary
    print(f"\nResults written to {args.output}", file=sys.stderr)
    print(
        f"  ops={s['total_ops']}  elapsed={s['total_elapsed_s']:.2f}s  "
        f"throughput={s['overall_throughput_ops_s']:.0f} ops/s\n"
        f"  r_lat={s['weighted_mean_read_latency_us']:.1f}µs  "
        f"w_lat={s['weighted_mean_write_latency_us']:.1f}µs  "
        f"r_tput={s['overall_read_throughput_ops_s']:.0f}/s\n"
        f"  freezes={s['num_freezes']}  compactions_done={s['num_compactions_done']}  "
        f"cmp_total={s['compaction_total_ms']:.1f}ms  cmp_frac={s['compaction_fraction']:.1%}\n"
        f"  prefetch_total={s['prefetch_total_ms']:.1f}ms  o_direct={s['o_direct']}  bal_prefetch={s['bal_prefetch']}\n"
        f"  write_amp(logical)={s['write_amplification']}  covered_height={s['final_covered_height']}",
        file=sys.stderr,
    )


if __name__ == "__main__":
    main()
