//! PrefixDB in-memory engine model.
//!
//! Core data types and constants live in types.zig; this module holds the
//! engine structs (RoutingTable, L0Buffer, Pool, Heap, PrefixDB) plus the
//! write/read operations and prefix-helper functions.
//! page_store.zig imports types.zig directly, keeping the dependency graph acyclic.

const std = @import("std");
const options = @import("options");

// ─── Re-export sub-modules ─────────────────────────────────────────────────────
pub const merkle = @import("merkle.zig");
pub const page_store = @import("page_store.zig");
const cache_mod = @import("cache.zig");
pub const node_arena_mod = @import("node_arena.zig");
pub const NodeArena = node_arena_mod.NodeArena;
const wal_mod = @import("wal.zig");
const kv_map_mod = @import("kv_map.zig");

// ─── Re-export shared types from types.zig ─────────────────────────────────────
const t = @import("types.zig");
pub const Hash = t.Hash;
pub const ZERO_HASH = t.ZERO_HASH;
pub const STRIDE = t.STRIDE;
pub const PAGE_ENTRIES = t.PAGE_ENTRIES;
pub const CHILD_COUNT = t.CHILD_COUNT;
pub const S_MAX = t.S_MAX;
pub const A_MAX = t.A_MAX;
pub const MERGE_THRESHOLD = t.MERGE_THRESHOLD;
pub const T_OPP = t.T_OPP;
pub const Key = t.Key;
pub const Value = t.Value;
pub const KvEntry = t.KvEntry;
pub const NodePageId = t.NodePageId;
pub const PayloadSlotId = t.PayloadSlotId;
pub const PrefixData = t.PrefixData;
pub const SstPage = t.SstPage;
pub const NodePage = t.NodePage;

// ─── Optional instrumentation structs ─────────────────────────────────────────
//
// Both structs are zero-size when enable_metrics=false: fields are dead-code
// eliminated and the `stats`/`heap_stats` fields add 0 bytes to their owners.

/// Per-operation counters held by PrefixDB.
pub const DbStats = if (options.enable_metrics) struct {
    read_ops: u64 = 0,
    write_ops: u64 = 0,
    l0_hits: u64 = 0,
    kv_map_hits: u64 = 0,
    read_sst_loads: u64 = 0,
    read_node_loads: u64 = 0,
    append_filter_probes: u64 = 0,
    append_filter_hits: u64 = 0,
    l0_flushes: u64 = 0,
    compaction_calls: u64 = 0,
    compaction_ops: u64 = 0,
    compaction_sst_reads: u64 = 0,
    compaction_sst_writes: u64 = 0,
    commit_block_calls: u64 = 0,
    /// Total dirty nodes processed across all commitBlock calls.
    commit_nodes_processed: u64 = 0,
    /// Cumulative wall-clock nanoseconds spent inside commitBlock.
    commit_block_ns: u64 = 0,
} else struct {};

/// Cache hit/miss counters held by Heap.
pub const HeapStats = if (options.enable_metrics) struct {
    sst_cache_hits: u64 = 0,
    sst_cache_misses: u64 = 0,
    node_cache_hits: u64 = 0,
    node_cache_misses: u64 = 0,
    disk_node_reads: u64 = 0,
    disk_node_writes: u64 = 0,
    disk_sst_reads: u64 = 0,
    disk_sst_writes: u64 = 0,
} else struct {};

// ─── Routing table (§4.2.1) ───────────────────────────────────────────────────
//
// Depths 1 and 2 are stored in NodeArena (flat arrays, always in memory).
// Depths 3+ are stored in a flat AutoHashMap(NodeCoord, NodePageId) with no
// upper-depth limit — the tree can grow as deep as the key distribution demands.

pub const RoutingTable = struct {
    deep: std.AutoHashMap(NodeCoord, NodePageId),

    pub fn init(allocator: std.mem.Allocator) RoutingTable {
        return .{ .deep = std.AutoHashMap(NodeCoord, NodePageId).init(allocator) };
    }

    pub fn deinit(self: *RoutingTable) void {
        self.deep.deinit();
    }

    pub fn get(self: *const RoutingTable, depth: u32, prefix: PrefixData) ?NodePageId {
        return self.deep.get(.{ .depth = depth, .prefix = prefix });
    }

    pub fn put(self: *RoutingTable, depth: u32, prefix: PrefixData, id: NodePageId) !void {
        try self.deep.put(.{ .depth = depth, .prefix = prefix }, id);
    }

    pub fn remove(self: *RoutingTable, depth: u32, prefix: PrefixData) bool {
        return self.deep.remove(.{ .depth = depth, .prefix = prefix });
    }
};

// ─── L0 in-memory write buffer (§4.1) ─────────────────────────────────────────

pub const L0Buffer = struct {
    entries: std.ArrayList(KvEntry),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) L0Buffer {
        return .{ .entries = .empty, .allocator = allocator };
    }

    pub fn deinit(self: *L0Buffer) void {
        self.entries.deinit(self.allocator);
    }

    pub fn append(self: *L0Buffer, entry: KvEntry) !void {
        try self.entries.append(self.allocator, entry);
    }

    pub fn prefixCount(self: *const L0Buffer, prefix6: u8) usize {
        var n: usize = 0;
        for (self.entries.items) |e| {
            if (prefixData(&e.key, 1) == @as(PrefixData, prefix6)) n += 1;
        }
        return n;
    }
};

// ─── Cache configuration (§4.3) ───────────────────────────────────────────────

pub const DEFAULT_NODE_CACHE_CAP: u32 = 262_144;
pub const DEFAULT_SST_CACHE_CAP: u32 = 262_144;

/// Controls the size of the two configurable caches for depths ≥ 3.
pub const CacheConfig = struct {
    /// LRU capacity for node pages at depth ≥ 3.
    node_cap: u32 = DEFAULT_NODE_CACHE_CAP,
    /// LRU capacity for SST (KV) pages across all depths.
    sst_cap: u32 = DEFAULT_SST_CACHE_CAP,
};

// ─── Page heap (§4.3) ─────────────────────────────────────────────────────────
//
// Two storage tiers:
//
//   node_cache  — LruCache(NodePage) for all depths, configurable size, write-through
//                 to disk (NodePageStore) when a store_dir is provided.  On a cache
//                 miss the page is reloaded from disk.  Default capacity (16 384) covers
//                 all possible depth-1/2 nodes plus a large depth-3/5 working set.
//   sst_cache   — LruCache(SstPage) for all depths, configurable size.  SST pages are
//                 not written to disk in this implementation (count field not preserved
//                 in the on-disk format); the cache acts as a bounded pool and returns
//                 error.SstCacheFull when capacity is exceeded.

