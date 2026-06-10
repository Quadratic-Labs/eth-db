//! BlockJournal: ring buffer of per-block KV diffs for chain-reorg support.
//!
//! REORG_WINDOW blocks' write histories are kept in a ring indexed by
//! block_num % REORG_WINDOW.  For each block the journal stores the pre-write
//! value of every key modified, so reorgTo() can undo those changes by writing
//! the old values back via db.write().
//!
//! Usage per block:
//!   journal.beginBlock(block_num);
//!   journal.recordWrite(key, old_value);   // before each db.write()
//!   try db.write(key, new_value);
//!   ...
//!   _ = try db.commitBlock();
//!   journal.endBlock(block_num);
//!
//! Reorg:
//!   try journal.reorgTo(target_block, &db);
//!   // process new-chain blocks normally: beginBlock / write / commitBlock / endBlock
//!
//! After each manifest flush:
//!   journal.evictOldBlocks(flushed_block_num);

const std = @import("std");
const t = @import("types.zig");
const PrefixDB = @import("root.zig").PrefixDB;

pub const REORG_WINDOW: u32 = 64;

pub const KvDiff = struct {
    key: t.Key,
    /// Pre-write value of the key.  null means the key was absent.
    old_value: ?t.Value,
};

const BlockSlot = struct {
    block_num: u32,
    diffs: std.ArrayList(KvDiff),
};

pub const BlockJournal = struct {
    ring: [REORG_WINDOW]?BlockSlot,
    /// Most recently committed block_num; null if the journal is empty.
    tip: ?u32,
    /// block_num currently being written (between beginBlock and endBlock).
    current: ?u32,
    /// First block_num still retained in the ring (not evicted by a flush).
    /// reorgTo returns error.ReorgWindowExceeded when target_block+1 < oldest_live.
    oldest_live: u32,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) BlockJournal {
        return .{
            .ring = [_]?BlockSlot{null} ** REORG_WINDOW,
            .tip = null,
            .current = null,
            .oldest_live = 0,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *BlockJournal) void {
        for (&self.ring) |*slot| {
            if (slot.*) |*s| {
                s.diffs.deinit(self.allocator);
                slot.* = null;
            }
        }
    }

    /// Begin recording writes for block_num.  Must be called before recordWrite.
    /// Evicts any stale ring entry at this block's slot.
    pub fn beginBlock(self: *BlockJournal, block_num: u32) void {
        self.current = block_num;
        const idx = block_num % REORG_WINDOW;
        if (self.ring[idx]) |*s| s.diffs.deinit(self.allocator);
        self.ring[idx] = .{ .block_num = block_num, .diffs = .empty };
    }

    /// Record the value of `key` before a write.
    /// old_value = null means the key was absent.  Call before db.write().
    pub fn recordWrite(self: *BlockJournal, key: t.Key, old_value: ?t.Value) !void {
        const bn = self.current orelse return;
        const idx = bn % REORG_WINDOW;
        if (self.ring[idx]) |*s| {
            if (s.block_num == bn) {
                try s.diffs.append(self.allocator, .{ .key = key, .old_value = old_value });
            }
        }
    }

    /// Finalize the current block entry.  Must be called after db.commitBlock().
    pub fn endBlock(self: *BlockJournal, block_num: u32) void {
        self.tip = block_num;
        self.current = null;
    }

    /// Undo all blocks after target_block by writing their pre-write values back
    /// to db.  Diffs are applied newest-block-first, reverse-diff-order within each
    /// block, so multiple writes to the same key in one block are undone correctly.
    ///
    /// Returns error.ReorgWindowExceeded if target_block+1 was already evicted
    /// by a manifest flush; caller must resync from the last flush in that case.
    pub fn reorgTo(self: *BlockJournal, target_block: u32, db: *PrefixDB) !void {
        const tip = self.tip orelse return;
        if (target_block >= tip) return;
        if (target_block +| 1 < self.oldest_live) return error.ReorgWindowExceeded;

        // Apply diffs newest-to-oldest.
        var b: u32 = tip;
        while (b > target_block) : (b -= 1) {
            const idx = b % REORG_WINDOW;
            if (self.ring[idx]) |s| {
                if (s.block_num == b) {
                    var i = s.diffs.items.len;
                    while (i > 0) {
                        i -= 1;
                        const d = s.diffs.items[i];
                        try db.write(d.key, d.old_value orelse t.TOMBSTONE);
                    }
                }
            }
        }

        // Release journal entries for the undone blocks.
        b = tip;
        while (b > target_block) : (b -= 1) {
            const idx = b % REORG_WINDOW;
            if (self.ring[idx]) |*s| {
                if (s.block_num == b) {
                    s.diffs.deinit(self.allocator);
                    self.ring[idx] = null;
                }
            }
        }

        self.tip = target_block;
    }

    /// Release journal entries for blocks <= flushed_block_num.
    /// Those blocks are now permanent in the manifest and cannot be reorged.
    pub fn evictOldBlocks(self: *BlockJournal, flushed_block_num: u32) void {
        for (&self.ring) |*slot| {
            if (slot.*) |*s| {
                if (s.block_num <= flushed_block_num) {
                    s.diffs.deinit(self.allocator);
                    slot.* = null;
                }
            }
        }
        self.oldest_live = @max(self.oldest_live, flushed_block_num +| 1);
    }
};

