const std = @import("std");
const mcp = @import("mcp");

const json_result = @import("../../adapters/mcp/result.zig");
const mcp_server = @import("../../adapters/mcp/server.zig");

/// Transport test double that captures all outbound JSON-RPC messages.
const CaptureTransport = struct {
    messages: []const []const u8,
    index: usize = 0,
    responses: std.ArrayList([]u8) = .empty,

    /// Releases owned allocations/resources; callers must not use the value afterward.
    fn deinit(self: *CaptureTransport, allocator: std.mem.Allocator) void {
        for (self.responses.items) |response| allocator.free(response);
        self.responses.deinit(allocator);
    }

    /// Returns the transport vtable used by this test double.
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

    /// Captures an outbound JSON-RPC message.
    fn send(self: *CaptureTransport, _: std.Io, allocator: std.mem.Allocator, message: []const u8) mcp.transport.Transport.SendError!void {
        const owned = allocator.dupe(u8, message) catch return error.OutOfMemory;
        var response_owned = true;
        defer if (response_owned) allocator.free(owned);
        self.responses.append(allocator, owned) catch return error.OutOfMemory;
        response_owned = false;
    }

    /// Dequeues the next inbound JSON-RPC message.
    fn receive(self: *CaptureTransport, _: std.Io, _: std.mem.Allocator) mcp.transport.Transport.ReceiveError!?[]const u8 {
        if (self.index >= self.messages.len) return error.EndOfStream;
        defer self.index += 1;
        return self.messages[self.index];
    }

    /// Marks the scripted transport closed.
    fn close(_: *CaptureTransport) void {}

    /// Sends a JSON-RPC message through the transport vtable.
    fn sendVtable(ptr: *anyopaque, io: std.Io, allocator: std.mem.Allocator, message: []const u8) mcp.transport.Transport.SendError!void {
        const self: *CaptureTransport = @ptrCast(@alignCast(ptr));
        return self.send(io, allocator, message);
    }

    /// Receives a JSON-RPC message through the transport vtable.
    fn receiveVtable(ptr: *anyopaque, io: std.Io, allocator: std.mem.Allocator) mcp.transport.Transport.ReceiveError!?[]const u8 {
        const self: *CaptureTransport = @ptrCast(@alignCast(ptr));
        return self.receive(io, allocator);
    }

    /// Closes the transport through the transport vtable.
    fn closeVtable(ptr: *anyopaque) void {
        const self: *CaptureTransport = @ptrCast(@alignCast(ptr));
        self.close();
    }
};

test "capture transport close and json number helpers cover adapter variants" {
    const messages = [_][]const u8{};
    var transport = CaptureTransport{ .messages = &messages };
    defer transport.deinit(std.testing.allocator);

    const tx = transport.transport();
    tx.vtable.close(tx.ptr);
    try expectJsonNumber(.{ .integer = 42 }, 42);
    try expectJsonNumber(.{ .number_string = "2.5" }, 2.5);
}

test "mcp tools/call releases repeated successful structured results" {
    const allocator = std.testing.allocator;
    var server = mcp_server.Server.init(allocator, .{ .name = "memory-test", .version = "1.0.0" });
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
        try expectToolCallResponse(response, false, "structured_success", "owned_success");
    }
}

test "mcp tools/call releases repeated structured tool errors" {
    const allocator = std.testing.allocator;
    var server = mcp_server.Server.init(allocator, .{ .name = "memory-test", .version = "1.0.0" });
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
        try expectToolCallResponse(response, true, "structured_error", "owned_error");
    }
}

test "mcp resources/read releases repeated owned resource content" {
    const allocator = std.testing.allocator;
    var server = mcp_server.Server.init(allocator, .{ .name = "memory-test", .version = "1.0.0" });
    defer server.deinit();
    server.state = .ready;

    try server.addResourceWithDeinit(.{
        .uri = "zigars://owned-resource",
        .name = "owned resource",
        .handler = ownedResourceHandler,
    }, json_result.deinitResourceContent);

    const messages = [_][]const u8{
        \\{"jsonrpc":"2.0","id":1,"method":"resources/read","params":{"uri":"zigars://owned-resource"}}
        ,
        \\{"jsonrpc":"2.0","id":2,"method":"resources/read","params":{"uri":"zigars://owned-resource"}}
        ,
        \\{"jsonrpc":"2.0","id":3,"method":"resources/read","params":{"uri":"zigars://owned-resource"}}
        ,
        \\{"jsonrpc":"2.0","id":4,"method":"resources/read","params":{"uri":"zigars://owned-resource"}}
        ,
    };
    var transport = CaptureTransport{ .messages = &messages };
    defer transport.deinit(allocator);

    try server.runWithTransport(std.testing.io, allocator, transport.transport());

    try std.testing.expectEqual(messages.len, transport.responses.items.len);
    for (transport.responses.items) |response| {
        try expectResourceReadResponse(response, "owned resource text");
    }
}

