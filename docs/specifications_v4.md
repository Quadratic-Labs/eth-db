# PrefixDB — Technical Specification

- **Version:** 0.4 (Draft)
- **Date:** 2026-05-22
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
- Each node page holds two zones in a single **1-page (4 KiB)** allocation: a **sorted zone** (up to 123 pages, globally sorted and non-overlapping) supporting O(log N) binary search, and an **append zone** (up to 8 pages, recently written) with a per-page **16-bit relative prefix filter** (FPR ≈ 0.1%) for point queries.
- Block writes are always O(1) appends to the append zone. Append-to-sorted compaction (§6.1) runs exclusively in the inter-block idle window, contributing zero latency variance to block processing. During the merge step, any page whose entries all share the same 6-bit sub-prefix is immediately promoted to the next level.

---

## 2. Data Model

### 2.0 Storage Model

- In-memory space ~32GiB, latency of ~10-50 nanoseconds.
- SSD space ~1TiB, latency of ~10-50 microseconds.
- SSD read/write must operate on a page, usually 4KiB each.
- SSD deletes must operate on a block, usually 64 pages.

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
With `D = 6`, each node holds exactly 64 sibling commitments (2,048 B), co-located with the node's SST index in a single 4 KiB page (§4.2.2).

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
| Worst-case block latency | Compaction stalls | Predictable | Zero — compaction in idle window |
| Read filter FPR | Bloom ~1% | N/A (exact) | ~0.1% (16-bit prefix, append zone only) |
| Skew handling | None | None | Per-page sub-prefix detection (§6.1) |

**Downsides.**
A key may exist in SST pages at multiple prefix levels simultaneously; a read must find the most-recent value across all of them (§5.1 step 8).
This is inherent to any LSM-derived design, but the impact is contained: within a single node, the sorted zone holds at most one copy and the append zone holds at most A_max = 8 pages with near-zero FPR (0.1%).

Append-to-sorted compaction rewrites up to S_max = 123 sorted pages per merge event (worst case for uniform key distributions such as Keccak256), giving a steady-state write amplification of approximately 15× per compaction cycle — substantially less than B+-tree's per-key path-copy cost (~384× at the target scale), and bounded to the idle window so block latency is unaffected.

The per-block compaction budget (§8.2) bounds worst-case idle-window processing time; if the budget is insufficient across multiple consecutive blocks, compaction debt accumulates and append zones remain full, degrading reads until the idle window catches up.

---

## 4. Storage Architecture

### 4.1 Layered Storage

Storage is organised into levels L0 through LN. Level Lk holds pages whose entries share a common key prefix of `6k` bits.

**L0 (in-memory buffer):**
- New writes are appended to a sorted in-memory buffer and simultaneously journalled to a WAL for crash recovery.
- When the buffer accumulates ≥ 64 entries sharing a common 6-bit prefix, a new SST page is created and appended to the **append zone** of the corresponding L1 node.
- Superseded values for duplicate keys are discarded at compaction time.

**L1:**
- Holds pages of 64 internally sorted entries, grouped by their first 6 bits of key prefix.
- Each node maintains a **sorted zone** (up to 123 pages, globally sorted and non-overlapping by key range) and an **append zone** (up to 8 recently appended pages); see §4.2.2.
- When the append zone is full, an append-to-sorted merge is queued for the inter-block idle window (§6.1). During that merge, any page whose entries all share a common 12-bit prefix is promoted as an L2 page.

**Lk (general):**
- Pages at level Lk hold entries sharing a common `6k`-bit prefix.
- Each node has the same two-zone structure as L1.
- On append-to-sorted merge, entries sharing a `6(k+1)`-bit prefix are eligible for promotion to L(k+1); the rest are integrated into the sorted zone.
- Stale values for overwritten keys are discarded at each merge.

**Compaction triggers:**
- *Append zone full*: `append_count = A_max` (default 8) → append-to-sorted merge queued for idle window.
- *Sorted zone full*: `sorted_count = S_max` (default 123) → upward split (§6.2) queued for idle window.

> **Note on latency:** Both triggers are processed in the inter-block idle window, never during block execution. A per-block compaction budget caps the total work per cycle (§8.2).

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

Each routing table entry `prefix_data → node_page_id` points to a **single-page (4 KiB) node page** on the heap. This allocation co-locates the node's child commitment hashes, its sorted-zone index, and its append-zone filter, making commitment and index updates a single atomic CoW operation.

