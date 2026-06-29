#!/usr/bin/env python3
"""
Seed a persistent PrefixDB with key-value pairs drawn from the benchmark
workload model.

Keys are produced with the SAME derive_key() and Zipf account/storage model as
benchmark_kv.py, so a subsequent

    python scripts/benchmark_kv.py --db-dir <same path> ...

run will find its reads hitting the pre-loaded state (at least for the per-account
hot/warm slots, which are deterministic given the pool seed). Cold/random keys
are, by nature, unlikely to overlap.

To maximise key-space overlap with the benchmark, pass the SAME
--pool-size / --alpha / --new-prob / --hot-slots / --warm-anchors / --spread /
--seed values you intend to use in benchmark_kv.py.

This is a write-only bulk loader: it puts N pairs, periodically commits a block
(to bound the in-memory dirty/L0 set), then drains compaction and flushes the
manifest so the populated state survives on disk.

Usage examples
--------------
  python scripts/seed_kv.py --db-dir ./seeded -n 100000
  python scripts/seed_kv.py --db-dir ./seeded -n 1000000 --pool-size 5000 --seed 42
  python scripts/seed_kv.py --db-dir ./seeded -n 500000 --commit-every 25000
"""

from __future__ import annotations

import argparse
import pathlib
import sys
import time

# Allow running from any directory (repo root is one level up from scripts/).
_repo = pathlib.Path(__file__).parent.parent
sys.path.insert(0, str(_repo))
sys.path.insert(0, str(pathlib.Path(__file__).parent))

from bindings.prefixdb import PrefixDB          # noqa: E402
from benchmark_kv import WorkloadGenerator, derive_key  # noqa: E402


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    p.add_argument("--db-dir", required=True, metavar="PATH",
                   help="Directory for the persistent database (created/recovered).")
    p.add_argument("-n", "--num-pairs", type=int, default=100_000,
                   help="Number of key-value pairs to put (default: 100000). "
                        "Key reuse means the resulting live-key count may be lower.")
    p.add_argument("--commit-every", type=int, default=50_000, metavar="N",
                   help="Commit a block every N puts to bound memory (default: 50000).")
    # Workload-model params — keep these in sync with the benchmark for overlap.
    p.add_argument("--pool-size",    type=int,   default=1000)
    p.add_argument("--alpha",        type=float, default=1.2)
    p.add_argument("--new-prob",     type=float, default=0.002)
    p.add_argument("--hot-slots",    type=int,   default=4)
    p.add_argument("--warm-anchors", type=int,   default=3)
    p.add_argument("--spread",       type=int,   default=64)
    p.add_argument("--seed",         type=int,   default=42)
    p.add_argument("--node-cache", type=int, default=None, metavar="N",
                   help="LRU capacity for routing-node pages (default: engine default).")
    p.add_argument("--sst-cache",  type=int, default=None, metavar="N",
                   help="LRU capacity for SST (KV) pages (default: engine default).")
    return p.parse_args()


def main() -> None:
    args = parse_args()

    # read_prob=0.0 makes every sampled access a write; we drive the sampler
    # directly below so this only affects the model's internal bookkeeping.
    gen = WorkloadGenerator(
        pool_size=args.pool_size,
        alpha=args.alpha,
        new_account_prob=args.new_prob,
        hot_slots_per_account=args.hot_slots,
        warm_anchors_per_account=args.warm_anchors,
        spread=args.spread,
        read_prob=0.0,
        seed=args.seed,
    )

    print(
        f"Seeding {args.num_pairs} pairs into {args.db_dir!r}  "
        f"(pool={args.pool_size}, alpha={args.alpha}, seed={args.seed}, "
        f"commit_every={args.commit_every})",
        file=sys.stderr,
    )

    t0 = time.perf_counter()
    last_root = b""

    with PrefixDB(path=args.db_dir, node_cap=args.node_cache, sst_cap=args.sst_cache) as db:
        for i in range(1, args.num_pairs + 1):
            acct = gen._sample_account()
            storage_key = gen._sample_storage_key(acct)
            key = derive_key(acct.address, storage_key)
            value = gen._rand_bytes(32)
            db.put(key, value)

            if i % args.commit_every == 0:
                last_root = db.commit_block()
                elapsed = time.perf_counter() - t0
                rate = i / max(elapsed, 1e-12)
                print(
                    f"  [{i}/{args.num_pairs}] committed  "
                    f"root={last_root.hex()[:16]}…  "
                    f"{rate:,.0f} puts/s  elapsed={elapsed:.1f}s",
                    file=sys.stderr,
                )

        # Final commit (covers the trailing partial batch), full compaction
        # drain, and manifest flush so the state is durable on disk.
        last_root = db.commit_block()
        db.compact(budget=None)
        db.flush()
        live = db.estimate_key_count()

    elapsed = time.perf_counter() - t0
    print(
        f"\nDone in {elapsed:.1f}s.\n"
        f"  puts issued      : {args.num_pairs}\n"
        f"  est. live keys   : {live}\n"
        f"  final state_root : {last_root.hex()}\n"
        f"  db dir           : {args.db_dir}",
        file=sys.stderr,
    )


if __name__ == "__main__":
    main()
