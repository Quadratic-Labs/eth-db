# PrefixDB — Technical Specification

- **Version:** 0.3 (Draft)
- **Date:** 2026-05-20
- **Status:** Work in Progress

---

## 1. Overview

PrefixDB is an authenticated key-value storage engine for Ethereum world state that synthesises the layered write-buffering of VerkleTrieDB (v1) with the compact routing index of QuotientDB (v2).
Its distinguishing property is that compaction is *prefix-local*: instead of sorting and merging globally, the engine partitions the key space by 6-bit prefix strides at each level, confining compaction work to the pages that share a common prefix.
This bounds write amplification to a small neighbourhood of the modified subtree and eliminates compaction-driven interference across unrelated key ranges.

Key properties:

- Pages of 64 KV-pairs (4 KiB) are the atomic unit of disk I/O — writes are buffered in-memory and flushed as full pages.
- A **depth-indexed routing table** — one in-memory hash map per depth level mapping `prefix_data` to node page address, WAL-backed for crash recovery — resolves all routing with zero disk I/O.
- A prefix-partitioned multi-level store: level Lk holds pages whose entries share at least a common `6k`-bit key prefix.
- Commitments are co-located 64 siblings per page and rewritten at most once per block per affected node.
- A chi-square skew detector (§7.2) analyses the combinadic fingerprints to drive **preemptive compaction** (§6.4): sub-prefixes accumulating keys non-uniformly are promoted to the next level before the SST count threshold is reached.

---

## 2. Data Model

### 2.0 Storage

As usual, the data can be stored either in-memory or on disk:

- In-memory: space ~32GiB, latency of ~10-50 nanoseconds.
- SSD: space ~1TiB, latency of ~10-50 microseconds.

Read and write operations on disk have the following specificities:

- Read/write must operate on a page, usually 4KiB each.
- Deletes must operate on a block, usually 64 pages.

SSDs use a File Translation Layer (FTL) to abstract away this semantics from the user.
However, it means that pages cannot be updated once written.
This makes copy-on-write (CoW) or immutable data-structures such as LSM more useful for SSD disks.

### 2.1 Key-Value pairs

A storage slot is a pair `(K, V)` where both `K` (the key) and `V` (the value) are 32-byte quantities.
The store is therefore a mapping:

```
K : Bytes[32]  →  V : Bytes[32]
```

The data received is a stream of the usual (unordered) operations on a mapping:

- read: given a key `K`, return the value `V`.
- write: given a key `K` and a value `V`, insert or update the stored value for that key.
- delete: given a key `K`, remove the key from the storage.

### 2.2 State Commitment

In addition to the raw slot mapping, the store maintains a cryptographic commitment to the full mapping — the **state root**.
The commitment is structured as a large sparse binary prefix tree (trie):

- Each node represents a key prefix and has exactly two children, corresponding to the 0-bit and 1-bit extensions of that prefix.
- A node's commitment is the hash of its two children's commitments, producing a 32-byte digest.
- Leaf nodes hold the slot value directly.

> **Reference:** See the relevant EIP for the precise definition of Stem Nodes and other protocol-level subtleties. They do not materially affect the storage design described here.

Commitments are computed per block of currently about 2000-10000 operations.
The blocks are synchronised: there is an approximate time window during which blocks arrive and are processed.
Currently, this is about every 12 seconds.
When scaling, these numbers can vary: number of operations should increase and/or time-window decrease.

This adds a new operation:

- get-state-root: given a block ID `B`, return its state root (commitment) `C`.

#### Commitment Caching

The state root is a commitment over the full mapping, thus changes when a single key-value pair changes.
Naively, this would require to recompute the whole commitment tree at every commit, i.e. at every block.
This is impratical, and we must implement intermediate commitments caching.
It creates write and space amplification, but makes commit trackable.

Rather than caching every intermediate node, the store caches commitment nodes only at depths that are multiples of a fixed stride `D`.
This bounds the recomputation cost to at most `D` levels when a cached node is invalidated.
With `D = 6`, each node holds exactly 64 sibling commitments (2,048 B), co-located with the node's SST index in a single 2-page allocation (§4.2.2).

Commitments near the root are updated very frequently but are cheaply recomputable from children cached commitments.
They are kept **in memory only** and are not persisted to disk.
Commitments are addressed by block ID and therefore need to be updated on a block batched write basis only.

### 2.3 Forks and Snapshots

Blocks get an ID + a position (auto-incrementing counter).
TODO: complete this section, how do we handle MVCC ?
Normally, cache is big enough to easily accomodate for the most recent blocks, which could solely handle MVCC in memory.
What about trie-logs ?
...

