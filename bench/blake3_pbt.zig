//! BLAKE3 microbenchmark for PBT branch hashing: EIP-8297 as written vs the split-bit +
//! keyed-BLAKE3 proposal. Standalone (no eth_db import):
//!
//!   zig run -O ReleaseFast bench/blake3_pbt.zig -- --n 4096 --rounds 500
//!
//! Every variant hashes the same N random child pairs (L, R), `rounds` times.
//!   std/spec67     std Blake3.hash on 0x01 ‖ enc("") ‖ L ‖ R              67 B, 2 compressions
//!   std/spec100    same with a 33-byte prefix (account-stem depth)        100 B, 2 compressions
//!   std/spec132    same with a 65-byte prefix (storage-stem depth)        132 B, 3 compressions
//!   std/keyed64    std Blake3 keyed hash on L ‖ R, key = K[depth]          64 B, 1 compression
//!   chunk/spec67   single-chunk scalar BLAKE3 (the besu-stateless approach) on the 67 B input
//!   chunk/keyed64  the same single-chunk code in keyed mode on L ‖ R (both proposals combined)
//!   block/keyed64  one keyed compression on L ‖ R, no hasher state
//!   simd/spec67    LANES messages at once, 67 B inputs                   2 compressions per lane
//!   simd/keyed64   LANES messages at once, one keyed compression each
//!
//! Spec variants assemble their input from L and R on every hash (a real implementation must);
//! keyed variants read L ‖ R in place, as children 2i and 2i+1 sit side by side in a heap.
//! All hand-written paths are checked against std before timing.

const std = @import("std");
const linux = std.os.linux;
const Blake3 = std.crypto.hash.Blake3;

const LANES = std.simd.suggestVectorLength(u32) orelse 4;
const V = @Vector(LANES, u32);

const IV = [8]u32{ 0x6A09E667, 0xBB67AE85, 0x3C6EF372, 0xA54FF53A, 0x510E527F, 0x9B05688C, 0x1F83D9AB, 0x5BE0CD19 };
const MSG_PERM = [16]u8{ 2, 6, 3, 10, 7, 0, 4, 13, 1, 11, 12, 5, 9, 14, 15, 8 };

const CHUNK_START: u32 = 1;
const CHUNK_END: u32 = 2;
const ROOT: u32 = 8;
const KEYED_HASH: u32 = 16;

/// Split depths for 66-byte keys: 0..528.
const DEPTHS = 529;

fn nowNs() i128 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(i128, ts.sec) * std.time.ns_per_s + ts.nsec;
}

// ─── Compression, generic over u32 (scalar) and V (one message per lane) ─────

inline fn splat(comptime T: type, x: u32) T {
    return if (T == u32) x else @splat(x);
}

inline fn g(comptime T: type, v: *[16]T, comptime a: usize, comptime b: usize, comptime c: usize, comptime d: usize, x: T, y: T) void {
    v[a] +%= v[b] +% x;
    v[d] = std.math.rotr(T, v[d] ^ v[a], 16);
    v[c] +%= v[d];
    v[b] = std.math.rotr(T, v[b] ^ v[c], 12);
    v[a] +%= v[b] +% y;
    v[d] = std.math.rotr(T, v[d] ^ v[a], 8);
    v[c] +%= v[d];
    v[b] = std.math.rotr(T, v[b] ^ v[c], 7);
}