The node page is divided into two zones:

- **Sorted zone** (`sorted_count` pages, 0 ≤ `sorted_count` ≤ 123): pages are globally sorted and non-overlapping by key range. A binary search on `sorted_min4` locates the unique candidate page for any lookup key.
- **Append zone** (`append_count` pages, 0 ≤ `append_count` ≤ 8): recently flushed pages, unordered relative to each other. Each page carries a sorted list of 64 relative 16-bit key prefixes for point-query filtering (§7.1).

**On-disk layout (4,096 bytes = 1 physical page):**

| Field | Size | Description |
|-------|------|-------------|
| `sorted_count` | 1 B | Number of valid entries in the sorted zone (0–123) |
| `append_count` | 1 B | Number of valid entries in the append zone (0–8) |
| `_pad` | 2 B | |
| `child_commitments[64]` | 2,048 B | 64 × 32 B commitment hashes for the 64 child nodes at depth k+1 |
| `sorted_slot_ids[123]` | 492 B | Heap addresses of the 123 sorted-zone SST pages |
| `sorted_min4[123]` | 492 B | Per-page boundary: 32-bit relative key prefix of the minimum key in each sorted page (§7.1) |
| `append_slot_ids[8]` | 32 B | Heap addresses of the 8 append-zone SST pages |
| `append_prefix16[8][64]` | 1,024 B | Per-page filter: sorted array of 64 relative 16-bit key prefixes (§7.1) |
| `_reserved` | 4 B | |

**Total:** `4 + 2,048 + 492 + 492 + 32 + 1,024 + 4 = 4,096 B` — exactly one physical page.

**Sorted-zone invariant:** `sorted_min4` values are strictly increasing (guaranteed for uniform/Keccak256 key distributions). For lookup key K, the candidate sorted page is the one at the largest index i such that `sorted_min4[i] ≤ prefix32(K, k)`, where `prefix32(K, k)` is defined in §7.1.

**Append-zone freshness:** append pages are ordered by insertion time; later indices hold more recently written entries. If the same key K appears in both zones, the append zone's value is always more recent than the sorted zone's value.

The node page is rewritten under CoW whenever SSTs are added, removed, or reordered, or when any child commitment changes.
The routing table entry pointing to it is updated in the same operation.
Because commitment data and SST index share the same physical allocation, a block that touches both requires only one CoW write per affected node rather than two.

**Compaction triggers:**
- Append zone full (`append_count = 8`): append-to-sorted merge queued for idle window (§6.1).
- Sorted zone full (`sorted_count = 123`): upward split queued for idle window (§6.2).

### 4.3 Heap

All persistent pages — **node pages (single-page 4 KiB allocations), KV payload pages** — are stored in a unified **page heap** with the following addressing scheme:

- **Page size:** 4 KiB.
- **Addressing:** 4-byte page identifiers → up to `2^32` pages → up to 16 TiB total addressable space.
- **Segment:** 1,024 contiguous pages = 4 MiB. The unit of allocation and GC.
- **Container:** 1,024 segments = 4 GiB. Stored as a single file, addressed by `(container_id, segment_offset)`.
- **Liveness bitmap:** One bit per page per segment (128 bytes), kept in memory and persisted to a sidecar file for GC use.

The routing table itself is in-memory; only the node pages it points to are heap-resident. Node pages carry both SST index data and child commitment hashes in one contiguous 4 KiB allocation; there are no separate commitment pages. The two logical stores (KV payload, and node pages) may be assigned separate containers with independent GC parameters and cache budgets.

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
5. For each node page received at depth k:
   - **Sorted zone:** compute `q = prefix32(K, k)` (§7.1). Binary-search `sorted_min4[0..sorted_count]` for the largest i such that `sorted_min4[i] ≤ q`. Add `sorted_slot_ids[i]` to the SST read set.
   - **Append zone:** compute `f = prefix16(K, k)` (§7.1). For each append page j in `0..append_count`: binary-search `append_prefix16[j][0..64]` for `f`; if found, add `append_slot_ids[j]` to the SST read set.
