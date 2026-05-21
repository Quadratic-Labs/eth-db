//! On-disk page I/O for KV payload (SST) pages (§4.3).
//!
//! Addressing — a 32-bit page ID splits as:
//!   bits 31..20  →  container_id  (one file per container, up to 4096 files)
//!   bits 19..0   →  local_page    (up to 2^20 pages per file = 4 GiB per file)
//!
//! On-disk SST page: exactly 4096 bytes = 64 × KvEntry.
//! The in-memory `count` field is NOT written — it is recovered from the
//! node-page fingerprint (§4.2.2).  Callers that receive a page via `read`
//! get `count = PAGE_ENTRIES`; they must apply the fingerprint to narrow it.

const std = @import("std");
const root = @import("types.zig");
const combinadic = @import("combinadic.zig");

pub const PAGE_SIZE: u32 = 4096;

// ─── Address helpers ──────────────────────────────────────────────────────────

inline fn containerId(id: u32) u32 {
    return id >> 20;
}
inline fn localPage(id: u32) u32 {
    return id & 0xFFFFF;
}
inline fn fileOffset(local: u32) u64 {
    return @as(u64, local) * PAGE_SIZE;
}

// ─── SST page store ───────────────────────────────────────────────────────────

/// Persistent store for KV payload (SST) pages.
///
/// Container files are named `sst_XXXXXXXX.dat` (lower-hex container ID)
/// inside `dir`.  Each file is a flat array of 4 KiB pages; the local page
/// index is used as the seek offset.  The store does not own `dir`.
pub const SstPageStore = struct {
    dir: std.fs.Dir,

    pub fn init(dir: std.fs.Dir) SstPageStore {
        return .{ .dir = dir };
    }

    /// Write `page.entries` (4096 bytes) to the heap slot `id`.
    /// `page.count` is not written to disk.
    pub fn write(self: *SstPageStore, id: root.PayloadSlotId, page: *const root.SstPage) !void {
        const f = try self.openContainer(containerId(id), .write);
        defer f.close();
        try f.seekTo(fileOffset(localPage(id)));
        try f.writeAll(std.mem.asBytes(&page.entries));
    }

    /// Read the SST page at heap slot `id`.
    /// Returns the page with `count = PAGE_ENTRIES`; callers must narrow this
    /// from the associated node-page fingerprint.
    pub fn read(self: *SstPageStore, id: root.PayloadSlotId) !root.SstPage {
        const f = try self.openContainer(containerId(id), .read);
        defer f.close();
        try f.seekTo(fileOffset(localPage(id)));
        var page = std.mem.zeroes(root.SstPage);
        const n = try f.readAll(std.mem.asBytes(&page.entries));
        if (n != @sizeOf(@TypeOf(page.entries))) return error.UnexpectedEof;
        page.count = @intCast(root.PAGE_ENTRIES);
        return page;
    }

    // ── Internal ─────────────────────────────────────────────────────────────

    const OpenMode = enum { read, write };

    fn openContainer(self: *SstPageStore, cid: u32, mode: OpenMode) !std.fs.File {
        var buf: [24]u8 = undefined;
        const name = try std.fmt.bufPrint(&buf, "sst_{x:0>8}.dat", .{cid});
        return switch (mode) {
            .read => self.dir.openFile(name, .{}),
            .write => self.dir.createFile(name, .{ .truncate = false }),
        };
    }
};

// ─── Node page store ──────────────────────────────────────────────────────────
//
// On-disk NodePage layout (fixed 8192 bytes = 2 physical pages):
//
//   bytes    0 –    3  : header  (sst_count u8, sorted_page_count u8, _pad[2])
//   bytes    4 – 2051  : child_commitments[64]  (64 × 32 = 2048 B)
//   bytes 2052 – 2431  : payload_slot_ids[95]   (95 × 4  =  380 B, little-endian)
//   bytes 2432 – 8131  : key_fingerprints[95]   (95 × 60 = 5700 B, combinadic)
//   bytes 8132 – 8191  : trailing padding (60 B, zero)
//
// The fingerprint slots beyond sst_count are encoded as NULL_FINGERPRINT, so
// the entire 8192-byte block is always written / read without branching on count.

