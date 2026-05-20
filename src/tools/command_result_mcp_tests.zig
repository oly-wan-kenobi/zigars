const std = @import("std");
const mcp = @import("mcp");
const zigar = @import("zigar");

const command_result = @import("command_result.zig");

test "commandResultValue sanitizes invalid UTF-8 command streams and diagnostics" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const stderr = try allocator.dupe(u8, "src/main.zig:1:1: error: bad \xff\n");
    const result = zigar.command.RunResult{
        .term = .{ .exited = 1 },
        .stdout = try allocator.dupe(u8, "ok\n"),
        .stderr = stderr,
    };
    const value = try command_result.commandResultValue(allocator, "zig test", &.{ "zig", "test" }, ".", 1000, result);
    const obj = value.object;

    try std.testing.expectEqualStrings("ok\n", obj.get("stdout").?.string);
    try std.testing.expect(!obj.get("stdout_invalid_utf8").?.bool);
    try std.testing.expect(obj.get("stderr_invalid_utf8").?.bool);
    try std.testing.expectEqualStrings("utf-8-lossy", obj.get("stderr_encoding").?.string);
    try std.testing.expect(std.unicode.utf8ValidateSlice(obj.get("stderr").?.string));

    const primary = obj.get("diagnostics").?.object.get("primary").?.object;
    try std.testing.expect(std.unicode.utf8ValidateSlice(primary.get("message").?.string));
    try std.testing.expect(std.mem.indexOf(u8, primary.get("message").?.string, &std.unicode.replacement_character_utf8) != null);

    const bytes = try zigar.json_result.serializeAlloc(allocator, value);
    try std.testing.expect(std.unicode.utf8ValidateSlice(bytes));
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value.object.get("stderr_invalid_utf8").?.bool);
}

const TestTransport = struct {
    messages: []const []const u8,
    index: usize = 0,
    sent: std.ArrayList([]const u8) = .empty,

    fn deinit(self: *TestTransport, allocator: std.mem.Allocator) void {
        for (self.sent.items) |message| allocator.free(message);
        self.sent.deinit(allocator);
    }

    fn transport(self: *TestTransport) mcp.transport.Transport {
        return .{ .ptr = self, .vtable = &.{ .send = sendVtable, .receive = receiveVtable, .close = closeVtable } };
    }

    fn sendVtable(ptr: *anyopaque, _: std.Io, allocator: std.mem.Allocator, message: []const u8) mcp.transport.Transport.SendError!void {
        const self: *TestTransport = @ptrCast(@alignCast(ptr));
        const owned = allocator.dupe(u8, message) catch return error.OutOfMemory;
        self.sent.append(allocator, owned) catch {
            allocator.free(owned);
            return error.OutOfMemory;
        };
    }

    fn receiveVtable(ptr: *anyopaque, _: std.Io, _: std.mem.Allocator) mcp.transport.Transport.ReceiveError!?[]const u8 {
        const self: *TestTransport = @ptrCast(@alignCast(ptr));
        if (self.index >= self.messages.len) return error.EndOfStream;
        defer self.index += 1;
        return self.messages[self.index];
    }

    fn closeVtable(_: *anyopaque) void {}
};

fn invalidUtf8CommandToolHandler(_: ?*anyopaque, _: std.Io, allocator: std.mem.Allocator, _: ?std.json.Value) !mcp.tools.ToolResult {
    const result = zigar.command.RunResult{
        .term = .{ .exited = 0 },
        .stdout = try allocator.dupe(u8, "ok \xff\n"),
        .stderr = try allocator.dupe(u8, ""),
    };
    defer result.deinit(allocator);
    const value = try command_result.commandResultValue(allocator, "invalid utf8 fixture", &.{"fixture"}, ".", 1000, result);
    return zigar.json_result.structured(allocator, value);
}

test "MCP command-backed tool response parses with invalid UTF-8 output" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var server: zigar.mcp_server.Server = .init(allocator, .{ .name = "utf8-server", .version = "1.0.0" });
    defer server.deinit();
    try server.addTool(.{ .name = "invalid_utf8_tool", .description = "Returns invalid command bytes", .handler = invalidUtf8CommandToolHandler });

    const messages = [_][]const u8{
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-11-25\",\"clientInfo\":{\"name\":\"tester\",\"version\":\"1\"}}}",
        "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}",
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"invalid_utf8_tool\"}}",
    };
    var transport: TestTransport = .{ .messages = messages[0..] };
    defer transport.deinit(allocator);

    try server.runWithTransport(std.testing.io, allocator, transport.transport());

    var saw_invalid_marker = false;
    for (transport.sent.items) |message| {
        try std.testing.expect(std.unicode.utf8ValidateSlice(message));
        if (std.mem.indexOf(u8, message, "\"stdout_invalid_utf8\":true") != null) saw_invalid_marker = true;
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, message, .{});
        defer parsed.deinit();
        try std.testing.expectEqualStrings("2.0", parsed.value.object.get("jsonrpc").?.string);
    }
    try std.testing.expect(saw_invalid_marker);
}
