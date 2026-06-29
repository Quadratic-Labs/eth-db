//! Write-Ahead Log (WAL) for crash recovery — segmented, with retention.
//!
//! The WAL doubles as the commitment delta log (commitment_v2.md phase 3):
//! commitment pages persist lazily, so recovery replays WAL blocks from the
//! engine's replay point — which may lie several checkpoints back.  The log
//! is therefore split into segment files `wal_XXXXXXXX.bin`, one per
//! checkpoint interval; segments wholly below the replay point are deleted.
//!
//! Segment layout:
//!   WalHeader  (16 bytes, at offset 0; carries the segment's first block)
//!   WalEntry*  (72 bytes each, sequential)
//!
//! Entry types:
//!   kv_write     — one KV pair (key[32] ++ value[32]) for an in-flight block
//!   block_commit — marks a complete committed block; data[0..32] = state_root
//!   checkpoint   — legacy marker (replay boundaries now come from the manifest)

const std = @import("std");
const types = @import("types.zig");
const page_store = @import("page_store.zig");
const Io = std.Io;

pub const WAL_MAGIC: u32 = 0x57_41_4c_50; // "WALP"
pub const WAL_VERSION: u32 = 2;

pub const WalEntryType = enum(u8) {
    kv_write = 1,
    block_commit = 2,
    checkpoint = 3,
    _,
};

pub const WalHeader = extern struct {
    magic: u32,
    version: u32,
    /// Block number of the first entry this segment may contain.
    first_block: u32 = 0,
    _pad: u32 = 0,
};

fn segName(buf: *[24]u8, seg: u32) ![]const u8 {
    return std.fmt.bufPrint(buf, "wal_{x:0>8}.bin", .{seg});
}

pub const WalEntry = extern struct {
    entry_type: u8,
    _pad: [3]u8,
    block_num: u32,
    data: [64]u8,

    pub fn kvWrite(block_num: u32, key: types.Key, value: types.Value) WalEntry {
        var e = std.mem.zeroes(WalEntry);
        e.entry_type = @intFromEnum(WalEntryType.kv_write);
        e.block_num = block_num;
        @memcpy(e.data[0..32], &key);
        @memcpy(e.data[32..64], &value);
        return e;
    }

    pub fn blockCommit(block_num: u32, state_root: types.Hash) WalEntry {
        var e = std.mem.zeroes(WalEntry);
        e.entry_type = @intFromEnum(WalEntryType.block_commit);
        e.block_num = block_num;
        @memcpy(e.data[0..32], &state_root);
        return e;
    }

    pub fn checkpoint() WalEntry {
        var e = std.mem.zeroes(WalEntry);
        e.entry_type = @intFromEnum(WalEntryType.checkpoint);
        return e;
    }
};

pub const Wal = struct {
    file: Io.File,
    store: page_store.DiskStore,
    write_offset: u64,
    seg: u32,

    /// Create segment `seg` (truncating any stale file of the same name).
    pub fn create(store: page_store.DiskStore, seg: u32, first_block: u32) !Wal {
        var name_buf: [24]u8 = undefined;
        const name = try segName(&name_buf, seg);
        const file = try store.dir.createFile(store.io, name, .{ .truncate = true });
        errdefer file.close(store.io);
        const header = WalHeader{ .magic = WAL_MAGIC, .version = WAL_VERSION, .first_block = first_block };
        try file.writePositionalAll(store.io, std.mem.asBytes(&header), 0);
        return .{
            .file = file,
            .store = store,
            .write_offset = @sizeOf(WalHeader),
            .seg = seg,
        };
    }

    pub fn close(self: *Wal) void {
        self.file.close(self.store.io);
    }

    pub fn append(self: *Wal, entry: WalEntry) !void {
        try self.file.writePositionalAll(self.store.io, std.mem.asBytes(&entry), self.write_offset);
        self.write_offset += @sizeOf(WalEntry);
    }

    /// Start the next segment (called at each checkpoint).
    pub fn rotate(self: *Wal, first_block: u32) !void {
        self.file.close(self.store.io);
        const next = try Wal.create(self.store, self.seg + 1, first_block);
        self.* = next;
    }
};

/// Delete segments in [first_seg, next_seg) whose entries all predate
/// `replay_from` (i.e. the NEXT segment starts at or before replay_from).
/// Returns the new first retained segment.
pub fn pruneSegments(store: page_store.DiskStore, first_seg: u32, next_seg: u32, replay_from: u32) u32 {
    var first = first_seg;
    while (first + 1 < next_seg) : (first += 1) {
        var cur_buf: [24]u8 = undefined;
        const cur_name = segName(&cur_buf, first) catch return first;
        const exists = blk: {
            const f = store.dir.openFile(store.io, cur_name, .{}) catch break :blk false;
            f.close(store.io);
            break :blk true;
        };
        if (!exists) continue; // already pruned in an earlier session
        var name_buf: [24]u8 = undefined;
        const next_name = segName(&name_buf, first + 1) catch return first;
        const f = store.dir.openFile(store.io, next_name, .{}) catch return first;
        var header: WalHeader = undefined;
        const n = f.readPositionalAll(store.io, std.mem.asBytes(&header), 0) catch {
            f.close(store.io);
            return first;
        };
        f.close(store.io);
        if (n != @sizeOf(WalHeader) or header.first_block > replay_from) return first;
        var del_buf: [24]u8 = undefined;
        const del_name = segName(&del_buf, first) catch return first;
        store.dir.deleteFile(store.io, del_name) catch return first;
    }
    return first;
}

/// Read all entries from segments first_seg.. (consecutive; stops at the
/// first missing segment).  Caller owns the returned slice.
pub fn readAllEntries(store: page_store.DiskStore, allocator: std.mem.Allocator, first_seg: u32) ![]WalEntry {
    var entries: std.ArrayList(WalEntry) = .empty;
    errdefer entries.deinit(allocator);

    // Leading segments may have been pruned after the manifest recorded
    // first_seg; skip the gap, then require segments to be consecutive.
    var seg = first_seg;
    var found_any = false;
    var misses: u32 = 0;
    segments: while (misses < 4096) : (seg += 1) {
        var name_buf: [24]u8 = undefined;
        const name = try segName(&name_buf, seg);
        const file = store.dir.openFile(store.io, name, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                if (found_any) break :segments;
                misses += 1;
                continue :segments;
            },
            else => return err,
        };
        found_any = true;
        defer file.close(store.io);

        var header: WalHeader = undefined;
        const hn = try file.readPositionalAll(store.io, std.mem.asBytes(&header), 0);
        if (hn < @sizeOf(WalHeader) or header.magic != WAL_MAGIC) break :segments;

        var off: u64 = @sizeOf(WalHeader);
        while (true) {
            var entry: WalEntry = undefined;
            const n = try file.readPositionalAll(store.io, std.mem.asBytes(&entry), off);
            if (n < @sizeOf(WalEntry)) break;
            try entries.append(allocator, entry);
            off += @sizeOf(WalEntry);
        }
    }
    return entries.toOwnedSlice(allocator);
}
