const std = @import("std");

const ports = @import("../../app/ports.zig");

pub const FakeToolCatalog = struct {
    text_value: []const u8 = "{}",
    calls: usize = 0,

    pub fn init(text_value: []const u8) FakeToolCatalog {
        return .{ .text_value = text_value };
    }

    pub fn port(self: *FakeToolCatalog) ports.ToolCatalog {
        return .{
            .ptr = self,
            .vtable = &.{ .text = text },
        };
    }

    fn text(ptr: *anyopaque, allocator: std.mem.Allocator) ports.PortError!ports.ToolCatalogText {
        const self: *FakeToolCatalog = @ptrCast(@alignCast(ptr));
        self.calls += 1;
        return .{
            .text = allocator.dupe(u8, self.text_value) catch return error.OutOfMemory,
            .owns_text = true,
        };
    }
};

test "fake catalog returns owned text" {
    var fake = FakeToolCatalog.init("{\"ok\":true}");
    const rendered = try fake.port().text(std.testing.allocator);
    defer rendered.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("{\"ok\":true}", rendered.text);
    try std.testing.expectEqual(@as(usize, 1), fake.calls);
}
