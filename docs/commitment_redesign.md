# Commitment Subsystem Redesign

Status: IMPLEMENTED 2026-06-11 (pass-through rule signed off; Merkle proof
*generation* API still pending — the stored page internals already serve it).
Supersedes the buffer-hash commitment scheme formerly implemented in
`commitBlock` (`nodeDataHash` mixing). Spec reference: `archive/overview.md` §2.2 (a duplicate of `specifications_v4.md`).

> **Partially superseded 2026-07-06 on the flat-store branch**
> (`exploratory/prefix-files`): the canonical trie function of §2
> (pass-through combine, 65-byte leaf domain separation) remains
> authoritative and unchanged, but the page machinery (§3 stride-6
> commitment pages, index-page split, §4.2 `T_DEEPEN`, §7
> `CommitmentPageStore`) is replaced by an implicit RAM heap (depths
> 0–`H`, `H` a config knob) over recomputed — not persisted — leaf
> subtrees. See `specifications_v5.md` §4. Goal 4 below ("every proof
> sibling is stored") is deliberately relaxed below depth `H` there.

Implementation notes vs this draft: deepening (`T_DEEPEN`, §4.2) is deferred —
bottom-slot occupancy at current scale doesn't warrant it yet; depth-1/2
commitment pages are persisted (only the depth-0 page is memory-only), which
makes recovery trivially cheap; `downwardMerge` gained a no-grandchildren
guard so node removal preserves path-connectivity (which gathers rely on).
Measured: commit cost is linear in block writes (~150 µs per written key at
slot occupancy ~49), independent of database size; identical 600k-key mappings
produce identical roots across write orders and compaction histories; the
engine root matches a naive evaluator of §2 in tests.

## 1. Goals and invariants

1. **Canonical roots.** The state root is a pure function of the key-value
   mapping. Identical mappings produce identical roots regardless of write
   order, compaction history, or which pages exist. (The current scheme
   violates this once `upwardSplit` moves data across depths — verified
   empirically with 600k keys.)
2. **Commitments are decoupled from storage.** Commitment computation never
   reads SST or append pages structurally; compaction never dirties
   commitment state. The only coupling is the *bottom-slot gather* (§5),
   which is a point lookup of a slot's key set, not a dependency on layout.
3. **Commit work is in-memory and proportional to the block's writes**, not to
   database size.
4. **Merkle proofs are first-class**: every sibling hash a proof needs is
   stored, not recomputed.

Decisions already made (2026-06-11): stride stays 6; commitment pages use the
127-hash full-subtree layout ("option C"); index pages reclaim the freed 2 KiB
for a higher-precision, larger append zone.

## 2. The canonical tree function

The commitment is a binary trie over the full 256-bit key space. To make the
root independent of *which commitment pages happen to be cached* (stride
boundaries must not affect values), the node rule must be purely local:

```
leafHash(K, V)   = Blake3(0x00 ‖ K ‖ V)      // 65-byte input, see §2.1
combine(L, R)    = ZERO                      if L = ZERO and R = ZERO
                 = L                         if R = ZERO        (pass-through)
                 = R                         if L = ZERO        (pass-through)
                 = Blake3(L ‖ R)             otherwise           (pairHash)
value(subtree)   = ZERO                      if empty
                 = leafHash(K, V)            if it contains exactly one key
                 = combine(value(left half), value(right half))  otherwise
```

The **pass-through rule** is the load-bearing refinement (see §2.2 for why).
A subtree containing a single key has value `leafHash(K,V)` at *every* level
up to the first point where it meets a non-empty sibling — no hash chains
through empty levels, ever. Empty subtrees are ZERO at every level, as today.
The root is `value(whole key space)`.

This function is canonical: it never mentions strides, pages, or NodePages.
Stride-6 commitment pages (§4) are pure caches of its values at 6-bit
intervals; creating or destroying a page cannot change any committed value.

### 2.1 Domain separation

`leafHash` input must be distinguishable from `combine` input, otherwise an
attacker can present an internal node `(L,R)` as a leaf `(K=L, V=R)`.
Cheapest sound option: make the leaf input 65 bytes —
`leafHash(K,V) = Blake3(0x00 ‖ K ‖ V)` — while `combine` keeps its 64-byte
input. Different input lengths give domain separation for free.
Position binding: because the full key `K` is inside the leaf hash, the
pass-through collapse cannot be abused to relocate a leaf (standard compact-SMT
argument).

Deletes: a tombstoned key is *absent* — its leaf is ZERO and the slot is
recomputed without it. The gather (§5) must filter tombstones.

### 2.2 Why pass-through instead of fixed-shape chains

With fixed-shape hashing (`pairHash(X, ZERO)` is a real hash), a slot
recompute must re-derive every cohabitant's chain from bit-depth 256 up to the
slot. With slot occupancy k ≈ 100 and keys diverging ~7 bits below the slot,
that is ≈ k × 230 ≈ 23,000 pairHashes ≈ 2.3 ms *per dirty slot*, i.e. ~460 ms
per 200-write block — worse than the scheme we are replacing. With
pass-through, a slot recompute is k leaf hashes + (k−1) combines ≈ 20 µs.
Roughly a 100× difference; chains simply never exist. This also retires the
"deep chain of single nodes" concern entirely — nothing is stored *and*
nothing is computed for empty levels.

This is the one refinement relative to the earlier "simple bit extension with
chained hashes" discussion — review §2 before implementation starts.

## 3. Page types

NodePages split into two page types. Routing entries carry both ids
(`index_page_id`, `commitment_page_id`); one routing lookup, load only what
the operation needs. Index pages and commitment pages are never co-resident
in one physical page.

### 3.1 Commitment page — 4 KiB, one per (depth, prefix) node

The complete 6-level binary subtree of the node, as an implicit heap
`h[1..127]` (`h[2i]`, `h[2i+1]` are children of `h[i]`):

| offset | size | content |
|---|---|---|
| 0 | 4 B | version u8, flags u8, pad u16 |
| 4 | 8 B | `leaf_valid` u64 — lazy-leaf validity bitmap (§4.2) |
| 12 | 20 B | reserved |
| 32 | 4064 B | `h[1..127]`: 127 × 32 B hashes |

- `h[1]` = the node's own subtree commitment (what the parent's leaf holds).
- `h[64..127]` = the 64 child-slot values at depth+1.
- `h[2..63]` = internal levels, stored so proofs read siblings directly and
  single-leaf updates cost 6 combines.
