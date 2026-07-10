//! Two-tier (account‖slot) commitment benchmark — docs/two_tier_plan.md Phase 4.
//!
//! Simulates state access over `--accounts` accounts whose slot-space sizes follow
//! a Zipf law (`size(rank r) = max(1, max_slots / r^zipf)`) — a handful of whales,
//! a long tail. Accesses sample accounts ∝ size (hot contracts are big contracts)
//! and slots uniformly within the account. Per block: reads/writes/deletes →
//! `slots.endBlock` → budgeted compaction → timed `commitBlock` with the engine's
//! per-phase breakdown (storage-root recompute + write-back vs account tree).
//!
//! The store starts empty and grows; state root is printed at the end for
//! cross-run comparison. First run at a given dir creates fresh stores; later
//! runs recover them (and the commitment checkpoint, if one was written).
//!
//! Usage:
//!   zig build -Doptimize=ReleaseFast
//!   ./zig-out/bin/bench2 --db-dir /mnt/big/ttdb -n 1000 --block-size 16000 \
//!       --accounts 1000000 --zipf 1.0 --max-slots 1000000 \
//!       --acct-heap-depth 24 --t-big-log2 12 --commit-checkpoint-every 200

const std = @import("std");
const eth = @import("eth_db");
const tt = eth.two_tier;
const Io = std.Io;
const linux = std.os.linux;

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

const Acc = struct {
    n: u64 = 0,
    sum_ns: u128 = 0,
    max_ns: u64 = 0,

    fn record(self: *Acc, ns: u64) void {
        self.n += 1;
        self.sum_ns += ns;
        self.max_ns = @max(self.max_ns, ns);
    }
    fn meanMs(self: *const Acc) f64 {
        if (self.n == 0) return 0;
        return @as(f64, @floatFromInt(self.sum_ns)) / @as(f64, @floatFromInt(self.n)) / 1e6;
    }
    fn maxMs(self: *const Acc) f64 {
        return @as(f64, @floatFromInt(self.max_ns)) / 1e6;
    }
};

const Args = struct {
    db_dir: []const u8,
    blocks: u64 = 1000,
    block_size: usize = 16000,
    read_prob: f64 = 0.75,
    delete_prob: f64 = 0.02,
    accounts: u64 = 100_000,
    zipf: f64 = 1.0,
    max_slots: u64 = 1_000_000,
    seed: u64 = 42,
    fence_gap: u32 = 64,
    memtable_cap: usize = 0,
    l0_threshold: usize = 0,
    freeze_interval: u64 = 0,
    compact_budget: usize = 256 << 20,
    acct_heap_depth: u8 = 20,
    t_big_log2: u8 = 12,
    commit_checkpoint_every: u64 = 0,
    o_direct: bool = false,
    print_every: u64 = 50,
};

