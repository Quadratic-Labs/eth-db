# eth-db — Technical Specification

- **Version:** 0.5 (Draft)
- **Date:** 2026-06-30
- **Status:** Work in Progress — Flat DB read/write/durability path implemented; Commitment DB separation in progress.
- **Related:** Design synthesis in `prefix_redesign.md`; commitment subsystem in `commitment_redesign.md`.

---

## 1. Overview

EthDB is an authenticated key-value storage engine for Ethereum world state.
Its central design principle is to decouple the flat key-value store from the commitment trie into two independent stores, each tuned for the phase of the block cycle in which it is on the critical path:

- *Flat DB* — a commitment-free key-value store optimised for *read latency* during block execution.
- *Commitment DB* — a pure crit-bit trie carrying commitments as node payload, optimised for the *batched, hierarchical re-hash* performed at block finalisation.

Key-values and commitments are exercised at different times under different constraints (§2.1), so the design gives each store the data layout that fits its workload without compromise rather than conflating both concerns in one structure.

**Key properties:**

- *Decoupled stores.* Key-value storage and commitment storage are independent layers with independent layouts, allocators, and lifecycle. They share only a structural compatibility seam: each flat partition is exactly one crit-bit subtree (§2.1).
- *Zero-index reads.* The Flat DB needs no per-key index and no per-partition statistics beyond the entry count `n`. A read is a prefix lookup → interpolated offset → one *windowed io_uring read* → in-window search (§3.2).
- *Uniform-key advantage.* Post-hash tree-keys are uniform over the space, so any prefix splits into balanced partitions, key suffixes are uniform within a partition (enabling interpolation search), and partitions never need rebalancing across the growth curve (§2.5).
- **Fixed partitioning.** A single global prefix width `P = 24` (16 M partitions) holds from mainnet-today through the 2³⁶ target with no repartitioning (§3.3).
- **Batched, async read path is mandatory.** Reads cannot be serialised within the execution budget; the read path is io_uring-batched, not blocking `pread` (§3.1).
- **In-RAM L0, exact reads.** Writes are absorbed by a mutable memtable, frozen into immutable sorted RAM runs (L0), and bulk-compacted out-of-place into the partitioned base. L0 is searched exactly in RAM — no approximate filter, no false-positive disk reads (§3.4).
- **WAL durability.** A sequential write-ahead log is the sole durability mechanism for in-RAM state; the base is rewritten out-of-place (never in place — SSD/CoW) (§3.4, §3.7).
- **Multi-drive scaling.** App-level partition sharding scales aggregate bandwidth/IOPS ~linearly; it does not reduce single-read latency (§3.6).
- **Recomputable commitments.** The Commitment DB keeps the dense near-root levels in RAM and is recomputable from internal subtries; persisted commitment pages are pure caches of a canonical trie function (§4).

---

## 2. Architecture

### 2.1 Decoupled stores — rationale

Although key-values and commitments are related, the design does **not** conflate their storage layer, because they are used at different times and under different constraints.

**During block execution, commitments are not on the critical path.**
Writes land in the in-memory memtable, and the state root is computed afterwards.
What matters at execution time is primarily **read latency**, and secondarily read throughput.
A flat store beats climbing the crit-bit tree per read: ~1 windowed I/O with no in-node search, versus ~1–2 disk I/Os plus per-node search per read.

**At block finalisation, commitments become the critical path** as the state root is computed.
All commitments close to the root are updated, and every write also needs its sibling commitments.
This is a **batched, read-and-write-heavy workload with hierarchical structure** — well served by a pure crit-bit trie carrying commitments as node payload, and poorly served by a flat layout.

**Compatibility seam (costs nothing now, avoids rework later).**
The two stores are kept compatible so the commitment layer can be wired onto the flat store without reorganising it:

- A crit-bit subtree is exactly a contiguous key range in sorted order, and a `P`-bit prefix split is precisely the set of crit-bit nodes at depth `P`. Therefore **each flat partition = one crit-bit subtree**.
- Constraint on the flat store: store leaves **sorted by the same (post-hash) tree-key the crit-bit tree orders on** (not the raw address/slot), and **track a per-batch dirty set**. Incremental re-hash and witness enumeration then map straight onto partitions.

### 2.2 Storage model & hardware constraints

