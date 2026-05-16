# PrefixDB — Technical Specification

- **Version:** 0.1 (Draft)
- **Date:** 2026-05-16
- **Status:** Work in Progress

---

## 1. Overview

PrefixDB is an authenticated key-value storage engine for Ethereum world state that synthesises the layered write-buffering of VerkleTrieDB (v1) with the compact routing index of QuotientDB (v2). Its distinguishing property is that compaction is *prefix-local*: instead of sorting and merging globally, the engine partitions the key space by 6-bit prefix strides at each level, confining compaction work to the pages that share a common prefix. This bounds write amplification to a small neighbourhood of the modified subtree and eliminates compaction-driven interference across unrelated key ranges.

Key properties:

- Pages of 64 KV-pairs (4 KiB) are the atomic unit of disk I/O — writes are buffered in-memory and flushed as full pages.
- A Patricia-trie routing index with Copy-on-Write (CoW) updates occupies roughly 2 % of the total payload, fitting largely in RAM.
- A prefix-partitioned multi-level store: level Lk holds pages whose entries share a common `6l`-bit key prefix, `l >= k`.
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

Storage is organised into levels L0 through LN. Level Lk holds pages whose entries share a common key prefix `6l` bits.

**L0 (in-memory buffer):**
- New writes are appended to a sorted in-memory buffer and simultaneously journalled to a per-shard WAL for crash recovery.
- When the buffer accumulates ≥ 64 entries sharing a common 6l-bit prefix, compaction to L1 could be triggered for that prefix group.
- Superseded values for duplicate keys are discarded at compaction time.

**L1:**
- Holds pages of 64 internally sorted entries, grouped by their first 6l bits of key prefix.
- Each routing-index node references at most N payload pages (N ≤ 84; see §4.3).
- When a prefix group reaches its page capacity, compaction to L2 is triggered: all pages for the group are merged, entries sharing a common 6(l+m)-bit prefix are sorted and flushed as L2 pages, and the remainder is reorganised into fresh L1 pages.

**Lk (general):**
- Pages at level Lk hold entries sharing a common `6m`-bit prefix.
- On compaction, entries sharing a `6(m+n)`-bit prefix are promoted to L(k+1); the rest are reorganised into new Lk pages.
- Stale values for overwritten keys are discarded at each compaction.

**Compaction trigger:** An index node initiates compaction of level Lk when its referenced page count reaches a configurable threshold (e.g., 64 pages per node).

> **Note on latency:** Because compaction is prefix-local, it seldom propagates across the full key space simultaneously. A per-block compaction budget can further bound worst-case processing time.

### 4.3 Routing Index

Rather than probabilistic filters, the engine maintains a **Patricia-trie routing index** with Copy-on-Write semantics. The index has a branching factor of 64 (one branch per 6-bit key symbol, matching the commitment stride), maps key prefixes to heap-page locations, and is the primary structure consulted on every read.

**Index node layout** (for a node holding N payload pages):

| Field | Size | Description |
|-------|------|-------------|
| Prefix extension | 31 B | Compressed shared key prefix (Patricia optimisation) |
| Children slot ID | 4 B | Heap address of the child index nodes |
| Commitment slot ID | 4 B | Heap address of this node's commitment page |
| Payload slot IDs | 4 × N B | Heap addresses of the N payload KV pages |
| Key fingerprints | 44 × N B | Combinadic-encoded 10-bit key prefixes for all 64 entries in each page (see §7.1) |
| Sorted page count | 1 B | Number of globally sorted pages at this node |

**Total size:** `40 + 48 × N` bytes → aligned to `48 × (N + 1)` bytes → fits in a single 4 KiB page with **N = 84**.

The index can occupy approximately 2 % of the total payload, allowing it to fit largely or entirely in RAM for the `2^32`-key regime. At `2^36` keys, selective caching of hot index nodes is required.

**CoW updates:** On any structural change, a new copy of the affected node (and its ancestors up to the root) is written to the heap; the old version is released for GC reclamation. This keeps index writes atomic and crash-safe without locking.

**Caching priority:** Index nodes are assigned the highest cache priority, as they are accessed before any payload or commitment page on every read path.

### 4.4 Heap

All persistent pages — index nodes, KV payload, and commitment pages — are stored in a unified **page heap** with the following addressing scheme:

- **Page size:** 4 KiB.
- **Addressing:** 4-byte page identifiers → up to `2^32` pages → up to 16 TiB total addressable space.
- **Segment:** 1,024 contiguous pages = 4 MiB. The unit of allocation and GC.
- **Container:** 1,024 segments = 4 GiB. Stored as a single file, addressed by `(container_id, segment_offset)`.
- **Liveness bitmap:** One bit per page per segment (128 bytes), kept in memory and persisted to a sidecar file for GC use.

The three logical stores (index, KV payload, commitments) may be assigned separate containers with independent GC parameters and cache budgets.

### 4.5 Cache

- L0 is always fully resident in memory.
- Higher levels are paged in on demand; each heap can be assigned its own LRU cache size and eviction policy.
- Index nodes receive the highest eviction priority — they are smaller than payload pages and provide the routing path to all other data.

---

## 5. Operations

### 5.1 Read

**Input:** key `K`

