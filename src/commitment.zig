//! Commitment subsystem v2 — sparse leaf pages (docs/commitment_v2.md).
//!
//! One page type.  A page covers a key span identified by an arbitrary-length
//! bit prefix and owns the span's live keys either INLINE (key + leafHash
//! pairs) or DELEGATED to a child page covering a longer prefix.  The page's
//! span value is the canonical pass-through trie value (§2) over its units,
//! maintained as a hash-augmented crit-bit tree: internal nodes exist only at
//! bit positions where units actually diverge, which is exactly where the
//! canonical rules hash.  Delegation is itself prefix-based (PATRICIA at page
//! granularity), so splits always move a crit-bit subtree — roughly half the
//! page — into a child at the subtree's natural divergence prefix.  Clusters
//! of keys sharing arbitrarily long prefixes therefore never cascade.
//!
//! The engine is fully decoupled from the storage tree: updates are driven by
//! the block's write stream alone and never read storage pages.

const std = @import("std");
const options = @import("options");
const t = @import("types.zig");
const merkle = @import("merkle.zig");
const page_store = @import("page_store.zig");

const Key = t.Key;
const Value = t.Value;
const Hash = t.Hash;
const KvEntry = t.KvEntry;
const ZERO_HASH = t.ZERO_HASH;
const TOMBSTONE = t.TOMBSTONE;
const FreeList = t.FreeList;
const keyBit = t.keyBit;

pub const PAGE_SIZE: u32 = 4096;
const PAGE_VERSION: u8 = 2;
const HEADER_SIZE: u32 = 32;
/// Delegated unit on disk: nav prefix 32 B + span_bits u16 + pad u16 +
/// child_page_id u32 + child span value 32 B.
const DELEG_SIZE: u32 = 72;
/// Inline unit on disk: key 32 B + leafHash 32 B.
const INLINE_SIZE: u32 = 64;
/// Re-inline a child into its parent when its content is at most this many
/// bytes (and the parent has room).
pub const MERGE_MAX_BYTES: u32 = 512;

/// Lazy persistence policy (docs/commitment_v2.md phase 3): a dirty page is
/// flushed once it has been untouched for IDLE_AGE blocks, or unconditionally
/// once it has been dirty for MAX_DIRTY blocks.  MAX_DIRTY bounds both the
/// WAL retention window and crash-recovery replay time; raising it coalesces
/// more touches per page flush.
pub const FLUSH_IDLE_AGE: u32 = 64;
pub const FLUSH_MAX_DIRTY: u32 = 1024;

pub const CMT_NONE: u32 = std.math.maxInt(u32);
const NONE: u16 = std.math.maxInt(u16);

/// Capacity rule from the on-disk layout.
fn unitBytes(m: u32, n: u32) u32 {
    return HEADER_SIZE + DELEG_SIZE * m + INLINE_SIZE * n;
}

fn fits(m: u32, n: u32) bool {
    return unitBytes(m, n) <= PAGE_SIZE;
}

/// First bit position (MSB-first) where two distinct keys differ.
fn firstDiffBit(a: *const Key, b: *const Key) u32 {
    var i: u32 = 0;
    while (i < 4) : (i += 1) {
        const wa = std.mem.readInt(u64, a[i * 8 ..][0..8], .big);
        const wb = std.mem.readInt(u64, b[i * 8 ..][0..8], .big);
        if (wa != wb) return i * 64 + @clz(wa ^ wb);
    }
    unreachable; // callers guarantee a != b
}

/// Do the first `bits` bits of `key` match `prefix`?
fn prefixMatches(key: *const Key, prefix: *const Key, bits: u32) bool {
    std.debug.assert(bits <= 256);
    const full_bytes = bits / 8;
    if (!std.mem.eql(u8, key[0..full_bytes], prefix[0..full_bytes])) return false;
    const rem: u3 = @intCast(bits % 8);
    if (rem == 0) return true;
    const mask = @as(u8, 0xFF) << @intCast(8 - @as(u4, rem));
    return (key[full_bytes] & mask) == (prefix[full_bytes] & mask);
}

/// `key` with all bits at positions ≥ `bits` cleared (canonical nav prefix).
fn maskKey(key: *const Key, bits: u32) Key {
    var out: Key = [_]u8{0} ** 32;
    const full_bytes = bits / 8;
    @memcpy(out[0..full_bytes], key[0..full_bytes]);
    const rem: u3 = @intCast(bits % 8);
    if (rem != 0) {
        out[full_bytes] = key[full_bytes] & (@as(u8, 0xFF) << @intCast(8 - @as(u4, rem)));
    }
    return out;
}

pub const CmtStats = if (options.enable_metrics) struct {
    apply_ns: u64 = 0,
    propagate_ns: u64 = 0,
    splits: u64 = 0,
    merges: u64 = 0,
    page_loads: u64 = 0,
    page_flushes: u64 = 0,
    page_evictions: u64 = 0,
    ids_reused: u64 = 0,
    combines: u64 = 0,
    walk_hops: u64 = 0,
} else struct {};

/// Module-level instrumentation (engine is single-threaded; metrics builds only).
var g_combines: u64 = 0;
var g_walk_hops: u64 = 0;

fn monoNs() u64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

// ─── Page ──────────────────────────────────────────────────────────────────────

const NodeKind = enum(u8) { internal, inline_leaf, delegated };

/// Hot half of a pool node: everything a walk or stale-mark touches, packed
/// to 8 bytes so eight nodes share a cache line (walks dominate commit cost).
const NodeHot = struct {
    crit: u16 = 0,
    left: u16 = NONE,
    right: u16 = NONE,
    kind: NodeKind,
    stale: bool = false,
};

/// Cold half: hashes, keys and child linkage, touched only on hits.
const NodeCold = struct {
    hash: Hash,
    key: Key,
    child_id: u32 = CMT_NONE,
    child: ?*Page = null,
};

/// Interchange representation of one unit (collect/rebuild/serde).
/// Internal nodes never appear in unit lists.
const Node = struct {
    kind: NodeKind,
    /// Internal: divergence bit (0..255).  Delegated: span length in bits.
    crit: u16 = 0,
    /// Internal: child pool indices.
    left: u16 = NONE,
    right: u16 = NONE,
    /// Internal: combine(left, right).  Inline leaf: leafHash(K, V).
    /// Delegated leaf: the child span's canonical value.
    hash: Hash,
    /// Inline leaf: the full key.  Delegated leaf: the span prefix, padded
    /// with zero bits (canonical nav key).
    key: Key,
    /// Delegated leaf only: last persisted child page id (CMT_NONE if never).
    child_id: u32 = CMT_NONE,
    /// Delegated leaf only: the loaded child page.
    child: ?*Page = null,
    /// Internal only: hash is out of date (lazy rehash, see Page.value).
    stale: bool = false,
};

