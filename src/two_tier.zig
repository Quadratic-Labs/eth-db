//! Two-tier commitment over composite `account_hash ‖ slot_hash` keys
//! (docs/two_tier_plan.md).
//!
//! The state is a mapping `account → {slot → value}` whose keys are only
//! piecewise-uniform: uniform across account hashes, uniform across slot hashes
//! *within* an account, with heavy-tailed account sizes. The design keeps every
//! single-tier mechanism and makes exactly one boundary adaptive:
//!
//!   • **Account tree** — a plain `commitment.CommitmentDb` (0x01-tagged leaves)
//!     over the *accounts store* (32-byte keys: `account_hash → storage_root`).
//!     Uniform, so the fixed heap-depth machinery applies unchanged.
//!   • **Storage subtrees** — per account, over the *slots store* (64-byte
//!     composite keys). Small accounts (≤ T_big slots) are recomputed whole from
//!     one contiguous range gather. Big accounts get a per-account implicit heap
//!     of slot-unit values at depth ⌈log₂ n⌉ − k, so units stay ~2^k slots —
//!     the global design recursed one level down.
//!
//! Leaf rules (canonical, history-independent):
//!   storage leaf  = Blake3(0x00 ‖ slot_hash ‖ value)
//!   account leaf  = Blake3(0x01 ‖ account_hash ‖ storage_root)
//!   state root    = account tree over all accounts with non-ZERO storage root.
//!
//! **Write-back invariant (load-bearing):** the accounts store is entirely
//! commitment-maintained. At each commit, every dirty account's freshly computed
//! storage root is written into its account record through the normal `put` path
//! (deleted when the root is ZERO), *before* the account tree recomputes. An
//! account-unit gather therefore always sees correct roots: just-written for
//! dirty accounts, correct-as-of-last-commit for clean ones (induction).
//! Recovery follows: replayed blocks re-mark their accounts dirty, so stale
//! stored roots are exactly the recomputed set.
//!
//! Host contract: `putSlot`/`deleteSlot` during the block (or `markDirtySlot`
//! when replaying data the slots store already holds), `slots.endBlock(h)`,
//! then `commitBlock(accts, slots, h)` → state root. The accounts store's
//! `endBlock` is driven internally (its content is derived data).

const std = @import("std");
const t = @import("types.zig");
const fs = @import("flat_store.zig");
const cmt = @import("commitment.zig");
const Io = std.Io;

pub const Hash = t.Hash;
pub const ZERO_HASH = t.ZERO_HASH;

/// Accounts store: `account_hash (32 B) → storage_root (32 B)`.
pub const AcctStore = fs.FlatStore;
/// Slots store: `account_hash ‖ slot_hash (64 B) → value (32 B)`.
pub const SlotStore = fs.FlatStore64;
pub const Entry64 = SlotStore.Entry;

pub const ACCOUNT_LEAF_TAG: u8 = 0x01;

const CSTOR_MAGIC: u32 = 0x31_54_53_43; // "CST1"
const CSTOR_VERSION: u32 = 1;

/// Header of the big-account checkpoint file (`<name>.cstor`), followed by
/// `count` × { CstorAcct, 2^depth × u32 counts, 2^depth × 32 B leaf row }.
const CstorHeader = extern struct {
    magic: u32,
    version: u32,
    count: u32,
    t_big_log2: u32,
    covered_height: u64,
};
const CstorAcct = extern struct { acct: [32]u8, depth: u32, _pad: u32 = 0 };

pub const Config = struct {
    /// Account-tree heap depth (H of the single-tier design, over account hashes).
    acct_heap_depth: u6 = cmt.HEAP_DEPTH_DEFAULT,
    /// k = log₂ T_big: accounts with more than 2^k live slots get a per-account
    /// unit row (plan D6); k is also the per-unit recompute budget — big-account
    /// unit depth is ⌈log₂ n⌉ − k, so units hold ~2^k slots. Demotion at n < 2^k/2.
    t_big_log2: u6 = 12,
};

// ─── Composite-key helpers ─────────────────────────────────────────────────────

pub fn composeKey(acct: *const [32]u8, slot: *const [32]u8) SlotStore.Key {
    var k: SlotStore.Key = undefined;
    @memcpy(k[0..32], acct);
    @memcpy(k[32..64], slot);
    return k;
}

fn getSlotBit(key: *const SlotStore.Key, bit: u16) u1 {
    const b = 256 + @as(u32, bit); // bit index within the slot half
    return @intCast((key[b >> 3] >> @intCast(7 - (b & 7))) & 1);
}

/// Top `depth` bits of the slot half of a composite key — the slot-unit index.
fn slotUnitOfKey(key: *const SlotStore.Key, depth: u6) u64 {
    return std.mem.readInt(u64, key[32..40], .big) >> @intCast(@as(u7, 64) - depth);
}

