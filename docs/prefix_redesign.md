# Design Note — Flat KV Store (synthesis, 2026-06-28)

> This note records the **decisions we converged on** after critiquing an initial
> brainstorm (with another agent) against the real constraints of this project.
> The raw transcript — with superseded numbers such as a 16-bit prefix / 65 536
> partition files — was trimmed from this file on 2026-08-25; see git history.
> Scope: the **flat, commitment-free key-value store** that serves the
> block-execution read path. Republished, extended and kept current as
> `specifications_v5.md` §1–§3; this note remains the design record cited from
> `flat_store.zig`, `batch_read.zig`, and `uring_read.zig`.

## 0. Architecture decision — decouple storage from commitment

- During block execution, commitments are **not** on the critical path: writes land in the
  in-memory mempool/memtable, and the state root is computed afterwards. What matters at
  execution time is **read latency**. A flat store beats climbing the crit-bit tree per read
  (tree ≈ 1–2 disk I/Os + in-node search vs. flat ≈ 1 windowed I/O, no search).
- Therefore: store KV pairs in a flat, commitment-free store optimized for reads; keep the
  crit-bit commitment tree as a **separate** structure. **Build the flat store first**,
  add the commitment layer later.
- Compatibility seam for the later commitment work — costs nothing now, avoids rework:
  - A crit-bit subtree is exactly a contiguous key range in sorted order, and a `P`-bit
    prefix split is precisely the set of crit-bit nodes at depth `P`. So **each flat
    partition = one crit-bit subtree**.
  - Constraint: store leaves **sorted by the same (post-hash) tree-key the crit-bit tree
    orders on** (not the raw address/slot), and **track a per-batch dirty set**. Then
    incremental re-hash and witness enumeration map straight onto partitions.

## 1. Scale & record geometry

| Quantity | Baseline (mainnet today) | Target |
|---|---|---|
| Entries | ~2³² (≈4.3 B) | ~2³⁶ (≈69 B) |
| Raw data @ 64 B/entry | ~256 GiB | ~4.4 TB |
| Record | 32 B key + 32 B value = 64 B | (cache-line aligned) |
| Page | 4 KiB = 64 entries | |

Keys are post-hash tree-keys ⇒ **uniform** over the space ⇒ any prefix splits into balanced
partitions, and the key suffix is uniform within a partition (this is what makes
interpolation work with zero stored statistics).

## 2. Read workload — burst within the execution budget (QPS framing)

The relevant metric is **not** reads averaged over the 12 s slot; it is reads completed
**within the execution window** (target sub-second, model as ~200 ms for headroom).

- Today, heavy block: ~12 K reads (+4 K writes) ⇒ **~60 K reads/s burst**.
- Scaled target (50–100 K reads/block): **~250–500 K reads/s burst**.

**Latency serialization wall:** 12 K cold reads × ~90 µs issued serially ≈ **1.08 s** — over
budget by 5× before any scaling. Consequences:

- **The read path MUST be io_uring-batched/async, not blocking `pread`.** Required queue
  depth = rate × latency ≈ 6 today, ≈ 45 at the scaled target. Trivial for io_uring.
- A pure sequential-EVM cold path can't supply that concurrency alone, so rely on
  (a) the hot-set cache absorbing most reads (real cold-miss rate ~10–30 %, not 100 %),
  and (b) access-list / parallel-EVM prefetch to issue cold reads in batches.
- Multiple drives raise the throughput ceiling but do **not** reduce single-read latency.

## 3. Read mechanism — interpolation + wide window (zero index)

Within a partition of `n` uniform entries, the rank of a key has σ ≈ √n / 2 entries. Read a
window of **±4σ = 4√n entries** centered on the interpolated offset ⇒ lands the key in a
single I/O ~99.99 % of the time. **Zero per-partition metadata** is needed beyond the entry
count `n`: `rank = (key_suffix / 2^(256−P)) × n`.

On NVMe a wider read is ~free in *latency* (a 64 KiB read ≈ 90 µs vs 4 KiB ≈ 80 µs); the
window only costs **bandwidth**, which is the ceiling that matters:

| entries/partition `n` | partition size | window (±4σ) | per-read latency | bandwidth QPS / drive |
|---|---|---|---|---|
| 4,096 | 256 KiB | 16 KiB | ~82 µs | ~366 K |
| 16,384 | 1 MiB | 32 KiB | ~85 µs | ~183 K |
| 65,536 | 4 MiB | 64 KiB | ~90 µs | ~92 K |

The **fence index** (store every G-th key in RAM → read a fixed G-entry / 4 KiB run, no
interpolation) is the alternative that trades RAM (~0.5 GiB @2³², ~8.6 GiB @2³⁶ for G=64)
for a smaller, constant read. Treat it as a **gated upgrade** for single-drive high-QPS
deployments, not a day-one cost. "Wide window" (G=∞, RAM=0) and "fence index" (small G) are
the two ends of one knob.

Deltas note: interpolation needs a clean sorted run, so apply it to the **base run** only;
the small per-partition delta from recent flushes is checked separately (see §5).

## 4. Partition sizing — fixed P = 24

Pick `P` so partitions stay small at target scale, and never repartition across the growth
curve:

- **P = 24** ⇒ 16 M partitions; ~256 entries each today (16 KiB, read whole partition),
  growing to ~4 K entries (16 KiB window) at 2³⁶. Stays in the top row of the table above
  (~366 K reads/s/drive) the whole way.
- Partition directory `partition → (container_file, offset, n[, drive])` ≈ **256 MiB RAM**.
  This **replaces the stride-6 variable-depth radix routing for the read path** — under
  uniform keys, fixed-P partitions are already balanced, so adaptive depth buys nothing here.
- **Do not** create 16 M files. Reuse the existing container scheme
  (`page_id = container_id<<20 | local_page`): pack many partitions per 4 GiB container file
  (~1100 files at 2³⁶).
