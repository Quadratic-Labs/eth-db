# PrefixDB — Technical Specification

- **Version:** 0.1 (Draft)
- **Date:** 2026-05-16
- **Status:** Work in Progress

---

## 1. Overview

PrefixDB is an authenticated key-value storage engine for Ethereum world state that synthesises the layered write-buffering of VerkleTrieDB (v1) with the compact routing index of QuotientDB (v2). Its distinguishing property is that compaction is *prefix-local*: instead of sorting and merging globally, the engine partitions the key space by 6-bit prefix strides at each level, confining compaction work to the pages that share a common prefix. This bounds write amplification to a small neighbourhood of the modified subtree and eliminates compaction-driven interference across unrelated key ranges.

Key properties:

- Pages of 64 KV-pairs (4 KiB) are the atomic unit of disk I/O — writes are buffered in-memory and flushed as full pages.
- A two-layer routing index — a small B+-tree over `(depth, prefix)` keys (top two levels permanently pinned, ≈ 22 MiB total) pointing to per-node data pages that hold SST slot IDs and combinadic filters — enables parallel lookup across all prefix levels with no serial pointer chasing.
- A prefix-partitioned multi-level store: level Lk holds pages whose entries share a common `6k`-bit key prefix.
- Commitment nodes are co-located 64 siblings per page and rewritten at most once per block per affected node.

---

## 2. Data Model

### 2.1 Storage Slots

A storage slot is a pair `(K, V)` where both `K` (the key) and `V` (the value) are 32-byte quantities. The store is therefore a mapping:

```
K : Bytes[32]  →  V : Bytes[32]
```

### 2.2 State Commitment

In addition to the raw slot mapping, the store maintains a cryptographic commitment to the full mapping — the **state root**. The commitment is structured as a large sparse binary prefix tree (trie):

- Each node represents a key prefix and has exactly two children, corresponding to the 0-bit and 1-bit extensions of that prefix.
- A node's commitment is the hash of its two children's commitments, producing a 32-byte digest.
- Leaf nodes hold the slot value directly.

> **Reference:** See the relevant EIP for the precise definition of Stem Nodes and other protocol-level subtleties. They do not materially affect the storage design described here.

### 2.3 Entries

All stored items — both slots and commitment nodes — are represented as uniform entries:

```
Entry := (key : Bytes[32], value : Bytes[32])   # 64 bytes with alignment padding
```

### 2.4 Pages

Entries are grouped into **pages** of 64 entries, matching a 4 KiB filesystem page:

```
Page := Entry[64]   # 4 KiB
```

Pages are the atomic unit of disk I/O; all reads and writes operate on full pages.

---

## 3. Commitment Caching

### 3.1 Motivation

Naively, every batch write would require recomputing commitments from leaf to root, touching every ancestor of every modified key. To avoid this, the store caches selected intermediate commitment nodes on disk.

Caching trades read for write and space amplification; however, since addressing relies only on key prefixes, reads and writes at different trie depths are independent and can proceed in parallel.

### 3.2 Cache Policy

Rather than caching every intermediate node, the store caches commitment nodes only at depths that are multiples of a fixed stride `D`. This bounds the recomputation cost to at most `D` levels when a cached node is invalidated. With `D = 6`, each commitment page holds exactly 64 sibling commitments, filling one 4 KiB page.

Upper tree levels (near the root) are updated very frequently but are cheaply recomputable from lower cached commitments, so they are kept **in memory only** and are not persisted to disk.

### 3.3 Commitment Pages

Commitment nodes at strided depths are stored 64 siblings per page at a 50 % load factor. Because commitments are recomputed at most once per block, each commitment page is rewritten at most once per block per affected node, tightly bounding commitment write amplification.

---

## 4. Storage Architecture

### 4.1 Sharding

For parallel I/O, the key space is partitioned into `2^S` shards using the first `S` bits of each key. Each shard maps to an independent filesystem directory, enabling the OS to manage locality and allowing independent compaction threads per shard.

### 4.2 Layered Storage

Storage is organised into levels L0 through LN. Level Lk holds pages whose entries share a common key prefix of `6k` bits.

**L0 (in-memory buffer):**
- New writes are appended to a sorted in-memory buffer and simultaneously journalled to a per-shard WAL for crash recovery.
- When the buffer accumulates ≥ 64 entries sharing a common 6-bit prefix, compaction to L1 can be triggered for that prefix group.
- Superseded values for duplicate keys are discarded at compaction time.