pub const Page = struct {
    /// Span prefix of this page: the first `span_bits` bits of `nav`.
    nav: Key = [_]u8{0} ** 32,
    span_bits: u32 = 0,
    parent: ?*Page,

    hot: std.ArrayList(NodeHot) = .empty,
    cold: std.ArrayList(NodeCold) = .empty,
    free_nodes: std.ArrayList(u16) = .empty,
    root: u16 = NONE,

    n_inline: u32 = 0,
    m_deleg: u32 = 0,

    /// Unflushed changes since the last persist.
    dirty: bool = false,
    /// Listed in the engine's per-block dirty bucket.
    in_block_dirty: bool = false,
    /// Listed in the engine's flush list.
    in_flush_list: bool = false,
    /// Block number of the last modification (flush aging).
    last_write: u32 = 0,
    /// Block number of the last descent through this page (eviction aging).
    last_touch: u32 = 0,
    /// Stable persisted page id, assigned at first flush (CMT_NONE before).
    /// Never changes afterwards: updates write in place, alternating between
    /// the id's two physical slots (torn-write safe via version + crc).
    page_id: u32 = CMT_NONE,
    /// Monotonic flush version; the slot written is version % 2.
    flush_version: u32 = 0,
    /// Block at which the page became dirty (pins the WAL replay window).
    first_dirty_block: u32 = 0,
    /// Cleared when the page is logically deleted mid-block (graveyard).
    alive: bool = true,

    fn create(allocator: std.mem.Allocator, nav: Key, span_bits: u32, parent: ?*Page) !*Page {
        const p = try allocator.create(Page);
        p.* = .{ .nav = nav, .span_bits = span_bits, .parent = parent };
        return p;
    }

    fn destroy(self: *Page, allocator: std.mem.Allocator) void {
        self.hot.deinit(allocator);
        self.cold.deinit(allocator);
        self.free_nodes.deinit(allocator);
        allocator.destroy(self);
    }

    /// The page's span value.  Internal hashes are maintained lazily: updates
    /// mark their root-to-leaf paths stale, and this resolves the union of all
    /// stale paths in one bottom-up pass — shared segments (pages receiving
    /// many child pushes) are combined exactly once.
    pub fn value(self: *Page) Hash {
        if (self.root == NONE) return ZERO_HASH;
        self.rehashStale(self.root);
        return self.cold.items[self.root].hash;
    }

    fn rehashStale(self: *Page, idx: u16) void {
        const h = &self.hot.items[idx];
        if (h.kind != .internal or !h.stale) return;
        self.rehashStale(h.left);
        self.rehashStale(h.right);
        if (comptime options.enable_metrics) g_combines += 1;
        self.cold.items[idx].hash = merkle.combine(
            &self.cold.items[h.left].hash,
            &self.cold.items[h.right].hash,
        );
        h.stale = false;
    }

    pub fn unitCount(self: *const Page) u32 {
        return self.n_inline + self.m_deleg;
    }

    fn contentBytes(self: *const Page) u32 {
        return unitBytes(self.m_deleg, self.n_inline);
    }

    fn allocNode(self: *Page, allocator: std.mem.Allocator, hot: NodeHot, cold: NodeCold) !u16 {
        if (self.free_nodes.pop()) |idx| {
            self.hot.items[idx] = hot;
            self.cold.items[idx] = cold;
            return idx;
        }
        const idx: u16 = @intCast(self.hot.items.len);
        try self.hot.append(allocator, hot);
        try self.cold.append(allocator, cold);
        return idx;
    }

    fn allocUnit(self: *Page, allocator: std.mem.Allocator, unit: Node) !u16 {
        return self.allocNode(
            allocator,
            .{ .kind = unit.kind, .crit = unit.crit },
            .{ .hash = unit.hash, .key = unit.key, .child_id = unit.child_id, .child = unit.child },
        );
    }

    fn freeNode(self: *Page, allocator: std.mem.Allocator, idx: u16) void {
        self.free_nodes.append(allocator, idx) catch {};
        self.cold.items[idx].child = null;
    }

    /// Mark the internal nodes along `path` stale; value() recombines them.
    fn markPath(self: *Page, path: []const u16) void {
        for (path) |idx| {
            const h = &self.hot.items[idx];
            if (h.kind == .internal) h.stale = true;
        }
    }

    /// Walk to the leaf the crit-bit structure selects for `key`, recording
    /// the internal path.  Returns the leaf index.
    fn walk(self: *const Page, key: *const Key, path: *[300]u16, plen: *usize) u16 {
        var idx = self.root;
        plen.* = 0;
        while (true) {
            const h = self.hot.items[idx];
            if (h.kind != .internal) return idx;
            if (comptime options.enable_metrics) g_walk_hops += 1;
            path[plen.*] = idx;
            plen.* += 1;
            idx = if (keyBit(key, h.crit) == 0) h.left else h.right;
        }
    }

    const UpsertResult = enum { inserted, updated };

    /// Insert or update the unit at `key`.  Standard crit-bit insert with
    /// hash maintenance.  The caller guarantees `key` is not inside any
    /// delegated span of this page (ownership is checked by descent).
    fn upsertNode(self: *Page, allocator: std.mem.Allocator, key: *const Key, make: Node) !UpsertResult {
        if (self.root == NONE) {
            self.root = try self.allocUnit(allocator, make);
            return .inserted;
        }
        var path: [300]u16 = undefined;
        var plen: usize = 0;
        const idx = self.walk(key, &path, &plen);
        const leaf = &self.cold.items[idx];
        if (std.mem.eql(u8, &leaf.key, key)) {
            std.debug.assert(self.hot.items[idx].kind == make.kind);
            leaf.hash = make.hash;
            self.markPath(path[0..plen]);
            return .updated;
        }
        try self.spliceNew(allocator, key, make, path[0..plen], idx);
        return .inserted;
    }

    /// Splice a new leaf next to walk result (`path`, landing leaf `idx`).
    fn spliceNew(self: *Page, allocator: std.mem.Allocator, key: *const Key, make: Node, path: []const u16, idx: u16) !void {
        const c = firstDiffBit(key, &self.cold.items[idx].key);
        // Splice above the first node whose crit bit is below c.
        var pos: usize = 0;
        while (pos < path.len and self.hot.items[path[pos]].crit < c) pos += 1;
        const below: u16 = if (pos < path.len) path[pos] else idx;

        const new_leaf = try self.allocUnit(allocator, make);
        var internal = NodeHot{ .kind = .internal, .crit = @intCast(c), .stale = true };
        if (keyBit(key, c) == 0) {
            internal.left = new_leaf;
            internal.right = below;
        } else {
            internal.left = below;
            internal.right = new_leaf;
        }
        const new_int = try self.allocNode(allocator, internal, .{ .hash = undefined, .key = undefined });
        if (pos == 0) {
            self.root = new_int;
        } else {
            const par = &self.hot.items[path[pos - 1]];
            if (par.left == below) par.left = new_int else par.right = new_int;
        }
        self.markPath(path[0..pos]);
    }

    /// Remove the unit at exactly `key` if it has kind `kind`.
    /// Returns the removed leaf's Node, or null if absent.
    fn removeNode(self: *Page, allocator: std.mem.Allocator, key: *const Key, kind: NodeKind) ?Node {
        if (self.root == NONE) return null;
        var path: [300]u16 = undefined;
        var plen: usize = 0;
        const idx = self.walk(key, &path, &plen);
        const lh = self.hot.items[idx];
        const lc = self.cold.items[idx];
        if (lh.kind != kind or !std.mem.eql(u8, &lc.key, key)) return null;

        if (plen == 0) {
            self.root = NONE;
        } else {
            const par_idx = path[plen - 1];
            const par = self.hot.items[par_idx];
            const sibling = if (par.left == idx) par.right else par.left;
            if (plen == 1) {
                self.root = sibling;
            } else {
                const gp = &self.hot.items[path[plen - 2]];
                if (gp.left == par_idx) gp.left = sibling else gp.right = sibling;
            }
            self.freeNode(allocator, par_idx);
            self.markPath(path[0 .. plen - 1]);
        }
        self.freeNode(allocator, idx);
        return .{ .kind = lh.kind, .crit = lh.crit, .hash = lc.hash, .key = lc.key, .child_id = lc.child_id, .child = lc.child };
    }

    /// Upsert an inline entry.  Capacity must be ensured by the caller.
    fn upsertInline(self: *Page, allocator: std.mem.Allocator, key: Key, leaf_hash: Hash) !UpsertResult {
        const res = try self.upsertNode(allocator, &key, .{
            .kind = .inline_leaf,
            .hash = leaf_hash,
            .key = key,
        });
        if (res == .inserted) self.n_inline += 1;
        return res;
    }

    /// Remove an inline entry; true if it existed.
    fn removeInline(self: *Page, allocator: std.mem.Allocator, key: *const Key) bool {
        if (self.removeNode(allocator, key, .inline_leaf)) |_| {
            self.n_inline -= 1;
            return true;
        }
        return false;
    }

    /// Push a fresh child span value into this page's delegated leaf at
    /// `nav` (which must exist).
    fn updateDelegated(self: *Page, nav: *const Key, child_value: Hash) void {
        var path: [300]u16 = undefined;
        var plen: usize = 0;
        const idx = self.walk(nav, &path, &plen);
        const leaf = &self.cold.items[idx];
        std.debug.assert(self.hot.items[idx].kind == .delegated and std.mem.eql(u8, &leaf.key, nav));
        if (std.mem.eql(u8, &leaf.hash, &child_value)) return;
        leaf.hash = child_value;
        self.markPath(path[0..plen]);
    }

    /// In-order unit collection (sorted by key, since crit bits order the tree).
    fn collectUnits(self: *const Page, allocator: std.mem.Allocator, out: *std.ArrayList(Node)) !void {
        if (self.root == NONE) return;
        try self.collectFrom(self.root, allocator, out);
    }

    fn collectFrom(self: *const Page, idx: u16, allocator: std.mem.Allocator, out: *std.ArrayList(Node)) !void {
        const h = self.hot.items[idx];
        if (h.kind == .internal) {
            try self.collectFrom(h.left, allocator, out);
            try self.collectFrom(h.right, allocator, out);
            return;
        }
        const c = self.cold.items[idx];
        try out.append(allocator, .{ .kind = h.kind, .crit = h.crit, .hash = c.hash, .key = c.key, .child_id = c.child_id, .child = c.child });
    }

    /// Rebuild the crit-bit tree from sorted units (bulk load).
    fn rebuild(self: *Page, allocator: std.mem.Allocator, units: []const Node) !void {
        self.hot.clearRetainingCapacity();
        self.cold.clearRetainingCapacity();
        self.free_nodes.clearRetainingCapacity();
        self.n_inline = 0;
        self.m_deleg = 0;
        if (units.len == 0) {
            self.root = NONE;
            return;
        }
        self.root = try self.buildRange(allocator, units);
    }

    fn buildRange(self: *Page, allocator: std.mem.Allocator, units: []const Node) !u16 {
        if (units.len == 1) {
            const idx = try self.allocUnit(allocator, units[0]);
            switch (units[0].kind) {
                .inline_leaf => self.n_inline += 1,
                .delegated => self.m_deleg += 1,
                .internal => unreachable,
            }
            return idx;
        }
        const c = firstDiffBit(&units[0].key, &units[units.len - 1].key);
        // Sorted input: all bit-c=0 units precede bit-c=1 units.
        var lo: usize = 0;
        var hi: usize = units.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (keyBit(&units[mid].key, c) == 0) lo = mid + 1 else hi = mid;
        }
        const l = try self.buildRange(allocator, units[0..lo]);
        const r = try self.buildRange(allocator, units[lo..]);
        if (comptime options.enable_metrics) g_combines += 1;
        return try self.allocNode(
            allocator,
            .{ .kind = .internal, .crit = @intCast(c), .left = l, .right = r },
            .{ .hash = merkle.combine(&self.cold.items[l].hash, &self.cold.items[r].hash), .key = undefined },
        );
    }

    // ── Serde ────────────────────────────────────────────────────────────────

    pub fn serialize(self: *const Page, allocator: std.mem.Allocator, scratch: *std.ArrayList(Node), buf: *[PAGE_SIZE]u8) !void {
        @memset(buf, 0);
        buf[0] = PAGE_VERSION;
        std.mem.writeInt(u16, buf[2..4], @intCast(self.n_inline), .little);
        std.mem.writeInt(u16, buf[4..6], @intCast(self.m_deleg), .little);
        std.mem.writeInt(u16, buf[6..8], @intCast(self.span_bits), .little);
        std.mem.writeInt(u32, buf[8..12], self.flush_version, .little);
        // buf[12..16]: crc32 over the page with this field zeroed (set last).

        scratch.clearRetainingCapacity();
        try self.collectUnits(allocator, scratch);
        // Delegated section then inline section, both in key order.
        var off: usize = HEADER_SIZE;
        for (scratch.items) |nd| {
            if (nd.kind != .delegated) continue;
            std.debug.assert(nd.child_id != CMT_NONE); // flush order guarantees this
            @memcpy(buf[off..][0..32], &nd.key);
            std.mem.writeInt(u16, buf[off + 32 ..][0..2], nd.crit, .little); // span_bits
            std.mem.writeInt(u32, buf[off + 36 ..][0..4], nd.child_id, .little);
            @memcpy(buf[off + 40 ..][0..32], &nd.hash);
            off += DELEG_SIZE;
        }
        for (scratch.items) |nd| {
            if (nd.kind != .inline_leaf) continue;
            @memcpy(buf[off..][0..32], &nd.key);
            @memcpy(buf[off + 32 ..][0..32], &nd.hash);
            off += INLINE_SIZE;
        }
        std.debug.assert(off <= PAGE_SIZE);
        std.mem.writeInt(u32, buf[12..16], std.hash.Crc32.hash(buf), .little);
    }

    /// Validate a slot image: crc must match (detects torn writes and
    /// never-written slots).  Returns the flush version, or null if invalid.
    pub fn slotVersion(buf: *const [PAGE_SIZE]u8) ?u32 {
        if (buf[0] != PAGE_VERSION) return null;
        var copy = buf.*;
        const stored = std.mem.readInt(u32, copy[12..16], .little);
        std.mem.writeInt(u32, copy[12..16], 0, .little);
        if (std.hash.Crc32.hash(&copy) != stored) return null;
        return std.mem.readInt(u32, buf[8..12], .little);
    }

    pub fn deserialize(self: *Page, allocator: std.mem.Allocator, scratch: *std.ArrayList(Node), buf: *const [PAGE_SIZE]u8) !void {
        if (buf[0] != PAGE_VERSION) return error.CmtPageVersionMismatch;
        self.flush_version = std.mem.readInt(u32, buf[8..12], .little);
        const n: u32 = std.mem.readInt(u16, buf[2..4], .little);
        const m: u32 = std.mem.readInt(u16, buf[4..6], .little);
        self.span_bits = std.mem.readInt(u16, buf[6..8], .little);

        // Merge the two key-ordered sections into one sorted unit list.
        scratch.clearRetainingCapacity();
        try scratch.ensureUnusedCapacity(allocator, n + m);
        const ioff_base: usize = HEADER_SIZE + @as(usize, m) * DELEG_SIZE;
        var di: u32 = 0;
        var ii: u32 = 0;
        while (di < m or ii < n) {
            const doff = HEADER_SIZE + di * DELEG_SIZE;
            const ioff = ioff_base + ii * INLINE_SIZE;
            const take_deleg = if (di >= m)
                false
            else if (ii >= n)
                true
            else
                std.mem.order(u8, buf[doff..][0..32], buf[ioff..][0..32]) == .lt;
            if (take_deleg) {
                var nd = Node{ .kind = .delegated, .hash = undefined, .key = undefined };
                @memcpy(&nd.key, buf[doff..][0..32]);
                nd.crit = std.mem.readInt(u16, buf[doff + 32 ..][0..2], .little);
                nd.child_id = std.mem.readInt(u32, buf[doff + 36 ..][0..4], .little);
                @memcpy(&nd.hash, buf[doff + 40 ..][0..32]);
                scratch.appendAssumeCapacity(nd);
                di += 1;
            } else {
                var nd = Node{ .kind = .inline_leaf, .hash = undefined, .key = undefined };
                @memcpy(&nd.key, buf[ioff..][0..32]);
                @memcpy(&nd.hash, buf[ioff + 32 ..][0..32]);
                scratch.appendAssumeCapacity(nd);
                ii += 1;
            }
        }
        try self.rebuild(allocator, scratch.items);
    }
};