- All values follow the §2 `combine` rule (including pass-through), so the
  stored internals are canonical trie values, not page-local artifacts.

Update rule — **in-memory representation only** (disk flushing is always
out-of-place, §7): the cached page is mutated directly; b dirty leaves → if
b ≲ 10, update b heap paths (6 combines each); else rebuild all 63 internals
(~6 µs). Either way `h[1]` is pushed into the parent page's leaf and the
parent is marked dirty (existing worklist propagation carries over unchanged).

A **depth-0 page** (memory-only) holds the 64 depth-1 commitments and the
state root at `h[1]`, replacing the ad-hoc `d1_commitments` array and making
proof shape uniform from root to leaf.

### 3.2 Index page — 4 KiB, append zone upgraded

Freed 2,048 B go to append-filter precision (16 → 32 bits, the existing
`prefix32` helper) and append capacity (8 → 12 pages):

| field | size | |
|---|---|---|
| header (sorted_count, append_count, pad) | 4 B | |
| sorted_slot_ids[104] | 416 B | S_MAX 108 → 104 |
| sorted_min4[104] | 416 B | |
| sorted_page_counts[104] | 104 B | |
| append_page_counts[12] | 12 B | A_MAX 8 → 12 |
| append_slot_ids[12] | 48 B | |
| append_prefix32[12][64] | 3,072 B | u32 filters |
| reserved | 24 B | |
| **total** | **4,096 B** | |

Effects: filter false-positive rate per append-page probe drops from
64/2^16 ≈ 0.1% to 64/2^32 ≈ 1.5e-8 (wasted SST loads vanish); 50% more append
absorption before an `appendToSortedMerge`, so compaction runs ~⅓ less often.
Sorted capacity 104 × 64 = 6,656 entries (vs 6,912) — bottom-slot occupancy is
essentially unchanged, which matters for §5 cost. The promotion check moves
from `prefix16 >> 10` to `prefix32 >> 26`. All on-disk formats are version 1 —
there is no released format to migrate from.

## 4. Commitment tree maintenance

### 4.1 Dirtiness — from the write stream, not from storage events

`markDirty` no longer fires from `appendSstToNode`/compaction (commitment
values are invariant under data movement). Instead, the dirty set is derived
from the block's logical writes: at `commitBlock`, for each written/deleted
key K in the block (already available in L0/kv_map/WAL), resolve the deepest
commitment page on K's path and mark `(page, slot)` dirty — a 64-bit dirty
mask per touched bottom page. Disk-dirtiness (`*_dirty_flush`, age-gated
amortised flushing) carries over as built.

### 4.2 Page existence and lazy leaves