**L1:**
- Holds pages of 64 internally sorted entries, grouped by their first 6 bits of key prefix.
- Each routing-index node references at most N payload pages (N ≤ 85; see §4.3).
- When a prefix group reaches its page capacity, compaction to L2 is triggered: all pages for the group are merged, entries sharing a common 12-bit prefix are sorted and flushed as L2 pages, and the remainder is reorganised into fresh L1 pages.

**Lk (general):**
- Pages at level Lk hold entries sharing a common `6k`-bit prefix.
- On compaction, entries sharing a `6(k+1)`-bit prefix are promoted to L(k+1); the rest are reorganised into new Lk pages.
- Stale values for overwritten keys are discarded at each compaction.

**Compaction trigger:** A routing-index node initiates compaction when its SST page count reaches a configurable threshold (e.g., 64 pages per node).

> **Note on latency:** Because compaction is prefix-local, it seldom propagates across the full key space simultaneously. A per-block compaction budget can further bound worst-case processing time.

### 4.3 Routing Index

The routing index comprises two complementary on-disk structures: a **Routing B+-Tree** that maps `(depth, prefix)` keys to the heap address of a node's data page, and the **Node Data Pages** themselves, which store SST slot IDs and combinadic membership filters. Together they replace the old Patricia-trie: the B+-tree's top two levels are small enough to pin in RAM permanently, so the serial pointer-chasing dependency of trie traversal is eliminated — all node data pages for a lookup can be read in a single parallel batch.

#### 4.3.1 Routing B+-Tree

Every non-empty trie node — every `(depth, prefix)` pair that currently holds one or more SST pages — has exactly one entry in this tree.

**Routing key:** `(depth : u8,  prefix_data : u32)`

- `depth` is the level number k; a node at level Lk holds entries sharing a common `6k`-bit key prefix.
- `prefix_data` is the first `6 × depth` bits of the full key, left-aligned into 32 bits and zero-padded on the right.
- Sort order: lexicographic on `(depth, prefix_data)`, which groups all level-k entries into a contiguous band and places shallower nodes before deeper ones.

**Prefix extraction:**

```
prefix_data(K, d) = (K as u256) >> (256 − 6d),  as big-endian u32
```

**Leaf node layout (4 KiB):**

| Field | Size | Description |
|-------|------|-------------|
| `node_type` | 1 B | 0 = leaf |
| `_pad` | 1 B | |
| `entry_count` | 2 B | Number of entries in this leaf |
| `prev_leaf` | 4 B | Previous leaf page ID (doubly-linked leaf list) |
| `next_leaf` | 4 B | Next leaf page ID |
| `entries[]` | 9 B × 453 | `(depth : u8, prefix_data : u32, node_data_page_id : u32)` packed |

**Internal node layout (4 KiB):**

| Field | Size | Description |
|-------|------|-------------|
| `node_type` | 1 B | 1 = internal |
| `_pad` | 1 B | |
| `entry_count` | 2 B | Number of separator entries |
| `leftmost_child` | 4 B | Page ID of the leftmost child node |
| `_pad` | 4 B | |
| `entries[]` | 9 B × 453 | `(depth : u8, prefix_data : u32, child_page_id : u32)` packed |

Capacity: floor((4096 − 12) / 9) = **453 entries per node**.

**Tree height at scale:**

| Scale | SST pages / shard | B+-tree leaves / shard | L2 internal / shard | Height |
|-------|-------------------|------------------------|----------------------|--------|
| 2^32  | ≈ 2^18            | ≈ 579                  | ≈ 2                  | 3      |
| 2^36  | ≈ 2^22            | ≈ 9,259                | ≈ 21                 | 3      |

Height stays at **3** across the full target range.

**In-memory management:**

- **Permanently pinned:** the root page and all L2 internal pages — roughly 22 pages per shard × 256 shards × 4 KiB ≈ **22 MiB** total. After startup these pages never leave RAM.
- **LRU-cached:** B+-tree leaf pages. Because the pinned levels fully determine which leaf page contains any routing key, locating a node data page after warm-up requires exactly **one uncached leaf read per depth level**, and those reads are independent of one another.

**CoW updates:** on any structural change a new copy of the affected node plus its ancestors up to the root is written to the heap; old copies are released for GC. At height 3 this costs at most **3 B+-tree node writes** per routing entry change.

#### 4.3.2 Node Data Pages

Each B+-tree leaf entry `(depth, prefix_data, node_data_page_id)` points to a 4 KiB **node data page** on the heap. This page stores everything needed to filter and load the SSTs at that trie node:

