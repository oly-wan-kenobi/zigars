const std = @import("std");
const mcp = @import("mcp");

const json_result = @import("json_result.zig");

const CaptureTransport = struct {
    messages: []const []const u8,
    index: usize = 0,
    responses: std.ArrayList([]u8) = .empty,

    fn deinit(self: *CaptureTransport, allocator: std.mem.Allocator) void {
        for (self.responses.items) |response| allocator.free(response);
        self.responses.deinit(allocator);
    }

    fn transport(self: *CaptureTransport) mcp.transport.Transport {
        return .{
            .ptr = self,
            .vtable = &.{
                .send = sendVtable,
                .receive = receiveVtable,
                .close = closeVtable,
            },
        };
    }

    fn send(self: *CaptureTransport, _: std.Io, allocator: std.mem.Allocator, message: []const u8) mcp.transport.Transport.SendError!void {
        const owned = allocator.dupe(u8, message) catch return error.OutOfMemory;
        errdefer allocator.free(owned);
        self.responses.append(allocator, owned) catch return error.OutOfMemory;
    }

    fn receive(self: *CaptureTransport, _: std.Io, _: std.mem.Allocator) mcp.transport.Transport.ReceiveError!?[]const u8 {
        if (self.index >= self.messages.len) return error.EndOfStream;
        defer self.index += 1;
        return self.messages[self.index];
    }

    fn close(_: *CaptureTransport) void {}

    fn sendVtable(ptr: *anyopaque, io: std.Io, allocator: std.mem.Allocator, message: []const u8) mcp.transport.Transport.SendError!void {
        const self: *CaptureTransport = @ptrCast(@alignCast(ptr));
        return self.send(io, allocator, message);
    }

    fn receiveVtable(ptr: *anyopaque, io: std.Io, allocator: std.mem.Allocator) mcp.transport.Transport.ReceiveError!?[]const u8 {
        const self: *CaptureTransport = @ptrCast(@alignCast(ptr));
        return self.receive(io, allocator);
    }

    fn closeVtable(ptr: *anyopaque) void {
        const self: *CaptureTransport = @ptrCast(@alignCast(ptr));
        self.close();
    }
};

test "mcp tools/call releases repeated successful structured results" {
    const allocator = std.testing.allocator;
    var server = mcp.Server.init(allocator, .{ .name = "memory-test", .version = "1.0.0" });
    defer server.deinit();
    server.state = .ready;

    try server.addTool(.{
        .name = "owned_success",
        .handler = successHandler,
        .deinit_result = json_result.deinitToolResult,
    });

    const messages = [_][]const u8{
        \\{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"owned_success","arguments":{"seed":"a"}}}
        ,
        \\{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"owned_success","arguments":{"seed":"b"}}}
        ,
        \\{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"owned_success","arguments":{"seed":"c"}}}
        ,
        \\{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"owned_success","arguments":{"seed":"d"}}}
        ,
    };
    var transport = CaptureTransport{ .messages = &messages };
    defer transport.deinit(allocator);

    try server.runWithTransport(std.testing.io, allocator, transport.transport());

    try std.testing.expectEqual(messages.len, transport.responses.items.len);
    for (transport.responses.items) |response| {
        try expectToolCallResponse(response, false, "structured_success");
    }
}

test "mcp tools/call releases repeated structured tool errors" {
    const allocator = std.testing.allocator;
    var server = mcp.Server.init(allocator, .{ .name = "memory-test", .version = "1.0.0" });
    defer server.deinit();
    server.state = .ready;

    try server.addTool(.{
        .name = "owned_error",
        .handler = structuredErrorHandler,
        .deinit_result = json_result.deinitToolResult,
    });

    const messages = [_][]const u8{
        \\{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"owned_error","arguments":{"seed":"a"}}}
        ,
        \\{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"owned_error","arguments":{"seed":"b"}}}
        ,
        \\{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"owned_error","arguments":{"seed":"c"}}}
        ,
        \\{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"owned_error","arguments":{"seed":"d"}}}
        ,
    };
    var transport = CaptureTransport{ .messages = &messages };
    defer transport.deinit(allocator);

    try server.runWithTransport(std.testing.io, allocator, transport.transport());

    try std.testing.expectEqual(messages.len, transport.responses.items.len);
    for (transport.responses.items) |response| {
        try expectToolCallResponse(response, true, "structured_error");
    }
}

