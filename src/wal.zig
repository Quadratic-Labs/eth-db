//! Write-Ahead Log (WAL) for crash recovery.
//!
//! The WAL is a sequential log of KV writes and block commits accumulated
//! since the last manifest checkpoint.  On crash recovery, entries after the
//! last CHECKPOINT entry are replayed to restore in-flight state.
//!
//! File layout:
//!   WalHeader  (8 bytes, at offset 0)
//!   WalEntry*  (72 bytes each, sequential)
//!
//! Entry types:
//!   kv_write     — one KV pair (key[32] ++ value[32]) for an in-flight block
//!   block_commit — marks a complete committed block; data[0..32] = state_root
//!   checkpoint   — safe recovery point; manifest is consistent through here

const std = @import("std");
const types = @import("types.zig");
const page_store = @import("page_store.zig");
const Io = std.Io;

pub const WAL_MAGIC: u32 = 0x57_41_4c_50; // "WALP"
pub const WAL_VERSION: u32 = 1;

pub const WalEntryType = enum(u8) {
    kv_write = 1,
    block_commit = 2,
    checkpoint = 3,
    _,
};

pub const WalHeader = extern struct {
    magic: u32,
    version: u32,
};

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

    /// Create (or truncate) wal.bin and write the header.
    pub fn create(store: page_store.DiskStore) !Wal {
        const file = try store.dir.createFile(store.io, "wal.bin", .{ .truncate = true });
        errdefer file.close(store.io);
        const header = WalHeader{ .magic = WAL_MAGIC, .version = WAL_VERSION };
        try file.writePositionalAll(store.io, std.mem.asBytes(&header), 0);
        return .{
            .file = file,
            .store = store,
            .write_offset = @sizeOf(WalHeader),
        };
    }

    pub fn close(self: *Wal) void {
        self.file.close(self.store.io);
    }

    pub fn append(self: *Wal, entry: WalEntry) !void {
        try self.file.writePositionalAll(self.store.io, std.mem.asBytes(&entry), self.write_offset);
        self.write_offset += @sizeOf(WalEntry);
    }
};

/// Read all entries from wal.bin.  Returns an empty slice when the file does
/// not exist or has an invalid header.  Caller owns the returned slice.
pub fn readAllEntries(store: page_store.DiskStore, allocator: std.mem.Allocator) ![]WalEntry {
    const file = store.dir.openFile(store.io, "wal.bin", .{}) catch |err| switch (err) {
        error.FileNotFound => return allocator.alloc(WalEntry, 0),
        else => return err,
    };
    defer file.close(store.io);

    var header: WalHeader = undefined;
    const hn = try file.readPositionalAll(store.io, std.mem.asBytes(&header), 0);
    if (hn < @sizeOf(WalHeader) or header.magic != WAL_MAGIC) {
        return allocator.alloc(WalEntry, 0);
    }

    var entries: std.ArrayList(WalEntry) = .empty;
    errdefer entries.deinit(allocator);
    var off: u64 = @sizeOf(WalHeader);
    while (true) {
        var entry: WalEntry = undefined;
        const n = try file.readPositionalAll(store.io, std.mem.asBytes(&entry), off);
        if (n < @sizeOf(WalEntry)) break;
        try entries.append(allocator, entry);
        off += @sizeOf(WalEntry);
    }
    return entries.toOwnedSlice(allocator);
}