// ─── Engine ────────────────────────────────────────────────────────────────────

pub const Engine = struct {
    allocator: std.mem.Allocator,
    root_page: *Page,
    store: ?page_store.CommitmentPageStore = null,

    next_id: u32 = 0,
    free: FreeList = .{},

    /// Pages changed by the current block, bucketed by span length so that
    /// propagation runs strictly deepest-first (a page must receive every
    /// child push before pushing its own value upward).
    block_dirty: [257]std.ArrayList(*Page),
    /// Pages logically deleted mid-block; destroyed at block end.
    graveyard: std.ArrayList(*Page) = .empty,
    /// Pages with unflushed changes (persist-level dirty).
    flush_list: std.ArrayList(*Page) = .empty,
    /// Ids of retired pages; reusable only after the next full flush.
    retired_ids: std.ArrayList(u32) = .empty,
    /// Scratch for splits/merges/serde.
    scratch_units: std.ArrayList(Node) = .empty,
    scratch_units2: std.ArrayList(Node) = .empty,

    current_block: u32 = 0,
    /// Number of pages currently materialised in RAM.
    loaded_pages: u32 = 1, // the root
    /// Eviction threshold: clean, cold pages are dropped (and reloaded from
    /// disk on demand) once the loaded count exceeds this.
    max_loaded: u32 = 131_072,
    stats: CmtStats = .{},

    pub fn init(allocator: std.mem.Allocator, store: ?page_store.CommitmentPageStore) !Engine {
        const root = try Page.create(allocator, [_]u8{0} ** 32, 0, null);
        var buckets: [257]std.ArrayList(*Page) = undefined;
        for (&buckets) |*b| b.* = .empty;
        return .{
            .allocator = allocator,
            .root_page = root,
            .store = store,
            .block_dirty = buckets,
        };
    }

    pub fn deinit(self: *Engine) void {
        self.destroyTree(self.root_page);
        for (&self.block_dirty) |*b| b.deinit(self.allocator);
        self.graveyard.deinit(self.allocator);
        self.flush_list.deinit(self.allocator);
        self.retired_ids.deinit(self.allocator);
        self.scratch_units.deinit(self.allocator);
        self.scratch_units2.deinit(self.allocator);
        self.free.deinit(self.allocator);
    }

    fn destroyTree(self: *Engine, page: *Page) void {
        for (page.hot.items, page.cold.items) |h, c| {
            if (h.kind != .delegated) continue;
            // Pool holes have child == null (freeNode clears it).
            if (c.child) |child| self.destroyTree(child);
        }
        page.destroy(self.allocator);
    }

    pub fn rootValue(self: *const Engine) Hash {
        return self.root_page.value();
    }

    fn allocPageId(self: *Engine) u32 {
        if (self.free.acquire()) |id| {
            if (comptime options.enable_metrics) self.stats.ids_reused += 1;
            return id;
        }
        const id = self.next_id;
        self.next_id += 1;
        return id;
    }

    /// Upsert `key → leaf_hash` with a single walk per page: the walk that
    /// finds the landing leaf simultaneously decides between descending into
    /// a delegated child, updating in place, splitting, or splicing.
    fn applyUpsert(self: *Engine, key: *const Key, leaf_hash: Hash) !void {
        var page = self.root_page;
        descend: while (true) {
            page.last_touch = self.current_block;
            if (page.root == NONE) {
                _ = try page.upsertInline(self.allocator, key.*, leaf_hash);
                try self.markDirty(page);
                return;
            }
            var path: [300]u16 = undefined;
            var plen: usize = 0;
            const idx = page.walk(key, &path, &plen);
            const lh = page.hot.items[idx];
            const leaf = &page.cold.items[idx];
            if (lh.kind == .delegated and prefixMatches(key, &leaf.key, lh.crit)) {
                if (leaf.child == null) leaf.child = try self.loadChild(page, leaf.key, lh.crit, leaf.child_id);
                page = leaf.child.?;
                continue :descend;
            }
            if (lh.kind == .inline_leaf and std.mem.eql(u8, &leaf.key, key)) {
                leaf.hash = leaf_hash;
                page.markPath(path[0..plen]);
                try self.markDirty(page);
                return;
            }
            // Insertion required; the walk is invalidated by a split, so
            // re-enter the loop on the same page (it still owns the key or
            // delegates it to the new child).
            if (!fits(page.m_deleg, page.n_inline + 1)) {
                try self.split(page);
                continue :descend;
            }
            try page.spliceNew(self.allocator, key, .{
                .kind = .inline_leaf,
                .hash = leaf_hash,
                .key = key.*,
            }, path[0..plen], idx);
            page.n_inline += 1;
            try self.markDirty(page);
            return;
        }
    }

    /// Descend to the page owning `key`, loading delegated children on demand.
    fn descendOwner(self: *Engine, key: *const Key) !*Page {
        var p = self.root_page;
        descend: while (true) {
            p.last_touch = self.current_block;
            if (p.root == NONE) return p;
            var path: [300]u16 = undefined;
            var plen: usize = 0;
            const idx = p.walk(key, &path, &plen);
            const h = p.hot.items[idx];
            const nd = &p.cold.items[idx];
            if (h.kind == .delegated and prefixMatches(key, &nd.key, h.crit)) {
                if (nd.child == null) nd.child = try self.loadChild(p, nd.key, h.crit, nd.child_id);
                p = nd.child.?;
                continue :descend;
            }
            return p;
        }
    }

    fn loadChild(self: *Engine, parent: *Page, nav: Key, span_bits: u32, child_id: u32) !*Page {
        std.debug.assert(child_id != CMT_NONE);
        self.loaded_pages += 1;
        const child = try Page.create(self.allocator, nav, span_bits, parent);
        errdefer child.destroy(self.allocator);
        var buf: [PAGE_SIZE]u8 = undefined;
        try self.readPageImage(child_id, &buf);
        try child.deserialize(self.allocator, &self.scratch_units, &buf);
        child.page_id = child_id;
        if (comptime options.enable_metrics) self.stats.page_loads += 1;
        return child;
    }

    fn markDirty(self: *Engine, page: *Page) !void {
        if (!page.dirty) page.first_dirty_block = self.current_block;
        page.dirty = true;
        page.last_write = self.current_block;
        if (!page.in_block_dirty) {
            page.in_block_dirty = true;
            try self.block_dirty[page.span_bits].append(self.allocator, page);
        }
        if (!page.in_flush_list) {
            page.in_flush_list = true;
            try self.flush_list.append(self.allocator, page);
        }
    }

    /// Split `page`: move a crit-bit subtree (≈ half the content, all sharing
    /// a common prefix longer than the page's span) into a new child page.
    /// Always relieves pressure regardless of key distribution.
    fn split(self: *Engine, page: *Page) !void {
        if (comptime options.enable_metrics) self.stats.splits += 1;

        const units = &self.scratch_units;
        units.clearRetainingCapacity();
        try page.collectUnits(self.allocator, units);
        std.debug.assert(units.items.len >= 2);

        // Largest range (by content bytes) that fits a fresh page, found by
        // walking down the implicit crit-bit structure taking the larger half.
        var lo: usize = 0;
        var hi: usize = units.items.len;
        var c_last: u32 = 0;
        const child_cap = PAGE_SIZE - HEADER_SIZE;
        while (rangeBytes(units.items[lo..hi]) > child_cap or (hi - lo) == units.items.len) {
            std.debug.assert(hi - lo >= 2);
            const c = firstDiffBit(&units.items[lo].key, &units.items[hi - 1].key);
            c_last = c;
            var slo = lo;
            var shi = hi;
            while (slo < shi) {
                const mid = slo + (shi - slo) / 2;
                if (keyBit(&units.items[mid].key, c) == 0) slo = mid + 1 else shi = mid;
            }
            // Take the heavier side.
            if (rangeBytes(units.items[lo..slo]) >= rangeBytes(units.items[slo..hi])) {
                hi = slo;
            } else {
                lo = slo;
            }
        }
        const moved = units.items[lo..hi];
        std.debug.assert(moved.len >= 1 and moved.len < units.items.len);
        // The moved range is a complete crit-bit subtree separated from the
        // rest of the page at bit c_last, so any prefix longer than c_last is
        // exclusive to it; its own first divergence is the natural span.
        const span: u32 = if (moved.len == 1)
            c_last + 1
        else
            firstDiffBit(&moved[0].key, &moved[moved.len - 1].key);
        const nav = maskKey(&moved[0].key, span);

        self.loaded_pages += 1;
        const child = try Page.create(self.allocator, nav, span, page);
        errdefer child.destroy(self.allocator);
        try child.rebuild(self.allocator, moved);
        // Loaded grandchild pages moved with their delegated units; their
        // parent pointers must follow.
        for (child.hot.items, child.cold.items) |h, c| {
            if (h.kind == .delegated) {
                if (c.child) |gc| gc.parent = child;
            }
        }

        // Rebuild the parent: remaining units plus one delegated unit, which
        // occupies the moved range's position in key order.
        const rest = &self.scratch_units2;
        rest.clearRetainingCapacity();
        try rest.ensureUnusedCapacity(self.allocator, units.items.len - moved.len + 1);
        rest.appendSliceAssumeCapacity(units.items[0..lo]);
        rest.appendAssumeCapacity(.{
            .kind = .delegated,
            .crit = @intCast(span),
            .hash = child.value(),
            .key = nav,
            .child = child,
        });
        rest.appendSliceAssumeCapacity(units.items[hi..]);
        try page.rebuild(self.allocator, rest.items);

        try self.markDirty(child);
        try self.markDirty(page);
    }

    fn rangeBytes(units: []const Node) u32 {
        var m: u32 = 0;
        var n: u32 = 0;
        for (units) |u| {
            if (u.kind == .delegated) m += 1 else n += 1;
        }
        return DELEG_SIZE * m + INLINE_SIZE * n;
    }

    /// After a removal: drop empty children; re-inline small children.
    fn afterRemove(self: *Engine, page: *Page) !void {
        const parent = page.parent orelse return;

        if (page.unitCount() == 0) {
            _ = parent.removeNode(self.allocator, &page.nav, .delegated) orelse unreachable;
            parent.m_deleg -= 1;
            try self.markDirty(parent);
            self.retirePage(page);
            return;
        }
        // Merge small children back into the parent (delegated units are
        // position-independent and move up freely).
        if (page.contentBytes() - HEADER_SIZE > MERGE_MAX_BYTES) return;
        if (parent.contentBytes() - DELEG_SIZE + (page.contentBytes() - HEADER_SIZE) > PAGE_SIZE) return;
        if (comptime options.enable_metrics) self.stats.merges += 1;

        const units = &self.scratch_units;
        units.clearRetainingCapacity();
        try page.collectUnits(self.allocator, units);
        _ = parent.removeNode(self.allocator, &page.nav, .delegated) orelse unreachable;
        parent.m_deleg -= 1;
        for (units.items) |u| {
            const res = try parent.upsertNode(self.allocator, &u.key, u);
            std.debug.assert(res == .inserted);
            if (u.kind == .delegated) {
                parent.m_deleg += 1;
                if (u.child) |c| c.parent = parent;
            } else {
                parent.n_inline += 1;
            }
        }
        try self.markDirty(parent);
        self.retirePage(page);
    }

    fn retirePage(self: *Engine, page: *Page) void {
        if (page.page_id != CMT_NONE) {
            // Stable ids: some on-disk parent may still reference this id
            // until every ancestor has been re-flushed, so it becomes
            // reusable only at the next FULL flush (consistent tree).
            self.retired_ids.append(self.allocator, page.page_id) catch {};
            page.page_id = CMT_NONE;
        }
        page.alive = false;
        page.dirty = false;
        self.graveyard.append(self.allocator, page) catch {};
    }

    /// Apply one block of writes.  `entries` must be sorted by key and
    /// deduplicated (newest value per key); TOMBSTONE values are deletions.
    /// Returns the new state root.
    pub fn applyBlock(self: *Engine, entries: []const KvEntry) !Hash {
        const ta0 = if (comptime options.enable_metrics) monoNs() else {};

        for (entries) |e| {
            if (std.mem.eql(u8, &e.value, &TOMBSTONE)) {
                const page = try self.descendOwner(&e.key);
                if (page.removeInline(self.allocator, &e.key)) {
                    try self.markDirty(page);
                    try self.afterRemove(page);
                }
                continue;
            }
            try self.applyUpsert(&e.key, merkle.leafHash(&e.key, &e.value));
        }
        if (comptime options.enable_metrics) self.stats.apply_ns += monoNs() - ta0;

        // Propagate changed page values into parents, strictly deepest span
        // first: a page receives every child push before pushing its own
        // value upward.  Parents land in shorter-span buckets, which are
        // processed later (a parent's span is always shorter than its
        // child's).
        const tp0 = if (comptime options.enable_metrics) monoNs() else {};
        var s: usize = 256;
        while (s >= 1) : (s -= 1) {
            // Bucket may grow while iterating (parents of equal span are
            // impossible, so growth only targets shorter spans).
            for (self.block_dirty[s].items) |page| {
                page.in_block_dirty = false;
                if (!page.alive) continue;
                const parent = page.parent.?; // span ≥ 1 pages always have one
                parent.updateDelegated(&page.nav, page.value());
                try self.markDirty(parent);
            }
            self.block_dirty[s].clearRetainingCapacity();
        }
        for (self.block_dirty[0].items) |page| page.in_block_dirty = false;
        self.block_dirty[0].clearRetainingCapacity();
        if (self.graveyard.items.len > 0) {
            // Retired pages may still sit in the flush list; purge before
            // their memory is freed (dangling pointers otherwise).
            var keep: usize = 0;
            for (self.flush_list.items) |p| {
                if (p.alive) {
                    self.flush_list.items[keep] = p;
                    keep += 1;
                } else {
                    p.in_flush_list = false;
                }
            }
            self.flush_list.shrinkRetainingCapacity(keep);
            self.loaded_pages -= @intCast(self.graveyard.items.len);
            for (self.graveyard.items) |page| page.destroy(self.allocator);
            self.graveyard.clearRetainingCapacity();
        }
        if (comptime options.enable_metrics) self.stats.propagate_ns += monoNs() - tp0;

        if (comptime options.enable_metrics) {
            self.stats.combines = g_combines;
            self.stats.walk_hops = g_walk_hops;
        }
        if (self.loaded_pages > self.max_loaded) self.evictCold();

        self.current_block += 1;
        return self.rootValue();
    }

    /// Drop clean, cold, persisted pages (with no loaded descendants) from
    /// RAM; they reload from disk on the next descent.  Dirty pages are never
    /// evicted (they must flush first), so correctness is unaffected.
    fn evictCold(self: *Engine) void {
        const EVICT_MIN_AGE: u32 = 4;
        _ = self.sweepEvict(self.root_page, EVICT_MIN_AGE);
    }

    /// Returns true if `page` must stay loaded (dirty, or kept descendants).
    fn sweepEvict(self: *Engine, page: *Page, min_age: u32) bool {
        var kept_any = false;
        for (page.hot.items, page.cold.items) |h, *c| {
            if (h.kind != .delegated) continue;
            const child = c.child orelse continue;
            const child_kept = self.sweepEvict(child, min_age);
            const evictable = !child_kept and
                !child.dirty and
                child.page_id != CMT_NONE and
                self.current_block -% child.last_touch >= min_age;
            if (evictable) {
                c.child_id = child.page_id;
                c.child = null;
                child.destroy(self.allocator);
                self.loaded_pages -= 1;
                if (comptime options.enable_metrics) self.stats.page_evictions += 1;
            } else {
                kept_any = true;
            }
        }
        return kept_any or page.dirty;
    }

    // ── Persistence ──────────────────────────────────────────────────────────

    /// Persist one page in place (stable id, alternating physical slot;
    /// never-flushed children are flushed first so the embedded child ids are
    /// always real).
    fn writePage(self: *Engine, page: *Page) anyerror!void {
        const cs = &(self.store orelse return);
        for (page.hot.items, page.cold.items) |h, *c| {
            if (h.kind != .delegated) continue;
            // Pool holes have child == null (freeNode clears it).
            if (c.child) |child| {
                if (child.page_id == CMT_NONE) try self.writePage(child);
                c.child_id = child.page_id;
            }
        }
        if (page.page_id == CMT_NONE) page.page_id = self.allocPageId();
        page.flush_version +%= 1;
        var buf: [PAGE_SIZE]u8 = undefined;
        try page.serialize(self.allocator, &self.scratch_units, &buf);
        try cs.writeRaw(page.page_id * 2 + (page.flush_version & 1), &buf);
        page.dirty = false;
        if (comptime options.enable_metrics) self.stats.page_flushes += 1;
    }

    /// Read a page image: both physical slots are checked and the valid one
    /// with the highest version wins (torn writes lose to the older slot).
    fn readPageImage(self: *Engine, id: u32, buf: *[PAGE_SIZE]u8) !void {
        const cs = &(self.store orelse return error.CmtPageNotLoaded);
        var buf_b: [PAGE_SIZE]u8 = undefined;
        var va: ?u32 = null;
        var vb: ?u32 = null;
        if (cs.readRaw(id * 2, buf)) |_| {
            va = Page.slotVersion(buf);
        } else |_| {}
        if (cs.readRaw(id * 2 + 1, &buf_b)) |_| {
            vb = Page.slotVersion(&buf_b);
        } else |_| {}
        if (va == null and vb == null) return error.CmtPageCorrupt;
        if (va == null or (vb != null and vb.? > va.?)) @memcpy(buf, &buf_b);
    }

    fn spanGreater(_: void, a: *Page, b: *Page) bool {
        return a.span_bits > b.span_bits;
    }

    /// Amortised lazy write-back: flush up to `budget` dirty pages, deepest
    /// (longest span) first.  A page flushes when it has gone idle for
    /// FLUSH_IDLE_AGE blocks, or unconditionally once it has been dirty for
    /// FLUSH_MAX_DIRTY blocks — the latter bounds the WAL replay window even
    /// for permanently-hot pages (the root is dirtied every block).
    pub fn flushBudget(self: *Engine, budget: u32) !void {
        if (self.store == null) return;
        std.mem.sort(*Page, self.flush_list.items, {}, spanGreater);
        var rem = budget;
        var keep: usize = 0;
        for (self.flush_list.items) |page| {
            if (!page.alive or !page.dirty) {
                page.in_flush_list = false;
                continue;
            }
            const idle = self.current_block -% page.last_write >= FLUSH_IDLE_AGE;
            const overdue = self.current_block -% page.first_dirty_block >= FLUSH_MAX_DIRTY;
            if (rem == 0 or !(idle or overdue)) {
                self.flush_list.items[keep] = page;
                keep += 1;
                continue;
            }
            try self.writePage(page);
            page.in_flush_list = false;
            rem -|= 1;
        }
        self.flush_list.shrinkRetainingCapacity(keep);
    }

    /// Earliest block whose effects are not yet fully persisted: WAL entries
    /// from this block onward must be retained for crash recovery.  Any
    /// unflushed change keeps an ancestor chain dirty, so the minimum
    /// first_dirty_block over dirty pages covers every pending effect.
    pub fn replayFrom(self: *const Engine) u32 {
        var min_block = self.current_block;
        for (self.flush_list.items) |page| {
            if (!page.alive or !page.dirty) continue;
            if (page.first_dirty_block < min_block) min_block = page.first_dirty_block;
        }
        return min_block;
    }

    /// Full flush: persist every dirty page (deepest first) and return the
    /// root page id.  After this the on-disk tree is fully consistent, so
    /// retired page ids become reusable.
    pub fn flushAll(self: *Engine) !u32 {
        if (self.store == null) return CMT_NONE;
        std.mem.sort(*Page, self.flush_list.items, {}, spanGreater);
        for (self.flush_list.items) |page| {
            page.in_flush_list = false;
            if (!page.alive or !page.dirty) continue;
            try self.writePage(page);
        }
        self.flush_list.clearRetainingCapacity();
        // The root page must always be persisted so the manifest can point at
        // it, even when nothing changed (fresh empty database).
        if (self.root_page.page_id == CMT_NONE) try self.writePage(self.root_page);
        for (self.retired_ids.items) |id| try self.free.release(self.allocator, id);
        self.retired_ids.clearRetainingCapacity();
        return self.root_page.page_id;
    }

    /// Open from a persisted root page id (children load lazily).
    pub fn load(
        allocator: std.mem.Allocator,
        store: page_store.CommitmentPageStore,
        root_id: u32,
        next_id: u32,
        free_ids: []const u32,
        block_num: u32,
    ) !Engine {
        var self = try Engine.init(allocator, store);
        errdefer self.deinit();
        self.next_id = next_id;
        self.current_block = block_num;
        try self.free.restore(allocator, free_ids);
        if (root_id != CMT_NONE) {
            var buf: [PAGE_SIZE]u8 = undefined;
            try self.readPageImage(root_id, &buf);
            try self.root_page.deserialize(allocator, &self.scratch_units, &buf);
            self.root_page.page_id = root_id;
        }
        return self;
    }
};