pub const Heap = struct {
    // All depths: node pages in an LRU cache, backed by disk when a store is available.
    node_cache: cache_mod.LruCache(NodePage),
    // Monotonically-increasing counter; each node page gets a unique ID.
    next_node_id: NodePageId,

    // All depths: SST (KV) pages in a bounded LRU cache.
    sst_cache: cache_mod.LruCache(SstPage),
    // Monotonically-increasing counter for SST page IDs.
    next_sst_id: PayloadSlotId,

    // Optional disk stores for node pages (write-through and miss-reload).
    node_store: ?page_store.NodePageStore,
    // sst_store reserved for a future release when the on-disk format includes count.
    sst_store: ?page_store.SstPageStore,

    allocator: std.mem.Allocator,
    heap_stats: HeapStats = .{},

    pub fn init(allocator: std.mem.Allocator, config: CacheConfig, store: ?page_store.DiskStore) !Heap {
        var node_cache = try cache_mod.LruCache(NodePage).init(allocator, config.node_cap);
        errdefer node_cache.deinit(allocator);

        const sst_cache = try cache_mod.LruCache(SstPage).init(allocator, config.sst_cap);

        return .{
            .node_cache = node_cache,
            .next_node_id = 0,
            .sst_cache = sst_cache,
            .next_sst_id = 0,
            .node_store = if (store) |s| page_store.NodePageStore.init(s.dir, s.io) else null,
            .sst_store = if (store) |s| page_store.SstPageStore.init(s.dir, s.io) else null,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Heap) void {
        self.node_cache.deinit(self.allocator);
        self.sst_cache.deinit(self.allocator);
    }

    /// Write a node page.  Refuse without a disk store if the cache would need to evict.
    /// Write-back: the page reaches disk when the LRU evicts it via nodeEvictCallback.
    pub fn writeNodePage(self: *Heap, depth: u32, page: NodePage) !NodePageId {
        _ = depth;
        if (self.node_cache.len >= self.node_cache.cap and self.node_store == null) {
            return error.NodeCacheFull;
        }
        const id = self.next_node_id;
        self.next_node_id += 1;
        try self.node_cache.put(id, page);
        return id;
    }

    /// Write an SST page.  Without a disk store the cache acts as a bounded pool.
    /// Write-back: the page reaches disk when the LRU evicts it via sstLruEvictCallback.
    pub fn writeSstPage(self: *Heap, page: SstPage) !PayloadSlotId {
        if (self.sst_store == null and self.sst_cache.len >= self.sst_cache.cap)
            return error.SstCacheFull;
        const id = self.next_sst_id;
        self.next_sst_id += 1;
        try self.sst_cache.put(id, page);
        return id;
    }

    /// Retrieve a node page by ID.  Cache miss triggers a disk load when a store is available.
    pub fn getNodePage(self: *Heap, id: NodePageId) !?NodePage {
        if (self.node_cache.get(id)) |page| {
            if (comptime options.enable_metrics) self.heap_stats.node_cache_hits += 1;
            return page;
        }
        if (comptime options.enable_metrics) self.heap_stats.node_cache_misses += 1;
        if (self.node_store) |*store| {
            const page = try store.read(id);
            if (comptime options.enable_metrics) self.heap_stats.disk_node_reads += 1;
            try self.node_cache.put(id, page);
            return page;
        }
        return error.NodeNotInCache;
    }

    /// Retrieve an SST page by ID.  On a cache miss, reloads from disk when a
    /// store is configured.  Returns null only when no store is available and
    /// the page is not in cache (should not happen under normal operation).
    /// NOTE: the returned page's `count` field reflects the disk-read default
    /// (PAGE_ENTRIES); callers must override it from the owning node's
    /// sorted_page_counts / append_page_counts before using count-sensitive ops.
    pub fn getSstPage(self: *Heap, id: PayloadSlotId) !?SstPage {
        if (self.sst_cache.get(id)) |page| {
            if (comptime options.enable_metrics) self.heap_stats.sst_cache_hits += 1;
            return page;
        }
        if (comptime options.enable_metrics) self.heap_stats.sst_cache_misses += 1;
        if (self.sst_store) |*store| {
            const page = try store.read(id);
            if (comptime options.enable_metrics) self.heap_stats.disk_sst_reads += 1;
            try self.sst_cache.put(id, page);
            return page;
        }
        return null;
    }

    pub fn freeNodePage(self: *Heap, id: NodePageId) void {
        self.node_cache.remove(id);
    }

    pub fn freeSstPage(self: *Heap, id: PayloadSlotId) void {
        self.sst_cache.remove(id);
    }
};

/// How many commitBlock calls trigger an automatic flush to disk.
const FLUSH_INTERVAL: u32 = 64;

// ─── PrefixDB top-level engine (§1) ───────────────────────────────────────────

/// Identifies a node (depth, prefix) for the compaction queue.
pub const NodeCoord = struct {
    depth: u32,
    prefix: PrefixData,
};

pub const PrefixDB = struct {
    l0: L0Buffer,
    arena: NodeArena,
    routing: RoutingTable,
    heap: Heap,
    compaction_queue: std.ArrayList(NodeCoord),
    /// Commitment-dirty bitmaps: set when SST data changes; cleared by commitBlock.
    d1_dirty: u64,
    d2_dirty: [64]u64,
    deep_dirty: std.AutoHashMap(NodeCoord, void),
    /// Commitment-dirty bitmaps for d3 (same role as d1_dirty/d2_dirty).
    /// Heap-allocated (len = 4096) to keep PrefixDB small by value.
    d3_dirty: []u64,
    /// Flush-dirty bitmaps: set on every write; cleared when the node is written to disk.
    d1_dirty_flush: u64,
    d2_dirty_flush: [64]u64,
    d3_dirty_flush: []u64,   // len = 4096, heap-allocated
    /// Last disk-persisted NodePageId for each d1/d2/d3 prefix (for manifest routing entries).
    d1_node_ids: [64]?NodePageId,
    d2_node_ids: []?NodePageId,   // len = 4096, heap-allocated
    d3_node_ids: []?NodePageId,   // len = 262144, heap-allocated
    /// Deepest depth at which any node currently exists. Always ≥ 2 (d1/d2 always present).
    max_depth_used: u32 = 2,
    /// Disk store for self-flushing; null for in-memory-only databases.
    store: ?page_store.DiskStore = null,
    /// Write-ahead log; non-null when a disk store is configured.
    wal: ?wal_mod.Wal = null,
    /// Block number for WAL entry grouping; incremented on each commitBlock.
    current_block_num: u32 = 0,
    /// Committed blocks since last flush; triggers flush at FLUSH_INTERVAL.
    flush_counter: u32 = 0,
    /// O(1) cache for recently-written keys; checked between L0 and SST walk.
    kv_map: kv_map_mod.KvMap,
    allocator: std.mem.Allocator,
    stats: DbStats = .{},

    pub fn init(allocator: std.mem.Allocator) !PrefixDB {
        return initWithConfig(allocator, .{}, null);
    }

    /// Compatibility wrapper: maps the old (node_cap, sst_cap) pair to CacheConfig.
    pub fn initCapacity(allocator: std.mem.Allocator, node_cap: u32, sst_cap: u32) !PrefixDB {
        return initWithConfig(allocator, .{ .node_cap = node_cap, .sst_cap = sst_cap }, null);
    }

    pub fn initWithConfig(
        allocator: std.mem.Allocator,
        config: CacheConfig,
        store: ?page_store.DiskStore,
    ) !PrefixDB {
        var heap = try Heap.init(allocator, config, store);
        errdefer heap.deinit();
        var arena = try NodeArena.init(allocator);
        errdefer arena.deinit();
        const d2_node_ids = try allocator.alloc(?NodePageId, 4096);
        errdefer allocator.free(d2_node_ids);
        @memset(d2_node_ids, null);
        const d3_node_ids = try allocator.alloc(?NodePageId, 262144);
        errdefer allocator.free(d3_node_ids);
        @memset(d3_node_ids, null);
        const d3_dirty = try allocator.alloc(u64, 4096);
        errdefer allocator.free(d3_dirty);
        @memset(d3_dirty, 0);
        const d3_dirty_flush = try allocator.alloc(u64, 4096);
        errdefer allocator.free(d3_dirty_flush);
        @memset(d3_dirty_flush, 0);
        var routing = RoutingTable.init(allocator);
        errdefer routing.deinit();
        return .{
            .l0 = L0Buffer.init(allocator),
            .arena = arena,
            .routing = routing,
            .heap = heap,
            .compaction_queue = std.ArrayList(NodeCoord).empty,
            .d1_dirty = 0,
            .d2_dirty = [_]u64{0} ** 64,
            .d3_dirty = d3_dirty,
            .deep_dirty = std.AutoHashMap(NodeCoord, void).init(allocator),
            .d1_dirty_flush = 0,
            .d2_dirty_flush = [_]u64{0} ** 64,
            .d3_dirty_flush = d3_dirty_flush,
            .d1_node_ids = [_]?NodePageId{null} ** 64,
            .d2_node_ids = d2_node_ids,
            .d3_node_ids = d3_node_ids,
            .kv_map = kv_map_mod.KvMap.init(allocator),
            .allocator = allocator,
            // WAL and store are attached by openWithConfig for disk-backed databases.
        };
    }

    /// Open (or create fresh) a PrefixDB backed by `store`.
    /// If `manifest.bin` is present in the store directory, the database state
    /// is recovered from disk.  Otherwise, a fresh empty database is created.
    pub fn openWithConfig(
        allocator: std.mem.Allocator,
        config: CacheConfig,
        store: page_store.DiskStore,
    ) !PrefixDB {
        // Try to read an existing manifest.
        var manifest = page_store.readManifest(store, allocator) catch |err| switch (err) {
            error.FileNotFound => {
                // No manifest: either a truly fresh database or the first session
                // crashed before its initial flush.  Check for a WAL either way.
                var db = try initWithConfig(allocator, config, store);
                errdefer db.deinit();
                const replayed = try replayWal(store, &db, allocator);
                if (replayed) try db.flush(store);
                db.flush_counter = 0;
                db.current_block_num = 0;
                db.store = store;
                db.wal = try wal_mod.Wal.create(store);
                return db;
            },
            else => return err,
        };
        defer manifest.deinit(allocator);
        if (manifest.header.magic != page_store.MANIFEST_MAGIC)
            return error.ManifestBadMagic;

        // Build a fresh engine skeleton with the disk store wired in.
        var heap = try Heap.init(allocator, config, store);
        errdefer heap.deinit();

        // Restore counters.
        heap.next_node_id = manifest.header.next_node_id;
        heap.next_sst_id  = manifest.header.next_sst_id;

        // Restore d1/d2 nodes into arena, d3+ into routing table.
        var arena = try NodeArena.init(allocator);
        errdefer arena.deinit();
        var routing = RoutingTable.init(allocator);
        errdefer routing.deinit();
        const d2_node_ids = try allocator.alloc(?NodePageId, 4096);
        errdefer allocator.free(d2_node_ids);
        @memset(d2_node_ids, null);
        const d3_node_ids = try allocator.alloc(?NodePageId, 262144);
        errdefer allocator.free(d3_node_ids);
        @memset(d3_node_ids, null);
        const d3_dirty = try allocator.alloc(u64, 4096);
        errdefer allocator.free(d3_dirty);
        @memset(d3_dirty, 0);
        const d3_dirty_flush = try allocator.alloc(u64, 4096);
        errdefer allocator.free(d3_dirty_flush);
        @memset(d3_dirty_flush, 0);
        var d1_node_ids = [_]?NodePageId{null} ** 64;
        var max_depth_used: u32 = 2;
        for (manifest.routes) |r| {
            if (r.depth <= 2) {
                const page = try heap.node_store.?.read(r.node_id);
                arena.put(r.depth, r.prefix, page);
                if (r.depth == 1) {
                    d1_node_ids[@intCast(r.prefix)] = r.node_id;
                } else {
                    d2_node_ids[@intCast(r.prefix)] = r.node_id;
                }
            } else if (r.depth == 3) {
                const page = try heap.node_store.?.read(r.node_id);
                arena.put(3, r.prefix, page);
                d3_node_ids[@intCast(r.prefix)] = r.node_id;
                if (max_depth_used < 3) max_depth_used = 3;
            } else {
                try routing.put(r.depth, r.prefix, r.node_id);
                if (r.depth > max_depth_used) max_depth_used = r.depth;
            }
        }

        // Restore L0 buffer.
        var l0 = L0Buffer.init(allocator);
        errdefer l0.deinit();
        for (manifest.l0) |entry| {
            try l0.append(entry);
        }

        var db = PrefixDB{
            .l0 = l0,
            .arena = arena,
            .routing = routing,
            .heap = heap,
            .compaction_queue = std.ArrayList(NodeCoord).empty,
            .d1_dirty = 0,
            .d2_dirty = [_]u64{0} ** 64,
            .d3_dirty = d3_dirty,
            .deep_dirty = std.AutoHashMap(NodeCoord, void).init(allocator),
            .d1_dirty_flush = 0,
            .d2_dirty_flush = [_]u64{0} ** 64,
            .d3_dirty_flush = d3_dirty_flush,
            .d1_node_ids = d1_node_ids,
            .d2_node_ids = d2_node_ids,
            .d3_node_ids = d3_node_ids,
            .max_depth_used = max_depth_used,
            .kv_map = kv_map_mod.KvMap.init(allocator),
            .allocator = allocator,
            // store and wal remain null during replay so write/commitBlock skip WAL
        };

        // Replay WAL entries accumulated after the last checkpoint, then
        // write a consistent manifest so the next open needs no replay.
        const replayed = try replayWal(store, &db, allocator);
        if (replayed) try db.flush(store);

        // Attach persistent state for normal (post-recovery) operation.
        db.flush_counter = 0;
        db.current_block_num = 0;
        db.store = store;
        db.wal = try wal_mod.Wal.create(store);
        return db;
    }

    /// Replay WAL entries recorded after the last CHECKPOINT into `db`.
    /// `db` must have store=null and wal=null (called during recovery before
    /// the WAL is attached).  Returns true if any block was replayed.
    fn replayWal(store: page_store.DiskStore, db: *PrefixDB, allocator: std.mem.Allocator) !bool {
        const entries = try wal_mod.readAllEntries(store, allocator);
        defer allocator.free(entries);
        if (entries.len == 0) return false;

        // Locate the last CHECKPOINT; replay everything after it.
        var replay_start: usize = 0;
        for (entries, 0..) |e, i| {
            if (@as(wal_mod.WalEntryType, @enumFromInt(e.entry_type)) == .checkpoint) {
                replay_start = i + 1;
            }
        }
        if (replay_start >= entries.len) return false;

        // Accumulate kv_writes per block_num; commit when block_commit is seen.
        var block_writes = std.AutoHashMap(u32, std.ArrayList(KvEntry)).init(allocator);
        defer {
            var vit = block_writes.valueIterator();
            while (vit.next()) |v| v.deinit(allocator);
            block_writes.deinit();
        }

        var replayed = false;
        for (entries[replay_start..]) |entry| {
            switch (@as(wal_mod.WalEntryType, @enumFromInt(entry.entry_type))) {
                .kv_write => {
                    const gop = try block_writes.getOrPut(entry.block_num);
                    if (!gop.found_existing) gop.value_ptr.* = .empty;
                    try gop.value_ptr.append(allocator, .{
                        .key = entry.data[0..32].*,
                        .value = entry.data[32..64].*,
                    });
                },
                .block_commit => {
                    if (block_writes.fetchRemove(entry.block_num)) |kv| {
                        var writes = kv.value;
                        defer writes.deinit(allocator);
                        for (writes.items) |pair| try db.write(pair.key, pair.value);
                        _ = try db.commitBlock();
                        replayed = true;
                    }
                },
                .checkpoint => {},
                _ => {},
            }
        }
        return replayed;
    }

    /// Nodes flushed per commitBlock call to amortise the 64-block flush spike.
    /// At most 64 + 4096 + 262144 = 266304 arena nodes can be dirty over 64 blocks;
    /// 4224 per block gives 2× headroom (4224 × 64 = 270336).
    const NODE_FLUSH_BUDGET: u32 = 4_224;

    /// Write at most `budget` dirty arena nodes to disk, d1 first, then d2, then d3.
    /// Updates *_node_ids and clears the corresponding *_dirty_flush bits as it goes.
    /// A no-op when no disk store is attached.
    fn flushDirtyNodes(self: *PrefixDB, budget: u32) !void {
        const ns = if (self.heap.node_store) |*s| s else return;
        var rem = budget;

        // d1 (up to 64 nodes)
        var w1 = self.d1_dirty_flush;
        while (w1 != 0 and rem > 0) : (rem -= 1) {
            const bit: u32 = @ctz(w1);
            const new_id = self.heap.next_node_id;
            self.heap.next_node_id += 1;
            try ns.write(new_id, &self.arena.d1_pages[bit]);
            if (comptime options.enable_metrics) self.heap.heap_stats.disk_node_writes += 1;
            self.d1_node_ids[bit] = new_id;
            w1 &= w1 - 1;
        }
        self.d1_dirty_flush = w1;

        // d2 (up to 4096 nodes)
        for (&self.d2_dirty_flush, 0..) |*word, wi| {
            var w = word.*;
            while (w != 0 and rem > 0) : (rem -= 1) {
                const bit: u32 = @ctz(w);
                const prefix: u32 = @intCast(wi * 64 + bit);
                const new_id = self.heap.next_node_id;
                self.heap.next_node_id += 1;
                try ns.write(new_id, &self.arena.d2_pages[prefix]);
                if (comptime options.enable_metrics) self.heap.heap_stats.disk_node_writes += 1;
                self.d2_node_ids[prefix] = new_id;
                w &= w - 1;
            }
            word.* = w;
            if (rem == 0) return;
        }

        // d3 (up to 262144 nodes)
        for (self.d3_dirty_flush, 0..) |*word, wi| {
            var w = word.*;
            while (w != 0 and rem > 0) : (rem -= 1) {
                const bit: u32 = @ctz(w);
                const prefix: u32 = @intCast(wi * 64 + bit);
                const new_id = self.heap.next_node_id;
                self.heap.next_node_id += 1;
                try ns.write(new_id, &self.arena.d3_pages[prefix]);
                if (comptime options.enable_metrics) self.heap.heap_stats.disk_node_writes += 1;
                self.d3_node_ids[prefix] = new_id;
                w &= w - 1;
            }
            word.* = w;
            if (rem == 0) return;
        }
    }

    /// Persist the current state to `store`.
    /// Writes all live arena nodes to node_store, then writes manifest.bin.
    /// Must be called before process exit to preserve the database.
    pub fn flush(self: *PrefixDB, store: page_store.DiskStore) !void {
        // Drain all remaining dirty arena nodes (safety net; incremental flushing
        // in commitBlock should have already written most of them).
        try self.flushDirtyNodes(std.math.maxInt(u32));

        // Ensure all d4+ nodes and SST pages referenced by the manifest are on disk.
        // With write-back, they may still be in cache but not yet persisted.
        if (self.heap.node_store != null) {
            var it = self.routing.deep.iterator();
            while (it.next()) |kv| {
                const node_id = kv.value_ptr.*;
                if (self.heap.node_cache.get(node_id)) |page| {
                    try self.heap.node_store.?.write(node_id, &page);
                    if (comptime options.enable_metrics) self.heap.heap_stats.disk_node_writes += 1;
                }
            }
        }
        if (self.heap.sst_store != null) {
            const SstFlushCtx = struct { db: *PrefixDB };
            var sst_ctx = SstFlushCtx{ .db = self };
            try self.heap.sst_cache.forEachLive(@ptrCast(&sst_ctx), struct {
                fn f(raw: *anyopaque, id: u32, page: *const SstPage) !void {
                    const c: *SstFlushCtx = @ptrCast(@alignCast(raw));
                    try c.db.heap.sst_store.?.write(id, page);
                    if (comptime options.enable_metrics) c.db.heap.heap_stats.disk_sst_writes += 1;
                }
            }.f);
        }

        // Count routing entries across all tiers.
        var route_count: u32 = 0;
        {
            var w = self.arena.d1_exists;
            while (w != 0) : (w &= w - 1) route_count += 1;
        }
        for (self.arena.d2_exists) |word| {
            var w = word;
            while (w != 0) : (w &= w - 1) route_count += 1;
        }
        for (self.arena.d3_exists) |word| {
            var w = word;
            while (w != 0) : (w &= w - 1) route_count += 1;
        }
        route_count += @as(u32, @intCast(self.routing.deep.count()));

        // Count L0 entries.
        const l0_count: u32 = @intCast(self.l0.entries.items.len);

        const header = page_store.ManifestHeader{
            .magic         = page_store.MANIFEST_MAGIC,
            .version       = page_store.MANIFEST_VERSION,
            .next_node_id  = self.heap.next_node_id,
            .next_sst_id   = self.heap.next_sst_id,
            .routing_count = route_count,
            .l0_count      = l0_count,
        };

        // Build routing entries slice.
        var routes = try std.ArrayList(page_store.ManifestRouteEntry).initCapacity(self.allocator, route_count);
        defer routes.deinit(self.allocator);
        // d1 live nodes (only those with a persisted ID)
        {
            var w = self.arena.d1_exists;
            while (w != 0) : (w &= w - 1) {
                const prefix: u32 = @ctz(w);
                if (self.d1_node_ids[prefix]) |id| {
                    routes.appendAssumeCapacity(.{ .depth = 1, .prefix = prefix, .node_id = id });
                }
            }
        }
        // d2 live nodes
        for (self.arena.d2_exists, 0..) |word, wi| {
            var w = word;
            while (w != 0) : (w &= w - 1) {
                const bit: u32 = @ctz(w);
                const prefix: u32 = @intCast(wi * 64 + bit);
                if (self.d2_node_ids[prefix]) |id| {
                    routes.appendAssumeCapacity(.{ .depth = 2, .prefix = prefix, .node_id = id });
                }
            }
        }
        // d3 live nodes (arena)
        for (self.arena.d3_exists, 0..) |word, wi| {
            var w = word;
            while (w != 0) : (w &= w - 1) {
                const bit: u32 = @ctz(w);
                const prefix: u32 = @intCast(wi * 64 + bit);
                if (self.d3_node_ids[prefix]) |id| {
                    routes.appendAssumeCapacity(.{ .depth = 3, .prefix = prefix, .node_id = id });
                }
            }
        }
        // deep nodes (depths 4+)
        {
            var it = self.routing.deep.iterator();
            while (it.next()) |kv| {
                routes.appendAssumeCapacity(.{
                    .depth   = kv.key_ptr.depth,
                    .prefix  = kv.key_ptr.prefix,
                    .node_id = kv.value_ptr.*,
                });
            }
        }

        try page_store.writeManifest(
            store,
            header,
            routes.items,
            self.l0.entries.items,
        );
        if (self.wal) |*w| try w.append(wal_mod.WalEntry.checkpoint());
    }

    /// Wire write-back callbacks for both node and SST caches.
    /// Must be called after the PrefixDB is at its final memory address.
    pub fn enableWriteBack(self: *PrefixDB) void {
        const ctx: *anyopaque = @ptrCast(self);
        self.heap.node_cache.evict_ctx    = ctx;
        self.heap.node_cache.lru_evict_fn = &nodeEvictCallback;
        self.heap.sst_cache.evict_ctx     = ctx;
        self.heap.sst_cache.lru_evict_fn  = &sstLruEvictCallback;
        self.heap.sst_cache.remove_fn     = &sstRemoveCallback;
    }

    fn nodeEvictCallback(ctx: *anyopaque, id: u32, page: *const NodePage) void {
        const db: *PrefixDB = @ptrCast(@alignCast(ctx));
        if (db.heap.node_store) |*ns| ns.write(id, page) catch {};
    }

    fn sstLruEvictCallback(ctx: *anyopaque, id: u32, page: *const SstPage) void {
        const db: *PrefixDB = @ptrCast(@alignCast(ctx));
        if (db.heap.sst_store) |*ss| ss.write(id, page) catch {};
        for (&page.entries) |*e| db.kv_map.removeIfFromSst(e.key, id);
    }

    fn sstRemoveCallback(ctx: *anyopaque, id: u32, page: *const SstPage) void {
        const db: *PrefixDB = @ptrCast(@alignCast(ctx));
        for (&page.entries) |*e| db.kv_map.removeIfFromSst(e.key, id);
    }

    pub fn deinit(self: *PrefixDB) void {
        if (self.wal) |*w| w.close();
        self.l0.deinit();
        self.arena.deinit();
        self.routing.deinit();
        self.heap.deinit();
        self.compaction_queue.deinit(self.allocator);
        self.deep_dirty.deinit();
        self.kv_map.deinit();
        self.allocator.free(self.d2_node_ids);
        self.allocator.free(self.d3_node_ids);
        self.allocator.free(self.d3_dirty);
        self.allocator.free(self.d3_dirty_flush);
    }

    fn markDirty(self: *PrefixDB, depth: u32, prefix: PrefixData) void {
        switch (depth) {
            1 => self.d1_dirty |= @as(u64, 1) << @as(u6, @intCast(prefix)),
            2 => self.d2_dirty[@intCast(prefix >> 6)] |= @as(u64, 1) << @as(u6, @intCast(prefix & 63)),
            3 => self.d3_dirty[@intCast(prefix >> 6)] |= @as(u64, 1) << @as(u6, @intCast(prefix & 63)),
            else => self.deep_dirty.put(.{ .depth = depth, .prefix = prefix }, {}) catch {},
        }
    }

    // ─── Node access helpers (dispatch arena for d1/d2, heap for d3-d5) ───────

    fn nodeGet(self: *PrefixDB, depth: u32, prefix: PrefixData) !?NodePage {
        if (depth <= 3) {
            const ptr = self.arena.get(depth, prefix) orelse return null;
            return ptr.*;
        }
        const id = self.routing.get(depth, prefix) orelse return null;
        return try self.heap.getNodePage(id);
    }

    fn nodePut(self: *PrefixDB, depth: u32, prefix: PrefixData, node: NodePage) !void {
        if (depth <= 3) {
            self.arena.put(depth, prefix, node);
            switch (depth) {
                1 => self.d1_dirty_flush |= @as(u64, 1) << @as(u6, @intCast(prefix)),
                2 => self.d2_dirty_flush[@intCast(prefix >> 6)] |= @as(u64, 1) << @as(u6, @intCast(prefix & 63)),
                3 => self.d3_dirty_flush[@intCast(prefix >> 6)] |= @as(u64, 1) << @as(u6, @intCast(prefix & 63)),
                else => unreachable,
            }
            if (depth > self.max_depth_used) self.max_depth_used = depth;
            return;
        }
        if (depth > self.max_depth_used) self.max_depth_used = depth;
        const old_id = self.routing.get(depth, prefix);
        const new_id = try self.heap.writeNodePage(depth, node);
        try self.routing.put(depth, prefix, new_id);
        if (old_id) |id| self.heap.freeNodePage(id);
    }

    fn nodeRemove(self: *PrefixDB, depth: u32, prefix: PrefixData) void {
        if (depth <= 3) {
            self.arena.remove(depth, prefix);
            return;
        }
        const id = self.routing.get(depth, prefix) orelse return;
        _ = self.routing.remove(depth, prefix);
        self.heap.freeNodePage(id);
    }

    // ─── Write (§5.2) ─────────────────────────────────────────────────────────

    /// Append (K, V) to L0; flush to L1 when the prefix group reaches PAGE_ENTRIES.
    pub fn write(self: *PrefixDB, key: Key, value: Value) !void {
        if (comptime options.enable_metrics) self.stats.write_ops += 1;
        if (self.wal) |*w| try w.append(wal_mod.WalEntry.kvWrite(self.current_block_num, key, value));
        try self.l0.append(.{ .key = key, .value = value });
        self.kv_map.put(key, value);
        const p = prefixData(&key, 1);
        if (self.l0.prefixCount(@intCast(p)) >= PAGE_ENTRIES) {
            try self.flushL0Prefix(p);
        }
    }

    // ─── Read (§5.1) ──────────────────────────────────────────────────────────

    /// Return the most-recent value for key, or null if not present.
    pub fn read(self: *PrefixDB, key: Key) !?Value {
        if (comptime options.enable_metrics) self.stats.read_ops += 1;

        // Step 1: L0 — scan backwards so the most-recent write is found first.
        var i: usize = self.l0.entries.items.len;
        while (i > 0) {
            i -= 1;
            if (std.mem.eql(u8, &self.l0.entries.items[i].key, &key)) {
                if (comptime options.enable_metrics) self.stats.l0_hits += 1;
                return self.l0.entries.items[i].value;
            }
        }

        // Step 2: kv_map — O(1) lookup for recently-written keys.
        if (self.kv_map.get(key)) |val| {
            if (comptime options.enable_metrics) self.stats.kv_map_hits += 1;
            return val;
        }

        // Steps 3–N: search levels depth 1..max_depth_used; shallowest hit wins.
        for (1..self.max_depth_used + 1) |d_usize| {
            const d: u32 = @intCast(d_usize);
            const p = prefixData(&key, d);
            const node = (try self.nodeGet(d, p)) orelse continue;
            if (comptime options.enable_metrics) self.stats.read_node_loads += 1;

            const q = prefix32(&key, d);
            const f = prefix16(&key, d);
            var opp_count: u32 = 0;

            // Append zone (most recent): scan from newest page to oldest.
            var append_result: ?Value = null;
            var j: usize = node.append_count;
            while (j > 0 and append_result == null) {
                j -= 1;
                if (comptime options.enable_metrics) self.stats.append_filter_probes += 1;
                if (filterContains(&node.append_prefix16[j], node.append_page_counts[j], f)) {
                    if (comptime options.enable_metrics) self.stats.append_filter_hits += 1;
                    opp_count += 1;
                    if (try self.heap.getSstPage(node.append_slot_ids[j])) |sst_raw| {
                        if (comptime options.enable_metrics) self.stats.read_sst_loads += 1;
                        var sst = sst_raw;
                        sst.count = node.append_page_counts[j];
                        append_result = binarySearchSst(&sst, &key);
                        if (append_result) |val| self.kv_map.putFromSst(key, val, node.append_slot_ids[j]);
                    }
                }
            }

            // Sorted zone (fallback when key not found in append zone).
            var sorted_result: ?Value = null;
            if (append_result == null and node.sorted_count > 0) {
                var lo: usize = 0;
                var hi: usize = node.sorted_count;
                while (lo < hi) {
                    const mid = lo + (hi - lo) / 2;
                    if (node.sorted_min4[mid] <= q) lo = mid + 1 else hi = mid;
                }
                if (lo > 0) {
                    const pg_idx = lo - 1;
                    if (try self.heap.getSstPage(node.sorted_slot_ids[pg_idx])) |sst_raw| {
                        if (comptime options.enable_metrics) self.stats.read_sst_loads += 1;
                        var sst = sst_raw;
                        sst.count = node.sorted_page_counts[pg_idx];
                        sorted_result = binarySearchSst(&sst, &key);
                        if (sorted_result) |val| self.kv_map.putFromSst(key, val, node.sorted_slot_ids[pg_idx]);
                    }
                }
            }

            // Opportunistic compaction: queue node if we loaded ≥ T_OPP append pages.
            if (opp_count >= T_OPP) {
                self.compaction_queue.append(self.allocator, .{ .depth = d, .prefix = p }) catch {};
            }

            const depth_result = append_result orelse sorted_result;
            if (depth_result != null) return depth_result;
        }

        return null;
    }

    // ─── Private helpers ──────────────────────────────────────────────────────

    /// Flush all L0 entries for `prefix` to L1, deduplicating and sorting them.
    fn flushL0Prefix(self: *PrefixDB, prefix: PrefixData) !void {
        if (comptime options.enable_metrics) self.stats.l0_flushes += 1;
        const alloc = self.allocator;

        var map = std.AutoHashMap(Key, Value).init(alloc);
        defer map.deinit();

        var k: usize = self.l0.entries.items.len;
        while (k > 0) {
            k -= 1;
            const e = self.l0.entries.items[k];
            if (prefixData(&e.key, 1) == prefix) {
                const gop = try map.getOrPut(e.key);
                if (!gop.found_existing) gop.value_ptr.* = e.value;
            }
        }

        var new_entries = std.ArrayList(KvEntry).empty;
        errdefer new_entries.deinit(alloc);
        for (self.l0.entries.items) |e| {
            if (prefixData(&e.key, 1) != prefix) {
                try new_entries.append(alloc, e);
            }
        }
        self.l0.entries.deinit(alloc);
        self.l0.entries = new_entries;

        if (map.count() == 0) return;

        var sorted = std.ArrayList(KvEntry).empty;
        defer sorted.deinit(alloc);
        var it = map.iterator();
        while (it.next()) |kv| {
            try sorted.append(alloc, .{ .key = kv.key_ptr.*, .value = kv.value_ptr.* });
        }
        std.mem.sort(KvEntry, sorted.items, {}, kvLessThan);

        var offset: usize = 0;
        while (offset < sorted.items.len) {
            const end = @min(offset + PAGE_ENTRIES, sorted.items.len);
            try self.writeSstChunk(1, prefix, sorted.items[offset..end]);
            offset = end;
        }
    }

    /// Build one SST page from `chunk` and attach it to the node's append zone.
    fn writeSstChunk(self: *PrefixDB, depth: u32, prefix: PrefixData, chunk: []const KvEntry) !void {
        std.debug.assert(chunk.len > 0 and chunk.len <= PAGE_ENTRIES);

        var sst = std.mem.zeroes(SstPage);
        sst.count = @intCast(chunk.len);
        @memcpy(sst.entries[0..chunk.len], chunk);
        const sst_id = try self.heap.writeSstPage(sst);

        var filter = [_]u16{std.math.maxInt(u16)} ** PAGE_ENTRIES;
        for (chunk, 0..) |e, idx| filter[idx] = prefix16(&e.key, depth);

        try self.appendSstToNode(depth, prefix, sst_id, @intCast(chunk.len), filter);
    }

    /// Attach an SST page to a node's append zone.
    fn appendSstToNode(
        self: *PrefixDB,
        depth: u32,
        prefix: PrefixData,
        sst_id: PayloadSlotId,
        count: u8,
        filter: [PAGE_ENTRIES]u16,
    ) anyerror!void {
        var node = (try self.nodeGet(depth, prefix)) orelse std.mem.zeroes(NodePage);

        // Append zone full: compact inline so we always have room.
        if (node.append_count >= A_MAX) {
            // Guard: merging append into sorted could produce sorted_count + append_count
            // pages in the worst case (no promotion). Run upwardSplit first to drain the
            // sorted zone before it overflows S_MAX.
            if (@as(u32, node.sorted_count) + @as(u32, node.append_count) > S_MAX) {
                try self.upwardSplit(depth, prefix);
                node = (try self.nodeGet(depth, prefix)) orelse std.mem.zeroes(NodePage);
            }
            try self.appendToSortedMerge(depth, prefix);
            node = (try self.nodeGet(depth, prefix)) orelse std.mem.zeroes(NodePage);
        }

        const ac = node.append_count;
        node.append_slot_ids[ac] = sst_id;
        node.append_page_counts[ac] = count;
        node.append_prefix16[ac] = filter;
        node.append_count += 1;

        try self.nodePut(depth, prefix, node);
        self.markDirty(depth, prefix);

        if (node.append_count == A_MAX) {
            self.compaction_queue.append(
                self.allocator,
                .{ .depth = depth, .prefix = prefix },
            ) catch {};
        }
    }

    // ─── Block commitment (§9) ────────────────────────────────────────────────

    /// Flush every remaining L0 entry to L1 regardless of group size.
    pub fn flushL0All(self: *PrefixDB) !void {
        var prefixes = std.AutoHashMap(PrefixData, void).init(self.allocator);
        defer prefixes.deinit();
        for (self.l0.entries.items) |e| {
            try prefixes.put(prefixData(&e.key, 1), {});
        }
        var list = std.ArrayList(PrefixData).empty;
        defer list.deinit(self.allocator);
        var it = prefixes.iterator();
        while (it.next()) |entry| try list.append(self.allocator, entry.key_ptr.*);
        for (list.items) |p| try self.flushL0Prefix(p);
    }

    /// Hash the logical key-value content of a single node (deduplicated, sorted).
    /// Append zone entries override sorted zone entries for the same key.
    fn nodeDataHash(self: *PrefixDB, node: NodePage) !Hash {
        var dedup = std.AutoHashMap(Key, Value).init(self.allocator);
        defer dedup.deinit();
        for (0..node.sorted_count) |si| {
            if (try self.heap.getSstPage(node.sorted_slot_ids[si])) |sst| {
                const cnt = node.sorted_page_counts[si];
                for (sst.entries[0..cnt]) |e| try dedup.put(e.key, e.value);
            }
        }
        for (0..node.append_count) |ai| {
            if (try self.heap.getSstPage(node.append_slot_ids[ai])) |sst| {
                const cnt = node.append_page_counts[ai];
                for (sst.entries[0..cnt]) |e| try dedup.put(e.key, e.value);
            }
        }
        if (dedup.count() == 0) return ZERO_HASH;
        var entries = std.ArrayList(KvEntry).empty;
        defer entries.deinit(self.allocator);
        var eit = dedup.iterator();
        while (eit.next()) |kv| {
            try entries.append(self.allocator, .{ .key = kv.key_ptr.*, .value = kv.value_ptr.* });
        }
        std.mem.sort(KvEntry, entries.items, {}, kvLessThan);
        var hasher = std.crypto.hash.Blake3.init(.{});
        for (entries.items) |e| {
            hasher.update(&e.key);
            hasher.update(&e.value);
        }
        var out: Hash = undefined;
        hasher.final(&out);
        return out;
    }

    /// Compute the Merkle root of a node's commitment by walking up dirty nodes
    /// deepest-first, propagating each child's hash into its parent's
    /// child_commitments slot (CoW rewrite), then returning a Merkle root over
    /// all depth-1 commitments.
    ///
    /// Call once per block after all writes are done.  Flushes L0 internally so
    /// callers do not need a separate flushL0All call.
    pub fn commitBlock(self: *PrefixDB) !Hash {
        if (comptime options.enable_metrics) self.stats.commit_block_calls += 1;
        const t0 = if (comptime options.enable_metrics) monoNs() else {};

        try self.flushL0All();

        // Seed worklist from dirty bitmaps (d1, d2) and deep_dirty hashmap (d3-d5).
        var worklist = std.AutoHashMap(NodeCoord, void).init(self.allocator);
        defer worklist.deinit();
        {
            // depth 1: 64-bit bitmap, one bit per prefix
            var w1 = self.d1_dirty;
            self.d1_dirty = 0;
            while (w1 != 0) : (w1 &= w1 - 1) {
                const prefix: PrefixData = @ctz(w1);
                try worklist.put(.{ .depth = 1, .prefix = prefix }, {});
            }
            // depth 2: 64 × 64-bit words → 4096 bits total
            for (&self.d2_dirty, 0..) |*word, wi| {
                var w = word.*;
                word.* = 0;
                while (w != 0) : (w &= w - 1) {
                    const bit: u32 = @ctz(w);
                    try worklist.put(.{ .depth = 2, .prefix = @intCast(wi * 64 + bit) }, {});
                }
            }
            // depth 3: 4096 × 64-bit words → 262144 bits
            for (self.d3_dirty, 0..) |*word, wi| {
                var w = word.*;
                word.* = 0;
                while (w != 0) : (w &= w - 1) {
                    const bit: u32 = @ctz(w);
                    try worklist.put(.{ .depth = 3, .prefix = @intCast(wi * 64 + bit) }, {});
                }
            }
            // depths 4+: sparse hashmap
            var it = self.deep_dirty.iterator();
            while (it.next()) |entry| try worklist.put(entry.key_ptr.*, {});
            self.deep_dirty.clearRetainingCapacity();
        }

        // Process deepest nodes first so children are committed before parents.
        // Find the maximum depth in the worklist to start from.
        var depth: u32 = 1;
        {
            var wit = worklist.iterator();
            while (wit.next()) |e| if (e.key_ptr.depth > depth) { depth = e.key_ptr.depth; };
        }
        while (true) {
            var at_depth = std.ArrayList(PrefixData).empty;
            defer at_depth.deinit(self.allocator);
            {
                var wit = worklist.iterator();
                while (wit.next()) |entry| {
                    if (entry.key_ptr.depth == depth) {
                        try at_depth.append(self.allocator, entry.key_ptr.prefix);
                    }
                }
            }

            for (at_depth.items) |prefix| {
                _ = worklist.remove(.{ .depth = depth, .prefix = prefix });
                if (comptime options.enable_metrics) self.stats.commit_nodes_processed += 1;

                const node = (try self.nodeGet(depth, prefix)) orelse continue;

                const data_hash = try self.nodeDataHash(node);
                const child_root = childMerkleRoot(node.child_commitments);
                const commitment = merkle.pairHash(&data_hash, &child_root);

                if (depth > 1) {
                    const parent_depth = depth - 1;
                    const parent_prefix = prefix >> STRIDE;
                    const child_idx = prefix & (CHILD_COUNT - 1);

                    if (try self.nodeGet(parent_depth, parent_prefix)) |parent_old| {
                        var parent = parent_old;
                        parent.child_commitments[child_idx] = commitment;
                        try self.nodePut(parent_depth, parent_prefix, parent);
                        // Ensure the parent is (re)processed to propagate further.
                        try worklist.put(.{ .depth = parent_depth, .prefix = parent_prefix }, {});
                    }
                }
            }

            if (depth == 1) break;
            depth -= 1;
        }

        // Build the root commitment: a Merkle tree over the 64 depth-1 slots.
        var root_children: [CHILD_COUNT]Hash = [_]Hash{ZERO_HASH} ** CHILD_COUNT;
        for (0..CHILD_COUNT) |p| {
            const pp: PrefixData = @intCast(p);
            const node = (try self.nodeGet(1, pp)) orelse continue;
            const data_hash = try self.nodeDataHash(node);
            const child_root = childMerkleRoot(node.child_commitments);
            root_children[p] = merkle.pairHash(&data_hash, &child_root);
        }
        const root = childMerkleRoot(root_children);
        if (comptime options.enable_metrics) {
            self.stats.commit_block_ns += monoNs() - t0;
        }
        if (self.wal) |*w| try w.append(wal_mod.WalEntry.blockCommit(self.current_block_num, root));
        self.current_block_num += 1;
        // Incrementally drain dirty arena nodes to smooth the 64-block flush spike.
        try self.flushDirtyNodes(NODE_FLUSH_BUDGET);
        self.flush_counter += 1;
        if (self.flush_counter >= FLUSH_INTERVAL) {
            if (self.store) |s| {
                try self.flush(s);
                self.flush_counter = 0;
            }
        }
        return root;
    }

    // ─── Compaction (§6) ──────────────────────────────────────────────────────

    /// Drain the compaction queue, running the appropriate procedure per node.
    pub fn runCompaction(self: *PrefixDB) !void {
        if (comptime options.enable_metrics) self.stats.compaction_calls += 1;
        while (self.compaction_queue.pop()) |coord| {
            const node = (try self.nodeGet(coord.depth, coord.prefix)) orelse continue;
            if (coord.depth > 1 and (try self.countNodeEntries(coord.depth, coord.prefix)) < MERGE_THRESHOLD) {
                if (comptime options.enable_metrics) self.stats.compaction_ops += 1;
                try self.downwardMerge(coord.depth, coord.prefix);
            } else if (node.sorted_count >= S_MAX) {
                if (comptime options.enable_metrics) self.stats.compaction_ops += 1;
                try self.upwardSplit(coord.depth, coord.prefix);
            } else if (node.append_count > 0) {
                if (comptime options.enable_metrics) self.stats.compaction_ops += 1;
                try self.appendToSortedMerge(coord.depth, coord.prefix);
            }
        }
    }

    /// Count total live KV entries across all SST pages of a node.
    /// Reads counts from node metadata — no SST page loads needed.
    fn countNodeEntries(self: *PrefixDB, depth: u32, prefix: PrefixData) !u32 {
        const node = (try self.nodeGet(depth, prefix)) orelse return 0;
        var count: u32 = 0;
        for (node.sorted_page_counts[0..node.sorted_count]) |c| count += c;
        for (node.append_page_counts[0..node.append_count]) |c| count += c;
        return count;
    }

    /// Estimated total number of stored entries (upper bound).
    /// Reads node page-count metadata only — no SST page loads, no disk I/O.
    /// Overcounts tombstones (deleted keys) and uncompacted duplicate writes.
    /// Run `compact()` first for a tighter estimate.
    pub fn estimateKeyCount(self: *PrefixDB) !u64 {
        var total: u64 = self.l0.entries.items.len;
        // d1 arena
        {
            var w = self.arena.d1_exists;
            while (w != 0) : (w &= w - 1) {
                const p: u32 = @ctz(w);
                const node = self.arena.d1_pages[p];
                for (node.sorted_page_counts[0..node.sorted_count]) |c| total += c;
                for (node.append_page_counts[0..node.append_count]) |c| total += c;
            }
        }
        // d2 arena
        for (self.arena.d2_exists, 0..) |word, wi| {
            var w = word;
            while (w != 0) : (w &= w - 1) {
                const bit: u32 = @ctz(w);
                const prefix: u32 = @intCast(wi * 64 + bit);
                const node = self.arena.d2_pages[prefix];
                for (node.sorted_page_counts[0..node.sorted_count]) |c| total += c;
                for (node.append_page_counts[0..node.append_count]) |c| total += c;
            }
        }
        // deep nodes (depths 3+)
        {
            var it = self.routing.deep.iterator();
            while (it.next()) |entry| {
                const node_id = entry.value_ptr.*;
                const node = (try self.heap.getNodePage(node_id)) orelse continue;
                for (node.sorted_page_counts[0..node.sorted_count]) |c| total += c;
                for (node.append_page_counts[0..node.append_count]) |c| total += c;
            }
        }
        return total;
    }

    /// §6.1: Merge the append zone into the sorted zone; promote homogeneous pages up.
    fn appendToSortedMerge(self: *PrefixDB, depth: u32, prefix: PrefixData) !void {
        const alloc = self.allocator;
        const old_node = (try self.nodeGet(depth, prefix)) orelse return;
        if (old_node.append_count == 0) return;

        var all_entries = std.ArrayList(KvEntry).empty;
        defer all_entries.deinit(alloc);
        for (0..old_node.sorted_count) |si| {
            if (try self.heap.getSstPage(old_node.sorted_slot_ids[si])) |sst| {
                if (comptime options.enable_metrics) self.stats.compaction_sst_reads += 1;
                const cnt = old_node.sorted_page_counts[si];
                for (sst.entries[0..cnt]) |e| try all_entries.append(alloc, e);
            }
        }
        for (0..old_node.append_count) |ai| {
            if (try self.heap.getSstPage(old_node.append_slot_ids[ai])) |sst| {
                if (comptime options.enable_metrics) self.stats.compaction_sst_reads += 1;
                const cnt = old_node.append_page_counts[ai];
                for (sst.entries[0..cnt]) |e| try all_entries.append(alloc, e);
            }
        }

        var dedup = std.AutoHashMap(Key, Value).init(alloc);
        defer dedup.deinit();
        for (all_entries.items) |e| try dedup.put(e.key, e.value);

        var survivors = std.ArrayList(KvEntry).empty;
        defer survivors.deinit(alloc);
        var it = dedup.iterator();
        while (it.next()) |kv| try survivors.append(alloc, .{ .key = kv.key_ptr.*, .value = kv.value_ptr.* });
        std.mem.sort(KvEntry, survivors.items, {}, kvLessThan);

        var new_ids = std.ArrayList(PayloadSlotId).empty;
        defer new_ids.deinit(alloc);
        var new_min4 = std.ArrayList(u32).empty;
        defer new_min4.deinit(alloc);
        var new_counts = std.ArrayList(u8).empty;
        defer new_counts.deinit(alloc);

        var offset: usize = 0;
        while (offset < survivors.items.len) {
            const end = @min(offset + PAGE_ENTRIES, survivors.items.len);
            const chunk = survivors.items[offset..end];

            if (chunk.len == PAGE_ENTRIES) {
                const f0 = prefix16(&chunk[0].key, depth);
                const f63 = prefix16(&chunk[PAGE_ENTRIES - 1].key, depth);
                if (f0 >> 10 == f63 >> 10) {
                    try self.promoteSstPage(depth, chunk);
                    if (comptime options.enable_metrics) self.stats.compaction_sst_writes += 1;
                    offset = end;
                    continue;
                }
            }

            var sst = std.mem.zeroes(SstPage);
            sst.count = @intCast(chunk.len);
            @memcpy(sst.entries[0..chunk.len], chunk);
            const sst_id = try self.heap.writeSstPage(sst);
            if (comptime options.enable_metrics) self.stats.compaction_sst_writes += 1;
            try new_ids.append(alloc, sst_id);
            try new_min4.append(alloc, prefix32(&chunk[0].key, depth));
            try new_counts.append(alloc, sst.count);
            offset = end;
        }

        var new_node = std.mem.zeroes(NodePage);
        new_node.sorted_count = @intCast(new_ids.items.len);
        new_node.append_count = 0;
        new_node.child_commitments = old_node.child_commitments;
        @memcpy(new_node.sorted_slot_ids[0..new_ids.items.len], new_ids.items);
        @memcpy(new_node.sorted_min4[0..new_min4.items.len], new_min4.items);
        @memcpy(new_node.sorted_page_counts[0..new_counts.items.len], new_counts.items);

        try self.nodePut(depth, prefix, new_node);
        for (old_node.sorted_slot_ids[0..old_node.sorted_count]) |id| self.heap.freeSstPage(id);
        for (old_node.append_slot_ids[0..old_node.append_count]) |id| self.heap.freeSstPage(id);
        self.markDirty(depth, prefix);

        if (new_node.sorted_count >= S_MAX)
            self.compaction_queue.append(alloc, .{ .depth = depth, .prefix = prefix }) catch {};
        if (depth > 1 and (try self.countNodeEntries(depth, prefix)) < MERGE_THRESHOLD)
            self.compaction_queue.append(alloc, .{ .depth = depth, .prefix = prefix }) catch {};
    }

    /// Promote a full page to the append zone of the L(k+1) child node.
    /// Using the append zone preserves the sorted_min4 strict-ordering invariant:
    /// the child runs appendToSortedMerge when its append zone fills, building a
    /// correct sorted zone from scratch.
    fn promoteSstPage(self: *PrefixDB, parent_depth: u32, chunk: []const KvEntry) !void {
        const child_depth = parent_depth + 1;
        const child_prefix = prefixData(&chunk[0].key, child_depth);

        var sst = std.mem.zeroes(SstPage);
        sst.count = @intCast(chunk.len);
        @memcpy(sst.entries[0..chunk.len], chunk);
        const sst_id = try self.heap.writeSstPage(sst);

        // Build a sorted prefix16 filter over the chunk entries at child_depth.
        var filter = [_]u16{std.math.maxInt(u16)} ** PAGE_ENTRIES;
        for (chunk, 0..) |e, idx| filter[idx] = prefix16(&e.key, child_depth);

        try self.appendSstToNode(child_depth, child_prefix, sst_id, sst.count, filter);
    }

    /// §6.2: Merge all sorted pages; promote groups with ≥64 entries to L(k+1).
    fn upwardSplit(self: *PrefixDB, depth: u32, prefix: PrefixData) !void {
        const alloc = self.allocator;
        const old_node = (try self.nodeGet(depth, prefix)) orelse return;
        const child_depth = depth + 1;

        var all_entries = std.ArrayList(KvEntry).empty;
        defer all_entries.deinit(alloc);
        for (0..old_node.sorted_count) |si| {
            if (try self.heap.getSstPage(old_node.sorted_slot_ids[si])) |sst| {
                if (comptime options.enable_metrics) self.stats.compaction_sst_reads += 1;
                const cnt = old_node.sorted_page_counts[si];
                for (sst.entries[0..cnt]) |e| try all_entries.append(alloc, e);
            }
        }
        std.mem.sort(KvEntry, all_entries.items, {}, kvLessThan);

        var new_ids = std.ArrayList(PayloadSlotId).empty;
        defer new_ids.deinit(alloc);
        var new_min4 = std.ArrayList(u32).empty;
        defer new_min4.deinit(alloc);
        var new_counts = std.ArrayList(u8).empty;
        defer new_counts.deinit(alloc);

        var remaining = std.ArrayList(KvEntry).empty;
        defer remaining.deinit(alloc);

        var i: usize = 0;
        while (i < all_entries.items.len) {
            const cp = prefixData(&all_entries.items[i].key, child_depth);
            var j = i + 1;
            while (j < all_entries.items.len and
                prefixData(&all_entries.items[j].key, child_depth) == cp) j += 1;
            const group = all_entries.items[i..j];

            if (group.len >= PAGE_ENTRIES) {
                var off: usize = 0;
                while (off < group.len) {
                    const end = @min(off + PAGE_ENTRIES, group.len);
                    const chunk = group[off..end];
                    var cn = (try self.nodeGet(child_depth, cp)) orelse std.mem.zeroes(NodePage);
                    var sst = std.mem.zeroes(SstPage);
                    sst.count = @intCast(chunk.len);
                    @memcpy(sst.entries[0..chunk.len], chunk);
                    const sid = try self.heap.writeSstPage(sst);
                    if (comptime options.enable_metrics) self.stats.compaction_sst_writes += 1;
                    if (cn.sorted_count < S_MAX) {
                        const sc = cn.sorted_count;
                        cn.sorted_slot_ids[sc] = sid;
                        cn.sorted_min4[sc] = prefix32(&chunk[0].key, child_depth);
                        cn.sorted_page_counts[sc] = sst.count;
                        cn.sorted_count += 1;
                        try self.nodePut(child_depth, cp, cn);
                        self.markDirty(child_depth, cp);
                        if (cn.sorted_count >= S_MAX)
                            self.compaction_queue.append(alloc, .{ .depth = child_depth, .prefix = cp }) catch {};
                    } else {
                        // Child sorted zone full: keep entries in parent and free the
                        // just-written SST rather than leaking it.
                        self.heap.freeSstPage(sid);
                        for (chunk) |e| try remaining.append(alloc, e);
                        self.compaction_queue.append(alloc, .{ .depth = child_depth, .prefix = cp }) catch {};
                    }
                    off = end;
                }
            } else {
                for (group) |e| try remaining.append(alloc, e);
            }
            i = j;
        }

        var off: usize = 0;
        while (off < remaining.items.len) {
            const end = @min(off + PAGE_ENTRIES, remaining.items.len);
            const chunk = remaining.items[off..end];
            var sst = std.mem.zeroes(SstPage);
            sst.count = @intCast(chunk.len);
            @memcpy(sst.entries[0..chunk.len], chunk);
            const sid = try self.heap.writeSstPage(sst);
            if (comptime options.enable_metrics) self.stats.compaction_sst_writes += 1;
            try new_ids.append(alloc, sid);
            try new_min4.append(alloc, prefix32(&chunk[0].key, depth));
            try new_counts.append(alloc, sst.count);
            off = end;
        }

        var new_node = std.mem.zeroes(NodePage);
        new_node.sorted_count = @intCast(new_ids.items.len);
        new_node.append_count = old_node.append_count;
        new_node.child_commitments = old_node.child_commitments;
        @memcpy(new_node.sorted_slot_ids[0..new_ids.items.len], new_ids.items);
        @memcpy(new_node.sorted_min4[0..new_min4.items.len], new_min4.items);
        @memcpy(new_node.sorted_page_counts[0..new_counts.items.len], new_counts.items);
        for (0..old_node.append_count) |ai| {
            new_node.append_slot_ids[ai] = old_node.append_slot_ids[ai];
            new_node.append_page_counts[ai] = old_node.append_page_counts[ai];
            new_node.append_prefix16[ai] = old_node.append_prefix16[ai];
        }

        try self.nodePut(depth, prefix, new_node);
        for (old_node.sorted_slot_ids[0..old_node.sorted_count]) |id| self.heap.freeSstPage(id);
        self.markDirty(depth, prefix);
    }

    /// §6.3: Merge a sparse child node back into its parent's sorted zone.
    fn downwardMerge(self: *PrefixDB, depth: u32, prefix: PrefixData) !void {
        std.debug.assert(depth > 1);
        const alloc = self.allocator;
        const parent_depth = depth - 1;
        const parent_prefix: PrefixData = prefix >> STRIDE;

        const old_child = (try self.nodeGet(depth, prefix)) orelse return;
        const old_parent = (try self.nodeGet(parent_depth, parent_prefix)) orelse return;

        var merged = std.AutoHashMap(Key, Value).init(alloc);
        defer merged.deinit();
        for (0..old_parent.sorted_count) |si| {
            if (try self.heap.getSstPage(old_parent.sorted_slot_ids[si])) |sst| {
                if (comptime options.enable_metrics) self.stats.compaction_sst_reads += 1;
                const cnt = old_parent.sorted_page_counts[si];
                for (sst.entries[0..cnt]) |e| try merged.put(e.key, e.value);
            }
        }
        for (0..old_child.sorted_count) |si| {
            if (try self.heap.getSstPage(old_child.sorted_slot_ids[si])) |sst| {
                if (comptime options.enable_metrics) self.stats.compaction_sst_reads += 1;
                const cnt = old_child.sorted_page_counts[si];
                for (sst.entries[0..cnt]) |e| try merged.put(e.key, e.value);
            }
        }
        for (0..old_child.append_count) |ai| {
            if (try self.heap.getSstPage(old_child.append_slot_ids[ai])) |sst| {
                if (comptime options.enable_metrics) self.stats.compaction_sst_reads += 1;
                const cnt = old_child.append_page_counts[ai];
                for (sst.entries[0..cnt]) |e| try merged.put(e.key, e.value);
            }
        }

        var survivors = std.ArrayList(KvEntry).empty;
        defer survivors.deinit(alloc);
        var mit = merged.iterator();
        while (mit.next()) |kv| try survivors.append(alloc, .{ .key = kv.key_ptr.*, .value = kv.value_ptr.* });
        std.mem.sort(KvEntry, survivors.items, {}, kvLessThan);

        const pages_needed = (survivors.items.len + PAGE_ENTRIES - 1) / PAGE_ENTRIES;
        if (pages_needed > S_MAX) return;

        var new_ids = std.ArrayList(PayloadSlotId).empty;
        defer new_ids.deinit(alloc);
        var new_min4 = std.ArrayList(u32).empty;
        defer new_min4.deinit(alloc);
        var new_counts = std.ArrayList(u8).empty;
        defer new_counts.deinit(alloc);

        var offset: usize = 0;
        while (offset < survivors.items.len) {
            const end = @min(offset + PAGE_ENTRIES, survivors.items.len);
            const chunk = survivors.items[offset..end];
            var sst = std.mem.zeroes(SstPage);
            sst.count = @intCast(chunk.len);
            @memcpy(sst.entries[0..chunk.len], chunk);
            const sid = try self.heap.writeSstPage(sst);
            if (comptime options.enable_metrics) self.stats.compaction_sst_writes += 1;
            try new_ids.append(alloc, sid);
            try new_min4.append(alloc, prefix32(&chunk[0].key, parent_depth));
            try new_counts.append(alloc, sst.count);
            offset = end;
        }

        var new_parent = std.mem.zeroes(NodePage);
        new_parent.sorted_count = @intCast(new_ids.items.len);
        new_parent.append_count = old_parent.append_count;
        new_parent.child_commitments = old_parent.child_commitments;
        // Child is absorbed: clear its commitment slot so the parent's Merkle path is clean.
        new_parent.child_commitments[prefix & (CHILD_COUNT - 1)] = ZERO_HASH;
        @memcpy(new_parent.sorted_slot_ids[0..new_ids.items.len], new_ids.items);
        @memcpy(new_parent.sorted_min4[0..new_min4.items.len], new_min4.items);
        @memcpy(new_parent.sorted_page_counts[0..new_counts.items.len], new_counts.items);
        for (0..old_parent.append_count) |ai| {
            new_parent.append_slot_ids[ai] = old_parent.append_slot_ids[ai];
            new_parent.append_page_counts[ai] = old_parent.append_page_counts[ai];
            new_parent.append_prefix16[ai] = old_parent.append_prefix16[ai];
        }
        try self.nodePut(parent_depth, parent_prefix, new_parent);
        for (old_parent.sorted_slot_ids[0..old_parent.sorted_count]) |id| self.heap.freeSstPage(id);
        self.markDirty(parent_depth, parent_prefix);

        self.nodeRemove(depth, prefix);
        for (old_child.sorted_slot_ids[0..old_child.sorted_count]) |id| self.heap.freeSstPage(id);
        for (old_child.append_slot_ids[0..old_child.append_count]) |id| self.heap.freeSstPage(id);

        if (parent_depth > 1 and (try self.countNodeEntries(parent_depth, parent_prefix)) < MERGE_THRESHOLD)
            self.compaction_queue.append(alloc, .{ .depth = parent_depth, .prefix = parent_prefix }) catch {};
    }
};

// ─── Monotonic clock (Zig 0.16 has no std.time.nanoTimestamp) ─────────────────

fn monoNs() u64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s +
        @as(u64, @intCast(ts.nsec));
}

