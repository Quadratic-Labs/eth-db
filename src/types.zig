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
pub const S_MAX: u32 = 123; // sorted zone capacity per node
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
//   492 B  sorted_slot_ids[123]   (u32 each)
//   492 B  sorted_min4[123]       (u32 boundary prefix per sorted page, §7.1)
//   32 B   append_slot_ids[8]     (u32 each)
//   1024 B append_prefix16[8][64] (u16 per key, per append page, §7.1)
//   4 B    _reserved

pub const NodePage = struct {
    sorted_count: u8,
    append_count: u8,
    child_commitments: [CHILD_COUNT]Hash,
    sorted_slot_ids: [S_MAX]PayloadSlotId,
    sorted_min4: [S_MAX]u32,
    append_slot_ids: [A_MAX]PayloadSlotId,
    append_prefix16: [A_MAX][PAGE_ENTRIES]u16,
};
