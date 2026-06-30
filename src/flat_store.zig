//! Flat KV store — read + write + durability (docs/prefix_redesign.md §3–§5, §9).
//!
//! Tiers, newest→oldest:
//!   • active memtable — hash map of recent writes (O(1) point lookups).
//!   • L0 — N immutable sorted RAM runs (each a frozen memtable), also persisted to
//!     disk as `run` files for recovery.
//!   • base — on-disk sorted store, partitioned by the top `prefix_bits` of the key,
//!     read by interpolation + one windowed io_uring read (§3–§4).
//!
//! Durability (§9) exploits that blocks are externally durable, so writes are
//! *derivable* rather than logged. Three tiers of durability:
//!   • base   — must be durable: generation-suffixed file `name.base.<gen>`.
//!   • L0     — persisted at freeze (`name.run.<seq>`) so recovery replays few blocks;
//!              kept RAM-resident for exact, filter-free reads.
//!   • memtable — never durable: rebuilt by the host re-executing blocks > covered_height.
//! The **manifest** (`name.manifest`, written via temp+rename) is the atomic commit
//! point recording {base gen, live runs, covered_height}. There is no per-write WAL.
//!
//! Write path: `put` → memtable. `endBlock(height)` freezes at a block boundary when
//! the memtable is full or `freeze_block_interval` blocks have elapsed; `freeze` writes
//! the run file + commits the manifest; at `l0_compact_threshold` runs, `compact`
//! rebuilds the base out-of-place, commits the manifest, then drops the folded runs.
//! Recovery: `open` loads base + runs from the manifest and exposes `covered_height`;
//! the host replays blocks `> covered_height` via `put`/`endBlock` before serving.
//!
//! Not yet: streaming compaction (loads the whole base into RAM to rebuild),
//! deletes/tombstones, multi-file/FD-cache/multi-drive (§6), orphan-file GC on open.

const std = @import("std");
const t = @import("types.zig");
const uring = @import("uring_read.zig");
const Io = std.Io;
const linux = std.os.linux;

pub const RECORD_SIZE: usize = 64; // base on-disk record: key(32) || value(32)
/// L0 run on-disk record: key(32) || value(32) || tombstone(1). Runs (RAM-resident,
/// read by binary search) carry a tombstone flag; the base never does — tombstones are
/// resolved and dropped during compaction, so they never reach the base.
pub const RUN_RECORD_SIZE: usize = 65;
pub const WINDOW_ENTRIES_DEFAULT: u32 = 1024;
pub const MEMTABLE_CAP_DEFAULT: usize = 64 * 1024;
pub const L0_COMPACT_THRESHOLD_DEFAULT: usize = 8;
pub const FREEZE_BLOCK_INTERVAL_DEFAULT: u64 = 64;

const MANIFEST_MAGIC: u32 = 0x31_54_4C_46; // "FLT1"
const MANIFEST_VERSION: u32 = 1;

// Windowed base reads are page-aligned so they satisfy O_DIRECT (and are harmless
// without it). The slab and base files are aligned/padded to this boundary.
const PAGE_SIZE: usize = 4096;
const PAGE_ALIGN: std.mem.Alignment = .fromByteUnits(PAGE_SIZE);

inline fn alignDownPage(x: u64) u64 {
    return x & ~@as(u64, PAGE_SIZE - 1);
}
inline fn alignUpPage(x: usize) usize {
    return (x + (PAGE_SIZE - 1)) & ~@as(usize, PAGE_SIZE - 1);
}

pub const Config = struct {
    prefix_bits: u6,
    window_entries: u32 = 0, // 0 → default
    memtable_cap: usize = 0, // 0 → default
    l0_compact_threshold: usize = 0, // 0 → default
    freeze_block_interval: u64 = 0, // 0 → default
    o_direct: bool = false, // open the hot read fd with O_DIRECT (bypass page cache)
};

pub const Partition = struct {
    offset: u64,
    count: u32,
};

/// One entry in an L0 run: a value, or a tombstone (deletion marker).
const RunEntry = struct { key: t.Key, value: t.Value, tomb: bool };

/// Immutable sorted RAM run (one frozen memtable), entries sorted by key.
/// `seq` is its on-disk run-file sequence number.
const Run = struct {
    entries: []RunEntry,
    seq: u32,

    fn lookup(self: Run, key: *const t.Key) ?RunEntry {
        var lo: usize = 0;
        var hi: usize = self.entries.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            switch (std.mem.order(u8, &self.entries[mid].key, key)) {
                .eq => return self.entries[mid],
                .lt => lo = mid + 1,
                .gt => hi = mid,
            }
        }
        return null;
    }

    fn deinit(self: Run, allocator: std.mem.Allocator) void {
        allocator.free(self.entries);
    }
};

const SlotMeta = struct { gi: usize, w0: u32, w: u32, count: u32, part_off: u64, sub: usize };

/// Result of a RAM-tier (memtable + L0) lookup: a live value, a tombstone (key
/// deleted), or no entry in RAM (fall through to the base).
const Found = union(enum) { value: t.Value, tombstone, miss };

pub const CompactStatus = enum { idle, in_progress, done };

/// In-progress streaming-compaction job: a resumable k-way merge of the base +
/// a snapshot of the first `fold_count` L0 runs into a new base generation. Lives
/// in RAM only — a crash abandons it (the partial new base file is orphaned and
/// GC'd on `open`), and it restarts from scratch.
const Compaction = struct {
    new_gen: u32,
    new_file: Io.File, // new base being built (RDWR)
    write_buf: []u8,
    write_buf_len: usize,
    write_off: u64,
    new_dir: []Partition, // built incrementally as records are emitted
    out_count: u64,
    cur_pid: i64, // partition currently being filled (-1 = none)
    base_buf: []u8, // buffered sequential reader over the old base
    base_buf_len: usize,
    base_buf_pos: usize,
    base_loaded: u64, // records read from the base file so far
    base_total: u64,
    base_cur: ?t.KvEntry, // current head of the base cursor
    fold_count: usize, // L0 runs being folded (the front of l0 at job start)
    run_pos: []usize, // per-run entry cursor
};

/// On-disk manifest header (followed by `run_count` × RunRec).
const ManifestHeader = extern struct {
    magic: u32,
    version: u32,
    prefix_bits: u32,
    window_entries: u32,
    base_gen: u32,
    next_run_seq: u32,
    run_count: u32,
    _pad: u32 = 0,
    covered_height: u64,
    base_count: u64,
};
const RunRec = extern struct { seq: u32, entry_count: u32 };

/// Reusable read-path buffers, allocated once per store (see FlatStore scratch fields).
const Scratch = struct {
    slab: []align(PAGE_SIZE) u8, // page-aligned for O_DIRECT; `slot_size` bytes per slot
    reqs: []uring.Request,
    results: []uring.Result,
    meta: []SlotMeta,
    unresolved: []usize,
    pf_keys: []t.Key, // prefetch: keys that miss RAM
    pf_out: []?t.Value, // prefetch: their base values
};

fn allocScratch(allocator: std.mem.Allocator, depth: usize, slot_size: usize) !Scratch {
    const slab = try allocator.alignedAlloc(u8, PAGE_ALIGN, depth * slot_size);
    errdefer allocator.free(slab);
    const reqs = try allocator.alloc(uring.Request, depth);
    errdefer allocator.free(reqs);
    const results = try allocator.alloc(uring.Result, depth);
    errdefer allocator.free(results);
    const meta = try allocator.alloc(SlotMeta, depth);
    errdefer allocator.free(meta);
    const unresolved = try allocator.alloc(usize, 0);
    errdefer allocator.free(unresolved);
    const pf_keys = try allocator.alloc(t.Key, 0);
    errdefer allocator.free(pf_keys);
    const pf_out = try allocator.alloc(?t.Value, 0);
    return .{ .slab = slab, .reqs = reqs, .results = results, .meta = meta, .unresolved = unresolved, .pf_keys = pf_keys, .pf_out = pf_out };
}

fn freeScratch(allocator: std.mem.Allocator, s: Scratch) void {
    allocator.free(s.slab);
    allocator.free(s.reqs);
    allocator.free(s.results);
    allocator.free(s.meta);
    allocator.free(s.unresolved);
    allocator.free(s.pf_keys);
    allocator.free(s.pf_out);
}

