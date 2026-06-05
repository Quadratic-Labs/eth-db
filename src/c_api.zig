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

const PrefixDB = root.PrefixDB;
const Key = root.Key;
const Value = root.Value;

const TOMBSTONE: Value = [_]u8{0xFF} ** 32;

const State = struct {
    gpa: std.heap.DebugAllocator(.{}),
    db: PrefixDB,
};

export fn prefixdb_init() ?*State {
    const state = std.heap.page_allocator.create(State) catch return null;
    state.gpa = .{};
    state.db = PrefixDB.init(state.gpa.allocator()) catch {
        _ = state.gpa.deinit();
        std.heap.page_allocator.destroy(state);
        return null;
    };
    return state;
}

export fn prefixdb_deinit(state: *State) void {
    state.db.deinit();
    _ = state.gpa.deinit();
    std.heap.page_allocator.destroy(state);
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