| Field | Size | Description |
|-------|------|-------------|
| `commitment_slot_id` | 4 B | Heap address of this node's commitment page |
| `N` (SST count) | 1 B | Number of SST pages currently at this node |
| `sorted_page_count` | 1 B | Number of globally sorted SST pages |
| `_pad` | 2 B | |
| `payload_slot_ids` | 4 × N B | Heap addresses of the N SST pages |
| `key_fingerprints` | 44 × N B | Combinadic-encoded 10-bit key fingerprints (§7.1), one per SST page |

**Total size:** `8 + 48 × N` bytes → maximum **N = 85** SST pages per node (up from 84, owing to removal of the prefix-extension and children-pointer fields from the old Patricia-trie node).

The node data page is rewritten under CoW whenever SSTs are added, removed, or reordered at the node. The B+-tree entry pointing to it is updated in the same CoW operation, keeping the two always consistent.

**Compaction trigger:** a node initiates upward compaction when its SST count N reaches the configurable threshold (default 64 pages).

### 4.4 Heap

All persistent pages — B+-tree nodes, node data pages, KV payload, and commitment pages — are stored in a unified **page heap** with the following addressing scheme:

- **Page size:** 4 KiB.
- **Addressing:** 4-byte page identifiers → up to `2^32` pages → up to 16 TiB total addressable space.
- **Segment:** 1,024 contiguous pages = 4 MiB. The unit of allocation and GC.
- **Container:** 1,024 segments = 4 GiB. Stored as a single file, addressed by `(container_id, segment_offset)`.
- **Liveness bitmap:** One bit per page per segment (128 bytes), kept in memory and persisted to a sidecar file for GC use.

The three logical stores (routing index, KV payload, commitments) may be assigned separate containers with independent GC parameters and cache budgets.

### 4.5 Cache

- L0 is always fully resident in memory.
- Higher levels are paged in on demand; each heap can be assigned its own LRU cache size and eviction policy.
- B+-tree pages receive the highest eviction priority. The top two levels (root + L2 internal nodes, ≈ 22 MiB) are permanently pinned; leaf pages and node data pages compete for the remaining LRU budget.

---

## 5. Operations

### 5.1 Read

**Input:** key `K`

1. Check the L0 in-memory buffer; if `K` is present, return its value.
2. Compute one routing key per depth level along `K`'s path: for each d ∈ {1, 2, 3, 4, 5}, `rk[d] = (d, prefix_data(K, d))` (§4.3.1). (Deeper levels exist only if the key space has been partitioned that far by compaction.)
3. For each `rk[d]`: use the pinned root and L2 internal pages of the B+-tree to locate the leaf page that contains `rk[d]`. Because both internal levels are in RAM, no uncached reads are needed for this step.
4. **Issue all required B+-tree leaf page reads as a single parallel batch.** Each matching leaf entry yields a `node_data_page_id` for that depth level.
5. **Issue all node data page reads as a single parallel batch** — one read per depth level that has an entry.
6. For each node data page received: apply the combinadic key fingerprints (§7.1) to identify which of its SST pages may contain `K`; collect their `payload_slot_ids`.
7. **Issue all candidate SST page reads as a single parallel batch.**
8. For each candidate SST page, perform a linear scan over the 64 entries to locate `K`; record any match found.
9. Return the most-recently-written value found across all depth levels, or `null` if no candidate page contained `K`.
10. For any prefix node `(k, P)` from which ≥ T_opp SST pages were loaded in step 7, add `(k, P)` to the per-shard merge-candidate queue (§6.3). The pages are already in the page cache, so no extra I/O is incurred.

The critical I/O path after warm-up is three parallel rounds: B+-tree leaf pages → node data pages → SST pages.

### 5.2 Write

**Input:** key `K`, value `V`

1. Append `(K, V)` to the in-memory L0 buffer and write a WAL record.
2. If any 6-bit prefix group in the buffer reaches ≥ 64 entries, trigger compaction for that group (see §6).
3. For every SST page created or relocated by compaction: update the corresponding node data page and B+-tree entry under CoW (at most 3 B+-tree node writes per changed routing key).

### 5.3 Batch Write

A batch write is a sequence of single writes at the store level. At the application layer, a single slot write propagates commitment updates to every ancestor. Batching slot writes and computing commitment updates in a single pass ensures each trie node is touched exactly once, substantially reducing write amplification.

### 5.4 Block Finalisation

The following steps are executed at the end of each block:

1. Compute commitment updates for all affected strided nodes; rewrite their commitment pages.
2. Apply pending compaction within the available per-block compaction budget.
3. Write all new and modified B+-tree nodes and node data pages to the heap (CoW); `fsync`.
4. Truncate the WAL to the current checkpoint.
5. Run the GC pass on segments whose live-page ratio falls below the threshold (see §5.5).

