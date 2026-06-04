#!/usr/bin/env python3
"""
Generate per-block (account, storage_key, op[, value]) records that mimic
Ethereum smart-contract workloads (e.g. Uniswap v2/v3 pools, ERC-20 tokens).

Access model per account
------------------------
  hot slots  (~70 %): a small set of specific storage keys hit on almost every
                       access — analogous to Uniswap reserve0/reserve1/slot0.
  warm region (~25 %): anchor regions where keys cluster (user balances, LP
                       positions), sampled with small random offsets.
  cold / random (~ 5 %): fully random 32-byte key.

Account selection
-----------------
  Zipf power-law over a growing pool.  Unnormalized prefix sums let new accounts
  be appended in O(1) without recomputing the whole weight vector; sampling is
  O(log n) via bisect.  A small probability injects a brand-new account each step.

Block model
-----------
  Each block contains a variable number of accesses drawn uniformly from
  [--min-block-size, --max-block-size].  Each access is tagged read ('r') or
  write ('w'); reads dominate (--read-prob, default 0.85).

  Writes carry a 32-byte value (SSTORE); reads do not (SLOAD).

Output formats
--------------
  csv    — columns: block_number,account,storage_key,op,value
           (value is empty for reads, 64-char hex for writes)
  hex    — "block_no account_hex key_hex op [value_hex]" per line
  binary — 89 bytes per record (fixed-size, zero-padded value for reads):
             4B  block_no (big-endian unsigned)
            20B  account address
            32B  storage key
             1B  op  (0x00 = read, 0x01 = write)
            32B  value (32 zero bytes for reads)

Usage examples
--------------
  python generate_kv_blocks.py -n 1000 --format csv -o accesses.csv --stats
  python generate_kv_blocks.py -n 500  --pool-size 200 --alpha 1.5 --format binary -o accesses.bin
  python generate_kv_blocks.py -n 2000 --min-block-size 50 --max-block-size 1200 --read-prob 0.9
"""

from __future__ import annotations

import argparse
import bisect
import random
import sys
import time
from dataclasses import dataclass

_ZERO_VALUE = b'\x00' * 32


# ---------------------------------------------------------------------------
# Data model
# ---------------------------------------------------------------------------

@dataclass
class Account:
    address: bytes           # 20 bytes
    hot_slots: list[bytes]   # specific 32-byte keys — updated on most accesses
    warm_anchors: list[int]  # anchor values (as int) for warm-region sampling
    access_count: int = 0


# ---------------------------------------------------------------------------
# Workload generator
# ---------------------------------------------------------------------------

class WorkloadGenerator:
    """Yields (block_no, account_address, storage_key, op, value) tuples."""

    HOT_PROB  = 0.70   # prob of hitting a hot slot
    WARM_PROB = 0.95   # cumulative; 0.70–0.95 = warm region, 0.95–1.00 = cold

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
        # Unnormalized Zipf prefix sums: prefix_sums[i] = sum_{r=1}^{i+1} 1/r^alpha.
        # New accounts are appended in O(1); sampling is O(log n) via bisect.
        self._prefix_sums: list[float] = []

        for _ in range(pool_size):
            self._append_account(self._make_account())

    # ------------------------------------------------------------------
    # Internal helpers
    # ------------------------------------------------------------------

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

    def _append_account(self, acct: Account):
        rank = len(self.pool) + 1          # 1-based Zipf rank
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
        idx = bisect.bisect_left(self._prefix_sums, r)
        idx = min(idx, len(self.pool) - 1)   # clamp for float rounding at boundary
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

    # ------------------------------------------------------------------
    # Public interface
    # ------------------------------------------------------------------

    def generate_blocks(self, num_blocks: int):
        """Yield (block_no, address, key, op, value) for every access across all blocks.

        op    : 'r' (read/SLOAD) or 'w' (write/SSTORE)
        value : 32 random bytes for writes; _ZERO_VALUE for reads
        """
        for block_no in range(1, num_blocks + 1):
            size = self.rng.randint(self.min_block_size, self.max_block_size)
            for _ in range(size):
                acct = self._sample_account()
                key = self._sample_storage_key(acct)
                if self.rng.random() < self.read_prob:
                    yield block_no, acct.address, key, 'r', _ZERO_VALUE
                else:
                    yield block_no, acct.address, key, 'w', self._rand_bytes(32)

    def stats(self) -> dict:
        counts = sorted((a.access_count for a in self.pool), reverse=True)
        total = sum(counts) or 1
        top10_share = sum(counts[:10]) / total if len(counts) >= 10 else 1.0
        return {
            "pool_size": len(self.pool),
            "top_10_share": top10_share,
            "max_access": counts[0] if counts else 0,
        }


# ---------------------------------------------------------------------------
# Buffered writer with progress logging
# ---------------------------------------------------------------------------

Record = tuple[int, bytes, bytes, str, bytes]   # (block_no, addr, key, op, value)