6. **Issue all candidate SST page reads as a single parallel batch.**
7. For each candidate SST page, perform a binary search over its 64 sorted entries to locate `K`; record any match found.
8. Among all matches found across all depth levels and zones: within a node, the append-zone value is authoritative over the sorted-zone value (append pages are always more recent). Across depth levels, the **shallowest** level (lowest k) that holds the key has the most recently written value — it overwrites any copy at deeper levels. Return that value, or `null` if no match was found.
9. For any node `(k, P)` from which ≥ T_opp append pages were loaded in step 6, add `(k, P)` to the merge-candidate queue (§6.4). The pages are already in the page cache, so no extra I/O is incurred.

The critical I/O path after warm-up is **two parallel rounds**: node pages → SST pages. In the common case (sorted zone hit, empty or no-match append zone), exactly **one SST page is read per node level**.

### 5.2 Write

**Input:** key `K`, value `V`

1. Append `(K, V)` to the in-memory L0 buffer and write a KV WAL record.
2. If any 6-bit prefix group in the buffer reaches ≥ 64 entries: sort that group, write a new SST page to the heap, append its `payload_slot_id` to the corresponding Lk node's append zone (`append_slot_ids[append_count]`, `append_prefix16[append_count][0..64]`), increment `append_count`, and rewrite the node page (CoW); update `RoutingMap[k][prefix_data] ← new_node_page_id` and append a routing WAL record.
3. If the append zone of any node reaches `A_max = 8` pages, queue that node for an append-to-sorted merge in the next idle window (§6.1).

### 5.3 Revert

PrefixDB has no separate delete primitive. Setting a slot to the empty value `[0u8; 32]` is a regular write — it propagates through L0 and compaction exactly like any other write, and yields `null` on read by convention at the Ethereum application layer (a zero-valued slot is absent from the trie).

The operation described here is **state revert**: undoing the writes applied in one or more blocks to restore the store to a prior state. Two mechanisms are available, suited to different rollback depths.

#### Within-block transaction revert (in-memory)

When a transaction reverts during block execution its writes are still in L0 — no flush has occurred. The engine maintains a per-transaction **L0 checkpoint** (the entry-count at transaction start). On revert, all L0 entries appended since that checkpoint are discarded in place. This is an O(n_reverted_writes) in-memory operation with zero disk I/O.

#### Block rollback via state diffs

At block finalisation (§5.5) the engine records a **state diff** for the block: for every key `K` whose value changed during the block, it stores the pair `(K, V_prev)` — the value that existed immediately before the block (or absent, recorded as `[0u8; 32]`).

To roll back block B:

1. For each `(K, V_prev)` in block B's state diff: apply `write(K, V_prev)` as a regular L0 write.
2. These write-backs flush through the normal L0 → append zone path. Because writes at the shallowest level are always authoritative (§5.1 step 8), `V_prev` is immediately the live value for `K` without waiting for compaction.
3. To roll back a chain of blocks back to ancestor B, apply state diffs in reverse order — block B+n first, down to block B+1.

Rolling back k blocks costs the same as writing k blocks' worth of changed keys and competes for the same L0 and append-zone resources.

#### Deep rollback via routing table snapshot restore

For a large reorg where state diffs would produce excessive write amplification, the engine can instead:

1. Restore the routing table from the WAL snapshot taken at block B (§4.2.1).
2. Mark all heap pages allocated after that snapshot epoch as garbage (their liveness bits are cleared).
3. GC reclaims those pages in the next idle window (§5.6).

This is O(routing_table_restore) rather than O(changed_keys × reorg_depth), but requires that GC has not yet recycled the post-B pages — i.e. the GC retention window must cover the rollback depth.

> The two mechanisms are complementary: state diffs are cheap for short rollbacks (1–128 blocks, the typical reorg window); snapshot restore is efficient for longer ones. State diff storage size is proportional to the number of touched keys per block, not total state size, keeping retention cost low.

### 5.4 Range Query

**Input:** range `[K_start, K_end)`

Returns all live key-value pairs `(K, V)` with `K_start ≤ K < K_end`, ordered by key, reflecting all pending writes and deletions.

