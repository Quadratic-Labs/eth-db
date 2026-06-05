//! On-disk page I/O for KV payload (SST) pages and node pages (§4.3).
//!
//! Addressing — a 32-bit page ID splits as:
//!   bits 31..20  →  container_id  (one file per container, up to 4096 files)
//!   bits 19..0   →  local_page    (up to 2^20 pages per file = 4 GiB per file)
//!
//! On-disk SST page: exactly 4096 bytes = 64 × KvEntry.
//! The in-memory `count` field is NOT written to disk; it is stored in the
//! owning node-page's sorted_page_counts / append_page_counts arrays (§4.2.2).
//!
//! On-disk node page: exactly 4096 bytes (one physical page).
//!   bytes    0 –    3  : header (sorted_count u8, append_count u8, _pad[2])
//!   bytes    4 – 2051  : child_commitments[64]          (64 × 32 = 2048 B)
//!   bytes 2052 – 2483  : sorted_slot_ids[108]            (108 × 4 = 432 B, LE u32)
//!   bytes 2484 – 2915  : sorted_min4[108]                (108 × 4 = 432 B, LE u32)
//!   bytes 2916 – 3023  : sorted_page_counts[108]         (108 × 1 = 108 B)
//!   bytes 3024 – 3031  : append_page_counts[8]           (8 × 1 = 8 B)
//!   bytes 3032 – 3063  : append_slot_ids[8]              (8 × 4 = 32 B, LE u32)
//!   bytes 3064 – 4087  : append_prefix16[8][64]          (8 × 64 × 2 = 1024 B, LE u16)
//!   bytes 4088 – 4095  : _reserved (zero)

const std = @import("std");
const root = @import("types.zig");
const Io = std.Io;

pub const PAGE_SIZE: u32 = 4096;

/// Directory handle + I/O interface bundled for disk-store operations.
pub const DiskStore = struct { dir: Io.Dir, io: Io };

pub const MANIFEST_MAGIC: u32 = 0x01_42_44_50;
pub const MANIFEST_VERSION: u32 = 1;

/// Fixed-size header written at offset 0 of manifest.bin.
pub const ManifestHeader = extern struct {
    magic: u32,
    version: u32,
    next_node_id: u32,
    next_sst_id: u32,
    pin_used_words: u32,
    routing_count: u32,
    l0_count: u32,
    _pad: u32 = 0,
};

/// One routing-table entry (depth + prefix → node_id).
pub const ManifestRouteEntry = extern struct {
    depth: u32,
    prefix: u32,
    node_id: u32,
};

/// Deserialized manifest data (caller owns the slices).
pub const ManifestData = struct {
    header: ManifestHeader,
    pin_used: []u64,
    routes: []ManifestRouteEntry,
    l0: []root.KvEntry,

    pub fn deinit(self: *ManifestData, allocator: std.mem.Allocator) void {
        allocator.free(self.pin_used);
        allocator.free(self.routes);
        allocator.free(self.l0);
    }
};

pub fn writeManifest(
    store: DiskStore,
    header: ManifestHeader,
    pin_used: []const u64,
    routes: []const ManifestRouteEntry,
    l0: []const root.KvEntry,
) !void {
    const f = try store.dir.createFile(store.io, "manifest.bin", .{ .truncate = true });
    defer f.close(store.io);
    var off: u64 = 0;
    try f.writePositionalAll(store.io, std.mem.asBytes(&header), off);
    off += @sizeOf(ManifestHeader);
    try f.writePositionalAll(store.io, std.mem.sliceAsBytes(pin_used), off);
    off += pin_used.len * @sizeOf(u64);
    try f.writePositionalAll(store.io, std.mem.sliceAsBytes(routes), off);
    off += routes.len * @sizeOf(ManifestRouteEntry);
    try f.writePositionalAll(store.io, std.mem.sliceAsBytes(l0), off);
}

