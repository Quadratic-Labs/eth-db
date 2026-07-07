//! Commitment DB — the state-root layer over the flat store (specifications_v5.md §4).
//!
//! Committed values follow the canonical trie function of commitment_redesign.md §2:
//! a binary trie over the 256-bit key space with 65-byte leaf domain separation and
//! pass-through `combine` (empty siblings vanish — no hash chains through empty
//! levels). Everything in this module is cache policy around that function; creating,
//! destroying, or checkpointing any cached structure never changes a committed value.
//!
//! Tiers (§4.1–4.3):
//!   • Tier 1 — depths 0..H as one implicit heap array in RAM: `heap[1]` is the state
//!     root, `heap[2^H + p]` the depth-H subtree value of unit prefix `p`. H is the
//!     RAM-for-recompute knob (each +1 doubles heap RAM, halves unit recompute).
//!   • Tier 2 — below depth H nothing is stored: a dirty unit is recomputed from the
//!     flat store's live entries via the gather seam (`FlatStore.gatherRange`).
//!   • Tier 3 — leaf-hash blobs (§4.3): not implemented (pure-cache upgrade path).
//!
//! Host contract: for every write/delete of a block, call `markDirty` alongside the
//! flat-store write; at the block boundary (after `endBlock`) call `commitBlock`.
//! Recovery: `open` restores the checkpointed depth-H row and `committed_height`;
//! the host replays blocks > committed_height (re-marking their keys dirty — the
//! flat store may already hold the data durably) and calls `commitBlock` once.

const std = @import("std");
const t = @import("types.zig");
const fs = @import("flat_store.zig");
const Io = std.Io;

pub const Hash = t.Hash;
pub const ZERO_HASH = t.ZERO_HASH;

pub const HEAP_DEPTH_DEFAULT: u6 = 24;

const CROOT_MAGIC: u32 = 0x31_4F_52_43; // "CRO1"
const CROOT_VERSION: u32 = 1;

/// On-disk header of a depth-H row checkpoint (followed by 2^H × 32 B hashes).
const CrootHeader = extern struct {
    magic: u32,
    version: u32,
    heap_depth: u32,
    _pad: u32 = 0,
    covered_height: u64,
};

pub const Config = struct {
    /// Heap depth H (§4.1) — heap RAM = 2^(H+1) × 32 B (1.07 GiB at 24). Each +1
    /// halves unit-recompute I/O + CPU. Density guideline (not a safety limit):
    /// H ≤ log2(N) − 5. Structural for checkpoints: `open` requires the stored H.
    heap_depth: u6 = HEAP_DEPTH_DEFAULT,
};

// ─── Canonical trie function (commitment_redesign.md §2) ──────────────────────

/// leafHash(K, V) = Blake3(0x00 ‖ K ‖ V). The 65-byte input gives domain separation
/// from `combine`'s 64-byte input; the embedded full key gives position binding.
pub fn leafHash(key: *const t.Key, value: *const t.Value) Hash {
    var buf: [65]u8 = undefined;
    buf[0] = 0x00;
    @memcpy(buf[1..33], key);
    @memcpy(buf[33..65], value);
    var out: Hash = undefined;
    std.crypto.hash.Blake3.hash(&buf, &out, .{});
    return out;
}

/// Pass-through combine: an empty sibling passes the other side up unchanged, so a
/// lone key's leafHash survives to the first non-empty sibling with zero hashing.
pub fn combine(left: *const Hash, right: *const Hash) Hash {
    const lz = std.mem.eql(u8, left, &ZERO_HASH);
    const rz = std.mem.eql(u8, right, &ZERO_HASH);
    if (lz and rz) return ZERO_HASH;
    if (rz) return left.*;
    if (lz) return right.*;
    var buf: [64]u8 = undefined;
    @memcpy(buf[0..32], left);
    @memcpy(buf[32..64], right);
    var out: Hash = undefined;
    std.crypto.hash.Blake3.hash(&buf, &out, .{});
    return out;
}