const NODE_PAGE_SIZE: u32 = 8192;
const NODE_COMMITMENTS_OFF: u32 = 4;
const NODE_SLOT_IDS_OFF: u32 = 2052;
const NODE_FINGERPRINTS_OFF: u32 = 2432;

fn nodeFileOffset(local_block: u32) u64 {
    return @as(u64, local_block) * NODE_PAGE_SIZE;
}

fn serialiseNodePage(page: *const root.NodePage, buf: *[NODE_PAGE_SIZE]u8) void {
    buf[0] = page.sst_count;
    buf[1] = page.sorted_page_count;
    buf[2] = 0;
    buf[3] = 0;

    // child_commitments: 64 × 32 bytes, endian-neutral (byte arrays)
    @memcpy(buf[NODE_COMMITMENTS_OFF..][0..2048], std.mem.asBytes(&page.child_commitments));

    // payload_slot_ids: 95 × u32, little-endian
    for (page.payload_slot_ids, 0..) |id, i| {
        std.mem.writeInt(u32, buf[NODE_SLOT_IDS_OFF + i * 4 ..][0..4], id, .little);
    }

    // key_fingerprints: 95 × 60 bytes, combinadic-encoded
    for (page.key_fingerprints, 0..) |fp, i| {
        const enc = combinadic.encode(&fp);
        @memcpy(buf[NODE_FINGERPRINTS_OFF + i * 60 ..][0..60], &enc);
    }

    // trailing padding
    @memset(buf[8132..8192], 0);
}

fn deserialiseNodePage(buf: *const [NODE_PAGE_SIZE]u8) root.NodePage {
    var page: root.NodePage = undefined;
    page.sst_count = buf[0];
    page.sorted_page_count = buf[1];

    @memcpy(std.mem.asBytes(&page.child_commitments), buf[NODE_COMMITMENTS_OFF..][0..2048]);

    for (0..root.MAX_SST_PER_NODE) |i| {
        page.payload_slot_ids[i] = std.mem.readInt(u32, buf[NODE_SLOT_IDS_OFF + i * 4 ..][0..4], .little);
    }

    for (0..root.MAX_SST_PER_NODE) |i| {
        const enc: *const [60]u8 = buf[NODE_FINGERPRINTS_OFF + i * 60 ..][0..60];
        page.key_fingerprints[i] = combinadic.decode(enc);
    }
    return page;
}

/// Persistent store for node pages (§4.2.2 / §4.3).
///
/// Container files are named `node_XXXXXXXX.dat` inside `dir`.
/// Each NodePageId maps to an 8 KiB block: bits 31..20 select the container
/// file, bits 19..0 give the block index within the file.
/// The on-disk encoding uses combinadic fingerprints (§7.1), not the decoded
/// in-memory form.
pub const NodePageStore = struct {
    dir: std.fs.Dir,

    pub fn init(dir: std.fs.Dir) NodePageStore {
        return .{ .dir = dir };
    }

    /// Serialise and write a node page to disk.
    pub fn write(self: *NodePageStore, id: root.NodePageId, page: *const root.NodePage) !void {
        var buf: [NODE_PAGE_SIZE]u8 = undefined;
        serialiseNodePage(page, &buf);
        const f = try self.openContainer(containerId(id), .write);
        defer f.close();
        try f.seekTo(nodeFileOffset(localPage(id)));
        try f.writeAll(&buf);
    }

    /// Read and deserialise a node page from disk.
    pub fn read(self: *NodePageStore, id: root.NodePageId) !root.NodePage {
        var buf: [NODE_PAGE_SIZE]u8 = undefined;
        const f = try self.openContainer(containerId(id), .read);
        defer f.close();
        try f.seekTo(nodeFileOffset(localPage(id)));
        const n = try f.readAll(&buf);
        if (n != NODE_PAGE_SIZE) return error.UnexpectedEof;
        return deserialiseNodePage(&buf);
    }

    const OpenMode = enum { read, write };

    fn openContainer(self: *NodePageStore, cid: u32, mode: OpenMode) !std.fs.File {
        var buf: [25]u8 = undefined;
        const name = try std.fmt.bufPrint(&buf, "node_{x:0>8}.dat", .{cid});
        return switch (mode) {
            .read => self.dir.openFile(name, .{}),
            .write => self.dir.createFile(name, .{ .truncate = false }),
        };
    }
};