// ─── Tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

fn testKey(i: u64) Key {
    var seed: [8]u8 = undefined;
    std.mem.writeInt(u64, &seed, i, .big);
    var k: Key = undefined;
    std.crypto.hash.Blake3.hash(&seed, &k, .{});
    return k;
}

fn testVal(i: u64) Value {
    var seed: [8]u8 = undefined;
    std.mem.writeInt(u64, &seed, i ^ 0x5EED, .big);
    var v: Value = undefined;
    std.crypto.hash.Blake3.hash(&seed, &v, .{});
    return v;
}

fn seqKey(i: u64) Key {
    var k = std.mem.zeroes(Key);
    std.mem.writeInt(u64, k[24..32], i, .big);
    return k;
}

/// Oracle: canonical value over a model map, via t.subtreeValue.
fn oracleRoot(allocator: std.mem.Allocator, model: *const std.AutoHashMap(Key, Value)) !Hash {
    var list = std.ArrayList(KvEntry).empty;
    defer list.deinit(allocator);
    var it = model.iterator();
    while (it.next()) |kv| {
        try list.append(allocator, .{ .key = kv.key_ptr.*, .value = kv.value_ptr.* });
    }
    std.mem.sort(KvEntry, list.items, {}, t.kvLessThan);
    return t.subtreeValue(list.items, 0);
}

