//! Batched positional reads over the `std.Io` interface — the flat-store read path.
//!
//! Why this exists (see docs/prefix_redesign.md §2): a heavy block does ~12 K state
//! reads, and on the flat store most cold lookups are a single ~90 µs window read.
//! Issued serially that is ~1.08 s per block — over the execution budget by ~5×.
//! The fix is to issue a block's reads *concurrently* and await them as one batch;
//! the required in-flight depth is only rate × latency (≈6 today, ≈45 at the scaled
//! target), trivially within an io_uring ring.
//!
//! Rather than hand-roll an io_uring ring, this rides `std.Io`'s async model: each
//! request is an `Io.Group` task and the whole group is awaited at once. When the
//! process `Io` is `std.Io.Uring`, the group's tasks become concurrent SQEs
//! submitted together (true batched io_uring); under a blocking/threaded `Io`
//! (e.g. tests) the same code is correct, just serialized. The read path therefore
//! stays backend-agnostic and unit-testable without io_uring, and is independent of
//! the flat-store layout still being finalized — it only deals in (file, offset,
//! buffer). Window sizing and record location sit in a layer above this.

const std = @import("std");
const Io = std.Io;

/// One positional read: fill `buffer` from `file` starting at byte `offset`.
/// `file` must stay open and `buffer` must stay alive for the whole `readBatch`
/// call (the buffer is written by a concurrent task).
pub const Request = struct {
    file: Io.File,
    buffer: []u8,
    offset: u64,
};

/// Per-request outcome: bytes read (a value `< buffer.len` means EOF was hit), or
/// the I/O error for that one request. `error.Canceled` indicates the batch was
/// canceled before this request's task ran.
pub const Result = Io.File.ReadPositionalError!usize;

fn readOne(io: Io, req: Request, out: *Result) void {
    out.* = req.file.readPositionalAll(io, req.buffer, req.offset);
}

/// Issue every request concurrently, then block until all complete.
///
/// `results[i]` receives the outcome of `reqs[i]`; the slices must be the same
/// length. A single request failing is reported in its `results` slot and does
/// NOT fail the batch — callers inspect each slot. Only batch-level cancelation
/// propagates out of this function.
pub fn readBatch(io: Io, reqs: []const Request, results: []Result) Io.Cancelable!void {
    std.debug.assert(reqs.len == results.len);
    if (reqs.len == 0) return;

    // Sentinel: any request whose task never runs (cancelation) is observable
    // as error.Canceled rather than reading uninitialized memory.
    for (results) |*r| r.* = error.Canceled;

    var group: Io.Group = .init;
    for (reqs, results) |req, *res| {
        group.async(io, readOne, .{ io, req, res });
    }
    return group.await(io);
}

// ─── Tests ──────────────────────────────────────────────────────────────────────

const PAGE: usize = 4096;

test "readBatch fills buffers for reads issued out of order" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const num_pages = 8;

    // Write `num_pages` pages; page p is filled with the byte value p.
    {
        const wf = try tmp.dir.createFile(io, "data.dat", .{ .truncate = true });
        defer wf.close(io);
        var page: [PAGE]u8 = undefined;
        for (0..num_pages) |p| {
            @memset(&page, @intCast(p));
            try wf.writePositionalAll(io, &page, @as(u64, p) * PAGE);
        }
    }

    const rf = try tmp.dir.openFile(io, "data.dat", .{});
    defer rf.close(io);

    // Read the pages in a shuffled order, each into its own buffer.
    const order = [_]usize{ 5, 0, 7, 2, 4, 1, 6, 3 };
    var bufs: [num_pages][PAGE]u8 = undefined;
    var reqs: [num_pages]Request = undefined;
    var results: [num_pages]Result = undefined;
    for (order, 0..) |p, i| {
        reqs[i] = .{ .file = rf, .buffer = &bufs[i], .offset = @as(u64, p) * PAGE };
    }

    try readBatch(io, &reqs, &results);

    for (order, 0..) |p, i| {
        const n = try results[i];
        try std.testing.expectEqual(PAGE, n);
        var expected: [PAGE]u8 = undefined;
        @memset(&expected, @intCast(p));
        try std.testing.expectEqualSlices(u8, &expected, &bufs[i]);
    }
}

test "readBatch reports short read past EOF per-slot without failing the batch" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // One page on disk.
    {
        const wf = try tmp.dir.createFile(io, "one.dat", .{ .truncate = true });
        defer wf.close(io);
        var page: [PAGE]u8 = undefined;
        @memset(&page, 0xAB);
        try wf.writePositionalAll(io, &page, 0);
    }

    const rf = try tmp.dir.openFile(io, "one.dat", .{});
    defer rf.close(io);

    var buf_ok: [PAGE]u8 = undefined;
    var buf_eof: [PAGE]u8 = undefined;
    const reqs = [_]Request{
        .{ .file = rf, .buffer = &buf_ok, .offset = 0 }, // valid page
        .{ .file = rf, .buffer = &buf_eof, .offset = 10 * PAGE }, // entirely past EOF
    };
    var results: [2]Result = undefined;

    try readBatch(io, &reqs, &results);

    try std.testing.expectEqual(PAGE, try results[0]);
    try std.testing.expectEqual(@as(usize, 0), try results[1]); // 0 bytes at EOF
}

test "readBatch on empty request list is a no-op" {
    const io = std.testing.io;
    const reqs = [_]Request{};
    var results = [_]Result{};
    try readBatch(io, &reqs, &results);
}
