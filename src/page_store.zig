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
pub const MANIFEST_VERSION: u32 = 2;

/// Fixed-size header written at offset 0 of manifest.bin.
/// The first 32 bytes are layout-identical to version 1; the free-list counts
/// were appended in version 2 (v1 manifests are read with empty free lists).
pub const ManifestHeader = extern struct {
    magic: u32,
    version: u32,
    next_node_id: u32,
    next_sst_id: u32,
    next_cmt_id: u32 = 0,
    routing_count: u32,
    l0_count: u32,
    _pad: u32 = 0,
    // ── Version 2 ──
    free_node_count: u32 = 0,
    free_sst_count: u32 = 0,
    free_cmt_count: u32 = 0,
    _pad2: u32 = 0,
};

/// Byte size of the version-1 header (prefix of the current layout).
pub const MANIFEST_HEADER_V1_SIZE: usize = 32;

comptime {
    if (@sizeOf(ManifestHeader) != 48) @compileError("ManifestHeader layout drifted");
}

/// One routing-table entry (depth + prefix → node_id [+ commitment page id]).
/// cmt_page_id is CMT_NONE (0xFFFFFFFF) when the node has no persisted
/// commitment page.
pub const ManifestRouteEntry = extern struct {
    depth: u32,
    node_id: u32,
    prefix: u64,
    cmt_page_id: u32 = root.CMT_NONE,
    _pad: u32 = 0,
};

/// Deserialized manifest data (caller owns the slices).
pub const ManifestData = struct {
    header: ManifestHeader,
    routes: []ManifestRouteEntry,
    l0: []root.KvEntry,
    /// Reusable page ids per store (empty for version-1 manifests).
    free_node: []u32,
    free_sst: []u32,
    free_cmt: []u32,

    pub fn deinit(self: *ManifestData, allocator: std.mem.Allocator) void {
        allocator.free(self.routes);
        allocator.free(self.l0);
        allocator.free(self.free_node);
        allocator.free(self.free_sst);
        allocator.free(self.free_cmt);
    }
};

/// Write the manifest atomically: serialise to manifest.tmp, fsync, then
/// rename over manifest.bin so a crash mid-write never corrupts the previous
/// checkpoint (recovery depends on the last manifest being intact).
pub fn writeManifest(
    store: DiskStore,
    header: ManifestHeader,
    routes: []const ManifestRouteEntry,
    l0: []const root.KvEntry,
    free_node: []const u32,
    free_sst: []const u32,
    free_cmt: []const u32,
) !void {
    std.debug.assert(header.free_node_count == free_node.len);
    std.debug.assert(header.free_sst_count == free_sst.len);
    std.debug.assert(header.free_cmt_count == free_cmt.len);
    {
        const f = try store.dir.createFile(store.io, "manifest.tmp", .{ .truncate = true });
        defer f.close(store.io);
        var off: u64 = 0;
        try f.writePositionalAll(store.io, std.mem.asBytes(&header), off);
        off += @sizeOf(ManifestHeader);
        try f.writePositionalAll(store.io, std.mem.sliceAsBytes(routes), off);
        off += routes.len * @sizeOf(ManifestRouteEntry);
        try f.writePositionalAll(store.io, std.mem.sliceAsBytes(l0), off);
        off += l0.len * @sizeOf(root.KvEntry);
        try f.writePositionalAll(store.io, std.mem.sliceAsBytes(free_node), off);
        off += free_node.len * @sizeOf(u32);
        try f.writePositionalAll(store.io, std.mem.sliceAsBytes(free_sst), off);
        off += free_sst.len * @sizeOf(u32);
        try f.writePositionalAll(store.io, std.mem.sliceAsBytes(free_cmt), off);
        try f.sync(store.io);
    }
    try store.dir.rename("manifest.tmp", store.dir, "manifest.bin", store.io);
}