fn usage() noreturn {
    std.debug.print(
        \\usage: bench2 --db-dir DIR [options]
        \\  -n, --blocks N            number of blocks (default 1000)
        \\  --block-size N            accesses per block (default 16000)
        \\  --read-prob F             fraction of accesses that are reads (default 0.75)
        \\  --delete-prob F           fraction of writes that are deletes (default 0.02)
        \\  --accounts N              number of accounts (default 100000)
        \\  --zipf S                  Zipf exponent for account sizes (default 1.0)
        \\  --max-slots N             slot-space size of the rank-1 whale (default 1e6);
        \\                            size(rank r) = max(1, max-slots / r^S)
        \\  --acct-heap-depth H       account-tree heap depth (default 20 = 64 MiB heap;
        \\                            24 = 1 GiB). Structural for state.croot
        \\  --t-big-log2 K            T_big = 2^K promotion threshold + unit budget
        \\                            (default 12). Structural for state.cstor
        \\  --commit-checkpoint-every N   checkpoint every N blocks (0 = only at exit)
        \\  --fence-gap G             slots-store fence gap (default 64; must be > 0)
        \\  --o-direct                O_DIRECT on the slots store's hot reads
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
        } else if (std.mem.eql(u8, s, "--delete-prob")) {
            a.delete_prob = try std.fmt.parseFloat(f64, eat(&i, argv));
        } else if (std.mem.eql(u8, s, "--accounts")) {
            a.accounts = try std.fmt.parseInt(u64, eat(&i, argv), 10);
        } else if (std.mem.eql(u8, s, "--zipf")) {
            a.zipf = try std.fmt.parseFloat(f64, eat(&i, argv));
        } else if (std.mem.eql(u8, s, "--max-slots")) {
            a.max_slots = try std.fmt.parseInt(u64, eat(&i, argv), 10);
        } else if (std.mem.eql(u8, s, "--acct-heap-depth")) {
            a.acct_heap_depth = try std.fmt.parseInt(u8, eat(&i, argv), 10);
        } else if (std.mem.eql(u8, s, "--t-big-log2")) {
            a.t_big_log2 = try std.fmt.parseInt(u8, eat(&i, argv), 10);
        } else if (std.mem.eql(u8, s, "--commit-checkpoint-every")) {
            a.commit_checkpoint_every = try std.fmt.parseInt(u64, eat(&i, argv), 10);
        } else if (std.mem.eql(u8, s, "--fence-gap")) {
            a.fence_gap = try std.fmt.parseInt(u32, eat(&i, argv), 10);
        } else if (std.mem.eql(u8, s, "--seed")) {
            a.seed = try std.fmt.parseInt(u64, eat(&i, argv), 10);
        } else if (std.mem.eql(u8, s, "--o-direct")) {
            a.o_direct = true;
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
    if (a.fence_gap == 0) usage();
    return a;
}

fn acctHash(id: u64) [32]u8 {
    var k = std.mem.zeroes([32]u8);
    std.mem.writeInt(u64, k[0..8], id *% 0x9E37_79B9_7F4A_7C15 +% 0x1234, .big);
    return k;
}

fn slotHash(id: u64) [32]u8 {
    var k = std.mem.zeroes([32]u8);
    std.mem.writeInt(u64, k[0..8], id *% 0xC2B2_AE3D_27D4_EB4F +% 0x77, .big);
    return k;
}

fn openOrCreate(comptime Store: type, gpa: std.mem.Allocator, io: Io, dir: Io.Dir, name: []const u8, cfg: eth.flat_store.Config) !Store {
    return Store.open(gpa, io, dir, name, cfg) catch |err| switch (err) {
        error.FileNotFound => try Store.create(gpa, io, dir, name, &.{}, cfg),
        else => err,
    };
}

pub fn main(init: std.process.Init) !void {
    const gpa = std.heap.smp_allocator;
    const io = init.io;

    var arglist = std.ArrayList([]const u8).empty;
    defer arglist.deinit(gpa);
    var arg_it = std.process.Args.Iterator.init(init.minimal.args);
    while (arg_it.next()) |a| try arglist.append(gpa, a);
    const args = try parseArgs(arglist.items);

    const dir = try std.Io.Dir.cwd().createDirPathOpen(io, args.db_dir, .{});

    var accts = try openOrCreate(tt.AcctStore, gpa, io, dir, "acct", .{
        .prefix_bits = 16,
        .memtable_cap = args.memtable_cap,
        .l0_compact_threshold = args.l0_threshold,
        .freeze_block_interval = if (args.freeze_interval == 0) 1 else args.freeze_interval,
    });
    defer accts.deinit();
    var slots = try openOrCreate(tt.SlotStore, gpa, io, dir, "slots", .{
        .prefix_bits = 16,
        .fence_gap = args.fence_gap,
        .memtable_cap = args.memtable_cap,
        .l0_compact_threshold = args.l0_threshold,
        .freeze_block_interval = args.freeze_interval,
        .o_direct = args.o_direct,
    });
    defer slots.deinit();

    const tt_cfg: tt.Config = .{
        .acct_heap_depth = @intCast(args.acct_heap_depth),
        .t_big_log2 = @intCast(args.t_big_log2),
    };
    var db = tt.TwoTierDb.open(gpa, io, dir, "state", tt_cfg) catch |err| switch (err) {
        error.FileNotFound => try tt.TwoTierDb.init(gpa, tt_cfg),
        else => return err,
    };
    defer db.deinit();
    if (db.committedHeight() > slots.covered_height) std.debug.print(
        "WARNING: commitment checkpoint (height {d}) is ahead of durable slot data (height {d}) — unfrozen writes were lost at the last exit, so restored roots are synthetic until every account is re-touched. For consistent roots across restarts set --freeze-interval so blocks freeze before checkpoints.\n",
        .{ db.committedHeight(), slots.covered_height },
    );

    // Zipf account sizes + cumulative weights for size-proportional sampling.
    const sizes = try gpa.alloc(u64, args.accounts);
    defer gpa.free(sizes);
    const cum = try gpa.alloc(u64, args.accounts);
    defer gpa.free(cum);
    var total: u64 = 0;
    for (sizes, 0..) |*sz, r| {
        const rank: f64 = @floatFromInt(r + 1);
        const f = @as(f64, @floatFromInt(args.max_slots)) / std.math.pow(f64, rank, args.zipf);
        sz.* = @max(1, @as(u64, @intFromFloat(f)));
        total += sz.*;
        cum[r] = total;
    }

    std.debug.print(
        "bench2: blocks={d} block_size={d} read_prob={d:.2} delete_prob={d:.2} accounts={d} zipf={d:.2} max_slots={d} total_slot_space={d} H={d} t_big_log2={d} covered_height0={d} committed_height0={d} big0={d}\n",
        .{ args.blocks, args.block_size, args.read_prob, args.delete_prob, args.accounts, args.zipf, args.max_slots, total, args.acct_heap_depth, args.t_big_log2, slots.covered_height, db.committedHeight(), db.big.count() },
    );

    var prng = std.Random.DefaultPrng.init(args.seed);
    const rnd = prng.random();

    var rh = Hist{}; // read latency
    var wh = Hist{}; // write latency
    var ch = Acc{}; // total commit
    var sh = Acc{}; // storage-root phase
    var ah = Acc{}; // account-tree phase
    var kh = Acc{}; // checkpoint
    var read_hits: u64 = 0;
    var total_reads: u64 = 0;
    var total_writes: u64 = 0;
    var total_deletes: u64 = 0;
    var dirty_pairs: u64 = 0;
    var dirty_accounts: u64 = 0;
    var compactions: u64 = 0;

    const base_height = slots.covered_height;
    const wall0 = nowNs();

    var blk: u64 = 0;
    while (blk < args.blocks) : (blk += 1) {
        const h = base_height + blk + 1;
        for (0..args.block_size) |_| {
            // Account ∝ size (binary search the cumulative weights), slot uniform
            // within the account's slot space.
            const pick = rnd.uintLessThan(u64, total);
            var lo: usize = 0;
            var hi: usize = cum.len;
            while (lo < hi) {
                const mid = lo + (hi - lo) / 2;
                if (cum[mid] <= pick) lo = mid + 1 else hi = mid;
            }
            const acct = acctHash(@intCast(lo));
            const slot = slotHash(rnd.uintLessThan(u64, sizes[lo]));

            if (rnd.float(f64) < args.read_prob) {
                const t0 = nowNs();
                const v = try slots.get(tt.composeKey(&acct, &slot));
                rh.record(nowNs() - t0);
                total_reads += 1;
                if (v != null) read_hits += 1;
            } else if (rnd.float(f64) < args.delete_prob) {
                const t0 = nowNs();
                try db.deleteSlot(&slots, &acct, &slot);
                wh.record(nowNs() - t0);
                total_deletes += 1;
            } else {
                var value: [32]u8 = undefined;
                rnd.bytes(&value);
                const t0 = nowNs();
                try db.putSlot(&slots, &acct, &slot, value);
                wh.record(nowNs() - t0);
                total_writes += 1;
            }
        }

        try slots.endBlock(h);
        if (slots.compactionDue()) {
            if (try slots.compactStep(args.compact_budget) == .done) compactions += 1;
        }
        if (accts.compactionDue()) try accts.compact(); // small store — just fold it

        const t0 = nowNs();
        _ = try db.commitBlock(&accts, &slots, h);
        ch.record(@intCast(nowNs() - t0));
        const st = db.last_commit_stats;
        sh.record(st.storage_ns);
        ah.record(st.acct_tree_ns);
        dirty_pairs += st.dirty_pairs;
        dirty_accounts += st.dirty_accounts;

        if (args.commit_checkpoint_every != 0 and (blk + 1) % args.commit_checkpoint_every == 0) {
            const k0 = nowNs();
            try db.checkpoint(io, dir, "state");
            kh.record(@intCast(nowNs() - k0));
        }

        if (args.print_every != 0 and (blk + 1) % args.print_every == 0) {
            std.debug.print(
                "  [{d}/{d}] r_mean={d:.1}us hit={d:.1}% c_mean={d:.2}ms (storage={d:.2} acct={d:.2}) big={d} dirty_accts/blk={d:.0}\n",
                .{
                    blk + 1,                                                                    args.blocks,
                    rh.meanUs(),                                                                @as(f64, @floatFromInt(read_hits)) / @as(f64, @floatFromInt(@max(total_reads, 1))) * 100.0,
                    ch.meanMs(),                                                                sh.meanMs(),
                    ah.meanMs(),                                                                db.big.count(),
                    @as(f64, @floatFromInt(dirty_accounts)) / @as(f64, @floatFromInt(blk + 1)),
                },
            );
        }
    }

    // Final checkpoint so the next run restores instead of replaying.
    {
        const k0 = nowNs();
        try db.checkpoint(io, dir, "state");
        kh.record(@intCast(nowNs() - k0));
    }

    const wall_s = @as(f64, @floatFromInt(nowNs() - wall0)) / 1e9;
    const total_ops = total_reads + total_writes + total_deletes;
    const root_hex = std.fmt.bytesToHex(db.root(), .lower);
    std.debug.print(
        \\
        \\=== results (two-tier) ===
        \\  ops={d}  elapsed={d:.2}s  throughput={d:.0} ops/s
        \\  reads={d}  hit_rate={d:.1}%  r_mean={d:.2}us  r_p50={d:.0}us  r_p95={d:.0}us  r_p99={d:.0}us
        \\  writes={d}  deletes={d}  w_mean={d:.2}us
        \\  commit: blocks={d}  c_mean={d:.2}ms  c_max={d:.2}ms
        \\          storage_mean={d:.2}ms  acct_tree_mean={d:.2}ms
        \\          dirty_pairs/blk={d:.0}  dirty_accts/blk={d:.0}  big_accounts={d}
        \\  checkpoints={d}  ckpt_mean={d:.1}ms  compactions_done={d}
        \\  committed_height={d}  covered_height={d}
        \\  root={s}
        \\
    , .{
        total_ops,                                                                                  wall_s,
        @as(f64, @floatFromInt(total_ops)) / @max(wall_s, 1e-9),                                    total_reads,
        @as(f64, @floatFromInt(read_hits)) / @as(f64, @floatFromInt(@max(total_reads, 1))) * 100.0, rh.meanUs(),
        rh.pctUs(50),                                                                               rh.pctUs(95),
        rh.pctUs(99),                                                                               total_writes,
        total_deletes,                                                                              wh.meanUs(),
        ch.n,                                                                                       ch.meanMs(),
        ch.maxMs(),                                                                                 sh.meanMs(),
        ah.meanMs(),                                                                                @as(f64, @floatFromInt(dirty_pairs)) / @as(f64, @floatFromInt(@max(ch.n, 1))),
        @as(f64, @floatFromInt(dirty_accounts)) / @as(f64, @floatFromInt(@max(ch.n, 1))),           db.big.count(),
        kh.n,                                                                                       kh.meanMs(),
        compactions,                                                                                db.committedHeight(),
        slots.covered_height,                                                                       &root_hex,
    });
}