// ─── Commitment helpers ───────────────────────────────────────────────────────

/// Binary Merkle root over exactly CHILD_COUNT (64) hashes.
/// Six rounds of pairHash reduce 64 leaves to one root.
pub fn childMerkleRoot(commitments: [CHILD_COUNT]Hash) Hash {
    var level = commitments;
    var size: usize = CHILD_COUNT;
    while (size > 1) {
        var i: usize = 0;
        while (i < size / 2) : (i += 1) {
            level[i] = merkle.pairHash(&level[2 * i], &level[2 * i + 1]);
        }
        size /= 2;
    }
    return level[0];
}

// ─── Prefix helpers (§4.2.1, §7.1) ───────────────────────────────────────────

/// prefixData(K, d) = top 6d bits of K, zero-padded into a u64.
/// Handles depths up to 10 (60 bits); at STRIDE=6 with a 256-bit key, depth 42 is the physical max.
pub fn prefixData(key: *const Key, depth: u32) PrefixData {
    const top8: u64 = (@as(u64, key[0]) << 56) | (@as(u64, key[1]) << 48) |
        (@as(u64, key[2]) << 40) | (@as(u64, key[3]) << 32) |
        (@as(u64, key[4]) << 24) | (@as(u64, key[5]) << 16) |
        (@as(u64, key[6]) << 8)  |  @as(u64, key[7]);
    return top8 >> @intCast(64 - STRIDE * depth);
}

