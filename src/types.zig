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
pub const MAX_SST_PER_NODE: u32 = 95;
pub const MAX_DEPTH: u32 = 5;
pub const PREFIX12_UNIVERSE: u32 = 4097;
pub const COMPACTION_TRIGGER: u32 = 64;
pub const MERGE_THRESHOLD: u32 = 16;
pub const T_OPP: u32 = 4;

// ─── Core key/value types (§2.1) ──────────────────────────────────────────────

pub const Key = [32]u8;
pub const Value = [32]u8;

pub const KvEntry = struct {
    key: Key,
    value: Value,
};

// ─── Decoded fingerprint (§7.1) ───────────────────────────────────────────────

pub const DecodedFingerprint = [PAGE_ENTRIES]u16;
pub const FINGERPRINT_NULL: u16 = 4096;
pub const NULL_FINGERPRINT: DecodedFingerprint = [_]u16{FINGERPRINT_NULL} ** PAGE_ENTRIES;

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

pub const NodePage = struct {
    sst_count: u8,
    sorted_page_count: u8,
    child_commitments: [CHILD_COUNT]Hash,
    payload_slot_ids: [MAX_SST_PER_NODE]PayloadSlotId,
    key_fingerprints: [MAX_SST_PER_NODE]DecodedFingerprint,
};