// ─── Tests ────────────────────────────────────────────────────────────────────

const root_mod = @import("root.zig");

fn testKey(n: u8) t.Key {
    var k = std.mem.zeroes(t.Key);
    k[31] = n;
    return k;
}

fn testVal(n: u8) t.Value {
    var v = std.mem.zeroes(t.Value);
    v[0] = n;
    return v;
}

test "BlockJournal: single-block reorg restores old value" {
    var j = BlockJournal.init(std.testing.allocator);
    defer j.deinit();

    var db = try PrefixDB.init(std.testing.allocator);
    defer db.deinit();

    const k1 = testKey(1);
    const v_old = testVal(0xAA);
    const v_new = testVal(0xBB);

    // Write initial value so the key exists.
    try db.write(k1, v_old);
    _ = try db.commitBlock();

    // Block 1: overwrite k1, recording old value.
    j.beginBlock(1);
    try j.recordWrite(k1, v_old);
    try db.write(k1, v_new);
    _ = try db.commitBlock();
    j.endBlock(1);

    // Verify new value is visible.
    try std.testing.expectEqual(@as(?t.Value, v_new), try db.read(k1));

    // Reorg to block 0: k1 should revert to v_old.
    try j.reorgTo(0, &db);
    _ = try db.commitBlock(); // flush reverted writes
    try std.testing.expectEqual(@as(?t.Value, v_old), try db.read(k1));
}

test "BlockJournal: multi-block reorg reverts all blocks" {
    var j = BlockJournal.init(std.testing.allocator);
    defer j.deinit();

    var db = try PrefixDB.init(std.testing.allocator);
    defer db.deinit();

    const k1 = testKey(1);
    const k2 = testKey(2);
    const v0 = testVal(0x00);
    const v1 = testVal(0x11);
    const v2 = testVal(0x22);

    // Base: commit block 0 with initial values.
    try db.write(k1, v0);
    try db.write(k2, v0);
    j.beginBlock(0);
    _ = try db.commitBlock();
    j.endBlock(0);

    // Block 1: write k1 = v1.
    j.beginBlock(1);
    try j.recordWrite(k1, v0);
    try db.write(k1, v1);
    _ = try db.commitBlock();
    j.endBlock(1);

    // Block 2: write k2 = v2.
    j.beginBlock(2);
    try j.recordWrite(k2, v0);
    try db.write(k2, v2);
    _ = try db.commitBlock();
    j.endBlock(2);

    try std.testing.expectEqual(@as(?t.Value, v1), try db.read(k1));
    try std.testing.expectEqual(@as(?t.Value, v2), try db.read(k2));

    // Reorg to block 0: both keys should be back to v0.
    try j.reorgTo(0, &db);
    _ = try db.commitBlock();

    try std.testing.expectEqual(@as(?t.Value, v0), try db.read(k1));
    try std.testing.expectEqual(@as(?t.Value, v0), try db.read(k2));
}