pub fn readManifest(store: DiskStore, allocator: std.mem.Allocator) !ManifestData {
    const f = try store.dir.openFile(store.io, "manifest.bin", .{});
    defer f.close(store.io);
    var off: u64 = 0;

    // Read the version-1 header prefix first; the v2 tail only exists on disk
    // when the version field says so.
    var header: ManifestHeader = .{
        .magic = 0,
        .version = 0,
        .next_node_id = 0,
        .next_sst_id = 0,
        .routing_count = 0,
        .l0_count = 0,
    };
    const head_bytes = std.mem.asBytes(&header);
    const hn = try f.readPositionalAll(store.io, head_bytes[0..MANIFEST_HEADER_V1_SIZE], off);
    if (hn != MANIFEST_HEADER_V1_SIZE) return error.ManifestTruncated;
    off += MANIFEST_HEADER_V1_SIZE;
    if (header.magic != MANIFEST_MAGIC) return error.ManifestBadMagic;
    switch (header.version) {
        1 => {},
        2 => {
            const tail = head_bytes[MANIFEST_HEADER_V1_SIZE..@sizeOf(ManifestHeader)];
            const tn = try f.readPositionalAll(store.io, tail, off);
            if (tn != tail.len) return error.ManifestTruncated;
            off += tail.len;
        },
        else => return error.ManifestVersionMismatch,
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
        off += l0.len * @sizeOf(root.KvEntry);
    }

    const free_node = try allocator.alloc(u32, header.free_node_count);
    errdefer allocator.free(free_node);
    const free_sst = try allocator.alloc(u32, header.free_sst_count);
    errdefer allocator.free(free_sst);
    const free_cmt = try allocator.alloc(u32, header.free_cmt_count);
    errdefer allocator.free(free_cmt);
    for ([_][]u32{ free_node, free_sst, free_cmt }) |list| {
        if (list.len == 0) continue;
        const n = try f.readPositionalAll(store.io, std.mem.sliceAsBytes(list), off);
        if (n != list.len * @sizeOf(u32)) return error.ManifestTruncated;
        off += list.len * @sizeOf(u32);
    }

    return .{
        .header = header,
        .routes = routes,
        .l0 = l0,
        .free_node = free_node,
        .free_sst = free_sst,
        .free_cmt = free_cmt,
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
const NODE_SORTED_IDS_OFF: u32 = 4;
const NODE_SORTED_MIN4_OFF: u32 = 420; // 4 + 416
const NODE_SORTED_COUNTS_OFF: u32 = 836; // 420 + 416
const NODE_APPEND_COUNTS_OFF: u32 = 940; // 836 + 104
const NODE_APPEND_IDS_OFF: u32 = 952; // 940 + 12
const NODE_APPEND_PREFIX32_OFF: u32 = 1000; // 952 + 48
// _reserved: 4072–4095 (24 B)

comptime {
    // Verify the on-disk layout totals exactly one physical page.
    const tail = NODE_APPEND_PREFIX32_OFF + root.A_MAX * root.PAGE_ENTRIES * 4 + 24;
    if (tail != NODE_PAGE_SIZE) @compileError("NodePage layout does not fit in 4096 bytes");
}

fn serialiseNodePage(page: *const root.NodePage, buf: *[NODE_PAGE_SIZE]u8) void {
    buf[0] = page.sorted_count;
    buf[1] = page.append_count;
    buf[2] = 0;
    buf[3] = 0;

    // sorted_slot_ids: 104 × u32, little-endian
    for (page.sorted_slot_ids, 0..) |id, i| {
        std.mem.writeInt(u32, buf[NODE_SORTED_IDS_OFF + i * 4 ..][0..4], id, .little);
    }

    // sorted_min4: 104 × u32, little-endian
    for (page.sorted_min4, 0..) |m, i| {
        std.mem.writeInt(u32, buf[NODE_SORTED_MIN4_OFF + i * 4 ..][0..4], m, .little);
    }

    // sorted_page_counts: 104 × u8
    @memcpy(buf[NODE_SORTED_COUNTS_OFF..][0..root.S_MAX], &page.sorted_page_counts);

    // append_page_counts: 12 × u8
    @memcpy(buf[NODE_APPEND_COUNTS_OFF..][0..root.A_MAX], &page.append_page_counts);

    // append_slot_ids: 12 × u32, little-endian
    for (page.append_slot_ids, 0..) |id, i| {
        std.mem.writeInt(u32, buf[NODE_APPEND_IDS_OFF + i * 4 ..][0..4], id, .little);
    }

    // append_prefix32: 12 × 64 × u32, little-endian; each row is 256 bytes
    for (page.append_prefix32, 0..) |row, pi| {
        for (row, 0..) |v, ki| {
            std.mem.writeInt(u32, buf[NODE_APPEND_PREFIX32_OFF + pi * 256 + ki * 4 ..][0..4], v, .little);
        }
    }

    // trailing reserved bytes
    @memset(buf[4072..4096], 0);
}

fn deserialiseNodePage(buf: *const [NODE_PAGE_SIZE]u8) root.NodePage {
    var page: root.NodePage = undefined;
    page.sorted_count = buf[0];
    page.append_count = buf[1];

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
            page.append_prefix32[pi][ki] = std.mem.readInt(u32, buf[NODE_APPEND_PREFIX32_OFF + pi * 256 + ki * 4 ..][0..4], .little);
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

// ─── Commitment page store (docs/commitment_redesign.md §3.1, §7) ─────────────

const CMT_PAGE_SIZE: u32 = 4096;
const CMT_VERSION: u8 = 1;
const CMT_LEAF_VALID_OFF: u32 = 4;
const CMT_HEAP_OFF: u32 = 32; // h[1..127] = 127 × 32 = 4064 B

comptime {
    if (CMT_HEAP_OFF + 127 * 32 != CMT_PAGE_SIZE)
        @compileError("CommitmentPage layout does not fit in 4096 bytes");
}

fn serialiseCmtPage(page: *const root.CommitmentPage, buf: *[CMT_PAGE_SIZE]u8) void {
    buf[0] = CMT_VERSION;
    buf[1] = 0; // flags
    buf[2] = 0;
    buf[3] = 0;
    std.mem.writeInt(u64, buf[CMT_LEAF_VALID_OFF..][0..8], page.leaf_valid, .little);
    @memset(buf[12..32], 0);
    // h[1..127]: endian-neutral 32-byte digests
    @memcpy(buf[CMT_HEAP_OFF..][0 .. 127 * 32], std.mem.asBytes(&page.h)[32 .. 128 * 32]);
}

fn deserialiseCmtPage(buf: *const [CMT_PAGE_SIZE]u8) root.CommitmentPage {
    var page = root.CommitmentPage.EMPTY;
    page.leaf_valid = std.mem.readInt(u64, buf[CMT_LEAF_VALID_OFF..][0..8], .little);
    @memcpy(std.mem.asBytes(&page.h)[32 .. 128 * 32], buf[CMT_HEAP_OFF..][0 .. 127 * 32]);
    return page;
}

/// Persistent store for commitment pages.  Container files are named
/// `cmt_XXXXXXXX.dat`; addressing is identical to NodePageStore.  Pages are
/// always written copy-on-write under fresh ids; the manifest checkpoint
/// repoints routing (logical identity = (depth, prefix), never the page id).
pub const CommitmentPageStore = struct {
    dir: Io.Dir,
    io: Io,

    pub fn init(dir: Io.Dir, io: Io) CommitmentPageStore {
        return .{ .dir = dir, .io = io };
    }

    pub fn write(self: *CommitmentPageStore, id: root.CommitmentPageId, page: *const root.CommitmentPage) !void {
        var buf: [CMT_PAGE_SIZE]u8 = undefined;
        serialiseCmtPage(page, &buf);
        const f = try self.openContainer(containerId(id), .write);
        defer f.close(self.io);
        try f.writePositionalAll(self.io, &buf, fileOffset(localPage(id)));
    }

    pub fn read(self: *CommitmentPageStore, id: root.CommitmentPageId) !root.CommitmentPage {
        var buf: [CMT_PAGE_SIZE]u8 = undefined;
        const f = try self.openContainer(containerId(id), .read);
        defer f.close(self.io);
        const n = try f.readPositionalAll(self.io, &buf, fileOffset(localPage(id)));
        if (n != CMT_PAGE_SIZE) return error.UnexpectedEof;
        return deserialiseCmtPage(&buf);
    }

    const OpenMode = enum { read, write };

    fn openContainer(self: *CommitmentPageStore, cid: u32, mode: OpenMode) !Io.File {
        var buf: [24]u8 = undefined;
        const name = try std.fmt.bufPrint(&buf, "cmt_{x:0>8}.dat", .{cid});
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
    page.sorted_slot_ids[0] = 42;
    page.sorted_slot_ids[1] = 99;
    page.sorted_min4[0] = 0x0000_1234;
    page.sorted_min4[1] = 0x0000_5678;
    page.append_slot_ids[0] = 7;
    // append_prefix32[0] — 64 u32 values for the one append page
    for (&page.append_prefix32[0], 0..) |*v, i| v.* = @intCast(i * 100_000);

    try store.write(0, &page);
    const got = try store.read(0);

    try std.testing.expectEqual(page.sorted_count, got.sorted_count);
    try std.testing.expectEqual(page.append_count, got.append_count);
    try std.testing.expectEqual(page.sorted_slot_ids[0], got.sorted_slot_ids[0]);
    try std.testing.expectEqual(page.sorted_slot_ids[1], got.sorted_slot_ids[1]);
    try std.testing.expectEqual(page.sorted_min4[0], got.sorted_min4[0]);
    try std.testing.expectEqual(page.sorted_min4[1], got.sorted_min4[1]);
    try std.testing.expectEqual(page.append_slot_ids[0], got.append_slot_ids[0]);
    try std.testing.expectEqualSlices(u32, &page.append_prefix32[0], &got.append_prefix32[0]);
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
    for (&page.sorted_page_counts, 0..) |*c, i| c.* = @intCast((i % 64) + 1);

    try store.write(0, &page);
    const got = try store.read(0);

    try std.testing.expectEqual(@as(u8, root.S_MAX), got.sorted_count);
    try std.testing.expectEqual(@as(u32, root.S_MAX - 1), got.sorted_slot_ids[root.S_MAX - 1]);
    try std.testing.expectEqual(@as(u32, (root.S_MAX - 1) * 0x100), got.sorted_min4[root.S_MAX - 1]);
    try std.testing.expectEqualSlices(u8, &page.sorted_page_counts, &got.sorted_page_counts);
}

test "NodePageStore round-trip — full append zone" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = NodePageStore.init(tmp.dir, std.testing.io);

    var page = std.mem.zeroes(root.NodePage);
    page.sorted_count = 0;
    page.append_count = root.A_MAX;
    for (&page.append_slot_ids, 0..) |*id, i| id.* = @intCast(1000 + i);
    // Fill all 12 × 64 prefix32 entries with recognisable values.
    for (&page.append_prefix32, 0..) |*row, pi| {
        for (row, 0..) |*v, ki| v.* = @intCast(pi * 1_000_000 + ki);
    }

    try store.write(1, &page);
    const got = try store.read(1);

    try std.testing.expectEqual(@as(u8, root.A_MAX), got.append_count);
    for (0..root.A_MAX) |pi| {
        try std.testing.expectEqual(@as(u32, 1000) + @as(u32, @intCast(pi)), got.append_slot_ids[pi]);
        try std.testing.expectEqualSlices(u32, &page.append_prefix32[pi], &got.append_prefix32[pi]);
    }
}

test "NodePageStore pages across containers" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = NodePageStore.init(tmp.dir, std.testing.io);

    var p0 = std.mem.zeroes(root.NodePage);
    p0.sorted_count = 1;
    p0.sorted_min4[0] = 0x1111_1111;

    var p1 = std.mem.zeroes(root.NodePage);
    p1.sorted_count = 2;
    p1.sorted_min4[0] = 0x2222_2222;

    const id0: root.NodePageId = (0 << 20) | 0;
    const id1: root.NodePageId = (1 << 20) | 0;
    try store.write(id0, &p0);
    try store.write(id1, &p1);

    const g0 = try store.read(id0);
    const g1 = try store.read(id1);
    try std.testing.expectEqual(@as(u8, 1), g0.sorted_count);
    try std.testing.expectEqual(@as(u8, 2), g1.sorted_count);
    try std.testing.expectEqual(p0.sorted_min4[0], g0.sorted_min4[0]);
    try std.testing.expectEqual(p1.sorted_min4[0], g1.sorted_min4[0]);
}

test "CommitmentPageStore write and read round-trip" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = CommitmentPageStore.init(tmp.dir, std.testing.io);

    var page = root.CommitmentPage.EMPTY;
    page.leaf_valid = 0xDEAD_BEEF_CAFE_F00D;
    page.h[1] = [_]u8{0x11} ** 32;
    page.h[64] = [_]u8{0x40} ** 32;
    page.h[127] = [_]u8{0x7F} ** 32;

    try store.write(5, &page);
    const got = try store.read(5);

    try std.testing.expectEqual(page.leaf_valid, got.leaf_valid);
    try std.testing.expectEqual(page.h[1], got.h[1]);
    try std.testing.expectEqual(page.h[64], got.h[64]);
    try std.testing.expectEqual(page.h[127], got.h[127]);
    // h[0] is padding and must come back zeroed.
    try std.testing.expectEqual(root.ZERO_HASH, got.h[0]);
}
