//! Combinadic encoding / decoding for key fingerprints (§7.1).
//!
//! A DecodedFingerprint is a sorted multiset of PAGE_ENTRIES (64) values from
//! {0 … 4096}.  This module encodes it as a 60-byte (480-bit) combinatorial
//! number and decodes it back.
//!
//! **Encoding** — transform the multiset (a₁ ≤ … ≤ a₆₄) to a strictly
//! increasing sequence bᵢ = aᵢ + i − 1, then apply the combinatorial number
//! system: N = Σᵢ₌₁⁶⁴ C(bᵢ, i).
//!
//! **Decoding** — from N, recover bᵢ in reverse order via binary search:
//! find the largest b such that C(b, i) ≤ remaining, subtract, continue for
//! i − 1.
//!
//! **LUT** — call `initLUT()` once at startup to precompute all C(n, k) for
//! n ≤ 4159 and k ∈ {1..64} using Pascal's triangle.  After that, every
//! `binomial` call in encode/decode becomes a single array lookup, reducing
//! per-fingerprint time from ~200 µs to ~1 µs.  If the LUT has not been
//! initialised, both functions fall back to the on-the-fly multiplicative
//! recurrence, so correctness is never affected by call order.

const std = @import("std");
const root = @import("types.zig");

/// 60-byte on-disk representation of one combinadic fingerprint.
pub const EncodedFingerprint = [60]u8;

// ─── 480-bit integer arithmetic ───────────────────────────────────────────────
//
// 8 × u64 limbs, little-endian (limb[0] = least significant word).
// We allocate 512 bits so the last two limb bytes are always spare;
// well-formed values ≤ C(4160, 64) ≈ 2^456 never set limb[7] high bits.

const LIMBS: usize = 8;
const U480 = [LIMBS]u64;
const ZERO: U480 = .{ 0, 0, 0, 0, 0, 0, 0, 0 };
const ONE: U480 = .{ 1, 0, 0, 0, 0, 0, 0, 0 };

fn u480_add(a: U480, b: U480) U480 {
    var r: U480 = undefined;
    var carry: u64 = 0;
    for (0..LIMBS) |i| {
        const s0 = @addWithOverflow(a[i], b[i]);
        const s1 = @addWithOverflow(s0[0], carry);
        r[i] = s1[0];
        carry = @as(u64, s0[1]) + @as(u64, s1[1]);
    }
    return r;
}

fn u480_sub(a: U480, b: U480) U480 {
    // Precondition: a ≥ b.
    var r: U480 = undefined;
    var borrow: u64 = 0;
    for (0..LIMBS) |i| {
        const s0 = @subWithOverflow(a[i], b[i]);
        const s1 = @subWithOverflow(s0[0], borrow);
        r[i] = s1[0];
        borrow = @as(u64, s0[1]) + @as(u64, s1[1]);
    }
    return r;
}

fn u480_cmp(a: U480, b: U480) std.math.Order {
    var i: usize = LIMBS;
    while (i > 0) {
        i -= 1;
        if (a[i] < b[i]) return .lt;
        if (a[i] > b[i]) return .gt;
    }
    return .eq;
}

fn u480_mul(a: U480, x: u64) U480 {
    var r: U480 = undefined;
    var carry: u128 = 0;
    for (0..LIMBS) |i| {
        const p: u128 = @as(u128, a[i]) * x + carry;
        r[i] = @truncate(p);
        carry = p >> 64;
    }
    return r;
}

fn u480_div(a: U480, x: u64) U480 {
    var r: U480 = undefined;
    var rem: u128 = 0;
    var i: usize = LIMBS;
    while (i > 0) {
        i -= 1;
        const n: u128 = (rem << 64) | a[i];
        r[i] = @truncate(n / x);
        rem = n % x;
    }
    return r;
}

// ─── Slow-path binomial (no LUT) ─────────────────────────────────────────────

/// Compute C(n, k) as a U480 value via the multiplicative recurrence.
/// Used as fallback when the LUT has not been initialised.
fn binomial(n: u32, k: u32) U480 {
    if (k > n) return ZERO;
    if (k == 0) return ONE;
    const k2 = @min(k, n - k); // symmetry: C(n,k) = C(n,n−k)
    var r = ONE;
    for (0..k2) |step| {
        const s: u32 = @intCast(step);
        r = u480_mul(r, n - s);
        r = u480_div(r, s + 1);
    }
    return r;
}

