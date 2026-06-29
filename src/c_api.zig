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
const journal_mod = @import("block_journal.zig");
const t = @import("types.zig");

const PrefixDB = root.PrefixDB;
const Key = root.Key;
const Value = root.Value;

const TOMBSTONE = t.TOMBSTONE;

// The library allocator.  NOT DebugAllocator: backed by the page allocator it
// creates one mmap per sizeable allocation, and a large database (hundreds of
// thousands of commitment-page arrays) runs into the kernel's vm.max_map_count
// (default 65530), after which every allocation fails spuriously.
// smp_allocator reuses slabs and keeps the mapping count bounded.
const lib_alloc = std.heap.smp_allocator;

const State = struct {
    db: PrefixDB,
    store: ?page_store.DiskStore = null,
    journal: journal_mod.BlockJournal,
};

fn globalIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

export fn prefixdb_init() ?*State {
    const state = std.heap.page_allocator.create(State) catch return null;
    state.* = .{ .db = undefined, .store = null, .journal = undefined };
    state.db = PrefixDB.init(lib_alloc) catch {
        std.heap.page_allocator.destroy(state);
        return null;
    };
    state.db.enableWriteBack();
    state.journal = journal_mod.BlockJournal.init(lib_alloc);
    return state;
}

export fn prefixdb_init_capacity(node_cap: u32, sst_cap: u32) ?*State {
    const state = std.heap.page_allocator.create(State) catch return null;
    state.* = .{ .db = undefined, .store = null, .journal = undefined };
    state.db = PrefixDB.initCapacity(lib_alloc, node_cap, sst_cap) catch {
        std.heap.page_allocator.destroy(state);
        return null;
    };
    state.db.enableWriteBack();
    state.journal = journal_mod.BlockJournal.init(lib_alloc);
    return state;
}

export fn prefixdb_deinit(state: *State) void {
    if (state.store) |store| {
        state.db.flushFull(store) catch |err| {
            std.debug.print("prefixdb_deinit: flush failed: {}\n", .{err});
        };
        store.dir.close(store.io);
    }
    state.journal.deinit();
    state.db.deinit();
    std.heap.page_allocator.destroy(state);
}

