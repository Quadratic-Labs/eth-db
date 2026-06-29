//! KvMap: O(1) hot-key cache for recently-written and recently-read state entries.
//!
//! Phase 6: every PrefixDB.write() inserts the key so KvMap always reflects the
//! most recent written value.  PrefixDB.read() checks KvMap after L0 but before
//! the SST tree walk.
//!
//! Phase 7: PrefixDB.read() also inserts a key into KvMap after finding it in an
//! SST page (cold-key warming).  Each entry records its source SST page ID so
//! the LRU-eviction callback can remove exactly the entries that came from an
//! evicted page, keeping KvMap memory bounded.
//!
//! Versioning rules:
//!   WRITE_SST_ID (u32.max) — written by write(); always beats any SST-sourced entry.
//!   putFromSst(key, val, id) — updates only when id > existing sst_id (newer page wins).
//!   removeIfFromSst(key, id) — removes only when the stored sst_id matches (prevents
//!                               removing an entry that was since overwritten by write()
//!                               or a newer SST page).

const std = @import("std");
const t = @import("types.zig");

/// SST page ID used for entries inserted by write().
/// Being u32.max, it always compares greater than any real page ID.
pub const WRITE_SST_ID: u32 = std.math.maxInt(u32);

const Entry = struct {
    value: t.Value,
    sst_id: u32,
};

pub const KvMap = struct {
    map: std.AutoHashMap(t.Key, Entry),

    pub fn init(allocator: std.mem.Allocator) KvMap {
        return .{ .map = std.AutoHashMap(t.Key, Entry).init(allocator) };
    }

    pub fn deinit(self: *KvMap) void {
        self.map.deinit();
    }

    /// Hard cap on cached entries.  KvMap is a pure read cache (reads fall
    /// back to the SST walk), but write-sourced entries are only evicted with
    /// their source page — which for writes is never — so without a cap it
    /// grows with every key ever written.  Reset wholesale when full.
    pub const MAX_ENTRIES: u32 = 1 << 20;

    /// Insert or overwrite key → value (write-sourced; always newest).
    /// On OOM the key is removed to prevent stale reads.
    pub fn put(self: *KvMap, key: t.Key, value: t.Value) void {
        if (self.map.count() >= MAX_ENTRIES) self.map.clearRetainingCapacity();
        self.map.put(key, .{ .value = value, .sst_id = WRITE_SST_ID }) catch {
            _ = self.map.remove(key);
        };
    }

    /// Insert key → value sourced from SST page `sst_id`.
    /// Updates an existing entry only when `sst_id` is strictly greater than
    /// the stored sst_id (higher ID = more recently created page).
    /// WRITE_SST_ID entries are never overwritten.
    pub fn putFromSst(self: *KvMap, key: t.Key, value: t.Value, sst_id: u32) void {
        if (self.map.getPtr(key)) |e| {
            if (sst_id > e.sst_id) {
                e.value = value;
                e.sst_id = sst_id;
            }
            return;
        }
        self.map.put(key, .{ .value = value, .sst_id = sst_id }) catch {};
    }

    /// Remove key only if its stored sst_id matches `sst_id`.
    /// Used by the SST eviction callback: a key re-inserted via write() or a newer
    /// SST page will have a different (larger) sst_id and is left untouched.
    pub fn removeIfFromSst(self: *KvMap, key: t.Key, sst_id: u32) void {
        const e = self.map.get(key) orelse return;
        if (e.sst_id == sst_id) _ = self.map.remove(key);
    }

    /// Look up a key.  Returns null if the key is not cached.
    pub fn get(self: *const KvMap, key: t.Key) ?t.Value {
        return if (self.map.get(key)) |e| e.value else null;
    }

    /// Remove a key unconditionally.  No-op if absent.
    pub fn remove(self: *KvMap, key: t.Key) void {
        _ = self.map.remove(key);
    }

    /// Number of entries currently cached.
    pub fn count(self: *const KvMap) usize {
        return self.map.count();
    }
};

// ─── Tests ────────────────────────────────────────────────────────────────────

test "KvMap: put and get" {
    var m = KvMap.init(std.testing.allocator);
    defer m.deinit();

    var key = std.mem.zeroes(t.Key);
    key[31] = 1;
    var val = std.mem.zeroes(t.Value);
    val[0] = 0xAB;

    try std.testing.expectEqual(@as(?t.Value, null), m.get(key));
    m.put(key, val);
    try std.testing.expectEqual(@as(?t.Value, val), m.get(key));
}