/// prefix32(K, k): the 32 bits of K immediately following the node's 6k-bit prefix.
pub fn prefix32(key: *const Key, depth: u32) u32 {
    const bit_offset = STRIDE * depth;
    const byte0: usize = bit_offset / 8;
    const shift: u6 = @intCast(8 - (bit_offset % 8));
    const raw: u64 = (@as(u64, key[byte0]) << 32) |
        (@as(u64, key[byte0 + 1]) << 24) |
        (@as(u64, key[byte0 + 2]) << 16) |
        (@as(u64, key[byte0 + 3]) << 8) |
        @as(u64, key[byte0 + 4]);
    return @truncate(raw >> shift);
}

/// prefix16(K, k): the 16 bits of K immediately following the node's 6k-bit prefix.
pub fn prefix16(key: *const Key, depth: u32) u16 {
    const bit_offset = STRIDE * depth;
    const byte0: usize = bit_offset / 8;
    const shift: u5 = @intCast(8 - (bit_offset % 8));
    const raw: u32 = (@as(u32, key[byte0]) << 16) |
        (@as(u32, key[byte0 + 1]) << 8) |
        @as(u32, key[byte0 + 2]);
    return @truncate(raw >> shift);
}

// ─── Private operation helpers ────────────────────────────────────────────────