/// One BLAKE3 compression with chunk counter 0; returns the new chaining value.
inline fn compress(comptime T: type, cv: [8]T, m_in: [16]T, block_len: u32, flags: u32) [8]T {
    var m = m_in;
    var v: [16]T = undefined;
    inline for (0..8) |i| v[i] = cv[i];
    inline for (0..4) |i| v[8 + i] = splat(T, IV[i]);
    v[12] = splat(T, 0);
    v[13] = splat(T, 0);
    v[14] = splat(T, block_len);
    v[15] = splat(T, flags);
    inline for (0..7) |r| {
        g(T, &v, 0, 4, 8, 12, m[0], m[1]);
        g(T, &v, 1, 5, 9, 13, m[2], m[3]);
        g(T, &v, 2, 6, 10, 14, m[4], m[5]);
        g(T, &v, 3, 7, 11, 15, m[6], m[7]);
        g(T, &v, 0, 5, 10, 15, m[8], m[9]);
        g(T, &v, 1, 6, 11, 12, m[10], m[11]);
        g(T, &v, 2, 7, 8, 13, m[12], m[13]);
        g(T, &v, 3, 4, 9, 14, m[14], m[15]);
        if (r < 6) {
            var p: [16]T = undefined;
            inline for (0..16) |i| p[i] = m[MSG_PERM[i]];
            m = p;
        }
    }
    var out: [8]T = undefined;
    inline for (0..8) |i| out[i] = v[i] ^ v[i + 8];
    return out;
}

inline fn loadBlock(b: *const [64]u8) [16]u32 {
    var m: [16]u32 = undefined;
    inline for (0..16) |i| m[i] = std.mem.readInt(u32, b[4 * i ..][0..4], .little);
    return m;
}

inline fn storeCv(cv: [8]u32, out: *[32]u8) void {
    inline for (0..8) |i| std.mem.writeInt(u32, out[4 * i ..][0..4], cv[i], .little);
}

fn keyWords(key: *const [32]u8) [8]u32 {
    var w: [8]u32 = undefined;
    inline for (0..8) |i| w[i] = std.mem.readInt(u32, key[4 * i ..][0..4], .little);
    return w;
}

// ─── Scalar paths ─────────────────────────────────────────────────────────────

/// BLAKE3 for inputs of at most one chunk (1024 B): blocks in sequence, no chunk tree. `key` is
/// the starting chaining value (IV for hash mode) and `mode` the flags on every block
/// (0 for hash mode, KEYED_HASH for keyed mode).
fn chunkHashWith(input: []const u8, key: [8]u32, mode: u32, out: *[32]u8) void {
    std.debug.assert(input.len <= 1024);
    var cv = key;
    var flags = mode | CHUNK_START;
    var off: usize = 0;
    while (input.len - off > 64) : (off += 64) {
        cv = compress(u32, cv, loadBlock(input[off..][0..64]), 64, flags);
        flags = mode;
    }
    var last = [_]u8{0} ** 64;
    const rem = input.len - off;
    @memcpy(last[0..rem], input[off..]);
    cv = compress(u32, cv, loadBlock(&last), @intCast(rem), flags | CHUNK_END | ROOT);
    storeCv(cv, out);
}

fn chunkHash(input: []const u8, out: *[32]u8) void {
    chunkHashWith(input, IV, 0, out);
}

/// The proposal's branch: one keyed compression over L ‖ R.
inline fn blockKeyed64(key: [8]u32, lr: *const [64]u8, out: *[32]u8) void {
    storeCv(compress(u32, key, loadBlock(lr), 64, CHUNK_START | CHUNK_END | ROOT | KEYED_HASH), out);
}

/// EIP-8297 branch input: 0x01 ‖ u16be(bit count) ‖ prefix ‖ L ‖ R. Returns its length.
inline fn specInput(buf: *[160]u8, prefix: []const u8, lr: *const [64]u8) usize {
    buf[0] = 0x01;
    std.mem.writeInt(u16, buf[1..3], @intCast(prefix.len * 8), .big);
    @memcpy(buf[3..][0..prefix.len], prefix);
    @memcpy(buf[3 + prefix.len ..][0..64], lr);
    return 3 + prefix.len + 64;
}

// ─── SIMD paths: LANES independent messages, one per lane ────────────────────