---

## 3. State of the Art

There exists a trichotomy for database engines where there is inherent tension between the ressources making it impossible to achieve optimisation for all three simultaneously.
So database engineering tries to achieve good balance between ressource amplification: space, read, write.

Specifically for key-value pairs, the tension can be materialised as follows:

- Write: logs are the optimal way of recording streams, but then the keys are unstructured leading to read amplification (search).
- Read: the optimal read is when all keys are structured, either through an indexe or through sorting, but the structure must be maintained, leading to write and/or space amplification.
- Space: the optimal space utilisation is when there is no duplication and no extra data is written, but this is impossible due to SSD paging.

Various solutions exist giving different balance of ressources utilisation.

### 3.1 Log Structured Merge Trees (LSM-tree)

The core insight of an LSM-tree is to convert random writes into sequential ones.
SSD random writes are expensive both in latency and wear; sequential append-only writes are cheap.
The trade-off is that reads become more expensive, since a key may exist in multiple locations.

**Write path.** Incoming writes are absorbed by an in-memory sorted buffer (memtable).
When the memtable reaches a size threshold, it is flushed as an immutable sorted file — a Sorted String Table (SST) — appended to the lowest on-disk level L1.
No existing page is ever modified; all writes are appends.

**Compaction.** SSTs accumulate at each level.
When a level exceeds its size budget, a background compaction merges a set of SSTs from that level with the overlapping SSTs at the next level, producing a fresh sorted output.
Only the most-recent value for each key survives the merge; superseded entries and deletions (recorded as tombstones) are discarded.
Compaction is the mechanism that reclaims space and keeps the number of SSTs — and therefore read amplification — bounded.

**Read path.** A read must consult the memtable and then potentially every SST level, newest first, until the key is found or all levels are exhausted.
Per-SST Bloom filters reduce this to a small number of actual disk reads in the common case.

**Amplification profile.** Writes are nearly optimal: one sequential append per flush, plus amortised compaction cost.
Reads pay for the multi-level search.
Space is amplified by temporary duplication of entries during compaction and by obsolete entries that have not yet been compacted away.

### 3.2 B+-Tree with Copy-on-Write (LMDB / MDBX)

A B+-tree keeps all keys sorted across a balanced tree of fixed-size pages, giving O(log N) reads with at most one page read per tree level.
The challenge on SSDs is that an in-place update to a leaf requires rewriting that page, and because the parent now holds a stale pointer, it too must be rewritten — cascading up to the root.
This is the CoW path-copy pattern.

**Write path.** On a write, the engine copies the modified leaf to a new page, then copies each ancestor page up to the root, updating child pointers as it goes.
The new root pointer is swapped atomically as the final step.
The old pages are not freed immediately; they remain valid until no active reader references them.
At tree height h, one write costs exactly h page writes — O(log N) write amplification, independent of data size.

**Crash safety without a WAL.** Because pages are never modified in place and the root swap is atomic, a crash at any point leaves either the old or the new root intact.
No write-ahead log is needed; the last committed root is always a consistent snapshot.

**Concurrency via MVCC.** Each transaction pins the root pointer at its start and reads a consistent snapshot without locking.
A single writer proceeds concurrently with any number of readers; neither blocks the other.
MDBX extends LMDB here with more aggressive page recycling and a sub-page mechanism for small values.

**Memory-mapped I/O.** Both LMDB and MDBX expose the database file directly through `mmap`.
Reads become simple pointer dereferences into the OS page cache — no userspace copy, no syscall overhead per read.
However, mmap transfers buffer management to the OS, which has no knowledge of the engine's access patterns.
When a required page has been evicted, the accessing thread stalls on a kernel page fault with no opportunity to yield or overlap I/O; the engine cannot schedule around it.
Under write pressure, OS eviction of dirty pages triggers TLB shootdowns — inter-processor interrupts to invalidate TLB entries on every core — which become a measurable bottleneck.
The OS also controls dirty-page writeback order, complicating crash-consistency guarantees.
These issues are tolerable for LMDB/MDBX because they target read-heavy workloads with datasets that fit in RAM; for write-intensive or memory-pressured engines a managed buffer pool is the standard remedy.

**Amplification profile.** Reads are optimal: one page read per level, with upper levels typically hot in cache.
Writes pay O(log N) pages per operation.
Space overhead comes from dead pages accumulating until GC recycles them; under heavy write workloads this can be significant.

### 3.3 PrefixDB

