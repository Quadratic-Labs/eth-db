//! Streaming bulk loader: build a FlatStore base directly from large
//! storage-<block>.tsv files, without holding the dataset in RAM and without the
//! Python bindings.
//!
//! TSV row (whitespace/tab separated):  address  slot  value  keccak256(slot)
//! The 4th column is ignored. Key = sha256(address[20] || slot[32]) — identical to
//! benchmark_flat.py / seed_flat.py so the benchmark hits the seeded keys.
//!
//! Algorithm — external BUCKET sort (scales past RAM, no merge heap):
//!   pass 1: stream rows, derive (key, seq, value), append to one of 2^Q bucket spill
//!           files chosen by the key's top Q bits; reservoir-sample M keys for the bench.
//!   pass 2: for each bucket in prefix order, read it, sort by (key, seq), keep the
//!           newest value per key (seq = global row order), and stream into a BaseBuilder.
//!   Concatenating buckets in prefix order yields globally key-sorted output.
//!
//! Output in --db-dir: the FlatStore (flat.base.0 + flat.manifest) and sample.keys
//! (M frequency-weighted keys for the Zig benchmark). Pick --buckets so each bucket
//! fits in RAM (bucket ≈ total / buckets).
//!
//! Usage:  zig build bulkload -- --db-dir /mnt/big/flatdb --prefix-bits 24 storage-*.tsv

const std = @import("std");
const eth = @import("eth_db");
const flat = eth.flat_store;
const Io = std.Io;
const Sha256 = std.crypto.hash.sha2.Sha256;

const SortRec = extern struct { key: [32]u8, value: [32]u8, seq: u64 };
const BUCKET_BUF = 64 * 1024;

fn recLess(_: void, a: SortRec, b: SortRec) bool {
    return switch (std.mem.order(u8, &a.key, &b.key)) {
        .lt => true,
        .gt => false,
        .eq => a.seq < b.seq,
    };
}

fn hexVal(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

/// Parse a hex string (optional 0x) into `out`, right-aligned and zero-padded.
fn parseHexRight(out: []u8, hex_in: []const u8) bool {
    @memset(out, 0);
    var hex = hex_in;
    if (hex.len >= 2 and hex[0] == '0' and (hex[1] == 'x' or hex[1] == 'X')) hex = hex[2..];
    if (hex.len > out.len * 2) return false;
    var oi = out.len;
    var i = hex.len;
    while (i > 0) {
        const lo = hexVal(hex[i - 1]) orelse return false;
        i -= 1;
        var byte: u8 = lo;
        if (i > 0) {
            const hi = hexVal(hex[i - 1]) orelse return false;
            i -= 1;
            byte |= hi << 4;
        }
        oi -= 1;
        out[oi] = byte;
    }
    return true;
}

/// Extract the block number from a "…storage-<N>.tsv" path (0 if absent).
fn blockNum(path: []const u8) u64 {
    const marker = "storage-";
    const at = std.mem.lastIndexOf(u8, path, marker) orelse return 0;
    var i = at + marker.len;
    var n: u64 = 0;
    var any = false;
    while (i < path.len and path[i] >= '0' and path[i] <= '9') : (i += 1) {
        n = n * 10 + (path[i] - '0');
        any = true;
    }
    return if (any) n else 0;
}

/// Chunked line reader over an Io.File (handles lines spanning read boundaries).
const Lines = struct {
    f: Io.File,
    io: Io,
    buf: []u8,
    off: u64 = 0,
    fill: usize = 0,
    pos: usize = 0,
    eof: bool = false,

    fn next(self: *Lines) !?[]const u8 {
        while (true) {
            if (std.mem.indexOfScalarPos(u8, self.buf[0..self.fill], self.pos, '\n')) |nl| {
                const line = self.buf[self.pos..nl];
                self.pos = nl + 1;
                return line;
            }
            if (self.eof) {
                if (self.pos < self.fill) {
                    const line = self.buf[self.pos..self.fill];
                    self.pos = self.fill;
                    return line;
                }
                return null;
            }
            const rem = self.fill - self.pos;
            std.mem.copyForwards(u8, self.buf[0..rem], self.buf[self.pos..self.fill]);
            self.fill = rem;
            self.pos = 0;
            if (self.fill == self.buf.len) return error.LineTooLong;
            const n = try self.f.readPositionalAll(self.io, self.buf[self.fill..], self.off);
            self.off += n;
            self.fill += n;
            if (n == 0) self.eof = true;
        }
    }
};

const Args = struct {
    db_dir: []const u8,
    inputs: [][]const u8,
    prefix_bits: u6 = 24,
    bucket_bits: u6 = 8, // 2^8 = 256 buckets
    sample_n: usize = 2_000_000,
    seed: u64 = 0,
};

fn usage() noreturn {
    std.debug.print(
        \\usage: bulkload --db-dir DIR [--prefix-bits N] [--buckets N] [--sample N] [--seed N] FILE...
        \\  FILE...        storage-<block>.tsv files (processed in block order)
        \\  --db-dir DIR   output FlatStore directory (created if absent)
        \\  --prefix-bits  partition prefix width (default 24)
        \\  --buckets      number of external-sort buckets, rounded up to a power of two (default 256)
        \\  --sample       frequency-weighted keys to sample for the benchmark (default 2000000)
        \\
    , .{});
    std.process.exit(2);
}

fn parseArgs(gpa: std.mem.Allocator, argv: []const []const u8) !Args {
    var db_dir: ?[]const u8 = null;
    var prefix_bits: u6 = 24;
    var buckets: usize = 256;
    var sample_n: usize = 2_000_000;
    var seed: u64 = 0;
    var inputs = std.ArrayList([]const u8).empty;
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (std.mem.eql(u8, a, "--db-dir")) {
            i += 1;
            if (i >= argv.len) usage();
            db_dir = argv[i];
        } else if (std.mem.eql(u8, a, "--prefix-bits")) {
            i += 1;
            if (i >= argv.len) usage();
            prefix_bits = @intCast(try std.fmt.parseInt(u8, argv[i], 10));
        } else if (std.mem.eql(u8, a, "--buckets")) {
            i += 1;
            if (i >= argv.len) usage();
            buckets = try std.fmt.parseInt(usize, argv[i], 10);
        } else if (std.mem.eql(u8, a, "--sample")) {
            i += 1;
            if (i >= argv.len) usage();
            sample_n = try std.fmt.parseInt(usize, argv[i], 10);
        } else if (std.mem.eql(u8, a, "--seed")) {
            i += 1;
            if (i >= argv.len) usage();
            seed = try std.fmt.parseInt(u64, argv[i], 10);
        } else if (std.mem.startsWith(u8, a, "--")) {
            usage();
        } else {
            try inputs.append(gpa, a);
        }
    }
    if (db_dir == null or inputs.items.len == 0) usage();
    // Sort inputs by block number so later blocks overwrite earlier (last write wins).
    std.mem.sort([]const u8, inputs.items, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return blockNum(x) < blockNum(y);
        }
    }.lt);
    const bb: u6 = @intCast(std.math.log2_int_ceil(usize, @max(buckets, 1)));
    return .{ .db_dir = db_dir.?, .inputs = inputs.items, .prefix_bits = prefix_bits, .bucket_bits = bb, .sample_n = sample_n, .seed = seed };
}