/// Same, from a bare 32-byte slot hash.
fn slotUnitOfSlot(slot: *const [32]u8, depth: u6) u64 {
    return std.mem.readInt(u64, slot[0..8], .big) >> @intCast(@as(u7, 64) - depth);
}

/// `acct ‖ (u << (256 − depth))` — the composite lower bound of slot-unit `u`.
fn unitLoKey(acct: *const [32]u8, u: u64, depth: u6) SlotStore.Key {
    var k: SlotStore.Key = undefined;
    @memcpy(k[0..32], acct);
    @memset(k[32..], 0);
    std.mem.writeInt(u64, k[32..40], u << @intCast(@as(u7, 64) - depth), .big);
    return k;
}

/// `(acct + 1) ‖ 0` — the exclusive upper bound of the account's slot range
/// (null when acct is all-0xFF: unbounded).
fn acctHiKey(acct: *const [32]u8) ?SlotStore.Key {
    var k: SlotStore.Key = undefined;
    @memcpy(k[0..32], acct);
    @memset(k[32..], 0);
    var i: usize = 32;
    while (i > 0) {
        i -= 1;
        k[i] +%= 1;
        if (k[i] != 0) return k; // no carry out
    }
    return null; // acct was all-0xFF
}

/// Canonical value of a storage subtree at slot-bit depth `bit` over its live
/// entries (sorted by composite key, unique). Pure function of the slot mapping —
/// the per-account analog of the single-tier canonical function.
pub fn storageSubtreeRoot(entries: []const Entry64, bit: u16) Hash {
    if (entries.len == 0) return ZERO_HASH;
    if (entries.len == 1) return cmt.leafHashTagged(0x00, entries[0].key[32..64], &entries[0].value);
    std.debug.assert(bit < 256); // distinct slot hashes diverge within 256 bits
    var lo: usize = 0;
    var hi: usize = entries.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (getSlotBit(&entries[mid].key, bit) == 0) lo = mid + 1 else hi = mid;
    }
    const l = storageSubtreeRoot(entries[0..lo], bit + 1);
    const r = storageSubtreeRoot(entries[lo..], bit + 1);
    return cmt.combine(&l, &r);
}

// ─── Two-tier DB ───────────────────────────────────────────────────────────────

/// Per-account committer state for accounts above T_big: an implicit heap of
/// slot-unit values plus exact per-unit live counts (counts of untouched units
/// cannot drift, so their sum `n` is exact).
const BigAccount = struct {
    depth: u6, // unit row depth within the slot-hash space (≥ 1)
    n: u64, // live slots (= sum of counts)
    counts: []u32, // 2^depth
    heap: []Hash, // 2^(depth+1); heap[1] = storage root

    fn deinit(self: *BigAccount, allocator: std.mem.Allocator) void {
        allocator.free(self.counts);
        allocator.free(self.heap);
    }
};

const DirtyPair = struct { acct: [32]u8, slot: [32]u8 };

/// Breakdown of the last commitBlock, for benchmarks/telemetry.
pub const CommitStats = struct {
    /// Storage-root recomputes + account-record write-backs.
    storage_ns: u64 = 0,
    /// Accounts-store endBlock + account-tree commit.
    acct_tree_ns: u64 = 0,
    dirty_pairs: u64 = 0,
    dirty_accounts: u64 = 0,
};

fn nowNs() u64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

fn pairLess(_: void, a: DirtyPair, b: DirtyPair) bool {
    return switch (std.mem.order(u8, &a.acct, &b.acct)) {
        .lt => true,
        .gt => false,
        .eq => std.mem.order(u8, &a.slot, &b.slot) == .lt,
    };
}

