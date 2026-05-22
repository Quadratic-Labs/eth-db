//! PrefixDB in-memory engine model.
//!
//! Core data types and constants live in types.zig; this module holds the
//! engine structs (RoutingTable, L0Buffer, Pool, Heap, PrefixDB) plus the
//! write/read operations and prefix-helper functions.
//! page_store.zig imports types.zig directly, keeping the dependency graph acyclic.

const std = @import("std");

// ─── Re-export sub-modules ─────────────────────────────────────────────────────
pub const merkle = @import("merkle.zig");
pub const page_store = @import("page_store.zig");

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

// ─── Page heap (§4.3) ─────────────────────────────────────────────────────────

pub const Heap = struct {
    node_pool: Pool(NodePage),
    sst_pool: Pool(SstPage),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, node_cap: u32, sst_cap: u32) !Heap {
        var node_pool = try Pool(NodePage).init(allocator, node_cap);
        errdefer node_pool.deinit(allocator);
        const sst_pool = try Pool(SstPage).init(allocator, sst_cap);
        return .{ .node_pool = node_pool, .sst_pool = sst_pool, .allocator = allocator };
    }

    pub fn deinit(self: *Heap) void {
        self.node_pool.deinit(self.allocator);
        self.sst_pool.deinit(self.allocator);
    }

    pub fn writeNodePage(self: *Heap, page: NodePage) !NodePageId {
        const id = self.node_pool.alloc() orelse return error.NodePoolFull;
        self.node_pool.pages[id] = page;
        return id;
    }

    pub fn writeSstPage(self: *Heap, page: SstPage) !PayloadSlotId {
        const id = self.sst_pool.alloc() orelse return error.SstPoolFull;
        self.sst_pool.pages[id] = page;
        return id;
    }

    pub fn nodePagePtr(self: *Heap, id: NodePageId) ?*NodePage {
        if (!self.node_pool.isLive(id)) return null;
        return self.node_pool.getPtr(id);
    }

    pub fn sstPagePtr(self: *Heap, id: PayloadSlotId) ?*SstPage {
        if (!self.sst_pool.isLive(id)) return null;
        return self.sst_pool.getPtr(id);
    }

    pub fn freeNodePage(self: *Heap, id: NodePageId) void {
        self.node_pool.free(id);
    }

    pub fn freeSstPage(self: *Heap, id: PayloadSlotId) void {
        self.sst_pool.free(id);
    }
};

// ─── PrefixDB top-level engine (§1) ───────────────────────────────────────────