/// Word `w` of each lane's 64-byte block, as one vector.
inline fn gatherBlock(blocks: [LANES]*const [64]u8) [16]V {
    var m: [16]V = undefined;
    inline for (0..16) |w| {
        var lane_words: [LANES]u32 = undefined;
        for (0..LANES) |l| lane_words[l] = std.mem.readInt(u32, blocks[l][4 * w ..][0..4], .little);
        m[w] = lane_words;
    }
    return m;
}

inline fn scatterCv(cv: [8]V, outs: [][32]u8) void {
    inline for (0..8) |w| {
        const words: [LANES]u32 = cv[w];
        for (0..LANES) |l| std.mem.writeInt(u32, outs[l][4 * w ..][0..4], words[l], .little);
    }
}

/// LANES keyed branches with the same split depth (one heap level): key broadcast to all lanes.
fn simdKeyed64(key: [8]u32, lrs: *const [LANES][64]u8, outs: [][32]u8) void {
    var cv: [8]V = undefined;
    inline for (0..8) |i| cv[i] = @splat(key[i]);
    var ptrs: [LANES]*const [64]u8 = undefined;
    inline for (0..LANES) |l| ptrs[l] = &lrs[l];
    scatterCv(compress(V, cv, gatherBlock(ptrs), 64, CHUNK_START | CHUNK_END | ROOT | KEYED_HASH), outs);
}

/// LANES spec branches with an empty prefix: 67 B, two blocks per lane.
fn simdSpec67(lrs: *const [LANES][64]u8, outs: [][32]u8) void {
    var bufs: [LANES][128]u8 = undefined;
    inline for (0..LANES) |l| {
        bufs[l][0] = 0x01;
        bufs[l][1] = 0;
        bufs[l][2] = 0;
        @memcpy(bufs[l][3..67], &lrs[l]);
        @memset(bufs[l][67..128], 0);
    }
    var first: [LANES]*const [64]u8 = undefined;
    var second: [LANES]*const [64]u8 = undefined;
    inline for (0..LANES) |l| {
        first[l] = bufs[l][0..64];
        second[l] = bufs[l][64..128];
    }
    var cv: [8]V = undefined;
    inline for (0..8) |i| cv[i] = @splat(IV[i]);
    cv = compress(V, cv, gatherBlock(first), 64, CHUNK_START);
    cv = compress(V, cv, gatherBlock(second), 3, CHUNK_END | ROOT);
    scatterCv(cv, outs);
}

// ─── Benchmark driver ─────────────────────────────────────────────────────────

const Ctx = struct {
    pairs: [][64]u8,
    outs: [][32]u8,
    keys: *const [DEPTHS][32]u8,
    key_words: *const [DEPTHS][8]u32,
    prefix: [65]u8,
};

const Variant = struct {
    name: []const u8,
    compressions: u32,
    run: *const fn (*Ctx) void,
};

fn runStdSpec(ctx: *Ctx, comptime plen: usize) void {
    var buf: [160]u8 = undefined;
    for (ctx.pairs, ctx.outs) |*lr, *out| {
        const len = specInput(&buf, ctx.prefix[0..plen], lr);
        Blake3.hash(buf[0..len], out, .{});
    }
}

fn runStdSpec67(ctx: *Ctx) void {
    runStdSpec(ctx, 0);
}
fn runStdSpec100(ctx: *Ctx) void {
    runStdSpec(ctx, 33);
}
fn runStdSpec132(ctx: *Ctx) void {
    runStdSpec(ctx, 65);
}

fn runStdKeyed64(ctx: *Ctx) void {
    for (ctx.pairs, ctx.outs, 0..) |*lr, *out, i| {
        Blake3.hash(lr, out, .{ .key = ctx.keys[i % DEPTHS] });
    }
}

fn runChunkSpec67(ctx: *Ctx) void {
    var buf: [160]u8 = undefined;
    for (ctx.pairs, ctx.outs) |*lr, *out| {
        const len = specInput(&buf, ctx.prefix[0..0], lr);
        chunkHash(buf[0..len], out);
    }
}

