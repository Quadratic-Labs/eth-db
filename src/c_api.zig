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