test "KvMap: overwrite returns latest value" {
    var m = KvMap.init(std.testing.allocator);
    defer m.deinit();

    var key = std.mem.zeroes(t.Key);
    key[31] = 2;
    var v1 = std.mem.zeroes(t.Value);
    v1[0] = 0x11;
    var v2 = std.mem.zeroes(t.Value);
    v2[0] = 0x22;

    m.put(key, v1);
    m.put(key, v2);
    try std.testing.expectEqual(@as(?t.Value, v2), m.get(key));
}

test "KvMap: remove clears entry" {
    var m = KvMap.init(std.testing.allocator);
    defer m.deinit();

    var key = std.mem.zeroes(t.Key);
    key[31] = 3;
    var val = std.mem.zeroes(t.Value);
    val[0] = 0xCC;

    m.put(key, val);
    m.remove(key);
    try std.testing.expectEqual(@as(?t.Value, null), m.get(key));
}

test "KvMap: count tracks entries" {
    var m = KvMap.init(std.testing.allocator);
    defer m.deinit();

    var k1 = std.mem.zeroes(t.Key);
    k1[31] = 1;
    var k2 = std.mem.zeroes(t.Key);
    k2[31] = 2;
    const v = std.mem.zeroes(t.Value);

    try std.testing.expectEqual(@as(usize, 0), m.count());
    m.put(k1, v);
    try std.testing.expectEqual(@as(usize, 1), m.count());
    m.put(k2, v);
    try std.testing.expectEqual(@as(usize, 2), m.count());
    m.put(k1, v); // overwrite — count stays 2
    try std.testing.expectEqual(@as(usize, 2), m.count());
    m.remove(k1);
    try std.testing.expectEqual(@as(usize, 1), m.count());
}

test "KvMap: putFromSst: newer sst_id wins" {
    var m = KvMap.init(std.testing.allocator);
    defer m.deinit();

    var key = std.mem.zeroes(t.Key);
    key[31] = 10;
    var v_old = std.mem.zeroes(t.Value);
    v_old[0] = 0x01;
    var v_new = std.mem.zeroes(t.Value);
    v_new[0] = 0x02;

    m.putFromSst(key, v_old, 5);
    try std.testing.expectEqual(@as(?t.Value, v_old), m.get(key));

    // Same ID: no change.
    m.putFromSst(key, v_new, 5);
    try std.testing.expectEqual(@as(?t.Value, v_old), m.get(key));

    // Older ID: no change.
    m.putFromSst(key, v_new, 3);
    try std.testing.expectEqual(@as(?t.Value, v_old), m.get(key));

    // Newer ID: update.
    m.putFromSst(key, v_new, 10);
    try std.testing.expectEqual(@as(?t.Value, v_new), m.get(key));
}

test "KvMap: write() beats putFromSst" {
    var m = KvMap.init(std.testing.allocator);
    defer m.deinit();

    var key = std.mem.zeroes(t.Key);
    key[31] = 11;
    var v_write = std.mem.zeroes(t.Value);
    v_write[0] = 0xAA;
    var v_sst = std.mem.zeroes(t.Value);
    v_sst[0] = 0xBB;

    m.put(key, v_write);
    // Any real sst_id < WRITE_SST_ID, so putFromSst must not overwrite.
    m.putFromSst(key, v_sst, WRITE_SST_ID - 1);
    try std.testing.expectEqual(@as(?t.Value, v_write), m.get(key));
}

test "KvMap: removeIfFromSst: only removes matching sst_id" {
    var m = KvMap.init(std.testing.allocator);
    defer m.deinit();

    var key = std.mem.zeroes(t.Key);
    key[31] = 12;
    var val = std.mem.zeroes(t.Value);
    val[0] = 0x55;

    m.putFromSst(key, val, 7);

    // Wrong sst_id: no removal.
    m.removeIfFromSst(key, 8);
    try std.testing.expectEqual(@as(?t.Value, val), m.get(key));

    // Correct sst_id: removed.
    m.removeIfFromSst(key, 7);
    try std.testing.expectEqual(@as(?t.Value, null), m.get(key));
}

test "KvMap: removeIfFromSst does not remove write()-sourced entry" {
    var m = KvMap.init(std.testing.allocator);
    defer m.deinit();

    var key = std.mem.zeroes(t.Key);
    key[31] = 13;
    var val = std.mem.zeroes(t.Value);
    val[0] = 0xFF;

    m.put(key, val); // WRITE_SST_ID
    m.removeIfFromSst(key, 42); // real sst_id ≠ WRITE_SST_ID → no removal
    try std.testing.expectEqual(@as(?t.Value, val), m.get(key));
}
