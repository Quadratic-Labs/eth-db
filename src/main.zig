const std = @import("std");
const eth_db = @import("eth_db");

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();

    var db = try eth_db.PrefixDB.init(allocator);
    defer db.deinit();

    std.debug.print("PrefixDB engine initialised.\n", .{});
}

test "simple test" {
    const gpa = std.testing.allocator;
    var list: std.ArrayList(i32) = .empty;
    defer list.deinit(gpa);
    try list.append(gpa, 42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}

test "PrefixDB init and deinit" {
    var db = try eth_db.PrefixDB.init(std.testing.allocator);
    defer db.deinit();
    try std.testing.expectEqual(@as(usize, 0), db.l0.entries.items.len);
}