pub const FlatStore = struct {
    allocator: std.mem.Allocator,
    io: Io,
    dir: Io.Dir,
    name: []const u8, // owned base name; actual files are name.{base.<gen>,run.<seq>,manifest}

    base_file: Io.File,
    base_gen: u32,
    directory: []Partition,
    prefix_bits: u6,
    window_entries: u32,
    reader: uring.Reader,

    memtable: std.AutoHashMap(t.Key, ?t.Value), // null value = tombstone
    memtable_cap: usize,
    l0: std.ArrayList(Run),
    next_run_seq: u32,
    l0_threshold: usize,
    freeze_block_interval: u64,

    /// Block height the durable state (base + persisted runs) reflects. The host must
    /// replay blocks `> covered_height` (via `put`/`endBlock`) after `open` before serving.
    covered_height: u64,

    /// Active streaming-compaction job, if any (RAM-only; abandoned on crash).
    job: ?Compaction = null,

    // Reusable read-path scratch, allocated once (single-threaded store) so getMany
    // does no per-call allocation. `scratch_slab` holds up to `reader.depth` windows.
    scratch_slab: []align(PAGE_SIZE) u8,
    slot_size: usize, // per-slot stride in scratch_slab (page-multiple, ≥ window + 1 page)
    scratch_reqs: []uring.Request,
    scratch_results: []uring.Result,
    scratch_meta: []SlotMeta,
    unresolved_buf: []usize, // grown on demand to the largest batch seen

    // O_DIRECT: when set, hot windowed reads use this fd (page cache bypassed), so the
    // benchmark can measure genuinely cold reads. Cold paths (compaction/recovery) keep
    // using the buffered `base_file`. null ⇒ reads go through base_file.handle.
    o_direct: bool,
    direct_fd: ?std.posix.fd_t,

    // BAL prefetch (§ block access lists): one batched base read of a block's read set,
    // cached here and consulted in the merge *below* L0 — `memtable → L0 → prefetch → base`
    // — so writes still shadow it (read-your-writes) while reads avoid re-hitting disk.
    prefetch_map: std.AutoHashMap(t.Key, ?t.Value), // value null = key absent in base
    pf_keys: []t.Key,
    pf_out: []?t.Value,

    // ─── Lifecycle ───────────────────────────────────────────────────────────────

    /// Create a fresh store: write base generation 0 from `entries`, commit a manifest,
    /// and start with an empty memtable / L0. Overwrites any existing store at `name`.
    pub fn create(
        allocator: std.mem.Allocator,
        io: Io,
        dir: Io.Dir,
        name: []const u8,
        entries: []const t.KvEntry,
        config: Config,
    ) !FlatStore {
        std.debug.assert(config.prefix_bits >= 1 and config.prefix_bits <= 32);
        std.debug.assert(name.len <= 200);

        var nb: [256]u8 = undefined;
        const bname = try fmtBase(&nb, name, 0);
        const directory = try buildBaseFile(allocator, io, dir, bname, entries, config.prefix_bits);
        errdefer allocator.free(directory);

        const base_file = try dir.openFile(io, bname, .{});
        errdefer base_file.close(io);

        var reader = try uring.Reader.init(uring.DEFAULT_QUEUE_DEPTH);
        errdefer reader.deinit();

        const name_copy = try allocator.dupe(u8, name);
        errdefer allocator.free(name_copy);

        const win_entries: usize = if (config.window_entries == 0) WINDOW_ENTRIES_DEFAULT else config.window_entries;
        const slot_size = alignUpPage(win_entries * RECORD_SIZE) + PAGE_SIZE; // window + 1 page of offset slop
        const sc = try allocScratch(allocator, reader.depth, slot_size);
        errdefer freeScratch(allocator, sc);

        const direct_fd: ?std.posix.fd_t = if (config.o_direct)
            try std.posix.openat(dir.handle, bname, .{ .ACCMODE = .RDONLY, .DIRECT = true }, 0)
        else
            null;
        errdefer if (direct_fd) |fd| { _ = linux.close(fd); };

        var store: FlatStore = .{
            .allocator = allocator,
            .io = io,
            .dir = dir,
            .name = name_copy,
            .base_file = base_file,
            .base_gen = 0,
            .directory = directory,
            .prefix_bits = config.prefix_bits,
            .window_entries = @intCast(win_entries),
            .reader = reader,
            .memtable = std.AutoHashMap(t.Key, ?t.Value).init(allocator),
            .memtable_cap = if (config.memtable_cap == 0) MEMTABLE_CAP_DEFAULT else config.memtable_cap,
            .l0 = .empty,
            .next_run_seq = 0,
            .l0_threshold = if (config.l0_compact_threshold == 0) L0_COMPACT_THRESHOLD_DEFAULT else config.l0_compact_threshold,
            .freeze_block_interval = if (config.freeze_block_interval == 0) FREEZE_BLOCK_INTERVAL_DEFAULT else config.freeze_block_interval,
            .covered_height = 0,
            .scratch_slab = sc.slab,
            .slot_size = slot_size,
            .scratch_reqs = sc.reqs,
            .scratch_results = sc.results,
            .scratch_meta = sc.meta,
            .unresolved_buf = sc.unresolved,
            .o_direct = config.o_direct,
            .direct_fd = direct_fd,
            .prefetch_map = std.AutoHashMap(t.Key, ?t.Value).init(allocator),
            .pf_keys = sc.pf_keys,
            .pf_out = sc.pf_out,
        };
        try store.writeManifest();
        return store;
    }

    /// Recover an existing store from its manifest: load base generation + all live runs
    /// into RAM. `covered_height` is set from the manifest; the caller replays newer blocks.
    /// Structural params (prefix_bits, window) come from the manifest; policy params
    /// (memtable_cap, thresholds) from `config`.
    pub fn open(
        allocator: std.mem.Allocator,
        io: Io,
        dir: Io.Dir,
        name: []const u8,
        config: Config,
    ) !FlatStore {
        std.debug.assert(name.len <= 200);
        const m = try readManifest(allocator, io, dir, name);
        defer allocator.free(m.runs);
        const prefix_bits: u6 = @intCast(m.header.prefix_bits);

        var nb: [256]u8 = undefined;
        const bname = try fmtBase(&nb, name, m.header.base_gen);
        const base_file = try dir.openFile(io, bname, .{});
        errdefer base_file.close(io);

        // Recompute the partition directory by scanning the (sorted) base records.
        const base_records = try readRecords(allocator, io, base_file, @intCast(m.header.base_count));
        defer allocator.free(base_records);
        const directory = try directoryFromEntries(allocator, base_records, prefix_bits);
        errdefer allocator.free(directory);

        var l0: std.ArrayList(Run) = .empty;
        errdefer {
            for (l0.items) |run| run.deinit(allocator);
            l0.deinit(allocator);
        }
        for (m.runs) |rr| {
            var rb: [256]u8 = undefined;
            const rname = try fmtRun(&rb, name, rr.seq);
            const rf = try dir.openFile(io, rname, .{});
            defer rf.close(io);
            const entries = try readRunFile(allocator, io, rf, rr.entry_count);
            try l0.append(allocator, .{ .entries = entries, .seq = rr.seq });
        }

        var reader = try uring.Reader.init(uring.DEFAULT_QUEUE_DEPTH);
        errdefer reader.deinit();
        const name_copy = try allocator.dupe(u8, name);
        errdefer allocator.free(name_copy);

        const slot_size = alignUpPage(@as(usize, m.header.window_entries) * RECORD_SIZE) + PAGE_SIZE;
        const sc = try allocScratch(allocator, reader.depth, slot_size);
        errdefer freeScratch(allocator, sc);

        const direct_fd: ?std.posix.fd_t = if (config.o_direct)
            try std.posix.openat(dir.handle, bname, .{ .ACCMODE = .RDONLY, .DIRECT = true }, 0)
        else
            null;
        errdefer if (direct_fd) |fd| { _ = linux.close(fd); };

        return .{
            .allocator = allocator,
            .io = io,
            .dir = dir,
            .name = name_copy,
            .base_file = base_file,
            .base_gen = m.header.base_gen,
            .directory = directory,
            .prefix_bits = prefix_bits,
            .window_entries = m.header.window_entries,
            .reader = reader,
            .memtable = std.AutoHashMap(t.Key, ?t.Value).init(allocator),
            .memtable_cap = if (config.memtable_cap == 0) MEMTABLE_CAP_DEFAULT else config.memtable_cap,
            .l0 = l0,
            .next_run_seq = m.header.next_run_seq,
            .l0_threshold = if (config.l0_compact_threshold == 0) L0_COMPACT_THRESHOLD_DEFAULT else config.l0_compact_threshold,
            .freeze_block_interval = if (config.freeze_block_interval == 0) FREEZE_BLOCK_INTERVAL_DEFAULT else config.freeze_block_interval,
            .covered_height = m.header.covered_height,
            .scratch_slab = sc.slab,
            .slot_size = slot_size,
            .scratch_reqs = sc.reqs,
            .scratch_results = sc.results,
            .scratch_meta = sc.meta,
            .unresolved_buf = sc.unresolved,
            .o_direct = config.o_direct,
            .direct_fd = direct_fd,
            .prefetch_map = std.AutoHashMap(t.Key, ?t.Value).init(allocator),
            .pf_keys = sc.pf_keys,
            .pf_out = sc.pf_out,
        };
    }

    /// fd used for hot windowed reads: the O_DIRECT fd if enabled, else the base file.
    fn hotFd(self: *const FlatStore) std.posix.fd_t {
        return self.direct_fd orelse self.base_file.handle;
    }

    /// (Re)open the O_DIRECT fd for the current base generation.
    fn openDirectFd(self: *FlatStore) !std.posix.fd_t {
        var nb: [256]u8 = undefined;
        const bname = try fmtBase(&nb, self.name, self.base_gen);
        return std.posix.openat(self.dir.handle, bname, .{ .ACCMODE = .RDONLY, .DIRECT = true }, 0);
    }

    pub fn deinit(self: *FlatStore) void {
        if (self.direct_fd) |fd| {
            _ = linux.close(fd);
        }
        if (self.job) |*job| {
            job.new_file.close(self.io);
            self.allocator.free(job.new_dir);
            self.allocator.free(job.write_buf);
            self.allocator.free(job.base_buf);
            self.allocator.free(job.run_pos);
        }
        self.reader.deinit();
        self.base_file.close(self.io);
        self.memtable.deinit();
        for (self.l0.items) |run| run.deinit(self.allocator);
        self.l0.deinit(self.allocator);
        self.allocator.free(self.directory);
        self.allocator.free(self.name);
        self.prefetch_map.deinit();
        freeScratch(self.allocator, .{
            .slab = self.scratch_slab,
            .reqs = self.scratch_reqs,
            .results = self.scratch_results,
            .meta = self.scratch_meta,
            .unresolved = self.unresolved_buf,
            .pf_keys = self.pf_keys,
            .pf_out = self.pf_out,
        });
    }

    // ─── Write path ────────────────────────────────────────────────────────────

    /// Insert or overwrite (key, value) into the active memtable. Single write entry
    /// point — freezing happens at block boundaries via `endBlock`, never mid-block.
    pub fn put(self: *FlatStore, key: t.Key, value: t.Value) !void {
        try self.memtable.put(key, value);
    }

    /// Delete `key`: records a tombstone in the memtable that shadows any older value
    /// in L0 / base until compaction drops both. Idempotent (no-op semantics if absent).
    pub fn delete(self: *FlatStore, key: t.Key) !void {
        try self.memtable.put(key, null);
    }

    /// Signal the end of block `height`. Freezes the memtable (and may compact) when it
    /// is full or `freeze_block_interval` blocks have elapsed since the last freeze.
    pub fn endBlock(self: *FlatStore, height: u64) !void {
        if (self.memtable.count() == 0) return;
        const due = self.memtable.count() >= self.memtable_cap or
            (height -| self.covered_height) >= self.freeze_block_interval;
        if (due) try self.freeze(height);
    }

    /// Sort the active memtable into an immutable run, persist it, commit the manifest,
    /// advance `covered_height` to `height`, and auto-compact if L0 is full. No-op on
    /// an empty memtable. `height` is the block height the frozen writes cover.
    pub fn freeze(self: *FlatStore, height: u64) !void {
        const n = self.memtable.count();
        if (n == 0) return;
        const a = self.allocator;

        const entries = try a.alloc(RunEntry, n);
        {
            var it = self.memtable.iterator();
            var i: usize = 0;
            while (it.next()) |kv| : (i += 1) entries[i] = .{
                .key = kv.key_ptr.*,
                .value = kv.value_ptr.* orelse std.mem.zeroes(t.Value),
                .tomb = kv.value_ptr.* == null,
            };
        }
        std.mem.sort(RunEntry, entries, {}, runLessThan);

        const seq = self.next_run_seq;
        self.writeRunFile(seq, entries) catch |e| {
            a.free(entries);
            return e;
        };
        self.l0.append(a, .{ .entries = entries, .seq = seq }) catch |e| {
            a.free(entries);
            return e;
        };

        self.next_run_seq += 1;
        self.memtable.clearRetainingCapacity();
        self.covered_height = height;
        try self.writeManifest(); // commit
        // Compaction is host-driven via `compactStep` in idle windows, not here —
        // see `compactionDue`.
    }

    /// Whether a compaction is in progress, or L0 has reached the threshold. Advisory:
    /// the host decides when to spend an idle-window budget on `compactStep`.
    pub fn compactionDue(self: *const FlatStore) bool {
        return self.job != null or self.l0.items.len >= self.l0_threshold;
    }

    /// Run a compaction to completion in one call (unbudgeted) — convenience over
    /// `compactStep`. Folds all current L0 runs into a new base generation.
    pub fn compact(self: *FlatStore) !void {
        while (true) {
            if (try self.compactStep(std.math.maxInt(usize)) != .in_progress) break;
        }
    }

    /// Advance compaction by at most `byte_budget` bytes of new-base output, then
    /// return. Starts a job (snapshotting the current L0 runs) when none is active and
    /// L0 is non-empty. A streaming k-way merge of base + runs (newest-wins) builds a
    /// new base out-of-place, resumable across calls by key position — so one L0
    /// compaction can be spread over many idle windows. Reads keep serving from the old
    /// base + L0 until the final atomic swap, returned as `.done`.
    pub fn compactStep(self: *FlatStore, byte_budget: usize) !CompactStatus {
        if (self.job == null) {
            if (self.l0.items.len == 0) return .idle;
            try self.startCompaction();
        }
        if (try self.runMerge(byte_budget)) {
            try self.finishCompaction();
            return .done;
        }
        return .in_progress;
    }

    fn startCompaction(self: *FlatStore) !void {
        const a = self.allocator;
        const new_gen = self.base_gen + 1;
        var nb: [256]u8 = undefined;
        const bname = try fmtBase(&nb, self.name, new_gen);

        const new_file = try self.dir.createFile(self.io, bname, .{ .read = true, .truncate = true });
        errdefer new_file.close(self.io);
        const new_dir = try a.alloc(Partition, @as(usize, 1) << self.prefix_bits);
        errdefer a.free(new_dir);
        for (new_dir) |*d| d.* = .{ .offset = 0, .count = 0 };
        const fold = self.l0.items.len;
        const run_pos = try a.alloc(usize, fold);
        errdefer a.free(run_pos);
        @memset(run_pos, 0);
        const base_buf = try a.alloc(u8, 1 << 20);
        errdefer a.free(base_buf);
        const write_buf = try a.alloc(u8, 1 << 20);
        errdefer a.free(write_buf);

        var job: Compaction = .{
            .new_gen = new_gen,
            .new_file = new_file,
            .write_buf = write_buf,
            .write_buf_len = 0,
            .write_off = 0,
            .new_dir = new_dir,
            .out_count = 0,
            .cur_pid = -1,
            .base_buf = base_buf,
            .base_buf_len = 0,
            .base_buf_pos = 0,
            .base_loaded = 0,
            .base_total = sumCounts(self.directory),
            .base_cur = null,
            .fold_count = fold,
            .run_pos = run_pos,
        };
        try self.advanceBase(&job); // prime the base cursor
        self.job = job; // ownership transferred; no error path past here
    }

    /// Emit merged records until `byte_budget` is reached or the sources are exhausted.
    /// Returns true once the merge is complete.
    fn runMerge(self: *FlatStore, byte_budget: usize) !bool {
        const job = &self.job.?;
        var produced: usize = 0;
        var done = false;
        while (produced < byte_budget) {
            // Smallest key across the base cursor and all run cursors.
            var have_min = false;
            var mk: [32]u8 = undefined;
            if (job.base_cur) |bc| {
                mk = bc.key;
                have_min = true;
            }
            for (0..job.fold_count) |i| {
                const ents = self.l0.items[i].entries;
                const rp = job.run_pos[i];
                if (rp < ents.len and (!have_min or std.mem.order(u8, &ents[rp].key, &mk) == .lt)) {
                    mk = ents[rp].key;
                    have_min = true;
                }
            }
            if (!have_min) {
                done = true;
                break;
            }
            // Newest entry among sources holding `mk`; advance every source at `mk`.
            // Priority: base = 0 (oldest), run i = i+1 (later runs newer). The base
            // never holds tombstones; a winning run-tombstone drops the key.
            var best_val: t.Value = undefined;
            var best_tomb = false;
            var best_pri: i64 = -1;
            if (job.base_cur) |bc| {
                if (std.mem.eql(u8, &bc.key, &mk)) {
                    best_val = bc.value;
                    best_tomb = false;
                    best_pri = 0;
                    try self.advanceBase(job);
                }
            }
            for (0..job.fold_count) |i| {
                const ents = self.l0.items[i].entries;
                const rp = job.run_pos[i];
                if (rp < ents.len and std.mem.eql(u8, &ents[rp].key, &mk)) {
                    const pri: i64 = @intCast(i + 1);
                    if (pri > best_pri) {
                        best_val = ents[rp].value;
                        best_tomb = ents[rp].tomb;
                        best_pri = pri;
                    }
                    job.run_pos[i] = rp + 1;
                }
            }
            if (!best_tomb) try self.emit(job, &mk, &best_val); // tombstone ⇒ key dropped
            produced += RECORD_SIZE;
        }
        try self.flushWrite(job);
        return done;
    }

    fn emit(self: *FlatStore, job: *Compaction, key: *const t.Key, value: *const t.Value) !void {
        const pid = partitionOf(key, self.prefix_bits);
        if (@as(i64, @intCast(pid)) != job.cur_pid) {
            job.new_dir[pid].offset = job.out_count * RECORD_SIZE;
            job.cur_pid = @intCast(pid);
        }
        job.new_dir[pid].count += 1;
        job.out_count += 1;
        if (job.write_buf_len + RECORD_SIZE > job.write_buf.len) try self.flushWrite(job);
        @memcpy(job.write_buf[job.write_buf_len ..][0..32], key);
        @memcpy(job.write_buf[job.write_buf_len + 32 ..][0..32], value);
        job.write_buf_len += RECORD_SIZE;
    }

    fn flushWrite(self: *FlatStore, job: *Compaction) !void {
        if (job.write_buf_len == 0) return;
        try job.new_file.writePositionalAll(self.io, job.write_buf[0..job.write_buf_len], job.write_off);
        job.write_off += job.write_buf_len;
        job.write_buf_len = 0;
    }

    fn advanceBase(self: *FlatStore, job: *Compaction) !void {
        if (job.base_buf_pos >= job.base_buf_len) {
            const remaining = job.base_total - job.base_loaded;
            if (remaining == 0) {
                job.base_cur = null;
                return;
            }
            const want_recs = @min(remaining, @as(u64, job.base_buf.len / RECORD_SIZE));
            const want: usize = @intCast(want_recs * RECORD_SIZE);
            const got = try self.base_file.readPositionalAll(self.io, job.base_buf[0..want], job.base_loaded * RECORD_SIZE);
            if (got != want) return error.BaseTruncated;
            job.base_loaded += want_recs;
            job.base_buf_len = want;
            job.base_buf_pos = 0;
        }
        var e: t.KvEntry = undefined;
        @memcpy(&e.key, job.base_buf[job.base_buf_pos ..][0..32]);
        @memcpy(&e.value, job.base_buf[job.base_buf_pos + 32 ..][0..32]);
        job.base_buf_pos += RECORD_SIZE;
        job.base_cur = e;
    }

    fn finishCompaction(self: *FlatStore) !void {
        const a = self.allocator;
        try self.flushWrite(&self.job.?);
        // Pad the new base to a page multiple so O_DIRECT full-block reads stay in-file.
        {
            const real: usize = @intCast(self.job.?.write_off);
            const padded = alignUpPage(real);
            if (padded > real) {
                const zeros = [_]u8{0} ** PAGE_SIZE;
                try self.job.?.new_file.writePositionalAll(self.io, zeros[0 .. padded - real], self.job.?.write_off);
            }
        }
        try self.job.?.new_file.sync(self.io);

        const job = self.job.?;
        const old_gen = self.base_gen;
        const folded = job.fold_count;
        const remaining = self.l0.items.len - folded;

        var folded_seqs = try a.alloc(u32, folded);
        defer a.free(folded_seqs);
        for (0..folded) |i| folded_seqs[i] = self.l0.items[i].seq;
        const recs = try a.alloc(RunRec, remaining);
        defer a.free(recs);
        for (0..remaining) |i| {
            const r = self.l0.items[folded + i];
            recs[i] = .{ .seq = r.seq, .entry_count = @intCast(r.entries.len) };
        }

        // Commit point: manifest now references the new base + the un-folded runs.
        try self.writeManifestRaw(job.new_gen, self.covered_height, job.out_count, recs);

        // Past the commit — infallible.
        self.base_file.close(self.io);
        self.base_file = job.new_file;
        a.free(self.directory);
        self.directory = job.new_dir;
        self.base_gen = job.new_gen;

        // Re-point the O_DIRECT fd at the new base generation (buffered fallback on failure).
        if (self.o_direct) {
            if (self.direct_fd) |fd| {
            _ = linux.close(fd);
        }
            self.direct_fd = self.openDirectFd() catch null;
        }

        for (0..folded) |i| self.l0.items[i].deinit(a);
        std.mem.copyForwards(Run, self.l0.items[0..remaining], self.l0.items[folded .. folded + remaining]);
        self.l0.shrinkRetainingCapacity(remaining);

        // Base changed — any prefetched base values are now stale.
        self.prefetch_map.clearRetainingCapacity();

        a.free(job.write_buf);
        a.free(job.base_buf);
        a.free(job.run_pos);
        self.job = null;

        // Best-effort GC of the superseded files.
        var ob: [256]u8 = undefined;
        if (fmtBase(&ob, self.name, old_gen)) |on| self.dir.deleteFile(self.io, on) catch {} else |_| {}
        for (folded_seqs) |s| {
            var rb: [256]u8 = undefined;
            if (fmtRun(&rb, self.name, s)) |rn| self.dir.deleteFile(self.io, rn) catch {} else |_| {}
        }
    }

    fn writeRunFile(self: *FlatStore, seq: u32, entries: []const RunEntry) !void {
        const a = self.allocator;
        var rb: [256]u8 = undefined;
        const rname = try fmtRun(&rb, self.name, seq);
        const data = try a.alloc(u8, entries.len * RUN_RECORD_SIZE);
        defer a.free(data);
        for (entries, 0..) |e, i| {
            @memcpy(data[i * RUN_RECORD_SIZE ..][0..32], &e.key);
            @memcpy(data[i * RUN_RECORD_SIZE + 32 ..][0..32], &e.value);
            data[i * RUN_RECORD_SIZE + 64] = @intFromBool(e.tomb);
        }
        const wf = try self.dir.createFile(self.io, rname, .{ .truncate = true });
        defer wf.close(self.io);
        if (data.len > 0) try wf.writePositionalAll(self.io, data, 0);
        try wf.sync(self.io);
    }

    // ─── Manifest ────────────────────────────────────────────────────────────────

    fn writeManifest(self: *FlatStore) !void {
        const a = self.allocator;
        const recs = try a.alloc(RunRec, self.l0.items.len);
        defer a.free(recs);
        for (self.l0.items, 0..) |run, i| recs[i] = .{ .seq = run.seq, .entry_count = @intCast(run.entries.len) };
        try self.writeManifestRaw(self.base_gen, self.covered_height, sumCounts(self.directory), recs);
    }

    fn writeManifestRaw(self: *FlatStore, base_gen: u32, covered_height: u64, base_count: u64, runs: []const RunRec) !void {
        try writeManifestFile(self.io, self.dir, self.name, self.prefix_bits, self.window_entries, base_gen, self.next_run_seq, covered_height, base_count, runs);
    }

    const ManifestData = struct { header: ManifestHeader, runs: []RunRec };

    fn readManifest(allocator: std.mem.Allocator, io: Io, dir: Io.Dir, name: []const u8) !ManifestData {
        var mb: [256]u8 = undefined;
        const mname = try fmtManifest(&mb, name);
        const f = try dir.openFile(io, mname, .{});
        defer f.close(io);

        var hdr: ManifestHeader = undefined;
        const hn = try f.readPositionalAll(io, std.mem.asBytes(&hdr), 0);
        if (hn != @sizeOf(ManifestHeader)) return error.ManifestTruncated;
        if (hdr.magic != MANIFEST_MAGIC) return error.ManifestBadMagic;
        if (hdr.version != MANIFEST_VERSION) return error.ManifestVersionMismatch;

        const runs = try allocator.alloc(RunRec, hdr.run_count);
        errdefer allocator.free(runs);
        if (runs.len > 0) {
            const rn = try f.readPositionalAll(io, std.mem.sliceAsBytes(runs), @sizeOf(ManifestHeader));
            if (rn != runs.len * @sizeOf(RunRec)) return error.ManifestTruncated;
        }
        return .{ .header = hdr, .runs = runs };
    }

    // ─── Read path ─────────────────────────────────────────────────────────────

    pub fn get(self: *FlatStore, key: t.Key) !?t.Value {
        var ks = [_]t.Key{key};
        var out = [_]?t.Value{null};
        try self.getMany(&ks, &out);
        return out[0];
    }

    /// Batched lookup, newest-wins: memtable → L0 (newest→oldest) → base. RAM tiers
    /// resolve in-process; only keys missing from RAM hit the base, batched per ring chunk.
    pub fn getMany(self: *FlatStore, keys: []const t.Key, out: []?t.Value) !void {
        std.debug.assert(keys.len == out.len);
        if (keys.len == 0) return;

        // Grow the reusable unresolved buffer only when a larger batch arrives.
        if (self.unresolved_buf.len < keys.len) {
            self.allocator.free(self.unresolved_buf);
            self.unresolved_buf = try self.allocator.alloc(usize, keys.len);
        }
        const unresolved = self.unresolved_buf;
        var nun: usize = 0;
        for (keys, 0..) |key, gi| {
            switch (self.lookupRam(&key)) {
                .value => |v| out[gi] = v,
                .tombstone => out[gi] = null, // deleted in RAM — no base read
                .miss => {
                    // Below L0: a prefetched base value (or known-absent) resolves here
                    // without a disk read; writes in memtable/L0 already took precedence.
                    if (self.prefetch_map.get(key)) |pv| {
                        out[gi] = pv;
                    } else {
                        unresolved[nun] = gi;
                        nun += 1;
                    }
                },
            }
        }
        try self.lookupBase(unresolved[0..nun], keys, out);
    }

    /// Warm the prefetch map with the base values of `keys` (a block's read set, from a
    /// Block Access List) in one batched io_uring pass. Keys already resolvable in RAM
    /// (memtable/L0) are skipped — their reads hit RAM. Subsequent `get`/`getMany` then
    /// resolve these keys from the map (below L0) with no per-read disk I/O, while writes
    /// during the block still shadow them via the memtable. Replaces the previous map.
    pub fn prefetch(self: *FlatStore, keys: []const t.Key) !void {
        self.prefetch_map.clearRetainingCapacity();
        if (keys.len == 0) return;

        if (self.pf_keys.len < keys.len) {
            self.allocator.free(self.pf_keys);
            self.pf_keys = try self.allocator.alloc(t.Key, keys.len);
        }
        if (self.pf_out.len < keys.len) {
            self.allocator.free(self.pf_out);
            self.pf_out = try self.allocator.alloc(?t.Value, keys.len);
        }
        if (self.unresolved_buf.len < keys.len) {
            self.allocator.free(self.unresolved_buf);
            self.unresolved_buf = try self.allocator.alloc(usize, keys.len);
        }

        var n: usize = 0;
        for (keys) |key| {
            switch (self.lookupRam(&key)) {
                .miss => {},
                else => continue, // resolves from RAM at read time; no prefetch needed
            }
            self.pf_keys[n] = key;
            self.unresolved_buf[n] = n; // identity index into pf_keys/pf_out
            n += 1;
        }
        if (n == 0) return;

        try self.lookupBase(self.unresolved_buf[0..n], self.pf_keys[0..n], self.pf_out[0..n]);
        for (0..n) |i| try self.prefetch_map.put(self.pf_keys[i], self.pf_out[i]);
    }

    /// Resolve a key against the RAM tiers, newest first: memtable then L0 runs.
    fn lookupRam(self: *FlatStore, key: *const t.Key) Found {
        if (self.memtable.get(key.*)) |maybe| return if (maybe) |v| .{ .value = v } else .tombstone;
        var i = self.l0.items.len;
        while (i > 0) {
            i -= 1;
            if (self.l0.items[i].lookup(key)) |e| return if (e.tomb) .tombstone else .{ .value = e.value };
        }
        return .miss;
    }

    fn lookupBase(self: *FlatStore, idxs: []const usize, keys: []const t.Key, out: []?t.Value) !void {
        if (idxs.len == 0) return;

        const fd = self.hotFd();
        const depth: usize = self.reader.depth; // scratch buffers are sized to `depth`

        var base: usize = 0;
        while (base < idxs.len) {
            const chunk = @min(idxs.len - base, depth);

            var nreq: usize = 0;
            for (0..chunk) |k| {
                const gi = idxs[base + k];
                const pid = partitionOf(&keys[gi], self.prefix_bits);
                const part = self.directory[pid];
                if (part.count == 0) {
                    out[gi] = null;
                    continue;
                }
                const w: u64 = @min(@as(u64, self.window_entries), part.count);
                const rank = interpRank(&keys[gi], self.prefix_bits, part.count);
                var w0: u64 = if (rank >= w / 2) rank - w / 2 else 0;
                if (w0 + w > part.count) w0 = part.count - w;

                // Page-align the read (covers the window + ≤1 page of leading slop) so it
                // satisfies O_DIRECT; the window starts `sub` bytes into the read.
                const w_start = part.offset + w0 * RECORD_SIZE;
                const page_start = alignDownPage(w_start);
                const sub: usize = @intCast(w_start - page_start);
                const read_len = alignUpPage(sub + @as(usize, @intCast(w)) * RECORD_SIZE);

                const slot = nreq;
                self.scratch_reqs[slot] = .{
                    .fd = fd,
                    .buffer = self.scratch_slab[slot * self.slot_size ..][0..read_len],
                    .offset = page_start,
                };
                self.scratch_meta[slot] = .{ .gi = gi, .w0 = @intCast(w0), .w = @intCast(w), .count = part.count, .part_off = part.offset, .sub = sub };
                nreq += 1;
            }
            if (nreq == 0) {
                base += chunk;
                continue;
            }

            try self.reader.readBatch(self.scratch_reqs[0..nreq], self.scratch_results[0..nreq]);

            for (0..nreq) |slot| {
                const m = self.scratch_meta[slot];
                _ = try self.scratch_results[slot]; // propagate I/O errors; window is within the read
                const buf = self.scratch_slab[slot * self.slot_size + m.sub ..][0 .. @as(usize, m.w) * RECORD_SIZE];
                if (locate(buf, &keys[m.gi])) |v| {
                    out[m.gi] = v;
                } else if (windowIsDefinitive(buf, m, &keys[m.gi])) {
                    out[m.gi] = null;
                } else {
                    out[m.gi] = try self.fallbackLookup(m, &keys[m.gi]);
                }
            }

            base += chunk;
        }
    }

    fn fallbackLookup(self: *FlatStore, m: SlotMeta, key: *const t.Key) !?t.Value {
        // Page-align the whole-partition read for O_DIRECT (rare path; allocates per call).
        const page_start = alignDownPage(m.part_off);
        const sub: usize = @intCast(m.part_off - page_start);
        const part_bytes = @as(usize, m.count) * RECORD_SIZE;
        const read_len = alignUpPage(sub + part_bytes);
        const buf = try self.allocator.alignedAlloc(u8, PAGE_ALIGN, read_len);
        defer self.allocator.free(buf);
        var req = [_]uring.Request{.{ .fd = self.hotFd(), .buffer = buf, .offset = page_start }};
        var res = [_]uring.Result{undefined};
        try self.reader.readBatch(&req, &res);
        _ = try res[0];
        return locate(buf[sub..][0..part_bytes], key);
    }
};

