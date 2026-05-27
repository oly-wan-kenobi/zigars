const std = @import("std");
const mcp = @import("mcp");

const server_mod = @import("../../adapters/mcp/server.zig");
const app_ports = @import("../../app/ports.zig");
const mcp_result = @import("../../adapters/mcp/result.zig");

const Server = server_mod.Server;
const ServerState = server_mod.ServerState;
const Tool = server_mod.Tool;

const fixture_tool_content = [_]mcp.types.ContentBlock{
    .{ .text = .{ .text = "tool text" } },
    .{ .image = .{ .data = "image-bytes", .mimeType = "image/png" } },
    .{ .audio = .{ .data = "audio-bytes", .mimeType = "audio/wav" } },
    .{ .resource_link = .{ .name = "linked", .uri = "file:///linked", .title = "Linked", .description = "linked resource", .mimeType = "text/plain" } },
    .{ .resource = .{ .resource = .{ .uri = "file:///embedded", .text = "embedded text", .mimeType = "text/plain" } } },
};

const fixture_prompt_messages = [_]mcp.prompts.PromptMessage{
    .{ .role = .user, .content = .{ .text = .{ .text = "prompt text" } } },
    .{ .role = .assistant, .content = .{ .resource_link = .{ .name = "prompt-link", .uri = "file:///prompt" } } },
    .{ .role = .user, .content = .{ .image = .{ .data = "prompt-image", .mimeType = "image/png" } } },
    .{ .role = .assistant, .content = .{ .audio = .{ .data = "prompt-audio", .mimeType = "audio/wav" } } },
    .{ .role = .user, .content = .{ .resource = .{ .resource = .{ .uri = "file:///prompt-resource", .text = "prompt resource text" } } } },
};

/// Scripted transport that queues inbound JSON-RPC messages and captures sends.
const ScriptTransport = struct {
    messages: []const []const u8,
    index: usize = 0,
    sent: std.ArrayList([]const u8) = .empty,

    /// Releases owned allocations/resources; callers must not use the value afterward.
    fn deinit(self: *ScriptTransport, allocator: std.mem.Allocator) void {
        for (self.sent.items) |message| allocator.free(message);
        self.sent.deinit(allocator);
    }

    /// Returns the transport vtable used by this test double.
    fn transport(self: *ScriptTransport) mcp.transport.Transport {
        return .{
            .ptr = self,
            .vtable = &.{
                .send = sendVtable,
                .receive = receiveVtable,
                .close = closeVtable,
            },
        };
    }

    /// Sends a JSON-RPC message through the transport vtable.
    fn sendVtable(ptr: *anyopaque, _: std.Io, allocator: std.mem.Allocator, message: []const u8) mcp.transport.Transport.SendError!void {
        const self: *ScriptTransport = @ptrCast(@alignCast(ptr));
        const owned = allocator.dupe(u8, message) catch return error.OutOfMemory;
        self.sent.append(allocator, owned) catch {
            allocator.free(owned);
            return error.OutOfMemory;
        };
    }

    /// Receives a JSON-RPC message through the transport vtable.
    fn receiveVtable(ptr: *anyopaque, _: std.Io, _: std.mem.Allocator) mcp.transport.Transport.ReceiveError!?[]const u8 {
        const self: *ScriptTransport = @ptrCast(@alignCast(ptr));
        if (self.index >= self.messages.len) return error.EndOfStream;
        const message = self.messages[self.index];
        self.index += 1;
        return message;
    }

    /// Closes the transport through the transport vtable.
    fn closeVtable(_: *anyopaque) void {}
};

test "script transport frees messages when recording send fails" {
    var transport = ScriptTransport{ .messages = &.{} };
    defer transport.deinit(std.testing.allocator);
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 1 });
    try std.testing.expectError(error.OutOfMemory, transport.transport().send(std.testing.io, failing.allocator(), "message"));
    transport.transport().close();
}

/// Joins captured transport sends into a single owned buffer.
fn joinedSent(allocator: std.mem.Allocator, transport: *ScriptTransport) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (transport.sent.items) |message| {
        try out.appendSlice(allocator, message);
        try out.append(allocator, '\n');
    }
    return out.toOwnedSlice(allocator);
}

/// Records an expected before call, cloning request data and failing on allocation errors.
fn expectBefore(haystack: []const u8, first: []const u8, second: []const u8) !void {
    const first_index = std.mem.indexOf(u8, haystack, first) orelse return error.TestExpectedEqual;
    const second_index = std.mem.indexOf(u8, haystack, second) orelse return error.TestExpectedEqual;
    try std.testing.expect(first_index < second_index);
}