PrefixDB is an LSM-variant that replaces global key-range compaction with prefix-partitioned compaction, and replaces serial trie traversal with a zero-I/O in-memory routing table.
The two prior designs each leave a specific gap that PrefixDB targets.

**Where LSM falls short.**
In a standard LSM, compaction merges SSTs across the entire key space.
A write to any key can eventually trigger a merge that rewrites unrelated key ranges, causing cross-range I/O interference and unpredictable latency spikes.
PrefixDB confines every compaction to a single prefix node: only the pages sharing a common key prefix are read, merged, and rewritten.
Write amplification is bounded to the neighbourhood of the modified subtree, and compaction at one prefix never touches another.

**Where B+-tree CoW falls short.**
A CoW B+-tree pays O(log N) page writes per update (path copy to root), and each read follows a serial pointer chain from root to leaf.
PrefixDB amortises write cost by absorbing writes into an in-memory L0 buffer and flushing full pages in batches.
Reads avoid serial traversal entirely: the routing table is an in-memory hash map at every depth level, so all routing lookups are pure RAM operations after startup, and node pages across every prefix level can be fetched in a single parallel batch.

**PrefixDB's wins in summary:**

| Property | LSM | B+-tree CoW | PrefixDB |
|---|---|---|---|
| Write amplification | Low (amortised) | O(log N) per write | Low (amortised, prefix-local) |
| Compaction scope | Global key range | N/A | Per-prefix node only |
| Read I/O rounds | Sequential per level | 4–5 serial at scale | 2 parallel rounds |
| Worst-case latency | Compaction stalls | Predictable | Bounded by per-block budget |
| Skew handling | None | None | Preemptive via chi-square (§6.4) |

**Downsides.**
A key may exist in SST pages at multiple prefix levels simultaneously; a read must find the most-recent value across all of them (§5.1 step 7).
This is inherent to any LSM-derived design and is mitigated by the combinadic filter, but it means reads are never as simple as a single authoritative lookup.

Uncompacted prefix nodes accumulate SST pages up to the compaction threshold (default 64).
A read on a cold prefix — one that receives writes but not enough to trigger compaction — may need to consult many SST pages.
The combinadic filter is near-optimal in space for this purpose, allowing more node pages to fit in RAM, and it is a pluggable component if a better filter is identified; but it does not eliminate false positives entirely.

The per-block compaction budget (§8.2) bounds worst-case latency but introduces a tuning dependency: if the budget is set too low, compaction debt accumulates across blocks and eventually drives up read amplification until a larger compaction pass clears it.

Finally, the engine is substantially more complex than either a plain LSM or LMDB — four compaction paths, a depth-indexed routing table, combinadic encoding, and a chi-square skew detector — which increases the implementation and testing surface considerably.

---
## 4. Storage Architecture

### 4.1 Layered Storage

Storage is organised into levels L0 through LN. Level Lk holds pages whose entries share a common key prefix of `6k` bits.

**L0 (in-memory buffer):**
- New writes are appended to a sorted in-memory buffer and simultaneously journalled to a WAL for crash recovery.
- When the buffer accumulates ≥ 64 entries sharing a common 6-bit prefix, compaction to L1 can be triggered for that prefix group.
- Superseded values for duplicate keys are discarded at compaction time.

**L1:**
- Holds pages of 64 internally sorted entries, grouped by their first 6 bits of key prefix.
- Each routing-index node references at most N payload pages (N ≤ 95; see §4.2.2).
- When a prefix group reaches its page capacity, compaction to L2 is triggered: all pages for the group are merged, entries sharing a common 12-bit prefix are sorted and flushed as L2 pages, and the remainder is reorganised into fresh L1 pages.

**Lk (general):**
- Pages at level Lk hold entries sharing a common `6k`-bit prefix.
- On compaction, entries sharing a `6(k+1)`-bit prefix are promoted to L(k+1); the rest are reorganised into new Lk pages.
- Stale values for overwritten keys are discarded at each compaction.

**Compaction trigger:** A routing-index node initiates compaction when its SST page count reaches a configurable threshold (e.g., 64 pages per node).

> **Note on latency:** Because compaction is prefix-local, it seldom propagates across the full key space simultaneously. A per-block compaction budget can further bound worst-case processing time.

### 4.2 Routing Index

The routing index maps every non-empty trie node `(depth, prefix_data)` to the heap address of its node page.
It is realised as one **open-addressing hash map per depth level**, kept entirely in RAM and backed by a WAL and periodic snapshots for crash recovery.
Since all routing lookups are point queries on a known prefix — not searches — no tree structure is needed; direct hash addressing suffices at every depth.

#### 4.2.1 Routing Hash Maps

