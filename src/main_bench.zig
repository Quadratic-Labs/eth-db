//! Benchmark a (seeded) FlatStore with a workload drawn from the TSV access
//! distribution — no Python bindings, so it measures the engine itself.
//!
//! It opens the store at --db-dir and loads `sample.keys` (the frequency-weighted key
//! sample emitted by the bulk loader). Sampling uniformly from that pool reproduces the
//! TSV's account/slot access distribution; a `--new-prob` fraction of accesses use fresh
//! random keys (new accounts / state growth → cold misses). Per block it issues reads
//! (which HIT the seeded base) and writes, then ends the block (block-aligned freeze) and
//! spends one idle-window compaction budget if due.
//!
//! Modes:
//!   default        one get/put per access (per-op latency; effective io_uring QD ≈ 1)
//!   --bal-prefetch prefetch the whole block read set in one io_uring batch (deep QD),
//!                  then execute from RAM — read-your-writes preserved by the memtable
//!   --o-direct     open the hot read fd with O_DIRECT (bypass page cache → cold reads)
//!
//! Usage:
//!   zig build bench -- --db-dir /mnt/big/flatdb -n 5000 --read-prob 0.75 --bal-prefetch --o-direct

const std = @import("std");
const eth = @import("eth_db");
const flat = eth.flat_store;
const Io = std.Io;
const linux = std.os.linux;
const Key = [32]u8;
const Value = [32]u8;

fn nowNs() i128 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(i128, ts.sec) * std.time.ns_per_s + ts.nsec;
}

// Microsecond-bucket latency histogram (last bucket = overflow).
const HBUCKETS = 4096;
const Hist = struct {
    b: [HBUCKETS]u64 = [_]u64{0} ** HBUCKETS,
    n: u64 = 0,
    sum_ns: u128 = 0,

    fn record(self: *Hist, ns: i128) void {
        self.n += 1;
        self.sum_ns += @intCast(ns);
        var us: usize = @intCast(@divFloor(ns, 1000));
        if (us >= HBUCKETS) us = HBUCKETS - 1;
        self.b[us] += 1;
    }
    fn meanUs(self: *const Hist) f64 {
        if (self.n == 0) return 0;
        return @as(f64, @floatFromInt(self.sum_ns)) / @as(f64, @floatFromInt(self.n)) / 1000.0;
    }
    fn pctUs(self: *const Hist, p: f64) f64 {
        if (self.n == 0) return 0;
        const target: u64 = @intFromFloat(@as(f64, @floatFromInt(self.n)) * p / 100.0);
        var cum: u64 = 0;
        for (self.b, 0..) |c, i| {
            cum += c;
            if (cum >= target) return @floatFromInt(i);
        }
        return HBUCKETS;
    }
};

const Args = struct {
    db_dir: []const u8,
    blocks: u64 = 1000,
    block_size: usize = 16000,
    read_prob: f64 = 0.75,
    new_prob: f64 = 0.01,
    seed: u64 = 42,
    bal_prefetch: bool = false,
    o_direct: bool = false,
    window_entries: usize = 0,
    fence_gap: u32 = 0,
    memtable_cap: usize = 0,
    l0_threshold: usize = 0,
    freeze_interval: u64 = 0,
    compact_budget: usize = 256 << 20,
    print_every: u64 = 50,
};

fn usage() noreturn {
    std.debug.print(
        \\usage: bench --db-dir DIR [options]
        \\  -n, --blocks N        number of blocks (default 1000)
        \\  --block-size N        accesses per block (default 16000)
        \\  --read-prob F         fraction of accesses that are reads (default 0.75)
        \\  --new-prob F          fraction using a fresh random key (default 0.01)
        \\  --bal-prefetch        prefetch the block read set in one io_uring batch
        \\  --o-direct            open hot reads with O_DIRECT (cold reads)
        \\  --window-entries N    interpolation window size in entries (0 = engine default
        \\                        1024 = 64 KiB); structural — only takes effect when
        \\                        creating a fresh store, ignored on recovery (from manifest)
        \\  --fence-gap G         G-gated fence index: keep every G-th base key (8 B) in
        \\                        RAM and read exactly one G-record run per lookup instead
        \\                        of interpolation (G=64 = one 4 KiB read). 0 = G=∞ (no
        \\                        index, wide-window interpolation). Pure RAM policy —
        \\                        effective on every open, no store rebuild needed
        \\  --memtable-cap N --l0-threshold N --freeze-interval N --compact-budget BYTES
        \\  --seed N --print-every N
        \\
    , .{});
    std.process.exit(2);
}

