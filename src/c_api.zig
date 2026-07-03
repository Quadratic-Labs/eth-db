/// C-compatible API for PrefixDB, used by the Python bindings.
///
/// Each handle is an opaque *State that owns a GPA and the PrefixDB.
/// Delete is implemented via a tombstone (0xFF * 32); reads that hit the
/// tombstone are reported as "not found" to callers.
///
/// Return codes: 0 = OK, 1 = key not found, -1 = internal error.

const std = @import("std");
const options = @import("options");
const root = @import("root.zig");
const page_store = @import("page_store.zig");

const PrefixDB = root.PrefixDB;
const Key = root.Key;
const Value = root.Value;

const TOMBSTONE: Value = [_]u8{0xFF} ** 32;

const State = struct {
    gpa: std.heap.DebugAllocator(.{}),
    db: PrefixDB,
    store: ?page_store.DiskStore = null,
};

fn globalIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

export fn prefixdb_init() ?*State {
    const state = std.heap.page_allocator.create(State) catch return null;
    state.* = .{ .gpa = .{}, .db = undefined, .store = null };
    state.db = PrefixDB.init(state.gpa.allocator()) catch {
        _ = state.gpa.deinit();
        std.heap.page_allocator.destroy(state);
        return null;
    };
    return state;
}

export fn prefixdb_init_capacity(node_cap: u32, sst_cap: u32) ?*State {
    const state = std.heap.page_allocator.create(State) catch return null;
    state.* = .{ .gpa = .{}, .db = undefined, .store = null };
    state.db = PrefixDB.initCapacity(state.gpa.allocator(), node_cap, sst_cap) catch {
        _ = state.gpa.deinit();
        std.heap.page_allocator.destroy(state);
        return null;
    };
    return state;
}

export fn prefixdb_deinit(state: *State) void {
    if (state.store) |store| {
        state.db.flush(store) catch |err| {
            std.debug.print("prefixdb_deinit: flush failed: {}\n", .{err});
        };
        store.dir.close(store.io);
    }
    state.db.deinit();
    _ = state.gpa.deinit();
    std.heap.page_allocator.destroy(state);
}

/// Open (or create) a disk-backed database at the given directory path.
/// Recovers from an existing manifest.bin if present.
/// node_cap and sst_cap are the LRU cache sizes (pass 0 to use engine defaults).
export fn prefixdb_open(path: [*:0]const u8, node_cap: u32, sst_cap: u32) ?*State {
    const state = std.heap.page_allocator.create(State) catch return null;
    state.* = .{ .gpa = .{}, .db = undefined, .store = null };
    const io = globalIo();
    const dir = std.Io.Dir.cwd().createDirPathOpen(io, std.mem.span(path), .{}) catch {
        _ = state.gpa.deinit();
        std.heap.page_allocator.destroy(state);
        return null;
    };
    const store = page_store.DiskStore{ .dir = dir, .io = io };
    state.store = store;
    const nc = if (node_cap == 0) root.DEFAULT_NODE_CACHE_CAP else node_cap;
    const sc = if (sst_cap  == 0) root.DEFAULT_SST_CACHE_CAP  else sst_cap;
    state.db = PrefixDB.openWithConfig(state.gpa.allocator(), .{ .node_cap = nc, .sst_cap = sc }, store) catch {
        dir.close(io);
        state.store = null;
        _ = state.gpa.deinit();
        std.heap.page_allocator.destroy(state);
        return null;
    };
    return state;
}

export fn prefixdb_flush(state: *State) i32 {
    const store = state.store orelse return 0; // no-op for in-memory
    state.db.flush(store) catch return -1;
    return 0;
}

/// Returns an estimated key count (upper bound).  -1 on internal error.
/// Reads node metadata only — no SST loads or disk I/O.
/// Overcounts tombstones and uncompacted duplicates; call compact() first for a tighter estimate.
export fn prefixdb_estimate_key_count(state: *State) i64 {
    const n = state.db.estimateKeyCount() catch return -1;
    return @intCast(n);
}

export fn prefixdb_put(state: *State, key: *const [32]u8, value: *const [32]u8) i32 {
    state.db.write(key.*, value.*) catch return -1;
    return 0;
}

/// Returns 0 and fills value_out if found; 1 if not found (or deleted); -1 on error.
export fn prefixdb_get(state: *State, key: *const [32]u8, value_out: *[32]u8) i32 {
    const result = state.db.read(key.*) catch return -1;
    if (result) |v| {
        if (std.mem.eql(u8, &v, &TOMBSTONE)) return 1;
        value_out.* = v;
        return 0;
    }
    return 1;
}