```
RoutingMap[k] : prefix_data (u32) → node_page_id (u32)
```

**Prefix encoding:**

```
prefix_data(K, d) = (K as u256) >> (256 − 6d),  as big-endian u32
```

`prefix_data` encodes the first `6 × depth` bits of the full key, left-aligned into 32 bits and zero-padded on the right. This fits a u32 for depths 1–5 (up to 30 bits); depth 6+ requires a u64.

**Entry layout:** `(prefix_data : u32, node_page_id : u32)` — 8 bytes. Depth is implicit from which map is consulted.

**Memory usage at scale:**

| Depth | Max possible nodes | Settling depth for | RAM at full occupancy |
|-------|--------------------|--------------------|----------------------|
| 1 | 64 | — | < 1 KiB |
| 2 | 4,096 | — | 32 KiB |
| 3 | 262,144 | — | 2 MiB |
| 4 | 16,777,216 | 2^32 keys | 134 MiB |
| 5 | 1,073,741,824 | 2^36 keys | 8 GiB |
| **Total (depths 1–5)** | | | **≈ 8.1 GiB** |

A depth-k node is the natural settling depth when the average key count per node, `2^N_keys / 2^(6k)`, falls in the range `[1, 64 × compaction_threshold]` — i.e., where compaction no longer drives keys deeper. At the target scale of 2^36 keys, the full routing table for depths 1–5 fits within the **32 GiB RAM budget**. Depths 1–4 (≤ 134 MiB combined) always fit regardless of scale.

**Persistence — WAL:** every routing table mutation appends one record to the routing WAL:

| Operation | Record layout | Size |
|-----------|--------------|------|
| Insert / Update | `(op : u8, depth : u8, prefix_data : u32, page_id : u32)` | 10 B |
| Delete | `(op : u8, depth : u8, prefix_data : u32)` | 6 B |

The routing WAL is flushed and `fsync`'d at every block finalisation (§5.4).

**Persistence — Snapshot:** when the routing WAL exceeds a size threshold (or every N blocks), each depth-k map is serialised as a **flat sorted file** — a contiguous array of `(prefix_data : u32, node_page_id : u32)` pairs in ascending `prefix_data` order. On recovery: load the most recent snapshot for each depth, then replay the WAL tail. The snapshot file is also the canonical disk representation for overflowed depth levels.

**Disk overflow:** for scales where a depth-k map exceeds the available RAM (depth 5 at 2^36 keys approaches 8 GiB; depth 5 at 2^32 keys is sparse and much smaller), the overflowed map stays on disk as its snapshot file. Lookups use binary search O(log n) on the sorted file, or a hash-indexed wrapper for O(1). WAL records for overflowed depths are replayed into disk in the next snapshot cycle. Depths 1–4 are always fully resident.

**Updates:** a routing table change is a single hash map operation plus one WAL append — O(1), with no path-copy overhead.

#### 4.2.2 Node Pages

Each routing table entry `prefix_data → node_page_id` points to a **2-page (8 KiB) node page** on the heap. This allocation co-locates the node's child commitment hashes with its SST index, making commitment and index updates a single atomic CoW operation and eliminating a separate heap object per node.

| Field | Size | Description |
|-------|------|-------------|
| `N` (SST count) | 1 B | Number of SST pages currently at this node |
| `sorted_page_count` | 1 B | Number of globally sorted SST pages |
| `_pad` | 2 B | |
| `child_commitments[64]` | 2,048 B | 64 × 32 B commitment hashes for the 64 child nodes at depth k+1 |
| `payload_slot_ids` | 4 × N B | Heap addresses of the N SST pages |
| `key_fingerprints` | 60 × N B | Combinadic-encoded 12-bit key fingerprints (§7.1), one per SST page |

**Total size:** `4 + 2,048 + 64 × N` bytes → maximum **N = 95** SST pages per node (`floor((8,192 − 2,052) / 64) = 95`).

The node page is rewritten under CoW whenever SSTs are added, removed, or reordered, or when any child commitment changes.
The routing table entry pointing to it is updated in the same operation.
Because commitment data and SST index share the same physical allocation, a block that touches both requires only one CoW write per affected node rather than two.

**Compaction trigger:** a node initiates upward compaction when its SST count N reaches the configurable threshold (default 64 pages).

### 4.3 Heap

All persistent pages — **node pages (2-page allocations), KV payload pages** — are stored in a unified **page heap** with the following addressing scheme:

- **Page size:** 4 KiB.
- **Addressing:** 4-byte page identifiers → up to `2^32` pages → up to 16 TiB total addressable space.
- **Segment:** 1,024 contiguous pages = 4 MiB. The unit of allocation and GC.
- **Container:** 1,024 segments = 4 GiB. Stored as a single file, addressed by `(container_id, segment_offset)`.
- **Liveness bitmap:** One bit per page per segment (128 bytes), kept in memory and persisted to a sidecar file for GC use.

The routing table itself is in-memory; only the node pages it points to are heap-resident. Node pages carry both SST index data and child commitment hashes in one contiguous 8 KiB allocation; there are no separate commitment pages. The two logical stores (KV payload, and node pages) may be assigned separate containers with independent GC parameters and cache budgets.

### 4.4 Cache

- L0 is always fully resident in memory.
- The routing table (all depth-level hash maps) is always fully resident in memory; no eviction or caching logic is required for routing.
- Higher levels are paged in on demand; each heap container can be assigned its own LRU cache size and eviction policy.
- Node data pages and KV payload pages compete for the LRU budget.

---

## 5. Operations

### 5.1 Read

**Input:** key `K`

1. Check the L0 in-memory buffer; if `K` is present, return its value.
2. For each d ∈ {1, 2, 3, 4, 5}: compute `prefix_data(K, d)` (§4.2.1). (Deeper levels exist only if the key space has been partitioned that far by compaction.)
3. For each d: look up `RoutingMap[d][prefix_data(K, d)]` — a pure in-memory hash table operation requiring no disk I/O. Collect the `node_page_ids` for all depths where an entry exists.
4. **Issue all node page reads as a single parallel batch** — one read per depth level that returned an entry in step 3.
5. For each node page received: compute K's relative 12-bit prefix `f = K[6k : 6k+12]` for that depth k, apply the combinadic key fingerprints (§7.1) to identify which of its SST pages may contain `K`, and collect their `payload_slot_ids`.
6. **Issue all candidate SST page reads as a single parallel batch.**
7. For each candidate SST page, perform a linear scan over the 64 entries to locate `K`; record any match found.
8. Return the most-recently-written value found across all depth levels, or `null` if no candidate page contained `K`.
9. For any prefix node `(k, P)` from which ≥ T_opp SST pages were loaded in step 6, add `(k, P)` to the merge-candidate queue (§6.3). The pages are already in the page cache, so no extra I/O is incurred.

The critical I/O path after warm-up is **two parallel rounds**: node pages → SST pages.

### 5.2 Write

**Input:** key `K`, value `V`

1. Append `(K, V)` to the in-memory L0 buffer and write a KV WAL record.
2. If any 6-bit prefix group in the buffer reaches ≥ 64 entries, trigger compaction for that group (see §6).
3. For every SST page created or relocated by compaction: write a new node page to the heap (CoW); update `RoutingMap[k][prefix_data] ← new_page_id` and append a routing WAL record.

### 5.3 Batch Write

A batch write is a sequence of single writes at the store level. At the application layer, a single slot write propagates commitment updates to every ancestor. Batching slot writes and computing commitment updates in a single pass ensures each trie node is touched exactly once, substantially reducing write amplification.

### 5.4 Block Finalisation

The following steps are executed at the end of each block:

1. Compute commitment updates for all affected strided nodes; rewrite their node pages (CoW).
2. Apply pending compaction within the available per-block compaction budget.
3. Write all new and modified node pages to the heap (CoW); `fsync` heap.
4. Flush routing WAL to disk; `fsync` routing WAL. If the WAL exceeds the snapshot size threshold, write a fresh snapshot for each modified depth-level map and truncate the WAL.
5. Truncate the KV WAL to the current checkpoint.
6. Run the GC pass on segments whose live-page ratio falls below the threshold (see §5.5).

> **Atomicity note:** New heap pages are always written before old ones are released. The routing WAL is flushed after the heap `fsync`, so a crash between the two leaves the heap consistent and the WAL tail covers any routing updates not yet reflected in a snapshot. Recovery replays the WAL tail against the last snapshot.

### 5.5 Garbage Collection

GC reclaims heap pages whose liveness-bitmap bit has been cleared by a CoW update or a key deletion.

**Trigger:** GC runs in the idle window between block finalisation and the arrival of the next block.

**Execution:**
1. Select segments whose live-page ratio falls below the threshold (e.g., 0.3).
2. For each selected segment: copy live pages to a fresh destination segment; for each moved node page update `RoutingMap[k][prefix_data] ← new_page_id` and append a routing WAL record; `fsync` after each batch.
3. Once a segment is fully evacuated, release its storage to the filesystem.

