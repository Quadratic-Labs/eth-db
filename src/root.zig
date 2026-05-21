//! PrefixDB in-memory engine model.
//!
//! Core data types and constants live in types.zig; this module holds the
//! engine structs (RoutingTable, L0Buffer, Pool, Heap, PrefixDB) and the
//! prefix-helper functions.  page_store.zig and combinadic.zig each import
//! types.zig directly, keeping the dependency graph acyclic.

const std = @import("std");

// ─── Re-export sub-modules ─────────────────────────────────────────────────────
pub const merkle = @import("merkle.zig");
pub const page_store = @import("page_store.zig");
pub const combinadic = @import("combinadic.zig");

// ─── Re-export shared types from types.zig ─────────────────────────────────────
const t = @import("types.zig");
pub const Hash = t.Hash;
pub const ZERO_HASH = t.ZERO_HASH;
pub const STRIDE = t.STRIDE;
pub const PAGE_ENTRIES = t.PAGE_ENTRIES;
pub const CHILD_COUNT = t.CHILD_COUNT;
pub const MAX_SST_PER_NODE = t.MAX_SST_PER_NODE;
pub const MAX_DEPTH = t.MAX_DEPTH;
pub const PREFIX12_UNIVERSE = t.PREFIX12_UNIVERSE;
pub const COMPACTION_TRIGGER = t.COMPACTION_TRIGGER;
pub const MERGE_THRESHOLD = t.MERGE_THRESHOLD;
pub const T_OPP = t.T_OPP;
pub const Key = t.Key;
pub const Value = t.Value;
pub const KvEntry = t.KvEntry;
pub const DecodedFingerprint = t.DecodedFingerprint;
pub const FINGERPRINT_NULL = t.FINGERPRINT_NULL;
pub const NULL_FINGERPRINT = t.NULL_FINGERPRINT;
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

pub const PrefixDB = struct {
    l0: L0Buffer,
    routing: RoutingTable,
    heap: Heap,
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
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *PrefixDB) void {
        self.l0.deinit();
        self.routing.deinit();
        self.heap.deinit();
    }
};

// ─── Prefix helpers (§4.2.1) ──────────────────────────────────────────────────

pub fn prefixData(key: *const Key, depth: u32) PrefixData {
    const top4: u32 = (@as(u32, key[0]) << 24) | (@as(u32, key[1]) << 16) |
        (@as(u32, key[2]) << 8) | @as(u32, key[3]);
    const shift: u5 = @intCast(32 - STRIDE * depth);
    return top4 >> shift;
}

pub fn relativePrefix12(key: *const Key, depth: u32) u16 {
    const bit_offset: u32 = STRIDE * depth;
    const byte0: usize = @intCast(bit_offset / 8);
    const bit_in_byte: u5 = @intCast(bit_offset % 8);
    const raw: u32 = (@as(u32, key[byte0]) << 16) |
        (@as(u32, key[byte0 + 1]) << 8) |
        @as(u32, key[byte0 + 2]);
    return @intCast((raw >> (12 - bit_in_byte)) & 0xFFF);
}

// ─── Tests ────────────────────────────────────────────────────────────────────

// Pull sub-module tests into the test binary.
test {
    _ = @import("page_store.zig");
    _ = @import("combinadic.zig");
}

test "prefixData depth 1 extracts top 6 bits" {
    const key = [_]u8{0b10110100} ++ [_]u8{0} ** 31;
    try std.testing.expectEqual(@as(PrefixData, 0b101101), prefixData(&key, 1));
}

test "prefixData depth 5 extracts top 30 bits" {
    const key = [_]u8{ 0xFF, 0xFF, 0xFF, 0xFF } ++ [_]u8{0} ** 28;
    try std.testing.expectEqual(@as(PrefixData, 0x3FFF_FFFF), prefixData(&key, 5));
}

test "relativePrefix12 depth 1" {
    const key = [_]u8{ 0b10110110, 0b00000000, 0 } ++ [_]u8{0} ** 29;
    try std.testing.expectEqual(@as(u16, 0b100000000000), relativePrefix12(&key, 1));
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
    page.sst_count = 2;
    const id = try heap.writeNodePage(page);
    const p = heap.nodePagePtr(id).?;
    try std.testing.expectEqual(@as(u8, 2), p.sst_count);
    heap.freeNodePage(id);
    try std.testing.expectEqual(@as(?*NodePage, null), heap.nodePagePtr(id));
}
