const std = @import("std");

const Allocator = std.mem.Allocator;

pub fn dupString(allocator: Allocator, value: []const u8) Allocator.Error![]const u8 {
    return try allocator.dupe(u8, value);
}

pub fn dupOptionalString(allocator: Allocator, value: ?[]const u8) Allocator.Error!?[]const u8 {
    return if (value) |slice| try dupString(allocator, slice) else null;
}

pub fn freeOptionalString(allocator: Allocator, value: ?[]const u8) void {
    if (value) |slice| allocator.free(slice);
}

pub fn dupStringList(allocator: Allocator, values: []const []const u8) Allocator.Error![]const []const u8 {
    const copied = try allocator.alloc([]const u8, values.len);
    errdefer allocator.free(copied);

    var copied_count: usize = 0;
    errdefer {
        for (copied[0..copied_count]) |value| allocator.free(value);
    }

    for (values, 0..) |value, index| {
        copied[index] = try dupString(allocator, value);
        copied_count += 1;
    }
    return copied;
}

pub fn freeStringList(allocator: Allocator, values: []const []const u8) void {
    for (values) |value| allocator.free(value);
    allocator.free(values);
}

pub fn optionalStringsEqual(left: ?[]const u8, right: ?[]const u8) bool {
    if (left == null and right == null) return true;
    if (left == null or right == null) return false;
    return std.mem.eql(u8, left.?, right.?);
}

pub fn stringListsEqual(left: []const []const u8, right: []const []const u8) bool {
    if (left.len != right.len) return false;
    for (left, right) |left_value, right_value| {
        if (!std.mem.eql(u8, left_value, right_value)) return false;
    }
    return true;
}

test "duplicates and releases string lists" {
    const allocator = std.testing.allocator;
    const values = try dupStringList(allocator, &.{ "one", "two" });
    defer freeStringList(allocator, values);

    try std.testing.expectEqual(@as(usize, 2), values.len);
    try std.testing.expectEqualStrings("one", values[0]);
    try std.testing.expectEqualStrings("two", values[1]);
    try std.testing.expect(stringListsEqual(values, &.{ "one", "two" }));
}