A commitment page exists at (d, P) iff a NodePage exists there (same routing),
**plus** optional commitment-only pages one level deeper wherever bottom-slot
occupancy exceeds a threshold `T_DEEPEN` (default 16; tunable). When a page is
created (node split or deepening), its leaves are *not* eagerly computed:
`leaf_valid = 0`, and each leaf is filled by a gather on first need. Creating
the page changes no values — the parent's leaf already equals what the new
page's `h[1]` will be.

### 4.3 Commit algorithm

```
commitBlock:
  flush L0 (storage concern, unchanged)
  for each written key K in block: mark bottom slot dirty
  for each dirty bottom page, deepest first:
      for each dirty slot: gather slot key set (§5), recompute slot value (§2)
      update heap paths / rebuild internals; push h[1] into parent leaf; mark parent
  propagate up the worklist to depth-0 page; root = depth0.h[1]
  WAL block_commit; age-gated flush of cold dirty pages (both types)
```

## 5. The bottom-slot gather (option A)

To recompute a bottom slot, enumerate its keys: prefix-scan the node buffers
along the path (sorted zone via `sorted_min4` binary search, append zone via
the new u32 filters), dedup (L0/kv_map newest-wins), filter tombstones. All
in the in-memory page cache in practice; 1–2 SST page touches per slot.

Cost model (the design's one scaling knob):

- per dirty slot ≈ k leaf hashes + (k−1) combines + gather ≈ **~25 µs at k≈100**
- per block: 200 writes → ≤200 slots → **~5 ms**; 5,000 writes → ~50–125 ms
  *unless* deepening keeps k ≤ T_DEEPEN=16 → **~4 µs/slot, ~20 ms** at 5,000
  writes. Multiple writes to one slot amortise further.

If "commitments never consult storage" is later wanted *categorically*, a
per-slot leaf-hash cache (~64 B per live key, pageable) slots in behind the
same gather interface without changing any committed value.

## 6. Proofs

A proof for key K: per stride level, the 6 sibling hashes along K's path read
directly from the commitment page heap; below the bottom slot, the (few)
non-ZERO siblings at branch points plus a presence bitmap (pass-through means
ZERO siblings are skipped, compact-SMT style). Verification replays §2 rules.
Estimated size ≈ 6 × 32 B per cached level + ~log2(k) × 32 B at the bottom.

## 7. Persistence and recovery

Two addressing layers, kept distinct:

- **Logical identity**: a commitment page is identified by (depth, prefix) —
  stable for the life of the node. Routing maps it to the current physical id.
- **Physical placement**: flushing is **always out-of-place (copy-on-write)**,
  exactly like node pages today — each flush allocates a fresh page id in the
  commitment container and writes there; the manifest checkpoint atomically
  repoints routing to the new ids. The previous checkpoint's pages remain
  valid until the checkpoint completes, so a crash mid-flush loses nothing
  (and SSDs never see same-LBA overwrites of live data). Superseded versions
  are garbage once the checkpoint lands.

In-place mutation exists only in the in-memory cache (§3.1). The "no CoW
churn" benefit of the split is about *what* gets rewritten, not *how*: with
co-location, every index CoW dragged 2 KB of unchanged commitment bytes to
disk; with separate page types, a commitment page is flushed only when
commitment values actually changed.

- Near-root levels (0–2) are memory-only per spec; deeper levels use a new
  `CommitmentPageStore` with its own container files; manifest gains a
  commitment-routing section; all formats are version 1 (pre-release).
- Recovery: manifest restores checkpointed pages; WAL replay re-marks dirty
  slots from logged kv_writes and recomputes them via gather — commitments are
  derived data, always rebuildable.
- Flushing policy: identical age-gated machinery, applied per page type.

## 8. Testing

- **History-invariance (new, the key regression):** same final mapping via
  different write orders / compaction schedules / intermediate commits ⇒
  identical root (the 600k-key experiment, as a permanent test).
- Page-existence invariance: force splits/deepening, root unchanged.
- Reference implementation: naive §2 evaluator over a plain sorted map;
  fuzz engine root against it (writes, overwrites, deletes).
- Proof round-trip: generate + verify for present and absent keys.
- All existing root-value tests get new expected values (scheme change is
  intentional and total).

## 9. Open items (review before implementation)

1. **Sign-off on §2 pass-through rule** — it replaces "chained hashes through
   empty levels" for the ~100× reason in §2.2, and is the one deviation from
   the earlier discussion.
2. S_MAX=104 / A_MAX=12 split (alternative: S_MAX=108 / A_MAX=11, 249 B spare).
3. `T_DEEPEN` default (16) and whether deepening lands in phase 1 or later.
4. Exact leaf domain-separation encoding (proposed: 65-byte `0x00 ‖ K ‖ V`).
