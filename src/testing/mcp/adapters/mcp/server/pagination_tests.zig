//! Pins the MCP pagination cursor contract: integer cursors are accepted and
//! produce a Page with the correct start offset; negative, string, and bool
//! cursors are rejected as InvalidCursor.

const std = @import("std");

const pagination = @import("../../../../../adapters/mcp/server/pagination.zig");

test "pagination accepts integer cursors" {
    var obj = std.json.ObjectMap.empty;
    defer obj.deinit(std.testing.allocator);
    try obj.put(std.testing.allocator, "cursor", .{ .integer = 2 });

    const page = try pagination.fromParams(.{ .object = obj });
    try std.testing.expectEqual(@as(usize, 2), page.start);
    try std.testing.expect(page.requested);
}

test "pagination rejects malformed and negative cursors" {
    var negative = std.json.ObjectMap.empty;
    defer negative.deinit(std.testing.allocator);
    try negative.put(std.testing.allocator, "cursor", .{ .integer = -1 });
    try std.testing.expectError(error.InvalidCursor, pagination.fromParams(.{ .object = negative }));

    var malformed = std.json.ObjectMap.empty;
    defer malformed.deinit(std.testing.allocator);
    try malformed.put(std.testing.allocator, "cursor", .{ .string = "abc" });
    try std.testing.expectError(error.InvalidCursor, pagination.fromParams(.{ .object = malformed }));

    var wrong_type = std.json.ObjectMap.empty;
    defer wrong_type.deinit(std.testing.allocator);
    try wrong_type.put(std.testing.allocator, "cursor", .{ .bool = true });
    try std.testing.expectError(error.InvalidCursor, pagination.fromParams(.{ .object = wrong_type }));
}