pub const DEFAULT_NODE_CAP: u32 = 256;
pub const DEFAULT_SST_CAP: u32 = 1024;

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

    pub fn init(allocator: std.mem.Allocator) !PrefixDB {
        return initCapacity(allocator, DEFAULT_NODE_CAP, DEFAULT_SST_CAP);
    }

    pub fn initCapacity(allocator: std.mem.Allocator, node_cap: u32, sst_cap: u32) !PrefixDB {
        var heap = try Heap.init(allocator, node_cap, sst_cap);
        errdefer heap.deinit();
        return .{
            .l0 = L0Buffer.init(allocator),
            .routing = RoutingTable.init(allocator),
            .heap = heap,
            .compaction_queue = std.ArrayList(NodeCoord){},
            .allocator = allocator,
        };
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
        try self.l0.append(.{ .key = key, .value = value });
        const p = prefixData(&key, 1);
        if (self.l0.prefixCount(@intCast(p)) >= PAGE_ENTRIES) {
            try self.flushL0Prefix(p);
        }
    }

    // ─── Read (§5.1) ──────────────────────────────────────────────────────────

    /// Return the most-recent value for key, or null if not present.
    pub fn read(self: *PrefixDB, key: Key) ?Value {
        // Step 1: L0 — scan backwards so the most-recent write is found first.
        var i: usize = self.l0.entries.items.len;
        while (i > 0) {
            i -= 1;
            if (std.mem.eql(u8, &self.l0.entries.items[i].key, &key)) {
                return self.l0.entries.items[i].value;
            }
        }

        // Steps 2–9: search levels depth 1..MAX_DEPTH; shallowest hit wins.
        for (1..MAX_DEPTH + 1) |d_usize| {
            const d: u32 = @intCast(d_usize);
            const p = prefixData(&key, d);
            const node_id = self.routing.get(d, p) orelse continue;
            const node = self.heap.nodePagePtr(node_id) orelse continue;

            const q = prefix32(&key, d);
            const f = prefix16(&key, d);
            var opp_count: u32 = 0;

            // Append zone (most recent): scan from newest page to oldest.
            var append_result: ?Value = null;
            var j: usize = node.append_count;
            while (j > 0 and append_result == null) {
                j -= 1;
                if (filterContains(&node.append_prefix16[j], f)) {
                    opp_count += 1;
                    if (self.heap.sstPagePtr(node.append_slot_ids[j])) |sst| {
                        append_result = binarySearchSst(sst, &key);
                    }
                }
            }

            // Sorted zone (fallback when key not found in append zone).
            var sorted_result: ?Value = null;
            if (append_result == null and node.sorted_count > 0) {
                // Upper-bound search: find first index where sorted_min4[idx] > q.
                var lo: usize = 0;
                var hi: usize = node.sorted_count;
                while (lo < hi) {
                    const mid = lo + (hi - lo) / 2;
                    if (node.sorted_min4[mid] <= q) lo = mid + 1 else hi = mid;
                }
                // lo-1 is the last page whose min key ≤ q; that page may contain K.
                if (lo > 0) {
                    if (self.heap.sstPagePtr(node.sorted_slot_ids[lo - 1])) |sst| {
                        sorted_result = binarySearchSst(sst, &key);
                    }
                }
            }

            // Opportunistic compaction: queue node if we loaded ≥ T_OPP append pages.
            if (opp_count >= T_OPP) {
                self.compaction_queue.append(self.allocator, .{ .depth = d, .prefix = p }) catch {};
            }

            // Append zone overrides sorted zone; return on first depth that holds the key.
            const depth_result = append_result orelse sorted_result;
            if (depth_result != null) return depth_result;
        }

        return null;
    }

    // ─── Private helpers ──────────────────────────────────────────────────────

    /// Flush all L0 entries for `prefix` to L1, deduplicating and sorting them.
    fn flushL0Prefix(self: *PrefixDB, prefix: PrefixData) !void {
        const alloc = self.allocator;

        // Collect unique keys: iterate L0 backwards so the first occurrence of
        // each key we encounter is its most recent value.
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

        // Rebuild L0 without this prefix group.
        var new_entries = std.ArrayList(KvEntry){};
        errdefer new_entries.deinit(alloc);
        for (self.l0.entries.items) |e| {
            if (prefixData(&e.key, 1) != prefix) {
                try new_entries.append(alloc, e);
            }
        }
        self.l0.entries.deinit(alloc);
        self.l0.entries = new_entries;

        if (map.count() == 0) return;

        // Sort unique entries by key.
        var sorted = std.ArrayList(KvEntry){};
        defer sorted.deinit(alloc);
        var it = map.iterator();
        while (it.next()) |kv| {
            try sorted.append(alloc, .{ .key = kv.key_ptr.*, .value = kv.value_ptr.* });
        }
        std.mem.sort(KvEntry, sorted.items, {}, kvLessThan);

        // Write SST pages of up to PAGE_ENTRIES entries each.
        var offset: usize = 0;
        while (offset < sorted.items.len) {
            const end = @min(offset + PAGE_ENTRIES, sorted.items.len);
            try self.writeSstChunk(1, prefix, sorted.items[offset..end]);
            offset = end;
        }
    }

    /// Build one SST page from `chunk`, compute its append_prefix16 filter, and
    /// attach it to the L1 node for (depth, prefix) via CoW.
    fn writeSstChunk(self: *PrefixDB, depth: u32, prefix: PrefixData, chunk: []const KvEntry) !void {
        std.debug.assert(chunk.len > 0 and chunk.len <= PAGE_ENTRIES);

        var sst = std.mem.zeroes(SstPage);
        sst.count = @intCast(chunk.len);
        @memcpy(sst.entries[0..chunk.len], chunk);
        const sst_id = try self.heap.writeSstPage(sst);

        // Build prefix16 filter.
        // chunk is sorted by key and shares a 6-bit prefix, so prefix16 values
        // are non-decreasing (§7.1).  Unused slots are padded with maxInt(u16).
        var filter = [_]u16{std.math.maxInt(u16)} ** PAGE_ENTRIES;
        for (chunk, 0..) |e, idx| filter[idx] = prefix16(&e.key, depth);

        try self.appendSstToNode(depth, prefix, sst_id, filter);
    }

    /// Attach an SST page to a node's append zone (CoW node page update).
    fn appendSstToNode(
        self: *PrefixDB,
        depth: u32,
        prefix: PrefixData,
        sst_id: PayloadSlotId,
        filter: [PAGE_ENTRIES]u16,
    ) !void {
        const old_id = self.routing.get(depth, prefix);

        // Copy current node state (or start fresh for a new node).
        var node = std.mem.zeroes(NodePage);
        if (old_id) |id| {
            if (self.heap.nodePagePtr(id)) |ptr| node = ptr.*;
        }

        std.debug.assert(node.append_count < A_MAX);

        const ac = node.append_count;
        node.append_slot_ids[ac] = sst_id;
        node.append_prefix16[ac] = filter;
        node.append_count += 1;

        // CoW: allocate a new node page, update routing, release the old page.
        const new_id = try self.heap.writeNodePage(node);
        try self.routing.put(depth, prefix, new_id);
        if (old_id) |id| self.heap.freeNodePage(id);

        // Queue for append-to-sorted compaction when the append zone fills (§6.1).
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
        while (self.compaction_queue.pop()) |coord| {
            const node_id = self.routing.get(coord.depth, coord.prefix) orelse continue;
            const node = self.heap.nodePagePtr(node_id) orelse continue;
            if (coord.depth > 1 and self.countNodeEntries(coord.depth, coord.prefix) < MERGE_THRESHOLD) {
                try self.downwardMerge(coord.depth, coord.prefix);
            } else if (node.sorted_count >= S_MAX) {
                try self.upwardSplit(coord.depth, coord.prefix);
            } else if (node.append_count > 0) {
                try self.appendToSortedMerge(coord.depth, coord.prefix);
            }
        }
    }

    /// Count total live KV entries across all SST pages of a node.
    fn countNodeEntries(self: *PrefixDB, depth: u32, prefix: PrefixData) u32 {
        const node_id = self.routing.get(depth, prefix) orelse return 0;
        const node = self.heap.nodePagePtr(node_id) orelse return 0;
        var count: u32 = 0;
        for (node.sorted_slot_ids[0..node.sorted_count]) |id| {
            if (self.heap.sstPagePtr(id)) |sst| count += sst.count;
        }
        for (node.append_slot_ids[0..node.append_count]) |id| {
            if (self.heap.sstPagePtr(id)) |sst| count += sst.count;
        }
        return count;
    }

    /// §6.1: Merge the append zone into the sorted zone; promote homogeneous pages up.
    fn appendToSortedMerge(self: *PrefixDB, depth: u32, prefix: PrefixData) !void {
        const alloc = self.allocator;
        const node_id = self.routing.get(depth, prefix) orelse return;
        const node = self.heap.nodePagePtr(node_id) orelse return;
        if (node.append_count == 0) return;
        const old_node = node.*;

        // Gather all entries: sorted zone first (oldest), then append oldest→newest.
        var all_entries = std.ArrayList(KvEntry){};
        defer all_entries.deinit(alloc);
        for (old_node.sorted_slot_ids[0..old_node.sorted_count]) |id| {
            if (self.heap.sstPagePtr(id)) |sst|
                for (sst.entries[0..sst.count]) |e| try all_entries.append(alloc, e);
        }
        for (old_node.append_slot_ids[0..old_node.append_count]) |id| {
            if (self.heap.sstPagePtr(id)) |sst|
                for (sst.entries[0..sst.count]) |e| try all_entries.append(alloc, e);
        }

        // Dedup: put() in source order so last write (newest) wins.
        var dedup = std.AutoHashMap(Key, Value).init(alloc);
        defer dedup.deinit();
        for (all_entries.items) |e| try dedup.put(e.key, e.value);

        var survivors = std.ArrayList(KvEntry){};
        defer survivors.deinit(alloc);
        var it = dedup.iterator();
        while (it.next()) |kv| try survivors.append(alloc, .{ .key = kv.key_ptr.*, .value = kv.value_ptr.* });
        std.mem.sort(KvEntry, survivors.items, {}, kvLessThan);

        // Repartition into pages; check sub-prefix promotion for each full page.
        var new_ids = std.ArrayList(PayloadSlotId){};
        defer new_ids.deinit(alloc);
        var new_min4 = std.ArrayList(u32){};
        defer new_min4.deinit(alloc);

        var offset: usize = 0;
        while (offset < survivors.items.len) {
            const end = @min(offset + PAGE_ENTRIES, survivors.items.len);
            const chunk = survivors.items[offset..end];

            if (chunk.len == PAGE_ENTRIES and depth < MAX_DEPTH) {
                const f0 = prefix16(&chunk[0].key, depth);
                const f63 = prefix16(&chunk[PAGE_ENTRIES - 1].key, depth);
                if (f0 >> 10 == f63 >> 10) {
                    try self.promoteSstPage(depth, chunk);
                    offset = end;
                    continue;
                }
            }

            var sst = std.mem.zeroes(SstPage);
            sst.count = @intCast(chunk.len);
            @memcpy(sst.entries[0..chunk.len], chunk);
            const sst_id = try self.heap.writeSstPage(sst);
            try new_ids.append(alloc, sst_id);
            try new_min4.append(alloc, prefix32(&chunk[0].key, depth));
            offset = end;
        }

        // Build new node: empty append zone, updated sorted zone.
        var new_node = std.mem.zeroes(NodePage);
        new_node.sorted_count = @intCast(new_ids.items.len);
        new_node.append_count = 0;
        new_node.child_commitments = old_node.child_commitments;
        @memcpy(new_node.sorted_slot_ids[0..new_ids.items.len], new_ids.items);
        @memcpy(new_node.sorted_min4[0..new_min4.items.len], new_min4.items);

        const new_node_id = try self.heap.writeNodePage(new_node);
        try self.routing.put(depth, prefix, new_node_id);
        self.heap.freeNodePage(node_id);
        for (old_node.sorted_slot_ids[0..old_node.sorted_count]) |id| self.heap.freeSstPage(id);
        for (old_node.append_slot_ids[0..old_node.append_count]) |id| self.heap.freeSstPage(id);

        if (new_node.sorted_count >= S_MAX)
            self.compaction_queue.append(alloc, .{ .depth = depth, .prefix = prefix }) catch {};
        if (depth > 1 and self.countNodeEntries(depth, prefix) < MERGE_THRESHOLD)
            self.compaction_queue.append(alloc, .{ .depth = depth, .prefix = prefix }) catch {};
    }

    /// Promote a full sorted page to the sorted zone of the L(k+1) child node.
    fn promoteSstPage(self: *PrefixDB, parent_depth: u32, chunk: []const KvEntry) !void {
        const child_depth = parent_depth + 1;
        const child_prefix = prefixData(&chunk[0].key, child_depth);
        const old_child_id = self.routing.get(child_depth, child_prefix);
        var cn = std.mem.zeroes(NodePage);
        if (old_child_id) |id| { if (self.heap.nodePagePtr(id)) |ptr| { cn = ptr.*; } }

        var sst = std.mem.zeroes(SstPage);
        sst.count = @intCast(chunk.len);
        @memcpy(sst.entries[0..chunk.len], chunk);
        const sst_id = try self.heap.writeSstPage(sst);

        const sc = cn.sorted_count;
        std.debug.assert(sc < S_MAX);
        cn.sorted_slot_ids[sc] = sst_id;
        cn.sorted_min4[sc] = prefix32(&chunk[0].key, child_depth);
        cn.sorted_count += 1;

        const new_cid = try self.heap.writeNodePage(cn);
        try self.routing.put(child_depth, child_prefix, new_cid);
        if (old_child_id) |id| self.heap.freeNodePage(id);
        if (cn.sorted_count >= S_MAX)
            self.compaction_queue.append(self.allocator, .{ .depth = child_depth, .prefix = child_prefix }) catch {};
    }

    /// §6.2: Merge all sorted pages; promote groups with ≥64 entries to L(k+1).
    fn upwardSplit(self: *PrefixDB, depth: u32, prefix: PrefixData) !void {
        if (depth >= MAX_DEPTH) return;
        const alloc = self.allocator;
        const node_id = self.routing.get(depth, prefix) orelse return;
        const node = self.heap.nodePagePtr(node_id) orelse return;
        const old_node = node.*;
        const child_depth = depth + 1;

        var all_entries = std.ArrayList(KvEntry){};
        defer all_entries.deinit(alloc);
        for (old_node.sorted_slot_ids[0..old_node.sorted_count]) |id| {
            if (self.heap.sstPagePtr(id)) |sst|
                for (sst.entries[0..sst.count]) |e| try all_entries.append(alloc, e);
        }
        std.mem.sort(KvEntry, all_entries.items, {}, kvLessThan);

        var new_ids = std.ArrayList(PayloadSlotId){};
        defer new_ids.deinit(alloc);
        var new_min4 = std.ArrayList(u32){};
        defer new_min4.deinit(alloc);

        // Remaining (non-promoted) entries are collected here, then repartitioned
        // as a single batch (§6.2 step 5) to avoid producing many tiny pages.
        var remaining = std.ArrayList(KvEntry){};
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
                    if (cur_id) |id| { if (self.heap.nodePagePtr(id)) |ptr| { cn = ptr.*; } }
                    var sst = std.mem.zeroes(SstPage);
                    sst.count = @intCast(chunk.len);
                    @memcpy(sst.entries[0..chunk.len], chunk);
                    const sid = try self.heap.writeSstPage(sst);
                    if (cn.sorted_count < S_MAX) {
                        cn.sorted_slot_ids[cn.sorted_count] = sid;
                        cn.sorted_min4[cn.sorted_count] = prefix32(&chunk[0].key, child_depth);
                        cn.sorted_count += 1;
                        const ncid = try self.heap.writeNodePage(cn);
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

        // Repartition all remaining (non-promoted) entries into full pages.
        var off: usize = 0;
        while (off < remaining.items.len) {
            const end = @min(off + PAGE_ENTRIES, remaining.items.len);
            const chunk = remaining.items[off..end];
            var sst = std.mem.zeroes(SstPage);
            sst.count = @intCast(chunk.len);
            @memcpy(sst.entries[0..chunk.len], chunk);
            const sid = try self.heap.writeSstPage(sst);
            try new_ids.append(alloc, sid);
            try new_min4.append(alloc, prefix32(&chunk[0].key, depth));
            off = end;
        }

        var new_node = std.mem.zeroes(NodePage);
        new_node.sorted_count = @intCast(new_ids.items.len);
        new_node.append_count = old_node.append_count;
        new_node.child_commitments = old_node.child_commitments;
        @memcpy(new_node.sorted_slot_ids[0..new_ids.items.len], new_ids.items);
        @memcpy(new_node.sorted_min4[0..new_min4.items.len], new_min4.items);
        for (0..old_node.append_count) |ai| {
            new_node.append_slot_ids[ai] = old_node.append_slot_ids[ai];
            new_node.append_prefix16[ai] = old_node.append_prefix16[ai];
        }

        const new_node_id = try self.heap.writeNodePage(new_node);
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
        const child = self.heap.nodePagePtr(child_id) orelse return;
        const old_child = child.*;
        const parent_id = self.routing.get(parent_depth, parent_prefix) orelse return;
        const parent_ptr = self.heap.nodePagePtr(parent_id) orelse return;
        const old_parent = parent_ptr.*;

        // Build merged map: parent entries first, child entries override (authoritative).
        var merged = std.AutoHashMap(Key, Value).init(alloc);
        defer merged.deinit();
        for (old_parent.sorted_slot_ids[0..old_parent.sorted_count]) |id| {
            if (self.heap.sstPagePtr(id)) |sst|
                for (sst.entries[0..sst.count]) |e| try merged.put(e.key, e.value);
        }
        for (old_child.sorted_slot_ids[0..old_child.sorted_count]) |id| {
            if (self.heap.sstPagePtr(id)) |sst|
                for (sst.entries[0..sst.count]) |e| try merged.put(e.key, e.value);
        }
        for (old_child.append_slot_ids[0..old_child.append_count]) |id| {
            if (self.heap.sstPagePtr(id)) |sst|
                for (sst.entries[0..sst.count]) |e| try merged.put(e.key, e.value);
        }

        var survivors = std.ArrayList(KvEntry){};
        defer survivors.deinit(alloc);
        var mit = merged.iterator();
        while (mit.next()) |kv| try survivors.append(alloc, .{ .key = kv.key_ptr.*, .value = kv.value_ptr.* });
        std.mem.sort(KvEntry, survivors.items, {}, kvLessThan);

        const pages_needed = (survivors.items.len + PAGE_ENTRIES - 1) / PAGE_ENTRIES;
        if (pages_needed > S_MAX) return; // parent has no capacity; skip

        var new_ids = std.ArrayList(PayloadSlotId){};
        defer new_ids.deinit(alloc);
        var new_min4 = std.ArrayList(u32){};
        defer new_min4.deinit(alloc);

        var offset: usize = 0;
        while (offset < survivors.items.len) {
            const end = @min(offset + PAGE_ENTRIES, survivors.items.len);
            const chunk = survivors.items[offset..end];
            var sst = std.mem.zeroes(SstPage);
            sst.count = @intCast(chunk.len);
            @memcpy(sst.entries[0..chunk.len], chunk);
            const sid = try self.heap.writeSstPage(sst);
            try new_ids.append(alloc, sid);
            try new_min4.append(alloc, prefix32(&chunk[0].key, parent_depth));
            offset = end;
        }

        // CoW parent.
        var new_parent = std.mem.zeroes(NodePage);
        new_parent.sorted_count = @intCast(new_ids.items.len);
        new_parent.append_count = old_parent.append_count;
        new_parent.child_commitments = old_parent.child_commitments;
        @memcpy(new_parent.sorted_slot_ids[0..new_ids.items.len], new_ids.items);
        @memcpy(new_parent.sorted_min4[0..new_min4.items.len], new_min4.items);
        for (0..old_parent.append_count) |ai| {
            new_parent.append_slot_ids[ai] = old_parent.append_slot_ids[ai];
            new_parent.append_prefix16[ai] = old_parent.append_prefix16[ai];
        }
        const new_parent_id = try self.heap.writeNodePage(new_parent);
        try self.routing.put(parent_depth, parent_prefix, new_parent_id);
        self.heap.freeNodePage(parent_id);
        for (old_parent.sorted_slot_ids[0..old_parent.sorted_count]) |id| self.heap.freeSstPage(id);

        // Delete child.
        _ = self.routing.remove(depth, prefix);
        self.heap.freeNodePage(child_id);
        for (old_child.sorted_slot_ids[0..old_child.sorted_count]) |id| self.heap.freeSstPage(id);
        for (old_child.append_slot_ids[0..old_child.append_count]) |id| self.heap.freeSstPage(id);

        if (parent_depth > 1 and self.countNodeEntries(parent_depth, parent_prefix) < MERGE_THRESHOLD)
            self.compaction_queue.append(alloc, .{ .depth = parent_depth, .prefix = parent_prefix }) catch {};
    }
};