fn applySorted(engine: *Engine, batch: []KvEntry) !Hash {
    std.mem.sort(KvEntry, batch, {}, t.kvLessThan);
    return engine.applyBlock(batch);
}

test "engine: empty root is ZERO_HASH" {
    var e = try Engine.init(testing.allocator, null);
    defer e.deinit();
    try testing.expectEqual(ZERO_HASH, e.rootValue());
}

test "engine: single key equals leafHash (pass-through to root)" {
    var e = try Engine.init(testing.allocator, null);
    defer e.deinit();
    var batch = [_]KvEntry{.{ .key = testKey(1), .value = testVal(1) }};
    const root = try applySorted(&e, &batch);
    try testing.expectEqual(merkle.leafHash(&batch[0].key, &batch[0].value), root);
}

test "engine: matches oracle across inserts, updates, deletes, many blocks" {
    var e = try Engine.init(testing.allocator, null);
    defer e.deinit();
    var model = std.AutoHashMap(Key, Value).init(testing.allocator);
    defer model.deinit();

    var rng = std.Random.DefaultPrng.init(42);
    const rand = rng.random();

    var blk: u32 = 0;
    while (blk < 30) : (blk += 1) {
        var batch = std.ArrayList(KvEntry).empty;
        defer batch.deinit(testing.allocator);
        var op: u32 = 0;
        const nops = 50 + rand.uintLessThan(u32, 150);
        while (op < nops) : (op += 1) {
            const i = rand.uintLessThan(u64, 2000);
            const k = testKey(i);
            if (rand.uintLessThan(u8, 10) < 2) {
                // delete (may be absent — must be a no-op)
                try batch.append(testing.allocator, .{ .key = k, .value = TOMBSTONE });
                _ = model.remove(k);
            } else {
                const v = testVal(i +% blk *% 7919 +% op);
                try batch.append(testing.allocator, .{ .key = k, .value = v });
                try model.put(k, v);
            }
        }
        // Dedup newest-wins, then sort (mirrors root.zig's preparation).
        var dedup = std.AutoHashMap(Key, Value).init(testing.allocator);
        defer dedup.deinit();
        var bi = batch.items.len;
        while (bi > 0) {
            bi -= 1;
            const ent = batch.items[bi];
            const gop = try dedup.getOrPut(ent.key);
            if (!gop.found_existing) gop.value_ptr.* = ent.value;
        }
        var unique = std.ArrayList(KvEntry).empty;
        defer unique.deinit(testing.allocator);
        var dit = dedup.iterator();
        while (dit.next()) |kv| {
            try unique.append(testing.allocator, .{ .key = kv.key_ptr.*, .value = kv.value_ptr.* });
        }
        const root = try applySorted(&e, unique.items);
        try testing.expectEqual(try oracleRoot(testing.allocator, &model), root);
    }
}

