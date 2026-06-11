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
pub const TOMBSTONE = t.TOMBSTONE;
pub const KvEntry = t.KvEntry;
pub const NodePageId = t.NodePageId;
pub const PayloadSlotId = t.PayloadSlotId;
pub const PrefixData = t.PrefixData;
pub const SstPage = t.SstPage;
pub const NodePage = t.NodePage;
pub const CommitmentPage = t.CommitmentPage;
pub const CommitmentPageId = t.CommitmentPageId;
pub const CMT_NONE = t.CMT_NONE;

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
    /// Commitment page ids served from the free list instead of fresh allocation.
    cmt_pages_reused: u64 = 0,
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
    /// Page ids served from the free lists instead of growing the files.
    node_pages_reused: u64 = 0,
    sst_pages_reused: u64 = 0,
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

// ─── Deferred-reuse free list for on-disk page ids ────────────────────────────
//
// Page slots in the container files are reused instead of growing forever.
// Reuse must not break crash recovery: the last durable manifest (plus the node
// pages it references) may still point at a page freed *after* that manifest
// was written.  Ids therefore quarantine in `pending` until the next manifest
// — which by construction no longer references them — is durably on disk; only
// then do they become allocatable.

pub const FreeList = struct {
    /// Ids dead in the last durable manifest — safe to reuse now.
    free: std.ArrayList(u32) = .empty,
    /// Ids freed since the last manifest write — reusable after the next one.
    pending: std.ArrayList(u32) = .empty,

    pub fn deinit(self: *FreeList, allocator: std.mem.Allocator) void {
        self.free.deinit(allocator);
        self.pending.deinit(allocator);
    }

    /// Quarantine a dead id until the next manifest checkpoint.
    pub fn release(self: *FreeList, allocator: std.mem.Allocator, id: u32) !void {
        try self.pending.append(allocator, id);
    }

    /// Pop a reusable id, or null when a fresh id must be allocated.
    pub fn acquire(self: *FreeList) ?u32 {
        return self.free.pop();
    }

    /// All ids that the manifest being written right now does not reference.
    /// Both lists qualify: once that manifest is durable, `pending` is dead too.
    pub fn totalLen(self: *const FreeList) u32 {
        return @intCast(self.free.items.len + self.pending.items.len);
    }

    /// Append free ++ pending into `out` (manifest serialisation order).
    pub fn appendAllTo(self: *const FreeList, allocator: std.mem.Allocator, out: *std.ArrayList(u32)) !void {
        try out.appendSlice(allocator, self.free.items);
        try out.appendSlice(allocator, self.pending.items);
    }

    /// The manifest excluding `pending`'s referents is durable: promote.
    pub fn promote(self: *FreeList, allocator: std.mem.Allocator) !void {
        try self.free.appendSlice(allocator, self.pending.items);
        self.pending.clearRetainingCapacity();
    }

    /// Restore from a recovered manifest: everything listed is immediately reusable.
    pub fn restore(self: *FreeList, allocator: std.mem.Allocator, ids: []const u32) !void {
        try self.free.appendSlice(allocator, ids);
    }
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
    // Monotonically-increasing counter; fresh node ids come from here when the
    // free list is empty.
    next_node_id: NodePageId,
    // Reusable node-page ids (deferred across one manifest checkpoint).
    node_free: FreeList = .{},

    // All depths: SST (KV) pages in a bounded LRU cache.
    sst_cache: cache_mod.LruCache(SstPage),
    // Monotonically-increasing counter for fresh SST page IDs.
    next_sst_id: PayloadSlotId,
    // Reusable SST page ids (deferred across one manifest checkpoint).
    sst_free: FreeList = .{},

    // Optional disk stores for node pages (write-through and miss-reload).
    node_store: ?page_store.NodePageStore,
    // sst_store reserved for a future release when the on-disk format includes count.
    sst_store: ?page_store.SstPageStore,
    // Disk store for commitment pages (CoW flush + lazy reload of deep pages).
    cmt_store: ?page_store.CommitmentPageStore,

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
            .cmt_store = if (store) |s| page_store.CommitmentPageStore.init(s.dir, s.io) else null,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Heap) void {
        self.node_cache.deinit(self.allocator);
        self.sst_cache.deinit(self.allocator);
        self.node_free.deinit(self.allocator);
        self.sst_free.deinit(self.allocator);
    }

    /// Next node-page id: reuse a reclaimed slot when one is available.
    pub fn allocNodeId(self: *Heap) NodePageId {
        if (self.node_free.acquire()) |id| {
            if (comptime options.enable_metrics) self.heap_stats.node_pages_reused += 1;
            return id;
        }
        const id = self.next_node_id;
        self.next_node_id += 1;
        return id;
    }

    /// Next SST page id: reuse a reclaimed slot when one is available.
    pub fn allocSstId(self: *Heap) PayloadSlotId {
        if (self.sst_free.acquire()) |id| {
            if (comptime options.enable_metrics) self.heap_stats.sst_pages_reused += 1;
            return id;
        }
        const id = self.next_sst_id;
        self.next_sst_id += 1;
        return id;
    }

    /// Write a node page.  Refuse without a disk store if the cache would need to evict.
    /// Write-back: the page reaches disk when the LRU evicts it via nodeEvictCallback.
    pub fn writeNodePage(self: *Heap, depth: u32, page: NodePage) !NodePageId {
        _ = depth;
        if (self.node_cache.len >= self.node_cache.cap and self.node_store == null) {
            return error.NodeCacheFull;
        }
        const id = self.allocNodeId();
        try self.node_cache.put(id, page);
        return id;
    }

    /// Write an SST page.  Without a disk store the cache acts as a bounded pool.
    /// Write-back: the page reaches disk when the LRU evicts it via sstLruEvictCallback.
    pub fn writeSstPage(self: *Heap, page: SstPage) !PayloadSlotId {
        if (self.sst_store == null and self.sst_cache.len >= self.sst_cache.cap)
            return error.SstCacheFull;
        const id = self.allocSstId();
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

    pub fn freeNodePage(self: *Heap, id: NodePageId) !void {
        self.node_cache.remove(id);
        try self.node_free.release(self.allocator, id);
    }

    pub fn freeSstPage(self: *Heap, id: PayloadSlotId) !void {
        self.sst_cache.remove(id);
        try self.sst_free.release(self.allocator, id);
    }
};

/// How many commitBlock calls trigger an automatic flush to disk.
const FLUSH_INTERVAL: u32 = 64;