pub const TwoTierDb = struct {
    allocator: std.mem.Allocator,
    cfg: Config,
    /// Account tree: the single-tier engine, verbatim, with 0x01-tagged leaves.
    acct_cdb: cmt.CommitmentDb,
    /// Per-account unit rows for accounts above T_big.
    big: std.AutoHashMap([32]u8, BigAccount),
    /// (account, slot) pairs written since the last commit (dupes fine — deduped
    /// by the commit's sort).
    dirty: std.ArrayList(DirtyPair),
    // Scratch reused across commits.
    gather_buf: std.ArrayList(Entry64),
    idx_buf: std.ArrayList(u64),
    /// Phase breakdown of the most recent commitBlock (zeroed timings if the
    /// platform lacks a monotonic clock).
    last_commit_stats: CommitStats = .{},

    pub fn init(allocator: std.mem.Allocator, cfg: Config) !TwoTierDb {
        std.debug.assert(cfg.t_big_log2 >= 1 and cfg.t_big_log2 <= 40);
        return .{
            .allocator = allocator,
            .cfg = cfg,
            .acct_cdb = try cmt.CommitmentDb.init(allocator, .{
                .heap_depth = cfg.acct_heap_depth,
                .leaf_tag = ACCOUNT_LEAF_TAG,
            }),
            .big = std.AutoHashMap([32]u8, BigAccount).init(allocator),
            .dirty = .empty,
            .gather_buf = .empty,
            .idx_buf = .empty,
        };
    }

    pub fn deinit(self: *TwoTierDb) void {
        var it = self.big.valueIterator();
        while (it.next()) |b| b.deinit(self.allocator);
        self.big.deinit();
        self.acct_cdb.deinit();
        self.dirty.deinit(self.allocator);
        self.gather_buf.deinit(self.allocator);
        self.idx_buf.deinit(self.allocator);
    }

    /// The state root as of the last commit/open.
    pub fn root(self: *const TwoTierDb) Hash {
        return self.acct_cdb.root();
    }

    pub fn committedHeight(self: *const TwoTierDb) u64 {
        return self.acct_cdb.committed_height;
    }

    fn tBig(self: *const TwoTierDb) u64 {
        return @as(u64, 1) << self.cfg.t_big_log2;
    }

    // ── Writes ─────────────────────────────────────────────────────────────────

    /// Record that (acct, slot) changed this block, without writing it — for
    /// replaying blocks the slots store already holds durably.
    pub fn markDirtySlot(self: *TwoTierDb, acct: *const [32]u8, slot: *const [32]u8) !void {
        try self.dirty.append(self.allocator, .{ .acct = acct.*, .slot = slot.* });
    }

    pub fn putSlot(self: *TwoTierDb, slots: *SlotStore, acct: *const [32]u8, slot: *const [32]u8, value: t.Value) !void {
        try slots.put(composeKey(acct, slot), value);
        try self.markDirtySlot(acct, slot);
    }

    pub fn deleteSlot(self: *TwoTierDb, slots: *SlotStore, acct: *const [32]u8, slot: *const [32]u8) !void {
        try slots.delete(composeKey(acct, slot));
        try self.markDirtySlot(acct, slot);
    }

    // ── Commit ─────────────────────────────────────────────────────────────────

    /// §two_tier_plan commit: per dirty account (storage roots first), write the
    /// root back into the accounts store, then run the account tree. Call at a
    /// block boundary, after `slots.endBlock(height)`.
    pub fn commitBlock(self: *TwoTierDb, accts: *AcctStore, slots: *SlotStore, height: u64) !Hash {
        const a = self.allocator;
        var stats: CommitStats = .{ .dirty_pairs = self.dirty.items.len };
        const t0 = nowNs();
        if (self.dirty.items.len > 0) {
            std.mem.sort(DirtyPair, self.dirty.items, {}, pairLess);
            const snap = try slots.memtableSnapshot(a);
            defer a.free(snap);

            var i: usize = 0;
            while (i < self.dirty.items.len) {
                const acct = self.dirty.items[i].acct;
                var j = i + 1;
                while (j < self.dirty.items.len and std.mem.eql(u8, &self.dirty.items[j].acct, &acct)) j += 1;
                const sroot = try self.storageRootFor(slots, snap, &acct, self.dirty.items[i..j]);
                // Write-back: the account record IS the storage root; a ZERO root
                // means "no storage" = absent account (canonicity: empty = never
                // existed). The account tree gathers these records.
                if (std.mem.eql(u8, &sroot, &ZERO_HASH)) {
                    try accts.delete(acct);
                } else {
                    try accts.put(acct, sroot);
                }
                try self.acct_cdb.markDirty(&acct);
                stats.dirty_accounts += 1;
                i = j;
            }
            self.dirty.clearRetainingCapacity();
        }
        const t1 = nowNs();
        stats.storage_ns = t1 - t0;
        try accts.endBlock(height); // derived-data store: lifecycle driven here
        const state_root = try self.acct_cdb.commitBlock(accts, height);
        stats.acct_tree_ns = nowNs() - t1;
        self.last_commit_stats = stats;
        return state_root;
    }

    /// Recompute one dirty account's storage root. `group` is its sorted dirty
    /// (acct, slot) list for this commit.
    fn storageRootFor(
        self: *TwoTierDb,
        slots: *SlotStore,
        snap: []const SlotStore.MemEntry,
        acct: *const [32]u8,
        group: []const DirtyPair,
    ) !Hash {
        const a = self.allocator;
        const acct_hi = acctHiKey(acct);
        const acct_hi_ptr: ?*const SlotStore.Key = if (acct_hi) |*h| h else null;

        if (self.big.getPtr(acct.*)) |b| {
            // Dirty units: group is slot-sorted, so unit ids are non-decreasing.
            const leaf_base = @as(u64, 1) << b.depth;
            self.idx_buf.clearRetainingCapacity();
            for (group) |p| {
                const u = slotUnitOfSlot(&p.slot, b.depth);
                if (self.idx_buf.items.len == 0 or self.idx_buf.items[self.idx_buf.items.len - 1] != leaf_base + u)
                    try self.idx_buf.append(a, leaf_base + u);
            }
            for (self.idx_buf.items) |hidx| {
                const u = hidx - leaf_base;
                const lo = unitLoKey(acct, u, b.depth);
                var hi_key: SlotStore.Key = undefined;
                var hi_ptr: ?*const SlotStore.Key = undefined;
                if (u + 1 == leaf_base) {
                    hi_ptr = acct_hi_ptr;
                } else {
                    hi_key = unitLoKey(acct, u + 1, b.depth);
                    hi_ptr = &hi_key;
                }
                self.gather_buf.clearRetainingCapacity();
                try slots.gatherBounds(a, &lo, hi_ptr, snap, &self.gather_buf);
                b.heap[hidx] = storageSubtreeRoot(self.gather_buf.items, b.depth);
                b.n = b.n - b.counts[u] + self.gather_buf.items.len;
                b.counts[u] = @intCast(self.gather_buf.items.len);
            }
            cmt.heapRecombine(b.heap, &self.idx_buf);
            const sroot = b.heap[1];
            if (b.n * 2 < self.tBig()) { // demote (hysteresis at T_big/2)
                b.deinit(a);
                _ = self.big.remove(acct.*);
            }
            return sroot;
        }

        // Small path: recompute the whole storage trie from one range gather.
        const lo = unitLoKey(acct, 0, 1);
        self.gather_buf.clearRetainingCapacity();
        try slots.gatherBounds(a, &lo, acct_hi_ptr, snap, &self.gather_buf);
        if (self.gather_buf.items.len > self.tBig())
            return self.promote(acct, self.gather_buf.items);
        return storageSubtreeRoot(self.gather_buf.items, 0);
    }

    /// Build a per-account unit row from the account's full (sorted) slot set and
    /// register it in `big`. Depth transitions are pure cache events — no
    /// committed value moves.
    fn promote(self: *TwoTierDb, acct: *const [32]u8, entries: []const Entry64) !Hash {
        const a = self.allocator;
        const n: u64 = entries.len;
        const depth: u6 = @intCast(@max(1, @as(i32, std.math.log2_int_ceil(u64, n)) - self.cfg.t_big_log2));
        const units = @as(u64, 1) << depth;

        const counts = try a.alloc(u32, @intCast(units));
        errdefer a.free(counts);
        @memset(counts, 0);
        const heap = try a.alloc(Hash, @intCast(2 * units));
        errdefer a.free(heap);
        @memset(heap, ZERO_HASH);

        var s: usize = 0;
        while (s < entries.len) {
            const u = slotUnitOfKey(&entries[s].key, depth);
            var e = s + 1;
            while (e < entries.len and slotUnitOfKey(&entries[e].key, depth) == u) e += 1;
            heap[@intCast(units + u)] = storageSubtreeRoot(entries[s..e], depth);
            counts[@intCast(u)] = @intCast(e - s);
            s = e;
        }
        cmt.heapRebuildInternals(heap);
        try self.big.put(acct.*, .{ .depth = depth, .n = n, .counts = counts, .heap = heap });
        return heap[1];
    }

    // ── Persistence ────────────────────────────────────────────────────────────
    // Two files, both pure cache: `<name>.croot` (account row, via the account
    // CommitmentDb) and `<name>.cstor` (big-account unit rows + counts). A missing
    // or stale cstor entry only costs a lazy re-promotion, never correctness.

    pub fn checkpoint(self: *const TwoTierDb, io: Io, dir: Io.Dir, name: []const u8) !void {
        try self.acct_cdb.checkpoint(io, dir, name);

        const hdr: CstorHeader = .{
            .magic = CSTOR_MAGIC,
            .version = CSTOR_VERSION,
            .count = self.big.count(),
            .t_big_log2 = self.cfg.t_big_log2,
            .covered_height = self.acct_cdb.committed_height,
        };
        var tb: [256]u8 = undefined;
        const tmp = try std.fmt.bufPrint(&tb, "{s}.cstor.tmp", .{name});
        {
            const wf = try dir.createFile(io, tmp, .{ .truncate = true });
            defer wf.close(io);
            var off: u64 = 0;
            try wf.writePositionalAll(io, std.mem.asBytes(&hdr), off);
            off += @sizeOf(CstorHeader);
            var it = self.big.iterator();
            while (it.next()) |kv| {
                const b = kv.value_ptr;
                const rec: CstorAcct = .{ .acct = kv.key_ptr.*, .depth = b.depth };
                try wf.writePositionalAll(io, std.mem.asBytes(&rec), off);
                off += @sizeOf(CstorAcct);
                try wf.writePositionalAll(io, std.mem.sliceAsBytes(b.counts), off);
                off += b.counts.len * 4;
                const row = b.heap[b.heap.len / 2 ..];
                try wf.writePositionalAll(io, std.mem.sliceAsBytes(row), off);
                off += row.len * 32;
            }
            try wf.sync(io);
        }
        var nb: [256]u8 = undefined;
        const fname = try std.fmt.bufPrint(&nb, "{s}.cstor", .{name});
        try dir.rename(tmp, dir, fname, io);
    }

    /// Restore from `<name>.croot` (+ `<name>.cstor` if present). Errors with
    /// `FileNotFound` when no croot exists — fall back to `init` then. The host
    /// replays blocks > committedHeight (re-marking their (acct, slot) pairs) and
    /// commits once.
    pub fn open(allocator: std.mem.Allocator, io: Io, dir: Io.Dir, name: []const u8, cfg: Config) !TwoTierDb {
        var db: TwoTierDb = .{
            .allocator = allocator,
            .cfg = cfg,
            .acct_cdb = try cmt.CommitmentDb.open(allocator, io, dir, name, .{
                .heap_depth = cfg.acct_heap_depth,
                .leaf_tag = ACCOUNT_LEAF_TAG,
            }),
            .big = std.AutoHashMap([32]u8, BigAccount).init(allocator),
            .dirty = .empty,
            .gather_buf = .empty,
            .idx_buf = .empty,
        };
        errdefer db.deinit();

        var nb: [256]u8 = undefined;
        const fname = try std.fmt.bufPrint(&nb, "{s}.cstor", .{name});
        const f = dir.openFile(io, fname, .{}) catch |err| switch (err) {
            // Big accounts simply re-promote lazily on their next dirty commit.
            error.FileNotFound => return db,
            else => return err,
        };
        defer f.close(io);

        var hdr: CstorHeader = undefined;
        var off: u64 = 0;
        if (try f.readPositionalAll(io, std.mem.asBytes(&hdr), off) != @sizeOf(CstorHeader)) return error.CstorTruncated;
        off += @sizeOf(CstorHeader);
        if (hdr.magic != CSTOR_MAGIC) return error.CstorBadMagic;
        if (hdr.version != CSTOR_VERSION) return error.CstorVersionMismatch;
        if (hdr.t_big_log2 != cfg.t_big_log2) return error.TBigMismatch;

        for (0..hdr.count) |_| {
            var rec: CstorAcct = undefined;
            if (try f.readPositionalAll(io, std.mem.asBytes(&rec), off) != @sizeOf(CstorAcct)) return error.CstorTruncated;
            off += @sizeOf(CstorAcct);
            const depth: u6 = @intCast(rec.depth);
            const units = @as(u64, 1) << depth;

            const counts = try allocator.alloc(u32, @intCast(units));
            errdefer allocator.free(counts);
            if (try f.readPositionalAll(io, std.mem.sliceAsBytes(counts), off) != units * 4) return error.CstorTruncated;
            off += units * 4;

            const heap = try allocator.alloc(Hash, @intCast(2 * units));
            errdefer allocator.free(heap);
            @memset(heap[0..@intCast(units)], ZERO_HASH);
            const row = heap[@intCast(units)..];
            if (try f.readPositionalAll(io, std.mem.sliceAsBytes(row), off) != units * 32) return error.CstorTruncated;
            off += units * 32;
            cmt.heapRebuildInternals(heap);

            var n: u64 = 0;
            for (counts) |c| n += c;
            try db.big.put(rec.acct, .{ .depth = depth, .n = n, .counts = counts, .heap = heap });
        }
        return db;
    }
};