- **RAM:** ~32 GiB budget, latency ~10–50 ns.
- **NVMe SSD:** ~1 TiB+, latency ~10–50 µs; reads/writes operate on 4 KiB pages, erases on multi-page blocks.
- SSDs expose a Flash Translation Layer (FTL): pages cannot be updated in place once written. This favours copy-on-write / immutable structures (LSM-style) — **all on-disk base rewrites are out-of-place** (new files + atomic rename); "in place" updates are memory-only.
- **`O_DIRECT`** is used on the hot read path to bypass the page cache (mostly dead weight under a high cold-miss rate) and DMA straight into user-space buffers. This imposes 4 KiB alignment on buffers, file offsets, and read sizes; windowed reads are therefore page-aligned (read the covering pages, slice the window).
- **io_uring** is the read submission mechanism: queue N reads → one `submit_and_wait` → drain completions, matched by `user_data` (out-of-order safe). It is mandatory for the read path (§3.1), independent of window size.

> **Note on the io_uring backend.** The high-level `std.Io.Uring` backend is unusable on the pinned Zig 0.16.0 (compile + runtime bugs). The production reader is built on the low-level `std.os.linux.IoUring` binding; a portable threaded fallback exists for non-Linux. Revisit `std.Io.Uring` if it matures.

### 2.3 Data model

A storage slot is a pair `(K, V)` where both `K` and `V` are 32-byte quantities — a mapping `K : Bytes[32] → V : Bytes[32]`. The store accepts the usual unordered operations:

- **read(K)** → `V` (or absent).
- **write(K, V)** — insert or update.
- **delete(K)** — remove `K` (recorded as a tombstone; see §3.5).

In addition the engine maintains a cryptographic commitment to the full mapping — the **state root** — via the Commitment DB (§4), with the operation:

- **get-state-root(B)** → commitment `C` for block `B`.

### 2.4 Scale & record geometry

The scaling target is deliberately optimistic: it doubles as a load test and as future-proofing.

| Quantity | Baseline (mainnet today) | Target |
|---|---|---|
| Entries | ~2³² (≈ 4.3 B) | ~2³⁶ (≈ 69 B) |
| Raw data @ 64 B/entry | ~256 GiB | ~4.4 TB |
| Record | 32 B key + 32 B value = 64 B | (cache-line aligned) |
| Page | 4 KiB = 64 entries | |

### 2.5 Workload characteristics

- **Uniform keys.** Keys are post-hash tree-keys and therefore **uniform** over the space. Consequences exploited throughout: any prefix splits into balanced partitions; key suffixes are uniform within a partition (interpolation search lands the key with zero stored statistics); fixed partitioning needs no rebalancing.
- **Poor locality, batchable writes.** Writes land in scattered parts of the space (no locality), but they can be buffered and applied in bulk. Reads are latency-sensitive; writes can wait.
- **Bursty reads bounded by the execution window** (§3.1).

---

## 3. Flat DB

### 3.1 Read workload — burst within the execution budget

The relevant metric is reads completed **within the execution window** (target sub-second; modelled as ~200 ms for headroom), not reads averaged over the ~12 s slot.

| Load | Reads/block | Burst rate |
|---|---|---|
| Mainnet today (heavy block) | ~12 K (+4 K writes) | ~60 K reads/s |
| Scaled target | 50–100 K | ~250–500 K reads/s |

**Constraint — reads cannot be serialised.** 12 K cold reads × ~90 µs issued serially ≈ **1.08 s**, ~5× over budget before any scaling. Therefore:

- The read path **MUST** be io_uring-batched/async, not blocking `pread`. Required queue depth = rate × latency ≈ 6 today, ≈ 45 at the scaled target — trivial for io_uring.
- A pure sequential-EVM cold path cannot supply that concurrency alone. The design relies on batching/prefetch:
  - **(a)** the hot-set cache absorbing most reads (real cold-miss rate ~10–30 %, not 100 %);
  - **(b)** access-list / parallel-EVM prefetch to issue cold reads in batches. With a Block Access List the whole read set is known upfront and can be issued as a single batched pass (queue depth up to the ring), hiding cold-NVMe latency that interleaved per-read batches cannot.

> Multiple drives raise the throughput ceiling but do **not** reduce single-read latency — io_uring concurrency is still required (§3.6).

### 3.2 Read mechanism — interpolation + wide window (zero index)