/// Write `name.manifest` atomically (temp + rename). Shared by FlatStore and BaseBuilder.
fn writeManifestFile(
    io: Io,
    dir: Io.Dir,
    name: []const u8,
    prefix_bits: u6,
    window_entries: u32,
    base_gen: u32,
    next_run_seq: u32,
    covered_height: u64,
    base_count: u64,
    runs: []const RunRec,
) !void {
    const hdr: ManifestHeader = .{
        .magic = MANIFEST_MAGIC,
        .version = MANIFEST_VERSION,
        .prefix_bits = prefix_bits,
        .window_entries = window_entries,
        .base_gen = base_gen,
        .next_run_seq = next_run_seq,
        .run_count = @intCast(runs.len),
        .covered_height = covered_height,
        .base_count = base_count,
    };
    var tb: [256]u8 = undefined;
    const tmp = try fmtManifestTmp(&tb, name);
    {
        const wf = try dir.createFile(io, tmp, .{ .truncate = true });
        defer wf.close(io);
        try wf.writePositionalAll(io, std.mem.asBytes(&hdr), 0);
        if (runs.len > 0)
            try wf.writePositionalAll(io, std.mem.sliceAsBytes(runs), @sizeOf(ManifestHeader));
        try wf.sync(io);
    }
    var mb: [256]u8 = undefined;
    const mname = try fmtManifest(&mb, name);
    try dir.rename(tmp, dir, mname, io);
}