fn parseArgs(argv: []const []const u8) !Args {
    var a = Args{ .db_dir = "" };
    var have_dir = false;
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const s = argv[i];
        const eat = struct {
            fn next(idx: *usize, av: []const []const u8) []const u8 {
                idx.* += 1;
                if (idx.* >= av.len) usage();
                return av[idx.*];
            }
        }.next;
        if (std.mem.eql(u8, s, "--db-dir")) {
            a.db_dir = eat(&i, argv);
            have_dir = true;
        } else if (std.mem.eql(u8, s, "-n") or std.mem.eql(u8, s, "--blocks")) {
            a.blocks = try std.fmt.parseInt(u64, eat(&i, argv), 10);
        } else if (std.mem.eql(u8, s, "--block-size")) {
            a.block_size = try std.fmt.parseInt(usize, eat(&i, argv), 10);
        } else if (std.mem.eql(u8, s, "--read-prob")) {
            a.read_prob = try std.fmt.parseFloat(f64, eat(&i, argv));
        } else if (std.mem.eql(u8, s, "--new-prob")) {
            a.new_prob = try std.fmt.parseFloat(f64, eat(&i, argv));
        } else if (std.mem.eql(u8, s, "--seed")) {
            a.seed = try std.fmt.parseInt(u64, eat(&i, argv), 10);
        } else if (std.mem.eql(u8, s, "--bal-prefetch")) {
            a.bal_prefetch = true;
        } else if (std.mem.eql(u8, s, "--o-direct")) {
            a.o_direct = true;
        } else if (std.mem.eql(u8, s, "--window-entries")) {
            a.window_entries = try std.fmt.parseInt(usize, eat(&i, argv), 10);
        } else if (std.mem.eql(u8, s, "--fence-gap")) {
            a.fence_gap = try std.fmt.parseInt(u32, eat(&i, argv), 10);
        } else if (std.mem.eql(u8, s, "--memtable-cap")) {
            a.memtable_cap = try std.fmt.parseInt(usize, eat(&i, argv), 10);
        } else if (std.mem.eql(u8, s, "--l0-threshold")) {
            a.l0_threshold = try std.fmt.parseInt(usize, eat(&i, argv), 10);
        } else if (std.mem.eql(u8, s, "--freeze-interval")) {
            a.freeze_interval = try std.fmt.parseInt(u64, eat(&i, argv), 10);
        } else if (std.mem.eql(u8, s, "--compact-budget")) {
            a.compact_budget = try std.fmt.parseInt(usize, eat(&i, argv), 10);
        } else if (std.mem.eql(u8, s, "--print-every")) {
            a.print_every = try std.fmt.parseInt(u64, eat(&i, argv), 10);
        } else usage();
    }
    if (!have_dir) usage();
    return a;
}

/// Read the whole `sample.keys` file into an owned []Key.
fn loadSample(gpa: std.mem.Allocator, io: Io, dir: Io.Dir) ![]Key {
    const f = dir.openFile(io, "sample.keys", .{}) catch return &[_]Key{};
    defer f.close(io);
    var list = std.ArrayList(u8).empty;
    defer list.deinit(gpa);
    var buf: [1 << 20]u8 = undefined;
    var off: u64 = 0;
    while (true) {
        const n = try f.readPositionalAll(io, &buf, off);
        if (n == 0) break;
        try list.appendSlice(gpa, buf[0..n]);
        off += n;
        if (n < buf.len) break;
    }
    const usable = list.items.len - (list.items.len % @sizeOf(Key));
    const src = std.mem.bytesAsSlice(Key, list.items[0..usable]);
    return gpa.dupe(Key, src);
}

const Access = struct { key: Key, value: Value, is_read: bool };