**Determinism:** GC is paused at block arrival and resumed at block finalisation, so it contributes zero latency variance to block processing.

---

## 6. Compaction

Compaction operates on a single prefix node at a time (micro-compaction), keeping I/O and routing-index updates localised. It runs in two directions: **upward split** when a node accumulates too many SST pages, and **downward merge** when a node becomes too sparse after deletions. A third path — **opportunistic merge** — exploits I/O already paid by reads. A fourth path — **preemptive compaction** — acts proactively on chi-square skew signals before thresholds are reached. All routing-index changes in all four paths are made by updating `RoutingMap[k]` (§4.2.1) and appending a WAL record — a single O(1) operation per changed routing entry, with no path-copy overhead.

### 6.1 Upward Split

**Trigger:** the SST count at node `(k, P)` reaches the compaction threshold (default 64 pages).

**Procedure:**

1. Read all SST pages referenced by the node page for `(k, P)` (at most 85 pages, ≤ 340 KiB).
2. Merge all 64-byte entries across pages, retaining only the most-recent value for each key; discard superseded entries.
3. Sort the surviving entries by key.
4. Identify all groups of entries sharing a common `6(k+1)`-bit prefix.
5. For each such group of ≥ 64 entries: write the 64 least-recently-written entries as a new L(k+1) SST page; create or update the node page for `(k+1, Q)` (where Q is the extended prefix); set `RoutingMap[k+1][Q] ← new_node_page_id` and append a routing WAL record.
6. Reorganise remaining entries into fresh Lk SST pages (up to 64 entries per page).
7. Rewrite the node page for `(k, P)` with the new SST slot IDs and recomputed combinadic fingerprints; set `RoutingMap[k][P] ← new_node_page_id` and append a routing WAL record; release all old SST pages and the old node page for GC.

> Upward compaction may cascade: if an L(k+1) node also reaches its SST threshold after receiving new pages, compaction at `(k+1, Q)` is queued for the next available compaction slot.

### 6.2 Downward Merge

**Trigger:** the total live entries across all SST pages at node `(k+1, Q)` fall below the merge threshold (default 16 entries), and the parent node `(k, P)` — where P is Q with its last 6 bits removed — has remaining SST capacity.

**Procedure:**

1. Read all SST pages referenced by the node pages for `(k+1, Q)` and `(k, P)`.
2. Merge all entries; for any key present at both levels the L(k+1) entry is authoritative (it reflects a more recent write or compaction).
3. Discard superseded entries; sort survivors by key.
4. Write merged result as fresh Lk SST pages (at most 85 per node).
5. Rewrite the node page for `(k, P)` with the new SST slot IDs and recomputed combinadic fingerprints; set `RoutingMap[k][P] ← new_node_page_id` and append a routing WAL record.
6. **Delete** `RoutingMap[k+1][Q]` and append a delete routing WAL record; release the node page for `(k+1, Q)` and all its old SST pages for GC.

> Downward merges may cascade: if the updated `(k, P)` node is itself now sparse, a downward merge from k → k−1 is queued for the next available slot.

### 6.3 Opportunistic Merge

When the read path loads several SST pages for the same prefix node, the I/O cost is already paid. Rather than discarding those pages, the engine queues the node for a lightweight within-node merge while the pages remain warm in cache.

**Trigger:** at the end of §5.1 step 9, any node `(k, P)` for which ≥ T_opp SST pages were loaded is added to the merge-candidate queue, ordered by loaded-page count descending.

**Execution** (during the inter-block idle window, consuming the shared compaction budget):

1. For each candidate `(k, P)` in queue order: verify the loaded SST pages are still current (no CoW replacement since the read); if stale, re-read them.
2. Merge all loaded entries, retaining only the most-recent value for each key; discard superseded entries.
3. Sort the surviving entries by key.
4. Write the result as the minimum number of fresh Lk SST pages (⌈surviving / 64⌉ pages).
5. Rewrite the node page for `(k, P)` with the new SST slot IDs and recomputed combinadic fingerprints; set `RoutingMap[k][P] ← new_node_page_id` and append a routing WAL record.
6. Release the replaced SST pages for GC.

**Scope:** opportunistic merge is strictly within-node — it never promotes entries to a deeper prefix level. If the SST count after merging still meets the upward-split trigger, §6.1 is queued normally.

### 6.4 Preemptive Compaction

The combinadic fingerprints stored in node pages (§4.2.2) encode the full distribution of relative key prefixes at a node without requiring SST page reads. By running a chi-square goodness-of-fit test (§7.2) against the uniform distribution, the engine detects sub-prefix ranges accumulating keys at above-average rates and promotes them to the next level *before* the SST count threshold is reached, smoothing write amplification spikes and preventing hot-spot formation.