fn runChunkKeyed64(ctx: *Ctx) void {
    for (ctx.pairs, ctx.outs, 0..) |*lr, *out, i| {
        chunkHashWith(lr, ctx.key_words[i % DEPTHS], KEYED_HASH, out);
    }
}

fn runBlockKeyed64(ctx: *Ctx) void {
    for (ctx.pairs, ctx.outs, 0..) |*lr, *out, i| {
        blockKeyed64(ctx.key_words[i % DEPTHS], lr, out);
    }
}

fn runSimdSpec67(ctx: *Ctx) void {
    var i: usize = 0;
    while (i < ctx.pairs.len) : (i += LANES) {
        simdSpec67(ctx.pairs[i..][0..LANES], ctx.outs[i..][0..LANES]);
    }
}

fn runSimdKeyed64(ctx: *Ctx) void {
    var i: usize = 0;
    while (i < ctx.pairs.len) : (i += LANES) {
        // One batch = one heap level: every lane shares the split depth.
        simdKeyed64(ctx.key_words[(i / LANES) % DEPTHS], ctx.pairs[i..][0..LANES], ctx.outs[i..][0..LANES]);
    }
}

const VARIANTS = [_]Variant{
    .{ .name = "std/spec67", .compressions = 2, .run = runStdSpec67 },
    .{ .name = "std/spec100", .compressions = 2, .run = runStdSpec100 },
    .{ .name = "std/spec132", .compressions = 3, .run = runStdSpec132 },
    .{ .name = "std/keyed64", .compressions = 1, .run = runStdKeyed64 },
    .{ .name = "chunk/spec67", .compressions = 2, .run = runChunkSpec67 },
    .{ .name = "chunk/keyed64", .compressions = 1, .run = runChunkKeyed64 },
    .{ .name = "block/keyed64", .compressions = 1, .run = runBlockKeyed64 },
    .{ .name = "simd/spec67", .compressions = 2, .run = runSimdSpec67 },
    .{ .name = "simd/keyed64", .compressions = 1, .run = runSimdKeyed64 },
};

// ─── Correctness against std ──────────────────────────────────────────────────

fn verify(ctx: *Ctx, rnd: std.Random) !void {
    var buf: [1024]u8 = undefined;
    var a: [32]u8 = undefined;
    var b: [32]u8 = undefined;

    for (0..1025) |len| {
        rnd.bytes(buf[0..len]);
        chunkHash(buf[0..len], &a);
        Blake3.hash(buf[0..len], &b, .{});
        if (!std.mem.eql(u8, &a, &b)) return error.ChunkHashMismatch;
    }

    for (0..DEPTHS) |d| {
        const lr = &ctx.pairs[d % ctx.pairs.len];
        blockKeyed64(ctx.key_words[d], lr, &a);
        Blake3.hash(lr, &b, .{ .key = ctx.keys[d] });
        if (!std.mem.eql(u8, &a, &b)) return error.KeyedBlockMismatch;
        chunkHashWith(lr, ctx.key_words[d], KEYED_HASH, &a);
        if (!std.mem.eql(u8, &a, &b)) return error.KeyedChunkMismatch;
    }

    var outs: [LANES][32]u8 = undefined;
    var spec: [160]u8 = undefined;
    const lrs = ctx.pairs[0..LANES];
    simdKeyed64(ctx.key_words[7], lrs, &outs);
    for (lrs, &outs) |*lr, *o| {
        Blake3.hash(lr, &b, .{ .key = ctx.keys[7] });
        if (!std.mem.eql(u8, o, &b)) return error.SimdKeyedMismatch;
    }
    simdSpec67(lrs, &outs);
    for (lrs, &outs) |*lr, *o| {
        const len = specInput(&spec, ctx.prefix[0..0], lr);
        Blake3.hash(spec[0..len], &b, .{});
        if (!std.mem.eql(u8, o, &b)) return error.SimdSpecMismatch;
    }
}