fn kvLessThan(_: void, a: KvEntry, b: KvEntry) bool {
    return std.mem.order(u8, &a.key, &b.key) == .lt;
}

fn binarySearchSst(sst: *const SstPage, key: *const Key) ?Value {
    var lo: usize = 0;
    var hi: usize = sst.count;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        switch (std.mem.order(u8, &sst.entries[mid].key, key)) {
            .eq => return sst.entries[mid].value,
            .lt => lo = mid + 1,
            .gt => hi = mid,
        }
    }
    return null;
}

fn filterContains(filter: *const [PAGE_ENTRIES]u16, count: u8, target: u16) bool {
    var lo: usize = 0;
    var hi: usize = count;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (filter[mid] == target) return true;
        if (filter[mid] < target) lo = mid + 1 else hi = mid;
    }
    return false;
}

// ─── Tests ────────────────────────────────────────────────────────────────────

test {
    _ = @import("page_store.zig");
    _ = @import("cache.zig");
    _ = @import("wal.zig");
    _ = @import("block_journal.zig");
    _ = @import("kv_map.zig");
}

test "kv_map: write + flush + read returns correct value without SST walk" {
    var db = try PrefixDB.init(std.testing.allocator);
    defer db.deinit();

    const k = testKey(42);
    const v = testVal(0xDE);

    // Write and commit (flushes L0 to SST, clears L0).
    try db.write(k, v);
    _ = try db.commitBlock();

    // kv_map retains the value after L0 flush; read must return it.
    const result = try db.read(k);
    try std.testing.expectEqual(@as(?Value, v), result);
    try std.testing.expectEqual(@as(usize, 1), db.kv_map.count());
}

