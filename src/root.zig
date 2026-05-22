//! PrefixDB in-memory engine model.
//!
//! Core data types and constants live in types.zig; this module holds the
//! engine structs (RoutingTable, L0Buffer, Pool, Heap, PrefixDB) and the
//! prefix-helper functions.  page_store.zig imports types.zig directly,
//! keeping the dependency graph acyclic.

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
    // key[0]=0b11111100, key[1..4]=0xFF, key[4]=0b00000000
    // bits 6..37: 00_11111111_11111111_11111111_00 = 0x00FF_FFFC shifted...
    // Expected: prefix32 should extract 32 bits starting at bit 6.
    // key bytes: FC FF FF FF 00 ...
    //   bit 6 = 0, bit 7 = 0
    //   bits 8-31 = all 1s (from 3 × 0xFF bytes)
    //   bits 32-37 = 000000 (from 0x00)
    // prefix32 = 0b00_11111111_11111111_11111111_000000 packed as u32:
    //          = 0b0011_1111_1111_1111_1111_1111_0000_00 ... wait that's 30 bits
    // Let me just compute: bits [6,38) of FC FF FF FF 00:
    //   byte0=FC=11111100, byte1=FF, byte2=FF, byte3=FF, byte4=00
    //   raw64 = (0xFC<<32)|(0xFF<<24)|(0xFF<<16)|(0xFF<<8)|0x00 = 0xFC_FF_FF_FF_00
    //   shift = 8 - (6%8) = 2
    //   raw64 >> 2 = 0x3F_3F_FF_FF_C0 (roughly)
    //   & 0xFFFF_FFFF = 0x3F_FF_FF_C0
    // Let me compute properly:
    //   0xFC_FF_FF_FF_00 = 1111_1100 1111_1111 1111_1111 1111_1111 0000_0000
    //   >> 2            = 0011_1111 0011_1111 1111_1111 1111_1111 1100_0000
    //   lower 32 bits   = 0011_1111 1111_1111 1111_1111 1100_0000
    //                   = 0x3FFF_FFC0
    const key = [_]u8{ 0xFC, 0xFF, 0xFF, 0xFF, 0x00 } ++ [_]u8{0} ** 27;
    try std.testing.expectEqual(@as(u32, 0x3FFF_FFC0), prefix32(&key, 1));
}

test "prefix32 depth 4 — bit_in_byte = 0" {
    // depth=4 → bit_offset=24, byte0=3, bit_in_byte=0, shift=8
    // raw64 = (key[3]<<32)|(key[4]<<24)|(key[5]<<16)|(key[6]<<8)|key[7]
    // shift=8 → raw64>>8 & 0xFFFF_FFFF = key[3]<<24|key[4]<<16|key[5]<<8|key[6]
    const key = [_]u8{0} ** 3 ++ [_]u8{ 0xAA, 0xBB, 0xCC, 0xDD, 0xEE } ++ [_]u8{0} ** 24;
    try std.testing.expectEqual(@as(u32, 0xAABB_CCDD), prefix32(&key, 4));
}

test "prefix16 depth 1 — bits [6,22) of key" {
    // depth=1 → bit_offset=6, byte0=0, bit_in_byte=6, shift=2
    // raw = (key[0]<<16)|(key[1]<<8)|key[2]
    // key = FC 00 F0 → raw = 0xFC_00_F0
    // >> 2 = 0x3F_00_3C; & 0xFFFF = 0x003C
    const key = [_]u8{ 0xFC, 0x00, 0xF0 } ++ [_]u8{0} ** 29;
    try std.testing.expectEqual(@as(u16, 0x003C), prefix16(&key, 1));
}

test "prefix16 depth 4 — bit_in_byte = 0" {
    // depth=4 → bit_offset=24, byte0=3, bit_in_byte=0, shift=8
    // raw = (key[3]<<16)|(key[4]<<8)|key[5]; >>8 = key[3]<<8|key[4]
    const key = [_]u8{0} ** 3 ++ [_]u8{ 0xAB, 0xCD, 0xFF } ++ [_]u8{0} ** 26;
    try std.testing.expectEqual(@as(u16, 0xABCD), prefix16(&key, 4));
}

test "prefix16 sub-prefix promotion check — top 6 bits" {
    // §6.1 step 6: if (prefix16_sorted[0] >> 10) == (prefix16_sorted[63] >> 10)
    // then all 64 entries share the same 6-bit sub-prefix.
    const uniform_low: u16 = 0b0000_0100_0000_0000; // top 6 = 0b000001
    const uniform_high: u16 = 0b0000_0111_1111_1111; // top 6 = 0b000001
    const different: u16 = 0b0000_1000_0000_0000; // top 6 = 0b000010
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