fn getBit(key: *const t.Key, bit: u16) u1 {
    return @intCast((key[bit >> 3] >> @intCast(7 - (bit & 7))) & 1);
}

/// Canonical value of the subtree rooted at bit-depth `bit` over its live entries
/// (sorted by key, unique keys). At bit 0 over the full mapping this *is* the naive
/// §2 evaluator — the reference the heap-maintained root is tested against.
/// n entries cost n leafHashes + (n−1) combines; pass-through frames hash nothing.
pub fn subtreeRoot(entries: []const t.KvEntry, bit: u16) Hash {
    if (entries.len == 0) return ZERO_HASH;
    if (entries.len == 1) return leafHash(&entries[0].key, &entries[0].value);
    std.debug.assert(bit < 256); // distinct keys must diverge within 256 bits
    // Sorted keys ⇒ entries with `bit` clear precede entries with `bit` set.
    var lo: usize = 0;
    var hi: usize = entries.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (getBit(&entries[mid].key, bit) == 0) lo = mid + 1 else hi = mid;
    }
    const l = subtreeRoot(entries[0..lo], bit + 1);
    const r = subtreeRoot(entries[lo..], bit + 1);
    return combine(&l, &r);
}

/// Top `bits` bits of the key — the commitment-unit prefix (heap-leaf index offset).
fn unitPrefix(key: *const t.Key, bits: u6) u64 {
    const p = std.mem.readInt(u64, key[0..8], .big);
    return p >> @intCast(@as(u7, 64) - bits);
}

// ─── Commitment DB ────────────────────────────────────────────────────────────