test "kv_map: overwrite reflected immediately" {
    var db = try PrefixDB.init(std.testing.allocator);
    defer db.deinit();

    const k = testKey(7);
    const v1 = testVal(0xAA);
    const v2 = testVal(0xBB);

    try db.write(k, v1);
    _ = try db.commitBlock();
    try db.write(k, v2);

    // Before second commit, kv_map has v2 and L0 also has v2.
    try std.testing.expectEqual(@as(?Value, v2), try db.read(k));

    _ = try db.commitBlock();
    // After second commit, L0 is flushed; kv_map still has v2.
    try std.testing.expectEqual(@as(?Value, v2), try db.read(k));
}

test "kv_map: SST read warms kv_map; eviction clears it" {
    // Use a disk-backed db so sst_cap=1 can evict (not SstCacheFull).
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const store = page_store.DiskStore{ .dir = tmp.dir, .io = std.testing.io };

    var db = try PrefixDB.openWithConfig(
        std.testing.allocator,
        .{ .node_cap = DEFAULT_NODE_CACHE_CAP, .sst_cap = 1 },
        store,
    );
    defer db.deinit();
    // Wire up the write-back callbacks (must be after db is in final location).
    db.enableWriteBack();

    // Keys with different byte[0] so they land in different d1 nodes and SST pages.
    // prefixData(key, 1) reads top 6 bits of byte[0]: k1→prefix 1, k2→prefix 2.
    var k1 = std.mem.zeroes(Key);
    k1[0] = 0x04; // top 6 bits = 1
    var k2 = std.mem.zeroes(Key);
    k2[0] = 0x08; // top 6 bits = 2
    const v1 = testVal(0x11);
    const v2 = testVal(0x22);

    // Write both keys and commit so they land in separate SST pages.
    try db.write(k1, v1);
    try db.write(k2, v2);
    _ = try db.commitBlock();

    // After commit, write()-sourced entries are in kv_map with WRITE_SST_ID.
    try std.testing.expectEqual(@as(?Value, v1), try db.read(k1));
    try std.testing.expectEqual(@as(?Value, v2), try db.read(k2));

    // Clear kv_map so that the next reads go cold to SST and warm the cache.
    db.kv_map.remove(k1);
    db.kv_map.remove(k2);
    try std.testing.expectEqual(@as(?Value, null), db.kv_map.get(k1));

    // Cold read for k1: SST hit → kv_map.putFromSst(k1, v1, page_id_A).
    try std.testing.expectEqual(@as(?Value, v1), try db.read(k1));
    try std.testing.expectEqual(@as(?Value, v1), db.kv_map.get(k1));

    // Cold read for k2: loads page B, evicts page A → kv_map entry for k1 removed.
    try std.testing.expectEqual(@as(?Value, v2), try db.read(k2));
    try std.testing.expectEqual(@as(?Value, null), db.kv_map.get(k1));
    // k2 is now warmed.
    try std.testing.expectEqual(@as(?Value, v2), db.kv_map.get(k2));
}

