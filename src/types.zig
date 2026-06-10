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

// ─── Commitment page (docs/commitment_redesign.md §3.1) ───────────────────────
//
// The complete 6-level binary subtree of one (depth, prefix) node, stored as an
// implicit heap: h[1] is the node's own subtree commitment, h[2i]/h[2i+1] are
// the children of h[i], and h[64..127] are the 64 child-slot values at depth+1.
// All values follow the canonical pass-through `combine` rule (§2), so stored
// internals are canonical trie values usable directly in Merkle proofs.
//
// On-disk: exactly 4096 bytes.
//   4 B    header (version u8, flags u8, _pad[2])
//   8 B    leaf_valid (u64 LE) — lazy-leaf validity bitmap
//   20 B   _reserved
//   4064 B h[1..127] (127 × 32 B)

pub const CommitmentPageId = u32;
/// Sentinel for "no persisted commitment page" in routing/manifest entries.
pub const CMT_NONE: CommitmentPageId = std.math.maxInt(u32);

pub const CommitmentPage = struct {
    /// Bit c set ⇔ h[64+c] holds the canonical value of child slot c.
    /// Invalid leaves are filled lazily (gather or child h[1]) before any
    /// internal value of this page is used.
    leaf_valid: u64,
    /// Implicit heap; h[0] is unused padding.
    h: [128]Hash,

    pub const EMPTY = CommitmentPage{
        .leaf_valid = 0,
        .h = [_]Hash{ZERO_HASH} ** 128,
    };
};