export fn prefixdb_del(state: *State, key: *const [32]u8) i32 {
    state.db.write(key.*, TOMBSTONE) catch return -1;
    return 0;
}

export fn prefixdb_compact(state: *State) i32 {
    state.db.runCompaction() catch return -1;
    return 0;
}

// ─── Metrics ──────────────────────────────────────────────────────────────────

/// C-compatible metrics snapshot.  Fields are always present; all are zero
/// when the library was built without -Denable_metrics=true.
pub const PrefixDBMetrics = extern struct {
    read_ops: u64,
    write_ops: u64,
    l0_hits: u64,
    read_sst_loads: u64,
    read_node_loads: u64,
    append_filter_probes: u64,
    append_filter_hits: u64,
    sst_cache_hits: u64,
    sst_cache_misses: u64,
    node_cache_hits: u64,
    node_cache_misses: u64,
    l0_flushes: u64,
    compaction_calls: u64,
    compaction_ops: u64,
    compaction_sst_reads: u64,
    compaction_sst_writes: u64,
    disk_node_reads: u64,
    disk_node_writes: u64,
    disk_sst_reads: u64,
    disk_sst_writes: u64,
};

/// Fill *out with a snapshot of all internal counters.
/// Returns 0 always.  All fields are zero when built without enable_metrics.
export fn prefixdb_get_metrics(state: *State, out: *PrefixDBMetrics) i32 {
    if (comptime options.enable_metrics) {
        const s = state.db.stats;
        const h = state.db.heap.heap_stats;
        out.* = .{
            .read_ops             = s.read_ops,
            .write_ops            = s.write_ops,
            .l0_hits              = s.l0_hits,
            .read_sst_loads       = s.read_sst_loads,
            .read_node_loads      = s.read_node_loads,
            .append_filter_probes = s.append_filter_probes,
            .append_filter_hits   = s.append_filter_hits,
            .sst_cache_hits       = h.sst_cache_hits,
            .sst_cache_misses     = h.sst_cache_misses,
            .node_cache_hits      = h.node_cache_hits,
            .node_cache_misses    = h.node_cache_misses,
            .l0_flushes           = s.l0_flushes,
            .compaction_calls     = s.compaction_calls,
            .compaction_ops       = s.compaction_ops,
            .compaction_sst_reads = s.compaction_sst_reads,
            .compaction_sst_writes = s.compaction_sst_writes,
            .disk_node_reads      = h.disk_node_reads,
            .disk_node_writes     = h.disk_node_writes,
            .disk_sst_reads       = h.disk_sst_reads,
            .disk_sst_writes      = h.disk_sst_writes,
        };
    } else {
        out.* = std.mem.zeroes(PrefixDBMetrics);
    }
    return 0;
}

/// Reset all counters to zero.  No-op when built without enable_metrics.
export fn prefixdb_reset_metrics(state: *State) i32 {
    if (comptime options.enable_metrics) {
        state.db.stats = .{};
        state.db.heap.heap_stats = .{};
    }
    return 0;
}

// ─── Flat store C API (`flatdb_*`) ──────────────────────────────────────────────
//
// Parallel surface exposing the redesigned flat KV store (src/flat_store.zig):
// io_uring-batched windowed reads, in-RAM L0 + streaming compaction, native
// tombstones. Files live under `path` with base name "flat". The handle owns a GPA,
// the opened directory, and the FlatStore. Cold-path file ops use the threaded Io
// backend; the hot read path uses the low-level io_uring reader inside FlatStore.
//
// Return codes match prefixdb_*: 0 = OK, 1 = not found, -1 = error (unless noted).

const flat_store = root.flat_store;

/// Fast general allocator for the flat store (no libc, much faster than DebugAllocator).
const flat_alloc = std.heap.smp_allocator;

const FlatState = struct {
    dir: std.Io.Dir,
    store: flat_store.FlatStore,
};