def _flush(f, buf: list[Record], fmt: str) -> None:
    if fmt == "binary":
        f.write(b"".join(
            n.to_bytes(4, "big") + a + k + (b'\x00' if op == 'r' else b'\x01') + v
            for n, a, k, op, v in buf
        ))
    elif fmt == "csv":
        f.write("".join(
            f"{n},{a.hex()},{k.hex()},{op},{v.hex() if op == 'w' else ''}\n"
            for n, a, k, op, v in buf
        ))
    else:  # hex
        f.write("".join(
            f"{n} {a.hex()} {k.hex()} {op}" + (f" {v.hex()}" if op == 'w' else "") + "\n"
            for n, a, k, op, v in buf
        ))


def _log(blocks_done: int, total_blocks: int, records: int, t_start: float) -> None:
    elapsed = time.monotonic() - t_start
    rec_rate = records / elapsed if elapsed > 0 else 0.0
    blk_rate = blocks_done / elapsed if elapsed > 0 else 0.0
    pct = blocks_done / total_blocks * 100
    eta = (total_blocks - blocks_done) / blk_rate if blk_rate > 0 else float("inf")
    eta_str = f"{eta:.1f}s" if eta != float("inf") else "?"
    print(
        f"[{blocks_done:>{len(str(total_blocks))}}/{total_blocks} blocks] {pct:5.1f}%  "
        f"records={records}  rate={rec_rate/1000:.1f}k rec/s  elapsed={elapsed:.1f}s  eta={eta_str}",
        file=sys.stderr,
    )


def generate_to_file(
    gen: WorkloadGenerator,
    num_blocks: int,
    fmt: str,
    out_path: str,
    buffer_size: int,
) -> None:
    is_binary = fmt == "binary"
    if out_path == "-":
        f = sys.stdout.buffer if is_binary else sys.stdout
        owned = False
    else:
        f = open(out_path, "wb" if is_binary else "w")
        owned = True

    try:
        if fmt == "csv":
            f.write("block_number,account,storage_key,op,value\n")  # type: ignore[arg-type]

        buf: list[Record] = []
        written = 0
        last_block = 0
        t_start = time.monotonic()

        for block_no, addr, key, op, value in gen.generate_blocks(num_blocks):
            buf.append((block_no, addr, key, op, value))
            last_block = block_no
            if len(buf) >= buffer_size:
                _flush(f, buf, fmt)
                written += len(buf)
                buf.clear()
                _log(last_block, num_blocks, written, t_start)

        if buf:
            _flush(f, buf, fmt)
            written += len(buf)
            _log(num_blocks, num_blocks, written, t_start)

    finally:
        if owned:
            f.close()  # type: ignore[union-attr]


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    p.add_argument("-n", "--blocks", type=int, default=1000,
                   help="Number of blocks to generate (default: 1 000)")
    p.add_argument("--pool-size", type=int, default=1000,
                   help="Initial account pool size (default: 1000)")
    p.add_argument("--alpha", type=float, default=1.2,
                   help="Zipf exponent — higher = more skew toward hot accounts (default: 1.2)")
    p.add_argument("--new-prob", type=float, default=0.002,
                   help="Probability of injecting a new account per sample (default: 0.002)")
    p.add_argument("--hot-slots", type=int, default=4,
                   help="Critical (hot) storage slots per account (default: 4)")
    p.add_argument("--warm-anchors", type=int, default=3,
                   help="Warm storage region anchors per account (default: 3)")
    p.add_argument("--spread", type=int, default=64,
                   help="Warm-region locality spread in slots (default: 64)")
    p.add_argument("--min-block-size", type=int, default=100,
                   help="Minimum accesses per block (default: 100)")
    p.add_argument("--max-block-size", type=int, default=800,
                   help="Maximum accesses per block (default: 800)")
    p.add_argument("--read-prob", type=float, default=0.85,
                   help="Probability an access is a read vs write (default: 0.85)")
    p.add_argument("--seed", type=int, default=42,
                   help="Random seed for reproducibility (default: 42)")
    p.add_argument("--format", choices=["csv", "hex", "binary"], default="csv",
                   help="Output format (default: csv)")
    p.add_argument("-o", "--output", default="-",
                   help="Output file path, or - for stdout (default: -)")
    p.add_argument("--buffer-size", type=int, default=50_000,
                   help="Records per write buffer / progress tick (default: 50 000)")
    p.add_argument("--stats", action="store_true",
                   help="Print workload statistics to stderr after generation")
    return p.parse_args()


def main():
    args = parse_args()

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

    generate_to_file(gen, args.blocks, args.format, args.output, args.buffer_size)

    if args.stats:
        s = gen.stats()
        avg_block = (args.min_block_size + args.max_block_size) / 2
        print(
            f"pool_size={s['pool_size']}  "
            f"top10_share={s['top_10_share']:.1%}  "
            f"max_access={s['max_access']}  "
            f"avg_block_size~{avg_block:.0f}  "
            f"read_prob={args.read_prob:.0%}",
            file=sys.stderr,
        )


if __name__ == "__main__":
    main()
