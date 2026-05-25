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
pub const S_MAX: u32 = 108; // sorted zone capacity per node
pub const A_MAX: u32 = 8; // append zone capacity per node
pub const MAX_DEPTH: u32 = 5;
pub const MERGE_THRESHOLD: u32 = 16;
pub const T_OPP: u32 = 2;

// ─── Core key/value types (§2.1) ──────────────────────────────────────────────

pub const Key = [32]u8;
pub const Value = [32]u8;

pub const KvEntry = struct {
    key: Key,
    value: Value,
};

// ─── Page addressing (§4.3) ───────────────────────────────────────────────────

pub const NodePageId = u32;
pub const PayloadSlotId = u32;
pub const PrefixData = u32;

// ─── SST payload page (§4.1) ──────────────────────────────────────────────────

pub const SstPage = struct {
    entries: [PAGE_ENTRIES]KvEntry,
    count: u8,
};

// ─── Node page (§4.2.2) ───────────────────────────────────────────────────────
//
// On-disk: exactly 4096 bytes (one physical page).
//   4 B    header (sorted_count u8, append_count u8, _pad[2])
//   2048 B child_commitments[64]
//   432 B  sorted_slot_ids[108]        (u32 each)
//   432 B  sorted_min4[108]            (u32 boundary prefix per sorted page, §7.1)
//   108 B  sorted_page_counts[108]     (u8 entry count per sorted page, 1..64)
//   8 B    append_page_counts[8]       (u8 entry count per append page, 1..64)
//   32 B   append_slot_ids[8]          (u32 each)
//   1024 B append_prefix16[8][64]      (u16 per key, per append page, §7.1)
//   8 B    _reserved

pub const NodePage = struct {
    sorted_count: u8,
    append_count: u8,
    child_commitments: [CHILD_COUNT]Hash,
    sorted_slot_ids: [S_MAX]PayloadSlotId,
    sorted_min4: [S_MAX]u32,
    sorted_page_counts: [S_MAX]u8,
    append_page_counts: [A_MAX]u8,
    append_slot_ids: [A_MAX]PayloadSlotId,
    append_prefix16: [A_MAX][PAGE_ENTRIES]u16,
};
