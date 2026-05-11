# QuotientDB — Technical Specification

- **Version:** 0.1 (Draft)
- **Date:** 2026-05-10
- **Status:** Work in Progress

---

## 1. Overview

QuotientDB is an authenticated key-value storage engine for Ethereum world state, optimized for low write amplification on SSD, deterministic block-processing latency, and graceful scaling.
Routes 256-bit keys to fixed-size buckets, stores 64-byte entries (32B key + 32B value) inside buckets, and manages bucket payloads via a log-structured slab heap with scheduled garbage collector (GC) for controlled latency.

What this design optimises:

- ...
- No sorted runs, no SSTs, no LSM levels → no compaction-driven write amp.

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
---

## 3. Commitment Caching

### 3.1 Motivation

Naively, every batch write would require recomputing commitments from leaf to root, touching every ancestor of every modified key. To avoid this, the store caches selected intermediate commitment nodes on disk.

Caching trades read for write and space amplification; however, since addressing relies only on key prefixes, reads and writes at different trie depths are independent and can proceed in parallel.

### 3.2 Cache Policy

Rather than caching every intermediate node, the store caches commitment nodes only at depths that are multiples of a fixed stride `D`.
This bounds the recomputation cost to at most `D` levels when a cached node is invalidated, trading amplification for reduced storage overhead.
Typically `D=6`, so that we can store in a node its 64 children commitments, fitting nicely in a storage page of 4KiB

Upper tree levels (near the root) are updated very frequently but are cheaply recomputable from lower cached commitments, so they are kept **in memory only** and are not persisted to disk.

---

## 4. Storage Architecture

### 4.1 Sharding
For easier parallel processing, we can shard storage according to the keys first `S`-bits.
We will use for example `S=8`, giving us 256 shards, plenty for parallel file accesses.

### 4.2 Routing (RAM-Resident)
More generally, we use the first `R` bits to route keys to a corresponding bucket.
This buy us direct bucket addressing for free.
Each bucket has metadata in memory: occupancy counter, segment id, slot id.
This should fit 8B, for a total of `2^{R + 3}`B.
Keeping all upper commitments from depth `0-R` in memory adds `2^{R+6}`B.
With `R=28`, this takes 2GiB of RAM for metadata, plus 16GiB of commitments.

### 4.3 Bucket Payload Heap (Disk)

Log-structured slab allocator with size levels, for example L0 is 4 KiB and each next level is 4 times the size of the previous level (4, 16, 64, 256).

- **Segments**: 64 MiB units of allocation and GC. Each holds a fixed number of equal-size slots (e.g., 16,384 slots of 4 KiB in the small class).
- **Containers**: 4 GiB files holding 64 segments each, addressed by `(container_id, segment_offset)`.
- **Allocation**: pure bump pointer per active segment. No free lists on the hot path. When a segment fills, it's sealed and a new one opened.
- **Promotion**: when a bucket outgrows its level's size, allocate a slot in the next level, copy payload, update bucket index, mark old slot dead. At most 3 promotions per bucket (across 4 levels).
- **Slot header**: 4 bytes for owner bucket-ID, used during GC to update the bucket index without reverse-scanning.

Expected occupancy: average 16 entries per bucket (1 KiB), tail to 256 entries (16 KiB) under load. Most buckets stay in the 4 KiB class.

### 4.4 Within-Bucket Structure

- Bucket is a flat array of 64B slots, indexed positionally.
- Insert: append at next free slot, increment occupancy.
- Lookup: linear scan of the bucket comparing keys (fast — 4 KiB is one NVMe read + sub-µs CPU scan).
- Delete: flip a bit in the segment's liveness bitmap. No physical write to the slot. Bucket-index entry updated to reflect new occupancy.

No per-entry offsets — slot position is the offset.

---

## 5. Heap Memory Management

### 5.1 Tombstones and Liveness

Tombstones allow to mark heap slots as being deleted.
We keep a liveness bitmap per segment, persisted in a sidecar file that is loaded on demand by the GC.
For 64 MiB segments, one bit per slot means 4 KiB, aligns well with pages.
On deletion of a slot, we have a bitmap bit flip + WAL append, so no I/O to the slot itself.

### 5.2 WAL and Crash Consistency

- Existing WAL-per-subtree infrastructure carries heap operations: allocations, promotions, GC moves, deletions.
- Heap writes are append-only at known segment offsets; partial writes truncated to last good offset on recovery.
- Bucket index reconstructed from checkpoints + WAL replay.
- Slot data is content-addressed via the bucket index; orphaned slots from crashes become dead space, reclaimed by next GC pass.

### 5.3 Garbage Collection
Garbage collection can be scheduled and single or multi-threaded.
There is currently much latency room for garbage collection, and is collection work is infrequent.

**Trigger and policy:**
- GC runs in the time window between block finalization and new block reception, when database is currently idle.
- Picks segments with lowest live ratio
- Threshold ~0.3 live ratio; over-provisioning ensures candidates exist.

Note: possible later refinement later, using a cost-benefit scoring with age weighting.

**Execution:**
- For each selected segment: process its live slots in 256 KiB batches (64 slots in the 4 KiB class).
- Per batch: read live slots from the source segment, append to a fresh destination segment, update bucket index, WAL the moves, fsync batch's WAL entry.
- Between batches: check window-open and budget-remaining flags.
- Uses `O_DIRECT` to bypass page cache, protecting hot trie nodes.

