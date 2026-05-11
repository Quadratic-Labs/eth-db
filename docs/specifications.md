# VerkleTrieDB — Technical Specification

- **Version:** 0.1 (Draft)
- **Date:** 2026-05-09
- **Status:** Work in Progress

---

## 1. Overview

VerkleTrieDB is an authenticated key-value store for Ethereum state, optimised for solid-state drives. It extends the design space of general-purpose key-value stores such as RocksDB with two structural improvements:

1. **Ethereum state specialisation.** The store is purpose-built for a large, sparse mapping of 32-byte keys to 32-byte values, avoiding the generality overhead of multi-purpose engines.
2. **Prefix-tree locality.** Entries are organised along their key prefixes, improving spatial locality and reducing read/write amplification on both SSDs and in memory.

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

Rather than caching every intermediate node, the store caches commitment nodes only at depths that are multiples of a fixed stride `D`. This bounds the recomputation cost to at most `D` levels when a cached node is invalidated, trading amplification for reduced storage overhead.

Upper tree levels (near the root) are updated very frequently but are cheaply recomputable from lower cached commitments, so they are kept **in memory only** and are not persisted to disk.

---

## 4. Storage Architecture

### 4.1 Sharding

The 32-byte key space is partitioned into `2^S` shards, where each shard corresponds to a unique `S`-bit key prefix. Typical values are `S = 14` or `S = 16`.

Each shard is an independent storage unit and can be mapped to a separate directory on the filesystem, allowing the OS to manage filesystem-level locality.

### 4.2 WAL-Based Storage

Each shard maintains a **Write-Ahead Log (WAL)**: an append-only file of at most `W` entries.

**Write path:** New entries are appended to the WAL and simultaneously reflected in an in-memory index.

**Read path:** The in-memory index is consulted first; if a candidate offset is found, a bounded linear scan from that offset is performed. If the entry is not located, a full sequential scan of the WAL is the fallback.

**WAL sizing:** `W` typically ranges from 1,024 to 65,536 entries, corresponding to WAL file sizes of 64 KB to 4 MB. The exact value is chosen to balance memory pressure against read amplification.

**In-memory index:** To minimise memory usage while supporting fast lookups with an associated payload (the WAL offset), the index uses a **Vector Quotient Filter** (see §6.3). Hash inputs reuse non-overlapping substrings of the key, which is already a hash, avoiding extra hash computation.

### 4.3 SST-Based Storage

When RAM pressure rises, older entries are demoted to **Sorted String Tables (SSTs)** stored entirely on disk. SSTs share the same 64-byte entry format as the WAL but are sorted by key.

**Negative-lookup filter:** Each SST carries a **BinaryFuse filter** (see §6.2) to allow fast rejection of absent keys without reading the table body.

**Sparse index:** An optional sparse index — maintained on disk or in memory — accelerates lookups by pointing directly to the region of the table where a key should reside.

**Key ordering:** Entries within an SST are ordered using **BFS encoding** (see §6.1), so that cousin nodes in the trie are co-located on the same storage page. This layout significantly reduces I/O when computing Merkle proofs.

**Sparse index alignment:** The sparse index should include only the leftmost cousin at each level (i.e., the entry with the most trailing zero bits in its BFS-encoded position), using bit-masking as necessary.

**SST levels:**

| Level | Description |
|-------|-------------|
| L0    | One or more freshly compacted tables, unsorted relative to each other. |
| L1    | Single merged table covering the full key range of the shard. |

### 4.4 Promotion and Demotion

**Promotion (cold → hot):** Newly written entries land in the WAL automatically. Frequently read entries are promoted from SST into the WAL based on access counts tracked in a counting sketch (see §6.4). A child entry may be promoted only after all its trie ancestors have been promoted; conversely, a parent may be demoted only after all its children have been demoted.

**Demotion (hot → cold):** During WAL compaction, entries that have not been recently accessed are written into a new SST L0 table.

---

## 5. Operations

### 5.1 Read

**Input:** key `K`

1. If `len(K)` falls within the in-memory trie size threshold, return the value from the in-memory trie.
2. Determine the shard from the `S`-bit prefix of `K`.
3. Query the WAL index. If an offset is returned, perform a bounded linear scan from that offset in the WAL file. On failure, fall back to a full sequential scan of the WAL.
4. Query each L0 SST: check range bounds, then the BinaryFuse filter. On a positive filter result, use the sparse index to locate the approximate offset and perform a bounded linear scan.
5. Repeat step 4 for the L1 SST.
6. If the key is not found in any structure, return `null`.
7. Record the access in the counting sketch.

### 5.2 Multi-Read (Batch Read)

Identical to the single read path, but all candidate lookups within a given WAL or SST are issued simultaneously when that structure is in scope, amortising per-file overhead.

### 5.3 Write

**Input:** key `K`, value `V`

1. If `len(K)` falls within the in-memory trie size threshold, update the in-memory trie directly.
2. Determine the shard from the `S`-bit prefix of `K`.
3. Append `(K, V)` to the shard's WAL and update the WAL index.
4. Record the access in the counting sketch.

### 5.4 Batch Write

From the database's perspective, a batch write is a sequence of single writes. The application layer, however, can exploit the structure of the Merkle trie: a single slot write propagates commitment updates up every ancestor. By batching slot writes and computing commitment updates in a single pass, each trie node is touched exactly once, substantially reducing write amplification.

### 5.5 Merkle Proof

A Merkle proof is a batch read that collects all sibling (cousin) commitments along the path from a target key to the root.

