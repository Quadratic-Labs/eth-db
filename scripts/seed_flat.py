#!/usr/bin/env python3
"""
Seed a FlatDB base from storage-<block>.tsv files, so a subsequent benchmark reads
against a realistic on-disk base instead of an empty store.

Input format (whitespace/tab separated), one row per storage entry:
    address    slot    value    keccak256(slot)
e.g.  0xabc..(20B)  0x012..(32B)  0x07..(32B)  0x9c..(32B)
The 4th column (keccak256(slot)) is ignored.

KEY DERIVATION — must match the benchmark, or its reads won't hit the seeded keys.
This reuses benchmark_flat/benchmark_kv's `derive_key`:
    key = sha256(address[20] || slot[32])          # raw slot, NOT keccak256(slot)
If you want a different scheme (e.g. keccak, or hashing the keccak'd slot), change it in
ONE place — `benchmark_kv.derive_key` — so seeding and the benchmark stay in lock-step.

Loading strategy: rows are `put` into the memtable; every `--freeze-rows` they are frozen
into an L0 run (bounding memtable RAM), and a compaction is run when due (bounding L0 RAM
and folding data down to the on-disk base). A final freeze + full compaction consolidates
everything into the base. `covered_height` ends at the highest block seen.

Scale note: this is a Python op-by-op loader (~tens of K puts/s). Fine for up to ~tens of
millions of rows; for billions, a streaming Zig bulk loader (external sort → base file) is
the right tool — not built yet.

Usage:
    zig build lib
    python3 scripts/seed_flat.py --db-dir /mnt/big/flatdb storage-*.tsv
    python3 scripts/seed_flat.py --db-dir /mnt/big/flatdb --prefix-bits 24 data/   # a dir
    # then benchmark against the seeded store:
    python3 scripts/benchmark_flat.py --db-dir /mnt/big/flatdb --bal-prefetch --o-direct ...
"""

from __future__ import annotations

import argparse
import glob
import os
import pathlib
import re
import sys
import time

_repo = pathlib.Path(__file__).parent.parent
sys.path.insert(0, str(_repo))
sys.path.insert(0, str(pathlib.Path(__file__).parent))

from bindings.flatdb import FlatDB  # noqa: E402
from benchmark_kv import derive_key  # noqa: E402  (sha256(account || storage_key))

_BLOCK_RE = re.compile(r"storage-(\d+)\.tsv$")


def _block_num(path: str) -> int:
    m = _BLOCK_RE.search(os.path.basename(path))
    return int(m.group(1)) if m else 0


def _expand_inputs(inputs: list[str]) -> list[str]:
    files: list[str] = []
    for item in inputs:
        if os.path.isdir(item):
            files.extend(glob.glob(os.path.join(item, "storage-*.tsv")))
        else:
            files.extend(glob.glob(item))  # supports shell globs passed as a string
    # Process in block order so later blocks' values overwrite earlier (last write wins).
    return sorted(set(files), key=_block_num)


def _parse_row(line: str) -> tuple[bytes, bytes] | None:
    """Return (db_key, value32) or None for blank/unparseable lines."""
    f = line.split()
    if len(f) < 3:
        return None
    try:
        addr = int(f[0], 16).to_bytes(20, "big")
        slot = int(f[1], 16).to_bytes(32, "big")
        val = int(f[2], 16).to_bytes(32, "big")
    except (ValueError, OverflowError):
        return None
    return derive_key(addr, slot), val


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("inputs", nargs="+", help="storage-<block>.tsv files, globs, or directories")
    p.add_argument("--db-dir", required=True, help="Directory for the FlatDB store (created if absent)")
    p.add_argument("--prefix-bits", type=int, default=24, help="Partition prefix width (only used when creating; default 24)")
    p.add_argument("--window-entries", type=int, default=0, help="Interpolation window size in entries (0 = engine default 1024 = 64 KiB); only used when creating")
    p.add_argument("--memtable-cap", type=int, default=0, help="Unique keys before an auto-freeze is due (0 = engine default)")
    p.add_argument("--l0-threshold", type=int, default=16, help="Frozen runs before compaction is due (default 16)")
    p.add_argument("--freeze-rows", type=int, default=1_000_000, help="Rows between explicit freezes (bounds memtable RAM; default 1e6)")
    p.add_argument("--progress-every", type=int, default=1_000_000, help="Print progress every N rows (0 to disable)")
    args = p.parse_args()

    files = _expand_inputs(args.inputs)
    if not files:
        print("no input files matched", file=sys.stderr)
        sys.exit(1)
    print(f"Seeding {args.db_dir} from {len(files)} file(s), prefix_bits={args.prefix_bits}", file=sys.stderr)

    rows = 0
    bad = 0
    start = time.perf_counter()
    cur_block = 0

    with FlatDB(
        args.db_dir,
        prefix_bits=args.prefix_bits,
        window_entries=args.window_entries,
        memtable_cap=args.memtable_cap,
        l0_threshold=args.l0_threshold,
        freeze_interval=1,  # unused here (we freeze explicitly by row count)
    ) as db:
        for path in files:
            cur_block = _block_num(path)
            with open(path, "r") as fh:
                for line in fh:
                    parsed = _parse_row(line)
                    if parsed is None:
                        bad += 1
                        continue
                    key, val = parsed
                    db.put(key, val)
                    rows += 1
                    if rows % args.freeze_rows == 0:
                        db.freeze(cur_block)
                        if db.compaction_due():
                            db.compact()
                    if args.progress_every and rows % args.progress_every == 0:
                        el = time.perf_counter() - start
                        print(f"  {rows:,} rows  ({rows / max(el, 1e-9):,.0f}/s)  block={cur_block}", file=sys.stderr)

        # Consolidate everything into the on-disk base.
        db.freeze(cur_block)
        db.compact()
        covered = db.covered_height()

    elapsed = time.perf_counter() - start
    base_bytes = sum(os.path.getsize(b) for b in glob.glob(os.path.join(args.db_dir, "flat.base.*")))
    print(
        f"\nSeeded {rows:,} rows ({bad:,} skipped) in {elapsed:.1f}s "
        f"({rows / max(elapsed, 1e-9):,.0f}/s)\n"
        f"  covered_height={covered}  base_on_disk={base_bytes / (1 << 20):.1f} MiB  dir={args.db_dir}",
        file=sys.stderr,
    )


if __name__ == "__main__":
    main()