/// Streaming builder for a fresh FlatStore base from a globally key-sorted record
/// stream — for bulk loading without holding the dataset in RAM. Feed records in
/// ascending key order (deduplicated); it writes the base file + partition directory,
/// pads to a page, and commits a manifest (generation 0, no L0 runs). The resulting
/// store is then opened with `FlatStore.open`.
pub const BaseBuilder = struct {
    allocator: std.mem.Allocator,
    io: Io,
    dir: Io.Dir,
    name: []const u8,
    prefix_bits: u6,
    window_entries: u32,
    file: Io.File,
    directory: []Partition,
    out_count: u64,
    cur_pid: i64,
    write_buf: []u8,
    write_buf_len: usize,
    write_off: u64,

    pub fn init(
        allocator: std.mem.Allocator,
        io: Io,
        dir: Io.Dir,
        name: []const u8,
        prefix_bits: u6,
        window_entries: u32,
    ) !BaseBuilder {
        std.debug.assert(prefix_bits >= 1 and prefix_bits <= 32);
        var nb: [256]u8 = undefined;
        const bname = try fmtBase(&nb, name, 0);
        const file = try dir.createFile(io, bname, .{ .truncate = true });
        errdefer file.close(io);
        const directory = try allocator.alloc(Partition, @as(usize, 1) << prefix_bits);
        errdefer allocator.free(directory);
        for (directory) |*d| d.* = .{ .offset = 0, .count = 0 };
        const write_buf = try allocator.alloc(u8, 1 << 20);
        return .{
            .allocator = allocator,
            .io = io,
            .dir = dir,
            .name = name,
            .prefix_bits = prefix_bits,
            .window_entries = if (window_entries == 0) WINDOW_ENTRIES_DEFAULT else window_entries,
            .file = file,
            .directory = directory,
            .out_count = 0,
            .cur_pid = -1,
            .write_buf = write_buf,
            .write_buf_len = 0,
            .write_off = 0,
        };
    }

    /// Append one record. Keys MUST arrive in ascending order, deduplicated.
    pub fn feed(self: *BaseBuilder, key: *const t.Key, value: *const t.Value) !void {
        const pid = partitionOf(key, self.prefix_bits);
        if (@as(i64, @intCast(pid)) != self.cur_pid) {
            self.directory[pid].offset = self.out_count * RECORD_SIZE;
            self.cur_pid = @intCast(pid);
        }
        self.directory[pid].count += 1;
        self.out_count += 1;
        if (self.write_buf_len + RECORD_SIZE > self.write_buf.len) try self.flushBuf();
        @memcpy(self.write_buf[self.write_buf_len ..][0..32], key);
        @memcpy(self.write_buf[self.write_buf_len + 32 ..][0..32], value);
        self.write_buf_len += RECORD_SIZE;
    }

    fn flushBuf(self: *BaseBuilder) !void {
        if (self.write_buf_len == 0) return;
        try self.file.writePositionalAll(self.io, self.write_buf[0..self.write_buf_len], self.write_off);
        self.write_off += self.write_buf_len;
        self.write_buf_len = 0;
    }

    /// Flush, pad to a page, fsync, and commit the manifest. The file stays open
    /// until `deinit`.
    pub fn finish(self: *BaseBuilder, covered_height: u64) !void {
        try self.flushBuf();
        const real: usize = @intCast(self.write_off);
        const padded = alignUpPage(real);
        if (padded > real) {
            const zeros = [_]u8{0} ** PAGE_SIZE;
            try self.file.writePositionalAll(self.io, zeros[0 .. padded - real], self.write_off);
        }
        try self.file.sync(self.io);
        try writeManifestFile(self.io, self.dir, self.name, self.prefix_bits, self.window_entries, 0, 0, covered_height, self.out_count, &.{});
    }

    pub fn deinit(self: *BaseBuilder) void {
        self.file.close(self.io);
        self.allocator.free(self.directory);
        self.allocator.free(self.write_buf);
    }
};