// ─── Tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

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

fn entryLess(_: void, a: Entry64, b: Entry64) bool {
    return std.mem.order(u8, &a.key, &b.key) == .lt;
}

fn getBit32(key: *const [32]u8, bit: u16) u1 {
    return @intCast((key[bit >> 3] >> @intCast(7 - (bit & 7))) & 1);
}

const AcctPair = struct { key: [32]u8, leaf: Hash };

/// Account tree over precomputed account leaves (sorted, unique) — the naive
/// evaluator's upper level, independent of the heap machinery.
fn acctPairsRoot(pairs: []const AcctPair, bit: u16) Hash {
    if (pairs.len == 0) return ZERO_HASH;
    if (pairs.len == 1) return pairs[0].leaf;
    var lo: usize = 0;
    var hi: usize = pairs.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (getBit32(&pairs[mid].key, bit) == 0) lo = mid + 1 else hi = mid;
    }
    const l = acctPairsRoot(pairs[0..lo], bit + 1);
    const r = acctPairsRoot(pairs[lo..], bit + 1);
    return cmt.combine(&l, &r);
}

/// Naive two-tier evaluator over a flat composite-key reference map: group sorted
/// entries by account, per-account storage root, 0x01-tagged account leaves,
/// account tree from bit 0.
fn naiveTwoTierRoot(allocator: std.mem.Allocator, ref: *std.AutoHashMap(SlotStore.Key, t.Value)) !Hash {
    const entries = try allocator.alloc(Entry64, ref.count());
    defer allocator.free(entries);
    var it = ref.iterator();
    var i: usize = 0;
    while (it.next()) |kv| : (i += 1) entries[i] = .{ .key = kv.key_ptr.*, .value = kv.value_ptr.* };
    std.mem.sort(Entry64, entries, {}, entryLess);

    var pairs = std.ArrayList(AcctPair).empty;
    defer pairs.deinit(allocator);
    var s: usize = 0;
    while (s < entries.len) {
        var e = s + 1;
        while (e < entries.len and std.mem.eql(u8, entries[e].key[0..32], entries[s].key[0..32])) e += 1;
        const sroot = storageSubtreeRoot(entries[s..e], 0);
        var acct: [32]u8 = undefined;
        @memcpy(&acct, entries[s].key[0..32]);
        try pairs.append(allocator, .{ .key = acct, .leaf = cmt.leafHashTagged(ACCOUNT_LEAF_TAG, &acct, &sroot) });
        s = e;
    }
    return acctPairsRoot(pairs.items, 0);
}