test "mcp prompts/get releases repeated owned prompt messages" {
    const allocator = std.testing.allocator;
    var server = mcp_server.Server.init(allocator, .{ .name = "memory-test", .version = "1.0.0" });
    defer server.deinit();
    server.state = .ready;

    try server.addPromptWithDeinit(.{
        .name = "owned_prompt",
        .handler = ownedPromptHandler,
    }, json_result.deinitPromptMessages);

    const messages = [_][]const u8{
        \\{"jsonrpc":"2.0","id":1,"method":"prompts/get","params":{"name":"owned_prompt","arguments":{}}}
        ,
        \\{"jsonrpc":"2.0","id":2,"method":"prompts/get","params":{"name":"owned_prompt","arguments":{}}}
        ,
        \\{"jsonrpc":"2.0","id":3,"method":"prompts/get","params":{"name":"owned_prompt","arguments":{}}}
        ,
        \\{"jsonrpc":"2.0","id":4,"method":"prompts/get","params":{"name":"owned_prompt","arguments":{}}}
        ,
    };
    var transport = CaptureTransport{ .messages = &messages };
    defer transport.deinit(allocator);

    try server.runWithTransport(std.testing.io, allocator, transport.transport());

    try std.testing.expectEqual(messages.len, transport.responses.items.len);
    for (transport.responses.items) |response| {
        try expectPromptGetResponse(response, "owned prompt text");
    }
}

/// Tool-call handler fixture that returns a success payload.
fn successHandler(_: ?*anyopaque, _: *mcp_server.Server, _: std.Io, allocator: std.mem.Allocator, _: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const value = makeOwnedNestedValue(allocator, "structured_success") catch return error.OutOfMemory;
    return json_result.structuredOwned(allocator, value);
}

/// Tool-call handler fixture that returns a structured error.
fn structuredErrorHandler(_: ?*anyopaque, _: *mcp_server.Server, _: std.Io, allocator: std.mem.Allocator, _: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const value = makeOwnedNestedValue(allocator, "structured_error") catch return error.OutOfMemory;
    defer json_result.deinitOwnedValue(allocator, value);
    return json_result.structuredError(allocator, value);
}

/// Resource handler fixture that returns allocator-owned content.
fn ownedResourceHandler(_: ?*anyopaque, _: std.Io, allocator: std.mem.Allocator, uri: []const u8) mcp.resources.ResourceError!mcp.resources.ResourceContent {
    const text = allocator.dupe(u8, "owned resource text") catch return error.OutOfMemory;
    return .{
        .uri = uri,
        .mimeType = "text/plain",
        .text = text,
    };
}

/// Prompt handler fixture that returns allocator-owned prompt messages.
fn ownedPromptHandler(_: ?*anyopaque, _: std.Io, allocator: std.mem.Allocator, _: ?std.json.Value) mcp.prompts.PromptError![]const mcp.prompts.PromptMessage {
    const messages = allocator.alloc(mcp.prompts.PromptMessage, 1) catch return error.OutOfMemory;
    var messages_owned = true;
    defer if (messages_owned) allocator.free(messages);
    const text = allocator.dupe(u8, "owned prompt text") catch return error.OutOfMemory;
    messages[0] = mcp.prompts.userMessage(text);
    messages_owned = false;
    return messages;
}

/// Records an expected tool call response call, cloning request data and failing on allocation errors.
fn expectToolCallResponse(response: []const u8, is_error: bool, expected_kind: []const u8, expected_tool: []const u8) !void {
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, response, .{});
    defer parsed.deinit();

    const root = parsed.value.object;
    const result = root.get("result").?.object;
    const response_id = root.get("id").?.integer;
    try std.testing.expectEqual(is_error, result.get("isError").?.bool);

    const content = result.get("content").?.array;
    try std.testing.expectEqual(@as(usize, 1), content.items.len);
    try std.testing.expectEqualStrings("text", content.items[0].object.get("type").?.string);

    const structured = result.get("structuredContent").?.object;
    try std.testing.expectEqualStrings(expected_kind, structured.get("kind").?.string);
    try std.testing.expect(structured.get("dev.zigars/correlation") == null);
    try expectJsonNumber(structured.get("ratio").?, 1.25);
    const details = structured.get("details").?.array;
    try std.testing.expectEqualStrings("alpha", details.items[0].string);
    try expectJsonNumber(details.items[1], 99.5);

    const meta = result.get("_meta").?.object;
    const correlation = meta.get("dev.zigars/correlation").?.object;
    try std.testing.expectEqual(@as(i64, 1), correlation.get("schema_version").?.integer);
    try std.testing.expectEqualStrings("tools/call", correlation.get("mcp_method").?.string);
    try std.testing.expectEqualStrings(expected_tool, correlation.get("tool_name").?.string);
    try std.testing.expectEqualStrings("integer", correlation.get("mcp_request_id").?.object.get("type").?.string);
    var id_buffer: [32]u8 = undefined;
    const expected_id = try std.fmt.bufPrint(&id_buffer, "{d}", .{response_id});
    try std.testing.expectEqualStrings(expected_id, correlation.get("mcp_request_id").?.object.get("value").?.string);
    try std.testing.expectEqual(@as(usize, 32), correlation.get("trace_id").?.string.len);
    try std.testing.expectEqual(@as(usize, 16), correlation.get("span_id").?.string.len);
    try std.testing.expect(std.mem.startsWith(u8, correlation.get("tool_call_id").?.string, "zigars-tc-"));
}