Within a partition of `n` uniform entries, the rank of a key has standard deviation σ ≈ √n / 2. Reading a window of **±4σ = 4√n entries** centred on the interpolated offset lands the key in a single I/O ~99.99 % of the time. The only per-partition metadata needed is the entry count `n`:

```
rank = (key_suffix / 2^(256−P)) × n
```

On NVMe a wider read is ~free in *latency* (a 64 KiB read ≈ 90 µs vs a 4 KiB read ≈ 80 µs); the window costs only *bandwidth*, which is the ceiling that matters:

| entries/partition `n` | partition size | window (±4σ) | per-read latency | bandwidth QPS / drive |
|---|---|---|---|---|
| 4,096 | 256 KiB | 16 KiB | ~82 µs | ~366 K |
| 16,384 | 1 MiB | 32 KiB | ~85 µs | ~183 K |
| 65,536 | 4 MiB | 64 KiB | ~90 µs | ~92 K |

On a rare interpolation miss the read falls back to scanning the whole partition.

**Property — the window/index knob.** "Wide window" (no index, RAM = 0) and a **fence index** (store every G-th key in RAM → read a fixed G-entry / 4 KiB run, no interpolation) are the two ends of one knob. The fence index trades RAM (~0.5 GiB @2³², ~8.6 GiB @2³⁶ for G = 64) for a smaller, constant read. It is a **gated upgrade** for single-drive high-QPS deployments, not a day-one cost.

> **Deltas note.** Interpolation needs a clean sorted run, so it applies to the **base run** only; the small per-partition delta from recent flushes (L0) is checked separately in RAM (§3.4).

### 3.3 Partition sizing — fixed P = 24

`P` is chosen so partitions stay small at target scale and never need repartitioning across the growth curve:

- **P = 24** ⇒ 16 M partitions: ~256 entries each today (16 KiB, read whole partition), growing to ~4 K entries (256 KiB, 16 KiB window) at 2³⁶. Stays in the top row of the §3.2 table (~366 K reads/s/drive) the whole way.
- **Partitions are not 16 M files.** They are packed into 4 GiB container files via an in-house page container scheme with its own allocator (`page_id = container_id << 20 | local_page`) — ~1100 files at target.
- **Partition directory** `partition → (container_file, offset, n[, drive])` ≈ **256 MiB RAM**. Under uniform keys, fixed-P partitions are already balanced, so the read path needs no variable-depth radix routing — adaptive depth buys nothing here.
- Smaller partitions help on every axis simultaneously: smaller read windows (more bandwidth headroom), smaller/uniform compaction units, cheaper rewrites. Total compaction write volume is **independent of P** (it is the base size); `P` only sets granularity.

### 3.4 Write scheme — in-RAM L0 runs + bulk partitioned compaction

Writes are uniform and thin: a memtable flush touches almost every partition with only a handful of keys each. **Per-partition flush is fatal** (millions of scattered tiny writes + 256×+ WAF). Instead the store keeps a 2-level structure: a small mutable memtable plus N immutable sorted RAM runs as L0, compacted in bulk into the prefix-partitioned on-disk base.

**Durability is the WAL's job, not L0's.** Each write is appended to a sequential WAL (cheap, predictable) before entering RAM, so L0 living in memory loses nothing on a crash: recovery replays the WAL segments not yet folded into the base. L0 is purely the in-RAM read + compaction structure.

The lifecycle has three stages, each chosen for predictability:

1. **Execution** *(Predictability #1)* — each write → WAL append (sequential) + the active memtable, a plain unordered hash map with O(1) point lookups. Base/compaction are untouched ⇒ no random-write jitter on the critical path.
2. **Freeze** *(Predictability #2)* — when the active memtable fills, sort it once into a compact immutable RAM run (the same 64 B `key‖value` sorted-array layout as the base) and start a fresh empty active map. No disk write here (the WAL already holds the bytes); cost is one memtable's worth of sort. Freezing is block-aligned.
3. **Compaction (idle window)** *(Predictability #3)* — once `K` frozen runs accumulate, k-way *merge* them (all pre-sorted) with the affected base partitions and write a new base **out-of-place** (new files + atomic rename; never in place — SSD/CoW), then drop those RAM runs and truncate their WAL segments. Each base partition is rewritten once per cycle; bounded, schedulable, evenly divisible across uniform partitions ⇒ time-sliceable and pausable.

**Read path — no filter needed.** A lookup checks, newest-wins: active memtable (hash, RAM) → each frozen RAM run (binary search of a sorted array, RAM, **exact**) → base (one windowed io_uring read). Frozen runs are searched exactly and cheaply in RAM, so there is **no approximate filter and no false-positive disk reads**. The only disk I/O on a cold read is the single base window read, preceded by ~`K` cache-friendly RAM binary searches.

**Amplification.** Disk writes are only: the WAL (1× the data, sequential, unavoidable for durability) + periodic base compaction. With memtable = 1 GiB and `K = 16` (16 GiB folded per cycle) into a 256 GiB base ⇒ base-rewrite **WAF ≈ 256/16 = 16×**, plus ~1× for the WAL. `K` is the read-amp ↔ write-amp dial: larger `K` ⇒ lower WAF, but more RAM runs to scan per read, more RAM resident, and longer crash replay.

> **WAF in absolute terms.** Under uniform thin writes a compaction rewrites ~the whole base, so WAF ≈ `base / (K · flush)` — streaming compaction (§3.5 ops) fixes memory and budgetability, not write volume. But Ethereum's logical write rate is tiny (~64 KB/s), so even a high WAF is modest in bytes (e.g. K = 64 ⇒ ~84× ⇒ ~5 MB/s ⇒ ~0.45 TB/day).

#### 3.4.1 Design rationale — N immutable sorted runs, not one larger memtable

Same bytes in RAM either way; the win is structure + lifecycle, not volume:

1. **Representation (the big one).** A single ever-growing memtable must stay *mutable and searchable*: a skiplist/tree (pointer-chasing, 2–4× bloat, cache-hostile `O(log n)`) or a hash map (unordered ⇒ must be sorted later anyway). Freezing transcodes each run **once** into a dense sorted array identical to the base — lock-free, cache-dense, binary/interpolation-searchable with the **same code as the base**, and already sorted, so compaction is a cheap k-way merge. Only the small active map pays the mutable-structure cost.
2. **Write/compaction overlap.** Freeze + fresh active map ⇒ writes never stall while the previous batch compacts in the background. One growing memtable forces a stall at flush (or a concurrent-mutation structure).
3. **Lock-free concurrent reads.** Immutable runs are read by the parallel/batched read path with zero synchronisation; a live mutable memtable needs locking/MVCC.
4. **Bounded compaction + bounded recovery.** Discrete runs = bounded, pausable compaction units and per-segment WAL truncation (bounded crash replay). One giant memtable = one giant flush event + a large WAL to replay.

> **Non-reason: WAF.** A bigger memtable and more frozen runs both raise data-per-base-rewrite, so they amortise base WAF identically — WAF does **not** distinguish them; reasons 1–4 do. (A bigger *active* memtable independently buys fewer freezes; tune it separately from `K`.)

#### 3.4.2 Rejected alternative (kept on the shelf) — on-disk L0 + xor filters

The first sketch put L0 runs **on disk** and used a per-run approximate filter to skip runs that don't contain the key:

- One static **xor / binary-fuse filter per run**, built at flush (runs are immutable). *Not* per-partition, and *not* min/max zone-maps — neither cuts the probe count, and zone-maps are useless under uniform keys (every run spans the whole range).
- A read probes the `R` run-filters in RAM; false-positive cost is `R × f` wasted window reads, negligible for small `R` (e.g. 8 × 1 % ≈ 0.08 reads/lookup) — even a blocked Bloom would do. Space is a non-issue (bits/key, tens of MB).

**Why rejected for now:** strictly more work and slightly slower than in-RAM L0 — it adds a second on-disk write per flush (beyond the WAL), `R` filter probes *plus* occasional false-positive disk reads, and filter build/maintenance — whereas in-RAM L0 is **exact** (zero FP, zero L0 disk reads) and reuses the base's sorted-array machinery. The in-RAM model trades ~`K × memtable` of RAM (a few GiB) for that simplicity and the slight speed edge.

**When to revisit:** if the RAM budget can't hold ~`K × memtable` of resident L0. The read path already binary-searches sorted runs, so the only additions are: persist runs, build a per-run filter, and gate each run read behind its filter. Layout, compaction, and newest-wins ordering are unchanged.

> Global L0 + bulk compaction keeps the merge **sequential and predictable** instead of scattering it across per-partition appends — at the same or better WAF.

### 3.5 Operations

**Read(K).** Resolve newest-wins across tiers: active memtable (hash) → L0 runs (binary search, newest run first) → base (windowed io_uring read; §3.2). A tombstone encountered in RAM short-circuits to *absent* with no base read. With BAL prefetch, a prefetch map sits **below L0 and above base** (`memtable → L0 → prefetch → base`), so in-block writes still shadow prefetched values (read-your-writes holds) and execution reads resolve from RAM with no per-read disk I/O.

**Write(K, V).** WAL append + insert into the active memtable. No base or compaction work on the critical path.

**Delete(K).** Records a memtable tombstone (the memtable maps `Key → ?Value`, null = tombstone). On freeze, tombstones are carried into the L0 run; the **base stays a pure 64-byte format** — compaction's newest-wins merge simply drops a key whose newest source is a tombstone, so tombstones never reach the base. Tombstones persist in run files, so recovery does not resurrect deleted keys. (Per Ethereum convention, writing the zero value is also equivalent to absence at the application layer.)

**Freeze / endBlock.** Block-aligned: fires at the memtable capacity or every `freeze_block_interval` blocks. Sorts the active map into an immutable run, persists the run file (fsync), then commits the manifest and advances `covered_height`.

**Compaction (streaming, budgeted, resumable).** A streaming k-way merge of the base (buffered sequential reader) + a snapshot of the L0 runs (newest-wins) into a new base built out-of-place, computing the partition directory on the fly. `compactStep(byte_budget)` advances ≤ that many output bytes per call and resumes by key position, so one compaction spreads over many idle windows under a per-window byte budget. Reads keep serving from the old base + L0 until the final atomic manifest swap; a freeze *during* a job appends a new run that the snapshot does not fold (it survives to the next cycle). Memory is bounded (read + write buffers + the new directory), not O(base).

**Durability & recovery (no per-write WAL of values; manifest-committed tiers).** Three tiers: the **base** is a generation-suffixed file (durable); **L0 runs** are persisted at freeze and kept RAM-resident for exact reads; the **memtable** is never durable (the host replays it). The **manifest** (written temp + fsync + rename) is the atomic commit point, recording `{prefix_bits, window, base_gen, next_run_seq, covered_height, [run seqs + counts]}`. On `open`, the base + runs are reloaded from the manifest and `covered_height` is exposed; the host replays blocks `> covered_height` before serving.

### 3.6 Multi-drive scaling — partition sharding

Independent NVMe drives scale aggregate **bandwidth and IOPS ~linearly**; they do **not** reduce single-read latency (io_uring concurrency is still required).

Use **app-level partition sharding, not RAID-0**: map `partition → drive` (`partition_id % N` or a directory field), placing each drive's container files on its mount. Uniform keys ⇒ each drive automatically gets ~1/N of reads, and every window read stays **one contiguous I/O to one drive** (no stripe-misalignment, no split-read coordination). Compaction's bulk rewrite also spreads across all N drives.

Drives vs. the scaled 500 K reads/s target (per drive ≈ 6 GB/s, ~1 M IOPS; PCIe 5.0 ~2×):

| read unit | reads/s / drive | drives for 500 K/s |
|---|---|---|
| 64 KiB window | ~92 K | ~6 |
| 32 KiB window | ~183 K | ~3 |
| 16 KiB window (P = 24) | ~366 K | ~2 |
| 4 KiB (fence index) | ~1 M (IOPS) | 1 |

> **Multiple drives and the fence index are alternative solutions to the same bandwidth ceiling** (hardware $ vs. RAM + code). Caveats: PCIe lanes cap N (~4–5 on a workstation, dozens on a server); memory bandwidth/NUMA becomes the next ceiling at ~6+ drives; latency is unchanged. Redundancy is a conscious choice — **JBOD-shard + re-sync-on-failure** is defensible since Ethereum state is reconstructible from peers (RAID-10/parity costs capacity and some of the bandwidth just bought).

### 3.7 Baseline recommendation

- **2–3 NVMe drives + fixed P = 24 + wide-window interpolation (zero index) + partition sharding.** Simplest read code; scales to the burst target on modest hardware.
- **io_uring-batched reads are mandatory** (the latency wall), independent of window size.
- **Write path:** active hash-map memtable → freeze into N immutable sorted RAM runs (L0, no filters — exact in-RAM lookup) → out-of-place streaming bulk compaction into the partitioned base in idle windows; tune `K` for WAF vs. read-amp; durability via WAL + manifest.
- **Fence index:** kept in reserve for single-drive deployments that still want high QPS.

---

## 4. Commitment DB

Commitments form a **crit-bit trie** with commitments carried as node payload; the structure follows the canonical trie function of `commitment_redesign.md` (§2 there) rather than any storage layout — creating or destroying a cached page never changes a committed value.

**Properties:**

- **Dense near the root, kept in RAM.** The levels closest to the root are dense and resident in memory; they are updated very frequently but are cheaply recomputable from children's cached commitments, so they need not be persisted (the depth-0 page is memory-only).
- **Recomputable.** Commitments are derived data: on recovery the trie is rebuilt from the internal subtries (manifest restores checkpointed pages; WAL replay re-marks dirty slots and recomputes via gather).
- **Stride-6 caching.** Commitment nodes are cached at depths that are multiples of stride `D = 6`. Each persisted **commitment page** is a 4 KiB allocation holding the complete 6-level binary subtree as an implicit heap of 127 × 32 B hashes (`h[1]` = the node's own subtree commitment; `h[64..127]` = the 64 child-slot values at depth + 1). This bounds recomputation to at most `D` levels when a cached node is invalidated, and stores every sibling a Merkle proof needs.
- **Decoupled from storage.** Commitment computation never reads SST/append pages structurally and compaction never dirties commitment state; the only coupling is the **bottom-slot gather** (a point lookup of a slot's key set), which is layout-independent. The dirty set is derived from the block's logical writes, not from storage events.
- **Out-of-place persistence.** Flushing is always copy-on-write; the manifest checkpoint atomically repoints routing to fresh page ids, so a crash mid-flush loses nothing.

> The detailed commitment node rule (pass-through `combine`, domain separation, lazy leaves, deepening `T_DEEPEN`), page layouts, commit algorithm, proofs, and persistence are specified in `commitment_redesign.md`. The flat/commitment compatibility seam (partition = subtree, sorted by tree-key, per-batch dirty set) is the integration point (§2.1).

---

## 5. Parametrisation

### 5.1 Scale targets

| Scale | Entries | Raw data @ 64 B | Partitions (P = 24) | Entries / partition | Window (±4σ) |
|---|---|---|---|---|---|
| Mainnet today | ~2³² | ~256 GiB | 16 M | ~256 | whole partition (16 KiB) |
| Target | ~2³⁶ | ~4.4 TB | 16 M | ~4 K | 16 KiB |

### 5.2 Parameters

| Parameter | Symbol | Typical value | Description |
|---|---|---|---|
| Partition prefix width | `P` | 24 | Fixed global prefix bits ⇒ 16 M balanced partitions; never repartitioned (§3.3). |
| Record size | — | 64 B | 32 B key + 32 B value, cache-line aligned. |
| Page | — | 4 KiB = 64 entries | Disk I/O unit; O_DIRECT alignment unit. |
| Read window | ±4σ | 4√n entries (default 1024 = 64 KiB) | Centred interpolation window; single-I/O hit ~99.99 % (§3.2). |
| Partition directory RAM | — | ≈ 256 MiB | `partition → (container_file, offset, n[, drive])` (§3.3). |
| Memtable capacity | — | ≈ 1 GiB | Active mutable hash map; freeze trigger (§3.4). |
| Frozen runs before compaction | `K` | tens–hundreds (test default 8) | Read-amp ↔ write-amp dial; sets base-rewrite WAF (§3.4). |
| Base-rewrite WAF | — | ≈ `base / (K · flush)` (~16× @ K = 16) | Plus ~1× sequential WAL (§3.4). |
| Container size | — | 4 GiB | Many partitions packed per container file; ~1100 files at target. |
| Fence index stride | `G` | ∞ (disabled) / 64 (gated) | RAM-for-read-size knob; ~0.5 GiB @2³², ~8.6 GiB @2³⁶ at G = 64 (§3.2). |
| Drives | `N` | 2–3 (baseline) | App-level partition sharding for bandwidth/IOPS (§3.6). |
| Commitment stride | `D` | 6 | Depth interval between cached commitment nodes ⇒ 127-hash 4 KiB subtree page (§4). |
| Memory budget | `M` | ≈ 32 GiB | WAL + memtable + L0 runs (~`K × memtable`) + partition directory + caches + commitment near-root. |
