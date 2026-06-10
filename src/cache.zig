//! Generic LRU cache backed by a fixed-size entry array plus a hash map.
//!
//! Keys are u32 page IDs.  Values are stored by copy.
//! On `put` the least-recently-used entry is evicted when the backing array
//! is full.  `get` promotes the hit entry to the MRU end.
//!
//! The backing array is pre-allocated at `init` time; no further heap
//! allocation is performed by `get` or `remove`.  `put` may grow the
//! internal hash-map (OOM possible).
//!
//! Two optional callbacks allow callers to react to entries leaving the cache:
//!   lru_evict_fn — fired when LRU eviction occurs inside `put()` (cache full).
//!                  The last in-memory copy is about to be lost; callers should
//!                  persist the page to disk here.
//!   remove_fn    — fired when `remove()` is called explicitly (logical deletion).
//!                  The page is being superseded; callers should NOT write to disk
//!                  but may need to clean up secondary structures (e.g. kv_map).

const std = @import("std");

pub fn LruCache(comptime V: type) type {
    return struct {
        const Self = @This();
        const NONE: u32 = std.math.maxInt(u32);

        const Entry = struct {
            key: u32,
            value: V,
            /// Index toward the MRU end; NONE if this entry is the head.
            prev: u32,
            /// Index toward the LRU end; NONE if this entry is the tail.
            next: u32,
        };

        entries: []Entry,
        map: std.AutoHashMap(u32, u32), // page_id → entry-array index
        free_head: u32, // free-list head; NONE when all slots are live
        lru_head: u32, // most-recently-used end
        lru_tail: u32, // least-recently-used end (eviction target)
        len: u32,
        cap: u32,
        evict_ctx: ?*anyopaque = null,
        /// Fired on LRU eviction in `put()` — last in-memory copy is about to be lost.
        lru_evict_fn: ?*const fn (*anyopaque, u32, *const V) void = null,
        /// Fired on explicit `remove()` — page is superseded; do NOT write to disk.
        remove_fn: ?*const fn (*anyopaque, u32, *const V) void = null,

        pub fn init(allocator: std.mem.Allocator, cap: u32) !Self {
            const entries = try allocator.alloc(Entry, cap);
            for (0..cap) |i| {
                entries[i] = .{
                    .key = 0,
                    .value = undefined,
                    .prev = NONE,
                    .next = if (i + 1 < cap) @intCast(i + 1) else NONE,
                };
            }
            return .{
                .entries = entries,
                .map = std.AutoHashMap(u32, u32).init(allocator),
                .free_head = if (cap > 0) 0 else NONE,
                .lru_head = NONE,
                .lru_tail = NONE,
                .len = 0,
                .cap = cap,
            };
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            allocator.free(self.entries);
            self.map.deinit();
        }

        /// Return a copy of the cached value for `key`, promoting it to MRU.
        /// Returns null on a cache miss.
        pub fn get(self: *Self, key: u32) ?V {
            const idx = self.map.get(key) orelse return null;
            self.promoteToHead(idx);
            return self.entries[idx].value;
        }

        /// Insert or update `key → value`.
        /// When the cache is full, the LRU entry is evicted and `lru_evict_fn` is called.
        /// May return `error.OutOfMemory` from the internal hash map.
        pub fn put(self: *Self, key: u32, value: V) !void {
            if (self.map.get(key)) |idx| {
                self.entries[idx].value = value;
                self.promoteToHead(idx);
                return;
            }
            // Reserve map capacity before mutating the list so that OOM
            // cannot leave the structure in a partially-updated state.
            try self.map.ensureUnusedCapacity(1);

            const slot: u32 = if (self.free_head != NONE) blk: {
                const s = self.free_head;
                self.free_head = self.entries[s].next;
                self.len += 1;
                break :blk s;
            } else blk: {
                // Evict LRU tail; len stays the same.
                const s = self.lru_tail;
                if (self.lru_evict_fn) |f| f(self.evict_ctx.?, self.entries[s].key, &self.entries[s].value);
                _ = self.map.remove(self.entries[s].key);
                self.detach(s);
                break :blk s;
            };

            self.entries[slot] = .{ .key = key, .value = value, .prev = NONE, .next = NONE };
            self.map.putAssumeCapacity(key, slot);
            self.attachHead(slot);
        }

        /// Remove `key` from the cache, calling `remove_fn` if set. No-op if not present.
        pub fn remove(self: *Self, key: u32) void {
            const kv = self.map.fetchRemove(key) orelse return;
            const idx = kv.value;
            if (self.remove_fn) |f| f(self.evict_ctx.?, key, &self.entries[idx].value);
            self.detach(idx);
            self.entries[idx].next = self.free_head;
            self.free_head = idx;
            self.len -= 1;
        }

        /// Call `f(ctx, key, &value)` for every live entry, MRU→LRU order.
        /// Used at flush time to write all in-cache pages to disk.
        pub fn forEachLive(
            self: *const Self,
            ctx: *anyopaque,
            f: *const fn (*anyopaque, u32, *const V) anyerror!void,
        ) !void {
            var idx = self.lru_head;
            while (idx != NONE) {
                const e = &self.entries[idx];
                try f(ctx, e.key, &e.value);
                idx = e.next;
            }
        }

        fn promoteToHead(self: *Self, idx: u32) void {
            if (self.lru_head == idx) return;
            self.detach(idx);
            self.attachHead(idx);
        }

        fn attachHead(self: *Self, idx: u32) void {
            self.entries[idx].prev = NONE;
            self.entries[idx].next = self.lru_head;
            if (self.lru_head != NONE) self.entries[self.lru_head].prev = idx;
            self.lru_head = idx;
            if (self.lru_tail == NONE) self.lru_tail = idx;
        }

        fn detach(self: *Self, idx: u32) void {
            const p = self.entries[idx].prev;
            const n = self.entries[idx].next;
            if (p != NONE) self.entries[p].next = n else self.lru_head = n;
            if (n != NONE) self.entries[n].prev = p else self.lru_tail = p;
        }
    };
}

