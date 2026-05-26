const std = @import("std");
const catalog_mod = @import("catalog.zig");

const Catalog = catalog_mod.Catalog;

test "catalog port renders public tool catalog text" {
    var catalog_port = Catalog{};
    const rendered = try catalog_port.port().text(std.testing.allocator);
    defer rendered.deinit(std.testing.allocator);

    try std.testing.expect(std.mem.indexOf(u8, rendered.text, "\"groups\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered.text, "\"registry_tool_arguments\"") != null);
}