/// Tool handler fixture that returns a successful response.
fn okToolHandler(_: ?*anyopaque, _: *Server, _: std.Io, _: std.mem.Allocator, _: ?std.json.Value) !mcp.tools.ToolResult {
    return .{
        .content = fixture_tool_content[0..],
        .structuredContent = .{ .bool = true },
    };
}

/// Tool handler fixture that returns a structured failure.
fn failToolHandler(_: ?*anyopaque, _: *Server, _: std.Io, _: std.mem.Allocator, _: ?std.json.Value) !mcp.tools.ToolResult {
    return error.ExecutionFailed;
}

/// Resource handler fixture that returns borrowed content.
fn testResourceHandler(_: ?*anyopaque, _: std.Io, _: std.mem.Allocator, uri: []const u8) !mcp.resources.ResourceContent {
    return .{
        .uri = uri,
        .text = "resource text",
        .blob = "cmVzb3VyY2U=",
        .mimeType = "text/plain",
    };
}

/// Resource handler fixture that returns a structured failure.
fn failResourceHandler(_: ?*anyopaque, _: std.Io, _: std.mem.Allocator, _: []const u8) !mcp.resources.ResourceContent {
    return error.ReadFailed;
}

/// Dynamic resource handler fixture that resolves content at call time.
fn dynamicResourceHandler(_: ?*anyopaque, _: std.Io, _: std.mem.Allocator, uri: []const u8) !mcp.resources.ResourceContent {
    return .{
        .uri = uri,
        .text = "dynamic text",
        .blob = "ZHluYW1pYw==",
        .mimeType = "text/plain",
    };
}

/// Dynamic resource handler fixture that returns a structured failure.
fn failDynamicResourceHandler(_: ?*anyopaque, _: std.Io, _: std.mem.Allocator, _: []const u8) !mcp.resources.ResourceContent {
    return error.ReadFailed;
}

/// Releases owned allocations/resources; callers must not use the value afterward.
fn noopResourceDeinit(_: std.mem.Allocator, _: mcp.resources.ResourceContent) void {}

/// Prompt handler fixture that returns borrowed messages.
fn testPromptHandler(_: ?*anyopaque, _: std.Io, _: std.mem.Allocator, _: ?std.json.Value) ![]const mcp.prompts.PromptMessage {
    return fixture_prompt_messages[0..];
}

/// Prompt handler fixture that returns a structured failure.
fn failPromptHandler(_: ?*anyopaque, _: std.Io, _: std.mem.Allocator, _: ?std.json.Value) ![]const mcp.prompts.PromptMessage {
    return error.GenerationFailed;
}

/// Releases owned allocations/resources; callers must not use the value afterward.
fn noopPromptDeinit(_: std.mem.Allocator, _: []const mcp.prompts.PromptMessage) void {}

test "Server initialization" {
    var server: Server = .init(std.testing.allocator, .{
        .name = "test-server",
        .version = "1.0.0",
    });
    defer server.deinit();

    try std.testing.expectEqual(ServerState.uninitialized, server.state);
    try std.testing.expectEqualStrings("test-server", server.config.name);
}

test "Server add tool" {
    var server: Server = .init(std.testing.allocator, .{
        .name = "test-server",
        .version = "1.0.0",
    });
    defer server.deinit();

    const tool: Tool = .{
        .name = "test_tool",
        .description = "A test tool",
        .handler = okToolHandler,
    };

    try server.addTool(tool);
    try std.testing.expect(server.tools.contains("test_tool"));
    try std.testing.expect(server.capabilities.tools != null);
}

test "Server add resource" {
    var server: Server = .init(std.testing.allocator, .{
        .name = "test-server",
        .version = "1.0.0",
    });
    defer server.deinit();

    try server.addResourceWithDeinit(.{
        .uri = "file:///test",
        .name = "Test",
        .handler = testResourceHandler,
    }, noopResourceDeinit);
    try std.testing.expect(server.resources.contains("file:///test"));
    try std.testing.expect(server.resource_content_deinits.contains("file:///test"));
    try std.testing.expect(server.capabilities.resources != null);
}

test "Server add prompt" {
    var server: Server = .init(std.testing.allocator, .{
        .name = "test-server",
        .version = "1.0.0",
    });
    defer server.deinit();

    try server.addPromptWithDeinit(.{
        .name = "test_prompt",
        .description = "A test prompt",
        .handler = testPromptHandler,
    }, noopPromptDeinit);
    try std.testing.expect(server.prompts.contains("test_prompt"));
    try std.testing.expect(server.prompt_message_deinits.contains("test_prompt"));
    try std.testing.expect(server.capabilities.prompts != null);
}

