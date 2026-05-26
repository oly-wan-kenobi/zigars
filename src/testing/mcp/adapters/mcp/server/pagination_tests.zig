const std = @import("std");

const pagination = @import("../../../../../adapters/mcp/server/pagination.zig");

test "pagination accepts integer cursors" {
    var obj = std.json.ObjectMap.empty;
    defer obj.deinit(std.testing.allocator);
    try obj.put(std.testing.allocator, "cursor", .{ .integer = 2 });

    const page = pagination.fromParams(.{ .object = obj });
    try std.testing.expectEqual(@as(usize, 2), page.start);
    try std.testing.expect(page.requested);
}