/// Deepest depth at which nodes may exist.  PrefixData packs one 6-bit stride
/// per level into a u64 (10 levels max), and commitBlock evaluates child slots
/// one stride below the deepest node, so node depth stops one level short of
/// the prefixData limit.  Hash-distributed keys never approach this bound;
/// adversarial sequential keys hit it and get error.NodeSaturated instead of
/// the silent prefix truncation (UB) the unguarded code produced.
pub const MAX_NODE_DEPTH: u32 = 9;

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
    /// FIFO of nodes awaiting compaction; consumed from `compaction_head`.
    compaction_queue: std.ArrayList(NodeCoord),
    /// Mirror set of queued coords — prevents duplicate queue entries.
    compaction_queued: std.AutoHashMap(NodeCoord, void),
    /// Index of the next coord to dequeue (FIFO over the backing array).
    compaction_head: usize = 0,
    /// Flush-dirty bitmaps: set on every write; cleared when the node is written to disk.
    d1_dirty_flush: u64,
    d2_dirty_flush: [64]u64,
    d3_dirty_flush: []u64,   // len = 4096, heap-allocated
    /// Last disk-persisted NodePageId for each d1/d2/d3 prefix (for manifest routing entries).
    d1_node_ids: [64]?NodePageId,
    d2_node_ids: []?NodePageId,   // len = 4096, heap-allocated
    d3_node_ids: []?NodePageId,   // len = 262144, heap-allocated
    /// Block number of the last modification per d1/d2/d3 node, used to
    /// age-gate the amortised write-back (only cold dirty nodes are flushed).
    d1_last_write: [64]u32 = [_]u32{0} ** 64,
    d2_last_write: []u32,   // len = 4096, heap-allocated
    d3_last_write: []u32,   // len = 262144, heap-allocated

    // ─── Commitment tree (docs/commitment_redesign.md) ───────────────────────
    //
    // Canonical sparse binary trie over the key-value mapping, cached at 6-bit
    // strides in CommitmentPages.  Fully decoupled from the storage tree:
    // compaction never touches these, and values are invariant under data
    // movement between node buffers.

    /// Depth-0 page: 64 depth-1 commitments as leaves, state root at h[1].
    /// Memory-only; rebuilt from depth-1 pages (or gathers) after open.
    cmt_d0: CommitmentPage,
    cmt_d1: []CommitmentPage,     // len = 64, heap-allocated; valid iff exists bit
    cmt_d1_exists: u64,
    cmt_d2: []CommitmentPage,     // len = 4096, heap-allocated
    cmt_d2_exists: []u64,         // len = 64
    /// Depth ≥ 3 commitment pages, created/loaded lazily.
    cmt_deep: std.AutoHashMap(NodeCoord, *CommitmentPage),
    /// Last persisted id per deep page (lazy reload + manifest routing).
    cmt_deep_ids: std.AutoHashMap(NodeCoord, CommitmentPageId),
    /// Deep pages with unflushed changes.
    cmt_deep_flush: std.AutoHashMap(NodeCoord, void),
    /// Flush-dirty bitmaps + ages + persisted ids for d1/d2 commitment pages.
    cmt_d1_flush: u64,
    cmt_d2_flush: []u64,          // len = 64
    cmt_d1_ids: [64]?CommitmentPageId,
    cmt_d2_ids: []?CommitmentPageId,   // len = 4096
    cmt_d1_last: [64]u32 = [_]u32{0} ** 64,
    cmt_d2_last: []u32,           // len = 4096
    next_cmt_id: CommitmentPageId = 0,
    /// Reusable commitment-page ids (deferred across one manifest checkpoint).
    cmt_free: FreeList = .{},
    /// Keys written (incl. tombstones) since the last commitBlock; the sole
    /// source of commitment dirtiness (write-stream derived, §4.1).
    block_keys: std.ArrayList(Key),
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
        const d3_dirty_flush = try allocator.alloc(u64, 4096);
        errdefer allocator.free(d3_dirty_flush);
        @memset(d3_dirty_flush, 0);
        const d2_last_write = try allocator.alloc(u32, 4096);
        errdefer allocator.free(d2_last_write);
        @memset(d2_last_write, 0);
        const d3_last_write = try allocator.alloc(u32, 262144);
        errdefer allocator.free(d3_last_write);
        @memset(d3_last_write, 0);
        // Commitment-tree storage (pages accessed only when their exists bit is set).
        const cmt_d1 = try allocator.alloc(CommitmentPage, 64);
        errdefer allocator.free(cmt_d1);
        const cmt_d2 = try allocator.alloc(CommitmentPage, 4096);
        errdefer allocator.free(cmt_d2);
        const cmt_d2_exists = try allocator.alloc(u64, 64);
        errdefer allocator.free(cmt_d2_exists);
        @memset(cmt_d2_exists, 0);
        const cmt_d2_flush = try allocator.alloc(u64, 64);
        errdefer allocator.free(cmt_d2_flush);
        @memset(cmt_d2_flush, 0);
        const cmt_d2_ids = try allocator.alloc(?CommitmentPageId, 4096);
        errdefer allocator.free(cmt_d2_ids);
        @memset(cmt_d2_ids, null);
        const cmt_d2_last = try allocator.alloc(u32, 4096);
        errdefer allocator.free(cmt_d2_last);
        @memset(cmt_d2_last, 0);
        var routing = RoutingTable.init(allocator);
        errdefer routing.deinit();
        return .{
            .l0 = L0Buffer.init(allocator),
            .arena = arena,
            .routing = routing,
            .heap = heap,
            .compaction_queue = std.ArrayList(NodeCoord).empty,
            .compaction_queued = std.AutoHashMap(NodeCoord, void).init(allocator),
            .d1_dirty_flush = 0,
            .d2_dirty_flush = [_]u64{0} ** 64,
            .d3_dirty_flush = d3_dirty_flush,
            .d1_node_ids = [_]?NodePageId{null} ** 64,
            .d2_node_ids = d2_node_ids,
            .d3_node_ids = d3_node_ids,
            .d2_last_write = d2_last_write,
            .d3_last_write = d3_last_write,
            .cmt_d0 = CommitmentPage.EMPTY,
            .cmt_d1 = cmt_d1,
            .cmt_d1_exists = 0,
            .cmt_d2 = cmt_d2,
            .cmt_d2_exists = cmt_d2_exists,
            .cmt_deep = std.AutoHashMap(NodeCoord, *CommitmentPage).init(allocator),
            .cmt_deep_ids = std.AutoHashMap(NodeCoord, CommitmentPageId).init(allocator),
            .cmt_deep_flush = std.AutoHashMap(NodeCoord, void).init(allocator),
            .cmt_d1_flush = 0,
            .cmt_d2_flush = cmt_d2_flush,
            .cmt_d1_ids = [_]?CommitmentPageId{null} ** 64,
            .cmt_d2_ids = cmt_d2_ids,
            .cmt_d2_last = cmt_d2_last,
            .block_keys = .empty,
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
        const d3_dirty_flush = try allocator.alloc(u64, 4096);
        errdefer allocator.free(d3_dirty_flush);
        @memset(d3_dirty_flush, 0);
        const d2_last_write = try allocator.alloc(u32, 4096);
        errdefer allocator.free(d2_last_write);
        @memset(d2_last_write, 0);
        const d3_last_write = try allocator.alloc(u32, 262144);
        errdefer allocator.free(d3_last_write);
        @memset(d3_last_write, 0);
        const cmt_d1 = try allocator.alloc(CommitmentPage, 64);
        errdefer allocator.free(cmt_d1);
        const cmt_d2 = try allocator.alloc(CommitmentPage, 4096);
        errdefer allocator.free(cmt_d2);
        const cmt_d2_exists = try allocator.alloc(u64, 64);
        errdefer allocator.free(cmt_d2_exists);
        @memset(cmt_d2_exists, 0);
        const cmt_d2_flush = try allocator.alloc(u64, 64);
        errdefer allocator.free(cmt_d2_flush);
        @memset(cmt_d2_flush, 0);
        const cmt_d2_ids = try allocator.alloc(?CommitmentPageId, 4096);
        errdefer allocator.free(cmt_d2_ids);
        @memset(cmt_d2_ids, null);
        const cmt_d2_last = try allocator.alloc(u32, 4096);
        errdefer allocator.free(cmt_d2_last);
        @memset(cmt_d2_last, 0);
        var cmt_d1_exists: u64 = 0;
        var cmt_d1_ids = [_]?CommitmentPageId{null} ** 64;
        var cmt_deep_ids = std.AutoHashMap(NodeCoord, CommitmentPageId).init(allocator);
        errdefer cmt_deep_ids.deinit();
        var d1_node_ids = [_]?NodePageId{null} ** 64;
        var max_depth_used: u32 = 2;
        for (manifest.routes) |r| {
            if (r.depth <= 2) {
                const page = try heap.node_store.?.read(r.node_id);
                arena.put(r.depth, r.prefix, page);
                if (r.depth == 1) {
                    d1_node_ids[@intCast(r.prefix)] = r.node_id;
                    if (r.cmt_page_id != CMT_NONE) {
                        cmt_d1[@intCast(r.prefix)] = try heap.cmt_store.?.read(r.cmt_page_id);
                        cmt_d1_exists |= @as(u64, 1) << @as(u6, @intCast(r.prefix));
                        cmt_d1_ids[@intCast(r.prefix)] = r.cmt_page_id;
                    }
                } else {
                    d2_node_ids[@intCast(r.prefix)] = r.node_id;
                    if (r.cmt_page_id != CMT_NONE) {
                        cmt_d2[@intCast(r.prefix)] = try heap.cmt_store.?.read(r.cmt_page_id);
                        cmt_d2_exists[@intCast(r.prefix >> 6)] |= @as(u64, 1) << @as(u6, @intCast(r.prefix & 63));
                        cmt_d2_ids[@intCast(r.prefix)] = r.cmt_page_id;
                    }
                }
            } else if (r.depth == 3) {
                const page = try heap.node_store.?.read(r.node_id);
                arena.put(3, r.prefix, page);
                d3_node_ids[@intCast(r.prefix)] = r.node_id;
                if (r.cmt_page_id != CMT_NONE)
                    try cmt_deep_ids.put(.{ .depth = 3, .prefix = r.prefix }, r.cmt_page_id);
                if (max_depth_used < 3) max_depth_used = 3;
            } else {
                try routing.put(r.depth, r.prefix, r.node_id);
                if (r.cmt_page_id != CMT_NONE)
                    try cmt_deep_ids.put(.{ .depth = r.depth, .prefix = r.prefix }, r.cmt_page_id);
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
            .compaction_queued = std.AutoHashMap(NodeCoord, void).init(allocator),
            .d1_dirty_flush = 0,
            .d2_dirty_flush = [_]u64{0} ** 64,
            .d3_dirty_flush = d3_dirty_flush,
            .d1_node_ids = d1_node_ids,
            .d2_node_ids = d2_node_ids,
            .d3_node_ids = d3_node_ids,
            .d2_last_write = d2_last_write,
            .d3_last_write = d3_last_write,
            .cmt_d0 = CommitmentPage.EMPTY,
            .cmt_d1 = cmt_d1,
            .cmt_d1_exists = cmt_d1_exists,
            .cmt_d2 = cmt_d2,
            .cmt_d2_exists = cmt_d2_exists,
            .cmt_deep = std.AutoHashMap(NodeCoord, *CommitmentPage).init(allocator),
            .cmt_deep_ids = cmt_deep_ids,
            .cmt_deep_flush = std.AutoHashMap(NodeCoord, void).init(allocator),
            .cmt_d1_flush = 0,
            .cmt_d2_flush = cmt_d2_flush,
            .cmt_d1_ids = cmt_d1_ids,
            .cmt_d2_ids = cmt_d2_ids,
            .cmt_d2_last = cmt_d2_last,
            .next_cmt_id = manifest.header.next_cmt_id,
            .block_keys = .empty,
            .max_depth_used = max_depth_used,
            .kv_map = kv_map_mod.KvMap.init(allocator),
            .allocator = allocator,
            // store and wal remain null during replay so write/commitBlock skip WAL
        };

        // Restore reusable page ids before replay so re-executed blocks draw
        // from the reclaimed pool instead of growing the container files.
        try db.heap.node_free.restore(allocator, manifest.free_node);
        try db.heap.sst_free.restore(allocator, manifest.free_sst);
        try db.cmt_free.restore(allocator, manifest.free_cmt);

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

    /// Nodes flushed per commitBlock call to amortise the FLUSH_INTERVAL spike.
    /// At most 64 + 4096 + 262144 = 266304 arena nodes can be dirty over 64 blocks;
    /// 4224 per block gives 2× headroom (4224 × 64 = 270336).
    const NODE_FLUSH_BUDGET: u32 = 4_224;
    /// Minimum age (blocks since last modification) before the amortised
    /// write-back persists a dirty node.  Hot pages keep their dirty bit and
    /// stay in memory until they cool down or the FLUSH_INTERVAL checkpoint.
    const NODE_FLUSH_MIN_AGE: u32 = 8;

    /// Write at most `budget` dirty arena nodes that have not been modified in
    /// the last `min_age` blocks, d1 first, then d2, then d3.  Updates
    /// *_node_ids and clears the flushed *_dirty_flush bits; younger nodes keep
    /// their bits for a later pass.  A no-op when no disk store is attached.
    fn flushDirtyNodes(self: *PrefixDB, budget: u32, min_age: u32) !void {
        const ns = if (self.heap.node_store) |*s| s else return;
        var rem = budget;

        // d1 (up to 64 nodes)
        {
            var w = self.d1_dirty_flush;
            while (w != 0 and rem > 0) : (w &= w - 1) {
                const bit: u32 = @ctz(w);
                if (self.current_block_num -% self.d1_last_write[bit] < min_age) continue;
                const new_id = self.heap.allocNodeId();
                try ns.write(new_id, &self.arena.d1_pages[bit]);
                if (comptime options.enable_metrics) self.heap.heap_stats.disk_node_writes += 1;
                if (self.d1_node_ids[bit]) |old| try self.heap.node_free.release(self.allocator, old);
                self.d1_node_ids[bit] = new_id;
                self.d1_dirty_flush &= ~(@as(u64, 1) << @as(u6, @intCast(bit)));
                rem -= 1;
            }
        }

        // d2 (up to 4096 nodes)
        for (&self.d2_dirty_flush, 0..) |*word, wi| {
            if (rem == 0) return;
            var w = word.*;
            while (w != 0 and rem > 0) : (w &= w - 1) {
                const bit: u32 = @ctz(w);
                const prefix: u32 = @intCast(wi * 64 + bit);
                if (self.current_block_num -% self.d2_last_write[prefix] < min_age) continue;
                const new_id = self.heap.allocNodeId();
                try ns.write(new_id, &self.arena.d2_pages[prefix]);
                if (comptime options.enable_metrics) self.heap.heap_stats.disk_node_writes += 1;
                if (self.d2_node_ids[prefix]) |old| try self.heap.node_free.release(self.allocator, old);
                self.d2_node_ids[prefix] = new_id;
                word.* &= ~(@as(u64, 1) << @as(u6, @intCast(bit)));
                rem -= 1;
            }
        }

        // d3 (up to 262144 nodes)
        for (self.d3_dirty_flush, 0..) |*word, wi| {
            if (rem == 0) return;
            var w = word.*;
            while (w != 0 and rem > 0) : (w &= w - 1) {
                const bit: u32 = @ctz(w);
                const prefix: u32 = @intCast(wi * 64 + bit);
                if (self.current_block_num -% self.d3_last_write[prefix] < min_age) continue;
                const new_id = self.heap.allocNodeId();
                try ns.write(new_id, &self.arena.d3_pages[prefix]);
                if (comptime options.enable_metrics) self.heap.heap_stats.disk_node_writes += 1;
                if (self.d3_node_ids[prefix]) |old| try self.heap.node_free.release(self.allocator, old);
                self.d3_node_ids[prefix] = new_id;
                word.* &= ~(@as(u64, 1) << @as(u6, @intCast(bit)));
                rem -= 1;
            }
        }
    }

    /// Write at most `budget` dirty commitment pages older than `min_age`
    /// blocks to disk, always copy-on-write under fresh page ids (the manifest
    /// checkpoint repoints routing).  Deep pages (depth ≥ 3) are drained only
    /// on a full flush (min_age == 0).  A no-op without a disk store.
    fn flushDirtyCmt(self: *PrefixDB, budget: u32, min_age: u32) !void {
        const cs = if (self.heap.cmt_store) |*s| s else return;
        var rem = budget;

        {
            var w = self.cmt_d1_flush;
            while (w != 0 and rem > 0) : (w &= w - 1) {
                const i: u32 = @ctz(w);
                if (self.current_block_num -% self.cmt_d1_last[i] < min_age) continue;
                const id = self.allocCmtId();
                try cs.write(id, &self.cmt_d1[i]);
                if (self.cmt_d1_ids[i]) |old| try self.cmt_free.release(self.allocator, old);
                self.cmt_d1_ids[i] = id;
                self.cmt_d1_flush &= ~(@as(u64, 1) << @as(u6, @intCast(i)));
                rem -= 1;
            }
        }

        for (self.cmt_d2_flush, 0..) |*word, wi| {
            if (rem == 0) return;
            var w = word.*;
            while (w != 0 and rem > 0) : (w &= w - 1) {
                const bit: u32 = @ctz(w);
                const prefix: u32 = @intCast(wi * 64 + bit);
                if (self.current_block_num -% self.cmt_d2_last[prefix] < min_age) continue;
                const id = self.allocCmtId();
                try cs.write(id, &self.cmt_d2[prefix]);
                if (self.cmt_d2_ids[prefix]) |old| try self.cmt_free.release(self.allocator, old);
                self.cmt_d2_ids[prefix] = id;
                word.* &= ~(@as(u64, 1) << @as(u6, @intCast(bit)));
                rem -= 1;
            }
        }

        if (min_age == 0) {
            var coords = std.ArrayList(NodeCoord).empty;
            defer coords.deinit(self.allocator);
            var it = self.cmt_deep_flush.iterator();
            while (it.next()) |e| try coords.append(self.allocator, e.key_ptr.*);
            for (coords.items) |coord| {
                const page = self.cmt_deep.get(coord) orelse {
                    _ = self.cmt_deep_flush.remove(coord);
                    continue;
                };
                const id = self.allocCmtId();
                try cs.write(id, page);
                if (self.cmt_deep_ids.get(coord)) |old| try self.cmt_free.release(self.allocator, old);
                try self.cmt_deep_ids.put(coord, id);
                _ = self.cmt_deep_flush.remove(coord);
            }
        }
    }

    /// Persist the current state to `store`.
    /// Writes all live arena nodes to node_store, then writes manifest.bin.
    /// Must be called before process exit to preserve the database.
    pub fn flush(self: *PrefixDB, store: page_store.DiskStore) !void {
        // Drain ALL remaining dirty arena nodes and commitment pages regardless
        // of age — the manifest written below must reference fully-persisted
        // pages.
        try self.flushDirtyNodes(std.math.maxInt(u32), 0);
        try self.flushDirtyCmt(std.math.maxInt(u32), 0);

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

        // The manifest written below references none of the freed page ids —
        // neither the long-dead (`free`) nor the freed-this-epoch (`pending`)
        // ones — so it lists both as reusable.  `promote()` runs only after
        // the manifest is durably renamed into place.
        var free_node = std.ArrayList(u32).empty;
        defer free_node.deinit(self.allocator);
        try self.heap.node_free.appendAllTo(self.allocator, &free_node);
        var free_sst = std.ArrayList(u32).empty;
        defer free_sst.deinit(self.allocator);
        try self.heap.sst_free.appendAllTo(self.allocator, &free_sst);
        var free_cmt = std.ArrayList(u32).empty;
        defer free_cmt.deinit(self.allocator);
        try self.cmt_free.appendAllTo(self.allocator, &free_cmt);

        const header = page_store.ManifestHeader{
            .magic         = page_store.MANIFEST_MAGIC,
            .version       = page_store.MANIFEST_VERSION,
            .next_node_id  = self.heap.next_node_id,
            .next_sst_id   = self.heap.next_sst_id,
            .next_cmt_id   = self.next_cmt_id,
            .routing_count = route_count,
            .l0_count      = l0_count,
            .free_node_count = @intCast(free_node.items.len),
            .free_sst_count  = @intCast(free_sst.items.len),
            .free_cmt_count  = @intCast(free_cmt.items.len),
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
                    routes.appendAssumeCapacity(.{
                        .depth = 1,
                        .prefix = prefix,
                        .node_id = id,
                        .cmt_page_id = self.cmt_d1_ids[prefix] orelse CMT_NONE,
                    });
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
                    routes.appendAssumeCapacity(.{
                        .depth = 2,
                        .prefix = prefix,
                        .node_id = id,
                        .cmt_page_id = self.cmt_d2_ids[prefix] orelse CMT_NONE,
                    });
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
                    routes.appendAssumeCapacity(.{
                        .depth = 3,
                        .prefix = prefix,
                        .node_id = id,
                        .cmt_page_id = self.cmt_deep_ids.get(.{ .depth = 3, .prefix = prefix }) orelse CMT_NONE,
                    });
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
                    .cmt_page_id = self.cmt_deep_ids.get(kv.key_ptr.*) orelse CMT_NONE,
                });
            }
        }

        try page_store.writeManifest(
            store,
            header,
            routes.items,
            self.l0.entries.items,
            free_node.items,
            free_sst.items,
            free_cmt.items,
        );

        // The new manifest is durable: this-epoch frees are now safe to reuse.
        try self.heap.node_free.promote(self.allocator);
        try self.heap.sst_free.promote(self.allocator);
        try self.cmt_free.promote(self.allocator);

        // Everything logged so far is captured by the manifest — truncate the
        // WAL instead of letting it grow for the lifetime of the database.
        if (self.wal) |*w| try w.reset();
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
        self.compaction_queued.deinit();
        self.kv_map.deinit();
        self.allocator.free(self.d2_node_ids);
        self.allocator.free(self.d3_node_ids);
        self.allocator.free(self.d3_dirty_flush);
        self.allocator.free(self.d2_last_write);
        self.allocator.free(self.d3_last_write);
        self.allocator.free(self.cmt_d1);
        self.allocator.free(self.cmt_d2);
        self.allocator.free(self.cmt_d2_exists);
        self.allocator.free(self.cmt_d2_flush);
        self.allocator.free(self.cmt_d2_ids);
        self.allocator.free(self.cmt_d2_last);
        var dit = self.cmt_deep.valueIterator();
        while (dit.next()) |p| self.allocator.destroy(p.*);
        self.cmt_deep.deinit();
        self.cmt_deep_ids.deinit();
        self.cmt_deep_flush.deinit();
        self.cmt_free.deinit(self.allocator);
        self.block_keys.deinit(self.allocator);
    }

    /// Next commitment-page id: reuse a reclaimed slot when one is available.
    fn allocCmtId(self: *PrefixDB) CommitmentPageId {
        if (self.cmt_free.acquire()) |id| {
            if (comptime options.enable_metrics) self.stats.cmt_pages_reused += 1;
            return id;
        }
        const id = self.next_cmt_id;
        self.next_cmt_id += 1;
        return id;
    }

    // ─── Node access helpers (dispatch arena for d1/d2, heap for d3-d5) ───────

    fn nodeExists(self: *const PrefixDB, depth: u32, prefix: PrefixData) bool {
        if (depth <= 3) return self.arena.exists(depth, prefix);
        return self.routing.get(depth, prefix) != null;
    }

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
                1 => {
                    self.d1_dirty_flush |= @as(u64, 1) << @as(u6, @intCast(prefix));
                    self.d1_last_write[@intCast(prefix)] = self.current_block_num;
                },
                2 => {
                    self.d2_dirty_flush[@intCast(prefix >> 6)] |= @as(u64, 1) << @as(u6, @intCast(prefix & 63));
                    self.d2_last_write[@intCast(prefix)] = self.current_block_num;
                },
                3 => {
                    self.d3_dirty_flush[@intCast(prefix >> 6)] |= @as(u64, 1) << @as(u6, @intCast(prefix & 63));
                    self.d3_last_write[@intCast(prefix)] = self.current_block_num;
                },
                else => unreachable,
            }
            if (depth > self.max_depth_used) self.max_depth_used = depth;
            return;
        }
        if (depth > self.max_depth_used) self.max_depth_used = depth;
        const old_id = self.routing.get(depth, prefix);
        const new_id = try self.heap.writeNodePage(depth, node);
        try self.routing.put(depth, prefix, new_id);
        if (old_id) |id| try self.heap.freeNodePage(id);
    }

    fn nodeRemove(self: *PrefixDB, depth: u32, prefix: PrefixData) !void {
        // The node's commitment page goes with it; the parent's leaf retains
        // the (canonical, placement-independent) subtree value.
        try self.cmtRemove(depth, prefix);
        if (depth <= 3) {
            self.arena.remove(depth, prefix);
            // Release the persisted page and drop the dirty bit so a later
            // write-back pass cannot resurrect the dead slot.
            switch (depth) {
                1 => {
                    if (self.d1_node_ids[@intCast(prefix)]) |old| try self.heap.node_free.release(self.allocator, old);
                    self.d1_node_ids[@intCast(prefix)] = null;
                    self.d1_dirty_flush &= ~(@as(u64, 1) << @as(u6, @intCast(prefix)));
                },
                2 => {
                    if (self.d2_node_ids[@intCast(prefix)]) |old| try self.heap.node_free.release(self.allocator, old);
                    self.d2_node_ids[@intCast(prefix)] = null;
                    self.d2_dirty_flush[@intCast(prefix >> 6)] &= ~(@as(u64, 1) << @as(u6, @intCast(prefix & 63)));
                },
                3 => {
                    if (self.d3_node_ids[@intCast(prefix)]) |old| try self.heap.node_free.release(self.allocator, old);
                    self.d3_node_ids[@intCast(prefix)] = null;
                    self.d3_dirty_flush[@intCast(prefix >> 6)] &= ~(@as(u64, 1) << @as(u6, @intCast(prefix & 63)));
                },
                else => unreachable,
            }
            return;
        }
        const id = self.routing.get(depth, prefix) orelse return;
        _ = self.routing.remove(depth, prefix);
        try self.heap.freeNodePage(id);
    }

    // ─── Write (§5.2) ─────────────────────────────────────────────────────────

    /// Append (K, V) to L0; flush to L1 when the prefix group reaches PAGE_ENTRIES.
    pub fn write(self: *PrefixDB, key: Key, value: Value) !void {
        if (comptime options.enable_metrics) self.stats.write_ops += 1;
        if (self.wal) |*w| try w.append(wal_mod.WalEntry.kvWrite(self.current_block_num, key, value));
        try self.block_keys.append(self.allocator, key);
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
            var opp_count: u32 = 0;

            // Append zone (most recent): scan from newest page to oldest.
            var append_result: ?Value = null;
            var j: usize = node.append_count;
            while (j > 0 and append_result == null) {
                j -= 1;
                if (comptime options.enable_metrics) self.stats.append_filter_probes += 1;
                if (filterContains(&node.append_prefix32[j], node.append_page_counts[j], q)) {
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
                // min4 is only a 32-bit prefix, so consecutive pages may share
                // it; the key can live in any page of the equal-min4 run (plus
                // the one page below it).  Scan downward; the common case —
                // distinct min4 values — still loads exactly one page.
                var pg = lo;
                while (pg > 0 and sorted_result == null) {
                    pg -= 1;
                    if (try self.heap.getSstPage(node.sorted_slot_ids[pg])) |sst_raw| {
                        if (comptime options.enable_metrics) self.stats.read_sst_loads += 1;
                        var sst = sst_raw;
                        sst.count = node.sorted_page_counts[pg];
                        sorted_result = binarySearchSst(&sst, &key);
                        if (sorted_result) |val| self.kv_map.putFromSst(key, val, node.sorted_slot_ids[pg]);
                    }
                    if (node.sorted_min4[pg] < q) break; // pages below cannot hold q
                }
            }

            // Opportunistic compaction: queue node if we loaded ≥ T_OPP append pages.
            if (opp_count >= T_OPP) {
                self.enqueueCompaction(.{ .depth = d, .prefix = p });
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

        var filter = [_]u32{std.math.maxInt(u32)} ** PAGE_ENTRIES;
        for (chunk, 0..) |e, idx| filter[idx] = prefix32(&e.key, depth);

        try self.appendSstToNode(depth, prefix, sst_id, @intCast(chunk.len), filter);
    }

    /// Attach an SST page to a node's append zone.
    fn appendSstToNode(
        self: *PrefixDB,
        depth: u32,
        prefix: PrefixData,
        sst_id: PayloadSlotId,
        count: u8,
        filter: [PAGE_ENTRIES]u32,
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
        node.append_prefix32[ac] = filter;
        node.append_count += 1;

        try self.nodePut(depth, prefix, node);

        // Jittered trigger: nodes enqueue up to 3 pages before A_MAX so that
        // uniformly-filling subtrees do not all come due in the same block.
        if (node.append_count + compactionJitter(depth, prefix) >= A_MAX) {
            self.enqueueCompaction(.{ .depth = depth, .prefix = prefix });
        }
    }

    /// Deterministic per-node offset in [0, 3] applied to the append-zone
    /// compaction trigger, de-synchronizing nodes that fill at the same rate.
    fn compactionJitter(depth: u32, prefix: PrefixData) u32 {
        var h = std.hash.Wyhash.init(depth);
        h.update(std.mem.asBytes(&prefix));
        return @intCast(h.final() & 3);
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

    // ─── Commitment tree internals (docs/commitment_redesign.md §4) ──────────

    /// Return the commitment page for (depth, prefix), creating an empty
    /// (all-leaves-invalid) page — or lazily loading the persisted one for
    /// deep coordinates — if absent.  depth 0 is the memory-only root page.
    fn cmtGetOrCreate(self: *PrefixDB, depth: u32, prefix: PrefixData) anyerror!*CommitmentPage {
        if (depth == 0) return &self.cmt_d0;
        if (depth == 1) {
            const i: usize = @intCast(prefix);
            const bit = @as(u64, 1) << @as(u6, @intCast(prefix));
            if (self.cmt_d1_exists & bit == 0) {
                self.cmt_d1[i] = CommitmentPage.EMPTY;
                self.cmt_d1_exists |= bit;
            }
            return &self.cmt_d1[i];
        }
        if (depth == 2) {
            const i: usize = @intCast(prefix);
            const w: usize = @intCast(prefix >> 6);
            const bit = @as(u64, 1) << @as(u6, @intCast(prefix & 63));
            if (self.cmt_d2_exists[w] & bit == 0) {
                self.cmt_d2[i] = CommitmentPage.EMPTY;
                self.cmt_d2_exists[w] |= bit;
            }
            return &self.cmt_d2[i];
        }
        const coord = NodeCoord{ .depth = depth, .prefix = prefix };
        if (self.cmt_deep.get(coord)) |p| return p;
        const page = try self.allocator.create(CommitmentPage);
        errdefer self.allocator.destroy(page);
        if (self.cmt_deep_ids.get(coord)) |id| {
            if (self.heap.cmt_store) |*cs| {
                page.* = try cs.read(id);
                try self.cmt_deep.put(coord, page);
                return page;
            }
        }
        page.* = CommitmentPage.EMPTY;
        try self.cmt_deep.put(coord, page);
        return page;
    }

    /// Drop the commitment page at (depth, prefix), e.g. when its node is
    /// absorbed by a downwardMerge.  The parent's leaf keeps the canonical
    /// subtree value, which is placement-independent.
    fn cmtRemove(self: *PrefixDB, depth: u32, prefix: PrefixData) !void {
        switch (depth) {
            0 => {},
            1 => {
                const bit = @as(u64, 1) << @as(u6, @intCast(prefix));
                self.cmt_d1_exists &= ~bit;
                self.cmt_d1_flush &= ~bit;
                if (self.cmt_d1_ids[@intCast(prefix)]) |old| try self.cmt_free.release(self.allocator, old);
                self.cmt_d1_ids[@intCast(prefix)] = null;
            },
            2 => {
                const bit = @as(u64, 1) << @as(u6, @intCast(prefix & 63));
                self.cmt_d2_exists[@intCast(prefix >> 6)] &= ~bit;
                self.cmt_d2_flush[@intCast(prefix >> 6)] &= ~bit;
                if (self.cmt_d2_ids[@intCast(prefix)]) |old| try self.cmt_free.release(self.allocator, old);
                self.cmt_d2_ids[@intCast(prefix)] = null;
            },
            else => {
                const coord = NodeCoord{ .depth = depth, .prefix = prefix };
                if (self.cmt_deep.fetchRemove(coord)) |kv| self.allocator.destroy(kv.value);
                if (self.cmt_deep_ids.fetchRemove(coord)) |kv| try self.cmt_free.release(self.allocator, kv.value);
                _ = self.cmt_deep_flush.remove(coord);
            },
        }
    }

    /// Mark a commitment page as needing a (CoW) flush, recording its age.
    fn cmtMarkFlush(self: *PrefixDB, depth: u32, prefix: PrefixData) void {
        switch (depth) {
            0 => {}, // memory-only
            1 => {
                self.cmt_d1_flush |= @as(u64, 1) << @as(u6, @intCast(prefix));
                self.cmt_d1_last[@intCast(prefix)] = self.current_block_num;
            },
            2 => {
                self.cmt_d2_flush[@intCast(prefix >> 6)] |= @as(u64, 1) << @as(u6, @intCast(prefix & 63));
                self.cmt_d2_last[@intCast(prefix)] = self.current_block_num;
            },
            else => self.cmt_deep_flush.put(.{ .depth = depth, .prefix = prefix }, {}) catch {},
        }
    }

    /// Recompute the 63 internal heap values from the 64 leaves using the
    /// canonical pass-through `combine` rule.  h[1] becomes the page root.
    fn rebuildInternals(page: *CommitmentPage) void {
        var i: usize = 63;
        while (i >= 1) : (i -= 1) {
            page.h[i] = merkle.combine(&page.h[2 * i], &page.h[2 * i + 1]);
        }
    }

    /// Fill all invalid leaves of `page` (child page roots where a child node
    /// exists, bottom-slot gathers otherwise) and rebuild the internals.
    /// Recursive: a child page may itself need materialising first.
    fn cmtMaterialize(self: *PrefixDB, depth: u32, prefix: PrefixData, page: *CommitmentPage) anyerror!void {
        if (page.leaf_valid == ~@as(u64, 0)) return;
        var missing = ~page.leaf_valid;
        while (missing != 0) : (missing &= missing - 1) {
            const c: u32 = @ctz(missing);
            const child_prefix = (prefix << STRIDE) | c;
            const child_depth = depth + 1;
            if (self.nodeExists(child_depth, child_prefix)) {
                const child = try self.cmtGetOrCreate(child_depth, child_prefix);
                try self.cmtMaterialize(child_depth, child_prefix, child);
                page.h[64 + c] = child.h[1];
            } else {
                page.h[64 + c] = try self.gatherSlotValue(child_depth, child_prefix);
            }
            page.leaf_valid |= @as(u64, 1) << @as(u6, @intCast(c));
        }
        rebuildInternals(page);
    }

    /// Deepest depth (in strides) at which a node exists on `key`'s path;
    /// 0 when not even the depth-1 node exists.
    fn deepestNodeOnPath(self: *const PrefixDB, key: *const Key) u32 {
        var best: u32 = 0;
        var d: u32 = 1;
        while (d <= self.max_depth_used) : (d += 1) {
            if (self.nodeExists(d, prefixData(key, d))) best = d;
        }
        return best;
    }

    /// Canonical value of the bottom slot at (level, p): the §2 trie value over
    /// every live key with that 6·level-bit prefix.
    ///
    /// Precondition: no node exists at (level, p).  Path-connectivity (enforced
    /// by the downwardMerge child guard) then guarantees no node exists below
    /// it either, so all matching keys live in ancestor buffers at depths
    /// 1..level-1.  L0 is empty here: commitBlock flushes it before gathering.
    fn gatherSlotValue(self: *PrefixDB, level: u32, p: PrefixData) anyerror!Hash {
        const alloc = self.allocator;
        var found = std.AutoHashMap(Key, Value).init(alloc);
        defer found.deinit();

        // Shallow depths first: read() precedence is shallowest-depth wins,
        // and within a node append (newest first) beats sorted.
        var d: u32 = 1;
        while (d < level) : (d += 1) {
            const np = p >> @intCast(STRIDE * (level - d));
            const node = (try self.nodeGet(d, np)) orelse continue;
            const rel_bits: u32 = STRIDE * (level - d); // bits of p below this node's prefix
            const rel: u64 = p & ((@as(u64, 1) << @intCast(rel_bits)) - 1);

            // Append zone, newest → oldest; prefix32 filters narrow the scan.
            const fbits: u32 = @min(rel_bits, 32);
            const fwant: u32 = @intCast(if (rel_bits <= 32) rel else rel >> @intCast(rel_bits - 32));
            var j: usize = node.append_count;
            while (j > 0) {
                j -= 1;
                var any = false;
                for (node.append_prefix32[j][0..node.append_page_counts[j]]) |fv| {
                    if ((fv >> @intCast(32 - fbits)) == fwant) {
                        any = true;
                        break;
                    }
                }
                if (!any) continue;
                if (try self.heap.getSstPage(node.append_slot_ids[j])) |sst| {
                    for (sst.entries[0..node.append_page_counts[j]]) |e| {
                        if (prefixData(&e.key, level) != p) continue;
                        const gop = try found.getOrPut(e.key);
                        if (!gop.found_existing) gop.value_ptr.* = e.value;
                    }
                }
            }

            // Sorted zone: keys under the slot span a contiguous page range.
            if (node.sorted_count > 0) {
                const lo: u64 = if (rel_bits <= 32) rel << @intCast(32 - rel_bits) else rel >> @intCast(rel_bits - 32);
                const hi: u64 = if (rel_bits <= 32) (rel + 1) << @intCast(32 - rel_bits) else lo + 1;
                var plo: usize = 0;
                var phi: usize = node.sorted_count;
                while (plo < phi) {
                    const mid = plo + (phi - plo) / 2;
                    if (node.sorted_min4[mid] <= lo) plo = mid + 1 else phi = mid;
                }
                var pg: usize = if (plo > 0) plo - 1 else 0;
                while (pg < node.sorted_count) : (pg += 1) {
                    if (@as(u64, node.sorted_min4[pg]) >= hi) break;
                    if (try self.heap.getSstPage(node.sorted_slot_ids[pg])) |sst| {
                        for (sst.entries[0..node.sorted_page_counts[pg]]) |e| {
                            if (prefixData(&e.key, level) != p) continue;
                            const gop = try found.getOrPut(e.key);
                            if (!gop.found_existing) gop.value_ptr.* = e.value;
                        }
                    }
                }
            }
        }

        // Tombstones shadow older values during precedence resolution above;
        // only now do deleted keys drop out of the trie.
        var list = std.ArrayList(KvEntry).empty;
        defer list.deinit(alloc);
        var it = found.iterator();
        while (it.next()) |kv| {
            if (std.mem.eql(u8, kv.value_ptr, &TOMBSTONE)) continue;
            try list.append(alloc, .{ .key = kv.key_ptr.*, .value = kv.value_ptr.* });
        }
        std.mem.sort(KvEntry, list.items, {}, kvLessThan);
        return subtreeValue(list.items, STRIDE * level);
    }

    /// Recompute the Merkle state root after a block of writes.
    ///
    /// Dirtiness is derived from the block's write stream (block_keys): each
    /// written key dirties one bottom slot; changed pages propagate their h[1]
    /// into the parent's leaf up to the depth-0 page, whose h[1] is the root.
    /// Commitment values never depend on which buffer holds an entry, so
    /// compaction and splits cannot change the root.
    ///
    /// Call once per block after all writes are done.  Flushes L0 internally so
    /// callers do not need a separate flushL0All call.
    pub fn commitBlock(self: *PrefixDB) !Hash {
        if (comptime options.enable_metrics) self.stats.commit_block_calls += 1;
        const t0 = if (comptime options.enable_metrics) monoNs() else {};

        try self.flushL0All();

        // Dirty slot masks per page, derived from the block's written keys.
        var dirty = std.AutoHashMap(NodeCoord, u64).init(self.allocator);
        defer dirty.deinit();
        var max_depth: u32 = 0;
        for (self.block_keys.items) |key| {
            const bottom = self.deepestNodeOnPath(&key);
            const coord = NodeCoord{
                .depth = bottom,
                .prefix = if (bottom == 0) 0 else prefixData(&key, bottom),
            };
            const slot: u6 = @intCast(prefixData(&key, bottom + 1) & (CHILD_COUNT - 1));
            const gop = try dirty.getOrPut(coord);
            if (!gop.found_existing) gop.value_ptr.* = 0;
            gop.value_ptr.* |= @as(u64, 1) << slot;
            if (bottom > max_depth) max_depth = bottom;
        }
        self.block_keys.clearRetainingCapacity();

        // Process deepest-first; each page pushes its new h[1] into its parent.
        var depth: u32 = max_depth;
        while (true) {
            var at_depth = std.ArrayList(NodeCoord).empty;
            defer at_depth.deinit(self.allocator);
            {
                var dit = dirty.iterator();
                while (dit.next()) |e| {
                    if (e.key_ptr.depth == depth) try at_depth.append(self.allocator, e.key_ptr.*);
                }
            }

            for (at_depth.items) |coord| {
                const mask = (dirty.fetchRemove(coord) orelse continue).value;
                if (comptime options.enable_metrics) self.stats.commit_nodes_processed += 1;

                const page = try self.cmtGetOrCreate(coord.depth, coord.prefix);

                // Refresh lazily-invalid leaves plus the dirty bottom slots.
                var need = ~page.leaf_valid | mask;
                while (need != 0) : (need &= need - 1) {
                    const c: u32 = @ctz(need);
                    const cbit = @as(u64, 1) << @as(u6, @intCast(c));
                    const child_prefix = (coord.prefix << STRIDE) | c;
                    const child_depth = coord.depth + 1;
                    if (self.nodeExists(child_depth, child_prefix)) {
                        if (page.leaf_valid & cbit == 0) {
                            const child = try self.cmtGetOrCreate(child_depth, child_prefix);
                            try self.cmtMaterialize(child_depth, child_prefix, child);
                            page.h[64 + c] = child.h[1];
                        }
                        // else: a deeper dirty page already pushed the fresh value.
                    } else {
                        page.h[64 + c] = try self.gatherSlotValue(child_depth, child_prefix);
                    }
                    page.leaf_valid |= cbit;
                }
                rebuildInternals(page);
                self.cmtMarkFlush(coord.depth, coord.prefix);

                if (coord.depth > 0) {
                    const slot: usize = @intCast(coord.prefix & (CHILD_COUNT - 1));
                    const parent_coord = NodeCoord{ .depth = coord.depth - 1, .prefix = coord.prefix >> STRIDE };
                    const parent = try self.cmtGetOrCreate(parent_coord.depth, parent_coord.prefix);
                    parent.h[64 + slot] = page.h[1];
                    parent.leaf_valid |= @as(u64, 1) << @as(u6, @intCast(slot));
                    const gop = try dirty.getOrPut(parent_coord);
                    if (!gop.found_existing) gop.value_ptr.* = 0;
                    gop.value_ptr.* |= @as(u64, 1) << @as(u6, @intCast(slot));
                }
            }

            if (depth == 0) break;
            depth -= 1;
        }

        // First commit after open (or a write-free block): make sure the root
        // page is fully materialised before reading the root.
        try self.cmtMaterialize(0, 0, &self.cmt_d0);
        const root = self.cmt_d0.h[1];
        if (comptime options.enable_metrics) {
            self.stats.commit_block_ns += monoNs() - t0;
        }
        if (self.wal) |*w| try w.append(wal_mod.WalEntry.blockCommit(self.current_block_num, root));
        self.current_block_num += 1;
        // Amortised write-back of OLD data only: dirty pages untouched for
        // NODE_FLUSH_MIN_AGE blocks are persisted; hot pages stay in memory
        // until they cool down or the FLUSH_INTERVAL checkpoint drains them.
        try self.flushDirtyNodes(NODE_FLUSH_BUDGET, NODE_FLUSH_MIN_AGE);
        try self.flushDirtyCmt(NODE_FLUSH_BUDGET, NODE_FLUSH_MIN_AGE);
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

    /// Default number of compaction procedures executed per runCompactionBudget
    /// call.  Sized so steady-state pressure (~9 ops/block in benchmarks) flows
    /// through unthrottled while synchronized fill waves spread across blocks
    /// via the queue instead of stalling a single block.
    pub const COMPACTION_BUDGET_DEFAULT: u32 = 16;

    /// Enqueue a node for compaction unless it is already queued.
    /// Best-effort: allocation failure drops the request (the inline overflow
    /// handling in appendSstToNode keeps the node correct regardless).
    fn enqueueCompaction(self: *PrefixDB, coord: NodeCoord) void {
        const gop = self.compaction_queued.getOrPut(coord) catch return;
        if (gop.found_existing) return;
        self.compaction_queue.append(self.allocator, coord) catch {
            _ = self.compaction_queued.remove(coord);
        };
    }

    /// Pop the oldest queued coord (FIFO), reclaiming the backing array when
    /// the consumed prefix grows large.
    fn dequeueCompaction(self: *PrefixDB) ?NodeCoord {
        if (self.compaction_head >= self.compaction_queue.items.len) {
            self.compaction_queue.clearRetainingCapacity();
            self.compaction_head = 0;
            return null;
        }
        const coord = self.compaction_queue.items[self.compaction_head];
        self.compaction_head += 1;
        _ = self.compaction_queued.remove(coord);
        if (self.compaction_head >= 4096 and self.compaction_head * 2 >= self.compaction_queue.items.len) {
            const remaining = self.compaction_queue.items.len - self.compaction_head;
            std.mem.copyForwards(
                NodeCoord,
                self.compaction_queue.items[0..remaining],
                self.compaction_queue.items[self.compaction_head..],
            );
            self.compaction_queue.shrinkRetainingCapacity(remaining);
            self.compaction_head = 0;
        }
        return coord;
    }

    /// Number of nodes currently awaiting compaction.
    pub fn compactionBacklog(self: *const PrefixDB) usize {
        return self.compaction_queue.items.len - self.compaction_head;
    }

    /// Drain the whole compaction queue (tests, shutdown, idle periods).
    pub fn runCompaction(self: *PrefixDB) !void {
        try self.runCompactionBudget(std.math.maxInt(u32));
    }

    /// Run at most `budget` compaction procedures, oldest-queued first; the
    /// remainder stays queued for later calls so one block never absorbs a
    /// whole fill wave.  Stale entries (nothing to do) do not consume budget.
    pub fn runCompactionBudget(self: *PrefixDB, budget: u32) !void {
        if (comptime options.enable_metrics) self.stats.compaction_calls += 1;
        var rem = budget;
        while (rem > 0) {
            const coord = self.dequeueCompaction() orelse break;
            const node = (try self.nodeGet(coord.depth, coord.prefix)) orelse continue;
            if (coord.depth > 1 and (try self.countNodeEntries(coord.depth, coord.prefix)) < MERGE_THRESHOLD) {
                if (comptime options.enable_metrics) self.stats.compaction_ops += 1;
                try self.downwardMerge(coord.depth, coord.prefix);
                rem -= 1;
            } else if (node.sorted_count >= S_MAX) {
                if (comptime options.enable_metrics) self.stats.compaction_ops += 1;
                try self.upwardSplit(coord.depth, coord.prefix);
                rem -= 1;
            } else if (node.append_count > 0) {
                if (comptime options.enable_metrics) self.stats.compaction_ops += 1;
                try self.appendToSortedMerge(coord.depth, coord.prefix);
                rem -= 1;
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

            if (chunk.len == PAGE_ENTRIES and depth < MAX_NODE_DEPTH) {
                const f0 = prefix32(&chunk[0].key, depth);
                const f63 = prefix32(&chunk[PAGE_ENTRIES - 1].key, depth);
                if (f0 >> 26 == f63 >> 26) {
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

        // Sorted zone capacity is a hard array bound; at MAX_NODE_DEPTH there
        // is no deeper level to promote into, so refuse rather than corrupt.
        if (new_ids.items.len > S_MAX) return error.NodeSaturated;

        var new_node = std.mem.zeroes(NodePage);
        new_node.sorted_count = @intCast(new_ids.items.len);
        new_node.append_count = 0;
        @memcpy(new_node.sorted_slot_ids[0..new_ids.items.len], new_ids.items);
        @memcpy(new_node.sorted_min4[0..new_min4.items.len], new_min4.items);
        @memcpy(new_node.sorted_page_counts[0..new_counts.items.len], new_counts.items);

        try self.nodePut(depth, prefix, new_node);
        for (old_node.sorted_slot_ids[0..old_node.sorted_count]) |id| try self.heap.freeSstPage(id);
        for (old_node.append_slot_ids[0..old_node.append_count]) |id| try self.heap.freeSstPage(id);

        if (new_node.sorted_count >= S_MAX)
            self.enqueueCompaction(.{ .depth = depth, .prefix = prefix });
        if (depth > 1 and (try self.countNodeEntries(depth, prefix)) < MERGE_THRESHOLD)
            self.enqueueCompaction(.{ .depth = depth, .prefix = prefix });
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

        // Build a sorted prefix32 filter over the chunk entries at child_depth.
        var filter = [_]u32{std.math.maxInt(u32)} ** PAGE_ENTRIES;
        for (chunk, 0..) |e, idx| filter[idx] = prefix32(&e.key, child_depth);

        try self.appendSstToNode(child_depth, child_prefix, sst_id, sst.count, filter);
    }

    /// §6.2: Merge all sorted pages; promote groups with ≥64 entries to L(k+1).
    fn upwardSplit(self: *PrefixDB, depth: u32, prefix: PrefixData) !void {
        if (depth >= MAX_NODE_DEPTH) return; // no deeper level exists (§MAX_NODE_DEPTH)
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
                        if (cn.sorted_count >= S_MAX)
                            self.enqueueCompaction(.{ .depth = child_depth, .prefix = cp });
                    } else {
                        // Child sorted zone full: keep entries in parent and free the
                        // just-written SST rather than leaking it.
                        try self.heap.freeSstPage(sid);
                        for (chunk) |e| try remaining.append(alloc, e);
                        self.enqueueCompaction(.{ .depth = child_depth, .prefix = cp });
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
        @memcpy(new_node.sorted_slot_ids[0..new_ids.items.len], new_ids.items);
        @memcpy(new_node.sorted_min4[0..new_min4.items.len], new_min4.items);
        @memcpy(new_node.sorted_page_counts[0..new_counts.items.len], new_counts.items);
        for (0..old_node.append_count) |ai| {
            new_node.append_slot_ids[ai] = old_node.append_slot_ids[ai];
            new_node.append_page_counts[ai] = old_node.append_page_counts[ai];
            new_node.append_prefix32[ai] = old_node.append_prefix32[ai];
        }

        try self.nodePut(depth, prefix, new_node);
        for (old_node.sorted_slot_ids[0..old_node.sorted_count]) |id| try self.heap.freeSstPage(id);
    }

    /// §6.3: Merge a sparse child node back into its parent's sorted zone.
    fn downwardMerge(self: *PrefixDB, depth: u32, prefix: PrefixData) !void {
        std.debug.assert(depth > 1);
        const alloc = self.allocator;
        const parent_depth = depth - 1;
        const parent_prefix: PrefixData = prefix >> STRIDE;

        // Never orphan grandchildren: removing this node while deeper nodes
        // exist under it would break path-connectivity, which the commitment
        // gather relies on (a missing node implies an empty subtree of nodes).
        {
            var c: PrefixData = 0;
            while (c < CHILD_COUNT) : (c += 1) {
                if (self.nodeExists(depth + 1, (prefix << STRIDE) | c)) return;
            }
        }

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
        @memcpy(new_parent.sorted_slot_ids[0..new_ids.items.len], new_ids.items);
        @memcpy(new_parent.sorted_min4[0..new_min4.items.len], new_min4.items);
        @memcpy(new_parent.sorted_page_counts[0..new_counts.items.len], new_counts.items);
        for (0..old_parent.append_count) |ai| {
            new_parent.append_slot_ids[ai] = old_parent.append_slot_ids[ai];
            new_parent.append_page_counts[ai] = old_parent.append_page_counts[ai];
            new_parent.append_prefix32[ai] = old_parent.append_prefix32[ai];
        }
        try self.nodePut(parent_depth, parent_prefix, new_parent);
        for (old_parent.sorted_slot_ids[0..old_parent.sorted_count]) |id| try self.heap.freeSstPage(id);

        try self.nodeRemove(depth, prefix);
        for (old_child.sorted_slot_ids[0..old_child.sorted_count]) |id| try self.heap.freeSstPage(id);
        for (old_child.append_slot_ids[0..old_child.append_count]) |id| try self.heap.freeSstPage(id);

        if (parent_depth > 1 and (try self.countNodeEntries(parent_depth, parent_prefix)) < MERGE_THRESHOLD)
            self.enqueueCompaction(.{ .depth = parent_depth, .prefix = parent_prefix });
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

/// Bit `bit` of a 256-bit key, MSB-first (bit 0 = top bit of key[0]).
pub fn keyBit(key: *const Key, bit: u32) u1 {
    return @intCast((key[bit >> 3] >> @intCast(7 - (bit & 7))) & 1);
}

/// Canonical trie value (docs/commitment_redesign.md §2) of the subtree at
/// bit-depth `bit` over `entries`, which must be sorted by key, unique, and
/// tombstone-free.  Pass-through collapse: a single entry IS the subtree value.
pub fn subtreeValue(entries: []const KvEntry, bit: u32) Hash {
    if (entries.len == 0) return ZERO_HASH;
    if (entries.len == 1) return merkle.leafHash(&entries[0].key, &entries[0].value);
    std.debug.assert(bit < 256); // >1 distinct keys must diverge within 256 bits
    // Sorted input: all bit=0 entries precede bit=1 entries; binary-search the split.
    var lo: usize = 0;
    var hi: usize = entries.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (keyBit(&entries[mid].key, bit) == 0) lo = mid + 1 else hi = mid;
    }
    const left = subtreeValue(entries[0..lo], bit + 1);
    const right = subtreeValue(entries[lo..], bit + 1);
    return merkle.combine(&left, &right);
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

fn filterContains(filter: *const [PAGE_ENTRIES]u32, count: u8, target: u32) bool {
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
    try heap.freeNodePage(id);
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

// ─── Commitment redesign tests (docs/commitment_redesign.md) ──────────────────

/// Hash-distributed key, optionally pinned under one depth-1 prefix so a
/// modest key count forces upwardSplit/promotion to depth 2+.
fn cmtTestKey(i: u64, pin_first_byte: ?u8) Key {
    var seed: [8]u8 = undefined;
    std.mem.writeInt(u64, &seed, i, .big);
    var k: Key = undefined;
    std.crypto.hash.Blake3.hash(&seed, &k, .{});
    if (pin_first_byte) |b| k[0] = b;
    return k;
}

fn cmtTestVal(i: u64) Value {
    var seed: [8]u8 = undefined;
    std.mem.writeInt(u64, &seed, i ^ 0xDEAD_BEEF, .big);
    var v: Value = undefined;
    std.crypto.hash.Blake3.hash(&seed, &v, .{});
    return v;
}

/// Reference implementation: §2 canonical trie value over a plain model map.
fn naiveRootFromModel(allocator: std.mem.Allocator, model: *const std.AutoHashMap(Key, Value)) !Hash {
    var list = std.ArrayList(KvEntry).empty;
    defer list.deinit(allocator);
    var it = model.iterator();
    while (it.next()) |kv| {
        if (std.mem.eql(u8, kv.value_ptr, &TOMBSTONE)) continue;
        try list.append(allocator, .{ .key = kv.key_ptr.*, .value = kv.value_ptr.* });
    }
    std.mem.sort(KvEntry, list.items, {}, kvLessThan);
    return subtreeValue(list.items, 0);
}

test "commitBlock: root equals naive canonical trie evaluation (with splits)" {
    const alloc = std.testing.allocator;
    var db = try PrefixDB.init(alloc);
    defer db.deinit();
    var model = std.AutoHashMap(Key, Value).init(alloc);
    defer model.deinit();

    // 8000 keys pinned under one depth-1 prefix overflow that node's sorted
    // zone (104 × 64 = 6656) and force splits/promotions to depth 2+.
    var i: u64 = 0;
    while (i < 8000) : (i += 1) {
        const k = cmtTestKey(i, 0x00);
        const v = cmtTestVal(i);
        try db.write(k, v);
        try model.put(k, v);
        if (i % 2000 == 1999) {
            const got = try db.commitBlock();
            try std.testing.expectEqual(try naiveRootFromModel(alloc, &model), got);
            try db.runCompaction();
        }
    }
    // Overwrites after compaction reshuffled placement.
    i = 0;
    while (i < 500) : (i += 1) {
        const k = cmtTestKey(i * 3, 0x00);
        const v = cmtTestVal(i + 1_000_000);
        try db.write(k, v);
        try model.put(k, v);
    }
    const got = try db.commitBlock();
    try std.testing.expectEqual(try naiveRootFromModel(alloc, &model), got);
}

test "commitBlock: root is independent of write order and compaction history" {
    const alloc = std.testing.allocator;
    const N: u64 = 8000;

    // History A: ascending order, one commit at the end.
    var db_a = try PrefixDB.init(alloc);
    defer db_a.deinit();
    var i: u64 = 0;
    while (i < N) : (i += 1) {
        try db_a.write(cmtTestKey(i, 0x00), cmtTestVal(i));
    }
    const root_a = try db_a.commitBlock();

    // History B: descending order, stale values corrected later, intermediate
    // commits and compaction runs.
    var db_b = try PrefixDB.init(alloc);
    defer db_b.deinit();
    i = N;
    while (i > 0) {
        i -= 1;
        if (i % 10 == 0) try db_b.write(cmtTestKey(i, 0x00), cmtTestVal(999_999));
        try db_b.write(cmtTestKey(i, 0x00), cmtTestVal(i));
        if (i % 1500 == 0) {
            _ = try db_b.commitBlock();
            try db_b.runCompaction();
        }
    }
    const root_b = try db_b.commitBlock();

    try std.testing.expectEqual(root_a, root_b);
}

test "commitBlock: deleted keys drop out of the root" {
    const alloc = std.testing.allocator;

    var db1 = try PrefixDB.init(alloc);
    defer db1.deinit();
    var i: u64 = 0;
    while (i < 100) : (i += 1) try db1.write(cmtTestKey(i, null), cmtTestVal(i));
    try db1.write(cmtTestKey(7777, null), cmtTestVal(7777));
    _ = try db1.commitBlock();
    try db1.write(cmtTestKey(7777, null), TOMBSTONE);
    const root_deleted = try db1.commitBlock();

    var db2 = try PrefixDB.init(alloc);
    defer db2.deinit();
    i = 0;
    while (i < 100) : (i += 1) try db2.write(cmtTestKey(i, null), cmtTestVal(i));
    const root_never = try db2.commitBlock();

    try std.testing.expectEqual(root_never, root_deleted);
}

test "commitBlock: empty block leaves the root unchanged" {
    const alloc = std.testing.allocator;
    var db = try PrefixDB.init(alloc);
    defer db.deinit();
    var i: u64 = 0;
    while (i < 200) : (i += 1) try db.write(cmtTestKey(i, null), cmtTestVal(i));
    const r1 = try db.commitBlock();
    const r2 = try db.commitBlock();
    try std.testing.expectEqual(r1, r2);
}

test "commitment pages survive flush + reopen (root stable across restart)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const store = page_store.DiskStore{ .dir = tmp.dir, .io = std.testing.io };

    var root_before: Hash = undefined;
    {
        var db = try PrefixDB.openWithConfig(std.testing.allocator, .{}, store);
        var i: u64 = 0;
        while (i < 3000) : (i += 1) try db.write(cmtTestKey(i, 0x00), cmtTestVal(i));
        root_before = try db.commitBlock();
        try db.flush(store);
        db.deinit();
    }
    {
        var db = try PrefixDB.openWithConfig(std.testing.allocator, .{}, store);
        defer db.deinit();
        // A write-free commit after reopen must reproduce the same root.
        const root_after = try db.commitBlock();
        try std.testing.expectEqual(root_before, root_after);
    }
}

test "WAL recovery reproduces the committed root" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const store = page_store.DiskStore{ .dir = tmp.dir, .io = std.testing.io };

    var root_before: Hash = undefined;
    {
        var db = try PrefixDB.openWithConfig(std.testing.allocator, .{}, store);
        var i: u64 = 0;
        while (i < 300) : (i += 1) try db.write(cmtTestKey(i, null), cmtTestVal(i));
        root_before = try db.commitBlock();
        // Crash: no flush.
        db.deinit();
    }
    {
        var db = try PrefixDB.openWithConfig(std.testing.allocator, .{}, store);
        defer db.deinit();
        const root_after = try db.commitBlock();
        try std.testing.expectEqual(root_before, root_after);
    }
}

// ─── GC / free-list tests ──────────────────────────────────────────────────────

test "FreeList: pending ids become reusable only after promote" {
    var fl = FreeList{};
    defer fl.deinit(std.testing.allocator);

    try fl.release(std.testing.allocator, 7);
    try fl.release(std.testing.allocator, 9);
    // Quarantined: nothing reusable before the checkpoint.
    try std.testing.expectEqual(@as(?u32, null), fl.acquire());
    try std.testing.expectEqual(@as(u32, 2), fl.totalLen());

    try fl.promote(std.testing.allocator);
    try std.testing.expectEqual(@as(?u32, 9), fl.acquire());
    try std.testing.expectEqual(@as(?u32, 7), fl.acquire());
    try std.testing.expectEqual(@as(?u32, null), fl.acquire());
}

test "GC: compaction releases SST page ids and a checkpoint makes them reusable" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const store = page_store.DiskStore{ .dir = tmp.dir, .io = std.testing.io };

    var db = try PrefixDB.openWithConfig(std.testing.allocator, .{}, store);
    defer db.deinit();

    // Enough same-prefix keys to fill the append zone and force merges that
    // rewrite (and therefore free) SST pages.
    var i: u64 = 0;
    while (i < 2000) : (i += 1) try db.write(cmtTestKey(i, 0x00), cmtTestVal(i));
    _ = try db.commitBlock();
    try db.runCompaction();

    try std.testing.expect(db.heap.sst_free.pending.items.len > 0);
    const quarantined = db.heap.sst_free.pending.items.len;

    try db.flush(store);
    // Checkpoint promotes the whole quarantine.
    try std.testing.expectEqual(@as(usize, 0), db.heap.sst_free.pending.items.len);
    try std.testing.expect(db.heap.sst_free.free.items.len >= quarantined);

    // New page writes must draw from the free list, not grow the id space.
    const next_before = db.heap.next_sst_id;
    const reusable = db.heap.sst_free.free.items.len;
    i = 2000;
    while (i < 2000 + 64) : (i += 1) try db.write(cmtTestKey(i, 0x00), cmtTestVal(i));
    _ = try db.commitBlock();
    const consumed = reusable - db.heap.sst_free.free.items.len;
    const grown = db.heap.next_sst_id - next_before;
    try std.testing.expect(consumed > 0);
    try std.testing.expectEqual(@as(u32, 0), grown);
}

test "GC: free lists survive flush + reopen and reuse keeps data readable" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const store = page_store.DiskStore{ .dir = tmp.dir, .io = std.testing.io };

    var root_before: Hash = undefined;
    var free_sst_before: usize = 0;
    {
        var db = try PrefixDB.openWithConfig(std.testing.allocator, .{}, store);
        errdefer db.deinit();
        var i: u64 = 0;
        // Pinned prefix: append zones overflow and merges free SST pages.
        while (i < 3000) : (i += 1) try db.write(cmtTestKey(i, 0x00), cmtTestVal(i));
        _ = try db.commitBlock();
        try db.runCompaction();
        root_before = try db.commitBlock();
        try db.flush(store);
        free_sst_before = db.heap.sst_free.free.items.len;
        try std.testing.expect(free_sst_before > 0);
        db.deinit();
    }
    {
        var db = try PrefixDB.openWithConfig(std.testing.allocator, .{}, store);
        defer db.deinit();
        try std.testing.expectEqual(free_sst_before, db.heap.sst_free.free.items.len);
        try std.testing.expectEqual(root_before, try db.commitBlock());

        // Churn through reused ids, then verify every original key still reads
        // back correctly (a reuse bug would corrupt unrelated live pages).
        var i: u64 = 3000;
        while (i < 6000) : (i += 1) try db.write(cmtTestKey(i, 0x00), cmtTestVal(i));
        _ = try db.commitBlock();
        try db.runCompaction();
        _ = try db.commitBlock();

        i = 0;
        while (i < 6000) : (i += 1) {
            const got = (try db.read(cmtTestKey(i, 0x00))) orelse return error.MissingKey;
            try std.testing.expectEqual(cmtTestVal(i), got);
        }
    }
}

test "compaction budget: backlog drains incrementally, not in one call" {
    var db = try PrefixDB.init(std.testing.allocator);
    defer db.deinit();

    // Four depth-1 nodes, each with pending append-zone work.
    const pins = [_]u8{ 0x00, 0x40, 0x80, 0xC0 };
    var i: u64 = 0;
    while (i < 4000) : (i += 1) try db.write(cmtTestKey(i, pins[@intCast(i % 4)]), cmtTestVal(i));
    try db.flushL0All();
    for (pins) |p| db.enqueueCompaction(.{ .depth = 1, .prefix = @as(PrefixData, p) >> 2 });
    try std.testing.expect(db.compactionBacklog() >= 4);

    // Each queued node has append pages, so budget 2 processes exactly two
    // of them and must leave the rest for a later call.
    try db.runCompactionBudget(2);
    try std.testing.expect(db.compactionBacklog() > 0);

    try db.runCompaction();
    try std.testing.expectEqual(@as(usize, 0), db.compactionBacklog());
}

test "compaction queue: duplicate enqueues collapse to one entry" {
    var db = try PrefixDB.init(std.testing.allocator);
    defer db.deinit();

    db.enqueueCompaction(.{ .depth = 1, .prefix = 5 });
    db.enqueueCompaction(.{ .depth = 1, .prefix = 5 });
    db.enqueueCompaction(.{ .depth = 1, .prefix = 5 });
    try std.testing.expectEqual(@as(usize, 1), db.compactionBacklog());
    db.enqueueCompaction(.{ .depth = 2, .prefix = 5 });
    try std.testing.expectEqual(@as(usize, 2), db.compactionBacklog());

    // FIFO order.
    try std.testing.expectEqual(NodeCoord{ .depth = 1, .prefix = 5 }, db.dequeueCompaction().?);
    try std.testing.expectEqual(NodeCoord{ .depth = 2, .prefix = 5 }, db.dequeueCompaction().?);
    try std.testing.expectEqual(@as(?NodeCoord, null), db.dequeueCompaction());
}
