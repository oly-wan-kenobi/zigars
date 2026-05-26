const std = @import("std");

const backend_catalog = @import("backend_catalog.zig");

test "backend setup catalog exposes configured executable paths" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const catalog = try backend_catalog.value(arena.allocator(), .{ .zflame_path = "/tools/zflame" }, true);
    try std.testing.expectEqualStrings("backend_setup_catalog", catalog.object.get("kind").?.string);
}
