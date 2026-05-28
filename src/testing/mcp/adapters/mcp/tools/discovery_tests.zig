const std = @import("std");

const app_context = @import("../../../../../app/context.zig");
const discovery = @import("../../../../../adapters/mcp/tools/discovery.zig");
const fake_tool_catalog = @import("../../../../fakes/tool_catalog.zig");

test "discovery adapter wrappers expose text and structured status results" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var catalog = fake_tool_catalog.FakeToolCatalog.init("{\"tools\":[\"zigars_schema\"]}");
    const context: app_context.Context = .{
        .workspace = .{ .root = "/workspace", .cache_root = "/workspace/.zigars-cache", .transport = "stdio", .host = "127.0.0.1", .port = 8088 },
        .zls_state = .{ .status = "connected", .running = true },
        .ports = .{ .tool_catalog = catalog.port() },
    };

    const capabilities = try discovery.zigarsCapabilities(allocator, context, null);
    try std.testing.expect(std.mem.indexOf(u8, capabilities.content[0].text.text, "zigars_schema") != null);
    try std.testing.expectEqualStrings("zigars_schema", capabilities.structuredContent.?.object.get("tools").?.array.items[0].string);
    try std.testing.expectEqual(@as(usize, 1), catalog.calls);

    const schema = try discovery.zigarsSchema(allocator, context, null);
    try std.testing.expect(std.mem.indexOf(u8, schema.content[0].text.text, "zigars_schema") != null);
    try std.testing.expectEqualStrings("zigars_schema", schema.structuredContent.?.object.get("tools").?.array.items[0].string);
    try std.testing.expectEqual(@as(usize, 2), catalog.calls);

    const metrics = try discovery.zigarsMetrics(allocator, context, null);
    try std.testing.expectEqualStrings("connected", metrics.structuredContent.?.object.get("zls_status").?.string);

    const http = try discovery.zigarsHttpStatus(allocator, context, null);
    try std.testing.expectEqual(@as(i64, 8088), http.structuredContent.?.object.get("port").?.integer);
}