// ─── Prefix helpers (§4.2.1, §7.1) ───────────────────────────────────────────

/// prefixData(K, d) = top 6d bits of K, zero-padded into a u32.
/// Used as the routing table key at depth d.
pub fn prefixData(key: *const Key, depth: u32) PrefixData {
    const top4: u32 = (@as(u32, key[0]) << 24) | (@as(u32, key[1]) << 16) |
        (@as(u32, key[2]) << 8) | @as(u32, key[3]);
    const shift: u5 = @intCast(32 - STRIDE * depth);
    return top4 >> shift;
}

/// prefix32(K, k): the 32 bits of K immediately following the node's 6k-bit
/// prefix, packed into a u32.  Used as the binary-search key in sorted_min4.
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

/// prefix16(K, k): the 16 bits of K immediately following the node's 6k-bit
/// prefix, packed into a u16.  Used to build and query append_prefix16 filters.
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

/// Binary search `sst.entries[0..sst.count]` for `key`; return its value or null.
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

/// Return true if `target` appears in the sorted 64-slot prefix16 filter.
fn filterContains(filter: *const [PAGE_ENTRIES]u16, target: u16) bool {
    var lo: usize = 0;
    var hi: usize = PAGE_ENTRIES;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (filter[mid] == target) return true;
        if (filter[mid] < target) lo = mid + 1 else hi = mid;
    }
    return false;
}