/// Open the flat store at directory `path` (created if absent), recovering from a
/// manifest if one is present, else starting empty. `prefix_bits` (1..32; 0 → 16) and
/// `window_entries` (0 → engine default 1024) are structural — only used when creating
/// fresh; on recovery both come from the manifest. `fence_gap` (G) enables the RAM
/// fence index: every G-th base key kept in RAM, one exact G-record read per lookup
/// instead of interpolation (0 → G=∞, no index). Pure policy — takes effect on every
/// open, no manifest involvement. The other knobs accept 0 for engine defaults.
export fn flatdb_open(
    path: [*:0]const u8,
    prefix_bits: u8,
    window_entries: u32,
    fence_gap: u32,
    memtable_cap: u64,
    l0_threshold: u32,
    freeze_interval: u64,
    o_direct: u8,
) ?*FlatState {
    const state = std.heap.page_allocator.create(FlatState) catch return null;
    state.* = .{ .dir = undefined, .store = undefined };
    const io = globalIo();

    const dir = std.Io.Dir.cwd().createDirPathOpen(io, std.mem.span(path), .{}) catch {
        std.heap.page_allocator.destroy(state);
        return null;
    };
    const cfg: flat_store.Config = .{
        .prefix_bits = if (prefix_bits == 0) 16 else @intCast(prefix_bits),
        .window_entries = window_entries,
        .fence_gap = fence_gap,
        .memtable_cap = memtable_cap,
        .l0_compact_threshold = l0_threshold,
        .freeze_block_interval = freeze_interval,
        .o_direct = o_direct != 0,
    };
    state.store = flat_store.FlatStore.open(flat_alloc, io, dir, "flat", cfg) catch |err| switch (err) {
        error.FileNotFound => flat_store.FlatStore.create(flat_alloc, io, dir, "flat", &.{}, cfg) catch {
            dir.close(io);
            std.heap.page_allocator.destroy(state);
            return null;
        },
        else => {
            dir.close(io);
            std.heap.page_allocator.destroy(state);
            return null;
        },
    };
    state.dir = dir;
    return state;
}

export fn flatdb_deinit(state: *FlatState) void {
    state.store.deinit();
    state.dir.close(globalIo());
    std.heap.page_allocator.destroy(state);
}

export fn flatdb_put(state: *FlatState, key: *const [32]u8, value: *const [32]u8) i32 {
    state.store.put(key.*, value.*) catch return -1;
    return 0;
}

/// 0 and fills value_out if present; 1 if absent or deleted; -1 on error.
export fn flatdb_get(state: *FlatState, key: *const [32]u8, value_out: *[32]u8) i32 {
    const r = state.store.get(key.*) catch return -1;
    if (r) |v| {
        value_out.* = v;
        return 0;
    }
    return 1;
}

/// Batched lookup of `n` keys. `found_out[i]` = 1 if present (value in `values_out[i]`),
/// else 0. Returns 0 on success, -1 on error. Exercises the io_uring read batch.
export fn flatdb_get_many(
    state: *FlatState,
    keys: [*]const [32]u8,
    n: usize,
    values_out: [*][32]u8,
    found_out: [*]u8,
) i32 {
    const out = flat_alloc.alloc(?[32]u8, n) catch return -1;
    defer flat_alloc.free(out);
    state.store.getMany(keys[0..n], out) catch return -1;
    for (0..n) |i| {
        if (out[i]) |v| {
            values_out[i] = v;
            found_out[i] = 1;
        } else {
            found_out[i] = 0;
        }
    }
    return 0;
}

export fn flatdb_del(state: *FlatState, key: *const [32]u8) i32 {
    state.store.delete(key.*) catch return -1;
    return 0;
}

/// Prefetch a block's read set (a Block Access List) into the in-RAM prefetch map in
/// one batched io_uring pass, so subsequent get/get_many resolve below L0 without
/// per-read disk I/O. Replaces any prior prefetch. Returns 0 on success, -1 on error.
export fn flatdb_prefetch(state: *FlatState, keys: [*]const [32]u8, n: usize) i32 {
    state.store.prefetch(keys[0..n]) catch return -1;
    return 0;
}

/// Signal end of block `height` (block-aligned freeze trigger).
export fn flatdb_end_block(state: *FlatState, height: u64) i32 {
    state.store.endBlock(height) catch return -1;
    return 0;
}

/// Force-freeze the memtable as a run covering `height` (e.g. to flush before exit).
export fn flatdb_freeze(state: *FlatState, height: u64) i32 {
    state.store.freeze(height) catch return -1;
    return 0;
}

/// Advance compaction by ≤ `byte_budget` output bytes. Returns 0 = idle, 1 = in
/// progress, 2 = done, -1 = error.
export fn flatdb_compact_step(state: *FlatState, byte_budget: u64) i32 {
    const st = state.store.compactStep(@intCast(byte_budget)) catch return -1;
    return switch (st) {
        .idle => 0,
        .in_progress => 1,
        .done => 2,
    };
}

/// Run compaction to completion. Returns 0 on success, -1 on error.
export fn flatdb_compact(state: *FlatState) i32 {
    state.store.compact() catch return -1;
    return 0;
}

/// True (1) if L0 has reached the compaction threshold or a job is in progress.
export fn flatdb_compaction_due(state: *FlatState) i32 {
    return if (state.store.compactionDue()) 1 else 0;
}

/// Block height the durable state reflects; replay blocks above it after open.
export fn flatdb_covered_height(state: *FlatState) u64 {
    return state.store.covered_height;
}