// ─── File-name helpers ────────────────────────────────────────────────────────

fn fmtBase(buf: []u8, name: []const u8, gen: u32) ![]const u8 {
    return std.fmt.bufPrint(buf, "{s}.base.{d}", .{ name, gen });
}
fn fmtRun(buf: []u8, name: []const u8, seq: u32) ![]const u8 {
    return std.fmt.bufPrint(buf, "{s}.run.{d}", .{ name, seq });
}
fn fmtManifest(buf: []u8, name: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "{s}.manifest", .{name});
}
fn fmtManifestTmp(buf: []u8, name: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "{s}.manifest.tmp", .{name});
}

// ─── Base file construction / parsing ─────────────────────────────────────────

fn sumCounts(directory: []const Partition) u64 {
    var s: u64 = 0;
    for (directory) |p| s += p.count;
    return s;
}

fn serialize(entries: []const t.KvEntry, data: []u8) void {
    for (entries, 0..) |e, i| {
        @memcpy(data[i * RECORD_SIZE ..][0..32], &e.key);
        @memcpy(data[i * RECORD_SIZE + 32 ..][0..32], &e.value);
    }
}

/// Read `count` 64-byte base records from `file` into freshly-allocated KvEntries.
fn readRecords(allocator: std.mem.Allocator, io: Io, file: Io.File, count: usize) ![]t.KvEntry {
    const entries = try allocator.alloc(t.KvEntry, count);
    errdefer allocator.free(entries);
    if (count == 0) return entries;
    const buf = try allocator.alloc(u8, count * RECORD_SIZE);
    defer allocator.free(buf);
    const got = try file.readPositionalAll(io, buf, 0);
    if (got != buf.len) return error.RecordsTruncated;
    for (entries, 0..) |*e, i| {
        @memcpy(&e.key, buf[i * RECORD_SIZE ..][0..32]);
        @memcpy(&e.value, buf[i * RECORD_SIZE + 32 ..][0..32]);
    }
    return entries;
}