// ─── Tests ────────────────────────────────────────────────────────────────────

// Pull sub-module tests into the test binary.
test {
    _ = @import("page_store.zig");
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
    // FC FF FF FF 00 → raw64=0xFC_FF_FF_FF_00, shift=2 → 0x3FFF_FFC0
    const key = [_]u8{ 0xFC, 0xFF, 0xFF, 0xFF, 0x00 } ++ [_]u8{0} ** 27;
    try std.testing.expectEqual(@as(u32, 0x3FFF_FFC0), prefix32(&key, 1));
}

test "prefix32 depth 4 — bit_in_byte = 0" {
    // depth=4 → bit_offset=24, shift=8 → key[3..6]
    const key = [_]u8{0} ** 3 ++ [_]u8{ 0xAA, 0xBB, 0xCC, 0xDD, 0xEE } ++ [_]u8{0} ** 24;
    try std.testing.expectEqual(@as(u32, 0xAABB_CCDD), prefix32(&key, 4));
}

test "prefix16 depth 1 — bits [6,22) of key" {
    // FC 00 F0 → raw=0xFC_00_F0, shift=2 → 0x003C
    const key = [_]u8{ 0xFC, 0x00, 0xF0 } ++ [_]u8{0} ** 29;
    try std.testing.expectEqual(@as(u16, 0x003C), prefix16(&key, 1));
}