/// Records an expected resource read response call, cloning request data and failing on allocation errors.
fn expectResourceReadResponse(response: []const u8, expected_text: []const u8) !void {
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, response, .{});
    defer parsed.deinit();

    const root = parsed.value.object;
    const result = root.get("result").?.object;
    const contents = result.get("contents").?.array;
    try std.testing.expectEqual(@as(usize, 1), contents.items.len);
    try std.testing.expectEqualStrings(expected_text, contents.items[0].object.get("text").?.string);
}

/// Records an expected prompt get response call, cloning request data and failing on allocation errors.
fn expectPromptGetResponse(response: []const u8, expected_text: []const u8) !void {
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, response, .{});
    defer parsed.deinit();

    const root = parsed.value.object;
    const result = root.get("result").?.object;
    const messages = result.get("messages").?.array;
    try std.testing.expectEqual(@as(usize, 1), messages.items.len);
    const content = messages.items[0].object.get("content").?.object;
    try std.testing.expectEqualStrings("text", content.get("type").?.string);
    try std.testing.expectEqualStrings(expected_text, content.get("text").?.string);
}

/// Records an expected json number call, cloning request data and failing on allocation errors.
fn expectJsonNumber(value: std.json.Value, expected: f64) !void {
    const actual = switch (value) {
        .float => |float| float,
        .integer => |integer| @as(f64, @floatFromInt(integer)),
        .number_string => |number_string| std.fmt.parseFloat(f64, number_string) catch return error.TestUnexpectedResult,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectApproxEqAbs(expected, actual, 0.000001);
}

/// Builds nested JSON test data with allocator-owned containers.
fn makeOwnedNestedValue(allocator: std.mem.Allocator, kind: []const u8) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    var obj_owned = true;
    defer if (obj_owned) json_result.deinitOwnedValue(allocator, .{ .object = obj });

    try putOwnedString(allocator, &obj, "kind", kind);
    try putOwnedNumberString(allocator, &obj, "ratio", "1.25");

    var details = std.json.Array.init(allocator);
    var details_owned = true;
    defer if (details_owned) json_result.deinitOwnedValue(allocator, .{ .array = details });
    try appendOwnedString(allocator, &details, "alpha");
    try appendOwnedNumberString(allocator, &details, "99.5");
    try putOwnedValue(allocator, &obj, "details", .{ .array = details });
    details_owned = false;

    var nested = std.json.ObjectMap.empty;
    var nested_owned = true;
    defer if (nested_owned) json_result.deinitOwnedValue(allocator, .{ .object = nested });
    try putOwnedString(allocator, &nested, "message", "owned nested string");
    try putOwnedValue(allocator, &obj, "nested", .{ .object = nested });
    nested_owned = false;

    obj_owned = false;
    return .{ .object = obj };
}

/// Inserts an owned JSON value into an object.
fn putOwnedValue(allocator: std.mem.Allocator, obj: *std.json.ObjectMap, key: []const u8, value: std.json.Value) !void {
    const owned_key = try allocator.dupe(u8, key);
    var key_owned = true;
    defer if (key_owned) allocator.free(owned_key);
    try obj.put(allocator, owned_key, value);
    key_owned = false;
}

/// Inserts an allocator-owned string into a JSON object.
fn putOwnedString(allocator: std.mem.Allocator, obj: *std.json.ObjectMap, key: []const u8, value: []const u8) !void {
    const owned_value = try allocator.dupe(u8, value);
    var value_owned = true;
    defer if (value_owned) allocator.free(owned_value);
    try putOwnedValue(allocator, obj, key, .{ .string = owned_value });
    value_owned = false;
}

/// Inserts a number encoded as an owned JSON string.
fn putOwnedNumberString(allocator: std.mem.Allocator, obj: *std.json.ObjectMap, key: []const u8, value: []const u8) !void {
    const owned_value = try allocator.dupe(u8, value);
    var value_owned = true;
    defer if (value_owned) allocator.free(owned_value);
    try putOwnedValue(allocator, obj, key, .{ .number_string = owned_value });
    value_owned = false;
}

/// Appends an allocator-owned string to a JSON array.
fn appendOwnedString(allocator: std.mem.Allocator, array: *std.json.Array, value: []const u8) !void {
    const owned_value = try allocator.dupe(u8, value);
    var value_owned = true;
    defer if (value_owned) allocator.free(owned_value);
    try array.append(.{ .string = owned_value });
    value_owned = false;
}

/// Appends a number encoded as an owned JSON string.
fn appendOwnedNumberString(allocator: std.mem.Allocator, array: *std.json.Array, value: []const u8) !void {
    const owned_value = try allocator.dupe(u8, value);
    var value_owned = true;
    defer if (value_owned) allocator.free(owned_value);
    try array.append(.{ .number_string = owned_value });
    value_owned = false;
}