const TestStores = struct {
    accts: AcctStore,
    slots: SlotStore,

    fn create(io: Io, dir: Io.Dir) !TestStores {
        const no_accts = [_]t.KvEntry{};
        const no_slots = [_]Entry64{};
        return .{
            .accts = try AcctStore.create(testing.allocator, io, dir, "acct", &no_accts, .{
                .prefix_bits = 2,
                .memtable_cap = 1_000_000,
                .l0_compact_threshold = 100,
                .freeze_block_interval = 1,
            }),
            .slots = try SlotStore.create(testing.allocator, io, dir, "slots", &no_slots, .{
                .prefix_bits = 2,
                .fence_gap = 8,
                .memtable_cap = 1_000_000,
                .l0_compact_threshold = 100,
                .freeze_block_interval = 2,
            }),
        };
    }

    fn open(io: Io, dir: Io.Dir) !TestStores {
        return .{
            .accts = try AcctStore.open(testing.allocator, io, dir, "acct", .{
                .prefix_bits = 2,
                .memtable_cap = 1_000_000,
                .l0_compact_threshold = 100,
                .freeze_block_interval = 1,
            }),
            .slots = try SlotStore.open(testing.allocator, io, dir, "slots", .{
                .prefix_bits = 2,
                .fence_gap = 8,
                .memtable_cap = 1_000_000,
                .l0_compact_threshold = 100,
                .freeze_block_interval = 2,
            }),
        };
    }

    fn deinit(self: *TestStores) void {
        self.accts.deinit();
        self.slots.deinit();
    }
};