**Trigger:** after any compaction event at node `(k, P)` (§6.1, §6.2, or §6.3) — when a fresh node page has just been written and its fingerprints are in hand — compute the chi-square statistic χ² (§7.2) without additional I/O. If χ² > χ²_α(4095) (default α = 0.05, critical value ≈ 4,275), schedule `(k, P)` for preemptive compaction during the next inter-block idle window.

**Execution** (during the inter-block idle window, consuming the shared compaction budget):

1. Decode all N fingerprints at `(k, P)` to build the histogram O[0..4095] of relative 12-bit prefix counts (§7.2).
2. Aggregate into 64 6-bit sub-prefix buckets: for each sub-prefix Q ∈ {0..63}, compute `A[Q] = Σ_{b : b >> 6 = Q} O[b]` — the total entries attributable to child node `(k+1, P||Q)`.
3. Identify dense sub-prefixes: all Q for which `A[Q] ≥ upward_split_threshold × 64 × ρ`, where ρ is the predictive density ratio (default ρ = 0.75).
4. For each dense Q: promote all entries at `(k, P)` with 6-bit sub-prefix Q to child node `(k+1, P||Q)` via the upward-split procedure (§6.1 steps 2–7), restricted to those entries. Insert `RoutingMap[k+1][P||Q] ← new_node_page_id` if it does not yet exist, and append a routing WAL record.
5. Rewrite the node page for `(k, P)` with updated SST slot IDs and recomputed fingerprints; set `RoutingMap[k][P] ← new_node_page_id` and append a routing WAL record.

> If no sub-prefix is dense (A[Q] < threshold × ρ for all Q) even though χ² exceeds the critical value, the skew is spread too finely to target a single child; no action is taken. If the updated `(k, P)` SST count still meets the upward-split trigger after preemptive promotion, §6.1 is queued normally.

All four compaction paths draw from the same per-block compaction budget (§8.2).

---

## 7. Data Structures and Algorithms

### 7.1 Combinadic Encoding

Each node page (§4.2.2) stores one compact fingerprint per SST page it references. The fingerprint encodes the sorted multiset of **relative 12-bit key prefixes** of the SST's 64 entries. For a node at level k, the relative prefix of key K is `K[6k : 6k+12]` — the 12 bits of K immediately following the node's own `6k`-bit prefix. Using the relative prefix rather than the absolute K[0:12] ensures the filter provides meaningful discrimination at every tree level, and enables the chi-square skew analysis (§7.2) to be applied uniformly.

**Membership check:** after loading a node page (§5.1 step 5), compute K's relative 12-bit prefix `f = K[6k : 6k+12]`, decode each SST's fingerprint, and include that SST's `payload_slot_id` in the parallel read batch only if `f` appears in the decoded multiset. With a 12-bit universe (4,096 values) and 64 entries per SST, the false-positive probability is 1 − (1 − 1/4096)^64 ≈ **1.5%** per SST.

**Setup:** relative 12-bit prefixes range over `{0, …, 4095}`, plus a null sentinel, giving a universe of 4,097 values. With repetitions permitted and entries sorted, the number of distinct multisets of size 64 is:

```
C(4097 + 64 − 1, 64) = C(4160, 64)
```

**Encoding:** Using the combinatorial number system, a sorted multiset `(a₁ ≤ a₂ ≤ … ≤ a₆₄)` maps to the integer:

```
Encode = Σᵢ₌₁⁶⁴  C(aᵢ + i − 1, i)
```

This requires 60 bytes (eight `uint64` limbs) to represent values up to `C(4160, 64)`.

**Decoding:** Recover `aᵢ` values in reverse order via an adjusted binary search biased toward the high end: find the largest `aᵢ` such that `C(aᵢ + i − 1, i) ≤ remaining`, subtract, and repeat for `i − 1`.

**LUT acceleration:** All binomial coefficients `C(n, k)` for `n ≤ 4160`, `k ≤ 64` are precomputed into a lookup table of `4,160 × 64` eight-limb values (< 17 MiB). Each `C(n, k)` evaluation becomes a single cache-friendly table lookup, replacing 12 multiplications and a division.

### 7.2 Chi-Square Skew Analysis

Decoding the N combinadic fingerprints at a node `(k, P)` yields, for each SST, 64 relative 12-bit prefix values. Aggregating across all N SSTs produces a histogram O[0..4095], where O[b] is the total count of entries whose relative 12-bit prefix equals b.