// ─── Tests ────────────────────────────────────────────────────────────────────

test "SstPageStore write and read round-trip" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = SstPageStore.init(tmp.dir);

    var page = std.mem.zeroes(root.SstPage);
    page.count = 2;
    page.entries[0] = .{ .key = [_]u8{0x01} ** 32, .value = [_]u8{0xAA} ** 32 };
    page.entries[1] = .{ .key = [_]u8{0x02} ** 32, .value = [_]u8{0xBB} ** 32 };

    try store.write(0, &page);
    const got = try store.read(0);

    try std.testing.expectEqual(page.entries[0], got.entries[0]);
    try std.testing.expectEqual(page.entries[1], got.entries[1]);
    // count is PAGE_ENTRIES on read — caller narrows via fingerprint
    try std.testing.expectEqual(@as(u8, root.PAGE_ENTRIES), got.count);
}

test "SstPageStore multiple pages in one container" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = SstPageStore.init(tmp.dir);

    var pa = std.mem.zeroes(root.SstPage);
    pa.entries[0].key = [_]u8{0xAA} ** 32;
    var pb = std.mem.zeroes(root.SstPage);
    pb.entries[0].key = [_]u8{0xBB} ** 32;

    try store.write(0, &pa); // container 0, local 0
    try store.write(1, &pb); // container 0, local 1

    const ga = try store.read(0);
    const gb = try store.read(1);
    try std.testing.expectEqual(pa.entries[0], ga.entries[0]);
    try std.testing.expectEqual(pb.entries[0], gb.entries[0]);
}

test "SstPageStore pages across containers" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = SstPageStore.init(tmp.dir);

    var p0 = std.mem.zeroes(root.SstPage);
    p0.entries[0].key = [_]u8{0x11} ** 32;
    var p1 = std.mem.zeroes(root.SstPage);
    p1.entries[0].key = [_]u8{0x22} ** 32;

    const id0: root.PayloadSlotId = (0 << 20) | 0; // container 0, local 0
    const id1: root.PayloadSlotId = (1 << 20) | 0; // container 1, local 0

    try store.write(id0, &p0);
    try store.write(id1, &p1);

    const g0 = try store.read(id0);
    const g1 = try store.read(id1);
    try std.testing.expectEqual(p0.entries[0], g0.entries[0]);
    try std.testing.expectEqual(p1.entries[0], g1.entries[0]);
}

test "SstPageStore non-zero offset within container" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = SstPageStore.init(tmp.dir);

    // Write to page 7 (local_page = 7, skipping pages 0-6)
    const id: root.PayloadSlotId = 7;
    var page = std.mem.zeroes(root.SstPage);
    page.entries[3].key = [_]u8{0xFF} ** 32;
    page.entries[3].value = [_]u8{0x42} ** 32;

    try store.write(id, &page);
    const got = try store.read(id);
    try std.testing.expectEqual(page.entries[3], got.entries[3]);
}

test "SstPageStore all 64 entries preserved" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = SstPageStore.init(tmp.dir);

    var page = std.mem.zeroes(root.SstPage);
    page.count = root.PAGE_ENTRIES;
    for (&page.entries, 0..) |*e, i| {
        @memset(&e.key, @intCast(i));
        @memset(&e.value, @intCast(i + 1));
    }

    try store.write(0, &page);
    const got = try store.read(0);
    try std.testing.expectEqualSlices(root.KvEntry, &page.entries, &got.entries);
}

