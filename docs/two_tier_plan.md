# Two-Tier Commitment & Composite Keys — Implementation Plan

- **Status:** IMPLEMENTED 2026-07-08 (all phases) — `src/flat_store.zig`
  (`FlatStoreKeyed`/`FlatStore64`), `src/two_tier.zig` (`TwoTierDb` with
  per-phase commit stats), leaf tags in `src/commitment.zig`; Phase 4:
  `ttdb_*` C API (`src/c_api.zig`), `bindings/twotier.py`, and the
  `bench2` tool (`src/main_bench2.zig`: Zipf account sizes, size-proportional
  access sampling, storage-vs-account-tree commit breakdown). Supersedes the
  single-key-space assumption of `specifications_v5.md` §2.5/§4 for the
  account‖slot keying model.
- **Implementation refinement vs D1 below:** account records live in a **separate
  32-byte-key accounts store** (`account_hash → storage_root`, plain `FlatStore`),
  not as sentinel-suffix records inside the composite store. Reason: an
  account-tree unit gather needs only the unit's ~256 account records, but in a
  single store those interleave with all their slots — gathering an account unit
  would scan a whale's entire slot set. With the split, account-unit gathers are
  pure and uniform (the account tree is literally the unchanged single-tier
  `CommitmentDb`, tag 0x01), and the accounts store is wholly
  commitment-maintained derived data (see D5). The slots store keeps the 64-byte
  composite key / 96-byte record as approved.
- **Implementation notes:** `gatherBounds` locates base ranges by binary-searching
  records directly (no fence involvement — immune to fence non-monotonicity); the
  fenced *read* path gained a record-driven `fenceStepForward` mirroring the
  step-back, so manufactured 64-bit account-prefix collisions degrade to
  slow-but-correct in both directions (tested). D4's deferred adaptive splitting
  remains deferred; revisit with multi-drive sharding.
- **Premise:** keys become piecewise-uniform: `account_hash (32 B) ‖ slot_hash (32 B)`.
  Uniform across accounts, uniform within an account's slots, heavy-tailed account
  *sizes* (Zipf; whales up to ~10⁸ slots, most accounts 0). The design keeps every
  existing mechanism and replaces exactly one assumption: *fixed depth globally* →
  *fixed depth per uniform region, adaptive at the account boundary*.
- **Track note:** this is the binary-tree (Blake3, pass-through) research track, not
  mainnet-MPT-exact roots. The two-tier shape mirrors MPT's trie-of-tries, so an
  MPT-exact node function (keccak/RLP/hexary, stacktrie builder) can later replace
  the leaf/combine functions inside the same skeleton.

## 0. Decisions to lock before coding

