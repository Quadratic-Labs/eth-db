//! Low-level io_uring batched reads for the flat-store hot path.
//!
//! Why low-level (see docs/prefix_redesign.md §9 and the toolchain note): the
//! high-level `std.Io.Uring` backend is unusable in the pinned Zig 0.16.0 — it
//! fails to compile (a std error-set bug) and, even when patched, deadlocks at
//! runtime (immature evented entry model). The long-standing
//! `std.os.linux.IoUring` binding, by contrast, works on this kernel today
//! (verified: 8 SQEs / 1 submit / 8 CQEs). So this is the production io_uring
//! reader; `batch_read.zig` (built on `Io.Group`) remains the portable fallback
//! that runs on the threaded `Io` backend.
//!
//! The design need (§2): a heavy block issues ~12 K reads; serialized at ~90 µs
//! each that is ~1 s, over the execution budget. Issuing the reads as one io_uring
//! batch keeps only `rate × latency` (≈6–45) in flight and submits them together.
//!
//! Semantics: each request is a single positional read. `results[i]` reports the
//! bytes read — a value `< buffer.len` means EOF / short read; the higher (flat-
//! store) layer handles a short tail. Completions are matched back to requests by
//! `user_data`, so out-of-order completion is handled correctly. The ring is not
//! thread-safe: use one `Reader` per thread.

const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;

comptime {
    if (builtin.os.tag != .linux)
        @compileError("uring_read is Linux-only; use batch_read.zig for portability");
}

/// One positional read: fill `buffer` from `fd` starting at byte `offset`.
/// `fd` must stay open and `buffer` alive for the whole `readBatch` call.
pub const Request = struct {
    fd: linux.fd_t,
    buffer: []u8,
    offset: u64,
};

pub const ReadError = error{
    InputOutput,
    WouldBlock,
    Canceled,
    BadFileDescriptor,
    Unexpected,
};

/// Per-request outcome: bytes read (`< buffer.len` ⇒ EOF/short), or its error.
pub const Result = ReadError!usize;

/// Ring depth must be a power of two (`IoUring.init` requires it). 256 gives
/// plenty of in-flight depth for a block's read fan-out; larger batches are
/// split across successive submits transparently.
pub const DEFAULT_QUEUE_DEPTH: u16 = 256;

pub const Reader = struct {
    ring: linux.IoUring,
    depth: u16,

    /// `queue_depth` must be a power of two.
    pub fn init(queue_depth: u16) !Reader {
        std.debug.assert(std.math.isPowerOfTwo(queue_depth));
        return .{ .ring = try linux.IoUring.init(queue_depth, 0), .depth = queue_depth };
    }

    pub fn deinit(self: *Reader) void {
        self.ring.deinit();
    }

    /// Issue every request via io_uring and block until all complete.
    /// `results[i]` receives the outcome of `reqs[i]`; the slices must be the
    /// same length. A request failing is reported in its slot, not raised. Only
    /// a failure to drive the ring itself (submit/copy_cqe) is returned as an
    /// error. Batches larger than the ring depth run as successive submits.
    pub fn readBatch(self: *Reader, reqs: []const Request, results: []Result) !void {
        std.debug.assert(reqs.len == results.len);

        var base: usize = 0;
        while (base < reqs.len) {
            const chunk = @min(reqs.len - base, self.depth);

            for (0..chunk) |k| {
                const i = base + k;
                // user_data = global request index, so out-of-order completions
                // are matched back to the correct result slot.
                _ = try self.ring.read(@intCast(i), reqs[i].fd, .{ .buffer = reqs[i].buffer }, reqs[i].offset);
            }

            _ = try self.ring.submit_and_wait(@intCast(chunk));

            for (0..chunk) |_| {
                const cqe = try self.ring.copy_cqe();
                const i: usize = @intCast(cqe.user_data);
                results[i] = cqeToResult(cqe.res);
            }

            base += chunk;
        }
    }
};

/// Map an io_uring CQE `res` (bytes read when ≥ 0, else `-errno`) to a Result.
fn cqeToResult(res: i32) Result {
    if (res >= 0) return @intCast(res);
    const e: linux.E = @enumFromInt(@as(u16, @intCast(-res)));
    return switch (e) {
        .IO => error.InputOutput,
        .AGAIN => error.WouldBlock,
        .CANCELED => error.Canceled,
        .BADF => error.BadFileDescriptor,
        else => error.Unexpected,
    };
}

