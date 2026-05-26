const std = @import("std");

const ports = @import("../../app/ports.zig");
const catalog_render = @import("../../manifest/tool_catalog_render.zig");

/// Runtime UX catalog port backed by the manifest renderer.
pub const Catalog = struct {
    /// Exposes this implementation through its application port vtable.
    pub fn port(self: *Catalog) ports.ToolCatalog {
        return .{
            .ptr = self,
            .vtable = &.{ .text = text },
        };
    }

    /// Returns borrowed catalog text for this entry.
    fn text(_: *anyopaque, allocator: std.mem.Allocator) ports.PortError!ports.ToolCatalogText {
        const body = catalog_render.text(allocator) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.Unavailable,
        };
        return .{ .text = body, .owns_text = true };
    }
};