pub fn readManifest(store: DiskStore, allocator: std.mem.Allocator) !ManifestData {
    const f = try store.dir.openFile(store.io, "manifest.bin", .{});
    defer f.close(store.io);
    var off: u64 = 0;

    var header: ManifestHeader = undefined;
    const hn = try f.readPositionalAll(store.io, std.mem.asBytes(&header), off);
    if (hn != @sizeOf(ManifestHeader)) return error.ManifestTruncated;
    off += @sizeOf(ManifestHeader);
    if (header.magic != MANIFEST_MAGIC) return error.ManifestBadMagic;
    if (header.version != MANIFEST_VERSION) return error.ManifestVersionMismatch;

    const pin_used = try allocator.alloc(u64, header.pin_used_words);
    errdefer allocator.free(pin_used);
    if (pin_used.len > 0) {
        const pn = try f.readPositionalAll(store.io, std.mem.sliceAsBytes(pin_used), off);
        if (pn != pin_used.len * @sizeOf(u64)) return error.ManifestTruncated;
        off += pin_used.len * @sizeOf(u64);
    }

    const routes = try allocator.alloc(ManifestRouteEntry, header.routing_count);
    errdefer allocator.free(routes);
    if (routes.len > 0) {
        const rn = try f.readPositionalAll(store.io, std.mem.sliceAsBytes(routes), off);
        if (rn != routes.len * @sizeOf(ManifestRouteEntry)) return error.ManifestTruncated;
        off += routes.len * @sizeOf(ManifestRouteEntry);
    }

    const l0 = try allocator.alloc(root.KvEntry, header.l0_count);
    errdefer allocator.free(l0);
    if (l0.len > 0) {
        const ln = try f.readPositionalAll(store.io, std.mem.sliceAsBytes(l0), off);
        if (ln != l0.len * @sizeOf(root.KvEntry)) return error.ManifestTruncated;
    }

    return .{
        .header = header,
        .pin_used = pin_used,
        .routes = routes,
        .l0 = l0,
    };
}

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
    dir: Io.Dir,
    io: Io,

    pub fn init(dir: Io.Dir, io: Io) SstPageStore {
        return .{ .dir = dir, .io = io };
    }

    /// Write `page.entries` (4096 bytes) to the heap slot `id`.
    /// `page.count` is not written to disk.
    pub fn write(self: *SstPageStore, id: root.PayloadSlotId, page: *const root.SstPage) !void {
        const f = try self.openContainer(containerId(id), .write);
        defer f.close(self.io);
        try f.writePositionalAll(self.io, std.mem.asBytes(&page.entries), fileOffset(localPage(id)));
    }

    /// Read the SST page at heap slot `id`.
    /// Returns the page with `count = PAGE_ENTRIES`; callers must narrow this
    /// from the associated node-page filter data.
    pub fn read(self: *SstPageStore, id: root.PayloadSlotId) !root.SstPage {
        const f = try self.openContainer(containerId(id), .read);
        defer f.close(self.io);
        var page = std.mem.zeroes(root.SstPage);
        const n = try f.readPositionalAll(self.io, std.mem.asBytes(&page.entries), fileOffset(localPage(id)));
        if (n != @sizeOf(@TypeOf(page.entries))) return error.UnexpectedEof;
        page.count = @intCast(root.PAGE_ENTRIES);
        return page;
    }

    // ── Internal ─────────────────────────────────────────────────────────────

    const OpenMode = enum { read, write };

    fn openContainer(self: *SstPageStore, cid: u32, mode: OpenMode) !Io.File {
        var buf: [24]u8 = undefined;
        const name = try std.fmt.bufPrint(&buf, "sst_{x:0>8}.dat", .{cid});
        return switch (mode) {
            .read => self.dir.openFile(self.io, name, .{}),
            .write => self.dir.createFile(self.io, name, .{ .truncate = false }),
        };
    }
};

// ─── Node page store ──────────────────────────────────────────────────────────

const NODE_PAGE_SIZE: u32 = 4096;
const NODE_COMMITMENTS_OFF: u32 = 4;
const NODE_SORTED_IDS_OFF: u32 = 2052; // 4 + 2048
const NODE_SORTED_MIN4_OFF: u32 = 2484; // 2052 + 432
const NODE_SORTED_COUNTS_OFF: u32 = 2916; // 2484 + 432
const NODE_APPEND_COUNTS_OFF: u32 = 3024; // 2916 + 108
const NODE_APPEND_IDS_OFF: u32 = 3032; // 3024 + 8
const NODE_APPEND_PREFIX16_OFF: u32 = 3064; // 3032 + 32
// _reserved: 4088–4095