// ─── Tests ────────────────────────────────────────────────────────────────────

test "LruCache: basic get/put" {
    var cache = try LruCache(u32).init(std.testing.allocator, 3);
    defer cache.deinit(std.testing.allocator);

    try cache.put(1, 100);
    try cache.put(2, 200);
    try std.testing.expectEqual(@as(?u32, 100), cache.get(1));
    try std.testing.expectEqual(@as(?u32, 200), cache.get(2));
    try std.testing.expectEqual(@as(?u32, null), cache.get(99));
}

test "LruCache: evicts LRU entry when full" {
    var cache = try LruCache(u32).init(std.testing.allocator, 2);
    defer cache.deinit(std.testing.allocator);

    try cache.put(1, 10);
    try cache.put(2, 20);
    // get(1) promotes 1 to MRU; 2 becomes the LRU entry.
    _ = cache.get(1);
    // Inserting 3 must evict 2.
    try cache.put(3, 30);
    try std.testing.expectEqual(@as(?u32, 10), cache.get(1));
    try std.testing.expectEqual(@as(?u32, null), cache.get(2)); // evicted
    try std.testing.expectEqual(@as(?u32, 30), cache.get(3));
    try std.testing.expectEqual(@as(u32, 2), cache.len);
}

test "LruCache: update in-place promotes to MRU" {
    var cache = try LruCache(u32).init(std.testing.allocator, 2);
    defer cache.deinit(std.testing.allocator);

    try cache.put(1, 10);
    try cache.put(2, 20);
    // Updating 1 makes it MRU; 2 is now LRU.
    try cache.put(1, 11);
    try cache.put(3, 30); // evicts 2
    try std.testing.expectEqual(@as(?u32, 11), cache.get(1));
    try std.testing.expectEqual(@as(?u32, null), cache.get(2));
    try std.testing.expectEqual(@as(?u32, 30), cache.get(3));
}

test "LruCache: remove frees slot for reuse" {
    var cache = try LruCache(u32).init(std.testing.allocator, 3);
    defer cache.deinit(std.testing.allocator);

    try cache.put(1, 10);
    try cache.put(2, 20);
    cache.remove(1);
    try std.testing.expectEqual(@as(?u32, null), cache.get(1));
    try std.testing.expectEqual(@as(?u32, 20), cache.get(2));
    try std.testing.expectEqual(@as(u32, 1), cache.len);
    // Slot freed by remove should be reused.
    try cache.put(3, 30);
    try std.testing.expectEqual(@as(u32, 2), cache.len);
    try std.testing.expectEqual(@as(?u32, 30), cache.get(3));
}

test "LruCache: eviction order with multiple accesses" {
    var cache = try LruCache(u32).init(std.testing.allocator, 3);
    defer cache.deinit(std.testing.allocator);

    try cache.put(1, 10);
    try cache.put(2, 20);
    try cache.put(3, 30);
    // Access 1 and 2; 3 becomes LRU.
    _ = cache.get(1);
    _ = cache.get(2);
    try cache.put(4, 40); // evicts 3
    try std.testing.expectEqual(@as(?u32, null), cache.get(3));
    try std.testing.expectEqual(@as(?u32, 40), cache.get(4));
}