/// Open (or create) a disk-backed database at the given directory path.
/// Recovers from an existing manifest.bin if present.
/// node_cap and sst_cap are the LRU cache sizes (pass 0 to use engine defaults).
export fn prefixdb_open(path: [*:0]const u8, node_cap: u32, sst_cap: u32) ?*State {
    const state = std.heap.page_allocator.create(State) catch return null;
    state.* = .{ .db = undefined, .store = null, .journal = undefined };
    const io = globalIo();
    const dir = std.Io.Dir.cwd().createDirPathOpen(io, std.mem.span(path), .{}) catch {
        std.heap.page_allocator.destroy(state);
        return null;
    };
    const store = page_store.DiskStore{ .dir = dir, .io = io };
    state.store = store;
    const nc = if (node_cap == 0) root.DEFAULT_NODE_CACHE_CAP else node_cap;
    const sc = if (sst_cap  == 0) root.DEFAULT_SST_CACHE_CAP  else sst_cap;
    state.db = PrefixDB.openWithConfig(lib_alloc, .{ .node_cap = nc, .sst_cap = sc }, store) catch {
        dir.close(io);
        state.store = null;
        std.heap.page_allocator.destroy(state);
        return null;
    };
    state.db.enableWriteBack();
    state.journal = journal_mod.BlockJournal.init(lib_alloc);
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

/// Drain the compaction queue completely (idle periods, shutdown).
export fn prefixdb_compact(state: *State) i32 {
    state.db.runCompaction() catch return -1;
    return 0;
}

/// Run at most `budget` compaction procedures; the rest stays queued for
/// later calls.  budget = 0 selects the engine default.
export fn prefixdb_compact_budget(state: *State, budget: u32) i32 {
    const b = if (budget == 0) root.PrefixDB.COMPACTION_BUDGET_DEFAULT else budget;
    state.db.runCompactionBudget(b) catch return -1;
    return 0;
}

/// Flush L0, update child_commitments along all dirty paths, and write the
/// 32-byte Merkle root into hash_out.  Returns 0 on success, -1 on error.
export fn prefixdb_commit_block(state: *State, hash_out: *[32]u8) i32 {
    const h = state.db.commitBlock() catch return -1;
    hash_out.* = h;
    return 0;
}

// ─── Reorg journal ────────────────────────────────────────────────────────────

/// Begin recording writes for block_num.  Call once per block, before any
/// prefixdb_record_write / prefixdb_put / prefixdb_del calls for that block.
export fn prefixdb_begin_block(state: *State, block_num: u32) void {
    state.journal.beginBlock(block_num);
}

/// Record the pre-write value of a key before calling prefixdb_put or prefixdb_del.
/// old_value must point to exactly 32 bytes, or be NULL if the key is currently absent.
/// Returns 0 on success, -1 on allocation failure.
export fn prefixdb_record_write(state: *State, key: *const [32]u8, old_value: ?[*]const u8) i32 {
    const ov: ?Value = if (old_value) |p| @as(*const [32]u8, @ptrCast(p)).* else null;
    state.journal.recordWrite(key.*, ov) catch return -1;
    return 0;
}

/// Finalize the journal entry for block_num.  Call after prefixdb_commit_block succeeds.
export fn prefixdb_end_block(state: *State, block_num: u32) void {
    state.journal.endBlock(block_num);
}

/// Undo all blocks after target_block by writing their pre-write values back.
/// Returns 0 on success, 1 if target_block is older than the journal window
/// (caller must resync from the last manifest flush), -1 on internal error.
export fn prefixdb_reorg(state: *State, target_block: u32) i32 {
    state.journal.reorgTo(target_block, &state.db) catch |err| switch (err) {
        error.ReorgWindowExceeded => return 1,
        else => return -1,
    };
    return 0;
}

/// Release journal entries for blocks <= flushed_block_num.
/// Call after each successful prefixdb_flush to reclaim memory.
export fn prefixdb_evict_journal(state: *State, flushed_block_num: u32) void {
    state.journal.evictOldBlocks(flushed_block_num);
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
    commit_block_calls: u64,
    commit_nodes_processed: u64,
    commit_block_ns: u64,
    kv_map_hits: u64,
    // ── Page reuse (GC) ──
    node_pages_reused: u64,
    sst_pages_reused: u64,
    cmt_pages_reused: u64,
    // ── Gauges (current state, not counters; unaffected by reset) ──
    free_node_ids: u64,
    free_sst_ids: u64,
    free_cmt_ids: u64,
    compaction_backlog: u64,
    // ── Commit-phase breakdown (subsets of commit_block_ns) ──
    commit_flushl0_ns: u64,
    commit_dirty_ns: u64,
    commit_gather_ns: u64,
    commit_gather_calls: u64,
    commit_gather_entries: u64,
    commit_rehash_ns: u64,
    // ── Commitment v2 engine ──
    commit_apply_ns: u64,
    commit_propagate_ns: u64,
    cmt_splits: u64,
    cmt_merges: u64,
    cmt_page_loads: u64,
    cmt_page_flushes: u64,
    cmt_combines: u64,
    cmt_walk_hops: u64,
};

/// Fill *out with a snapshot of all internal counters.
/// Returns 0 always.  All fields are zero when built without enable_metrics.
export fn prefixdb_get_metrics(state: *State, out: *PrefixDBMetrics) i32 {
    // Gauges are available regardless of enable_metrics.
    const gauge_free_node = state.db.heap.node_free.totalLen();
    const gauge_free_sst = state.db.heap.sst_free.totalLen();
    const gauge_free_cmt = state.db.cmt.free.totalLen();
    const gauge_backlog = state.db.compactionBacklog();
    if (comptime options.enable_metrics) {
        const s = state.db.stats;
        const h = state.db.heap.heap_stats;
        const c = state.db.cmt.stats;
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
            .disk_node_reads        = h.disk_node_reads,
            .disk_node_writes       = h.disk_node_writes,
            .disk_sst_reads         = h.disk_sst_reads,
            .disk_sst_writes        = h.disk_sst_writes,
            .commit_block_calls     = s.commit_block_calls,
            .commit_nodes_processed = s.commit_nodes_processed,
            .commit_block_ns        = s.commit_block_ns,
            .kv_map_hits            = s.kv_map_hits,
            .node_pages_reused      = h.node_pages_reused,
            .sst_pages_reused       = h.sst_pages_reused,
            .cmt_pages_reused       = c.ids_reused,
            .free_node_ids          = gauge_free_node,
            .free_sst_ids           = gauge_free_sst,
            .free_cmt_ids           = gauge_free_cmt,
            .compaction_backlog     = gauge_backlog,
            .commit_flushl0_ns      = s.commit_flushl0_ns,
            .commit_dirty_ns        = s.commit_dirty_ns,
            .commit_gather_ns       = s.commit_gather_ns,
            .commit_gather_calls    = s.commit_gather_calls,
            .commit_gather_entries  = s.commit_gather_entries,
            .commit_rehash_ns       = s.commit_rehash_ns,
            .commit_apply_ns        = c.apply_ns,
            .commit_propagate_ns    = c.propagate_ns,
            .cmt_splits             = c.splits,
            .cmt_merges             = c.merges,
            .cmt_page_loads         = c.page_loads,
            .cmt_page_flushes       = c.page_flushes,
            .cmt_combines           = c.combines,
            .cmt_walk_hops          = c.walk_hops,
        };
    } else {
        out.* = std.mem.zeroes(PrefixDBMetrics);
        out.free_node_ids = gauge_free_node;
        out.free_sst_ids = gauge_free_sst;
        out.free_cmt_ids = gauge_free_cmt;
        out.compaction_backlog = gauge_backlog;
    }
    return 0;
}

/// Reset all counters to zero.  No-op when built without enable_metrics.
export fn prefixdb_reset_metrics(state: *State) i32 {
    if (comptime options.enable_metrics) {
        state.db.stats = .{};
        state.db.heap.heap_stats = .{};
        state.db.cmt.stats = .{};
    }
    return 0;
}