fn successHandler(_: ?*anyopaque, _: std.Io, allocator: std.mem.Allocator, _: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const value = makeOwnedNestedValue(allocator, "structured_success") catch return error.OutOfMemory;
    return json_result.structuredOwned(allocator, value);
}

fn structuredErrorHandler(_: ?*anyopaque, _: std.Io, allocator: std.mem.Allocator, _: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const value = makeOwnedNestedValue(allocator, "structured_error") catch return error.OutOfMemory;
    defer json_result.deinitOwnedValue(allocator, value);
    return json_result.structuredError(allocator, value);
}

fn expectToolCallResponse(response: []const u8, is_error: bool, expected_kind: []const u8) !void {
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, response, .{});
    defer parsed.deinit();

    const root = parsed.value.object;
    const result = root.get("result").?.object;
    try std.testing.expectEqual(is_error, result.get("isError").?.bool);

    const content = result.get("content").?.array;
    try std.testing.expectEqual(@as(usize, 1), content.items.len);
    try std.testing.expectEqualStrings("text", content.items[0].object.get("type").?.string);

    const structured = result.get("structuredContent").?.object;
    try std.testing.expectEqualStrings(expected_kind, structured.get("kind").?.string);
    try expectJsonNumber(structured.get("ratio").?, 1.25);
    const details = structured.get("details").?.array;
    try std.testing.expectEqualStrings("alpha", details.items[0].string);
    try expectJsonNumber(details.items[1], 99.5);
}

fn expectJsonNumber(value: std.json.Value, expected: f64) !void {
    const actual = switch (value) {
        .float => |float| float,
        .integer => |integer| @as(f64, @floatFromInt(integer)),
        .number_string => |number_string| std.fmt.parseFloat(f64, number_string) catch return error.TestUnexpectedResult,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectApproxEqAbs(expected, actual, 0.000001);
}

fn makeOwnedNestedValue(allocator: std.mem.Allocator, kind: []const u8) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer json_result.deinitOwnedValue(allocator, .{ .object = obj });

    try putOwnedString(allocator, &obj, "kind", kind);
    try putOwnedNumberString(allocator, &obj, "ratio", "1.25");

    var details = std.json.Array.init(allocator);
    var details_owned = true;
    errdefer if (details_owned) json_result.deinitOwnedValue(allocator, .{ .array = details });
    try appendOwnedString(allocator, &details, "alpha");
    try appendOwnedNumberString(allocator, &details, "99.5");
    try putOwnedValue(allocator, &obj, "details", .{ .array = details });
    details_owned = false;

    var nested = std.json.ObjectMap.empty;
    var nested_owned = true;
    errdefer if (nested_owned) json_result.deinitOwnedValue(allocator, .{ .object = nested });
    try putOwnedString(allocator, &nested, "message", "owned nested string");
    try putOwnedValue(allocator, &obj, "nested", .{ .object = nested });
    nested_owned = false;

    return .{ .object = obj };
}

fn putOwnedValue(allocator: std.mem.Allocator, obj: *std.json.ObjectMap, key: []const u8, value: std.json.Value) !void {
    const owned_key = try allocator.dupe(u8, key);
    errdefer allocator.free(owned_key);
    try obj.put(allocator, owned_key, value);
}

fn putOwnedString(allocator: std.mem.Allocator, obj: *std.json.ObjectMap, key: []const u8, value: []const u8) !void {
    const owned_value = try allocator.dupe(u8, value);
    errdefer allocator.free(owned_value);
    try putOwnedValue(allocator, obj, key, .{ .string = owned_value });
}

fn putOwnedNumberString(allocator: std.mem.Allocator, obj: *std.json.ObjectMap, key: []const u8, value: []const u8) !void {
    const owned_value = try allocator.dupe(u8, value);
    errdefer allocator.free(owned_value);
    try putOwnedValue(allocator, obj, key, .{ .number_string = owned_value });
}

fn appendOwnedString(allocator: std.mem.Allocator, array: *std.json.Array, value: []const u8) !void {
    const owned_value = try allocator.dupe(u8, value);
    errdefer allocator.free(owned_value);
    try array.append(.{ .string = owned_value });
}

fn appendOwnedNumberString(allocator: std.mem.Allocator, array: *std.json.Array, value: []const u8) !void {
    const owned_value = try allocator.dupe(u8, value);
    errdefer allocator.free(owned_value);
    try array.append(.{ .number_string = owned_value });
}