comptime {
    // Verify the on-disk layout totals exactly one physical page.
    const tail = NODE_APPEND_PREFIX16_OFF + root.A_MAX * root.PAGE_ENTRIES * 2 + 8;
    if (tail != NODE_PAGE_SIZE) @compileError("NodePage layout does not fit in 4096 bytes");
}

fn serialiseNodePage(page: *const root.NodePage, buf: *[NODE_PAGE_SIZE]u8) void {
    buf[0] = page.sorted_count;
    buf[1] = page.append_count;
    buf[2] = 0;
    buf[3] = 0;

    // child_commitments: 64 × 32 bytes, endian-neutral (byte arrays)
    @memcpy(buf[NODE_COMMITMENTS_OFF..][0..2048], std.mem.asBytes(&page.child_commitments));

    // sorted_slot_ids: 123 × u32, little-endian
    for (page.sorted_slot_ids, 0..) |id, i| {
        std.mem.writeInt(u32, buf[NODE_SORTED_IDS_OFF + i * 4 ..][0..4], id, .little);
    }

    // sorted_min4: 123 × u32, little-endian
    for (page.sorted_min4, 0..) |m, i| {
        std.mem.writeInt(u32, buf[NODE_SORTED_MIN4_OFF + i * 4 ..][0..4], m, .little);
    }

    // sorted_page_counts: 108 × u8
    @memcpy(buf[NODE_SORTED_COUNTS_OFF..][0..root.S_MAX], &page.sorted_page_counts);

    // append_page_counts: 8 × u8
    @memcpy(buf[NODE_APPEND_COUNTS_OFF..][0..root.A_MAX], &page.append_page_counts);

    // append_slot_ids: 8 × u32, little-endian
    for (page.append_slot_ids, 0..) |id, i| {
        std.mem.writeInt(u32, buf[NODE_APPEND_IDS_OFF + i * 4 ..][0..4], id, .little);
    }

    // append_prefix16: 8 × 64 × u16, little-endian; each row is 128 bytes
    for (page.append_prefix16, 0..) |row, pi| {
        for (row, 0..) |v, ki| {
            std.mem.writeInt(u16, buf[NODE_APPEND_PREFIX16_OFF + pi * 128 + ki * 2 ..][0..2], v, .little);
        }
    }

    // trailing reserved bytes
    @memset(buf[4088..4096], 0);
}

fn deserialiseNodePage(buf: *const [NODE_PAGE_SIZE]u8) root.NodePage {
    var page: root.NodePage = undefined;
    page.sorted_count = buf[0];
    page.append_count = buf[1];

    @memcpy(std.mem.asBytes(&page.child_commitments), buf[NODE_COMMITMENTS_OFF..][0..2048]);

    for (0..root.S_MAX) |i| {
        page.sorted_slot_ids[i] = std.mem.readInt(u32, buf[NODE_SORTED_IDS_OFF + i * 4 ..][0..4], .little);
    }

    for (0..root.S_MAX) |i| {
        page.sorted_min4[i] = std.mem.readInt(u32, buf[NODE_SORTED_MIN4_OFF + i * 4 ..][0..4], .little);
    }

    @memcpy(&page.sorted_page_counts, buf[NODE_SORTED_COUNTS_OFF..][0..root.S_MAX]);

    @memcpy(&page.append_page_counts, buf[NODE_APPEND_COUNTS_OFF..][0..root.A_MAX]);

    for (0..root.A_MAX) |i| {
        page.append_slot_ids[i] = std.mem.readInt(u32, buf[NODE_APPEND_IDS_OFF + i * 4 ..][0..4], .little);
    }

    for (0..root.A_MAX) |pi| {
        for (0..root.PAGE_ENTRIES) |ki| {
            page.append_prefix16[pi][ki] = std.mem.readInt(u16, buf[NODE_APPEND_PREFIX16_OFF + pi * 128 + ki * 2 ..][0..2], .little);
        }
    }

    return page;
}

