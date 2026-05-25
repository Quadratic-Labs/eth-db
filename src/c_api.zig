/// C-compatible API for PrefixDB, used by the Python bindings.
///
/// Each handle is an opaque *State that owns a GPA and the PrefixDB.
/// Delete is implemented via a tombstone (0xFF * 32); reads that hit the
/// tombstone are reported as "not found" to callers.
///
/// Return codes: 0 = OK, 1 = key not found, -1 = internal error.

const std = @import("std");
const root = @import("root.zig");

const PrefixDB = root.PrefixDB;
const Key = root.Key;
const Value = root.Value;

const TOMBSTONE: Value = [_]u8{0xFF} ** 32;

const State = struct {
    gpa: std.heap.GeneralPurposeAllocator(.{}),
    db: PrefixDB,
};

export fn prefixdb_init() ?*State {
    const state = std.heap.page_allocator.create(State) catch return null;
    state.gpa = .{};
    state.db = PrefixDB.init(state.gpa.allocator()) catch {
        _ = state.gpa.deinit();
        std.heap.page_allocator.destroy(state);
        return null;
    };
    return state;
}

export fn prefixdb_deinit(state: *State) void {
    state.db.deinit();
    _ = state.gpa.deinit();
    std.heap.page_allocator.destroy(state);
}

export fn prefixdb_put(state: *State, key: *const [32]u8, value: *const [32]u8) i32 {
    state.db.write(key.*, value.*) catch return -1;
    return 0;
}

/// Returns 0 and fills value_out if found; 1 if not found (or deleted); -1 on error.
export fn prefixdb_get(state: *State, key: *const [32]u8, value_out: *[32]u8) i32 {
    const result = state.db.read(key.*) catch return -1;
    if (result) |v| {
        if (std.mem.eql(u8, &v, &TOMBSTONE)) return 1;
        value_out.* = v;
        return 0;
    }
    return 1;
}

export fn prefixdb_del(state: *State, key: *const [32]u8) i32 {
    state.db.write(key.*, TOMBSTONE) catch return -1;
    return 0;
}

export fn prefixdb_compact(state: *State) i32 {
    state.db.runCompaction() catch return -1;
    return 0;
}