pub const CommitmentDb = struct {
    allocator: std.mem.Allocator,
    /// Implicit complete binary tree, 2^(H+1) hashes: [0] unused, [1] = state root,
    /// [2^H + p] = unit p's subtree value. All values are canonical (§2) — the heap's
    /// own combines use the same pass-through rule, so sparse bottom rows stay exact.
    heap: []Hash,
    heap_depth: u6,
    /// Unit prefixes touched by writes since the last `commitBlock`.
    dirty: std.AutoHashMap(u64, void),
    /// Block height the heap reflects (advanced by commitBlock, persisted by
    /// checkpoint). After `open`, the host replays blocks > committed_height.
    committed_height: u64,
    /// Scratch reused across commits: dirty heap indices and one unit's gather.
    dirty_list: std.ArrayList(u64),
    gather_buf: std.ArrayList(t.KvEntry),

    pub fn init(allocator: std.mem.Allocator, config: Config) !CommitmentDb {
        const h = config.heap_depth;
        std.debug.assert(h >= 1 and h <= 40);
        const heap = try allocator.alloc(Hash, @as(usize, 2) << h);
        @memset(heap, ZERO_HASH);
        return .{
            .allocator = allocator,
            .heap = heap,
            .heap_depth = h,
            .dirty = std.AutoHashMap(u64, void).init(allocator),
            .committed_height = 0,
            .dirty_list = .empty,
            .gather_buf = .empty,
        };
    }

    pub fn deinit(self: *CommitmentDb) void {
        self.allocator.free(self.heap);
        self.dirty.deinit();
        self.dirty_list.deinit(self.allocator);
        self.gather_buf.deinit(self.allocator);
    }

    /// The state root as of the last commitBlock / rebuild / open.
    pub fn root(self: *const CommitmentDb) Hash {
        return self.heap[1];
    }

    fn leafBase(self: *const CommitmentDb) u64 {
        return @as(u64, 1) << self.heap_depth;
    }

    /// Record that `key` was written or deleted this block. Call alongside every
    /// flat-store `put`/`delete` (and for each replayed write after `open`).
    pub fn markDirty(self: *CommitmentDb, key: *const t.Key) !void {
        try self.dirty.put(unitPrefix(key, self.heap_depth), {});
    }

    /// §4.4 commit: recompute every dirty unit from the flat store's live entries,
    /// then re-combine the dirty ancestor paths (deduplicated per level) up to the
    /// root. Call at a block boundary — the store must hold exactly the mapping as
    /// of block `height`. Returns the new state root.
    pub fn commitBlock(self: *CommitmentDb, store: *fs.FlatStore, height: u64) !Hash {
        const a = self.allocator;
        self.committed_height = height;
        if (self.dirty.count() == 0) return self.heap[1];

        const snap = try store.memtableSnapshot(a);
        defer a.free(snap);

        self.dirty_list.clearRetainingCapacity();
        var it = self.dirty.keyIterator();
        while (it.next()) |p| try self.dirty_list.append(a, self.leafBase() + p.*);
        std.mem.sort(u64, self.dirty_list.items, {}, std.sort.asc(u64));

        for (self.dirty_list.items) |hidx| {
            const prefix = hidx - self.leafBase();
            self.gather_buf.clearRetainingCapacity();
            try store.gatherRange(a, prefix, self.heap_depth, snap, &self.gather_buf);
            self.heap[hidx] = subtreeRoot(self.gather_buf.items, self.heap_depth);
        }
        self.recombine();
        self.dirty.clearRetainingCapacity();
        return self.heap[1];
    }

    /// Re-combine ancestors of the (sorted, unique, same-level) heap indices in
    /// `dirty_list`, level by level, deduplicating shared parents. ~|dirty| × H
    /// combines worst case, less as paths converge.
    fn recombine(self: *CommitmentDb) void {
        var idxs = &self.dirty_list;
        while (idxs.items.len > 0 and idxs.items[0] != 1) {
            var w: usize = 0;
            var last: u64 = 0;
            for (idxs.items) |i| {
                const p = i >> 1;
                if (p == last) continue; // sibling already handled
                self.heap[p] = combine(&self.heap[2 * p], &self.heap[2 * p + 1]);
                idxs.items[w] = p;
                w += 1;
                last = p;
            }
            idxs.shrinkRetainingCapacity(w);
        }
    }

    /// Cold rebuild (§4.5 worst case): recompute every unit from the flat store, then
    /// all internal levels — one full pass, no checkpoint needed. Also the way to
    /// attach a fresh CommitmentDb (or a new H) to an existing store.
    pub fn rebuild(self: *CommitmentDb, store: *fs.FlatStore, height: u64) !Hash {
        const a = self.allocator;
        const snap = try store.memtableSnapshot(a);
        defer a.free(snap);
        const n_units = self.leafBase();
        var p: u64 = 0;
        while (p < n_units) : (p += 1) {
            self.gather_buf.clearRetainingCapacity();
            try store.gatherRange(a, p, self.heap_depth, snap, &self.gather_buf);
            self.heap[self.leafBase() + p] = subtreeRoot(self.gather_buf.items, self.heap_depth);
        }
        self.rebuildInternals();
        self.dirty.clearRetainingCapacity();
        self.committed_height = height;
        return self.heap[1];
    }

    /// Recompute heap levels H−1 … 0 from the leaf row (2^H combines).
    fn rebuildInternals(self: *CommitmentDb) void {
        var i: u64 = self.leafBase() - 1;
        while (i >= 1) : (i -= 1) {
            self.heap[i] = combine(&self.heap[2 * i], &self.heap[2 * i + 1]);
        }
    }

    // ─── Persistence (§4.5) ──────────────────────────────────────────────────────
    // The only persisted commitment state is the depth-H row + committed_height,
    // written out-of-place (temp + fsync + rename). Upper rows rebuild on open.

    /// Checkpoint the depth-H row to `<name>.croot`, atomically.
    pub fn checkpoint(self: *const CommitmentDb, io: Io, dir: Io.Dir, name: []const u8) !void {
        const hdr: CrootHeader = .{
            .magic = CROOT_MAGIC,
            .version = CROOT_VERSION,
            .heap_depth = self.heap_depth,
            .covered_height = self.committed_height,
        };
        var tb: [256]u8 = undefined;
        const tmp = try std.fmt.bufPrint(&tb, "{s}.croot.tmp", .{name});
        {
            const wf = try dir.createFile(io, tmp, .{ .truncate = true });
            defer wf.close(io);
            try wf.writePositionalAll(io, std.mem.asBytes(&hdr), 0);
            const row = self.heap[@intCast(self.leafBase())..];
            try wf.writePositionalAll(io, std.mem.sliceAsBytes(row), @sizeOf(CrootHeader));
            try wf.sync(io);
        }
        var nb: [256]u8 = undefined;
        const fname = try std.fmt.bufPrint(&nb, "{s}.croot", .{name});
        try dir.rename(tmp, dir, fname, io);
    }

    /// Restore from `<name>.croot`: load the depth-H row, rebuild the upper levels,
    /// expose `committed_height`. The stored H must match `config.heap_depth`
    /// (error.HeapDepthMismatch otherwise — use `rebuild` to change H). The host then
    /// replays blocks > committed_height: re-mark their written keys dirty and call
    /// `commitBlock` (the flat store may already hold those writes durably).
    pub fn open(allocator: std.mem.Allocator, io: Io, dir: Io.Dir, name: []const u8, config: Config) !CommitmentDb {
        var nb: [256]u8 = undefined;
        const fname = try std.fmt.bufPrint(&nb, "{s}.croot", .{name});
        const f = try dir.openFile(io, fname, .{});
        defer f.close(io);

        var hdr: CrootHeader = undefined;
        const hn = try f.readPositionalAll(io, std.mem.asBytes(&hdr), 0);
        if (hn != @sizeOf(CrootHeader)) return error.CrootTruncated;
        if (hdr.magic != CROOT_MAGIC) return error.CrootBadMagic;
        if (hdr.version != CROOT_VERSION) return error.CrootVersionMismatch;
        if (hdr.heap_depth != config.heap_depth) return error.HeapDepthMismatch;

        var db = try init(allocator, config);
        errdefer db.deinit();
        const row = db.heap[@intCast(db.leafBase())..];
        const rn = try f.readPositionalAll(io, std.mem.sliceAsBytes(row), @sizeOf(CrootHeader));
        if (rn != row.len * 32) return error.CrootTruncated;
        db.rebuildInternals();
        db.committed_height = hdr.covered_height;
        return db;
    }
};

