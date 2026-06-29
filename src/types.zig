//! Core data types and constants shared across all PrefixDB modules.
//!
//! This file has no dependencies within the project other than merkle.zig
//! (for Hash), so every other module can import it without creating cycles.

const std = @import("std");
pub const merkle = @import("merkle.zig");

pub const Hash = merkle.Hash;
pub const ZERO_HASH = merkle.ZERO_HASH;

// ─── Parameters (§8.2) ────────────────────────────────────────────────────────

pub const STRIDE: u32 = 6;
pub const PAGE_ENTRIES: u32 = 64;
pub const CHILD_COUNT: u32 = 64;
pub const S_MAX: u32 = 104; // sorted zone capacity per node
pub const A_MAX: u32 = 12; // append zone capacity per node
pub const MERGE_THRESHOLD: u32 = 16;
pub const T_OPP: u32 = 2;

// ─── Core key/value types (§2.1) ──────────────────────────────────────────────

pub const Key = [32]u8;
pub const Value = [32]u8;
/// Sentinel value written by the delete operation; reads return "not found".
pub const TOMBSTONE: Value = [_]u8{0xFF} ** 32;

pub const KvEntry = struct {
    key: Key,
    value: Value,
};

// ─── Page addressing (§4.3) ───────────────────────────────────────────────────

pub const NodePageId = u32;
pub const PayloadSlotId = u32;
pub const PrefixData = u64;

// ─── SST payload page (§4.1) ──────────────────────────────────────────────────

pub const SstPage = struct {
    entries: [PAGE_ENTRIES]KvEntry,
    count: u8,
};

// ─── Node (index) page — commitments decoupled ────────────────────────────────
//
// On-disk: exactly 4096 bytes (one physical page).
//   4 B    header (sorted_count u8, append_count u8, _pad[2])
//   416 B  sorted_slot_ids[104]        (u32 each)
//   416 B  sorted_min4[104]            (u32 boundary prefix per sorted page, §7.1)
//   104 B  sorted_page_counts[104]     (u8 entry count per sorted page, 1..64)
//   12 B   append_page_counts[12]      (u8 entry count per append page, 1..64)
//   48 B   append_slot_ids[12]         (u32 each)
//   3072 B append_prefix32[12][64]     (u32 per key, per append page, §7.1)
//   24 B   _reserved

pub const NodePage = struct {
    sorted_count: u8,
    append_count: u8,
    sorted_slot_ids: [S_MAX]PayloadSlotId,
    sorted_min4: [S_MAX]u32,
    sorted_page_counts: [S_MAX]u8,
    append_page_counts: [A_MAX]u8,
    append_slot_ids: [A_MAX]PayloadSlotId,
    append_prefix32: [A_MAX][PAGE_ENTRIES]u32,
};


// ─── Commitment page ids ──────────────────────────────────────────────────────

pub const CommitmentPageId = u32;
/// Sentinel for "no persisted commitment page".
pub const CMT_NONE: CommitmentPageId = std.math.maxInt(u32);

// ─── Deferred-reuse free list for on-disk page ids ────────────────────────────
//
// Page slots in the container files are reused instead of growing forever.
// Reuse must not break crash recovery: the last durable manifest (plus the node
// pages it references) may still point at a page freed *after* that manifest
// was written.  Ids therefore quarantine in `pending` until the next manifest
// — which by construction no longer references them — is durably on disk; only
// then do they become allocatable.

pub const FreeList = struct {
    /// Ids dead in the last durable manifest — safe to reuse now.
    free: std.ArrayList(u32) = .empty,
    /// Ids freed since the last manifest write — reusable after the next one.
    pending: std.ArrayList(u32) = .empty,

    pub fn deinit(self: *FreeList, allocator: std.mem.Allocator) void {
        self.free.deinit(allocator);
        self.pending.deinit(allocator);
    }

    /// Quarantine a dead id until the next manifest checkpoint.
    pub fn release(self: *FreeList, allocator: std.mem.Allocator, id: u32) !void {
        try self.pending.append(allocator, id);
    }

    /// Pop a reusable id, or null when a fresh id must be allocated.
    pub fn acquire(self: *FreeList) ?u32 {
        return self.free.pop();
    }

    /// All ids that the manifest being written right now does not reference.
    /// Both lists qualify: once that manifest is durable, `pending` is dead too.
    pub fn totalLen(self: *const FreeList) u32 {
        return @intCast(self.free.items.len + self.pending.items.len);
    }

    /// Append free ++ pending into `out` (manifest serialisation order).
    pub fn appendAllTo(self: *const FreeList, allocator: std.mem.Allocator, out: *std.ArrayList(u32)) !void {
        try out.appendSlice(allocator, self.free.items);
        try out.appendSlice(allocator, self.pending.items);
    }

    /// The manifest excluding `pending`'s referents is durable: promote.
    pub fn promote(self: *FreeList, allocator: std.mem.Allocator) !void {
        try self.free.appendSlice(allocator, self.pending.items);
        self.pending.clearRetainingCapacity();
    }

    /// Restore from a recovered manifest: everything listed is immediately reusable.
    pub fn restore(self: *FreeList, allocator: std.mem.Allocator, ids: []const u32) !void {
        try self.free.appendSlice(allocator, ids);
    }
};

// ─── Canonical trie helpers (shared by root.zig and commitment.zig) ──────────

/// Bit `bit` of a 256-bit key, MSB-first (bit 0 = top bit of key[0]).
pub fn keyBit(key: *const Key, bit: u32) u1 {
    return @intCast((key[bit >> 3] >> @intCast(7 - (bit & 7))) & 1);
}

pub fn kvLessThan(_: void, a: KvEntry, b: KvEntry) bool {
    return std.mem.order(u8, &a.key, &b.key) == .lt;
}

/// Canonical trie value (commitment_v2.md §2) of the subtree at bit-depth
/// `bit` over `entries`, which must be sorted by key, unique, and
/// tombstone-free.  Pass-through collapse: a single entry IS the subtree value.
pub fn subtreeValue(entries: []const KvEntry, bit: u32) Hash {
    if (entries.len == 0) return ZERO_HASH;
    if (entries.len == 1) return merkle.leafHash(&entries[0].key, &entries[0].value);
    std.debug.assert(bit < 256); // >1 distinct keys must diverge within 256 bits
    // Sorted input: all bit=0 entries precede bit=1 entries; binary-search the split.
    var lo: usize = 0;
    var hi: usize = entries.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (keyBit(&entries[mid].key, bit) == 0) lo = mid + 1 else hi = mid;
    }
    const left = subtreeValue(entries[0..lo], bit + 1);
    const right = subtreeValue(entries[lo..], bit + 1);
    return merkle.combine(&left, &right);
}