- Smaller partitions help simultaneously: smaller read windows (more bandwidth headroom),
  smaller/uniform compaction units, cheaper rewrites. Total compaction write volume is
  **independent of P** (it's the base size); P only sets granularity.

## 5. Write scheme — in-RAM L0 runs + bulk partitioned compaction

Writes are uniform and thin: a memtable flush touches almost every partition with only a
handful of keys each. **Per-partition flush is fatal** (millions of scattered tiny writes +
256×+ WAF). Instead, a 2-level structure: a small mutable memtable + **N immutable sorted
RAM runs** as L0, compacted in bulk into the prefix-partitioned on-disk base.

**Durability is the WAL's job, not L0's.** Each write is appended to a sequential WAL (cheap,
predictable) before entering RAM, so L0 living in memory loses nothing on a crash — recovery
replays the WAL segments not yet folded into the base. L0 is purely the in-RAM read +
compaction structure.

1. **Execution:** each write → WAL append (sequential) + the **active memtable**, a plain hash
   map (O(1) point lookups; unordered is fine — we only probe it by key). Base/compaction are
   untouched ⇒ no random write jitter on the critical path. *(Predictability #1)*
2. **Freeze:** when the active memtable fills, **sort it once into a compact immutable RAM
   run** — the same 64 B `key‖value` sorted-array layout as the base — and start a fresh empty
   active map. No disk write here (the WAL already holds the bytes). Cost: one memtable's worth
   of sort. *(Predictability #2)*
3. **Compaction (idle window):** once `K` frozen runs accumulate, k-way **merge** them (all
   pre-sorted) with the affected base partitions and write a new base **out-of-place** (new
   files + atomic rename; never in-place — SSD/CoW), then drop those RAM runs and truncate
   their WAL segments. Each base partition is rewritten once per cycle; bounded, schedulable,
   evenly divisible across uniform partitions ⇒ time-sliceable, pausable. *(Predictability #3)*

**Read path — no filter needed.** A lookup checks: active memtable (hash, RAM) → each frozen
RAM run (binary search of a sorted array, RAM, **exact**) → base (one windowed io_uring read).
Frozen runs are searched exactly and cheaply in RAM, so there is **no approximate filter and
no false-positive disk reads**. The only disk I/O on a cold read is the single base window
read, preceded by ~`K` cache-friendly RAM binary searches. Newest-wins ordering (memtable →
newest run → … → base) returns the freshest value.

**Amplification.** Disk writes are only: the WAL (1× the data, sequential, unavoidable for
durability) + periodic base compaction. With memtable = 1 GiB, `K = 16` (16 GiB folded per
cycle) into a 256 GiB base ⇒ base-rewrite **WAF ≈ 256/16 = 16×**, plus ~1× for the WAL. `K`
is the read-amp ↔ write-amp dial: larger `K` ⇒ lower WAF, but more RAM runs to scan per read,
more RAM resident, and longer crash replay.

### Why N immutable sorted runs, not one larger memtable

Same bytes in RAM either way — the win is structure + lifecycle, not volume:

1. **Representation (the big one).** A single ever-growing memtable must stay *mutable and
   searchable*: a skiplist/tree (pointer-chasing, 2–4× bloat, cache-hostile `O(log n)`) or a
   hash map (unordered ⇒ must be sorted later anyway). Freezing transcodes each run **once**
   into a dense sorted array identical to the base — lock-free, cache-dense, binary/inter-
   polation searchable with the *same code as the base*, and **already sorted, so compaction
   is a cheap k-way merge**. Only the small active map pays the mutable-structure cost.
2. **Write/compaction overlap.** Freeze + fresh active map ⇒ writes never stall while the
   previous batch compacts in the background. One growing memtable forces a stall at flush
   (or a concurrent-mutation structure).
3. **Lock-free concurrent reads.** Immutable runs are read by the parallel/batched read path
   with zero synchronization; a live mutable memtable needs locking/MVCC.
4. **Bounded compaction + bounded recovery.** Discrete runs = bounded, pausable compaction
   units and per-segment WAL truncation (bounded crash replay). One giant memtable = one giant
   flush event + a large WAL to replay.

**Non-reason: WAF.** A bigger memtable and more frozen runs both raise data-per-base-rewrite,
so they amortize base WAF identically — WAF does **not** distinguish them. Reasons 1–4 do. (A
bigger *active* memtable independently buys fewer freezes; tune it separately from `K`.)

### Rejected alternative (kept on the shelf): on-disk L0 + xor filters

The first sketch put L0 runs **on disk** and used a per-run approximate **filter** to skip
runs that don't contain the key. Mechanics, for the record:

- One static **xor / binary-fuse filter per run**, built at flush (runs are immutable). *Not*
  per-partition, and *not* min/max zone-maps: neither cuts the probe count, and zone-maps are
  useless under uniform keys (every run spans the whole key range).
- A read probes the `R` run-filters in RAM; false-positive cost is `R × f` wasted window reads,
  negligible for small `R` (e.g. 8 × 1 % ≈ 0.08 reads/lookup) — so even a blocked Bloom would
  do; minimum-FP exotica is unnecessary. Space is a non-issue (bit/key, tens of MB).

**Why rejected for now:** strictly more work and slightly slower than in-RAM L0 — it adds a
second on-disk write per flush (beyond the WAL), `R` filter probes *plus* occasional
false-positive disk reads, and filter build/maintenance — whereas in-RAM L0 is **exact** (zero
FP, zero L0 disk reads) and reuses the base's sorted-array machinery. The in-RAM model trades
~`K × memtable` of RAM (a few GiB) for that simplicity and the slight speed edge.

**When to revisit:** if the RAM budget can't hold ~`K × memtable` of resident L0, move L0 to
disk and add the per-run xor filter. The read path already binary-searches sorted runs, so the
only additions are: persist runs, build a filter per run, and gate each run read behind its
filter. Layout, compaction, and newest-wins ordering are unchanged.

This is the **flat/global version of the existing per-node design** (append zone A_MAX=8 →
sorted zone S_MAX=108, ~15× WAF): global L0 + bulk compaction keeps the merge sequential and
predictable instead of scattered, at the same or better WAF.

## 6. Multi-drive scaling — partition sharding (not in current spec)

Independent NVMe drives scale aggregate **bandwidth and IOPS ~linearly**; they do **not**
reduce single-read latency (io_uring concurrency is still required).

Use **app-level partition sharding**, not RAID-0: map `partition → drive` (`partition_id % N`
or a directory field), place each drive's container files on its mount. Uniform keys ⇒ each
drive automatically gets ~1/N of reads, and every window read stays **one contiguous I/O to
one drive** (no stripe-misalignment, no split-read coordination). Compaction's bulk rewrite
also spreads across all N drives.

Drives vs. the scaled 500 K reads/s target (per drive ≈ 6 GB/s, ~1 M IOPS; PCIe 5.0 ~2×):

| read unit | reads/s / drive | drives for 500 K/s |
|---|---|---|
| 64 KiB window | ~92 K | ~6 |
| 32 KiB window | ~183 K | ~3 |
| 16 KiB window (P=24) | ~366 K | ~2 |
| 4 KiB (fence index) | ~1 M (IOPS) | 1 |

**Multiple drives and the fence index are alternative solutions to the same bandwidth
ceiling** (hardware $ vs. RAM + code). Caveats: PCIe lanes cap N (~4–5 on a workstation,
dozens on a server); memory bandwidth/NUMA becomes the next ceiling at ~6+ drives; latency
unchanged; redundancy is a conscious choice — **JBOD-shard + re-sync-on-failure** is
defensible since Ethereum state is reconstructible from peers (RAID-10/parity costs capacity
and some of the bandwidth just bought).

## 7. Baseline recommendation

- **2–3 NVMe drives + fixed P = 24 + wide-window interpolation (zero index) + partition
  sharding.** Simplest read code; scales to the burst target on modest hardware.
- **io_uring-batched reads are mandatory** (latency wall), independent of window size.
- **Write path:** active hash-map memtable → freeze into N immutable sorted RAM runs (L0,
  no filters — exact in-RAM lookup) → out-of-place bulk compaction into the partitioned base
  in idle windows; tune K for WAF vs. read-amp; durability via WAL.
- **Fence index:** kept in reserve for single-drive deployments that still want high QPS.

## 8. Open questions / next steps

1. **Flush/compaction cadence math** — memtable size, `K` (runs before compaction), and the
   idle-window budget per block — to land a target WAF and bounded L0 read-amp against the
   real block rate.
2. **Async io_uring read path** — batched window reads against the existing `page_store.zig`
   container addressing (the actual gating mechanism, not the window size).
3. **Pin P precisely** against the real key-count growth model (confirm P=24 vs 22/26).
4. **Commitment integration** (later) — wire the per-batch dirty set + partition=subtree
   mapping into crit-bit re-hash.

## 9. Implementation status (2026-06-29)

- **`src/batch_read.zig`** — first cut of the batched read path. Issues N positional
  reads as an `Io.Group` of async tasks and awaits them as one batch; `readBatch(io,
  reqs, results)` over `(file, offset, buffer)`. Backend-agnostic: becomes batched
  io_uring SQEs under `std.Io.Uring`, runs concurrently on the thread pool under the
  threaded backend. Compiles; 3 unit tests pass on `std.testing.io`.
- **`src/uring_read.zig`** — the **production io_uring reader** (`Reader.readBatch`)
  on the low-level `std.os.linux.IoUring` binding: queue N reads → one
  `submit_and_wait` → drain CQEs, matched back by `user_data` (out-of-order safe),
  batches > ring depth split across submits. Single positional-read semantics
  (`< buffer.len` ⇒ EOF). 4 unit tests pass on a **real ring** (out-of-order,
  chunking, per-request error/EOF, empty).
- **Why low-level, not the `std.Io` backend:** `std.Io.Uring` is doubly broken in the
  pinned Zig **0.16.0** — it fails to compile (std error-set bug: `ReadOnlyFileSystem`
  missing from `Dir.OpenError`/`File.RealPathError`, `std/Io/Uring.zig:2732`/`:3157`)
  **and**, even with a 2-line std patch, deadlocks at runtime (immature evented entry
  model). There is no newer Zig release to upgrade to (0.16.0 is latest). The
  low-level binding works on this kernel (verified: 8 SQE / 1 submit / 8 CQE).
  **Decision (2026-06-29): low-level reader now; revisit `std.Io.Uring` if it matures.**
- **`batch_read.zig` is retained as the portable fallback** (threaded `Io` backend,
  cross-platform); `uring_read.zig` is Linux-only and is the hot path.
- **`src/flat_store.zig`** — the flat-store **read path**, wired onto the reader.
  `FlatStore` holds the RAM partition directory `[]Partition{offset,count}` (indexed
  by the top `prefix_bits` of the key), the base file, and a `uring_read.Reader`.
  `get`/`getMany` do: partition → interpolation `rank=(suffix64·n)>>64` → window read
  (centred, `window_entries`, default 1024 = 64 KiB) batched via the ring → in-window
  binary search → whole-partition fallback on the rare interpolation miss. On-disk
  record is canonical `key[0..32]||value[32..64]` (layout-independent). The hot path
  reads the raw fd via `Io.File.handle`; the base file is built (cold) via the
  portable `std.Io` path. 5 tests pass on a real ring (uniform-key point lookups,
  batched getMany, tiny-window→fallback, empty store, dup last-write-wins).
- **`src/flat_store.zig` — write path (§5), wired onto the read path.** `put` →
  active `AutoHashMap` memtable; at `memtable_cap` unique keys, `freeze` sorts it into
  an immutable RAM `Run` (L0) and starts a fresh map; at `l0_compact_threshold` (K)
  runs, `compact` reads the base + all runs, rebuilds a new base via `buildBaseFile`
  written **out-of-place** (temp + `rename`), reopens it, and drops the runs.
  `get`/`getMany` now merge newest→oldest: memtable (hash) → L0 runs (binary search,
  newest first) → base (windowed ring read, only for keys missing from RAM). 6
  write-path tests pass on a real ring — memtable read-back, newest-wins across all
  three tiers, freeze threshold, L0-only reads, and a **randomized 4000-op pipeline
  with overwrites** (auto freeze + auto compaction) verified against a reference map
  under the leak-checking test allocator.
- **`src/flat_store.zig` — durability (§9 model), no per-write WAL.** Three tiers:
  base = generation-suffixed file `name.base.<gen>` (must be durable); L0 = persisted
  at freeze as `name.run.<seq>` (fsync'd) *and* kept RAM-resident for exact reads;
  memtable = never durable (host replays). The **manifest** `name.manifest` (written
  temp+fsync+`rename`) is the atomic commit point — `{prefix_bits, window, base_gen,
  next_run_seq, covered_height, [run seqs+counts]}`. `freeze` is block-aligned via
  **`endBlock(height)`** (fires at `memtable_cap` or every `freeze_block_interval`
  blocks), writes the run file, then commits the manifest and advances `covered_height`.
  `compact` writes a new base gen, commits the manifest (empty run list), then GCs the
  old base + folded run files. **`open()`** reloads base + runs from the manifest and
  exposes `covered_height`; the host replays blocks `> covered_height` via `put`/`endBlock`
  before serving. 2 recovery tests pass on a real ring (reopen with live runs; reopen
  after compaction); the durable boundary (frozen survives, memtable-only is lost) is
  asserted.
- **`src/flat_store.zig` — streaming compaction (budgeted, resumable).** Replaces the
  load-whole-base-into-RAM rebuild with a **streaming k-way merge** of the base
  (buffered sequential reader) + a snapshot of the L0 runs (newest-wins; base prio 0,
  run `i` prio `i+1`) into a new base built out-of-place, with the partition directory
  computed on the fly. `compactStep(byte_budget)` advances ≤ that many output bytes and
  returns `idle`/`in_progress`/`done`; resume is by key position, so one L0 compaction
  spreads over many idle windows under a per-window byte budget. Reads keep serving from
  old base + L0 until the final atomic manifest swap on `.done`; a freeze *during* a job
  appends a new run that the snapshot won't fold (survives to the next cycle). Memory is
  bounded (1 MiB read + 1 MiB write buffers + the new directory), not O(base). `compact`
  = run-to-completion; `compactionDue` is the host's advisory trigger. Compaction is no
  longer auto-run inside `freeze`. 2 new tests (multi-step budgeted; freeze-during-job
  snapshot) pass on a real ring.
- **WAF note (recorded):** under uniform thin writes a compaction still rewrites ~the
  whole base, so WAF ≈ `base / (K · flush)` — **streaming fixes memory + budgetability,
  not write volume.** But Ethereum's logical write rate is tiny (~64 KB/s), so even
  high WAF is modest in absolute bytes (e.g. K=64 ⇒ ~84× ⇒ ~5 MB/s ⇒ ~0.45 TB/day). `K`
  (`l0_compact_threshold`) is the WAF↔RAM dial; the default of 8 is a test value —
  production wants tens–hundreds. Skipping untouched data needs per-partition extents (a
  later option); prefix depth stays a single global parameter (uniform keys self-balance;
  global re-partition only if the whole set outgrows P).
- **`src/flat_store.zig` — deletes/tombstones.** `delete(key)` records a memtable
  tombstone (memtable is now `AutoHashMap(Key, ?Value)`, null = tombstone). On freeze,
  tombstones become `RunEntry{key,value,tomb}` in the L0 run, persisted in a 65-byte
  run record (`key||value||tomb`); the **base stays a pure 64-byte format** — tombstones
  never reach it because compaction's newest-wins merge *drops* a key whose newest
  source is a tombstone. Reads resolve a 3-state (`value`/`tombstone`/`miss`): a RAM
  tombstone short-circuits to null with no base read. Tombstones persist in run files,
  so recovery doesn't resurrect deleted keys. 3 tests (memtable delete + idempotent +
  re-put; shadow-base-then-drop-on-compaction; survive-recovery).
- **`src/flat_store.zig` — read-path perf fix (reusable scratch).** Originally `getMany`
  allocated the window slab + reqs/results/meta **per call**, sized `min(depth,batch) ×
  window_bytes` — i.e. ~64 KB *per key* below batch 256, through the slow `DebugAllocator`.
  That allocation (not disk, not the workload) dominated read latency: an *empty* DB —
  zero io_uring reads — still cost ~90 µs/get. Fix: allocate the scratch (slab sized
  `depth × window_entries × 64 B` ≈ 16 MiB, plus reqs/results/meta, and a grow-on-demand
  `unresolved_buf`) **once at open** and reuse it (the store is single-threaded). The C
  API (`flatdb_*`) also switched from `DebugAllocator` to `std.heap.smp_allocator`. Result
  (measured, keys served from base): per-op read latency went from 103/52/28 µs (batch
  1/4/64) to a **flat ~5 µs regardless of batch size**; the 120-block benchmark dropped
  3.65 s → 0.50 s (read latency 61.7 µs → 4.0 µs, throughput ~14.5K → ~105K ops/s).
  Batching now barely matters since the batch-scaling allocation is gone. The window size
  is still a fixed config (1024); making it configurable is below.
- **`src/flat_store.zig` — BAL prefetch + O_DIRECT.** With a Block Access List the whole
  block read set is known upfront, so `prefetch(keys)` issues it as **one batched
  io_uring pass** (queue depth up to the ring, hiding cold-NVMe latency that the
  interleaved per-write batches — effective QD ~4 — cannot), caching base values in a
  `prefetch_map`. The map is consulted in the merge **below L0** (`memtable → L0 →
  prefetch → base`), so writes during the block still shadow it — read-your-writes holds
  — and execution reads resolve from RAM with no per-read disk I/O. The map is cleared on
  each `prefetch` and on compaction (base change). `o_direct` (Config/`flatdb_open` flag)
  opens a separate O_DIRECT fd for hot reads so cold-read behaviour can be measured
  without a >RAM base; cold paths (compaction/recovery) keep the buffered fd. To satisfy
  O_DIRECT, windowed reads are now **page-aligned unconditionally** (read the covering
  pages, slice the window at `sub`), the scratch slab is 4 KiB-aligned, and base files are
  padded to a page. C API: `flatdb_prefetch` + `o_direct` arg on `flatdb_open`; Python:
  `FlatDB.prefetch` + `o_direct=`; benchmark: `--bal-prefetch` (prefetch the block read
  set, then execute from RAM) and `--o-direct`. 1 new test (prefetch read-your-writes) +
  1 (O_DIRECT aligned reads); 19 flat_store tests pass.
- **v1 limits / next:** (1) orphan-file GC on `open` (an abandoned job leaves an
  unreferenced base file). (2) directory-fsync for strict crash durability; optional
  `O_DIRECT`. (3) a min-heap merge if `K` grows large (linear per-record source scan
  today). (4) multi-file container packing + FD cache + multi-drive sharding (§6).
  (5) tune the window to ±4σ per-partition if partitions exceed ~65K; batch the fallback
  reads. (6) commitment integration via the per-batch dirty set (§0).