test "engine: split path — many keys forced through page overflow" {
    var e = try Engine.init(testing.allocator, null);
    defer e.deinit();
    var model = std.AutoHashMap(Key, Value).init(testing.allocator);
    defer model.deinit();

    var batch = std.ArrayList(KvEntry).empty;
    defer batch.deinit(testing.allocator);
    var i: u64 = 0;
    while (i < 500) : (i += 1) {
        const k = testKey(i);
        const v = testVal(i);
        try batch.append(testing.allocator, .{ .key = k, .value = v });
        try model.put(k, v);
    }
    const root = try applySorted(&e, batch.items);
    try testing.expectEqual(try oracleRoot(testing.allocator, &model), root);
    try testing.expect(e.root_page.m_deleg > 0); // splits actually happened
}

test "engine: sequential keys (deep shared prefix) never cascade" {
    var e = try Engine.init(testing.allocator, null);
    defer e.deinit();
    var model = std.AutoHashMap(Key, Value).init(testing.allocator);
    defer model.deinit();

    // 2000 keys differing only in their last 8 bytes: a slot-aligned design
    // would cascade to a depth cap; prefix-based delegation must handle it.
    var batch = std.ArrayList(KvEntry).empty;
    defer batch.deinit(testing.allocator);
    var i: u64 = 0;
    while (i < 2000) : (i += 1) {
        const k = seqKey(i);
        const v = testVal(i);
        try batch.append(testing.allocator, .{ .key = k, .value = v });
        try model.put(k, v);
    }
    const root = try applySorted(&e, batch.items);
    try testing.expectEqual(try oracleRoot(testing.allocator, &model), root);
}