test "prefix16 depth 4 — bit_in_byte = 0" {
    // depth=4 → shift=8 → key[3]<<8 | key[4]
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
    var heap = try Heap.init(std.testing.allocator, 8, 32);
    defer heap.deinit();
    var page = std.mem.zeroes(NodePage);
    page.sorted_count = 2;
    page.append_count = 1;
    const id = try heap.writeNodePage(page);
    const p = heap.nodePagePtr(id).?;
    try std.testing.expectEqual(@as(u8, 2), p.sorted_count);
    try std.testing.expectEqual(@as(u8, 1), p.append_count);
    heap.freeNodePage(id);
    try std.testing.expectEqual(@as(?*NodePage, null), heap.nodePagePtr(id));
}

// ─── Write / Read operation tests ─────────────────────────────────────────────

/// Make a key in prefix group 0 (top 6 bits = 0) that is unique by `index`.
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
    try std.testing.expectEqual(@as(?Value, null), db.read(testKey(7)));
}

test "write then read from L0" {
    var db = try PrefixDB.init(std.testing.allocator);
    defer db.deinit();
    try db.write(testKey(1), testVal(0xAA));
    try std.testing.expectEqual(@as(?Value, testVal(0xAA)), db.read(testKey(1)));
}

test "L0 overwrite — most recent value returned" {
    var db = try PrefixDB.init(std.testing.allocator);
    defer db.deinit();
    try db.write(testKey(5), testVal(0x11));
    try db.write(testKey(5), testVal(0x22));
    try db.write(testKey(5), testVal(0x33));
    try std.testing.expectEqual(@as(?Value, testVal(0x33)), db.read(testKey(5)));
}

