//! Tests that the backend catalog enforces the configurability and
//! probability contracts: every backend has a path flag, a non-empty
//! default path, at least one probe argv, and at least one verify needle.
const std = @import("std");
const catalog_mod = @import("catalog.zig");

const backends = catalog_mod.backends;
const value = catalog_mod.value;

test "backend catalog keeps every backend executable configurable and probeable" {
    try std.testing.expectEqual(@as(usize, 6), backends.len);
    for (backends) |backend| {
        try std.testing.expect(std.mem.startsWith(u8, backend.path_flag, "--"));
        try std.testing.expect(backend.default_path.len > 0);
        try std.testing.expect(backend.probe_argv.len > 0);
        try std.testing.expect(backend.verify.len > 0);
    }
}

test "backend catalog applies configured paths to probe argv" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const catalog = try value(arena.allocator(), .{ .zls_path = "/tools/zls" }, true);
    const zls = catalog.object.get("backends").?.array.items[1].object;
    try std.testing.expectEqualStrings("/tools/zls", zls.get("configured_path").?.string);
    try std.testing.expectEqualStrings("/tools/zls", zls.get("probe_argv").?.array.items[0].string);
}