test "WAL: crash recovery restores committed blocks" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const store = page_store.DiskStore{ .dir = tmp.dir, .io = std.testing.io };

    const k1 = testKey(1);
    const v1 = testVal(0xAA);
    const k2 = testKey(2);
    const v2 = testVal(0xBB);

    // Session 1: write two blocks but do NOT flush (simulate crash).
    {
        var db = try PrefixDB.openWithConfig(std.testing.allocator, .{}, store);
        try db.write(k1, v1);
        _ = try db.commitBlock();
        try db.write(k2, v2);
        _ = try db.commitBlock();
        // Crash: deinit without calling flush.
        db.deinit();
    }

    // Session 2: reopen — WAL replay must restore both committed blocks.
    {
        var db = try PrefixDB.openWithConfig(std.testing.allocator, .{}, store);
        defer db.deinit();
        try std.testing.expectEqual(@as(?Value, v1), try db.read(k1));
        try std.testing.expectEqual(@as(?Value, v2), try db.read(k2));
    }
}

test "prefixData depth 1 extracts top 6 bits" {
    const key = [_]u8{0b10110100} ++ [_]u8{0} ** 31;
    try std.testing.expectEqual(@as(PrefixData, 0b101101), prefixData(&key, 1));
}

test "prefixData depth 5 extracts top 30 bits" {
    const key = [_]u8{ 0xFF, 0xFF, 0xFF, 0xFF } ++ [_]u8{0} ** 28;
    try std.testing.expectEqual(@as(PrefixData, 0x3FFF_FFFF), prefixData(&key, 5));
}

test "prefixData depth 6 extracts top 36 bits" {
    const key = [_]u8{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF } ++ [_]u8{0} ** 27;
    // top 36 bits all-ones = 2^36 - 1 = 0xF_FFFF_FFFF
    try std.testing.expectEqual(@as(PrefixData, 0xF_FFFF_FFFF), prefixData(&key, 6));
}

test "prefix32 depth 1 — bits [6,38) of key" {
    const key = [_]u8{ 0xFC, 0xFF, 0xFF, 0xFF, 0x00 } ++ [_]u8{0} ** 27;
    try std.testing.expectEqual(@as(u32, 0x3FFF_FFC0), prefix32(&key, 1));
}

test "prefix32 depth 4 — bit_in_byte = 0" {
    const key = [_]u8{0} ** 3 ++ [_]u8{ 0xAA, 0xBB, 0xCC, 0xDD, 0xEE } ++ [_]u8{0} ** 24;
    try std.testing.expectEqual(@as(u32, 0xAABB_CCDD), prefix32(&key, 4));
}

test "prefix16 depth 1 — bits [6,22) of key" {
    const key = [_]u8{ 0xFC, 0x00, 0xF0 } ++ [_]u8{0} ** 29;
    try std.testing.expectEqual(@as(u16, 0x003C), prefix16(&key, 1));
}

test "prefix16 depth 4 — bit_in_byte = 0" {
    const key = [_]u8{0} ** 3 ++ [_]u8{ 0xAB, 0xCD, 0xFF } ++ [_]u8{0} ** 26;
    try std.testing.expectEqual(@as(u16, 0xABCD), prefix16(&key, 4));
}

test "prefix16 sub-prefix promotion check — top 6 bits" {
    const uniform_low: u16 = 0b0000_0100_0000_0000;
    const uniform_high: u16 = 0b0000_0111_1111_1111;
    const different: u16 = 0b0000_1000_0000_0000;
    try std.testing.expectEqual(uniform_low >> 10, uniform_high >> 10);
    try std.testing.expect((uniform_low >> 10) != (different >> 10));
}

test "RoutingTable put and get" {
    var rt = RoutingTable.init(std.testing.allocator);
    defer rt.deinit();
    try rt.put(3, 0b101101, 42);
    try std.testing.expectEqual(@as(?NodePageId, 42), rt.get(3, 0b101101));
    try std.testing.expectEqual(@as(?NodePageId, null), rt.get(3, 0b000000));
}

test "L0Buffer append and prefixCount" {
    var l0 = L0Buffer.init(std.testing.allocator);
    defer l0.deinit();
    const key_a = [_]u8{0b10110100} ++ [_]u8{0} ** 31;
    const key_b = [_]u8{0b00000000} ++ [_]u8{0} ** 31;
    try l0.append(.{ .key = key_a, .value = [_]u8{1} ** 32 });
    try l0.append(.{ .key = key_b, .value = [_]u8{2} ** 32 });
    try std.testing.expectEqual(@as(usize, 1), l0.prefixCount(45));
    try std.testing.expectEqual(@as(usize, 1), l0.prefixCount(0));
    try std.testing.expectEqual(@as(usize, 0), l0.prefixCount(1));
}

test "Heap write and retrieve node page" {
    var heap = try Heap.init(std.testing.allocator, .{ .node_cap = 8, .sst_cap = 32 }, null);
    defer heap.deinit();
    var page = std.mem.zeroes(NodePage);
    page.sorted_count = 2;
    page.append_count = 1;
    // depth=1 → pinned pool
    const id = try heap.writeNodePage(1, page);
    const got = (try heap.getNodePage(id)).?;
    try std.testing.expectEqual(@as(u8, 2), got.sorted_count);
    try std.testing.expectEqual(@as(u8, 1), got.append_count);
    heap.freeNodePage(id);
    try std.testing.expectError(error.NodeNotInCache, heap.getNodePage(id));
}

// ─── Write / Read operation tests ─────────────────────────────────────────────

fn testKey(index: u8) Key {
    var k = std.mem.zeroes(Key);
    k[31] = index;
    return k;
}

fn testVal(index: u8) Value {
    return [_]u8{index} ** 32;
}

test "read returns null for unknown key" {
    var db = try PrefixDB.init(std.testing.allocator);
    defer db.deinit();
    try std.testing.expectEqual(@as(?Value, null), try db.read(testKey(7)));
}

test "write then read from L0" {
    var db = try PrefixDB.init(std.testing.allocator);
    defer db.deinit();
    try db.write(testKey(1), testVal(0xAA));
    try std.testing.expectEqual(@as(?Value, testVal(0xAA)), try db.read(testKey(1)));
}

test "L0 overwrite — most recent value returned" {
    var db = try PrefixDB.init(std.testing.allocator);
    defer db.deinit();
    try db.write(testKey(5), testVal(0x11));
    try db.write(testKey(5), testVal(0x22));
    try db.write(testKey(5), testVal(0x33));
    try std.testing.expectEqual(@as(?Value, testVal(0x33)), try db.read(testKey(5)));
}

test "write 64 keys triggers L0 flush to L1 append zone" {
    var db = try PrefixDB.init(std.testing.allocator);
    defer db.deinit();

    for (0..PAGE_ENTRIES) |i| {
        try db.write(testKey(@intCast(i)), testVal(@intCast(i)));
    }

    try std.testing.expectEqual(@as(usize, 0), db.l0.entries.items.len);
    try std.testing.expect(db.arena.exists(1, 0));

    const node = db.arena.get(1, 0).?.*;
    try std.testing.expectEqual(@as(u8, 0), node.sorted_count);
    try std.testing.expectEqual(@as(u8, 1), node.append_count);
}

test "read keys from L1 append zone after flush" {
    var db = try PrefixDB.init(std.testing.allocator);
    defer db.deinit();

    for (0..PAGE_ENTRIES) |i| {
        try db.write(testKey(@intCast(i)), testVal(@intCast(i)));
    }

    for (0..PAGE_ENTRIES) |i| {
        const got = try db.read(testKey(@intCast(i)));
        try std.testing.expectEqual(@as(?Value, testVal(@intCast(i))), got);
    }

    try std.testing.expectEqual(@as(?Value, null), try db.read(testKey(0xFF)));
}