// ─── Tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

fn kvLess(_: void, a: t.KvEntry, b: t.KvEntry) bool {
    return std.mem.order(u8, &a.key, &b.key) == .lt;
}

/// Naive §2 evaluator over a plain map: sort, evaluate from bit 0. The reference
/// every engine root is compared against (commitment_redesign.md §8).
fn naiveRoot(allocator: std.mem.Allocator, reference: *std.AutoHashMap(t.Key, t.Value)) !Hash {
    const entries = try allocator.alloc(t.KvEntry, reference.count());
    defer allocator.free(entries);
    var it = reference.iterator();
    var i: usize = 0;
    while (it.next()) |kv| : (i += 1) entries[i] = .{ .key = kv.key_ptr.*, .value = kv.value_ptr.* };
    std.mem.sort(t.KvEntry, entries, {}, kvLess);
    return subtreeRoot(entries, 0);
}

fn keyFromU64(hi: u64) t.Key {
    var k = std.mem.zeroes(t.Key);
    std.mem.writeInt(u64, k[0..8], hi, .big);
    return k;
}

/// Pseudo-random but id-stable key (same pool as the flat-store tests), so
/// overwrites and deletes hit existing keys.
fn poolKey(id: u64) t.Key {
    return keyFromU64(id *% 0x9E37_79B9_7F4A_7C15 +% 0x1234);
}

fn valOf(b: u8) t.Value {
    return [_]u8{b} ** 32;
}