/// Read `count` 65-byte run records (key||value||tombstone) into RunEntries.
fn readRunFile(allocator: std.mem.Allocator, io: Io, file: Io.File, count: usize) ![]RunEntry {
    const entries = try allocator.alloc(RunEntry, count);
    errdefer allocator.free(entries);
    if (count == 0) return entries;
    const buf = try allocator.alloc(u8, count * RUN_RECORD_SIZE);
    defer allocator.free(buf);
    const got = try file.readPositionalAll(io, buf, 0);
    if (got != buf.len) return error.RecordsTruncated;
    for (entries, 0..) |*e, i| {
        @memcpy(&e.key, buf[i * RUN_RECORD_SIZE ..][0..32]);
        @memcpy(&e.value, buf[i * RUN_RECORD_SIZE + 32 ..][0..32]);
        e.tomb = buf[i * RUN_RECORD_SIZE + 64] != 0;
    }
    return entries;
}

/// Build the partition directory from globally-sorted records (caller owns result).
fn directoryFromEntries(allocator: std.mem.Allocator, sorted: []const t.KvEntry, prefix_bits: u6) ![]Partition {
    const dir_len = @as(usize, 1) << prefix_bits;
    var directory = try allocator.alloc(Partition, dir_len);
    errdefer allocator.free(directory);
    for (directory) |*d| d.* = .{ .offset = 0, .count = 0 };
    var idx: usize = 0;
    while (idx < sorted.len) {
        const pid = partitionOf(&sorted[idx].key, prefix_bits);
        var j = idx + 1;
        while (j < sorted.len and partitionOf(&sorted[j].key, prefix_bits) == pid) j += 1;
        directory[pid] = .{ .offset = @as(u64, idx) * RECORD_SIZE, .count = @intCast(j - idx) };
        idx = j;
    }
    return directory;
}

/// Write a sorted, prefix-partitioned base file from `entries` (deduplicated, last
/// write wins) and return its RAM directory (caller owns). The file is fsynced.
fn buildBaseFile(
    allocator: std.mem.Allocator,
    io: Io,
    dir: Io.Dir,
    name: []const u8,
    entries: []const t.KvEntry,
    prefix_bits: u6,
) ![]Partition {
    var map = std.AutoHashMap(t.Key, t.Value).init(allocator);
    defer map.deinit();
    for (entries) |e| try map.put(e.key, e.value);

    const sorted = try allocator.alloc(t.KvEntry, map.count());
    defer allocator.free(sorted);
    {
        var it = map.iterator();
        var i: usize = 0;
        while (it.next()) |kv| : (i += 1) sorted[i] = .{ .key = kv.key_ptr.*, .value = kv.value_ptr.* };
    }
    std.mem.sort(t.KvEntry, sorted, {}, kvLessThan);

    const real = sorted.len * RECORD_SIZE;
    const data = try allocator.alloc(u8, alignUpPage(real)); // pad to a page for O_DIRECT
    defer allocator.free(data);
    serialize(sorted, data[0..real]);
    @memset(data[real..], 0);

    {
        const wf = try dir.createFile(io, name, .{ .truncate = true });
        defer wf.close(io);
        if (data.len > 0) try wf.writePositionalAll(io, data, 0);
        try wf.sync(io);
    }

    return directoryFromEntries(allocator, sorted, prefix_bits);
}

// ─── Key arithmetic / search ──────────────────────────────────────────────────

fn kvLessThan(_: void, a: t.KvEntry, b: t.KvEntry) bool {
    return std.mem.order(u8, &a.key, &b.key) == .lt;
}

fn runLessThan(_: void, a: RunEntry, b: RunEntry) bool {
    return std.mem.order(u8, &a.key, &b.key) == .lt;
}

fn partitionOf(key: *const [32]u8, prefix_bits: u6) usize {
    var v: u64 = 0;
    inline for (0..8) |i| v = (v << 8) | key[i];
    return @intCast(v >> @as(u6, @intCast(@as(u32, 64) - prefix_bits)));
}

fn suffix64(key: *const [32]u8, prefix_bits: u6) u64 {
    const bit: usize = prefix_bits;
    const byte0 = bit / 8;
    const sh: u3 = @intCast(bit % 8);
    var acc: u128 = 0;
    inline for (0..9) |i| {
        const bidx = byte0 + i;
        const bv: u128 = if (bidx < 32) key[bidx] else 0;
        acc = (acc << 8) | bv;
    }
    const right: u7 = @as(u7, 8) - sh;
    return @truncate(acc >> right);
}

fn interpRank(key: *const [32]u8, prefix_bits: u6, n: u32) u64 {
    const s = suffix64(key, prefix_bits);
    return @intCast((@as(u128, s) * @as(u128, n)) >> 64);
}

fn locate(buf: []const u8, key: *const t.Key) ?t.Value {
    const n = buf.len / RECORD_SIZE;
    var lo: usize = 0;
    var hi: usize = n;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const rec_key = buf[mid * RECORD_SIZE ..][0..32];
        switch (std.mem.order(u8, rec_key, key)) {
            .eq => {
                var v: t.Value = undefined;
                @memcpy(&v, buf[mid * RECORD_SIZE + 32 ..][0..32]);
                return v;
            },
            .lt => lo = mid + 1,
            .gt => hi = mid,
        }
    }
    return null;
}

fn windowIsDefinitive(buf: []const u8, m: SlotMeta, key: *const t.Key) bool {
    const n = buf.len / RECORD_SIZE;
    if (n == 0) return true;
    const first_key = buf[0..][0..32];
    const last_key = buf[(n - 1) * RECORD_SIZE ..][0..32];
    const left_open = m.w0 > 0;
    const right_open = (@as(u64, m.w0) + m.w) < m.count;
    if (std.mem.order(u8, key, first_key) == .lt) return !left_open;
    if (std.mem.order(u8, key, last_key) == .gt) return !right_open;
    return true;
}

// ─── Tests ──────────────────────────────────────────────────────────────────────

fn keyFromU64(hi: u64) t.Key {
    var k = std.mem.zeroes(t.Key);
    std.mem.writeInt(u64, k[0..8], hi, .big);
    return k;
}

fn poolKey(id: u64) t.Key {
    return keyFromU64(id *% 0x9E37_79B9_7F4A_7C15 +% 0x1234);
}

test "FlatStore: point lookups over uniform random keys (base built up front)" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var prng = std.Random.DefaultPrng.init(0xC0FFEE);
    const rnd = prng.random();

    const N = 500;
    var entries: [N]t.KvEntry = undefined;
    for (&entries) |*e| {
        rnd.bytes(&e.key);
        rnd.bytes(&e.value);
    }

    var store = try FlatStore.create(std.testing.allocator, io, tmp.dir, "flat", &entries, .{ .prefix_bits = 4 });
    defer store.deinit();

    for (entries) |e| {
        const got = try store.get(e.key);
        try std.testing.expect(got != null);
        try std.testing.expectEqualSlices(u8, &e.value, &got.?);
    }
    var misses: usize = 0;
    for (0..50) |_| {
        var k: t.Key = undefined;
        rnd.bytes(&k);
        if ((try store.get(k)) == null) misses += 1;
    }
    try std.testing.expectEqual(@as(usize, 50), misses);
}

test "FlatStore: tiny window forces interpolation misses → whole-partition fallback" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const N = 200;
    var entries: [N]t.KvEntry = undefined;
    var prng = std.Random.DefaultPrng.init(7);
    const rnd = prng.random();
    for (&entries) |*e| {
        rnd.bytes(&e.key);
        rnd.bytes(&e.value);
    }

    var store = try FlatStore.create(std.testing.allocator, io, tmp.dir, "flat", &entries, .{ .prefix_bits = 1, .window_entries = 2 });
    defer store.deinit();
    for (entries) |e| {
        const got = try store.get(e.key);
        try std.testing.expect(got != null);
        try std.testing.expectEqualSlices(u8, &e.value, &got.?);
    }
}