- **In SSTs:** Cousins are co-located by BFS ordering, so sibling reads are amortised across the width of the trie (few page reads per level).
- **In the WAL:** No structural locality is available; recent batch writes do, however, group parents and children temporally.
- **Opportunistic promotion:** When a sibling is found in a page during proof generation, it may be promoted to the in-memory trie at negligible extra cost.

### 5.6 Block Finalisation

The following steps are executed at the end of each block:

1. Flush the current block's read/write key set into the counting sketch.
2. Apply the promotion policy to identify SST entries that qualify for promotion.
3. Copy promoted entries into the WAL.
4. Apply the compaction policy to identify WALs that require compaction.
5. For each WAL to compact, apply the demotion policy to identify entries to demote.
6. Compact the WAL: write a new WAL file, recompute its index, and route demoted entries to SST L0.
7. Write the demoted L0 tables along with their sparse indexes and BinaryFuse filters.
8. Apply the SST compaction policy to identify shards requiring L0→L1 merging.
9. Merge L0 and L1 tables for the identified shards: rewrite the table, sparse index, and BinaryFuse filter.

> **Atomicity note:** File rewrites follow the sequence: write new file → delete old file → `fsync` → rename. This ensures that a crash never leaves the store in an inconsistent state.

---

## 6. Data Structures and Algorithms

### 6.1 BFS Encoding

Keys in SSTs are ordered by their position in a BFS traversal of the binary trie.

**Encoding:** For a bit-string of length `l` with big-endian value `n`, the BFS index is `2^l + n`. The leading `1` bit is a sentinel that encodes the length implicitly. The null node is represented by index `0`.

**Decoding:** Strip the most significant `1` bit from the BFS index; the remaining bits are the key prefix.

**Page locality:** With 4 KB pages and 64-byte entries, a page holds 64 entries. BFS ordering ensures that nodes at the same depth (cousins) are contiguous, so a single page read typically retrieves all siblings needed for a Merkle proof level.

### 6.2 BinaryFuse Filters

BinaryFuse filters are static probabilistic data structures used for fast negative lookups in SSTs. They are compact, have low false-positive rates, and are rebuilt during SST compaction. Ribbon filters are a comparable alternative.

> Full construction and query algorithms are deferred to a future revision.

### 6.3 Vector Quotient Filter (VQF)

The VQF is a dynamic filter that supports insert, update, and delete while also carrying a payload — here, the WAL offset associated with a key.

**Block selection:** The filter is divided into `k` blocks. For each key, two candidate blocks are identified via 2 non-overlapping substrings of the key (which is already a hash). The key is assigned to whichever candidate block is less loaded at insertion time (power-of-two-choices).

**Block structure:** Each block contains `b` buckets, each with a capacity of `s` payload slots of `r` bits each.

**Encoding:** A block is serialised as:
- A `(b + s)`-bit unary header, where each bucket's current occupancy is encoded in unary (1s for entries, 0 as a delimiter).
- A `(s × r)`-bit payload section containing the concatenated payloads.

**Parameter tuning:** The parameters `(k, b, s, r)` must be jointly chosen with the WAL size `W` and shard count `2^S` to meet the target space and read-amplification budgets.

### 6.4 Counting Sketches

Access frequency is tracked using a collection of count-min sketch instances arranged as a sliding window over recent blocks.

**Structure:** Maintain a rolling array of `N` sketch instances (e.g., `N = 12`), each covering a window of `B` consecutive blocks (e.g., `B = 32`). Each sketch uses 3–5 independent hash functions mapping keys to one of `C` buckets (e.g., `C = 65,536`).

**Per-block update:** At the end of each block, record deduplicated accessed keys into the current sketch instance. Rotate to a fresh instance every `B` blocks, discarding the oldest.

**Usage:** At block finalisation, query the combined sketch to rank keys by access frequency and determine promotion and demotion candidates.

### 6.5 Hash Functions

| Security level | Recommended function |
|----------------|---------------------|
| Performance    | xxHash              |
| Adversary resistance | SipHash       |
| Cryptographic  | SHA-256 (or Poseidon) |

---

## 7. Parametrisation

### 7.1 Scale Targets

Ethereum mainnet currently has approximately `S ≈ 2^32` storage slots. With a target load-test scale of `S = 2^36` slots and 64 bytes per entry, with a commitment fanout of `f = 2^6`:

```
Total data ≈ S × (f / (f − 1)) × 64 B
           ≈ 2^36 × (64/63) × 64 B
           ≈ ~4.4 TB
```

### 7.2 Parameters

| Parameter | Symbol | Description |
|-----------|--------|-------------|
| Commitment stride | `D` | Trie depth interval between persisted commitment nodes. Controls the recomputation vs. storage amplification trade-off. |
| Shard bits | `S` | Number of prefix bits used for sharding; yields `2^S` shards. Recommended: 14–16. |
| Commitment fanout | `f` | Number of stored child commitment nodes per stored parent. |
| Memory budget | `M` | Approximate maximum in-memory allocation for all caches (trie, indexes, filters, sketches). |
| WAL capacity | `W` | Maximum number of 64-byte entries per WAL file before compaction is triggered. Typical range: 1,024–65,536. |
| VQF parameters | `(k, b, s, r)` | Block count, bucket count per block, bucket capacity, and payload bit-width for the Vector Quotient Filter. |
| Sketch window | `(N, B, C)` | Number of sketch instances, blocks per instance, and bucket count per sketch. |