// ─── LUT ─────────────────────────────────────────────────────────────────────
//
// lut[n][k−1] = C(n, k)  for n ∈ {0..4159}, k ∈ {1..64}.
// Row n=0 is all ZERO (C(0,k)=0 for k≥1).
// Subsequent rows follow Pascal's triangle:
//   C(n, 1) = C(n−1, 1) + 1             (k−1 = 0)
//   C(n, k) = C(n−1, k) + C(n−1, k−1)  (k−1 ≥ 1)
//
// Heap-allocated via page_allocator to keep the binary small; a static
// `= undefined` global would embed 17 MiB of debug-sentinel bytes in the
// Debug binary's .data section, causing crashes on load in WSL2.

const LUT_N: usize = 4160; // n ∈ {0..4159}
const LUT_K: usize = 64; // k ∈ {1..64}, stored at index k−1

var lut_storage: ?[][LUT_K]U480 = null;
var lut_ready: bool = false;

/// Allocate and populate the binomial coefficient LUT.
/// No-op after the first call.  Must be called before encode/decode are
/// performance-critical; the slow-path fallback is always available.
pub fn initLUT() void {
    if (lut_ready) return;
    const table = std.heap.page_allocator.alloc([LUT_K]U480, LUT_N) catch
        @panic("combinadic: LUT allocation failed");

    // Row 0: C(0, k) = 0 for all k ≥ 1.
    for (&table[0]) |*cell| cell.* = ZERO;

    for (1..LUT_N) |n| {
        // k=1 (index 0): C(n,1) = C(n−1,1) + C(n−1,0) = prev + 1
        table[n][0] = u480_add(table[n - 1][0], ONE);
        // k=2..64 (index 1..63): Pascal's triangle
        for (1..LUT_K) |ki| {
            table[n][ki] = u480_add(table[n - 1][ki], table[n - 1][ki - 1]);
        }
    }
    lut_storage = table;
    lut_ready = true;
}

/// Retrieve C(n, k).  Uses the LUT when ready; falls back to the
/// multiplicative recurrence otherwise.  k must be ≥ 1.
inline fn lutGet(n: u32, k: u32) U480 {
    if (lut_ready) return lut_storage.?[n][k - 1];
    return binomial(n, k);
}

// ─── Serialisation ────────────────────────────────────────────────────────────

fn to_bytes(v: U480) [60]u8 {
    var out: [60]u8 = undefined;
    for (0..LIMBS) |li| {
        const start = li * 8;
        if (start >= 60) break;
        var buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &buf, v[li], .little);
        const end = @min(start + 8, 60);
        @memcpy(out[start..end], buf[0 .. end - start]);
    }
    return out;
}

fn from_bytes(enc: *const [60]u8) U480 {
    var v = ZERO;
    for (0..LIMBS) |li| {
        const start = li * 8;
        if (start >= 60) break;
        const end = @min(start + 8, 60);
        var buf: [8]u8 = .{ 0, 0, 0, 0, 0, 0, 0, 0 };
        @memcpy(buf[0 .. end - start], enc[start..end]);
        v[li] = std.mem.readInt(u64, &buf, .little);
    }
    return v;
}

// ─── Public API ───────────────────────────────────────────────────────────────

/// Encode a sorted DecodedFingerprint to its 60-byte combinadic form.
pub fn encode(fp: *const root.DecodedFingerprint) EncodedFingerprint {
    var acc = ZERO;
    for (fp, 0..) |a, idx| {
        const i: u32 = @intCast(idx + 1); // 1-based
        const b: u32 = @as(u32, a) + i - 1; // multiset → strictly increasing
        acc = u480_add(acc, lutGet(b, i));
    }
    return to_bytes(acc);
}

/// Decode a 60-byte combinadic representation to a DecodedFingerprint.
pub fn decode(enc: *const EncodedFingerprint) root.DecodedFingerprint {
    var n = from_bytes(enc);
    var fp: root.DecodedFingerprint = undefined;
    var upper: u32 = 4159; // bᵢ ≤ 4096 + 63 = 4159

    var i: u32 = root.PAGE_ENTRIES; // 64, counts down to 1
    while (i >= 1) : (i -= 1) {
        // Binary search: find largest b in [i−1, upper] s.t. C(b, i) ≤ n.
        var lo: u32 = i - 1;
        var hi: u32 = upper;
        while (lo < hi) {
            const mid = lo + (hi - lo + 1) / 2;
            if (u480_cmp(lutGet(mid, i), n) == .gt) {
                hi = mid - 1;
            } else {
                lo = mid;
            }
        }
        const b = lo;
        n = u480_sub(n, lutGet(b, i));
        fp[i - 1] = @intCast(b - (i - 1)); // recover aᵢ = bᵢ − (i−1)
        upper = if (b > 0) b - 1 else 0;
    }
    return fp;
}