// ── NodePageStore tests ────────────────────────────────────────────────────────

test "NodePageStore write and read round-trip — sparse page" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = NodePageStore.init(tmp.dir);

    var page = std.mem.zeroes(root.NodePage);
    page.sst_count = 2;
    page.sorted_page_count = 1;
    // Set some non-trivial child commitments
    page.child_commitments[0] = [_]u8{0xAB} ** 32;
    page.child_commitments[63] = [_]u8{0xCD} ** 32;
    // Two payload slot IDs
    page.payload_slot_ids[0] = 42;
    page.payload_slot_ids[1] = 99;
    // Two fingerprints: a simple one and the null fingerprint
    page.key_fingerprints[0] = root.NULL_FINGERPRINT;
    page.key_fingerprints[0][0] = 0;
    page.key_fingerprints[0][1] = 7;
    // key_fingerprints[1] stays zero-initialised (all zeros ≠ null, but valid sorted)

    try store.write(0, &page);
    const got = try store.read(0);

    try std.testing.expectEqual(page.sst_count, got.sst_count);
    try std.testing.expectEqual(page.sorted_page_count, got.sorted_page_count);
    try std.testing.expectEqual(page.child_commitments[0], got.child_commitments[0]);
    try std.testing.expectEqual(page.child_commitments[63], got.child_commitments[63]);
    try std.testing.expectEqual(page.payload_slot_ids[0], got.payload_slot_ids[0]);
    try std.testing.expectEqual(page.payload_slot_ids[1], got.payload_slot_ids[1]);
    try std.testing.expectEqual(page.key_fingerprints[0], got.key_fingerprints[0]);
}

test "NodePageStore round-trip — full child_commitments" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = NodePageStore.init(tmp.dir);

    var page = std.mem.zeroes(root.NodePage);
    page.sst_count = 0;
    for (&page.child_commitments, 0..) |*h, i| {
        @memset(h, @intCast(i + 1));
    }

    try store.write(1, &page);
    const got = try store.read(1);

    for (page.child_commitments, got.child_commitments) |a, b| {
        try std.testing.expectEqual(a, b);
    }
}

test "NodePageStore round-trip — NULL_FINGERPRINT for all 95 slots" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = NodePageStore.init(tmp.dir);

    var page = std.mem.zeroes(root.NodePage);
    page.sst_count = root.MAX_SST_PER_NODE;
    for (&page.key_fingerprints) |*fp| fp.* = root.NULL_FINGERPRINT;
    for (&page.payload_slot_ids, 0..) |*id, i| id.* = @intCast(i);

    try store.write(0, &page);
    const got = try store.read(0);

    try std.testing.expectEqual(page.sst_count, got.sst_count);
    try std.testing.expectEqual(root.NULL_FINGERPRINT, got.key_fingerprints[0]);
    try std.testing.expectEqual(root.NULL_FINGERPRINT, got.key_fingerprints[94]);
    try std.testing.expectEqual(@as(u32, 94), got.payload_slot_ids[94]);
}

test "NodePageStore pages across containers" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = NodePageStore.init(tmp.dir);

    var p0 = std.mem.zeroes(root.NodePage);
    p0.sst_count = 1;
    p0.child_commitments[0] = [_]u8{0x11} ** 32;

    var p1 = std.mem.zeroes(root.NodePage);
    p1.sst_count = 2;
    p1.child_commitments[0] = [_]u8{0x22} ** 32;

    const id0: root.NodePageId = (0 << 20) | 0;
    const id1: root.NodePageId = (1 << 20) | 0;
    try store.write(id0, &p0);
    try store.write(id1, &p1);

    const g0 = try store.read(id0);
    const g1 = try store.read(id1);
    try std.testing.expectEqual(@as(u8, 1), g0.sst_count);
    try std.testing.expectEqual(@as(u8, 2), g1.sst_count);
    try std.testing.expectEqual(p0.child_commitments[0], g0.child_commitments[0]);
    try std.testing.expectEqual(p1.child_commitments[0], g1.child_commitments[0]);
}