/// Persistent store for node pages (§4.2.2 / §4.3).
///
/// Container files are named `node_XXXXXXXX.dat` inside `dir`.
/// Each NodePageId maps to a 4 KiB block: bits 31..20 select the container
/// file, bits 19..0 give the block index within the file.
pub const NodePageStore = struct {
    dir: Io.Dir,
    io: Io,

    pub fn init(dir: Io.Dir, io: Io) NodePageStore {
        return .{ .dir = dir, .io = io };
    }

    /// Serialise and write a node page to disk.
    pub fn write(self: *NodePageStore, id: root.NodePageId, page: *const root.NodePage) !void {
        var buf: [NODE_PAGE_SIZE]u8 = undefined;
        serialiseNodePage(page, &buf);
        const f = try self.openContainer(containerId(id), .write);
        defer f.close(self.io);
        try f.writePositionalAll(self.io, &buf, fileOffset(localPage(id)));
    }

    /// Read and deserialise a node page from disk.
    pub fn read(self: *NodePageStore, id: root.NodePageId) !root.NodePage {
        var buf: [NODE_PAGE_SIZE]u8 = undefined;
        const f = try self.openContainer(containerId(id), .read);
        defer f.close(self.io);
        const n = try f.readPositionalAll(self.io, &buf, fileOffset(localPage(id)));
        if (n != NODE_PAGE_SIZE) return error.UnexpectedEof;
        return deserialiseNodePage(&buf);
    }

    const OpenMode = enum { read, write };

    fn openContainer(self: *NodePageStore, cid: u32, mode: OpenMode) !Io.File {
        var buf: [25]u8 = undefined;
        const name = try std.fmt.bufPrint(&buf, "node_{x:0>8}.dat", .{cid});
        return switch (mode) {
            .read => self.dir.openFile(self.io, name, .{}),
            .write => self.dir.createFile(self.io, name, .{ .truncate = false }),
        };
    }
};

// ─── Tests ────────────────────────────────────────────────────────────────────

test "SstPageStore write and read round-trip" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = SstPageStore.init(tmp.dir, std.testing.io);

    var page = std.mem.zeroes(root.SstPage);
    page.count = 2;
    page.entries[0] = .{ .key = [_]u8{0x01} ** 32, .value = [_]u8{0xAA} ** 32 };
    page.entries[1] = .{ .key = [_]u8{0x02} ** 32, .value = [_]u8{0xBB} ** 32 };

    try store.write(0, &page);
    const got = try store.read(0);

    try std.testing.expectEqual(page.entries[0], got.entries[0]);
    try std.testing.expectEqual(page.entries[1], got.entries[1]);
    // count is PAGE_ENTRIES on read — caller narrows via node-page filter
    try std.testing.expectEqual(@as(u8, root.PAGE_ENTRIES), got.count);
}

test "SstPageStore multiple pages in one container" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = SstPageStore.init(tmp.dir, std.testing.io);

    var pa = std.mem.zeroes(root.SstPage);
    pa.entries[0].key = [_]u8{0xAA} ** 32;
    var pb = std.mem.zeroes(root.SstPage);
    pb.entries[0].key = [_]u8{0xBB} ** 32;

    try store.write(0, &pa);
    try store.write(1, &pb);

    const ga = try store.read(0);
    const gb = try store.read(1);
    try std.testing.expectEqual(pa.entries[0], ga.entries[0]);
    try std.testing.expectEqual(pb.entries[0], gb.entries[0]);
}

test "SstPageStore pages across containers" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = SstPageStore.init(tmp.dir, std.testing.io);

    var p0 = std.mem.zeroes(root.SstPage);
    p0.entries[0].key = [_]u8{0x11} ** 32;
    var p1 = std.mem.zeroes(root.SstPage);
    p1.entries[0].key = [_]u8{0x22} ** 32;

    const id0: root.PayloadSlotId = (0 << 20) | 0;
    const id1: root.PayloadSlotId = (1 << 20) | 0;

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
    var store = SstPageStore.init(tmp.dir, std.testing.io);

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
    var store = SstPageStore.init(tmp.dir, std.testing.io);

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
    var store = NodePageStore.init(tmp.dir, std.testing.io);

    var page = std.mem.zeroes(root.NodePage);
    page.sorted_count = 2;
    page.append_count = 1;
    page.child_commitments[0] = [_]u8{0xAB} ** 32;
    page.child_commitments[63] = [_]u8{0xCD} ** 32;
    page.sorted_slot_ids[0] = 42;
    page.sorted_slot_ids[1] = 99;
    page.sorted_min4[0] = 0x0000_1234;
    page.sorted_min4[1] = 0x0000_5678;
    page.append_slot_ids[0] = 7;
    // append_prefix16[0] — 64 u16 values for the one append page
    for (&page.append_prefix16[0], 0..) |*v, i| v.* = @intCast(i * 100);

    try store.write(0, &page);
    const got = try store.read(0);

    try std.testing.expectEqual(page.sorted_count, got.sorted_count);
    try std.testing.expectEqual(page.append_count, got.append_count);
    try std.testing.expectEqual(page.child_commitments[0], got.child_commitments[0]);
    try std.testing.expectEqual(page.child_commitments[63], got.child_commitments[63]);
    try std.testing.expectEqual(page.sorted_slot_ids[0], got.sorted_slot_ids[0]);
    try std.testing.expectEqual(page.sorted_slot_ids[1], got.sorted_slot_ids[1]);
    try std.testing.expectEqual(page.sorted_min4[0], got.sorted_min4[0]);
    try std.testing.expectEqual(page.sorted_min4[1], got.sorted_min4[1]);
    try std.testing.expectEqual(page.append_slot_ids[0], got.append_slot_ids[0]);
    try std.testing.expectEqualSlices(u16, &page.append_prefix16[0], &got.append_prefix16[0]);
}