1. Collect entries from the L0 buffer with `K_start ≤ K < K_end`; keep only the most-recent write per key.
2. For each depth d ∈ {1, 2, 3, 4, 5}: enumerate all `RoutingMap[d]` entries whose `prefix_data` falls in the interval `[prefix_data(K_start, d), prefix_data(K_end, d)]`. Collect the corresponding `node_page_ids`.
3. **Issue all node page reads as a single parallel batch.**
4. For each node page received at depth k:
   - **Sorted zone:** binary-search `sorted_min4[0..sorted_count]` for the first page index i where `sorted_min4[i] ≤ prefix32(K_end, k)` and `sorted_min4[i+1] > prefix32(K_start, k)` (i.e., the page's range overlaps the query). Scan forward through consecutive pages until the range is exhausted. Add all intersecting `sorted_slot_ids` to the SST read set.
   - **Append zone:** add all `append_slot_ids[0..append_count]` to the SST read set unconditionally — append pages are unordered relative to one another and any of them may contain entries in the query range.
5. **Issue all candidate SST page reads as a single parallel batch.**
6. For each candidate SST page: binary-search its 64 sorted entries for `K_start`, then scan forward collecting entries with `K < K_end`.
7. Merge results across all depth levels and zones:
   - Deduplicate by key, keeping the most-recent version: append zone overrides sorted zone within a node; shallowest level overrides deeper levels across nodes.
   - Discard entries whose value is `TOMBSTONE`.
8. Return the deduplicated, tombstone-filtered results in ascending key order.

> **Routing enumeration scope:** at depth d, at most `prefix_data(K_end, d) − prefix_data(K_start, d) + 1` nodes are visited — equal to the range expressed in units of `2^(256 − 6d)` of key space. For account-scoped storage queries (keys sharing a common Keccak256 prefix), this is typically 1–2 nodes per depth. For full-range scans all nodes at the settling depth are visited; the routing WAL snapshot files (§4.2.1), which are flat sorted arrays, support efficient prefix-range enumeration via binary search in that case.

### 5.5 Block Finalisation

The following steps are executed at the end of each block:

1. Compute commitment updates for all affected strided nodes; rewrite their node pages (CoW).
2. Apply pending append-to-sorted merges and upward splits within the available per-block compaction budget.
3. Write all new and modified node pages to the heap (CoW); `fsync` heap.
4. Flush routing WAL to disk; `fsync` routing WAL. If the WAL exceeds the snapshot size threshold, write a fresh snapshot for each modified depth-level map and truncate the WAL.
5. Truncate the KV WAL to the current checkpoint.
6. Run the GC pass on segments whose live-page ratio falls below the threshold (see §5.5).

> **Atomicity note:** New heap pages are always written before old ones are released. The routing WAL is flushed after the heap `fsync`, so a crash between the two leaves the heap consistent and the WAL tail covers any routing updates not yet reflected in a snapshot. Recovery replays the WAL tail against the last snapshot.

### 5.6 Garbage Collection

GC reclaims heap pages whose liveness-bitmap bit has been cleared by a CoW update or a key deletion.

**Trigger:** GC runs in the idle window between block finalisation and the arrival of the next block.

**Execution:**
1. Select segments whose live-page ratio falls below the threshold (e.g., 0.3).
2. For each selected segment: copy live pages to a fresh destination segment; for each moved node page update `RoutingMap[k][prefix_data] ← new_page_id` and append a routing WAL record; `fsync` after each batch.
3. Once a segment is fully evacuated, release its storage to the filesystem.

**Determinism:** GC is paused at block arrival and resumed at block finalisation, so it contributes zero latency variance to block processing.

---

## 6. Compaction

Compaction operates on a single prefix node at a time (micro-compaction), keeping I/O and routing-index updates localised. It runs in three modes: **append-to-sorted merge** when the append zone fills, **upward split** when the sorted zone is full, and **downward merge** when a node becomes too sparse. A fourth path — **opportunistic merge** — exploits I/O already paid by reads. All routing-index changes in all paths are made by updating `RoutingMap[k]` (§4.2.1) and appending a WAL record — a single O(1) operation per changed routing entry, with no path-copy overhead.

### 6.1 Append-to-Sorted Merge

**Trigger:** `append_count` at node `(k, P)` reaches `A_max = 8`.

**Procedure** (executed during the inter-block idle window):

1. Read all `A_max` append-zone SST pages for `(k, P)`.
2. Identify which sorted-zone pages have key ranges that intersect any of the append pages: for each sorted page i, load it if its range `[sorted_min4[i], sorted_min4[i+1])` overlaps with the key range of any append page. In the worst case (uniform key distributions such as Keccak256), this is all sorted pages; in the best case (clustered writes), it is one or two.
3. Merge all loaded entries (append + intersecting sorted pages), retaining only the most-recent value for each key; discard superseded entries.
4. Sort the surviving entries by key.
5. Repartition into pages of 64 entries each (⌈surviving / 64⌉ pages).
6. **Sub-prefix promotion check:** for each resulting page, inspect bits `[6k : 6k+6]` of its entries' 16-bit relative prefixes. If all 64 entries share the same 6-bit sub-prefix — detectable in O(1) as `(prefix16_min >> 10) == (prefix16_max >> 10)` on the sorted prefix list — promote that page to L(k+1): write it as a new SST page, create or update the node page for `(k+1, P||Q)`, set `RoutingMap[k+1][P||Q] ← new_node_page_id`, and append a routing WAL record.
7. The non-promoted pages replace the intersecting sorted pages; unaffected sorted pages remain unchanged. Reconstruct `sorted_slot_ids` and `sorted_min4` in sorted key order. Reset `append_count = 0`.
8. Rewrite the node page for `(k, P)` (CoW); set `RoutingMap[k][P] ← new_node_page_id` and append a routing WAL record; release all replaced SST pages and the old node page for GC.

> Promotion may cascade: if L(k+1, P||Q) now has a full append zone, it is queued for its own merge in the next available compaction slot.

### 6.2 Upward Split

**Trigger:** `sorted_count` at node `(k, P)` reaches `S_max = 123`.

**Procedure** (executed during the inter-block idle window):

1. Read all `S_max` sorted-zone SST pages for `(k, P)`.
2. Merge all entries, retaining only the most-recent value for each key; discard superseded entries.
3. Sort the surviving entries by key.
4. Identify all groups sharing a common `6(k+1)`-bit prefix. For each such group of ≥ 64 entries: write SST pages and create or update the node page for `(k+1, Q)`; set `RoutingMap[k+1][Q] ← new_node_page_id` and append a routing WAL record.
5. Reorganise remaining entries into fresh sorted Lk pages (up to 64 entries per page).
6. Rebuild the sorted zone for `(k, P)` and rewrite its node page (CoW); set `RoutingMap[k][P] ← new_node_page_id` and append a routing WAL record; release all old SST pages and the old node page for GC.

> Upward splits may cascade: if an L(k+1) node reaches S_max after receiving new pages, it is queued for its own upward split.

### 6.3 Downward Merge

**Trigger:** the total live entries across all SST pages at node `(k+1, Q)` fall below the merge threshold (default 16 entries), and the parent node `(k, P)` — where P is Q with its last 6 bits removed — has remaining sorted capacity.

**Procedure:**

1. Read all SST pages from node `(k+1, Q)` and all intersecting sorted pages from node `(k, P)`.
2. Merge all entries; for any key present at both levels the L(k+1) entry is authoritative (it reflects a more recent write or compaction).
3. Discard superseded entries; sort survivors by key.
4. Integrate merged result into the sorted zone of `(k, P)`: repartition and rebuild `sorted_slot_ids` and `sorted_min4`.
5. Rewrite the node page for `(k, P)` (CoW); set `RoutingMap[k][P] ← new_node_page_id` and append a routing WAL record.
6. **Delete** `RoutingMap[k+1][Q]` and append a delete routing WAL record; release the node page for `(k+1, Q)` and all its SST pages for GC.

> Downward merges may cascade: if the updated `(k, P)` node is itself now sparse, a downward merge from k → k−1 is queued for the next available slot.

### 6.4 Opportunistic Merge

When the read path loads several append-zone pages for the same prefix node, the I/O cost is already paid. Rather than discarding those pages, the engine queues the node for an early append-to-sorted merge while the pages remain warm in cache.

**Trigger:** at the end of §5.1 step 9, any node `(k, P)` from which ≥ T_opp append pages were loaded is added to the merge-candidate queue, ordered by loaded-page count descending.

**Execution** (during the inter-block idle window, consuming the shared compaction budget):

1. For each candidate `(k, P)` in queue order: verify the loaded SST pages are still current (no CoW replacement since the read); if stale, re-read them.
2. Execute the append-to-sorted merge procedure (§6.1 steps 3–8) using only the loaded append pages, merging with any intersecting sorted pages.

All four compaction paths draw from the same per-block compaction budget (§8.2).

---

## 7. Data Structures and Algorithms

### 7.1 Relative Prefix Encoding

Two relative prefix quantities are used throughout the node page (§4.2.2) to support efficient lookup without requiring full key comparisons across all SST pages.

For a node at depth k, let `K_u256` denote key K interpreted as a big-endian 256-bit integer.

**32-bit boundary prefix (sorted zone):**

```
prefix32(K, k) = (K_u256 >> (256 − 6k − 32)) & 0xFFFFFFFF
```

This extracts the 32 bits of K immediately following the node's `6k`-bit prefix, packed into a `u32`. It is used as the binary-search key in `sorted_min4`: the page boundary stored for each sorted page is `prefix32(min_key_of_page, k)`.

**16-bit filter prefix (append zone):**

```
prefix16(K, k) = (K_u256 >> (256 − 6k − 16)) & 0xFFFF
```

This extracts the 16 bits of K immediately following the node's `6k`-bit prefix, packed into a `u16`. Each entry in every SST page contributes one `prefix16` value to the per-page filter stored in `append_prefix16`.

**Filter properties:** with a 16-bit universe (65,536 values) and 64 entries per SST page, the false-positive probability per page is:

```
FPR = 1 − (1 − 1/65536)^64 ≈ 64 / 65536 ≈ 0.098%
```

Because entries within an SST page are already sorted by full key, their `prefix16` values are non-decreasing — no additional sort pass is needed when building `append_prefix16`.

**Sub-prefix promotion check:** during an append-to-sorted merge (§6.1 step 6), a page can be tested for full sub-prefix homogeneity in O(1): since `append_prefix16` is sorted, check `(prefix16_sorted[0] >> 10) == (prefix16_sorted[63] >> 10)`. If true, all 64 entries share the same 6-bit sub-prefix (the top 6 of the 16-bit prefix) and the page is a candidate for promotion to L(k+1).

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
| Sorted zone capacity | `S_max` | 123 | Maximum sorted-zone SST pages per node; derived from single-page constraint: `floor((4,096 − 2,052 − A_max × 132) / 8) = 123` with A_max = 8. |
| Append zone capacity | `A_max` | 8 | Maximum append-zone SST pages per node; merge triggered when this is reached. |
| Total pages per node | — | 131 | `S_max + A_max = 123 + 8`; all metadata fits in a single 4 KiB node page. |
| Node page size | — | 4 KiB (1 page) | Single physical page; layout: 4 B header + 2,048 B commitments + 984 B sorted zone + 1,056 B append zone + 4 B reserved. |
| Append-zone FPR | — | ≈ 0.098% | Per-page false-positive rate for 16-bit relative prefix filter; `64 / 65,536`. |
| Routing entry size | — | 8 B | `(prefix_data : u32, node_page_id : u32)`; depth is implicit from which map is consulted. |
| Routing table RAM | — | ≈ 134 MiB / 8.1 GiB | Total for depths 1–5 at 2^32 / 2^36 key scale; depths 1–4 always reside in RAM. |
| Routing WAL flush | — | every block | Routing WAL is flushed and `fsync`'d at every block finalisation. |
| Routing snapshot interval | — | configurable | Full snapshot of all depth-level maps written to disk when WAL exceeds size threshold; WAL truncated after successful snapshot. |
| Upward split trigger | — | 123 pages | Sorted-zone SST count at which upward split (§6.2) is queued. |
| Downward merge threshold | — | 16 entries | Total live entries below which a node is merged back into its parent. |
| Opportunistic merge threshold | `T_opp` | 2 pages | Minimum append pages loaded for the same node in a single read to queue an early merge (§6.4). |
| Steady-state write amplification | — | ≈ 15× | Append-to-sorted merge rewrites ≈ S_max sorted pages per A_max × 64-entry merge event; paid during idle window only. |
| Compaction budget | — | TBD | Maximum SST pages processed per idle window to bound worst-case processing time. |
| GC live-ratio threshold | — | 0.3 | Segments below this live-page fraction are scheduled for GC. Over-provisioning ensures candidates always exist. |
| Segment size | — | 4 MiB | 1,024 pages per segment; unit of GC allocation and liveness tracking. |
| Container size | — | 4 GiB | 1,024 segments per container file, addressed by `(container_id, segment_offset)`. |
| Memory budget | `M` | ≈ 32 GiB | L0 buffer + routing table (≤ 8.1 GiB at 2^36) + node page cache + payload page cache. |