pub fn main(init: std.process.Init) !void {
    const gpa = std.heap.smp_allocator;
    const io = init.io;

    var arglist = std.ArrayList([]const u8).empty;
    defer arglist.deinit(gpa);
    var arg_it = std.process.Args.Iterator.init(init.minimal.args);
    while (arg_it.next()) |a| try arglist.append(gpa, a);
    const args = try parseArgs(arglist.items);

    const dir = try std.Io.Dir.cwd().createDirPathOpen(io, args.db_dir, .{});
    var store = try flat.FlatStore.open(gpa, io, dir, "flat", .{
        .prefix_bits = 24, // ignored on open (taken from the manifest)
        .window_entries = @intCast(args.window_entries), // ignored on open (taken from the manifest)
        .fence_gap = args.fence_gap, // policy: rebuilt in RAM on open, no manifest involvement
        .memtable_cap = args.memtable_cap,
        .l0_compact_threshold = args.l0_threshold,
        .freeze_block_interval = args.freeze_interval,
        .o_direct = args.o_direct,
    });
    defer store.deinit();

    const sample = try loadSample(gpa, io, dir);
    defer gpa.free(sample);

    std.debug.print(
        "bench: blocks={d} block_size={d} read_prob={d:.2} new_prob={d:.3} sample={d} bal_prefetch={} o_direct={} window_entries={d} fence_gap={d} fences={d} covered_height0={d}\n",
        .{ args.blocks, args.block_size, args.read_prob, args.new_prob, sample.len, args.bal_prefetch, args.o_direct, store.window_entries, store.fence_gap, store.fences.len, store.covered_height },
    );

    var prng = std.Random.DefaultPrng.init(args.seed);
    const rnd = prng.random();

    const ops = try gpa.alloc(Access, args.block_size);
    defer gpa.free(ops);
    const read_keys = try gpa.alloc(Key, args.block_size);
    defer gpa.free(read_keys);

    var rh = Hist{}; // read latency
    var wh = Hist{}; // write latency
    var ph = Hist{}; // prefetch latency (per block)
    var read_hits: u64 = 0;
    var total_reads: u64 = 0;
    var total_writes: u64 = 0;
    var freezes: u64 = 0;
    var compactions: u64 = 0;

    const base_height = store.covered_height;
    const wall0 = nowNs();

    var blk: u64 = 0;
    while (blk < args.blocks) : (blk += 1) {
        // Generate this block's accesses.
        var nr: usize = 0;
        for (ops) |*op| {
            op.is_read = rnd.float(f64) < args.read_prob;
            const is_new = sample.len == 0 or rnd.float(f64) < args.new_prob;
            if (is_new) rnd.bytes(&op.key) else op.key = sample[rnd.uintLessThan(usize, sample.len)];
            if (!op.is_read) rnd.bytes(&op.value);
            if (op.is_read) {
                read_keys[nr] = op.key;
                nr += 1;
            }
        }

        if (args.bal_prefetch and nr > 0) {
            const t0 = nowNs();
            try store.prefetch(read_keys[0..nr]);
            ph.record(nowNs() - t0);
        }

        for (ops) |*op| {
            if (op.is_read) {
                const t0 = nowNs();
                const v = try store.get(op.key);
                rh.record(nowNs() - t0);
                total_reads += 1;
                if (v != null) read_hits += 1;
            } else {
                const t0 = nowNs();
                try store.put(op.key, op.value);
                wh.record(nowNs() - t0);
                total_writes += 1;
            }
        }

        const h0 = store.covered_height;
        try store.endBlock(base_height + blk + 1);
        if (store.covered_height != h0) freezes += 1;
        if (store.compactionDue()) {
            if (try store.compactStep(args.compact_budget) == .done) compactions += 1;
        }

        if (args.print_every != 0 and (blk + 1) % args.print_every == 0) {
            std.debug.print(
                "  [{d}/{d}] r_mean={d:.1}us r_p99={d:.0}us hit={d:.1}% freezes={d} compactions={d}\n",
                .{ blk + 1, args.blocks, rh.meanUs(), rh.pctUs(99), @as(f64, @floatFromInt(read_hits)) / @as(f64, @floatFromInt(@max(total_reads, 1))) * 100.0, freezes, compactions },
            );
        }
    }

    const wall_s = @as(f64, @floatFromInt(nowNs() - wall0)) / 1e9;
    const total_ops = total_reads + total_writes;
    std.debug.print(
        \\
        \\=== results ===
        \\  ops={d}  elapsed={d:.2}s  throughput={d:.0} ops/s
        \\  reads={d}  hit_rate={d:.1}%  r_mean={d:.2}us  r_p50={d:.0}us  r_p95={d:.0}us  r_p99={d:.0}us
        \\  writes={d}  w_mean={d:.2}us
        \\  bal_prefetch={}  prefetch_mean={d:.1}us/block  o_direct={}
        \\  freezes={d}  compactions_done={d}  covered_height={d}
        \\
    , .{
        total_ops,                                                            wall_s,
        @as(f64, @floatFromInt(total_ops)) / @max(wall_s, 1e-9),              total_reads,
        @as(f64, @floatFromInt(read_hits)) / @as(f64, @floatFromInt(@max(total_reads, 1))) * 100.0, rh.meanUs(),
        rh.pctUs(50),                                                         rh.pctUs(95),
        rh.pctUs(99),                                                         total_writes,
        wh.meanUs(),                                                          args.bal_prefetch,
        ph.meanUs(),                                                          args.o_direct,
        freezes,                                                              compactions,
        store.covered_height,
    });
}