test "combine: pass-through identities" {
    const a = leafHash(&poolKey(1), &valOf(1));
    const z = ZERO_HASH;
    try testing.expectEqual(ZERO_HASH, combine(&z, &z));
    try testing.expectEqual(a, combine(&a, &z)); // right empty ⇒ left passes through
    try testing.expectEqual(a, combine(&z, &a)); // left empty ⇒ right passes through
    const b = leafHash(&poolKey(2), &valOf(2));
    const ab = combine(&a, &b);
    try testing.expect(!std.mem.eql(u8, &ab, &a));
    try testing.expect(!std.mem.eql(u8, &ab, &b));
}

test "leafHash: domain-separated from combine" {
    // A leaf over (K, V) must differ from an internal node over children (K, V).
    var k: t.Key = [_]u8{7} ** 32;
    var v: t.Value = [_]u8{9} ** 32;
    try testing.expect(!std.mem.eql(u8, &leafHash(&k, &v), &combine(&k, &v)));
}

test "subtreeRoot: empty, single leaf at any depth, deep shared prefixes" {
    try testing.expectEqual(ZERO_HASH, subtreeRoot(&.{}, 0));

    // Pass-through: a single key's value is its leafHash at every level.
    const one = [_]t.KvEntry{.{ .key = poolKey(5), .value = valOf(5) }};
    try testing.expectEqual(leafHash(&one[0].key, &one[0].value), subtreeRoot(&one, 0));
    try testing.expectEqual(subtreeRoot(&one, 0), subtreeRoot(&one, 200));

    // Two keys sharing a 200-bit prefix: no hash chains through the shared levels —
    // the pair value is one combine of the two leaves, regardless of starting bit.
    var k1 = [_]u8{0xAB} ** 32;
    var k2 = [_]u8{0xAB} ** 32;
    k1[25] = 0x00; // diverge at byte 25
    k2[25] = 0x80;
    const pair = [_]t.KvEntry{
        .{ .key = k1, .value = valOf(1) },
        .{ .key = k2, .value = valOf(2) },
    };
    const l = leafHash(&k1, &valOf(1));
    const r = leafHash(&k2, &valOf(2));
    try testing.expectEqual(combine(&l, &r), subtreeRoot(&pair, 0));
    try testing.expectEqual(combine(&l, &r), subtreeRoot(&pair, 100));
}

test "CommitmentDb: empty store root is ZERO; single key root is its leafHash" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const empty = [_]t.KvEntry{};
    var store = try fs.FlatStore.create(testing.allocator, io, tmp.dir, "flat", &empty, .{ .prefix_bits = 4, .memtable_cap = 1_000_000 });
    defer store.deinit();
    var cdb = try CommitmentDb.init(testing.allocator, .{ .heap_depth = 6 });
    defer cdb.deinit();

    try testing.expectEqual(ZERO_HASH, cdb.root());
    try testing.expectEqual(ZERO_HASH, try cdb.commitBlock(&store, 1));

    const k = poolKey(42);
    try store.put(k, valOf(0xAA));
    try cdb.markDirty(&k);
    try testing.expectEqual(leafHash(&k, &valOf(0xAA)), try cdb.commitBlock(&store, 2));
}

test "CommitmentDb: engine root matches naive evaluator across blocks, freezes, compaction, deletes" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const empty = [_]t.KvEntry{};
    // freeze_block_interval=2 + periodic compaction exercises all three tiers under gather.
    var store = try fs.FlatStore.create(testing.allocator, io, tmp.dir, "flat", &empty, .{ .prefix_bits = 4, .memtable_cap = 1_000_000, .l0_compact_threshold = 100, .freeze_block_interval = 2 });
    defer store.deinit();
    var cdb = try CommitmentDb.init(testing.allocator, .{ .heap_depth = 6 }); // H > prefix_bits: sub-partition units
    defer cdb.deinit();

    var reference = std.AutoHashMap(t.Key, t.Value).init(testing.allocator);
    defer reference.deinit();
    var prng = std.Random.DefaultPrng.init(0xC0117);
    const rnd = prng.random();

    var h: u64 = 1;
    while (h <= 30) : (h += 1) {
        for (0..15) |_| {
            const key = poolKey(rnd.intRangeLessThan(u64, 0, 200));
            if (rnd.intRangeLessThan(u8, 0, 10) == 0) { // occasional delete
                try store.delete(key);
                _ = reference.remove(key);
            } else {
                var value: t.Value = undefined;
                rnd.bytes(&value);
                try store.put(key, value);
                try reference.put(key, value);
            }
            try cdb.markDirty(&key);
        }
        try store.endBlock(h);
        if (h % 7 == 0) try store.compact();
        const got = try cdb.commitBlock(&store, h);
        try testing.expectEqual(try naiveRoot(testing.allocator, &reference), got);
    }
}