/// Bucket index = top `bucket_bits` of the key.
fn bucketOf(key: *const [32]u8, bucket_bits: u6) usize {
    if (bucket_bits == 0) return 0;
    var v: u64 = 0;
    inline for (0..8) |k| v = (v << 8) | key[k];
    return @intCast(v >> @as(u6, @intCast(@as(u32, 64) - bucket_bits)));
}

pub fn main(init: std.process.Init) !void {
    const gpa = std.heap.smp_allocator;
    const io = init.io;

    var arglist = std.ArrayList([]const u8).empty;
    defer arglist.deinit(gpa);
    var arg_it = std.process.Args.Iterator.init(init.minimal.args);
    while (arg_it.next()) |a| try arglist.append(gpa, a);
    const args = try parseArgs(gpa, arglist.items);

    const dir = try std.Io.Dir.cwd().createDirPathOpen(io, args.db_dir, .{});
    const tmp = try dir.createDirPathOpen(io, "bulktmp", .{});

    const nbuckets = @as(usize, 1) << args.bucket_bits;

    // ── Pass 1: bucket the rows + reservoir-sample keys ──────────────────────────
    const bucket_files = try gpa.alloc(Io.File, nbuckets);
    defer gpa.free(bucket_files);
    const bucket_off = try gpa.alloc(u64, nbuckets);
    defer gpa.free(bucket_off);
    const bucket_bufs = try gpa.alloc(u8, nbuckets * BUCKET_BUF);
    defer gpa.free(bucket_bufs);
    const bucket_len = try gpa.alloc(usize, nbuckets);
    defer gpa.free(bucket_len);
    for (0..nbuckets) |b| {
        var nb: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&nb, "b{d}", .{b});
        bucket_files[b] = try tmp.createFile(io, name, .{ .truncate = true });
        bucket_off[b] = 0;
        bucket_len[b] = 0;
    }

    const sample = try gpa.alloc([32]u8, args.sample_n);
    defer gpa.free(sample);
    var sample_filled: usize = 0;
    var prng = std.Random.DefaultPrng.init(args.seed);
    const rnd = prng.random();

    const line_buf = try gpa.alloc(u8, 1 << 20);
    defer gpa.free(line_buf);

    var rows: u64 = 0;
    var bad: u64 = 0;
    var seq: u64 = 0;
    var max_block: u64 = 0;

    for (args.inputs) |path| {
        max_block = @max(max_block, blockNum(path));
        const f = std.Io.Dir.cwd().openFile(io, path, .{}) catch |e| {
            std.debug.print("skip {s}: {s}\n", .{ path, @errorName(e) });
            continue;
        };
        defer f.close(io);
        var lines = Lines{ .f = f, .io = io, .buf = line_buf };
        while (try lines.next()) |line| {
            var it = std.mem.tokenizeAny(u8, line, " \t\r");
            const f0 = it.next() orelse continue;
            const f1 = it.next() orelse {
                bad += 1;
                continue;
            };
            const f2 = it.next() orelse {
                bad += 1;
                continue;
            };
            var rec: SortRec = undefined;
            var addr: [20]u8 = undefined;
            var keybytes: [52]u8 = undefined;
            if (!parseHexRight(&addr, f0) or !parseHexRight(keybytes[20..52], f1) or !parseHexRight(&rec.value, f2)) {
                bad += 1;
                continue;
            }
            @memcpy(keybytes[0..20], &addr);
            Sha256.hash(&keybytes, &rec.key, .{});
            rec.seq = seq;
            seq += 1;

            // Reservoir sample over rows ⇒ a frequency-weighted key sample.
            if (sample_filled < args.sample_n) {
                sample[sample_filled] = rec.key;
                sample_filled += 1;
            } else {
                const j = rnd.uintLessThan(u64, rows + 1);
                if (j < args.sample_n) sample[@intCast(j)] = rec.key;
            }

            // Append to its bucket spill (flush the bucket buffer when full).
            const b = bucketOf(&rec.key, args.bucket_bits);
            if (bucket_len[b] + @sizeOf(SortRec) > BUCKET_BUF) {
                try bucket_files[b].writePositionalAll(io, bucket_bufs[b * BUCKET_BUF ..][0..bucket_len[b]], bucket_off[b]);
                bucket_off[b] += bucket_len[b];
                bucket_len[b] = 0;
            }
            @memcpy(bucket_bufs[b * BUCKET_BUF + bucket_len[b] ..][0..@sizeOf(SortRec)], std.mem.asBytes(&rec));
            bucket_len[b] += @sizeOf(SortRec);
            rows += 1;
        }
    }
    // Flush + close bucket files.
    for (0..nbuckets) |b| {
        if (bucket_len[b] > 0) {
            try bucket_files[b].writePositionalAll(io, bucket_bufs[b * BUCKET_BUF ..][0..bucket_len[b]], bucket_off[b]);
            bucket_off[b] += bucket_len[b];
        }
        bucket_files[b].close(io);
    }
    std.debug.print("pass 1: {d} rows ({d} bad) across {d} buckets\n", .{ rows, bad, nbuckets });

    // ── Pass 2: sort each bucket, dedup newest-per-key, stream into the base ─────
    var bb = try flat.BaseBuilder.init(gpa, io, dir, "flat", args.prefix_bits, 0);
    defer bb.deinit();

    for (0..nbuckets) |b| {
        const nbytes = bucket_off[b];
        if (nbytes == 0) continue;
        const count: usize = @intCast(nbytes / @sizeOf(SortRec));
        const recs = try gpa.alloc(SortRec, count);
        defer gpa.free(recs);
        var nb: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&nb, "b{d}", .{b});
        {
            const rf = try tmp.openFile(io, name, .{});
            defer rf.close(io);
            const got = try rf.readPositionalAll(io, std.mem.sliceAsBytes(recs), 0);
            if (got != nbytes) return error.BucketTruncated;
        }
        std.mem.sort(SortRec, recs, {}, recLess);
        var i: usize = 0;
        while (i < recs.len) {
            var j = i + 1;
            while (j < recs.len and std.mem.eql(u8, &recs[j].key, &recs[i].key)) j += 1;
            try bb.feed(&recs[j - 1].key, &recs[j - 1].value); // newest (max seq) for this key
            i = j;
        }
        tmp.deleteFile(io, name) catch {};
    }
    try bb.finish(max_block);

    // ── Write the benchmark key sample ───────────────────────────────────────────
    {
        const sf = try dir.createFile(io, "sample.keys", .{ .truncate = true });
        defer sf.close(io);
        try sf.writePositionalAll(io, std.mem.sliceAsBytes(sample[0..sample_filled]), 0);
        try sf.sync(io);
    }

    std.debug.print(
        "done: {d} rows -> {d} base records, sample={d}, covered_height={d}, dir={s}\n",
        .{ rows, bb.out_count, sample_filled, max_block, args.db_dir },
    );
}