test "NodePageStore round-trip — full sorted zone" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = NodePageStore.init(tmp.dir, std.testing.io);

    var page = std.mem.zeroes(root.NodePage);
    page.sorted_count = root.S_MAX;
    page.append_count = 0;
    for (&page.sorted_slot_ids, 0..) |*id, i| id.* = @intCast(i);
    for (&page.sorted_min4, 0..) |*m, i| m.* = @intCast(i * 0x100);
    for (&page.child_commitments, 0..) |*h, i| @memset(h, @intCast(i + 1));

    try store.write(0, &page);
    const got = try store.read(0);

    try std.testing.expectEqual(@as(u8, root.S_MAX), got.sorted_count);
    try std.testing.expectEqual(@as(u32, root.S_MAX - 1), got.sorted_slot_ids[root.S_MAX - 1]);
    try std.testing.expectEqual(@as(u32, (root.S_MAX - 1) * 0x100), got.sorted_min4[root.S_MAX - 1]);
    for (page.child_commitments, got.child_commitments) |a, b| {
        try std.testing.expectEqual(a, b);
    }
}

test "NodePageStore round-trip — full append zone" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = NodePageStore.init(tmp.dir, std.testing.io);

    var page = std.mem.zeroes(root.NodePage);
    page.sorted_count = 0;
    page.append_count = root.A_MAX;
    for (&page.append_slot_ids, 0..) |*id, i| id.* = @intCast(1000 + i);
    // Fill all 8 × 64 prefix16 entries with recognisable values.
    for (&page.append_prefix16, 0..) |*row, pi| {
        for (row, 0..) |*v, ki| v.* = @intCast(pi * 1000 + ki);
    }

    try store.write(1, &page);
    const got = try store.read(1);

    try std.testing.expectEqual(@as(u8, root.A_MAX), got.append_count);
    for (0..root.A_MAX) |pi| {
        try std.testing.expectEqual(@as(u32, 1000) + @as(u32, @intCast(pi)), got.append_slot_ids[pi]);
        try std.testing.expectEqualSlices(u16, &page.append_prefix16[pi], &got.append_prefix16[pi]);
    }
}

test "NodePageStore pages across containers" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = NodePageStore.init(tmp.dir, std.testing.io);

    var p0 = std.mem.zeroes(root.NodePage);
    p0.sorted_count = 1;
    p0.child_commitments[0] = [_]u8{0x11} ** 32;

    var p1 = std.mem.zeroes(root.NodePage);
    p1.sorted_count = 2;
    p1.child_commitments[0] = [_]u8{0x22} ** 32;

    const id0: root.NodePageId = (0 << 20) | 0;
    const id1: root.NodePageId = (1 << 20) | 0;
    try store.write(id0, &p0);
    try store.write(id1, &p1);

    const g0 = try store.read(id0);
    const g1 = try store.read(id1);
    try std.testing.expectEqual(@as(u8, 1), g0.sorted_count);
    try std.testing.expectEqual(@as(u8, 2), g1.sorted_count);
    try std.testing.expectEqual(p0.child_commitments[0], g0.child_commitments[0]);
    try std.testing.expectEqual(p1.child_commitments[0], g1.child_commitments[0]);
}