test "FlatStore: put reads back from the memtable; freeze is block-aligned" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const empty = [_]t.KvEntry{};
    var store = try FlatStore.create(std.testing.allocator, io, tmp.dir, "flat", &empty, .{ .prefix_bits = 4, .memtable_cap = 1024, .freeze_block_interval = 64 });
    defer store.deinit();

    const k = poolKey(1);
    try store.put(k, [_]u8{0xAA} ** 32);
    try std.testing.expectEqual(@as(usize, 1), store.memtable.count());
    try std.testing.expectEqual(@as(usize, 0), store.l0.items.len);

    try store.endBlock(1); // interval not reached, memtable below cap ⇒ no freeze
    try std.testing.expectEqual(@as(usize, 1), store.memtable.count());

    try std.testing.expectEqualSlices(u8, &([_]u8{0xAA} ** 32), &(try store.get(k)).?);
    try std.testing.expectEqual(@as(?t.Value, null), try store.get(keyFromU64(0xDEAD)));
}

test "FlatStore: overwrite resolves newest across memtable / L0 / base" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const k = poolKey(99);
    const base = [_]t.KvEntry{.{ .key = k, .value = [_]u8{0x11} ** 32 }};
    var store = try FlatStore.create(std.testing.allocator, io, tmp.dir, "flat", &base, .{ .prefix_bits = 4, .memtable_cap = 1024 });
    defer store.deinit();

    try std.testing.expectEqualSlices(u8, &([_]u8{0x11} ** 32), &(try store.get(k)).?); // base
    try store.put(k, [_]u8{0x22} ** 32);
    try std.testing.expectEqualSlices(u8, &([_]u8{0x22} ** 32), &(try store.get(k)).?); // memtable
    try store.freeze(1);
    try std.testing.expectEqualSlices(u8, &([_]u8{0x22} ** 32), &(try store.get(k)).?); // L0
    try store.put(k, [_]u8{0x33} ** 32);
    try store.freeze(2);
    try store.compact();
    try std.testing.expectEqual(@as(usize, 0), store.l0.items.len);
    try std.testing.expectEqualSlices(u8, &([_]u8{0x33} ** 32), &(try store.get(k)).?); // base after compaction
}

test "FlatStore: endBlock freezes on the block interval" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const empty = [_]t.KvEntry{};
    var store = try FlatStore.create(std.testing.allocator, io, tmp.dir, "flat", &empty, .{ .prefix_bits = 4, .memtable_cap = 1_000_000, .l0_compact_threshold = 100, .freeze_block_interval = 4 });
    defer store.deinit();

    try store.put(poolKey(1), [_]u8{1} ** 32);
    try store.endBlock(1);
    try store.endBlock(2);
    try store.endBlock(3);
    try std.testing.expectEqual(@as(usize, 0), store.l0.items.len); // interval (4) not reached
    try store.put(poolKey(2), [_]u8{2} ** 32);
    try store.endBlock(4); // 4 - 0 >= 4 ⇒ freeze
    try std.testing.expectEqual(@as(usize, 1), store.l0.items.len);
    try std.testing.expectEqual(@as(u64, 4), store.covered_height);
    try std.testing.expectEqual(@as(usize, 0), store.memtable.count());
}

test "FlatStore: auto freeze + auto compaction pipeline, randomized with overwrites" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const empty = [_]t.KvEntry{};
    var store = try FlatStore.create(std.testing.allocator, io, tmp.dir, "flat", &empty, .{ .prefix_bits = 6, .memtable_cap = 1_000_000, .l0_compact_threshold = 4, .freeze_block_interval = 1 });
    defer store.deinit();

    var reference = std.AutoHashMap(t.Key, t.Value).init(std.testing.allocator);
    defer reference.deinit();
    var prng = std.Random.DefaultPrng.init(0x1234_5678);
    const rnd = prng.random();

    var h: u64 = 0;
    while (h < 200) : (h += 1) { // 200 "blocks" × 20 writes, freeze every block (interval 1)
        for (0..20) |_| {
            const key = poolKey(rnd.intRangeLessThan(u64, 0, 400));
            var value: t.Value = undefined;
            rnd.bytes(&value);
            try store.put(key, value);
            try reference.put(key, value);
        }
        try store.endBlock(h + 1);
        if (store.compactionDue()) try store.compact(); // host drives compaction in idle windows
    }
    try store.compact(); // fold any remaining runs

    var it = reference.iterator();
    while (it.next()) |kv| {
        const got = try store.get(kv.key_ptr.*);
        try std.testing.expect(got != null);
        try std.testing.expectEqualSlices(u8, kv.value_ptr, &got.?);
    }
}

test "FlatStore: persist frozen runs and recover via open()" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cfg: Config = .{ .prefix_bits = 4, .memtable_cap = 1_000_000, .l0_compact_threshold = 100, .freeze_block_interval = 1 };

    // Write 8 keys, freeze them into a run (covered_height = 5), then a 9th key that
    // stays in the (unfrozen) memtable.
    {
        const empty = [_]t.KvEntry{};
        var store = try FlatStore.create(std.testing.allocator, io, tmp.dir, "flat", &empty, cfg);
        defer store.deinit();
        for (0..8) |i| try store.put(poolKey(i), [_]u8{@intCast(i)} ** 32);
        try store.endBlock(5); // freeze ⇒ run persisted, covered_height = 5
        try std.testing.expectEqual(@as(usize, 1), store.l0.items.len);
        try store.put(poolKey(100), [_]u8{0xFF} ** 32); // memtable only — not durable
    }

    // Reopen: base + run reloaded; frozen keys present, memtable-only key absent.
    var store = try FlatStore.open(std.testing.allocator, io, tmp.dir, "flat", cfg);
    defer store.deinit();
    try std.testing.expectEqual(@as(u64, 5), store.covered_height);
    try std.testing.expectEqual(@as(usize, 1), store.l0.items.len);
    for (0..8) |i| {
        const got = try store.get(poolKey(i));
        try std.testing.expect(got != null);
        try std.testing.expectEqual(@as(u8, @intCast(i)), got.?[0]);
    }
    try std.testing.expectEqual(@as(?t.Value, null), try store.get(poolKey(100))); // lost with memtable
}

test "FlatStore: recover after compaction (runs folded into base)" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cfg: Config = .{ .prefix_bits = 4, .memtable_cap = 1_000_000, .l0_compact_threshold = 2, .freeze_block_interval = 1 };
    {
        const empty = [_]t.KvEntry{};
        var store = try FlatStore.create(std.testing.allocator, io, tmp.dir, "flat", &empty, cfg);
        defer store.deinit();
        // Two freezes ⇒ threshold 2 ⇒ auto compaction folds runs into base gen 1.
        for (0..10) |i| try store.put(poolKey(i), [_]u8{@intCast(i)} ** 32);
        try store.endBlock(1);
        for (10..20) |i| try store.put(poolKey(i), [_]u8{@intCast(i)} ** 32);
        try store.endBlock(2);
        try std.testing.expectEqual(@as(usize, 2), store.l0.items.len); // two frozen runs
        try store.compact(); // host folds them into base gen 1
        try std.testing.expectEqual(@as(usize, 0), store.l0.items.len);
        try std.testing.expectEqual(@as(u32, 1), store.base_gen);
    }

    var store = try FlatStore.open(std.testing.allocator, io, tmp.dir, "flat", cfg);
    defer store.deinit();
    try std.testing.expectEqual(@as(u32, 1), store.base_gen);
    try std.testing.expectEqual(@as(usize, 0), store.l0.items.len);
    for (0..20) |i| {
        const got = try store.get(poolKey(i));
        try std.testing.expect(got != null);
        try std.testing.expectEqual(@as(u8, @intCast(i)), got.?[0]);
    }
}

test "FlatStore: budgeted streaming compaction completes over many steps" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const empty = [_]t.KvEntry{};
    var store = try FlatStore.create(std.testing.allocator, io, tmp.dir, "flat", &empty, .{ .prefix_bits = 4, .memtable_cap = 1_000_000, .l0_compact_threshold = 100, .freeze_block_interval = 1 });
    defer store.deinit();

    // 3 runs × 40 distinct keys = 120 records to merge.
    var id: u64 = 0;
    var h: u64 = 1;
    while (h <= 3) : (h += 1) {
        for (0..40) |_| {
            try store.put(poolKey(id), [_]u8{@intCast(id & 0xff)} ** 32);
            id += 1;
        }
        try store.freeze(h);
    }
    try std.testing.expectEqual(@as(usize, 3), store.l0.items.len);

    // Tiny budget (2 records) ⇒ must take several in-progress steps before .done.
    var saw_in_progress = false;
    while (true) {
        const st = try store.compactStep(2 * RECORD_SIZE);
        if (st == .in_progress) saw_in_progress = true;
        if (st != .in_progress) break;
    }
    try std.testing.expect(saw_in_progress);
    try std.testing.expectEqual(@as(usize, 0), store.l0.items.len);
    try std.testing.expectEqual(@as(u32, 1), store.base_gen);

    for (0..120) |k| {
        const got = try store.get(poolKey(k));
        try std.testing.expect(got != null);
        try std.testing.expectEqual(@as(u8, @intCast(k & 0xff)), got.?[0]);
    }
}