test "L0 value overrides L1 for the same key" {
    var db = try PrefixDB.init(std.testing.allocator);
    defer db.deinit();

    for (0..PAGE_ENTRIES) |i| {
        try db.write(testKey(@intCast(i)), testVal(0xAA));
    }

    try db.write(testKey(0), testVal(0xBB));
    try std.testing.expectEqual(@as(?Value, testVal(0xBB)), try db.read(testKey(0)));

    for (1..PAGE_ENTRIES) |i| {
        try std.testing.expectEqual(@as(?Value, testVal(0xAA)), try db.read(testKey(@intCast(i))));
    }
}

test "keys from a different prefix group remain in L0 after flush" {
    var db = try PrefixDB.init(std.testing.allocator);
    defer db.deinit();

    var other_key = std.mem.zeroes(Key);
    other_key[0] = 0x04;
    try db.write(other_key, testVal(0xFF));

    for (0..PAGE_ENTRIES) |i| {
        try db.write(testKey(@intCast(i)), testVal(@intCast(i)));
    }

    try std.testing.expectEqual(@as(usize, 1), db.l0.entries.items.len);
    try std.testing.expectEqual(@as(?Value, testVal(0xFF)), try db.read(other_key));
}

test "two flushes: 128 distinct keys across two SST pages in append zone" {
    var db = try PrefixDB.initCapacity(std.testing.allocator, DEFAULT_NODE_CACHE_CAP, 2048);
    defer db.deinit();

    for (0..PAGE_ENTRIES) |i| {
        try db.write(testKey(@intCast(i)), testVal(@intCast(i)));
    }
    for (PAGE_ENTRIES..2 * PAGE_ENTRIES) |i| {
        var k = std.mem.zeroes(Key);
        k[30] = 1;
        k[31] = @intCast(i - PAGE_ENTRIES);
        try db.write(k, testVal(@intCast(i)));
    }

    const node = db.arena.get(1, 0).?.*;
    try std.testing.expectEqual(@as(u8, 2), node.append_count);

    for (0..PAGE_ENTRIES) |i| {
        try std.testing.expectEqual(@as(?Value, testVal(@intCast(i))), try db.read(testKey(@intCast(i))));
    }
    for (PAGE_ENTRIES..2 * PAGE_ENTRIES) |i| {
        var k = std.mem.zeroes(Key);
        k[30] = 1;
        k[31] = @intCast(i - PAGE_ENTRIES);
        try std.testing.expectEqual(@as(?Value, testVal(@intCast(i))), try db.read(k));
    }
}

fn testKeyBatch(batch: u8, index: u8) Key {
    var k = std.mem.zeroes(Key);
    k[1] = batch;
    k[2] = index;
    return k;
}

test "deduplication in L0 flush — only latest value persisted" {
    var db = try PrefixDB.init(std.testing.allocator);
    defer db.deinit();

    try db.write(testKey(0), testVal(0x11));
    for (1..PAGE_ENTRIES) |i| {
        try db.write(testKey(@intCast(i)), testVal(@intCast(i)));
    }
    try std.testing.expectEqual(@as(?Value, testVal(0x11)), try db.read(testKey(0)));

    try db.write(testKey(0), testVal(0x22));
    try std.testing.expectEqual(@as(?Value, testVal(0x22)), try db.read(testKey(0)));
}

// ─── Compaction tests ─────────────────────────────────────────────────────────

test "appendToSortedMerge: clears append zone and keeps all keys readable" {
    var db = try PrefixDB.initCapacity(std.testing.allocator, 512, 4096);
    defer db.deinit();

    for (0..A_MAX) |batch| {
        for (0..PAGE_ENTRIES) |i| {
            try db.write(testKeyBatch(@intCast(batch), @intCast(i)), testVal(@intCast(i)));
        }
    }

    const before = db.arena.get(1, 0).?.*;
    try std.testing.expectEqual(@as(u8, A_MAX), before.append_count);
    try std.testing.expect(db.compaction_queue.items.len > 0);

    try db.runCompaction();

    const after = db.arena.get(1, 0).?.*;
    try std.testing.expectEqual(@as(u8, 0), after.append_count);

    for (0..A_MAX) |batch| {
        for (0..PAGE_ENTRIES) |i| {
            const got = try db.read(testKeyBatch(@intCast(batch), @intCast(i)));
            try std.testing.expectEqual(@as(?Value, testVal(@intCast(i))), got);
        }
    }
}

test "appendToSortedMerge: newest value wins when same key appears in multiple append pages" {
    var db = try PrefixDB.initCapacity(std.testing.allocator, 512, 4096);
    defer db.deinit();

    try db.write(testKeyBatch(0, 0), testVal(0x11));
    for (1..PAGE_ENTRIES) |i| {
        try db.write(testKeyBatch(0, @intCast(i)), testVal(@intCast(i)));
    }

    for (1..A_MAX) |batch| {
        const use_val: u8 = if (batch == 4) 0x99 else @intCast(batch);
        try db.write(testKeyBatch(0, 0), testVal(use_val));
        for (1..PAGE_ENTRIES) |i| {
            try db.write(testKeyBatch(@intCast(batch), @intCast(i)), testVal(@intCast(i)));
        }
    }

    try db.runCompaction();

    const got = try db.read(testKeyBatch(0, 0));
    try std.testing.expectEqual(@as(?Value, testVal(A_MAX - 1)), got);
}

test "sub-prefix promotion: uniform sub-prefix page moves to depth-2 node" {
    var db = try PrefixDB.initCapacity(std.testing.allocator, 512, 4096);
    defer db.deinit();

    for (0..A_MAX) |batch| {
        for (0..PAGE_ENTRIES) |i| {
            try db.write(testKeyBatch(@intCast(batch), @intCast(i)), testVal(@intCast(i)));
        }
    }

    try db.runCompaction();

    // With promoteSstPage routing to append zone, pages may propagate past
    // depth-2 all the way to depth-3 before settling. Check any depth > 1.
    var found_deeper = false;
    outer: for (2..db.max_depth_used + 1) |d| {
        const dd: u32 = @intCast(d);
        for (0..64) |p| {
            const has = switch (dd) {
                2 => db.arena.exists(2, @intCast(p)),
                3 => db.arena.exists(3, @intCast(p)),
                else => db.routing.get(dd, @intCast(p)) != null,
            };
            if (has) {
                found_deeper = true;
                break :outer;
            }
        }
    }
    try std.testing.expect(found_deeper);

    for (0..A_MAX) |batch| {
        for (0..PAGE_ENTRIES) |i| {
            const got = try db.read(testKeyBatch(@intCast(batch), @intCast(i)));
            try std.testing.expectEqual(@as(?Value, testVal(@intCast(i))), got);
        }
    }
}

test "upwardSplit: promoted depth-2 node triggers split when sorted zone fills" {
    var db = try PrefixDB.initCapacity(std.testing.allocator, 4096, 32768);
    defer db.deinit();

    var node2 = std.mem.zeroes(NodePage);
    for (0..S_MAX) |si| {
        var sst = std.mem.zeroes(SstPage);
        sst.count = 1;
        sst.entries[0].key[31] = @intCast(si);
        sst.entries[0].value = testVal(@intCast(si));
        const sid = try db.heap.writeSstPage(sst);
        node2.sorted_slot_ids[si] = sid;
        node2.sorted_min4[si] = prefix32(&sst.entries[0].key, 2);
        node2.sorted_page_counts[si] = 1;
        node2.sorted_count += 1;
    }
    db.arena.put(2, 0, node2);

    try db.compaction_queue.append(db.allocator, .{ .depth = 2, .prefix = 0 });
    try db.runCompaction();

    if (db.arena.get(2, 0)) |p| {
        const n = p.*;
        try std.testing.expectEqual(@as(u8, 0), n.sorted_count);
    }
    const d3n = db.arena.get(3, 0).?.*;
    try std.testing.expectEqual(@as(u8, 2), d3n.sorted_count);
}

test "commitBlock: empty db returns ZERO_HASH root" {
    var db = try PrefixDB.init(std.testing.allocator);
    defer db.deinit();
    const root = try db.commitBlock();
    try std.testing.expectEqual(ZERO_HASH, root);
}

test "commitBlock: deterministic — same writes yield same root" {
    var db1 = try PrefixDB.init(std.testing.allocator);
    defer db1.deinit();
    var db2 = try PrefixDB.init(std.testing.allocator);
    defer db2.deinit();

    for (0..PAGE_ENTRIES) |i| {
        try db1.write(testKey(@intCast(i)), testVal(@intCast(i)));
        try db2.write(testKey(@intCast(i)), testVal(@intCast(i)));
    }

    const r1 = try db1.commitBlock();
    const r2 = try db2.commitBlock();
    try std.testing.expectEqual(r1, r2);
    try std.testing.expect(!std.mem.eql(u8, &r1, &ZERO_HASH));
}

test "commitBlock: different writes yield different roots" {
    var db1 = try PrefixDB.init(std.testing.allocator);
    defer db1.deinit();
    var db2 = try PrefixDB.init(std.testing.allocator);
    defer db2.deinit();

    try db1.write(testKey(1), testVal(0xAA));
    try db2.write(testKey(1), testVal(0xBB));

    const r1 = try db1.commitBlock();
    const r2 = try db2.commitBlock();
    try std.testing.expect(!std.mem.eql(u8, &r1, &r2));
}

test "commitBlock: root stable after second call with no new writes" {
    var db = try PrefixDB.init(std.testing.allocator);
    defer db.deinit();

    for (0..PAGE_ENTRIES) |i| {
        try db.write(testKey(@intCast(i)), testVal(@intCast(i)));
    }
    const r1 = try db.commitBlock();
    const r2 = try db.commitBlock();
    try std.testing.expectEqual(r1, r2);
}

test "downwardMerge: sparse child node is absorbed into parent" {
    var db = try PrefixDB.initCapacity(std.testing.allocator, 512, 4096);
    defer db.deinit();

    const child_prefix: PrefixData = 0;
    var child_node = std.mem.zeroes(NodePage);
    var sst = std.mem.zeroes(SstPage);
    sst.count = 5;
    for (0..5) |idx| {
        sst.entries[idx].key[31] = @intCast(idx + 200);
        sst.entries[idx].value = testVal(@intCast(idx + 200));
    }
    const csst_id = try db.heap.writeSstPage(sst);
    child_node.sorted_slot_ids[0] = csst_id;
    child_node.sorted_min4[0] = prefix32(&sst.entries[0].key, 2);
    child_node.sorted_page_counts[0] = 5;
    child_node.sorted_count = 1;
    db.arena.put(2, child_prefix, child_node);

    var parent_node = std.mem.zeroes(NodePage);
    var psst = std.mem.zeroes(SstPage);
    psst.count = 3;
    for (0..3) |idx| {
        psst.entries[idx].key[31] = @intCast(idx);
        psst.entries[idx].value = testVal(@intCast(idx));
    }
    const psst_id = try db.heap.writeSstPage(psst);
    parent_node.sorted_slot_ids[0] = psst_id;
    parent_node.sorted_min4[0] = prefix32(&psst.entries[0].key, 1);
    parent_node.sorted_page_counts[0] = 3;
    parent_node.sorted_count = 1;
    db.arena.put(1, 0, parent_node);

    try db.compaction_queue.append(db.allocator, .{ .depth = 2, .prefix = child_prefix });
    try db.runCompaction();

    try std.testing.expect(!db.arena.exists(2, child_prefix));

    const new_parent = db.arena.get(1, 0).?.*;
    var total: u32 = 0;
    for (new_parent.sorted_slot_ids[0..new_parent.sorted_count]) |id| {
        total += (try db.heap.getSstPage(id)).?.count;
    }
    try std.testing.expectEqual(@as(u32, 8), total);
}
