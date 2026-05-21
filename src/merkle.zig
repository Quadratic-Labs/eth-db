//! Commitment hash primitives.
//!
//! These are the only hash operations needed for PrefixDB commitment
//! maintenance.  The full binary Merkle trie is no longer held in memory as a
//! separate data structure; intermediate commitment hashes are co-located with
//! the routing index in NodePage.child_commitments (§4.2.2).

const std = @import("std");

/// A 32-byte Blake3 hash digest.
pub const Hash = [32]u8;

/// All-zero hash — the empty-node sentinel.
pub const ZERO_HASH: Hash = [_]u8{0} ** 32;

/// H(left ‖ right): combine two child hashes into a parent commitment.
/// Returns ZERO_HASH when both children are empty (all-zero input).
pub fn pairHash(left: *const Hash, right: *const Hash) Hash {
    var buf: [64]u8 = undefined;
    @memcpy(buf[0..32], left);
    @memcpy(buf[32..64], right);
    return hash64(buf);
}

/// Blake3 of a 32-byte input.
pub fn hash32(input: [32]u8) Hash {
    var out: Hash = undefined;
    std.crypto.hash.Blake3.hash(&input, &out, .{});
    return out;
}

/// Blake3 of a 64-byte input.
/// All-zero input returns ZERO_HASH (empty-node sentinel).
pub fn hash64(input: [64]u8) Hash {
    const zero: [64]u8 = [_]u8{0} ** 64;
    if (std.mem.eql(u8, &input, &zero)) return ZERO_HASH;
    var out: Hash = undefined;
    std.crypto.hash.Blake3.hash(&input, &out, .{});
    return out;
}

// ─── Tests ────────────────────────────────────────────────────────────────────

test "ZERO_HASH sentinel" {
    const left = ZERO_HASH;
    const right = ZERO_HASH;
    try std.testing.expectEqual(ZERO_HASH, pairHash(&left, &right));
}

test "hash32 is deterministic" {
    const input = [_]u8{0x42} ** 32;
    try std.testing.expectEqual(hash32(input), hash32(input));
}

test "pairHash differs from single input" {
    const a = hash32([_]u8{1} ** 32);
    const b = hash32([_]u8{2} ** 32);
    const ab = pairHash(&a, &b);
    try std.testing.expect(!std.mem.eql(u8, &ab, &a));
    try std.testing.expect(!std.mem.eql(u8, &ab, &b));
}
