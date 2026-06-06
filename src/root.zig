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

// ─── Re-export shared types from types.zig ─────────────────────────────────────
const t = @import("types.zig");
pub const Hash = t.Hash;
pub const ZERO_HASH = t.ZERO_HASH;
pub const STRIDE = t.STRIDE;
pub const PAGE_ENTRIES = t.PAGE_ENTRIES;
pub const CHILD_COUNT = t.CHILD_COUNT;
pub const S_MAX = t.S_MAX;
pub const A_MAX = t.A_MAX;
pub const MAX_DEPTH = t.MAX_DEPTH;
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
    read_sst_loads: u64 = 0,
    read_node_loads: u64 = 0,
    append_filter_probes: u64 = 0,
    append_filter_hits: u64 = 0,
    l0_flushes: u64 = 0,
    compaction_calls: u64 = 0,
    compaction_ops: u64 = 0,
    compaction_sst_reads: u64 = 0,
    compaction_sst_writes: u64 = 0,
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

pub const RoutingMap = std.AutoHashMap(PrefixData, NodePageId);

pub const RoutingTable = struct {
    maps: [MAX_DEPTH]RoutingMap,

    pub fn init(allocator: std.mem.Allocator) RoutingTable {
        var rt: RoutingTable = undefined;
        for (&rt.maps) |*m| m.* = RoutingMap.init(allocator);
        return rt;
    }

    pub fn deinit(self: *RoutingTable) void {
        for (&self.maps) |*m| m.deinit();
    }

    pub fn get(self: *const RoutingTable, depth: u32, prefix: PrefixData) ?NodePageId {
        return self.maps[depth - 1].get(prefix);
    }

    pub fn put(self: *RoutingTable, depth: u32, prefix: PrefixData, id: NodePageId) !void {
        try self.maps[depth - 1].put(prefix, id);
    }

    pub fn remove(self: *RoutingTable, depth: u32, prefix: PrefixData) bool {
        return self.maps[depth - 1].remove(prefix);
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

// ─── Pool(T) ──────────────────────────────────────────────────────────────────

pub fn Pool(comptime T: type) type {
    if (@sizeOf(T) < @sizeOf(u32)) @compileError("Pool(T): T must be ≥ 4 bytes");
    return struct {
        const Self = @This();
        pub const NONE: u32 = std.math.maxInt(u32);

        pages: []T,
        used: []u64,
        free_head: u32,
        live_count: u32,

        pub fn init(allocator: std.mem.Allocator, cap: u32) !Self {
            std.debug.assert(cap > 0 and cap < NONE);
            const words = (cap + 63) / 64;
            const pages = try allocator.alloc(T, cap);
            errdefer allocator.free(pages);
            const used = try allocator.alloc(u64, words);
            @memset(used, 0);
            for (0..cap) |i| {
                const next: u32 = if (i + 1 < cap) @intCast(i + 1) else NONE;
                writeLink(pages, @intCast(i), next);
            }
            return .{ .pages = pages, .used = used, .free_head = 0, .live_count = 0 };
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            allocator.free(self.pages);
            allocator.free(self.used);
        }

        pub fn alloc(self: *Self) ?u32 {
            if (self.free_head == NONE) return null;
            const id = self.free_head;
            self.free_head = readLink(self.pages, id);
            setBit(self.used, id);
            self.live_count += 1;
            return id;
        }

        pub fn free(self: *Self, id: u32) void {
            writeLink(self.pages, id, self.free_head);
            self.free_head = id;
            clearBit(self.used, id);
            self.live_count -= 1;
        }

        pub fn getPtr(self: *Self, id: u32) *T {
            return &self.pages[id];
        }

        pub fn isLive(self: *const Self, id: u32) bool {
            return (self.used[id >> 6] >> @as(u6, @intCast(id & 63))) & 1 == 1;
        }

        pub fn capacity(self: *const Self) u32 {
            return @intCast(self.pages.len);
        }

        /// Mark slot `id` as live and set its page data. Used during recovery.
        /// The `used` bitmap bit must NOT already be set.
        pub fn restoreSlot(self: *Self, id: u32, page: T) void {
            std.debug.assert(!self.isLive(id));
            self.pages[id] = page;
            setBit(self.used, id);
            self.live_count += 1;
        }

        /// Rebuild the embedded free-list links for all dead slots.
        /// Call once after all `restoreSlot` calls are done.
        pub fn rebuildFreeList(self: *Self) void {
            self.free_head = NONE;
            var i: u32 = @intCast(self.pages.len);
            while (i > 0) {
                i -= 1;
                if (!self.isLive(i)) {
                    writeLink(self.pages, i, self.free_head);
                    self.free_head = i;
                }
            }
        }

        fn readLink(pages: []T, id: u32) u32 {
            const src: *const [4]u8 = @ptrCast(&pages[id]);
            return std.mem.readInt(u32, src, .little);
        }

        fn writeLink(pages: []T, id: u32, next: u32) void {
            const dst: *[4]u8 = @ptrCast(&pages[id]);
            std.mem.writeInt(u32, dst, next, .little);
        }

        fn setBit(words: []u64, id: u32) void {
            words[id >> 6] |= @as(u64, 1) << @as(u6, @intCast(id & 63));
        }

        fn clearBit(words: []u64, id: u32) void {
            words[id >> 6] &= ~(@as(u64, 1) << @as(u6, @intCast(id & 63)));
        }
    };
}

// ─── Cache configuration (§4.3) ───────────────────────────────────────────────

/// Maximum node-page slots at depths 1–2 (64 L1 nodes + 4096 L2 nodes).
/// Node pages with IDs in `0..PIN_NODE_CAP` are always kept in RAM.
pub const PIN_NODE_CAP: u32 = CHILD_COUNT + CHILD_COUNT * CHILD_COUNT; // 4160

pub const DEFAULT_NODE_CACHE_CAP: u32 = 1024;
pub const DEFAULT_SST_CACHE_CAP: u32 = 4096;

/// Controls the size of the two configurable caches for depths ≥ 3.
pub const CacheConfig = struct {
    /// LRU capacity for node pages at depth ≥ 3.
    node_cap: u32 = DEFAULT_NODE_CACHE_CAP,
    /// LRU capacity for SST (KV) pages across all depths.
    sst_cap: u32 = DEFAULT_SST_CACHE_CAP,
};

// ─── Page heap (§4.3) ─────────────────────────────────────────────────────────
//
// Three storage tiers:
//
//   pin_nodes   — Pool(NodePage) for depths 1–2, always in RAM, IDs 0..PIN_NODE_CAP-1.
//   node_cache  — LruCache(NodePage) for depths 3–5, configurable size, write-through
//                 to disk (NodePageStore) when a store_dir is provided.  On a cache
//                 miss the page is reloaded from disk.
//   sst_cache   — LruCache(SstPage) for all depths, configurable size.  SST pages are
//                 not written to disk in this implementation (count field not preserved
//                 in the on-disk format); the cache acts as a bounded pool and returns
//                 error.SstCacheFull when capacity is exceeded.

pub const Heap = struct {
    // Depths 1-2: node pages pinned to RAM (never evicted).
    pin_nodes: Pool(NodePage),

    // Depths 3-5: node pages in an LRU cache, backed by disk when a store is available.
    node_cache: cache_mod.LruCache(NodePage),
    // Monotonically-increasing counter; each depth-≥3 node page gets a unique ID ≥ PIN_NODE_CAP.
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
        var pin_nodes = try Pool(NodePage).init(allocator, PIN_NODE_CAP);
        errdefer pin_nodes.deinit(allocator);

        var node_cache = try cache_mod.LruCache(NodePage).init(allocator, config.node_cap);
        errdefer node_cache.deinit(allocator);

        const sst_cache = try cache_mod.LruCache(SstPage).init(allocator, config.sst_cap);

        return .{
            .pin_nodes = pin_nodes,
            .node_cache = node_cache,
            .next_node_id = PIN_NODE_CAP,
            .sst_cache = sst_cache,
            .next_sst_id = 0,
            .node_store = if (store) |s| page_store.NodePageStore.init(s.dir, s.io) else null,
            .sst_store = if (store) |s| page_store.SstPageStore.init(s.dir, s.io) else null,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Heap) void {
        self.pin_nodes.deinit(self.allocator);
        self.node_cache.deinit(self.allocator);
        self.sst_cache.deinit(self.allocator);
    }

    /// Write a node page.  Depth ≤ 2 → pinned pool; depth ≥ 3 → LRU cache + disk.
    pub fn writeNodePage(self: *Heap, depth: u32, page: NodePage) !NodePageId {
        if (depth <= 2) {
            const id = self.pin_nodes.alloc() orelse return error.PinnedNodePoolFull;
            self.pin_nodes.pages[id] = page;
            return id;
        }
        // Depth 3-5: refuse without a disk store if the cache would need to evict.
        if (self.node_cache.len >= self.node_cache.cap and self.node_store == null) {
            return error.NodeCacheFull;
        }
        const id = self.next_node_id;
        self.next_node_id += 1;
        // Write-through: persist before inserting so an evicted entry is recoverable.
        if (self.node_store) |*store| {
            try store.write(id, &page);
            if (comptime options.enable_metrics) self.heap_stats.disk_node_writes += 1;
        }
        try self.node_cache.put(id, page);
        return id;
    }

    /// Write an SST page (write-through to disk when a store is configured).
    /// Without a disk store the cache acts as a bounded pool; SstCacheFull is
    /// returned rather than silently evicting data that cannot be recovered.
    pub fn writeSstPage(self: *Heap, page: SstPage) !PayloadSlotId {
        if (self.sst_store == null and self.sst_cache.len >= self.sst_cache.cap)
            return error.SstCacheFull;
        const id = self.next_sst_id;
        self.next_sst_id += 1;
        if (self.sst_store) |*store| {
            try store.write(id, &page);
            if (comptime options.enable_metrics) self.heap_stats.disk_sst_writes += 1;
        }
        try self.sst_cache.put(id, page);
        return id;
    }

    /// Retrieve a node page by ID.  Returns null if the slot is no longer live.
    /// For depth-≥3 IDs a cache miss triggers a disk load when a store is available.
    pub fn getNodePage(self: *Heap, id: NodePageId) !?NodePage {
        if (id < PIN_NODE_CAP) {
            if (!self.pin_nodes.isLive(id)) {
                if (comptime options.enable_metrics) self.heap_stats.node_cache_misses += 1;
                return null;
            }
            if (comptime options.enable_metrics) self.heap_stats.node_cache_hits += 1;
            return self.pin_nodes.pages[id];
        }
        // LRU cache lookup.
        if (self.node_cache.get(id)) |page| {
            if (comptime options.enable_metrics) self.heap_stats.node_cache_hits += 1;
            return page;
        }
        // Cache miss: reload from disk.
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
        if (id < PIN_NODE_CAP) {
            self.pin_nodes.free(id);
        } else {
            self.node_cache.remove(id);
        }
    }

    pub fn freeSstPage(self: *Heap, id: PayloadSlotId) void {
        self.sst_cache.remove(id);
    }
};

// ─── PrefixDB top-level engine (§1) ───────────────────────────────────────────

/// Identifies a node (depth, prefix) for the compaction queue.
pub const NodeCoord = struct {
    depth: u32,
    prefix: PrefixData,
};

pub const PrefixDB = struct {
    l0: L0Buffer,
    routing: RoutingTable,
    heap: Heap,
    compaction_queue: std.ArrayList(NodeCoord),
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
        return .{
            .l0 = L0Buffer.init(allocator),
            .routing = RoutingTable.init(allocator),
            .heap = heap,
            .compaction_queue = std.ArrayList(NodeCoord).empty,
            .allocator = allocator,
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
                // Fresh database — no recovery needed.
                return initWithConfig(allocator, config, store);
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

        // Restore pin_nodes bitmap from manifest and reload page data from disk.
        const used_words = manifest.pin_used.len;
        if (used_words > 0) {
            const ns = heap.node_store orelse return error.StoreRequired;
            _ = ns;
            // Copy the bitmap into the pool's used[] array.
            const copy_words = @min(used_words, heap.pin_nodes.used.len);
            @memcpy(heap.pin_nodes.used[0..copy_words], manifest.pin_used[0..copy_words]);
            // Reload each live pin_node from disk.
            for (0..@intCast(heap.pin_nodes.capacity())) |i| {
                const id: u32 = @intCast(i);
                if (heap.pin_nodes.isLive(id)) {
                    const page = try @constCast(&heap.node_store.?).read(id);
                    heap.pin_nodes.pages[id] = page;
                    heap.pin_nodes.live_count += 1;
                }
            }
            heap.pin_nodes.rebuildFreeList();
        }

        // Restore routing table.
        var routing = RoutingTable.init(allocator);
        errdefer routing.deinit();
        for (manifest.routes) |r| {
            try routing.put(r.depth, r.prefix, r.node_id);
        }

        // Restore L0 buffer.
        var l0 = L0Buffer.init(allocator);
        errdefer l0.deinit();
        for (manifest.l0) |entry| {
            try l0.append(entry);
        }

        return .{
            .l0 = l0,
            .routing = routing,
            .heap = heap,
            .compaction_queue = std.ArrayList(NodeCoord).empty,
            .allocator = allocator,
        };
    }

    /// Persist the current state to `store`.
    /// Writes all live pin_nodes to node_store, then writes manifest.bin.
    /// Must be called before process exit to preserve the database.
    pub fn flush(self: *PrefixDB, store: page_store.DiskStore) !void {
        // Write live pin_nodes (depths 1-2) to node_store.
        if (self.heap.node_store) |*ns| {
            for (0..@intCast(self.heap.pin_nodes.capacity())) |i| {
                const id: u32 = @intCast(i);
                if (self.heap.pin_nodes.isLive(id)) {
                    try ns.write(id, &self.heap.pin_nodes.pages[id]);
                }
            }
        }

        // Count routing entries.
        var route_count: u32 = 0;
        for (&self.routing.maps) |*m| route_count += @as(u32, @intCast(m.count()));

        // Count L0 entries.
        const l0_count: u32 = @intCast(self.l0.entries.items.len);

        const header = page_store.ManifestHeader{
            .magic         = page_store.MANIFEST_MAGIC,
            .version       = page_store.MANIFEST_VERSION,
            .next_node_id  = self.heap.next_node_id,
            .next_sst_id   = self.heap.next_sst_id,
            .pin_used_words = @intCast(self.heap.pin_nodes.used.len),
            .routing_count = route_count,
            .l0_count      = l0_count,
            ._pad          = 0,
        };

        // Build routing entries slice.
        var routes = try std.ArrayList(page_store.ManifestRouteEntry).initCapacity(self.allocator, route_count);
        defer routes.deinit(self.allocator);
        for (&self.routing.maps, 0..) |*m, di| {
            var it = m.iterator();
            while (it.next()) |kv| {
                routes.appendAssumeCapacity(.{
                    .depth   = @intCast(di + 1),
                    .prefix  = kv.key_ptr.*,
                    .node_id = kv.value_ptr.*,
                });
            }
        }

        try page_store.writeManifest(
            store,
            header,
            self.heap.pin_nodes.used,
            routes.items,
            self.l0.entries.items,
        );
    }

    pub fn deinit(self: *PrefixDB) void {
        self.l0.deinit();
        self.routing.deinit();
        self.heap.deinit();
        self.compaction_queue.deinit(self.allocator);
    }

    // ─── Write (§5.2) ─────────────────────────────────────────────────────────

    /// Append (K, V) to L0; flush to L1 when the prefix group reaches PAGE_ENTRIES.
    pub fn write(self: *PrefixDB, key: Key, value: Value) !void {
        if (comptime options.enable_metrics) self.stats.write_ops += 1;
        try self.l0.append(.{ .key = key, .value = value });
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

        // Steps 2–9: search levels depth 1..MAX_DEPTH; shallowest hit wins.
        for (1..MAX_DEPTH + 1) |d_usize| {
            const d: u32 = @intCast(d_usize);
            const p = prefixData(&key, d);
            const node_id = self.routing.get(d, p) orelse continue;
            const node = (try self.heap.getNodePage(node_id)) orelse continue;
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

    /// Attach an SST page to a node's append zone (CoW node page update).
    fn appendSstToNode(
        self: *PrefixDB,
        depth: u32,
        prefix: PrefixData,
        sst_id: PayloadSlotId,
        count: u8,
        filter: [PAGE_ENTRIES]u16,
    ) anyerror!void {
        const old_id = self.routing.get(depth, prefix);

        var node = std.mem.zeroes(NodePage);
        if (old_id) |id| {
            if (try self.heap.getNodePage(id)) |existing| node = existing;
        }

        // Append zone full: compact inline so we always have room.
        if (node.append_count >= A_MAX) {
            try self.appendToSortedMerge(depth, prefix);
            node = std.mem.zeroes(NodePage);
            if (self.routing.get(depth, prefix)) |id| {
                if (try self.heap.getNodePage(id)) |compacted| node = compacted;
            }
        }

        const ac = node.append_count;
        node.append_slot_ids[ac] = sst_id;
        node.append_page_counts[ac] = count;
        node.append_prefix16[ac] = filter;
        node.append_count += 1;

        const new_id = try self.heap.writeNodePage(depth, node);
        try self.routing.put(depth, prefix, new_id);
        if (old_id) |id| self.heap.freeNodePage(id);

        if (node.append_count == A_MAX) {
            self.compaction_queue.append(
                self.allocator,
                .{ .depth = depth, .prefix = prefix },
            ) catch {};
        }
    }

    // ─── Compaction (§6) ──────────────────────────────────────────────────────

    /// Drain the compaction queue, running the appropriate procedure per node.
    pub fn runCompaction(self: *PrefixDB) !void {
        if (comptime options.enable_metrics) self.stats.compaction_calls += 1;
        while (self.compaction_queue.pop()) |coord| {
            const node_id = self.routing.get(coord.depth, coord.prefix) orelse continue;
            const node = (try self.heap.getNodePage(node_id)) orelse continue;
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
        const node_id = self.routing.get(depth, prefix) orelse return 0;
        const node = (try self.heap.getNodePage(node_id)) orelse return 0;
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
        for (&self.routing.maps) |*map| {
            var it = map.iterator();
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
        const node_id = self.routing.get(depth, prefix) orelse return;
        const old_node = (try self.heap.getNodePage(node_id)) orelse return;
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

            if (chunk.len == PAGE_ENTRIES and depth < MAX_DEPTH) {
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

        const new_node_id = try self.heap.writeNodePage(depth, new_node);
        try self.routing.put(depth, prefix, new_node_id);
        self.heap.freeNodePage(node_id);
        for (old_node.sorted_slot_ids[0..old_node.sorted_count]) |id| self.heap.freeSstPage(id);
        for (old_node.append_slot_ids[0..old_node.append_count]) |id| self.heap.freeSstPage(id);

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
        if (depth >= MAX_DEPTH) return;
        const alloc = self.allocator;
        const node_id = self.routing.get(depth, prefix) orelse return;
        const old_node = (try self.heap.getNodePage(node_id)) orelse return;
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
                    const cur_id = self.routing.get(child_depth, cp);
                    var cn = std.mem.zeroes(NodePage);
                    if (cur_id) |id| {
                        if (try self.heap.getNodePage(id)) |existing| cn = existing;
                    }
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
                        const ncid = try self.heap.writeNodePage(child_depth, cn);
                        try self.routing.put(child_depth, cp, ncid);
                        if (cur_id) |id| self.heap.freeNodePage(id);
                        if (cn.sorted_count >= S_MAX)
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

        const new_node_id = try self.heap.writeNodePage(depth, new_node);
        try self.routing.put(depth, prefix, new_node_id);
        self.heap.freeNodePage(node_id);
        for (old_node.sorted_slot_ids[0..old_node.sorted_count]) |id| self.heap.freeSstPage(id);
    }

    /// §6.3: Merge a sparse child node back into its parent's sorted zone.
    fn downwardMerge(self: *PrefixDB, depth: u32, prefix: PrefixData) !void {
        std.debug.assert(depth > 1);
        const alloc = self.allocator;
        const parent_depth = depth - 1;
        const parent_prefix: PrefixData = prefix >> STRIDE;

        const child_id = self.routing.get(depth, prefix) orelse return;
        const old_child = (try self.heap.getNodePage(child_id)) orelse return;
        const parent_id = self.routing.get(parent_depth, parent_prefix) orelse return;
        const old_parent = (try self.heap.getNodePage(parent_id)) orelse return;

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
        @memcpy(new_parent.sorted_slot_ids[0..new_ids.items.len], new_ids.items);
        @memcpy(new_parent.sorted_min4[0..new_min4.items.len], new_min4.items);
        @memcpy(new_parent.sorted_page_counts[0..new_counts.items.len], new_counts.items);
        for (0..old_parent.append_count) |ai| {
            new_parent.append_slot_ids[ai] = old_parent.append_slot_ids[ai];
            new_parent.append_page_counts[ai] = old_parent.append_page_counts[ai];
            new_parent.append_prefix16[ai] = old_parent.append_prefix16[ai];
        }
        const new_parent_id = try self.heap.writeNodePage(parent_depth, new_parent);
        try self.routing.put(parent_depth, parent_prefix, new_parent_id);
        self.heap.freeNodePage(parent_id);
        for (old_parent.sorted_slot_ids[0..old_parent.sorted_count]) |id| self.heap.freeSstPage(id);

        _ = self.routing.remove(depth, prefix);
        self.heap.freeNodePage(child_id);
        for (old_child.sorted_slot_ids[0..old_child.sorted_count]) |id| self.heap.freeSstPage(id);
        for (old_child.append_slot_ids[0..old_child.append_count]) |id| self.heap.freeSstPage(id);

        if (parent_depth > 1 and (try self.countNodeEntries(parent_depth, parent_prefix)) < MERGE_THRESHOLD)
            self.compaction_queue.append(alloc, .{ .depth = parent_depth, .prefix = parent_prefix }) catch {};
    }
};

// ─── Prefix helpers (§4.2.1, §7.1) ───────────────────────────────────────────

/// prefixData(K, d) = top 6d bits of K, zero-padded into a u32.
pub fn prefixData(key: *const Key, depth: u32) PrefixData {
    const top4: u32 = (@as(u32, key[0]) << 24) | (@as(u32, key[1]) << 16) |
        (@as(u32, key[2]) << 8) | @as(u32, key[3]);
    const shift: u5 = @intCast(32 - STRIDE * depth);
    return top4 >> shift;
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
}

test "prefixData depth 1 extracts top 6 bits" {
    const key = [_]u8{0b10110100} ++ [_]u8{0} ** 31;
    try std.testing.expectEqual(@as(PrefixData, 0b101101), prefixData(&key, 1));
}

test "prefixData depth 5 extracts top 30 bits" {
    const key = [_]u8{ 0xFF, 0xFF, 0xFF, 0xFF } ++ [_]u8{0} ** 28;
    try std.testing.expectEqual(@as(PrefixData, 0x3FFF_FFFF), prefixData(&key, 5));
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
    try rt.put(1, 0b101101, 42);
    try std.testing.expectEqual(@as(?NodePageId, 42), rt.get(1, 0b101101));
    try std.testing.expectEqual(@as(?NodePageId, null), rt.get(1, 0b000000));
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

test "Pool alloc, write, free, realloc" {
    var pool = try Pool(SstPage).init(std.testing.allocator, 4);
    defer pool.deinit(std.testing.allocator);
    const a = pool.alloc().?;
    const b = pool.alloc().?;
    try std.testing.expect(a != b);
    try std.testing.expect(pool.isLive(a));
    pool.free(a);
    try std.testing.expect(!pool.isLive(a));
    const c = pool.alloc().?;
    try std.testing.expectEqual(a, c);
    pool.free(b);
    pool.free(c);
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
    try std.testing.expectEqual(@as(?NodePage, null), try heap.getNodePage(id));
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
    try std.testing.expect(db.routing.get(1, 0) != null);

    const node_id = db.routing.get(1, 0).?;
    const node = (try db.heap.getNodePage(node_id)).?;
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

    const node_id = db.routing.get(1, 0).?;
    const node = (try db.heap.getNodePage(node_id)).?;
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

    const before_id = db.routing.get(1, 0).?;
    const before = (try db.heap.getNodePage(before_id)).?;
    try std.testing.expectEqual(@as(u8, A_MAX), before.append_count);
    try std.testing.expect(db.compaction_queue.items.len > 0);

    try db.runCompaction();

    const after_id = db.routing.get(1, 0).?;
    const after = (try db.heap.getNodePage(after_id)).?;
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
    outer: for (2..MAX_DEPTH + 1) |d| {
        const dd: u32 = @intCast(d);
        for (0..64) |p| {
            if (db.routing.get(dd, @intCast(p)) != null) {
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
    // depth=2 → pinned pool
    const nid2 = try db.heap.writeNodePage(2, node2);
    try db.routing.put(2, 0, nid2);

    try db.compaction_queue.append(db.allocator, .{ .depth = 2, .prefix = 0 });
    try db.runCompaction();

    if (db.routing.get(2, 0)) |id| {
        const n = (try db.heap.getNodePage(id)).?;
        try std.testing.expectEqual(@as(u8, 0), n.sorted_count);
    }
    const d3id = db.routing.get(3, 0).?;
    const d3n = (try db.heap.getNodePage(d3id)).?;
    try std.testing.expectEqual(@as(u8, 2), d3n.sorted_count);
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
    // depth=2 → pinned pool
    const cid = try db.heap.writeNodePage(2, child_node);
    try db.routing.put(2, child_prefix, cid);

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
    // depth=1 → pinned pool
    const pid = try db.heap.writeNodePage(1, parent_node);
    try db.routing.put(1, 0, pid);

    try db.compaction_queue.append(db.allocator, .{ .depth = 2, .prefix = child_prefix });
    try db.runCompaction();

    try std.testing.expectEqual(@as(?NodePageId, null), db.routing.get(2, child_prefix));

    const new_pid = db.routing.get(1, 0).?;
    const new_parent = (try db.heap.getNodePage(new_pid)).?;
    var total: u32 = 0;
    for (new_parent.sorted_slot_ids[0..new_parent.sorted_count]) |id| {
        total += (try db.heap.getSstPage(id)).?.count;
    }
    try std.testing.expectEqual(@as(u32, 8), total);
}
