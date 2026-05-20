const std = @import("std");
const mcp = @import("mcp");

const server_mod = @import("mcp_server.zig");

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
};

const ScriptTransport = struct {
    messages: []const []const u8,
    index: usize = 0,
    sent: std.ArrayList([]const u8) = .empty,

    fn deinit(self: *ScriptTransport, allocator: std.mem.Allocator) void {
        for (self.sent.items) |message| allocator.free(message);
        self.sent.deinit(allocator);
    }

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

    fn sendVtable(ptr: *anyopaque, _: std.Io, allocator: std.mem.Allocator, message: []const u8) mcp.transport.Transport.SendError!void {
        const self: *ScriptTransport = @ptrCast(@alignCast(ptr));
        const owned = allocator.dupe(u8, message) catch return error.OutOfMemory;
        self.sent.append(allocator, owned) catch {
            allocator.free(owned);
            return error.OutOfMemory;
        };
    }

    fn receiveVtable(ptr: *anyopaque, _: std.Io, _: std.mem.Allocator) mcp.transport.Transport.ReceiveError!?[]const u8 {
        const self: *ScriptTransport = @ptrCast(@alignCast(ptr));
        if (self.index >= self.messages.len) return error.EndOfStream;
        const message = self.messages[self.index];
        self.index += 1;
        return message;
    }

    fn closeVtable(_: *anyopaque) void {}
};

fn joinedSent(allocator: std.mem.Allocator, transport: *ScriptTransport) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (transport.sent.items) |message| {
        try out.appendSlice(allocator, message);
        try out.append(allocator, '\n');
    }
    return out.toOwnedSlice(allocator);
}

fn okToolHandler(_: ?*anyopaque, _: std.Io, _: std.mem.Allocator, _: ?std.json.Value) !mcp.tools.ToolResult {
    return .{
        .content = fixture_tool_content[0..],
        .structuredContent = .{ .bool = true },
    };
}

fn failToolHandler(_: ?*anyopaque, _: std.Io, _: std.mem.Allocator, _: ?std.json.Value) !mcp.tools.ToolResult {
    return error.ExecutionFailed;
}

fn testResourceHandler(_: ?*anyopaque, _: std.Io, _: std.mem.Allocator, uri: []const u8) !mcp.resources.ResourceContent {
    return .{
        .uri = uri,
        .text = "resource text",
        .blob = "cmVzb3VyY2U=",
        .mimeType = "text/plain",
    };
}

fn testPromptHandler(_: ?*anyopaque, _: std.Io, _: std.mem.Allocator, _: ?std.json.Value) ![]const mcp.prompts.PromptMessage {
    return fixture_prompt_messages[0..];
}

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
        .handler = struct {
            fn handler(_: ?*anyopaque, _: std.Io, _: std.mem.Allocator, _: ?std.json.Value) !mcp.tools.ToolResult {
                return .{ .content = &.{} };
            }
        }.handler,
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

    try server.addResource(.{
        .uri = "file:///test",
        .name = "Test",
        .handler = struct {
            fn handler(_: ?*anyopaque, _: std.Io, _: std.mem.Allocator, uri: []const u8) !mcp.resources.ResourceContent {
                return .{ .uri = uri };
            }
        }.handler,
    });
    try std.testing.expect(server.resources.contains("file:///test"));
    try std.testing.expect(server.capabilities.resources != null);
}

test "Server add prompt" {
    var server: Server = .init(std.testing.allocator, .{
        .name = "test-server",
        .version = "1.0.0",
    });
    defer server.deinit();

    try server.addPrompt(.{
        .name = "test_prompt",
        .description = "A test prompt",
        .handler = struct {
            fn handler(_: ?*anyopaque, _: std.Io, _: std.mem.Allocator, _: ?std.json.Value) ![]const mcp.prompts.PromptMessage {
                return &.{};
            }
        }.handler,
    });
    try std.testing.expect(server.prompts.contains("test_prompt"));
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
    server.enableTasks();

    try std.testing.expect(server.capabilities.logging != null);
    try std.testing.expect(server.capabilities.completions != null);
    try std.testing.expect(server.capabilities.tasks != null);
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
    server.enableTasks();

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
        .execution = .{ .taskSupport = "optional" },
        .annotations = .{ .title = "Annotation", .readOnlyHint = true, .destructiveHint = false, .idempotentHint = true, .openWorldHint = false },
        .handler = okToolHandler,
    });
    try server.addTool(.{
        .name = "fail_tool",
        .description = "A failing tool",
        .handler = failToolHandler,
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
        "{\"jsonrpc\":\"2.0\",\"id\":18,\"method\":\"tasks/list\"}",
        "{\"jsonrpc\":\"2.0\",\"id\":19,\"method\":\"tasks/get\"}",
        "{\"jsonrpc\":\"2.0\",\"id\":20,\"method\":\"tasks/result\"}",
        "{\"jsonrpc\":\"2.0\",\"id\":21,\"method\":\"tasks/cancel\"}",
        "{\"jsonrpc\":\"2.0\",\"id\":22,\"method\":\"unknown/method\"}",
        "{\"jsonrpc\":\"2.0\",\"id\":23,\"result\":{}}",
        "{\"jsonrpc\":\"2.0\",\"id\":24,\"error\":{\"code\":-32603,\"message\":\"client error\"}}",
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
    try std.testing.expect(transport.sent.items.len >= 27);
    try std.testing.expect(std.mem.indexOf(u8, sent, "Server not initialized") != null);
    try std.testing.expect(std.mem.indexOf(u8, sent, "\"serverInfo\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, sent, "\"tools\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, sent, "\"structuredContent\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, sent, "\"resource_link\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, sent, "ExecutionFailed") != null);
    try std.testing.expect(std.mem.indexOf(u8, sent, "Tool not found") != null);
    try std.testing.expect(std.mem.indexOf(u8, sent, "\"resources\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, sent, "\"resourceTemplates\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, sent, "\"prompts\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, sent, "\"completion\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, sent, "\"tasks\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, sent, "Method not found") != null);
    try std.testing.expect(std.mem.indexOf(u8, sent, "notifications/tools/list_changed") != null);
    try std.testing.expect(std.mem.indexOf(u8, sent, "notifications/resources/updated") != null);
    try std.testing.expect(std.mem.indexOf(u8, sent, "notifications/prompts/list_changed") != null);
}