test "Server enable capabilities" {
    var server: Server = .init(std.testing.allocator, .{
        .name = "test-server",
        .version = "1.0.0",
    });
    defer server.deinit();

    server.enableLogging();
    server.enableCompletions();

    try std.testing.expect(server.capabilities.logging != null);
    try std.testing.expect(server.capabilities.completions != null);
}

test "Server routes JSON-RPC methods and serializes registered surfaces" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var server: Server = .init(allocator, .{
        .name = "fixture-server",
        .version = "1.0.0",
        .title = "Fixture",
        .description = "Fixture server",
        .websiteUrl = "https://example.test",
        .instructions = "Use fixture tools.",
    });
    defer server.deinit();
    server.enableLogging();
    server.enableCompletions();

    var props = std.json.ObjectMap.empty;
    try props.put(allocator, "flag", .{ .object = .empty });
    try server.addTool(.{
        .name = "ok_tool",
        .description = "A routed tool",
        .title = "OK Tool",
        .inputSchema = .{
            .@"$schema" = "https://json-schema.org/draft/2020-12/schema",
            .description = "Tool input",
            .properties = .{ .object = props },
            .required = &.{"flag"},
        },
        .outputSchema = .{
            .@"$schema" = "https://json-schema.org/draft/2020-12/schema",
            .properties = .{ .object = props },
            .required = &.{"kind"},
        },
        .execution = .{ .taskSupport = "optional" },
        .annotations = .{ .title = "Annotation", .readOnlyHint = true, .destructiveHint = false, .idempotentHint = true, .openWorldHint = false },
        .handler = okToolHandler,
    });
    try server.addTool(.{
        .name = "fail_tool",
        .description = "A failing tool",
        .handler = failToolHandler,
    });
    try server.addResourceWithDeinit(.{
        .uri = "file:///resource",
        .name = "Resource",
        .title = "Resource Title",
        .description = "Resource description",
        .mimeType = "text/plain",
        .size = 12,
        .handler = testResourceHandler,
    }, noopResourceDeinit);
    server.enableResourceSubscriptions();
    try server.addResourceTemplate(.{
        .uriTemplate = "file:///{name}",
        .name = "Template",
        .title = "Template Title",
        .description = "Template description",
        .mimeType = "text/plain",
    });
    try server.addPromptWithDeinit(.{
        .name = "prompt",
        .title = "Prompt Title",
        .description = "Prompt description",
        .arguments = &.{.{ .name = "topic", .title = "Topic", .description = "Prompt topic", .required = true }},
        .handler = testPromptHandler,
    }, noopPromptDeinit);

    const messages = [_][]const u8{
        "{ bad json",
        "{\"jsonrpc\":\"2.0\",\"id\":0,\"method\":\"ping\"}",
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-11-25\",\"clientInfo\":{\"name\":\"tester\",\"version\":\"1\"}}}",
        "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}",
        "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/roots/list_changed\"}",
        "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/cancelled\",\"params\":{\"requestId\":99}}",
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"ping\"}",
        "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/list\"}",
        "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/call\",\"params\":{\"name\":\"ok_tool\",\"arguments\":{\"flag\":true}}}",
        "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"tools/call\",\"params\":{\"name\":\"fail_tool\"}}",
        "{\"jsonrpc\":\"2.0\",\"id\":6,\"method\":\"tools/call\",\"params\":{\"name\":\"missing_tool\"}}",
        "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"resources/list\"}",
        "{\"jsonrpc\":\"2.0\",\"id\":8,\"method\":\"resources/read\",\"params\":{\"uri\":\"file:///resource\"}}",
        "{\"jsonrpc\":\"2.0\",\"id\":9,\"method\":\"resources/read\",\"params\":{\"uri\":\"file:///missing\"}}",
        "{\"jsonrpc\":\"2.0\",\"id\":10,\"method\":\"resources/templates/list\"}",
        "{\"jsonrpc\":\"2.0\",\"id\":11,\"method\":\"resources/subscribe\",\"params\":{\"uri\":\"file:///resource\"}}",
        "{\"jsonrpc\":\"2.0\",\"id\":12,\"method\":\"resources/unsubscribe\",\"params\":{\"uri\":\"file:///resource\"}}",
        "{\"jsonrpc\":\"2.0\",\"id\":13,\"method\":\"prompts/list\"}",
        "{\"jsonrpc\":\"2.0\",\"id\":14,\"method\":\"prompts/get\",\"params\":{\"name\":\"prompt\",\"arguments\":{\"topic\":\"zig\"}}}",
        "{\"jsonrpc\":\"2.0\",\"id\":15,\"method\":\"prompts/get\",\"params\":{\"name\":\"missing\"}}",
        "{\"jsonrpc\":\"2.0\",\"id\":16,\"method\":\"logging/setLevel\",\"params\":{\"level\":\"debug\"}}",
        "{\"jsonrpc\":\"2.0\",\"id\":17,\"method\":\"completion/complete\",\"params\":{}}",
        "{\"jsonrpc\":\"2.0\",\"id\":18,\"method\":\"completion/complete\",\"params\":{\"ref\":{\"type\":\"ref/prompt\"},\"argument\":{\"name\":\"topic\",\"value\":\"pro\"}}}",
        "{\"jsonrpc\":\"2.0\",\"id\":19,\"method\":\"completion/complete\",\"params\":{\"ref\":{\"type\":\"ref/resource\"},\"argument\":{\"name\":\"uri\",\"value\":\"file\"}}}",
        "{\"jsonrpc\":\"2.0\",\"id\":20,\"method\":\"completion/complete\",\"params\":{\"argument\":{\"name\":\"command\",\"value\":\"b\"}}}",
        "{\"jsonrpc\":\"2.0\",\"id\":21,\"method\":\"completion/complete\",\"params\":{\"argument\":{\"name\":\"client\",\"value\":\"co\"}}}",
        "{\"jsonrpc\":\"2.0\",\"id\":25,\"method\":\"completion/complete\",\"params\":{\"argument\":{\"name\":\"workflow\",\"value\":\"zigars_\"}}}",
        "{\"jsonrpc\":\"2.0\",\"id\":26,\"method\":\"completion/complete\",\"params\":{\"argument\":{\"name\":\"uri\",\"value\":\"file\"}}}",
        "{\"jsonrpc\":\"2.0\",\"id\":27,\"method\":\"completion/complete\",\"params\":{\"argument\":{\"name\":\"mode\",\"value\":\"comp\"}}}",
        "{\"jsonrpc\":\"2.0\",\"id\":22,\"method\":\"unknown/method\"}",
        "{\"jsonrpc\":\"2.0\",\"id\":23,\"result\":{}}",
        "{\"jsonrpc\":\"2.0\",\"id\":24,\"error\":{\"code\":-32603,\"message\":\"client error\"}}",
        "{\"jsonrpc\":\"2.0\",\"id\":\"string-response\",\"result\":{}}",
        "{\"jsonrpc\":\"2.0\",\"id\":\"string-error\",\"error\":{\"code\":-32603,\"message\":\"client error\"}}",
    };
    var transport: ScriptTransport = .{ .messages = messages[0..] };
    defer transport.deinit(allocator);
    try server.pending_requests.put(23, .{ .method = "client/request", .timestamp = 1 });
    try server.pending_requests.put(24, .{ .method = "client/error", .timestamp = 2 });

    try server.runWithTransport(std.testing.io, allocator, transport.transport());
    try std.testing.expectEqual(ServerState.stopped, server.state);
    try std.testing.expect(!server.pending_requests.contains(23));
    try std.testing.expect(!server.pending_requests.contains(24));

    try server.sendLogMessage(std.testing.io, allocator, .debug, "debug log");
    try server.sendProgress(std.testing.io, allocator, .{ .string = "tok" }, 0.5, 1.0, "half");
    try server.notifyToolsChanged(std.testing.io, allocator);
    try server.notifyResourcesChanged(std.testing.io, allocator);
    try server.notifyResourceUpdated(std.testing.io, allocator, "file:///resource");
    try server.notifyPromptsChanged(std.testing.io, allocator);

    const sent = try joinedSent(allocator, &transport);
    try std.testing.expect(transport.sent.items.len >= 23);
    try std.testing.expect(std.mem.indexOf(u8, sent, "Server not initialized") != null);
    try std.testing.expect(std.mem.indexOf(u8, sent, "\"serverInfo\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, sent, "\"tools\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, sent, "\"outputSchema\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, sent, "\"structuredContent\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, sent, "\"resource_link\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, sent, "ExecutionFailed") != null);
    try std.testing.expect(std.mem.indexOf(u8, sent, "unexpected_tool_handler_error") != null);
    try std.testing.expect(std.mem.indexOf(u8, sent, "\"error_kind\":\"execution_failed\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, sent, "Tool not found") != null);
    try std.testing.expect(std.mem.indexOf(u8, sent, "\"resources\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, sent, "\"resourceTemplates\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, sent, "\"result\":{}") != null);
    try std.testing.expect(std.mem.indexOf(u8, sent, "\"prompts\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, sent, "\"completion\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, sent, "zigars_compile_error_workflow") != null);
    try std.testing.expect(std.mem.indexOf(u8, sent, "compact") != null);
    try std.testing.expect(std.mem.indexOf(u8, sent, "Method not found") != null);
    try std.testing.expect(std.mem.indexOf(u8, sent, "notifications/tools/list_changed") != null);
    try std.testing.expect(std.mem.indexOf(u8, sent, "notifications/resources/updated") != null);
    try std.testing.expect(std.mem.indexOf(u8, sent, "notifications/prompts/list_changed") != null);
}

test "Server dynamic resources cover fallback handler success and failure" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var success_server: Server = .init(allocator, .{
        .name = "dynamic-server",
        .version = "1.0.0",
    });
    defer success_server.deinit();
    success_server.setDynamicResourceHandler(dynamicResourceHandler, null, noopResourceDeinit);

    const success_messages = [_][]const u8{
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-11-25\",\"clientInfo\":{\"name\":\"tester\",\"version\":\"1\"}}}",
        "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}",
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"resources/read\",\"params\":{\"uri\":\"file:///dynamic\"}}",
    };
    var success_transport: ScriptTransport = .{ .messages = success_messages[0..] };
    defer success_transport.deinit(allocator);
    try success_server.runWithTransport(std.testing.io, allocator, success_transport.transport());
    const success_sent = try joinedSent(allocator, &success_transport);
    try std.testing.expect(std.mem.indexOf(u8, success_sent, "dynamic text") != null);
    try std.testing.expect(std.mem.indexOf(u8, success_sent, "ZHluYW1pYw==") != null);

    var failure_server: Server = .init(allocator, .{
        .name = "dynamic-failure-server",
        .version = "1.0.0",
    });
    defer failure_server.deinit();
    failure_server.setDynamicResourceHandler(failDynamicResourceHandler, null, null);

    const failure_messages = [_][]const u8{
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-11-25\",\"clientInfo\":{\"name\":\"tester\",\"version\":\"1\"}}}",
        "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}",
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"resources/read\",\"params\":{\"uri\":\"file:///missing\"}}",
    };
    var failure_transport: ScriptTransport = .{ .messages = failure_messages[0..] };
    defer failure_transport.deinit(allocator);
    try failure_server.runWithTransport(std.testing.io, allocator, failure_transport.transport());
    const failure_sent = try joinedSent(allocator, &failure_transport);
    try std.testing.expect(std.mem.indexOf(u8, failure_sent, "Dynamic resource not found or could not be read") != null);
}

test "Server discovery lists follow registration order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var server: Server = .init(allocator, .{
        .name = "order-server",
        .version = "1.0.0",
    });
    defer server.deinit();

    try server.addTool(.{ .name = "tool_z_first", .description = "first", .handler = okToolHandler });
    try server.addTool(.{ .name = "tool_a_second", .description = "second", .handler = okToolHandler });
    try server.addResource(.{ .uri = "file:///z-first", .name = "Resource Z", .handler = testResourceHandler });
    try server.addResource(.{ .uri = "file:///a-second", .name = "Resource A", .handler = testResourceHandler });
    try server.addResourceTemplate(.{ .uriTemplate = "file:///z/{name}", .name = "Template Z" });
    try server.addResourceTemplate(.{ .uriTemplate = "file:///a/{name}", .name = "Template A" });
    try server.addPrompt(.{ .name = "prompt_z_first", .description = "first", .handler = testPromptHandler });
    try server.addPrompt(.{ .name = "prompt_a_second", .description = "second", .handler = testPromptHandler });

    const messages = [_][]const u8{
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-11-25\",\"clientInfo\":{\"name\":\"tester\",\"version\":\"1\"}}}",
        "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}",
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\"}",
        "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"resources/list\"}",
        "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"resources/templates/list\"}",
        "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"prompts/list\"}",
    };
    var transport: ScriptTransport = .{ .messages = messages[0..] };
    defer transport.deinit(allocator);

    try server.runWithTransport(std.testing.io, allocator, transport.transport());

    const sent = try joinedSent(allocator, &transport);
    try expectBefore(sent, "\"name\":\"tool_z_first\"", "\"name\":\"tool_a_second\"");
    try expectBefore(sent, "\"uri\":\"file:///z-first\"", "\"uri\":\"file:///a-second\"");
    try expectBefore(sent, "\"uriTemplate\":\"file:///z/{name}\"", "\"uriTemplate\":\"file:///a/{name}\"");
    try expectBefore(sent, "\"name\":\"prompt_z_first\"", "\"name\":\"prompt_a_second\"");
}

test "Server returns structured internal errors for resource and prompt handler failures" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var server: Server = .init(allocator, .{
        .name = "failure-server",
        .version = "1.0.0",
    });
    defer server.deinit();

    try server.addResource(.{ .uri = "file:///fails", .name = "Failing Resource", .handler = failResourceHandler });
    try server.addPrompt(.{ .name = "fails", .description = "Failing Prompt", .handler = failPromptHandler });

    const messages = [_][]const u8{
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-11-25\",\"clientInfo\":{\"name\":\"tester\",\"version\":\"1\"}}}",
        "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}",
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"resources/read\",\"params\":{\"uri\":\"file:///fails\"}}",
        "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"prompts/get\",\"params\":{\"name\":\"fails\"}}",
    };
    var transport: ScriptTransport = .{ .messages = messages[0..] };
    defer transport.deinit(allocator);

    try server.runWithTransport(std.testing.io, allocator, transport.transport());

    const sent = try joinedSent(allocator, &transport);
    try std.testing.expect(std.mem.indexOf(u8, sent, "\"code\":-32603") != null);
    try std.testing.expect(std.mem.indexOf(u8, sent, "unexpected_resource_handler_error") != null);
    try std.testing.expect(std.mem.indexOf(u8, sent, "\"resource_uri\":\"file:///fails\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, sent, "ReadFailed") != null);
    try std.testing.expect(std.mem.indexOf(u8, sent, "unexpected_prompt_handler_error") != null);
    try std.testing.expect(std.mem.indexOf(u8, sent, "\"prompt\":\"fails\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, sent, "GenerationFailed") != null);
}

test "Server rejects unsupported subscriptions and invalid log levels" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var server: Server = .init(allocator, .{
        .name = "polish-server",
        .version = "1.0.0",
    });
    defer server.deinit();
    server.enableLogging();
    try server.addResource(.{ .uri = "file:///resource", .name = "Resource", .handler = testResourceHandler });

    const messages = [_][]const u8{
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-11-25\",\"clientInfo\":{\"name\":\"tester\",\"version\":\"1\"}}}",
        "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}",
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"resources/subscribe\",\"params\":{\"uri\":\"file:///resource\"}}",
        "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"resources/unsubscribe\",\"params\":{\"uri\":\"file:///resource\"}}",
        "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"logging/setLevel\"}",
        "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"logging/setLevel\",\"params\":{\"level\":7}}",
        "{\"jsonrpc\":\"2.0\",\"id\":6,\"method\":\"logging/setLevel\",\"params\":{\"level\":\"trace\"}}",
        "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"logging/setLevel\",\"params\":{\"level\":\"debug\"}}",
    };
    var transport: ScriptTransport = .{ .messages = messages[0..] };
    defer transport.deinit(allocator);

    try server.runWithTransport(std.testing.io, allocator, transport.transport());

    const sent = try joinedSent(allocator, &transport);
    try std.testing.expect(std.mem.indexOf(u8, sent, "Resource subscriptions are not supported") != null);
    try std.testing.expect(std.mem.indexOf(u8, sent, "logging/setLevel requires params.level to be a string") != null);
    try std.testing.expect(std.mem.indexOf(u8, sent, "Unsupported logging level") != null);
    try std.testing.expect(std.mem.indexOf(u8, sent, "\"code\":-32602") != null);
    try std.testing.expectEqual(mcp.protocol.LogLevel.debug, server.log_level);
}

test "protocol helper scaffolds are capability aware" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var server: Server = .init(allocator, .{ .name = "helper-server", .version = "1.0.0" });
    defer server.deinit();

    const fallback = try server.tryElicitationCreate(std.testing.io, allocator, .{ .object = .empty });
    try std.testing.expectEqualStrings("protocol_helper_fallback", fallback.object.get("kind").?.string);
    try std.testing.expect(!fallback.object.get("supported").?.bool);

    server.client_capabilities = .{
        .elicitation = .{ .form = .{} },
        .sampling = .{ .context = .{} },
    };
    var transport = ScriptTransport{ .messages = &.{} };
    defer transport.deinit(allocator);
    server.transport = transport.transport();

    var elicit_params = std.json.ObjectMap.empty;
    try elicit_params.put(allocator, "message", .{ .string = "Need value" });
    const elicit = try server.tryElicitationCreate(std.testing.io, allocator, .{ .object = elicit_params });
    try std.testing.expect(elicit.object.get("supported").?.bool);
    try std.testing.expect(server.pending_requests.contains(elicit.object.get("request_id").?.integer));

    var sampling_params = std.json.ObjectMap.empty;
    try sampling_params.put(allocator, "maxTokens", .{ .integer = 16 });
    const sampling = try server.trySamplingCreateMessage(std.testing.io, allocator, .{ .object = sampling_params });
    try std.testing.expect(sampling.object.get("supported").?.bool);
    try std.testing.expect(server.pending_requests.contains(sampling.object.get("request_id").?.integer));

    const sent = try joinedSent(allocator, &transport);
    try std.testing.expect(std.mem.indexOf(u8, sent, "elicitation/create") != null);
    try std.testing.expect(std.mem.indexOf(u8, sent, "sampling/createMessage") != null);
}

test "protocol helper response classifiers cover declined malformed and timeout responses" {
    var elicited = std.json.ObjectMap.empty;
    try elicited.put(std.testing.allocator, "action", .{ .string = "accept" });
    defer elicited.deinit(std.testing.allocator);
    try std.testing.expectEqual(Server.ProtocolResponseStatus.accepted, Server.classifyElicitationResponse(.{ .object = elicited }));

    var declined = std.json.ObjectMap.empty;
    try declined.put(std.testing.allocator, "action", .{ .string = "decline" });
    defer declined.deinit(std.testing.allocator);
    try std.testing.expectEqual(Server.ProtocolResponseStatus.declined, Server.classifyElicitationResponse(.{ .object = declined }));

    var malformed = std.json.ObjectMap.empty;
    try malformed.put(std.testing.allocator, "action", .{ .integer = 1 });
    defer malformed.deinit(std.testing.allocator);
    try std.testing.expectEqual(Server.ProtocolResponseStatus.malformed, Server.classifyElicitationResponse(.{ .object = malformed }));
    try std.testing.expectEqual(Server.ProtocolResponseStatus.timeout, Server.classifyElicitationResponse(null));

    var sampled = std.json.ObjectMap.empty;
    try sampled.put(std.testing.allocator, "content", .{ .string = "summary" });
    defer sampled.deinit(std.testing.allocator);
    try std.testing.expectEqual(Server.ProtocolResponseStatus.accepted, Server.classifySamplingResponse(.{ .object = sampled }));
    try std.testing.expectEqual(Server.ProtocolResponseStatus.timeout, Server.classifySamplingResponse(null));
    try std.testing.expectEqual(Server.ProtocolResponseStatus.malformed, Server.classifySamplingResponse(.{ .object = .empty }));
}

test "client protocol request waits for matching elicitation response" {
    const allocator = std.testing.allocator;
    var server = Server.init(allocator, .{ .name = "protocol", .version = "1" });
    defer server.deinit();
    server.state = .ready;
    server.client_capabilities = .{ .elicitation = .{ .form = .{} } };

    const messages = [_][]const u8{
        \\{"jsonrpc":"2.0","method":"notifications/progress","params":{"progressToken":"p","progress":1}}
        ,
        \\{"jsonrpc":"2.0","id":1,"result":{"action":"accept","content":{"confirm":true}}}
        ,
    };
    var transport = ScriptTransport{ .messages = &messages };
    defer transport.deinit(allocator);
    server.transport = transport.transport();

    var params = std.json.ObjectMap.empty;
    try params.put(allocator, "message", .{ .string = "Apply?" });
    defer params.deinit(allocator);
    const response = try server.requestClientProtocol(std.testing.io, allocator, .{
        .feature = .elicitation,
        .method = "elicitation/create",
        .params = .{ .object = params },
    });
    try std.testing.expect(response.supported);
    try std.testing.expect(response.used);
    try std.testing.expectEqual(app_ports.ProtocolResponseStatus.accepted, response.status);
    try std.testing.expect(response.result != null);
    if (response.result) |result| mcp_result.deinitOwnedValue(allocator, result);
    try std.testing.expectEqual(@as(usize, 0), server.pending_requests.count());

    const sent = try joinedSent(allocator, &transport);
    defer allocator.free(sent);
    try std.testing.expect(std.mem.indexOf(u8, sent, "elicitation/create") != null);
}

test "client protocol request returns unsupported and transport timeout metadata" {
    const allocator = std.testing.allocator;
    var server = Server.init(allocator, .{ .name = "protocol", .version = "1" });
    defer server.deinit();
    server.state = .ready;

    var params = std.json.ObjectMap.empty;
    try params.put(allocator, "message", .{ .string = "Apply?" });
    defer params.deinit(allocator);
    const unsupported = try server.requestClientProtocol(std.testing.io, allocator, .{
        .feature = .elicitation,
        .method = "elicitation/create",
        .params = .{ .object = params },
    });
    try std.testing.expect(!unsupported.supported);
    try std.testing.expectEqual(app_ports.ProtocolResponseStatus.unsupported, unsupported.status);

    server.client_capabilities = .{ .sampling = .{ .context = .{} } };
    const messages = [_][]const u8{};
    var transport = ScriptTransport{ .messages = &messages };
    defer transport.deinit(allocator);
    server.transport = transport.transport();
    var sampling_params = std.json.ObjectMap.empty;
    try sampling_params.put(allocator, "maxTokens", .{ .integer = 8 });
    defer sampling_params.deinit(allocator);
    const timeout = try server.requestClientProtocol(std.testing.io, allocator, .{
        .feature = .sampling,
        .method = "sampling/createMessage",
        .params = .{ .object = sampling_params },
    });
    try std.testing.expect(timeout.supported);
    try std.testing.expect(!timeout.used);
    try std.testing.expectEqual(app_ports.ProtocolResponseStatus.timeout, timeout.status);
    try std.testing.expectEqual(@as(usize, 0), server.pending_requests.count());
}

test "protocol response builders release response allocations" {
    const allocator = std.testing.allocator;

    var server: Server = .init(allocator, .{
        .name = "leak-check-server",
        .version = "1.0.0",
        .title = "Leak Check",
        .description = "Fixture server",
        .websiteUrl = "https://example.test",
        .instructions = "Use fixture tools.",
    });
    defer server.deinit();
    server.enableLogging();
    server.enableCompletions();

    try server.addTool(.{
        .name = "ok_tool",
        .description = "A routed tool",
        .title = "OK Tool",
        .inputSchema = .{
            .@"$schema" = "https://json-schema.org/draft/2020-12/schema",
            .description = "Tool input",
            .required = &.{"flag"},
        },
        .execution = .{ .taskSupport = "optional" },
        .annotations = .{ .title = "Annotation", .readOnlyHint = true, .destructiveHint = false, .idempotentHint = true, .openWorldHint = false },
        .handler = okToolHandler,
    });
    try server.addResource(.{
        .uri = "file:///resource",
        .name = "Resource",
        .title = "Resource Title",
        .description = "Resource description",
        .mimeType = "text/plain",
        .size = 12,
        .handler = testResourceHandler,
    });
    try server.addResourceTemplate(.{
        .uriTemplate = "file:///{name}",
        .name = "Template",
        .title = "Template Title",
        .description = "Template description",
        .mimeType = "text/plain",
    });
    try server.addPrompt(.{
        .name = "prompt",
        .title = "Prompt Title",
        .description = "Prompt description",
        .arguments = &.{.{ .name = "topic", .title = "Topic", .description = "Prompt topic", .required = true }},
        .handler = testPromptHandler,
    });

    const messages = [_][]const u8{
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-11-25\",\"clientInfo\":{\"name\":\"tester\",\"version\":\"1\"}}}",
        "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}",
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"ping\"}",
        "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/list\"}",
        "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"resources/list\"}",
        "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"resources/templates/list\"}",
        "{\"jsonrpc\":\"2.0\",\"id\":6,\"method\":\"resources/subscribe\",\"params\":{\"uri\":\"file:///resource\"}}",
        "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"resources/unsubscribe\",\"params\":{\"uri\":\"file:///resource\"}}",
        "{\"jsonrpc\":\"2.0\",\"id\":8,\"method\":\"prompts/list\"}",
        "{\"jsonrpc\":\"2.0\",\"id\":9,\"method\":\"logging/setLevel\",\"params\":{\"level\":\"debug\"}}",
        "{\"jsonrpc\":\"2.0\",\"id\":10,\"method\":\"completion/complete\",\"params\":{}}",
        "{\"jsonrpc\":\"2.0\",\"id\":12,\"method\":\"tools/list\"}",
        "{\"jsonrpc\":\"2.0\",\"id\":13,\"method\":\"prompts/list\"}",
    };
    var transport: ScriptTransport = .{ .messages = messages[0..] };
    defer transport.deinit(allocator);

    try server.runWithTransport(std.testing.io, allocator, transport.transport());
    try server.sendLogMessage(std.testing.io, allocator, .info, "info log");
    try server.sendProgress(std.testing.io, allocator, .{ .string = "tok" }, 0.5, 1.0, "half");
    try server.notifyResourceUpdated(std.testing.io, allocator, "file:///resource");

    const sent = try joinedSent(allocator, &transport);
    defer allocator.free(sent);
    try std.testing.expect(std.mem.indexOf(u8, sent, "\"tools\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, sent, "\"resourceTemplates\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, sent, "\"prompts\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, sent, "notifications/resources/updated") != null);
}