test "engine: delete back down through merges to empty" {
    var e = try Engine.init(testing.allocator, null);
    defer e.deinit();

    var batch = std.ArrayList(KvEntry).empty;
    defer batch.deinit(testing.allocator);
    var i: u64 = 0;
    while (i < 300) : (i += 1) {
        try batch.append(testing.allocator, .{ .key = testKey(i), .value = testVal(i) });
    }
    _ = try applySorted(&e, batch.items);

    batch.clearRetainingCapacity();
    i = 0;
    while (i < 300) : (i += 1) {
        try batch.append(testing.allocator, .{ .key = testKey(i), .value = TOMBSTONE });
    }
    const root = try applySorted(&e, batch.items);
    try testing.expectEqual(ZERO_HASH, root);
    try testing.expectEqual(@as(u32, 0), e.root_page.unitCount());
}

test "page: serialize/deserialize round-trip preserves value and units" {
    var e = try Engine.init(testing.allocator, null);
    defer e.deinit();
    var batch = std.ArrayList(KvEntry).empty;
    defer batch.deinit(testing.allocator);
    var i: u64 = 0;
    while (i < 200) : (i += 1) {
        try batch.append(testing.allocator, .{ .key = testKey(i), .value = testVal(i) });
    }
    _ = try applySorted(&e, batch.items);

    // Round-trip the root page.  Its delegated children need ids; fake them.
    const page = e.root_page;
    for (page.hot.items, page.cold.items) |h, *c| {
        if (h.kind == .delegated) c.child_id = 7;
    }
    var buf: [PAGE_SIZE]u8 = undefined;
    var scratch = std.ArrayList(Node).empty;
    defer scratch.deinit(testing.allocator);
    try page.serialize(testing.allocator, &scratch, &buf);

    var copy = try Page.create(testing.allocator, [_]u8{0} ** 32, 0, null);
    defer copy.destroy(testing.allocator);
    try copy.deserialize(testing.allocator, &scratch, &buf);
    try testing.expectEqual(page.value(), copy.value());
    try testing.expectEqual(page.n_inline, copy.n_inline);
    try testing.expectEqual(page.m_deleg, copy.m_deleg);
}