test "write 64 keys triggers L0 flush to L1 append zone" {
    // 64 writes with the same 6-bit prefix (prefix group 0) fill L0 and trigger
    // a flush.  After the flush L0 is empty and the routing table has a depth-1
    // entry for the node.
    var db = try PrefixDB.init(std.testing.allocator);
    defer db.deinit();

    for (0..PAGE_ENTRIES) |i| {
        try db.write(testKey(@intCast(i)), testVal(@intCast(i)));
    }

    // L0 must be empty after the flush.
    try std.testing.expectEqual(@as(usize, 0), db.l0.entries.items.len);

    // Routing table must have exactly one entry at depth 1, prefix 0.
    try std.testing.expect(db.routing.get(1, 0) != null);

    // The node page must have 1 append-zone page and 0 sorted pages.
    const node_id = db.routing.get(1, 0).?;
    const node = db.heap.nodePagePtr(node_id).?;
    try std.testing.expectEqual(@as(u8, 0), node.sorted_count);
    try std.testing.expectEqual(@as(u8, 1), node.append_count);
}

test "read keys from L1 append zone after flush" {
    var db = try PrefixDB.init(std.testing.allocator);
    defer db.deinit();

    for (0..PAGE_ENTRIES) |i| {
        try db.write(testKey(@intCast(i)), testVal(@intCast(i)));
    }

    // All 64 keys must be readable from the append zone.
    for (0..PAGE_ENTRIES) |i| {
        const got = db.read(testKey(@intCast(i)));
        try std.testing.expectEqual(@as(?Value, testVal(@intCast(i))), got);
    }

    // A key that was never written must still return null.
    try std.testing.expectEqual(@as(?Value, null), db.read(testKey(0xFF)));
}

test "L0 value overrides L1 for the same key" {
    // Write key, flush it to L1, then overwrite in L0.  The L0 copy must win.
    var db = try PrefixDB.init(std.testing.allocator);
    defer db.deinit();

    // Write PAGE_ENTRIES keys to trigger flush.
    for (0..PAGE_ENTRIES) |i| {
        try db.write(testKey(@intCast(i)), testVal(0xAA));
    }
    // key[0] is now in L1 with value 0xAA.

    // Re-write key[0] in L0 with a new value.
    try db.write(testKey(0), testVal(0xBB));
    try std.testing.expectEqual(@as(?Value, testVal(0xBB)), db.read(testKey(0)));

    // All other keys are still readable from L1.
    for (1..PAGE_ENTRIES) |i| {
        try std.testing.expectEqual(@as(?Value, testVal(0xAA)), db.read(testKey(@intCast(i))));
    }
}

test "keys from a different prefix group remain in L0 after flush" {
    // Prefix group 1: keys starting with 0b000001xx (key[0] = 0x04..0x07).
    var db = try PrefixDB.init(std.testing.allocator);
    defer db.deinit();

    // One key in prefix group 1.
    var other_key = std.mem.zeroes(Key);
    other_key[0] = 0x04; // top 6 bits = 0b000001 = prefix 1
    try db.write(other_key, testVal(0xFF));

    // Fill prefix group 0 to trigger its flush.
    for (0..PAGE_ENTRIES) |i| {
        try db.write(testKey(@intCast(i)), testVal(@intCast(i)));
    }

    // Prefix 0 flushed; prefix 1 key must still be in L0.
    try std.testing.expectEqual(@as(usize, 1), db.l0.entries.items.len);
    try std.testing.expectEqual(@as(?Value, testVal(0xFF)), db.read(other_key));
}