| # | Decision | Recommendation |
|---|---|---|
| D1 | Key layout | 64-byte composite `account_hash ‖ slot_hash`; account records at sentinel suffix `slot_hash = 0³²` (unreachable as a real hash preimage). Record = 96 B packed (64 key + 32 value); windowed reads already tolerate non-page-divisible strides. Rejected: 16+16-byte truncated composite (2⁶⁴ grinding merges two accounts' state — correctness, not perf) and single re-hash to uniform (EIP-7864-style — discards the locality this whole design exists to exploit). |
| D2 | Key width in code | `comptime` key length on FlatStore (`FlatStore(64)`), keeping the 32-byte instantiation for existing tests/tools. Commitment layer works on the composite width only. |
| D3 | Read routing under skew | Interpolation is invalid on composite keys (bimodal suffixes). **Fences become the default and only routing** for composite stores; fence value = `acct[0..8] ‖ slot[0..8]` (16 B, u128 compare). Order-consistent except across 64-bit account-hash collisions, where the existing tie step-back preserves correctness. RAM: 16 B × records/G (G knob unchanged). |
| D4 | Flat partitioning | **Keep fixed P on account-hash top bits; defer adaptive splitting.** With D3, reads never depend on partition size; a whale partition only skews shard balance and compaction locality — revisit when multi-drive sharding lands. |
| D5 | `storage_root` materialization | Stored in the account record's flat value, written back via normal `put` at each commit (see §2 invariant). Not a sidecar map. |
| D6 | Big-account threshold | `T_big = 2^k`, k ≈ 12 (≈4096 slots — the unit size already tuned). n ≤ T_big: storage root recomputed whole from one range gather. n > T_big: per-account unit rows at depth `d_a = ⌈log₂ n⌉ − k`, so units stay ~2^k slots. Depth transitions are lazy (checkpoints are pure cache; a rebase is a background recompute, never a correctness event). |
| D7 | Account values | Engine keeps 32 B opaque values for v1 bench purposes, with `storage_root` occupying a defined sub-field for contract accounts. Real account encoding (nonce/balance/codehash > 32 B) is a later, independent record-format change. |

## 1. Phase 1 — Flat store on composite keys

1. Parametrize key width (`comptime KEY_LEN`); `RECORD_SIZE = KEY_LEN + 32`.
   Ripple: `locate`, `serialize`, run records (+1 tombstone byte), scratch sizing,
   `BaseBuilder`, manifest (add `key_len` field, version bump).
2. `partitionOf` unchanged in spirit (top bits of first 8 bytes = account-hash bits).
3. Fences per D3: 16-byte fence array (`[]u128`), `fenceUpperBound` on u128,
   `keyPrefix64` → `fenceKey(key)`; step-back logic unchanged.
4. Reject `fence_gap == 0` for composite stores (no interpolation path).
5. `gatherRange` generalized from `(prefix, bits)` to explicit `[lo, hi)` key bounds
   (still: contiguous base range + L0 + memtable snapshot, newest-wins). Two callers:
   account-unit ranges and per-account slot ranges/sub-ranges.
6. Tests: whale-account partition (10⁵⁺ records, one account), fence routing inside
   it, step-back across a manufactured 64-bit account-prefix collision, mixed
   account/slot records, reopen/compaction with 96 B records.

## 2. Phase 2 — Two-tier commitment

**Canonical function.** Storage leaf = `Blake3(0x00 ‖ slot_key ‖ value)`;
account leaf = `Blake3(0x01 ‖ account_hash ‖ account_value ‖ storage_root)`
(domain-tagged; `storage_root = ZERO` for storage-less accounts); `combine` and
pass-through unchanged at both levels. State root = binary trie over account-hash
space whose leaves are account leaves.

**Refactor.** Extract from `CommitmentDb` a reusable `SubtreeCommitter`
(unit rows + gather-recompute + recombine over an arbitrary key range at an
arbitrary heap depth). Instantiate it:
- once globally for the account tree (heap depth H over account-hash bits —
  today's code, unchanged behavior), and
- per big account for its storage trie (depth `d_a` per D6).

**The write-back invariant (load-bearing).** At `commitBlock`, for every dirty
account: recompute its storage root, then `put` the updated account record
(containing the new `storage_root`) through the normal flat write path *before*
recomputing account units. Consequences:
- Account-unit gather is self-contained: every gathered account record already
  carries a correct root (dirty ones just written; clean ones correct as of their
  last commit, by induction).
- Recovery needs nothing new: replayed blocks re-mark their accounts dirty, so
  stale stored roots are exactly the recomputed set.
- Commit-time puts land in the memtable after `endBlock`; `covered_height`
  semantics are untouched (roots are derived data, rebuilt on replay).

**Dirty tracking.** `dirty_accounts: account_hash → dirty-slot-unit set` (unit = the
whole trie for small accounts). Account-record writes mark the account dirty with an
empty slot set.

**Commit order.** (1) per dirty account: recompute storage root (small: one range
gather; big: dirty units + recombine) — embarrassingly parallel later, serial v1;
(2) write back account records; (3) memtable snapshot; (4) dirty account units →
account heap → root.

**Checkpoint format v2** (`flat.croot`, version 2): header + account-level depth-H
row (unchanged) + big-account section: `count × {account_hash, n, d_a, 2^{d_a}-row}`.
On open: restore rows, rebuild internals at both levels. Accounts that crossed
`T_big` since the checkpoint simply rebuild lazily (cache property).

**Caveat (explicit non-goal v1):** account deletion with populated storage needs a
range delete; post-Cancun selfdestruct is same-tx-creation only, so v1 supports
delete of accounts with ≤ T_big slots (enumerate + tombstone) and rejects larger.

## 3. Phase 3 — Tests

- Two-tier naive reference: evaluate `{account → (value, {slot → val})}` directly
  from the §2 function; engine root must match across blocks.
- History invariance including: whale account (synthetic 10⁵–10⁶ slots), slot
  overwrites/deletes, account creation, storage emptied to zero (root reverts to
  account-without-storage leaf), different write orders and compaction schedules.
- Threshold crossing: grow an account past `T_big`, verify root unchanged across the
  d_a rebase; shrink below it, same.
- Checkpoint v2 round-trip with big-account rows; replay-after-checkpoint.
- Parallel-invariance guard (for when parallel storage roots land): commit result
  independent of account processing order — already implied by canonicity, tested
  via shuffled dirty-set iteration.

## 4. Phase 4 — c_api / bindings / bench

- API works on `(account: 32 B, slot: 32 B)` pairs: `put_slot`, `get_slot`,
  `put_account`, `delete_slot`, …; commit surface unchanged
  (`commit_block → root`).
- Bench: Zipf account-size generator (`--accounts N --zipf S --whale-slots M`);
  per-phase commit metrics (storage-root time vs account-tree time vs write-back);
  dirty-accounts and dirty-units counters.

## 5. Sequencing & risk

Phase 1 is the widest ripple (key width through store/manifest/tools) but
mechanically boring; Phase 2 is the real design content and lands mostly in
`commitment.zig`; Phases 3–4 mirror the existing test/bench patterns. Biggest
risks, in order: fence behavior under manufactured prefix collisions (test early),
the write-back invariant interacting with freeze timing (test replay paths hard),
and checkpoint-v2 forward compatibility (version the file now).