**Reclamation:**
- When source segment hits zero live slots, `fallocate(PUNCH_HOLE)` returns its bytes to the filesystem.
- Container files grow only when all segments are allocated.

**Determinism guarantees:**
- GC paused at block arrival (T0), resumed at block finalization (T6).
- Bucket index immutable from GC's perspective during block processing.
- `O_DIRECT` keeps page cache uncontaminated.
- Latency variance from GC is bounded to zero during active block work.

### 5.4 Steady-State Economics

- **Write amplification**: ~1.3-1.5× total (promotion ≈1.3×, GC ≈0.05×). Dominated by promotion copies, since dead slots accumulate from invalidation but not from sorting.
- **Space amplification**: ~1.5-2× (over-provisioning to maintain low live-ratio at GC time).
- **Read amplification**: ~1× (one bucket read).
- **GC throughput needed**: <5 MiB/s at current Ethereum cadence. Negligible fraction of NVMe budget.

---

## 6. Operations

### 6.1 Read

**Input:** key `K`

1. Compute the `R`-bit prefix of `K` to identify the target bucket.
2. Load bucket metadata (occupancy, segment ID, slot ID) from the RAM-resident routing table.
3. Issue a single read of the bucket's payload from the slab heap (one NVMe I/O for small buckets).
4. Perform a linear scan over the 64-byte entries to locate `K`.
5. Return the associated value, or `null` if not found.

### 6.2 Write

**Input:** key `K`, value `V`

1. Compute the `R`-bit prefix of `K` to identify the target bucket.
2. Load bucket metadata from the routing table.
3. Append `(K, V)` to the bucket's payload in the current segment.
4. If the bucket's payload exceeds the current slab level's capacity, promote to the next level (copy, update bucket index, mark old slot dead — see §4.3).
5. Update bucket metadata and append the operation to the WAL.

### 6.3 Batch Write

From the database's perspective, a batch write is a sequence of single writes. The application layer, however, can exploit the structure of the Merkle trie: a single slot write propagates commitment updates up every ancestor. By batching slot writes and computing commitment updates in a single pass, each trie node is touched exactly once, substantially reducing write amplification.

---

## 7. Memory Footprint

- Routing: hundreds of MiB (per-bucket occupancy counters).
- Bucket index cache: configurable, ~1-2 GiB for hot working set.
- Segment metadata: <100 MiB.
- Liveness bitmaps (loaded portions): tens of MiB.
- TrieStore arena: separate, already designed.

Total storage-engine RAM: a few GiB, well within modern server budgets.

## 8. Design Seams Left Open for Scale-Up

Even though we're staying in the over-provisioned regime, two seams worth keeping clean:

1. **Bucket-index updates go through a single abstraction**, so MVCC could be retrofitted if time windows ever shrink to the point where concurrent GC becomes necessary.
2. **GC is batch-processable and resumable from day one**, so it can be subdivided across smaller windows without restructuring.
3. **`O_DIRECT` from the start** — enables kernel I/O priority later without refactoring.

## 9. What This Design Is Not Doing

- No sorted runs, no SSTs, no LSM levels → no compaction-driven write amp.
- No global free list maintenance on the hot path → no allocator contention.
- No per-entry offsets stored anywhere → simpler metadata.
- No power-of-two-choice routing → no read amplification, no per-block filters.
- No background GC during block processing → deterministic latency.

---

## 10. Parametrisation

### 10.1 Scale Targets

Ethereum mainnet currently has approximately `2^32` storage slots. With a target load-test scale of `2^36` slots and 64 bytes per entry, with a commitment fanout of `f = 2^6`:

```
Total data ≈ 2^36 × (64/63) × 64 B  ≈  4.4 TB
```

### 10.2 Parameters

| Parameter | Symbol | Typical value | Description |
|-----------|--------|---------------|-------------|
| Commitment stride | `D` | 6 | Trie depth interval between persisted commitment nodes. Controls recomputation vs. storage amplification trade-off; `D=6` fits 64 child commitments in one 4 KiB page. |
| Shard bits | `S` | 8 | Number of key prefix bits used for filesystem-level sharding; yields `2^S` shards. `S ≤ R`. |
| Routing bits | `R` | 28 | Number of key prefix bits used to address buckets; yields `2^R` buckets with 8 B metadata each (`2^{R+3}` B total). `R=28` → 2 GiB routing table. |
| Slab level sizes | — | 4, 16, 64, 256 KiB | Payload slot sizes per slab level (geometric series, ratio 4×). Determines promotion thresholds and maximum bucket payload. |
| Segment size | — | 64 MiB | Fixed unit of allocation and GC. Liveness bitmap is 4 KiB (one bit per 4 KiB slot). |
| Container size | — | 4 GiB | File holding 64 segments, addressed by `(container_id, segment_offset)`. |
| GC live ratio threshold | — | 0.3 | Segments below this ratio are GC candidates. Over-provisioning ensures candidates always exist. |
| GC batch size | — | 256 KiB | Sub-unit of execution within a selected segment (64 slots in the 4 KiB class). Controls pause granularity. |
| Memory budget | `M` | 32 GiB | Approximate upper bound on storage-engine RAM across routing table, bucket index cache, segment metadata, and liveness bitmaps. |

---