test "two flushes: 128 distinct keys across two SST pages in append zone" {
    var db = try PrefixDB.initCapacity(std.testing.allocator, DEFAULT_NODE_CAP, 2048);
    defer db.deinit();

    // First 64 keys: indices 0..63.  Triggers first flush (page 0 in append zone).
    for (0..PAGE_ENTRIES) |i| {
        try db.write(testKey(@intCast(i)), testVal(@intCast(i)));
    }
    // Next 64 keys: indices 64..127 — same prefix group, triggers second flush.
    for (PAGE_ENTRIES..2 * PAGE_ENTRIES) |i| {
        // Spread into a second unique byte to stay in prefix group 0 and be distinct.
        var k = std.mem.zeroes(Key);
        k[30] = 1;
        k[31] = @intCast(i - PAGE_ENTRIES);
        try db.write(k, testVal(@intCast(i)));
    }

    const node_id = db.routing.get(1, 0).?;
    const node = db.heap.nodePagePtr(node_id).?;
    try std.testing.expectEqual(@as(u8, 2), node.append_count);

    // All 128 keys readable.
    for (0..PAGE_ENTRIES) |i| {
        try std.testing.expectEqual(@as(?Value, testVal(@intCast(i))), db.read(testKey(@intCast(i))));
    }
    for (PAGE_ENTRIES..2 * PAGE_ENTRIES) |i| {
        var k = std.mem.zeroes(Key);
        k[30] = 1;
        k[31] = @intCast(i - PAGE_ENTRIES);
        try std.testing.expectEqual(@as(?Value, testVal(@intCast(i))), db.read(k));
    }
}

/// Key in prefix group 0, differentiated by `batch` (byte 1) and `index` (byte 2).
/// Using early bytes ensures prefix32/prefix16 values are distinct across batches,
/// which satisfies the sorted_min4 strictly-increasing invariant after promotion.
fn testKeyBatch(batch: u8, index: u8) Key {
    var k = std.mem.zeroes(Key);
    k[1] = batch;
    k[2] = index;
    return k;
}

test "deduplication in L0 flush — only latest value persisted" {
    var db = try PrefixDB.init(std.testing.allocator);
    defer db.deinit();

    // Write key 0 first with value 0x11, then fill the rest to trigger flush.
    try db.write(testKey(0), testVal(0x11));
    for (1..PAGE_ENTRIES) |i| {
        try db.write(testKey(@intCast(i)), testVal(@intCast(i)));
    }
    // key 0 has been seen once (value 0x11). Flush happens at exactly 64 raw entries.
    // value should be 0x11.
    try std.testing.expectEqual(@as(?Value, testVal(0x11)), db.read(testKey(0)));

    // Now write key 0 again (goes to L0).
    try db.write(testKey(0), testVal(0x22));
    try std.testing.expectEqual(@as(?Value, testVal(0x22)), db.read(testKey(0)));
}

// ─── Compaction tests ─────────────────────────────────────────────────────────

test "appendToSortedMerge: clears append zone and keeps all keys readable" {
    // 8 flushes × 64 keys = 512 unique keys fills the append zone to A_MAX.
    var db = try PrefixDB.initCapacity(std.testing.allocator, 512, 4096);
    defer db.deinit();

    for (0..A_MAX) |batch| {
        for (0..PAGE_ENTRIES) |i| {
            try db.write(testKeyBatch(@intCast(batch), @intCast(i)), testVal(@intCast(i)));
        }
    }

    const before_id = db.routing.get(1, 0).?;
    const before = db.heap.nodePagePtr(before_id).?;
    try std.testing.expectEqual(@as(u8, A_MAX), before.append_count);
    try std.testing.expect(db.compaction_queue.items.len > 0);

    try db.runCompaction();

    const after_id = db.routing.get(1, 0).?;
    const after = db.heap.nodePagePtr(after_id).?;
    try std.testing.expectEqual(@as(u8, 0), after.append_count);
    // All pages may have been promoted to depth-2 (all keys share sub-prefix 0).
    // The merge is successful if the append zone is clear and all keys are readable.

    for (0..A_MAX) |batch| {
        for (0..PAGE_ENTRIES) |i| {
            const got = db.read(testKeyBatch(@intCast(batch), @intCast(i)));
            try std.testing.expectEqual(@as(?Value, testVal(@intCast(i))), got);
        }
    }
}

test "appendToSortedMerge: newest value wins when same key appears in multiple append pages" {
    var db = try PrefixDB.initCapacity(std.testing.allocator, 512, 4096);
    defer db.deinit();

    // Write key(0,0) with value 0x11 in the first batch.
    try db.write(testKeyBatch(0, 0), testVal(0x11));
    for (1..PAGE_ENTRIES) |i| {
        try db.write(testKeyBatch(0, @intCast(i)), testVal(@intCast(i)));
    }
    // key(0,0) → value 0x11 is now in L1 append page 0.

    // Fill 7 more batches so append zone reaches A_MAX; overwrite key(0,0) in batch 4.
    for (1..A_MAX) |batch| {
        const use_val: u8 = if (batch == 4) 0x99 else @intCast(batch);
        try db.write(testKeyBatch(0, 0), testVal(use_val)); // key(0,0) overwritten
        for (1..PAGE_ENTRIES) |i| {
            try db.write(testKeyBatch(@intCast(batch), @intCast(i)), testVal(@intCast(i)));
        }
    }

    try db.runCompaction();

    // After compaction, key(0,0) must have the value from the last overwrite (batch 7 → 0x07).
    const got = db.read(testKeyBatch(0, 0));
    try std.testing.expectEqual(@as(?Value, testVal(A_MAX - 1)), got);
}

