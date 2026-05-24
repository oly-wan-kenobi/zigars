const std = @import("std");

const ports = @import("../../app/ports.zig");
const catalog_render = @import("../../manifest/tool_catalog_render.zig");

pub const Catalog = struct {
    pub fn port(self: *Catalog) ports.ToolCatalog {
        return .{
            .ptr = self,
            .vtable = &.{ .text = text },
        };
    }

    fn text(_: *anyopaque, allocator: std.mem.Allocator) ports.PortError!ports.ToolCatalogText {
        const body = catalog_render.text(allocator) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.Unavailable,
        };
        return .{ .text = body, .owns_text = true };
    }
};

test "catalog port renders public tool catalog text" {
    var catalog_port = Catalog{};
    const rendered = try catalog_port.port().text(std.testing.allocator);
    defer rendered.deinit(std.testing.allocator);

    try std.testing.expect(std.mem.indexOf(u8, rendered.text, "\"groups\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered.text, "\"registry_tool_arguments\"") != null);
}