test "TwoTierDb: engine matches naive across blocks, compaction, promotion, deletes" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var st = try TestStores.create(io, tmp.dir);
    defer st.deinit();
    var db = try TwoTierDb.init(testing.allocator, .{ .acct_heap_depth = 4, .t_big_log2 = 3 }); // T_big = 8
    defer db.deinit();

    var ref = std.AutoHashMap(SlotStore.Key, t.Value).init(testing.allocator);
    defer ref.deinit();
    var prng = std.Random.DefaultPrng.init(0x27_1E5);
    const rnd = prng.random();

    var saw_big = false;
    var h: u64 = 1;
    while (h <= 25) : (h += 1) {
        for (0..15) |_| {
            const acct = acctHash(rnd.intRangeLessThan(u64, 0, 12));
            const slot = slotHash(rnd.intRangeLessThan(u64, 0, 30));
            if (rnd.intRangeLessThan(u8, 0, 7) == 0) {
                try db.deleteSlot(&st.slots, &acct, &slot);
                _ = ref.remove(composeKey(&acct, &slot));
            } else {
                var value: t.Value = undefined;
                rnd.bytes(&value);
                try db.putSlot(&st.slots, &acct, &slot, value);
                try ref.put(composeKey(&acct, &slot), value);
            }
        }
        try st.slots.endBlock(h);
        if (h % 7 == 0) try st.slots.compact();
        const got = try db.commitBlock(&st.accts, &st.slots, h);
        try testing.expectEqual(try naiveTwoTierRoot(testing.allocator, &ref), got);
        if (db.big.count() > 0) saw_big = true;
    }
    try testing.expect(saw_big); // promotion path was exercised
}