// ─── Tests ──────────────────────────────────────────────────────────────────────

const PAGE: usize = 4096;

/// Write `num_pages` pages (page p filled with byte p) into a fresh temp file via
/// the portable Io path, then return an fd opened for reading. Caller closes fd
/// (via linux.close) and the file handle, and cleans up `tmp`.
fn makePagedFile(io: std.Io, dir: std.Io.Dir, name: []const u8, num_pages: usize) !std.Io.File {
    const wf = try dir.createFile(io, name, .{ .truncate = true });
    defer wf.close(io);
    var page: [PAGE]u8 = undefined;
    for (0..num_pages) |p| {
        @memset(&page, @intCast(p));
        try wf.writePositionalAll(io, &page, @as(u64, p) * PAGE);
    }
    return dir.openFile(io, name, .{});
}

test "Reader.readBatch reads pages out of order via a real io_uring ring" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const num_pages = 8;
    const rf = try makePagedFile(io, tmp.dir, "u.dat", num_pages);
    defer rf.close(io);

    var reader = try Reader.init(DEFAULT_QUEUE_DEPTH);
    defer reader.deinit();

    const order = [_]usize{ 5, 0, 7, 2, 4, 1, 6, 3 };
    var bufs: [num_pages][PAGE]u8 = undefined;
    var reqs: [num_pages]Request = undefined;
    var results: [num_pages]Result = undefined;
    for (order, 0..) |p, i| {
        reqs[i] = .{ .fd = rf.handle, .buffer = &bufs[i], .offset = @as(u64, p) * PAGE };
    }

    try reader.readBatch(&reqs, &results);

    for (order, 0..) |p, i| {
        try std.testing.expectEqual(PAGE, try results[i]);
        var expected: [PAGE]u8 = undefined;
        @memset(&expected, @intCast(p));
        try std.testing.expectEqualSlices(u8, &expected, &bufs[i]);
    }
}

test "Reader.readBatch splits a batch larger than the ring depth" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const num_pages = 8;
    const rf = try makePagedFile(io, tmp.dir, "u.dat", num_pages);
    defer rf.close(io);

    var reader = try Reader.init(4); // depth 4 < 8 ⇒ two submits
    defer reader.deinit();

    var bufs: [num_pages][PAGE]u8 = undefined;
    var reqs: [num_pages]Request = undefined;
    var results: [num_pages]Result = undefined;
    for (0..num_pages) |p| {
        reqs[p] = .{ .fd = rf.handle, .buffer = &bufs[p], .offset = @as(u64, p) * PAGE };
    }

    try reader.readBatch(&reqs, &results);

    for (0..num_pages) |p| {
        try std.testing.expectEqual(PAGE, try results[p]);
        try std.testing.expectEqual(@as(u8, @intCast(p)), bufs[p][0]);
        try std.testing.expectEqual(@as(u8, @intCast(p)), bufs[p][PAGE - 1]);
    }
}

test "Reader.readBatch reports per-request errors and EOF without failing the batch" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const rf = try makePagedFile(io, tmp.dir, "u.dat", 1); // one page on disk
    defer rf.close(io);

    var reader = try Reader.init(DEFAULT_QUEUE_DEPTH);
    defer reader.deinit();

    var buf_ok: [PAGE]u8 = undefined;
    var buf_eof: [PAGE]u8 = undefined;
    var buf_bad: [PAGE]u8 = undefined;
    const reqs = [_]Request{
        .{ .fd = rf.handle, .buffer = &buf_ok, .offset = 0 }, // valid
        .{ .fd = rf.handle, .buffer = &buf_eof, .offset = 100 * PAGE }, // past EOF
        .{ .fd = -1, .buffer = &buf_bad, .offset = 0 }, // bad fd
    };
    var results: [3]Result = undefined;

    try reader.readBatch(&reqs, &results);

    try std.testing.expectEqual(PAGE, try results[0]);
    try std.testing.expectEqual(@as(usize, 0), try results[1]); // EOF ⇒ 0 bytes
    try std.testing.expectError(error.BadFileDescriptor, results[2]);
}

test "Reader.readBatch on an empty request list is a no-op" {
    var reader = try Reader.init(DEFAULT_QUEUE_DEPTH);
    defer reader.deinit();
    const reqs = [_]Request{};
    var results = [_]Result{};
    try reader.readBatch(&reqs, &results);
}
