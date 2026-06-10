//! NodeArena: flat in-memory storage for depth-1, depth-2, and depth-3 node pages.
//!
//! Depths 1, 2, and 3 have at most 64, 4096, and 262144 nodes respectively
//! (STRIDE=6: 2^6=64, 2^12=4096, 2^18=262144).  All three fit entirely in RAM
//! and are cheaper to address by direct array indexing than by LRU-cache hashtable
//! lookup.
//!
//! Existence is tracked with compact bitmaps so scanning all live nodes costs
//! O(n/64) with @ctz-based loops.
//!
//! All page arrays and the d3 bitmap are heap-allocated to keep the struct
//! small by value: Debug builds materialise temporary copies of aggregates on
//! the stack, and an inline `[64]NodePage` (~256 KB) multiplied across the
//! init call chain overflows an 8 MB stack (e.g. when loaded via Python ctypes).

const std = @import("std");
const t = @import("types.zig");

pub const NodeArena = struct {
    // ─── Depth-1 (64 nodes, heap-allocated ~256 KB) ───────────────────────────
    d1_pages:  []t.NodePage,  // len = 64
    d1_exists: u64,           // bit i set ↔ d1_pages[i] is live

    // ─── Depth-2 (4096 nodes, heap-allocated ~16 MB) ──────────────────────────
    d2_pages:  []t.NodePage,  // len = 4096
    d2_exists: [64]u64,       // bit (w*64+b) set ↔ d2_pages[w*64+b] is live

    // ─── Depth-3 (262144 nodes, heap-allocated ~1 GB) ─────────────────────────
    d3_pages:  []t.NodePage,  // len = 262144
    d3_exists: []u64,         // len = 4096; bit (w*64+b) set ↔ d3_pages[w*64+b] is live

    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !NodeArena {
        const d1_pages = try allocator.alloc(t.NodePage, 64);
        errdefer allocator.free(d1_pages);
        const d2_pages = try allocator.alloc(t.NodePage, 4096);
        errdefer allocator.free(d2_pages);
        const d3_pages = try allocator.alloc(t.NodePage, 262144);
        errdefer allocator.free(d3_pages);
        const d3_exists = try allocator.alloc(u64, 4096);
        @memset(d3_exists, 0);
        return .{
            .d1_pages  = d1_pages,    // contents only accessed when d1_exists bit is set
            .d1_exists = 0,
            .d2_pages  = d2_pages,
            .d2_exists = [_]u64{0} ** 64,
            .d3_pages  = d3_pages,
            .d3_exists = d3_exists,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *NodeArena) void {
        self.allocator.free(self.d1_pages);
        self.allocator.free(self.d2_pages);
        self.allocator.free(self.d3_pages);
        self.allocator.free(self.d3_exists);
    }

    pub fn exists(self: *const NodeArena, depth: u32, prefix: t.PrefixData) bool {
        return switch (depth) {
            1 => (self.d1_exists >> @as(u6, @intCast(prefix))) & 1 != 0,
            2 => (self.d2_exists[@intCast(prefix >> 6)] >> @as(u6, @intCast(prefix & 63))) & 1 != 0,
            3 => (self.d3_exists[@intCast(prefix >> 6)] >> @as(u6, @intCast(prefix & 63))) & 1 != 0,
            else => unreachable,
        };
    }

    /// Return a const pointer to an existing node, or null if absent.
    pub fn get(self: *const NodeArena, depth: u32, prefix: t.PrefixData) ?*const t.NodePage {
        return switch (depth) {
            1 => if ((self.d1_exists >> @as(u6, @intCast(prefix))) & 1 != 0)
                     &self.d1_pages[@intCast(prefix)] else null,
            2 => if ((self.d2_exists[@intCast(prefix >> 6)] >> @as(u6, @intCast(prefix & 63))) & 1 != 0)
                     &self.d2_pages[@intCast(prefix)] else null,
            3 => if ((self.d3_exists[@intCast(prefix >> 6)] >> @as(u6, @intCast(prefix & 63))) & 1 != 0)
                     &self.d3_pages[@intCast(prefix)] else null,
            else => unreachable,
        };
    }

    /// Write `node` to the given slot, creating it if absent.
    pub fn put(self: *NodeArena, depth: u32, prefix: t.PrefixData, node: t.NodePage) void {
        switch (depth) {
            1 => {
                self.d1_pages[@intCast(prefix)] = node;
                self.d1_exists |= @as(u64, 1) << @as(u6, @intCast(prefix));
            },
            2 => {
                self.d2_pages[@intCast(prefix)] = node;
                self.d2_exists[@intCast(prefix >> 6)] |= @as(u64, 1) << @as(u6, @intCast(prefix & 63));
            },
            3 => {
                self.d3_pages[@intCast(prefix)] = node;
                self.d3_exists[@intCast(prefix >> 6)] |= @as(u64, 1) << @as(u6, @intCast(prefix & 63));
            },
            else => unreachable,
        }
    }

    /// Remove a node slot (e.g. after a downwardMerge absorbs it).
    pub fn remove(self: *NodeArena, depth: u32, prefix: t.PrefixData) void {
        switch (depth) {
            1 => self.d1_exists &= ~(@as(u64, 1) << @as(u6, @intCast(prefix))),
            2 => self.d2_exists[@intCast(prefix >> 6)] &= ~(@as(u64, 1) << @as(u6, @intCast(prefix & 63))),
            3 => self.d3_exists[@intCast(prefix >> 6)] &= ~(@as(u64, 1) << @as(u6, @intCast(prefix & 63))),
            else => unreachable,
        }
    }
};