test "CommitmentDb: history invariance — same mapping, different pipelines and H, same root" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // Final mapping: keys 0..120 with value = id (keys 40..60 arrive via
    // overwrite/delete churn in pipeline B).
    var expected_entries: [120]t.KvEntry = undefined;
    for (&expected_entries, 0..) |*e, i| e.* = .{ .key = poolKey(i), .value = valOf(@intCast(i)) };
    std.mem.sort(t.KvEntry, &expected_entries, {}, kvLess);
    const expected = subtreeRoot(&expected_entries, 0); // naive reference

    // Pipeline A: base built up front, root via cold rebuild. H spans < = > prefix_bits.
    {
        var store = try fs.FlatStore.create(testing.allocator, io, tmp.dir, "flatA", &expected_entries, .{ .prefix_bits = 4 });
        defer store.deinit();
        for ([_]u6{ 2, 4, 9 }) |h| {
            var cdb = try CommitmentDb.init(testing.allocator, .{ .heap_depth = h });
            defer cdb.deinit();
            try testing.expectEqual(expected, try cdb.rebuild(&store, 1));
        }
    }

    // Pipeline B: reverse write order, churn (overwrites + deletes of transient keys),
    // freezes and compactions interleaved, root maintained incrementally.
    {
        const empty = [_]t.KvEntry{};
        var store = try fs.FlatStore.create(testing.allocator, io, tmp.dir, "flatB", &empty, .{ .prefix_bits = 4, .memtable_cap = 1_000_000, .l0_compact_threshold = 100, .freeze_block_interval = 1 });
        defer store.deinit();
        var cdb = try CommitmentDb.init(testing.allocator, .{ .heap_depth = 6 });
        defer cdb.deinit();

        var h: u64 = 1;
        var id: i64 = 119;
        while (id >= 0) : (h += 1) {
            for (0..20) |_| {
                if (id < 0) break;
                const uid: u64 = @intCast(id);
                const key = poolKey(uid);
                if (uid >= 40 and uid < 60) { // churn: wrong value, transient key, delete, fix
                    try store.put(key, valOf(0xEE));
                    try cdb.markDirty(&key);
                    const transient = poolKey(uid + 10_000);
                    try store.put(transient, valOf(0xDD));
                    try cdb.markDirty(&transient);
                    try store.delete(transient);
                }
                try store.put(key, valOf(@intCast(uid)));
                try cdb.markDirty(&key);
                id -= 1;
            }
            try store.endBlock(h);
            if (h % 3 == 0) try store.compact();
            _ = try cdb.commitBlock(&store, h);
        }
        try store.compact();
        try testing.expectEqual(expected, try cdb.commitBlock(&store, h));
    }
}

test "CommitmentDb: incremental maintenance equals cold rebuild" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const empty = [_]t.KvEntry{};
    var store = try fs.FlatStore.create(testing.allocator, io, tmp.dir, "flat", &empty, .{ .prefix_bits = 4, .memtable_cap = 1_000_000, .l0_compact_threshold = 100, .freeze_block_interval = 3 });
    defer store.deinit();
    var cdb = try CommitmentDb.init(testing.allocator, .{ .heap_depth = 5 });
    defer cdb.deinit();

    var prng = std.Random.DefaultPrng.init(0x5EED);
    const rnd = prng.random();
    var h: u64 = 1;
    while (h <= 10) : (h += 1) {
        for (0..25) |_| {
            const key = poolKey(rnd.intRangeLessThan(u64, 0, 150));
            var value: t.Value = undefined;
            rnd.bytes(&value);
            try store.put(key, value);
            try cdb.markDirty(&key);
        }
        try store.endBlock(h);
        _ = try cdb.commitBlock(&store, h);
    }

    // The memtable still holds unfrozen writes — gather must see all tiers.
    var fresh = try CommitmentDb.init(testing.allocator, .{ .heap_depth = 5 });
    defer fresh.deinit();
    try testing.expectEqual(cdb.root(), try fresh.rebuild(&store, h));
}