test "TwoTierDb: history invariance — whale + churn vs single-block build" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // Final mapping: whale account 7 with slots 0..300 (value = slot id byte),
    // plus accounts 100..110 with 3 slots each.
    var ref = std.AutoHashMap(SlotStore.Key, t.Value).init(testing.allocator);
    defer ref.deinit();
    for (0..300) |s| try ref.put(composeKey(&acctHash(7), &slotHash(s)), [_]u8{@intCast(s % 251)} ** 32);
    for (100..110) |a| {
        for (0..3) |s| try ref.put(composeKey(&acctHash(a), &slotHash(s)), [_]u8{@intCast(a % 251)} ** 32);
    }
    const expected = try naiveTwoTierRoot(testing.allocator, &ref);

    // Pipeline A: everything in one block, one commit.
    {
        var dir_a = try tmp.dir.createDirPathOpen(io, "a", .{});
        defer dir_a.close(io);
        var st = try TestStores.create(io, dir_a);
        defer st.deinit();
        var db = try TwoTierDb.init(testing.allocator, .{ .acct_heap_depth = 4, .t_big_log2 = 3 });
        defer db.deinit();
        var it = ref.iterator();
        while (it.next()) |kv| {
            var acct: [32]u8 = undefined;
            var slot: [32]u8 = undefined;
            @memcpy(&acct, kv.key_ptr[0..32]);
            @memcpy(&slot, kv.key_ptr[32..64]);
            try db.putSlot(&st.slots, &acct, &slot, kv.value_ptr.*);
        }
        try st.slots.endBlock(1);
        try testing.expectEqual(expected, try db.commitBlock(&st.accts, &st.slots, 1));
        try testing.expectEqual(@as(u32, 1), db.big.count()); // the whale promoted
    }

    // Pipeline B: reverse order, wrong values overwritten, transient slots and a
    // transient account deleted, compactions between blocks, multi-block commits.
    {
        var dir_b = try tmp.dir.createDirPathOpen(io, "b", .{});
        defer dir_b.close(io);
        var st = try TestStores.create(io, dir_b);
        defer st.deinit();
        var db = try TwoTierDb.init(testing.allocator, .{ .acct_heap_depth = 4, .t_big_log2 = 3 });
        defer db.deinit();

        var h: u64 = 1;
        var s: i64 = 299;
        while (s >= 0) : (h += 1) {
            for (0..40) |_| {
                if (s < 0) break;
                const us: u64 = @intCast(s);
                try db.putSlot(&st.slots, &acctHash(7), &slotHash(us), [_]u8{0xEE} ** 32); // wrong value
                try db.putSlot(&st.slots, &acctHash(7), &slotHash(us), [_]u8{@intCast(us % 251)} ** 32);
                if (us % 10 == 0) { // transient slot, deleted in the same block
                    try db.putSlot(&st.slots, &acctHash(7), &slotHash(us + 10_000), [_]u8{0xDD} ** 32);
                    try db.deleteSlot(&st.slots, &acctHash(7), &slotHash(us + 10_000));
                }
                s -= 1;
            }
            try st.slots.endBlock(h);
            if (h % 3 == 0) try st.slots.compact();
            _ = try db.commitBlock(&st.accts, &st.slots, h);
        }
        // Transient account: appears, then fully emptied.
        try db.putSlot(&st.slots, &acctHash(555), &slotHash(0), [_]u8{9} ** 32);
        try st.slots.endBlock(h);
        _ = try db.commitBlock(&st.accts, &st.slots, h);
        h += 1;
        try db.deleteSlot(&st.slots, &acctHash(555), &slotHash(0));
        var a2: u64 = 109;
        while (a2 >= 100) : (a2 -= 1) {
            for (0..3) |sl| try db.putSlot(&st.slots, &acctHash(a2), &slotHash(sl), [_]u8{@intCast(a2 % 251)} ** 32);
        }
        try st.slots.endBlock(h);
        try st.slots.compact();
        try testing.expectEqual(expected, try db.commitBlock(&st.accts, &st.slots, h));
        // Emptied account is gone from the accounts store (write-back deletion).
        try testing.expectEqual(@as(?t.Value, null), try st.accts.get(acctHash(555)));
    }
}