**Statistic:**

Under the null hypothesis of a uniform distribution over 4,096 prefix buckets, the expected count per bucket is:

```
E = 64N / 4096 = N / 64
```

The chi-square statistic is:

```
χ² = Σ_{b=0}^{4095} (O[b] − E)² / E
```

with **4,095 degrees of freedom**.

**Threshold:** reject uniformity when χ² > χ²_α(4095). At the default significance level α = 0.05, the critical value is approximately **4,275**.

**Interpretation:** a large χ² means some relative 12-bit prefix values are disproportionately represented. The top 6 bits of each overrepresented value (b >> 6) identify the 6-bit sub-prefix Q at the next level that is accumulating keys faster than average. This signal drives §6.4.

**Computational cost:** decoding N fingerprints costs N × 64 LUT lookups (one per element per SST), each a single cache-line read, plus O(4096) arithmetic for the summation. At N = 64 (the compaction trigger), this is 4,096 LUT lookups — on the order of a few microseconds.

---

## 8. Parametrisation

### 8.1 Scale Targets

Ethereum mainnet currently has approximately `2^32` storage slots.
With a target load-test scale of `2^36` slots and 64 bytes per entry, with a commitment fanout of `f = 2^6`:

```
Total data ≈ 2^36 × (64/63) × 64 B  ≈  4.4 TB
```

**Routing table RAM at scale:**

| Scale | Settling depth | Occupied nodes at settling depth | Routing table RAM (all depths) |
|-------|---------------|----------------------------------|-------------------------------|
| 2^32  | 4             | ≤ 2^24 ≈ 16.8M                  | ≈ 134 MiB                     |
| 2^36  | 5             | ≤ 2^30 ≈ 1.07B                  | ≈ 8.1 GiB                     |

Both fit within a 32 GiB RAM budget. For scales beyond 2^36, depth-5 maps overflow to disk-backed flat sorted files (§4.2.1).

### 8.2 Parameters

| Parameter | Symbol | Typical value | Description |
|-----------|--------|---------------|-------------|
| Commitment stride | `D` | 6 | Trie depth interval between persisted commitment nodes; `D = 6` yields 64 child commitments (2,048 B) co-located in the node page and matches the routing stride. |
| SSTs per node | `N` | 95 | Maximum SST pages per node page; `4 + 2,048 + 64 × N ≤ 8,192` → N = 95. Node pages are 2-page (8 KiB) contiguous allocations co-locating child commitments and SST index. |
| Routing entry size | — | 8 B | `(prefix_data : u32, node_page_id : u32)`; depth is implicit from which map is consulted. |
| Routing table RAM | — | ≈ 134 MiB / 8.1 GiB | Total for depths 1–5 at 2^32 / 2^36 key scale; depths 1–4 always reside in RAM. |
| Routing WAL flush | — | every block | Routing WAL is flushed and `fsync`'d at every block finalisation. |
| Routing snapshot interval | — | configurable | Full snapshot of all depth-level maps written to disk when WAL exceeds size threshold; WAL truncated after successful snapshot. |
| Upward compaction trigger | — | 64 pages | SST count at a node that initiates upward split compaction. |
| Downward merge threshold | — | 16 entries | Total live entries below which a node is merged back into its parent. |
| Opportunistic merge threshold | `T_opp` | 4 pages | Minimum SST pages loaded for the same prefix node in a single read to queue an opportunistic merge (§6.3). |
| Chi-square significance | `α` | 0.05 | Significance level for the skew test in §7.2; χ²₀.₀₅(4095) ≈ 4,275. |
| Predictive density ratio | `ρ` | 0.75 | Fraction of the upward-split capacity at which a dense sub-prefix triggers preemptive promotion (§6.4). |
| Compaction budget | — | TBD | Maximum SST pages processed per block to bound worst-case block-processing latency. |
| GC live-ratio threshold | — | 0.3 | Segments below this live-page fraction are scheduled for GC. Over-provisioning ensures candidates always exist. |
| Combinadic LUT size | — | < 17 MiB | Precomputed binomial coefficient table for `n ≤ 4160`, `k ≤ 64`; eight `uint64` limbs per entry. |
| Segment size | — | 4 MiB | 1,024 pages per segment; unit of GC allocation and liveness tracking. |
| Container size | — | 4 GiB | 1,024 segments per container file, addressed by `(container_id, segment_offset)`. |
| Memory budget | `M` | ≈ 32 GiB | L0 buffer + routing table (≤ 8.1 GiB at 2^36) + node page cache + payload page cache + combinadic LUT (< 32 MiB). |