> **Atomicity note:** New pages are always written before old ones are released. All index updates follow CoW. A crash at any point leaves the previous consistent state intact and recoverable via WAL replay.

### 5.5 Garbage Collection

GC reclaims heap pages whose liveness-bitmap bit has been cleared by a CoW index update or a key deletion.

**Trigger:** GC runs in the idle window between block finalisation and the arrival of the next block.

**Execution:**
1. Select segments whose live-page ratio falls below the threshold (e.g., 0.3).
2. For each selected segment: copy live pages to a fresh destination segment, update all B+-tree entries and node data page references via CoW, WAL the moves, and `fsync` after each batch.
3. Once a segment is fully evacuated, release its storage to the filesystem.

**Determinism:** GC is paused at block arrival and resumed at block finalisation, so it contributes zero latency variance to block processing.

---

## 6. Compaction

Compaction operates on a single prefix node at a time (micro-compaction), keeping I/O and routing-index updates localised. It runs in two directions: **upward split** when a node accumulates too many SST pages, and **downward merge** when a node becomes too sparse after deletions. All routing-index changes in both directions are made through the B+-tree (§4.3.1) and its node data pages (§4.3.2) under CoW.

### 6.1 Upward Split

**Trigger:** the SST count at node `(k, P)` reaches the compaction threshold (default 64 pages).

**Procedure:**

1. Read all SST pages referenced by the node data page for `(k, P)` (at most 85 pages, ≤ 340 KiB).
2. Merge all 64-byte entries across pages, retaining only the most-recent value for each key; discard superseded entries.
3. Sort the surviving entries by key.
4. Identify all groups of entries sharing a common `6(k+1)`-bit prefix.
5. For each such group of ≥ 64 entries: write the 64 least-recently-written entries as a new L(k+1) SST page; create or update the node data page for `(k+1, Q)` (where Q is the extended prefix); insert or update the B+-tree entry `(k+1, Q) → new_node_data_page_id` (CoW, ≤ 3 node writes).
6. Reorganise remaining entries into fresh Lk SST pages (up to 64 entries per page).
7. Rewrite the node data page for `(k, P)` with the new SST slot IDs and recomputed combinadic fingerprints; update the B+-tree entry `(k, P)` (CoW); release all old SST pages and the old node data page for GC.

> Upward compaction may cascade: if an L(k+1) node also reaches its SST threshold after receiving new pages, compaction at `(k+1, Q)` is queued for the next available compaction slot.

### 6.2 Downward Merge

**Trigger:** the total live entries across all SST pages at node `(k+1, Q)` fall below the merge threshold (default 16 entries), and the parent node `(k, P)` — where P is Q with its last 6 bits removed — has remaining SST capacity.

**Procedure:**

1. Read all SST pages referenced by the node data pages for `(k+1, Q)` and `(k, P)`.
2. Merge all entries; for any key present at both levels the L(k+1) entry is authoritative (it reflects a more recent write or compaction).
3. Discard superseded entries; sort survivors by key.
4. Write merged result as fresh Lk SST pages (at most 85 per node).
5. Rewrite the node data page for `(k, P)` with the new SST slot IDs and recomputed combinadic fingerprints; update the B+-tree entry `(k, P)` (CoW).
6. **Delete** the B+-tree entry for `(k+1, Q)` (CoW); release the node data page for `(k+1, Q)` and all its old SST pages for GC.

> Downward merges may cascade: if the updated `(k, P)` node is itself now sparse, a downward merge from k → k−1 is queued for the next available slot.

### 6.3 Opportunistic Merge

When the read path loads several SST pages for the same prefix node, the I/O cost is already paid. Rather than discarding those pages, the engine queues the node for a lightweight within-node merge while the pages remain warm in cache.

**Trigger:** at the end of §5.1 step 10, any node `(k, P)` for which ≥ T_opp SST pages were loaded is added to the per-shard merge-candidate queue, ordered by loaded-page count descending.

**Execution** (during the inter-block idle window, consuming the shared compaction budget):

1. For each candidate `(k, P)` in queue order: verify the loaded SST pages are still current (no CoW replacement since the read); if stale, re-read them.
2. Merge all loaded entries, retaining only the most-recent value for each key; discard superseded entries.
3. Sort the surviving entries by key.
4. Write the result as the minimum number of fresh Lk SST pages (⌈surviving / 64⌉ pages).
5. Rewrite the node data page for `(k, P)` with the new SST slot IDs and recomputed combinadic fingerprints; update the B+-tree entry (CoW).
6. Release the replaced SST pages for GC.