test "FlatStore: a freeze during in-progress compaction is preserved (snapshot)" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const empty = [_]t.KvEntry{};
    var store = try FlatStore.create(std.testing.allocator, io, tmp.dir, "flat", &empty, .{ .prefix_bits = 4, .memtable_cap = 1_000_000, .l0_compact_threshold = 100, .freeze_block_interval = 1 });
    defer store.deinit();

    for (0..20) |i| try store.put(poolKey(i), [_]u8{1} ** 32);
    try store.freeze(1);
    for (20..40) |i| try store.put(poolKey(i), [_]u8{2} ** 32);
    try store.freeze(2);
    try std.testing.expectEqual(@as(usize, 2), store.l0.items.len);

    // Start a job (snapshot folds the 2 runs), advancing only a little.
    try std.testing.expectEqual(CompactStatus.in_progress, try store.compactStep(2 * RECORD_SIZE));
    try std.testing.expect(store.job != null);

    // Freeze a NEW run mid-compaction — it must NOT be folded by this job.
    for (40..60) |i| try store.put(poolKey(i), [_]u8{3} ** 32);
    try store.freeze(3);

    while (try store.compactStep(2 * RECORD_SIZE) == .in_progress) {}

    try std.testing.expectEqual(@as(usize, 1), store.l0.items.len); // the mid-job run survives
    try std.testing.expectEqual(@as(u32, 1), store.base_gen);
    for (0..60) |i| try std.testing.expect((try store.get(poolKey(i))) != null);
    try std.testing.expectEqual(@as(u8, 1), (try store.get(poolKey(0))).?[0]); // base
    try std.testing.expectEqual(@as(u8, 3), (try store.get(poolKey(50))).?[0]); // surviving run
}

test "FlatStore: delete in memtable; idempotent on absent; re-put resurrects" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const empty = [_]t.KvEntry{};
    var store = try FlatStore.create(std.testing.allocator, io, tmp.dir, "flat", &empty, .{ .prefix_bits = 4, .memtable_cap = 1_000_000 });
    defer store.deinit();

    const k = poolKey(7);
    try store.put(k, [_]u8{0xAA} ** 32);
    try std.testing.expect((try store.get(k)) != null);
    try store.delete(k);
    try std.testing.expectEqual(@as(?t.Value, null), try store.get(k)); // deleted

    try store.delete(poolKey(999)); // delete absent key — no error, still null
    try std.testing.expectEqual(@as(?t.Value, null), try store.get(poolKey(999)));

    try store.put(k, [_]u8{0xBB} ** 32); // re-insert after delete
    try std.testing.expectEqualSlices(u8, &([_]u8{0xBB} ** 32), &(try store.get(k)).?);
}

test "FlatStore: tombstone shadows base and is dropped by compaction" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const k = poolKey(3);
    const base = [_]t.KvEntry{.{ .key = k, .value = [_]u8{0x11} ** 32 }};
    var store = try FlatStore.create(std.testing.allocator, io, tmp.dir, "flat", &base, .{ .prefix_bits = 4, .memtable_cap = 1_000_000 });
    defer store.deinit();

    try std.testing.expect((try store.get(k)) != null); // present in base

    try store.delete(k); // memtable tombstone shadows the base value
    try std.testing.expectEqual(@as(?t.Value, null), try store.get(k));
    try store.freeze(1); // tombstone now in an L0 run
    try std.testing.expectEqual(@as(?t.Value, null), try store.get(k));
    try store.compact(); // merge drops both the base value and the tombstone

    try std.testing.expectEqual(@as(usize, 0), store.l0.items.len);
    try std.testing.expectEqual(@as(?t.Value, null), try store.get(k));
    // The key is physically gone from the base: its partition is now empty.
    const pid = partitionOf(&k, store.prefix_bits);
    try std.testing.expectEqual(@as(u32, 0), store.directory[pid].count);
}

test "FlatStore: prefetch serves base values, shadowed by later writes/deletes" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const N = 300;
    var entries: [N]t.KvEntry = undefined;
    for (&entries, 0..) |*e, i| {
        e.key = poolKey(i);
        e.value = [_]u8{@intCast(i & 0xff)} ** 32;
    }
    var store = try FlatStore.create(std.testing.allocator, io, tmp.dir, "flat", &entries, .{ .prefix_bits = 4, .memtable_cap = 1_000_000 });
    defer store.deinit();

    // Prefetch the whole read set (+ some absent keys).
    var read_set: [N + 2]t.Key = undefined;
    for (0..N) |i| read_set[i] = poolKey(i);
    read_set[N] = poolKey(9000); // absent
    read_set[N + 1] = poolKey(9001); // absent
    try store.prefetch(&read_set);
    try std.testing.expect(store.prefetch_map.count() > 0);

    // Reads resolve from the prefetch map (values + known-absent).
    for (0..N) |i| {
        const got = try store.get(poolKey(i));
        try std.testing.expect(got != null);
        try std.testing.expectEqual(@as(u8, @intCast(i & 0xff)), got.?[0]);
    }
    try std.testing.expectEqual(@as(?t.Value, null), try store.get(poolKey(9000)));

    // Read-your-writes: a write after prefetch shadows the prefetched base value.
    try store.put(poolKey(5), [_]u8{0xEE} ** 32);
    try std.testing.expectEqualSlices(u8, &([_]u8{0xEE} ** 32), &(try store.get(poolKey(5))).?);
    // A delete after prefetch shadows it too.
    try store.delete(poolKey(6));
    try std.testing.expectEqual(@as(?t.Value, null), try store.get(poolKey(6)));
    // Untouched prefetched keys still return their base value.
    try std.testing.expectEqual(@as(u8, @intCast(7 & 0xff)), (try store.get(poolKey(7))).?[0]);
}

test "BaseBuilder: build a base from a sorted stream, then open and read it" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const N = 500;
    var entries: [N]t.KvEntry = undefined;
    var prng = std.Random.DefaultPrng.init(0xB111D);
    const rnd = prng.random();
    for (&entries) |*e| {
        rnd.bytes(&e.key);
        rnd.bytes(&e.value);
    }
    std.mem.sort(t.KvEntry, &entries, {}, kvLessThan); // BaseBuilder requires ascending keys

    {
        var bb = try BaseBuilder.init(std.testing.allocator, io, tmp.dir, "flat", 4, 0);
        defer bb.deinit();
        for (&entries) |*e| try bb.feed(&e.key, &e.value);
        try bb.finish(123); // covered_height
    }

    var store = try FlatStore.open(std.testing.allocator, io, tmp.dir, "flat", .{ .prefix_bits = 4 });
    defer store.deinit();
    try std.testing.expectEqual(@as(u64, 123), store.covered_height);
    for (entries) |e| {
        const got = try store.get(e.key);
        try std.testing.expect(got != null);
        try std.testing.expectEqualSlices(u8, &e.value, &got.?);
    }
}

test "FlatStore: O_DIRECT page-aligned reads return correct values" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const N = 1000;
    var entries: [N]t.KvEntry = undefined;
    var prng = std.Random.DefaultPrng.init(0xD1EC7);
    const rnd = prng.random();
    for (&entries) |*e| {
        rnd.bytes(&e.key);
        rnd.bytes(&e.value);
    }
    // prefix_bits 6 → ~16 entries/partition → multi-record windows at non-page offsets.
    var store = FlatStore.create(std.testing.allocator, io, tmp.dir, "flat", &entries, .{ .prefix_bits = 6, .o_direct = true }) catch |e| switch (e) {
        // Some filesystems (tmpfs/overlay) reject O_DIRECT — skip rather than fail.
        error.Unexpected => return error.SkipZigTest,
        else => return e,
    };
    defer store.deinit();
    try std.testing.expect(store.direct_fd != null);

    for (entries) |e| {
        const got = try store.get(e.key);
        try std.testing.expect(got != null);
        try std.testing.expectEqualSlices(u8, &e.value, &got.?);
    }
    var absent: t.Key = undefined;
    rnd.bytes(&absent);
    try std.testing.expectEqual(@as(?t.Value, null), try store.get(absent));
}

test "FlatStore: tombstone persists across recovery (no resurrection)" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cfg: Config = .{ .prefix_bits = 4, .memtable_cap = 1_000_000, .l0_compact_threshold = 100, .freeze_block_interval = 1 };
    const k = poolKey(5);

    {
        const base = [_]t.KvEntry{.{ .key = k, .value = [_]u8{0x11} ** 32 }};
        var store = try FlatStore.create(std.testing.allocator, io, tmp.dir, "flat", &base, cfg);
        defer store.deinit();
        try store.delete(k);
        try store.endBlock(1); // freeze ⇒ tombstone persisted to the run file
        try std.testing.expectEqual(@as(usize, 1), store.l0.items.len);
    }

    var store = try FlatStore.open(std.testing.allocator, io, tmp.dir, "flat", cfg);
    defer store.deinit();
    // Base still has k=0x11, but the reloaded run's tombstone must shadow it.
    try std.testing.expectEqual(@as(?t.Value, null), try store.get(k));
    try store.compact(); // and compaction must remove it from the base for good
    try std.testing.expectEqual(@as(?t.Value, null), try store.get(k));
    const pid = partitionOf(&k, store.prefix_bits);
    try std.testing.expectEqual(@as(u32, 0), store.directory[pid].count);
}