test "engine: flush + load round-trip via disk store" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const store = page_store.CommitmentPageStore.init(tmp.dir, testing.io);

    var root_before: Hash = undefined;
    var root_id: u32 = undefined;
    var next_id: u32 = undefined;
    {
        var e = try Engine.init(testing.allocator, store);
        defer e.deinit();
        var batch = std.ArrayList(KvEntry).empty;
        defer batch.deinit(testing.allocator);
        var i: u64 = 0;
        while (i < 400) : (i += 1) {
            try batch.append(testing.allocator, .{ .key = testKey(i), .value = testVal(i) });
        }
        root_before = try applySorted(&e, batch.items);
        root_id = try e.flushAll();
        next_id = e.next_id;
    }
    {
        var e = try Engine.load(testing.allocator, store, root_id, next_id, &.{}, 1);
        defer e.deinit();
        try testing.expectEqual(root_before, e.rootValue());

        // Touch a key in a lazily-loaded child page; root must change, then
        // restore exactly when the original value is written back.
        var batch = [_]KvEntry{.{ .key = testKey(3), .value = testVal(9999) }};
        const root_after = try applySorted(&e, &batch);
        try testing.expect(!std.mem.eql(u8, &root_after, &root_before));

        var batch2 = [_]KvEntry{.{ .key = testKey(3), .value = testVal(3) }};
        const root_restored = try applySorted(&e, &batch2);
        try testing.expectEqual(root_before, root_restored);
    }
}

test "engine: scale stress — deep split churn over ~1M keys" {

    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var e = try Engine.init(alloc, null);
    defer e.deinit();

    var rng = std.Random.DefaultPrng.init(7);
    const rand = rng.random();
    var batch = std.ArrayList(KvEntry).empty;
    defer batch.deinit(alloc);

    var total: u64 = 0;
    var blk: u32 = 0;
    while (blk < 2_000) : (blk += 1) {
        batch.clearRetainingCapacity();
        var j: u32 = 0;
        while (j < 450) : (j += 1) {
            try batch.append(alloc, .{ .key = testKey(rand.int(u64)), .value = testVal(total) });
            total += 1;
        }
        std.mem.sort(KvEntry, batch.items, {}, t.kvLessThan);
        // dedup adjacent (rare with 64-bit draws)
        var w: usize = 0;
        for (batch.items, 0..) |it, i| {
            if (i > 0 and std.mem.eql(u8, &batch.items[w - 1].key, &it.key)) continue;
            batch.items[w] = it;
            w += 1;
        }
        _ = try e.applyBlock(batch.items[0..w]);

    }
}

test "engine: eviction — pages reload transparently under a tiny RAM cap" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const store = page_store.CommitmentPageStore.init(tmp.dir, testing.io);

    var e = try Engine.init(testing.allocator, store);
    defer e.deinit();
    e.max_loaded = 8; // brutal: almost everything evicts between blocks

    var model = std.AutoHashMap(Key, Value).init(testing.allocator);
    defer model.deinit();
    var batch = std.ArrayList(KvEntry).empty;
    defer batch.deinit(testing.allocator);

    var rng = std.Random.DefaultPrng.init(99);
    const rand = rng.random();
    var blk: u32 = 0;
    var i: u64 = 0;
    while (blk < 40) : (blk += 1) {
        batch.clearRetainingCapacity();
        var j: u32 = 0;
        while (j < 200) : (j += 1) {
            const k = if (rand.boolean()) testKey(i) else testKey(rand.uintLessThan(u64, @max(i, 1)));
            const v = testVal(i);
            try batch.append(testing.allocator, .{ .key = k, .value = v });
            try model.put(k, v);
            i += 1;
        }
        // dedup newest-wins then sort
        var dedup = std.AutoHashMap(Key, Value).init(testing.allocator);
        defer dedup.deinit();
        var bi = batch.items.len;
        while (bi > 0) {
            bi -= 1;
            const ent = batch.items[bi];
            const gop = try dedup.getOrPut(ent.key);
            if (!gop.found_existing) gop.value_ptr.* = ent.value;
        }
        batch.clearRetainingCapacity();
        var dit = dedup.iterator();
        while (dit.next()) |kv| {
            try batch.append(testing.allocator, .{ .key = kv.key_ptr.*, .value = kv.value_ptr.* });
        }
        std.mem.sort(KvEntry, batch.items, {}, t.kvLessThan);
        // Eviction needs flushed (clean) pages to act on; full-flush as we
        // go (the lazy budget policy would keep everything dirty for 64+
        // blocks and nothing would ever be evictable in a 40-block test).
        const root = try e.applyBlock(batch.items);
        _ = try e.flushAll();
        try testing.expectEqual(try oracleRoot(testing.allocator, &model), root);
    }
    // Evictions actually happened (metrics builds only can observe this).
    if (comptime options.enable_metrics) try testing.expect(e.stats.page_evictions > 0);
}