test "CommitmentDb: checkpoint + open restores the root; replay catches up; H mismatch rejected" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const cfg: fs.Config = .{ .prefix_bits = 4, .memtable_cap = 1_000_000, .l0_compact_threshold = 100, .freeze_block_interval = 1 };
    var root_mid: Hash = undefined;
    var root_final: Hash = undefined;
    var late_keys: [40]t.Key = undefined; // written after the checkpoint — the replay set

    {
        const empty = [_]t.KvEntry{};
        var store = try fs.FlatStore.create(testing.allocator, io, tmp.dir, "flat", &empty, cfg);
        defer store.deinit();
        var cdb = try CommitmentDb.init(testing.allocator, .{ .heap_depth = 6 });
        defer cdb.deinit();

        // Blocks 1..4: 80 keys, freeze every block (interval 1) so all writes are durable.
        var id: u64 = 0;
        var h: u64 = 1;
        while (h <= 4) : (h += 1) {
            for (0..20) |_| {
                const key = poolKey(id);
                try store.put(key, valOf(@intCast(id & 0xff)));
                try cdb.markDirty(&key);
                id += 1;
            }
            try store.endBlock(h);
            root_mid = try cdb.commitBlock(&store, h);
        }
        try cdb.checkpoint(io, tmp.dir, "flat"); // covers height 4

        // Blocks 5..6: 40 more keys, durable in the flat store but past the checkpoint.
        while (h <= 6) : (h += 1) {
            for (0..20) |_| {
                const key = poolKey(id);
                late_keys[id - 80] = key;
                try store.put(key, valOf(@intCast(id & 0xff)));
                try cdb.markDirty(&key);
                id += 1;
            }
            try store.endBlock(h);
            root_final = try cdb.commitBlock(&store, h);
        }
        try testing.expect(!std.mem.eql(u8, &root_mid, &root_final));
    }

    // Recover: flat store has everything (height 6); croot covers height 4.
    var store = try fs.FlatStore.open(testing.allocator, io, tmp.dir, "flat", cfg);
    defer store.deinit();
    try testing.expectEqual(@as(u64, 6), store.covered_height);

    try testing.expectError(error.HeapDepthMismatch, CommitmentDb.open(testing.allocator, io, tmp.dir, "flat", .{ .heap_depth = 7 }));

    var cdb = try CommitmentDb.open(testing.allocator, io, tmp.dir, "flat", .{ .heap_depth = 6 });
    defer cdb.deinit();
    try testing.expectEqual(@as(u64, 4), cdb.committed_height);
    try testing.expectEqual(root_mid, cdb.root()); // restored row + rebuilt internals

    // Replay blocks 5..6: the data is already durable in the flat store, so recovery
    // is re-marking the replayed writes dirty and committing once.
    for (late_keys) |k| try cdb.markDirty(&k);
    try testing.expectEqual(root_final, try cdb.commitBlock(&store, 6));

    // Checkpoint at the final height: a clean reopen needs no replay at all.
    try cdb.checkpoint(io, tmp.dir, "flat");
    var cdb2 = try CommitmentDb.open(testing.allocator, io, tmp.dir, "flat", .{ .heap_depth = 6 });
    defer cdb2.deinit();
    try testing.expectEqual(@as(u64, 6), cdb2.committed_height);
    try testing.expectEqual(root_final, cdb2.root());
}