**Scope:** opportunistic merge is strictly within-node — it never promotes entries to a deeper prefix level. If the SST count after merging still meets the upward-split trigger, §6.1 is queued normally.

All three compaction paths draw from the same per-block compaction budget (§8.2).

---

## 7. Data Structures and Algorithms

### 7.1 Combinadic Encoding

Each node data page (§4.3.2) stores one compact fingerprint per SST page it references. The fingerprint encodes the sorted multiset of 10-bit key prefixes of the SST's 64 entries, enabling a membership check before issuing a heap read.

**Setup:** 10-bit prefixes range over `{0, …, 1023}`, plus a null sentinel, giving a universe of 1,025 values. With repetitions permitted and entries sorted, the number of distinct multisets of size 64 is:

```
C(1025 + 64 − 1, 64) = C(1088, 64)
```

**Encoding:** Using the combinatorial number system, a sorted multiset `(a₁ ≤ a₂ ≤ … ≤ a₆₄)` maps to the integer:

```
Encode = Σᵢ₌₁⁶⁴  C(aᵢ + i − 1, i)
```

This requires 44 bytes (six `uint64` limbs) to represent values up to `C(1088, 64)`.

**Decoding:** Recover `aᵢ` values in reverse order via an adjusted binary search biased toward the high end: find the largest `aᵢ` such that `C(aᵢ + i − 1, i) ≤ remaining`, subtract, and repeat for `i − 1`.

**LUT acceleration:** All binomial coefficients `C(n, k)` for `n ≤ 1088`, `k ≤ 64` are precomputed into a lookup table of `1,088 × 64` six-limb values (< 32 MiB). Each `C(n, k)` evaluation becomes a single cache-friendly table lookup, replacing 12 multiplications and a division.

**Usage in lookups:** After loading a node data page (§5.1 step 6), compute K's 10-bit prefix, decode each SST's fingerprint, and include that SST's `payload_slot_id` in the parallel read batch only if the prefix appears in the decoded multiset. This compact lossy filter avoids unnecessary SST page reads without a separate filter structure.

---

## 8. Parametrisation

### 8.1 Scale Targets

Ethereum mainnet currently has approximately `2^32` storage slots. With a target load-test scale of `2^36` slots and 64 bytes per entry, with a commitment fanout of `f = 2^6`:

```
Total data ≈ 2^36 × (64/63) × 64 B  ≈  4.4 TB
```

### 8.2 Parameters

| Parameter | Symbol | Typical value | Description |
|-----------|--------|---------------|-------------|
| Commitment stride | `D` | 6 | Trie depth interval between persisted commitment nodes; `D = 6` fits 64 child commitments in one 4 KiB page and matches the routing stride. |
| Shard bits | `S` | 8 | Number of key prefix bits used for filesystem-level sharding; yields `2^S` independent shard directories. |
| SSTs per node | `N` | 85 | Maximum SST pages per node data page; `8 + 48 × N ≤ 4096` → N = 85. |
| B+-tree entries per node | — | 453 | `(depth : u8, prefix_data : u32, page_id : u32)` = 9 B; floor((4096 − 12) / 9) = 453. |
| B+-tree height | — | 3 | log₄₅₃(2²²) ≈ 2.5 → 3 levels; stable from 2^32 to 2^36 keys. |
| B+-tree pinned RAM | — | ≈ 22 MiB | Root + L2 internal pages across all shards; permanently resident after startup. |
| Upward compaction trigger | — | 64 pages | SST count at a node that initiates upward split compaction. |
| Downward merge threshold | — | 16 entries | Total live entries below which a node is merged back into its parent. |
| Opportunistic merge threshold | `T_opp` | 4 pages | Minimum SST pages loaded for the same prefix node in a single read to queue an opportunistic merge (§6.3). |
| Compaction budget | — | TBD | Maximum SST pages processed per block to bound worst-case block-processing latency. |
| GC live-ratio threshold | — | 0.3 | Segments below this live-page fraction are scheduled for GC. Over-provisioning ensures candidates always exist. |
| Combinadic LUT size | — | < 32 MiB | Precomputed binomial coefficient table for `n ≤ 1088`, `k ≤ 64`; six `uint64` limbs per entry. |
| Segment size | — | 4 MiB | 1,024 pages per segment; unit of GC allocation and liveness tracking. |
| Container size | — | 4 GiB | 1,024 segments per container file, addressed by `(container_id, segment_offset)`. |
| Memory budget | `M` | TBD | Approximate upper bound on storage-engine RAM across the L0 buffer, B+-tree pages, node data page cache, payload page cache, and LUT. |