test "BlockJournal: reorgTo with absent key writes tombstone" {
    var j = BlockJournal.init(std.testing.allocator);
    defer j.deinit();

    var db = try PrefixDB.init(std.testing.allocator);
    defer db.deinit();

    const k = testKey(5);
    const v = testVal(0x55);

    // Block 0: key does not exist.
    j.beginBlock(0);
    _ = try db.commitBlock();
    j.endBlock(0);

    // Block 1: write k for the first time (old_value = null = absent).
    j.beginBlock(1);
    try j.recordWrite(k, null);
    try db.write(k, v);
    _ = try db.commitBlock();
    j.endBlock(1);

    try std.testing.expectEqual(@as(?t.Value, v), try db.read(k));

    // Reorg to block 0: key should appear absent (tombstone written).
    try j.reorgTo(0, &db);
    _ = try db.commitBlock();

    // Read should return null (tombstone treated as not-found by the C API layer).
    const result = try db.read(k);
    if (result) |val| {
        try std.testing.expect(std.mem.eql(u8, &val, &t.TOMBSTONE));
    }
}

test "BlockJournal: ReorgWindowExceeded after eviction" {
    var j = BlockJournal.init(std.testing.allocator);
    defer j.deinit();

    var db = try PrefixDB.init(std.testing.allocator);
    defer db.deinit();

    // Commit two blocks.
    j.beginBlock(0);
    _ = try db.commitBlock();
    j.endBlock(0);

    j.beginBlock(1);
    _ = try db.commitBlock();
    j.endBlock(1);

    // Evict block 0 (simulate flush through block 0).
    j.evictOldBlocks(0);

    // Reorg to 1 is fine (nothing to undo from tip=1 to target=1).
    // Reorg to 0 should return ReorgWindowExceeded (block 1 was evicted? no — block 0 was).
    // Actually oldest_live = 1 after evictOldBlocks(0).
    // target_block=0, target_block+1=1, oldest_live=1 → 1 < 1 is false → should succeed? No wait.
    // oldest_live=1 means block 1 is still live. target_block+1 = 1 = oldest_live → NOT < → no error.
    // Let me evict block 1 too.
    j.evictOldBlocks(1);
    // oldest_live = 2. target_block=0, target_block+1=1 < 2 → ReorgWindowExceeded.
    try std.testing.expectError(error.ReorgWindowExceeded, j.reorgTo(0, &db));
}

test "BlockJournal: multiple writes to same key reverted correctly" {
    var j = BlockJournal.init(std.testing.allocator);
    defer j.deinit();

    var db = try PrefixDB.init(std.testing.allocator);
    defer db.deinit();

    const k = testKey(7);
    const v0 = testVal(0x10);
    const v1 = testVal(0x20);
    const v2 = testVal(0x30);

    // Block 0: write initial value.
    try db.write(k, v0);
    j.beginBlock(0);
    _ = try db.commitBlock();
    j.endBlock(0);

    // Block 1: write k twice within the same block.
    j.beginBlock(1);
    try j.recordWrite(k, v0); // old value before first write
    try db.write(k, v1);
    try j.recordWrite(k, v1); // old value before second write
    try db.write(k, v2);
    _ = try db.commitBlock();
    j.endBlock(1);

    try std.testing.expectEqual(@as(?t.Value, v2), try db.read(k));

    // Reorg to block 0: diffs applied in reverse → undo second write (v1→v0), then first (v0→v0... wait)
    // Actually: diffs are [{k, v0}, {k, v1}]. Applied in reverse: first {k, v1} → write v1, then {k, v0} → write v0.
    // Final in L0: v0 (last applied). Correct.
    try j.reorgTo(0, &db);
    _ = try db.commitBlock();
    try std.testing.expectEqual(@as(?t.Value, v0), try db.read(k));
}