// ─── Tests ────────────────────────────────────────────────────────────────────
//
// Tests run in declaration order.  The slow-path tests come first (lut_ready
// is false at that point).  The LUT tests call initLUT() and run after; from
// that point the global state has lut_ready=true, so any subsequent decode/
// encode calls also use the LUT — which is correct since both paths produce
// identical results.

test "binomial small values (slow path)" {
    const eq = std.testing.expectEqual;
    try eq(ONE, binomial(0, 0));
    try eq(ONE, binomial(5, 0));
    try eq(ONE, binomial(5, 5));
    try eq(ZERO, binomial(3, 5)); // k > n
    const c52: U480 = .{ 10, 0, 0, 0, 0, 0, 0, 0 };
    try eq(c52, binomial(5, 2));
    const c103: U480 = .{ 120, 0, 0, 0, 0, 0, 0, 0 };
    try eq(c103, binomial(10, 3));
    try eq(binomial(100, 3), binomial(100, 97)); // symmetry
}

test "encode/decode all-zero fingerprint (slow path)" {
    const fp = [_]u16{0} ** root.PAGE_ENTRIES;
    const enc = encode(&fp);
    try std.testing.expectEqual([_]u8{0} ** 60, enc);
    try std.testing.expectEqual(fp, decode(&enc));
}

test "encode/decode NULL_FINGERPRINT round-trip (slow path)" {
    const enc = encode(&root.NULL_FINGERPRINT);
    try std.testing.expectEqual(root.NULL_FINGERPRINT, decode(&enc));
}

test "encode/decode mixed fingerprint round-trip (slow path)" {
    var fp: root.DecodedFingerprint = [_]u16{root.FINGERPRINT_NULL} ** root.PAGE_ENTRIES;
    fp[0] = 0;
    fp[1] = 7;
    fp[2] = 42;
    fp[3] = 100;
    fp[4] = 1000;
    fp[5] = 4095;
    try std.testing.expectEqual(fp, decode(&encode(&fp)));
}

test "encode/decode dense fingerprint round-trip (slow path)" {
    var fp: root.DecodedFingerprint = undefined;
    for (&fp, 0..) |*s, i| s.* = @intCast(i);
    try std.testing.expectEqual(fp, decode(&encode(&fp)));
}

// ── LUT tests ─────────────────────────────────────────────────────────────────

test "initLUT populates correct values" {
    initLUT();
    const table = lut_storage.?;
    // C(n, 1) = n for all n
    for (0..LUT_N) |n| {
        const expected: U480 = .{ @intCast(n), 0, 0, 0, 0, 0, 0, 0 };
        try std.testing.expectEqual(expected, table[n][0]);
    }
    // Spot checks
    // C(5, 2) = 10
    const c52: U480 = .{ 10, 0, 0, 0, 0, 0, 0, 0 };
    try std.testing.expectEqual(c52, table[5][1]);
    // C(10, 3) = 120
    const c103: U480 = .{ 120, 0, 0, 0, 0, 0, 0, 0 };
    try std.testing.expectEqual(c103, table[10][2]);
    // LUT matches slow binomial
    try std.testing.expectEqual(binomial(100, 5), table[100][4]);
    try std.testing.expectEqual(binomial(200, 10), table[200][9]);
    try std.testing.expectEqual(binomial(4159, 64), table[4159][63]);
}

test "encode/decode NULL_FINGERPRINT round-trip (LUT)" {
    // lut_ready is true after the previous test
    const enc = encode(&root.NULL_FINGERPRINT);
    try std.testing.expectEqual(root.NULL_FINGERPRINT, decode(&enc));
}

test "encode/decode mixed fingerprint round-trip (LUT)" {
    var fp: root.DecodedFingerprint = [_]u16{root.FINGERPRINT_NULL} ** root.PAGE_ENTRIES;
    fp[0] = 0;
    fp[1] = 7;
    fp[2] = 42;
    fp[3] = 100;
    fp[4] = 1000;
    fp[5] = 4095;
    try std.testing.expectEqual(fp, decode(&encode(&fp)));
}

test "encode/decode dense fingerprint round-trip (LUT)" {
    var fp: root.DecodedFingerprint = undefined;
    for (&fp, 0..) |*s, i| s.* = @intCast(i);
    try std.testing.expectEqual(fp, decode(&encode(&fp)));
}