fn usage() noreturn {
    std.debug.print(
        \\usage: blake3_pbt [--n PAIRS] [--rounds R] [--seed S]
        \\  --n       child pairs per round, rounded up to a multiple of the SIMD width (default 4096 = 256 KiB)
        \\  --rounds  passes over the pairs per variant (default 500)
        \\
    , .{});
    std.process.exit(2);
}

pub fn main(init: std.process.Init) !void {
    const gpa = std.heap.smp_allocator;

    var n: usize = 4096;
    var rounds: usize = 500;
    var seed: u64 = 1;
    var arg_it = std.process.Args.Iterator.init(init.minimal.args);
    _ = arg_it.next();
    while (arg_it.next()) |s| {
        const val = arg_it.next() orelse usage();
        if (std.mem.eql(u8, s, "--n")) {
            n = try std.fmt.parseInt(usize, val, 10);
        } else if (std.mem.eql(u8, s, "--rounds")) {
            rounds = try std.fmt.parseInt(usize, val, 10);
        } else if (std.mem.eql(u8, s, "--seed")) {
            seed = try std.fmt.parseInt(u64, val, 10);
        } else usage();
    }
    n = std.mem.alignForward(usize, @max(n, LANES), LANES);

    var prng = std.Random.DefaultPrng.init(seed);
    const rnd = prng.random();

    const pairs = try gpa.alloc([64]u8, n);
    defer gpa.free(pairs);
    const outs = try gpa.alloc([32]u8, n);
    defer gpa.free(outs);
    for (pairs) |*p| rnd.bytes(p);

    // K[d] = BLAKE3 derive_key("EIP-8297 branch", u16be(d)).
    const keys = try gpa.create([DEPTHS][32]u8);
    defer gpa.destroy(keys);
    const key_words = try gpa.create([DEPTHS][8]u32);
    defer gpa.destroy(key_words);
    for (keys, key_words, 0..) |*k, *kw, d| {
        var kdf = Blake3.initKdf("EIP-8297 branch", .{});
        var dbuf: [2]u8 = undefined;
        std.mem.writeInt(u16, &dbuf, @intCast(d), .big);
        kdf.update(&dbuf);
        kdf.final(k);
        kw.* = keyWords(k);
    }

    var ctx = Ctx{ .pairs = pairs, .outs = outs, .keys = keys, .key_words = key_words, .prefix = undefined };
    rnd.bytes(&ctx.prefix);

    try verify(&ctx, rnd);

    std.debug.print("BLAKE3 PBT branch hashing: {d} pairs x {d} rounds, SIMD width {d} lanes, all paths verified against std\n\n", .{ n, rounds, LANES });
    std.debug.print("{s:<15} {s:>6} {s:>10} {s:>12} {s:>10} {s:>12}\n", .{ "variant", "compr", "ns/hash", "Mhash/s", "ns/compr", "vs std/spec67" });

    var baseline: f64 = 0;
    var sink: u64 = 0;
    for (VARIANTS) |v| {
        v.run(&ctx); // warm-up
        const t0 = nowNs();
        for (0..rounds) |_| {
            v.run(&ctx);
            std.mem.doNotOptimizeAway(ctx.outs.ptr);
        }
        const elapsed: f64 = @floatFromInt(nowNs() - t0);
        for (ctx.outs) |*o| sink ^= std.mem.readInt(u64, o[0..8], .little);

        const hashes: f64 = @floatFromInt(n * rounds);
        const ns = elapsed / hashes;
        if (baseline == 0) baseline = ns;
        std.debug.print("{s:<15} {d:>6} {d:>10.2} {d:>12.1} {d:>10.2} {d:>11.2}x\n", .{
            v.name, v.compressions, ns, 1e3 / ns, ns / @as(f64, @floatFromInt(v.compressions)), baseline / ns,
        });
    }
    std.debug.print("\n(sink {x})\n", .{sink});
}