1. Check the L0 in-memory buffer first; if `K` is present, return its value.
2. Traverse the routing index from the root, following `K`'s 6-bit symbols at each Patricia-trie node. At **each node along the path**, inspect the combinadic key fingerprints for its referenced payload pages (§7.1) to identify candidate pages, and issue heap reads for those pages.
3. For each candidate page, perform a linear scan over the 64 entries to locate `K`. On a match, record the value and continue traversal (a deeper node may hold a more recent write).
4. Return the most-recently-written value found, or `null` if no candidate page contained `K`.

### 5.2 Write

**Input:** key `K`, value `V`

1. Append `(K, V)` to the in-memory L0 buffer and write a WAL record.
2. If any 6-bit prefix group in the buffer reaches ≥ 64 entries, trigger compaction for that group (see §6).
3. Update affected routing-index nodes (CoW) for any newly created or moved pages.

### 5.3 Batch Write

A batch write is a sequence of single writes at the store level. At the application layer, a single slot write propagates commitment updates to every ancestor. Batching slot writes and computing commitment updates in a single pass ensures each trie node is touched exactly once, substantially reducing write amplification.

### 5.4 Block Finalisation

The following steps are executed at the end of each block:

1. Compute commitment updates for all affected strided nodes; rewrite their commitment pages.
2. Apply pending compaction within the available per-block compaction budget.
3. Write all new and modified index nodes to the heap (CoW); `fsync`.
4. Truncate the WAL to the current checkpoint.
5. Run the GC pass on segments whose live-page ratio falls below the threshold (see §5.5).

> **Atomicity note:** New pages are always written before old ones are released. All index updates follow CoW. A crash at any point leaves the previous consistent state intact and recoverable via WAL replay.

### 5.5 Garbage Collection

GC reclaims heap pages whose liveness-bitmap bit has been cleared by a CoW index update or a key deletion.

**Trigger:** GC runs in the idle window between block finalisation and the arrival of the next block.

**Execution:**
1. Select segments whose live-page ratio falls below the threshold (e.g., 0.3).
2. For each selected segment: copy live pages to a fresh destination segment, update all routing-index references via CoW, WAL the moves, and `fsync` after each batch.
3. Once a segment is fully evacuated, release its storage to the filesystem.

**Determinism:** GC is paused at block arrival and resumed at block finalisation, so it contributes zero latency variance to block processing.

---

## 6. Compaction

Compaction is triggered per routing-index node and operates on a single prefix group at a time (micro-compaction), keeping I/O and index updates localised.

**Procedure for level Lk at a given prefix node:**

1. Read all payload pages referenced by the node (at most 84 pages, ≤ 336 KiB).
2. Merge all 64-byte entries across pages, retaining only the most-recent value for each key; discard superseded entries.
3. Sort the surviving entries by key.
4. Identify all groups of entries sharing a common `6(k+1)`-bit prefix.
5. For each such group of ≥ 64 entries: write the 64 least-recently-written entries as a new L(k+1) page; update the routing index.
6. Reorganise remaining entries into fresh Lk pages (up to 64 entries per page).
7. Write new pages to the heap; update all routing-index references (CoW); release old pages for GC.
8. Recompute and store the combinadic key fingerprints for all new pages in the routing-index node.

> Compaction at Lk may cascade: if the L(k+1) node also reaches its page capacity after receiving new pages, compaction at L(k+1) is queued for the next available compaction slot.

---

## 7. Data Structures and Algorithms

### 7.1 Combinadic Encoding

Each routing-index node stores a compact fingerprint of the keys held in each of its payload pages. The fingerprint encodes the sorted multiset of 10-bit key prefixes of the page's 64 entries, enabling a membership check before issuing a heap read.

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

**Usage in lookups:** To check whether key `K` may be present in a page, compute K's 10-bit prefix, decode the page's fingerprint, and issue the heap read only if the prefix appears in the decoded multiset. This compact probabilistic membership check replaces a separate per-page filter structure.

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
| Commitment stride | `D` | 6 | Trie depth interval between persisted commitment nodes; `D = 6` fits 64 child commitments in one 4 KiB page and matches the index branching factor. |
| Shard bits | `S` | 8 | Number of key prefix bits used for filesystem-level sharding; yields `2^S` independent shard directories. |
| Pages per index node | `N` | 84 | Maximum payload pages per routing-index node; determined by the 4 KiB node layout constraint (`48 × (N + 1) ≤ 4096`). |
| Compaction trigger | — | 64 pages | Page count at an index node that initiates level compaction. |
| Compaction budget | — | TBD | Maximum pages processed per block to bound worst-case block-processing latency. |
| GC live-ratio threshold | — | 0.3 | Segments below this live-page fraction are scheduled for GC. Over-provisioning ensures candidates always exist. |
| Combinadic LUT size | — | < 32 MiB | Precomputed binomial coefficient table for `n ≤ 1088`, `k ≤ 64`; six `uint64` limbs per entry. |
| Segment size | — | 4 MiB | 1,024 pages per segment; unit of GC allocation and liveness tracking. |
| Container size | — | 4 GiB | 1,024 segments per container file, addressed by `(container_id, segment_offset)`. |
| Memory budget | `M` | TBD | Approximate upper bound on storage-engine RAM across the L0 buffer, routing-index cache, page caches, and LUT. |