test "TwoTierDb: promotion and demotion across T_big keep the root canonical" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var st = try TestStores.create(io, tmp.dir);
    defer st.deinit();
    var db = try TwoTierDb.init(testing.allocator, .{ .acct_heap_depth = 4, .t_big_log2 = 3 }); // T_big = 8, demote < 4
    defer db.deinit();

    var ref = std.AutoHashMap(SlotStore.Key, t.Value).init(testing.allocator);
    defer ref.deinit();
    const acct = acctHash(1);

    // Grow to 20 slots → promoted.
    for (0..20) |s| {
        try db.putSlot(&st.slots, &acct, &slotHash(s), [_]u8{@intCast(s + 1)} ** 32);
        try ref.put(composeKey(&acct, &slotHash(s)), [_]u8{@intCast(s + 1)} ** 32);
    }
    try st.slots.endBlock(1);
    try testing.expectEqual(try naiveTwoTierRoot(testing.allocator, &ref), try db.commitBlock(&st.accts, &st.slots, 1));
    try testing.expectEqual(@as(u32, 1), db.big.count());

    // Shrink to 2 slots → demoted (n < T_big/2), root still canonical.
    for (2..20) |s| {
        try db.deleteSlot(&st.slots, &acct, &slotHash(s));
        _ = ref.remove(composeKey(&acct, &slotHash(s)));
    }
    try st.slots.endBlock(2);
    try testing.expectEqual(try naiveTwoTierRoot(testing.allocator, &ref), try db.commitBlock(&st.accts, &st.slots, 2));
    try testing.expectEqual(@as(u32, 0), db.big.count());

    // Grow again past T_big → re-promoted, still canonical.
    for (0..15) |s| {
        try db.putSlot(&st.slots, &acct, &slotHash(100 + s), [_]u8{7} ** 32);
        try ref.put(composeKey(&acct, &slotHash(100 + s)), [_]u8{7} ** 32);
    }
    try st.slots.endBlock(3);
    try testing.expectEqual(try naiveTwoTierRoot(testing.allocator, &ref), try db.commitBlock(&st.accts, &st.slots, 3));
    try testing.expectEqual(@as(u32, 1), db.big.count());
}

test "TwoTierDb: checkpoint + open restores root and big rows; replay catches up" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var root3: Hash = undefined;
    var root4: Hash = undefined;
    var late: [12]DirtyPair = undefined;

    {
        var st = try TestStores.create(io, tmp.dir);
        defer st.deinit();
        var db = try TwoTierDb.init(testing.allocator, .{ .acct_heap_depth = 4, .t_big_log2 = 3 });
        defer db.deinit();

        // Blocks 1..3: whale (acct 2, 30 slots) + small accounts; slots freeze at
        // interval 2, so everything durable by height 4's endBlock.
        var h: u64 = 1;
        var id: u64 = 0;
        while (h <= 3) : (h += 1) {
            for (0..10) |_| {
                try db.putSlot(&st.slots, &acctHash(2), &slotHash(id), [_]u8{@intCast(id % 251)} ** 32);
                try db.putSlot(&st.slots, &acctHash(50 + id), &slotHash(0), [_]u8{1} ** 32);
                id += 1;
            }
            try st.slots.endBlock(h);
            root3 = try db.commitBlock(&st.accts, &st.slots, h);
        }
        try testing.expectEqual(@as(u32, 1), db.big.count());
        try db.checkpoint(io, tmp.dir, "state");

        // Block 4: more writes past the checkpoint (whale units + a new account).
        for (0..12) |k| {
            const acct = if (k < 8) acctHash(2) else acctHash(77);
            const slot = slotHash(1000 + k);
            late[k] = .{ .acct = acct, .slot = slot };
            try db.putSlot(&st.slots, &acct, &slot, [_]u8{0xAB} ** 32);
        }
        try st.slots.endBlock(4);
        try st.slots.freeze(4); // make block 4 durable in the slots store
        root4 = try db.commitBlock(&st.accts, &st.slots, 4);
        try testing.expect(!std.mem.eql(u8, &root3, &root4));
    }

    var st = try TestStores.open(io, tmp.dir);
    defer st.deinit();
    var db = try TwoTierDb.open(testing.allocator, io, tmp.dir, "state", .{ .acct_heap_depth = 4, .t_big_log2 = 3 });
    defer db.deinit();

    try testing.expectEqual(@as(u64, 3), db.committedHeight());
    try testing.expectEqual(root3, db.root()); // account row + big rows restored
    try testing.expectEqual(@as(u32, 1), db.big.count());

    // Replay block 4: data already durable in the slots store — re-mark and commit.
    for (late) |p| try db.markDirtySlot(&p.acct, &p.slot);
    try testing.expectEqual(root4, try db.commitBlock(&st.accts, &st.slots, 4));

    // T_big mismatch is rejected (structural for the cstor file).
    try testing.expectError(
        error.TBigMismatch,
        TwoTierDb.open(testing.allocator, io, tmp.dir, "state", .{ .acct_heap_depth = 4, .t_big_log2 = 5 }),
    );
}