test "sub-prefix promotion: uniform sub-prefix page moves to depth-2 node" {
    // testKeyBatch(b, i) keys have k[0]=0, k[1]=0 → depth-1 prefix=0, depth-2 prefix=0.
    // A full page of 64 such keys passes the (prefix16>>10)==(prefix16>>10) check and
    // is promoted to the depth-2 node during appendToSortedMerge.
    var db = try PrefixDB.initCapacity(std.testing.allocator, 512, 4096);
    defer db.deinit();

    for (0..A_MAX) |batch| {
        for (0..PAGE_ENTRIES) |i| {
            try db.write(testKeyBatch(@intCast(batch), @intCast(i)), testVal(@intCast(i)));
        }
    }

    try db.runCompaction();

    // At least one page should have been promoted: depth-2 routing has an entry.
    var found_depth2 = false;
    for (0..64) |p| {
        if (db.routing.get(2, @intCast(p)) != null) {
            found_depth2 = true;
            break;
        }
    }
    try std.testing.expect(found_depth2);

    // All keys remain readable regardless of which zone holds them.
    for (0..A_MAX) |batch| {
        for (0..PAGE_ENTRIES) |i| {
            const got = db.read(testKeyBatch(@intCast(batch), @intCast(i)));
            try std.testing.expectEqual(@as(?Value, testVal(@intCast(i))), got);
        }
    }
}

test "upwardSplit: promoted depth-2 node triggers split when sorted zone fills" {
    // Force S_MAX sorted pages into a depth-2 node by promoting many depth-1 pages,
    // then verify the node triggers an upward split (routing entry at depth-3 or fewer
    // sorted pages at depth-2).
    // Use large pool capacities; S_MAX=123 sorted pages × 64 entries = 7872 entries.
    var db = try PrefixDB.initCapacity(std.testing.allocator, 4096, 32768);
    defer db.deinit();

    // Write S_MAX * A_MAX * PAGE_ENTRIES entries — but that is enormous.
    // Instead, manually inject a depth-2 node with sorted_count = S_MAX and queue it.
    var node2 = std.mem.zeroes(NodePage);
    for (0..S_MAX) |si| {
        var sst = std.mem.zeroes(SstPage);
        sst.count = 1;
        // Use keys with depth-2 prefix=0 but distinct byte 31 offsets.
        sst.entries[0].key[31] = @intCast(si);
        sst.entries[0].value = testVal(@intCast(si));
        const sid = try db.heap.writeSstPage(sst);
        node2.sorted_slot_ids[si] = sid;
        node2.sorted_min4[si] = prefix32(&sst.entries[0].key, 2);
        node2.sorted_count += 1;
    }
    const nid2 = try db.heap.writeNodePage(node2);
    try db.routing.put(2, 0, nid2);

    // Queue and run compaction — should trigger upward split.
    try db.compaction_queue.append(db.allocator, .{ .depth = 2, .prefix = 0 });
    try db.runCompaction();

    // All 123 entries share depth-3 prefix=0 (keys differ only at byte 31, beyond
    // the 18-bit depth-3 prefix window).  So the group size = 123 >= 64 and ALL
    // entries are promoted to depth-3.  Depth-2 sorted_count drops to 0.
    if (db.routing.get(2, 0)) |id| {
        const n = db.heap.nodePagePtr(id).?;
        try std.testing.expectEqual(@as(u8, 0), n.sorted_count);
    }
    // Depth-3 must have ceil(123/64) = 2 pages.
    const d3id = db.routing.get(3, 0).?;
    const d3n = db.heap.nodePagePtr(d3id).?;
    try std.testing.expectEqual(@as(u8, 2), d3n.sorted_count);
}

test "downwardMerge: sparse child node is absorbed into parent" {
    var db = try PrefixDB.initCapacity(std.testing.allocator, 512, 4096);
    defer db.deinit();

    // Manually create a sparse depth-2 node (< MERGE_THRESHOLD = 16 entries).
    const child_prefix: PrefixData = 0; // depth-2 prefix 0
    var child_node = std.mem.zeroes(NodePage);
    var sst = std.mem.zeroes(SstPage);
    sst.count = 5; // 5 entries < MERGE_THRESHOLD
    for (0..5) |idx| {
        sst.entries[idx].key[31] = @intCast(idx + 200); // distinct values
        sst.entries[idx].value = testVal(@intCast(idx + 200));
    }
    const csst_id = try db.heap.writeSstPage(sst);
    child_node.sorted_slot_ids[0] = csst_id;
    child_node.sorted_min4[0] = prefix32(&sst.entries[0].key, 2);
    child_node.sorted_count = 1;
    const cid = try db.heap.writeNodePage(child_node);
    try db.routing.put(2, child_prefix, cid);

    // Manually create parent depth-1 node with a few entries.
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
    parent_node.sorted_count = 1;
    const pid = try db.heap.writeNodePage(parent_node);
    try db.routing.put(1, 0, pid);

    // Queue the sparse child for downward merge and run.
    try db.compaction_queue.append(db.allocator, .{ .depth = 2, .prefix = child_prefix });
    try db.runCompaction();

    // Child node must be removed from routing.
    try std.testing.expectEqual(@as(?NodePageId, null), db.routing.get(2, child_prefix));

    // All 8 entries (3 parent + 5 child) must be in the parent's sorted zone.
    const new_pid = db.routing.get(1, 0).?;
    const new_parent = db.heap.nodePagePtr(new_pid).?;
    var total: u32 = 0;
    for (new_parent.sorted_slot_ids[0..new_parent.sorted_count]) |id| {
        total += db.heap.sstPagePtr(id).?.count;
    }
    try std.testing.expectEqual(@as(u32, 8), total);
}
