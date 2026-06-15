//! Integration tests for the MCP server adapter: JSON-RPC routing, capability
//! negotiation, tool/resource/prompt registration, error-contract invariants,
//! and structured-content projection.
//! Key invariants pinned here: raw Zig error names (e.g. ExecutionFailed,
//! ReadFailed) must never appear in client-visible output; discovery lists
//! preserve insertion order; and repeated initialize is rejected.

const std = @import("std");
const mcp = @import("mcp");
const server_mod = @import("../../adapters/mcp/server.zig");
const manifest = @import("../../manifest/mod.zig");
const tool_registry = @import("../../adapters/mcp/registry.zig");
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

const ScriptTransport = struct {
    messages: []const []const u8,
    index: usize = 0,
    sent: std.ArrayList([]const u8) = .empty,

    fn deinit(self: *ScriptTransport, allocator: std.mem.Allocator) void {
        for (self.sent.items) |message| allocator.free(message);
        self.sent.deinit(allocator);
    }

    fn transport(self: *ScriptTransport) mcp.transport.Transport {
        // Keep this logic centralized so callers observe one consistent behavior path.
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

test "script transport frees messages when recording send fails" {
    var transport = ScriptTransport{ .messages = &.{} };
    defer transport.deinit(std.testing.allocator);
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 1 });
    try std.testing.expectError(error.OutOfMemory, transport.transport().send(std.testing.io, failing.allocator(), "message"));
    transport.transport().close();
}

fn joinedSent(allocator: std.mem.Allocator, transport: *ScriptTransport) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (transport.sent.items) |message| {
        try out.appendSlice(allocator, message);
        try out.append(allocator, '\n');
    }
    return out.toOwnedSlice(allocator);
}

// Verifies that first appears before second in the joined sent output.
// Used to assert registration-order preservation in discovery list tests.
fn expectBefore(haystack: []const u8, first: []const u8, second: []const u8) !void {
    const first_index = std.mem.indexOf(u8, haystack, first) orelse return error.TestExpectedEqual;
    const second_index = std.mem.indexOf(u8, haystack, second) orelse return error.TestExpectedEqual;
    try std.testing.expect(first_index < second_index);
}

fn okToolHandler(_: ?*anyopaque, _: *Server, _: std.Io, _: std.mem.Allocator, _: ?std.json.Value) !mcp.tools.ToolResult {
    return .{
        .content = fixture_tool_content[0..],
        .structuredContent = .{ .bool = true },
    };
}

fn failToolHandler(_: ?*anyopaque, _: *Server, _: std.Io, _: std.mem.Allocator, _: ?std.json.Value) !mcp.tools.ToolResult {
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

fn failResourceHandler(_: ?*anyopaque, _: std.Io, _: std.mem.Allocator, _: []const u8) !mcp.resources.ResourceContent {
    return error.ReadFailed;
}

fn dynamicResourceHandler(_: ?*anyopaque, _: std.Io, _: std.mem.Allocator, uri: []const u8) !mcp.resources.ResourceContent {
    return .{
        .uri = uri,
        .text = "dynamic text",
        .blob = "ZHluYW1pYw==",
        .mimeType = "text/plain",
    };
}

fn failDynamicResourceHandler(_: ?*anyopaque, _: std.Io, _: std.mem.Allocator, _: []const u8) !mcp.resources.ResourceContent {
    return error.ReadFailed;
}

fn noopResourceDeinit(_: std.mem.Allocator, _: mcp.resources.ResourceContent) void {}

fn testPromptHandler(_: ?*anyopaque, _: std.Io, _: std.mem.Allocator, _: ?std.json.Value) ![]const mcp.prompts.PromptMessage {
    return fixture_prompt_messages[0..];
}

fn failPromptHandler(_: ?*anyopaque, _: std.Io, _: std.mem.Allocator, _: ?std.json.Value) ![]const mcp.prompts.PromptMessage {
    return error.GenerationFailed;
}

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

test "registered tool validation errors include correlation metadata" {
    const allocator = std.testing.allocator;
    var server: Server = .init(allocator, .{
        .name = "test-server",
        .version = "1.0.0",
    });
    defer server.deinit();
    server.state = .ready;

    const TestRuntime = struct {
        calls: usize = 0,
        records: usize = 0,
        last_error: bool = false,
        last_has_correlation: bool = false,
    };
    const TestHandler = struct {
        fn handler(runtime: *TestRuntime, _: std.mem.Allocator, _: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
            runtime.calls += 1;
            return .{ .content = &.{.{ .text = .{ .text = "unexpected" } }} };
        }

        fn record(runtime: *TestRuntime, _: []const u8, _: u64, is_error: bool, correlation: anytype) void {
            runtime.records += 1;
            runtime.last_error = is_error;
            runtime.last_has_correlation = correlation != null;
        }
    };

    var runtime = TestRuntime{};
    try tool_registry.addTool(
        &server,
        allocator,
        &runtime,
        manifest.entryFor(.zig_check).meta,
        TestHandler.handler,
        TestHandler.record,
    );

    const messages = [_][]const u8{
        "{\"jsonrpc\":\"2.0\",\"id\":\"req-validation\",\"method\":\"tools/call\",\"params\":{\"name\":\"zig_check\",\"arguments\":{}}}",
    };
    var transport: ScriptTransport = .{ .messages = messages[0..] };
    defer transport.deinit(allocator);

    try server.runWithTransport(std.testing.io, allocator, transport.transport());
    try std.testing.expectEqual(@as(usize, 1), transport.sent.items.len);
    try std.testing.expectEqual(@as(usize, 0), runtime.calls);
    try std.testing.expectEqual(@as(usize, 1), runtime.records);
    try std.testing.expect(runtime.last_error);
    try std.testing.expect(runtime.last_has_correlation);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, transport.sent.items[0], .{});
    defer parsed.deinit();

    const result = parsed.value.object.get("result").?.object;
    try std.testing.expect(result.get("isError").?.bool);
    const structured = result.get("structuredContent").?.object;
    try std.testing.expectEqualStrings("argument_error", structured.get("kind").?.string);
    try std.testing.expectEqualStrings("missing_required_argument", structured.get("code").?.string);
    try std.testing.expectEqualStrings("file", structured.get("field").?.string);

    const corr = result.get("_meta").?.object.get("dev.zigars/correlation").?.object;
    try std.testing.expectEqualStrings("tools/call", corr.get("mcp_method").?.string);
    try std.testing.expectEqualStrings("zig_check", corr.get("tool_name").?.string);
    const request_id = corr.get("mcp_request_id").?.object;
    try std.testing.expectEqualStrings("string", request_id.get("type").?.string);
    try std.testing.expectEqualStrings("req-validation", request_id.get("value").?.string);
}

test "Server deinit frees registry-owned tool schemas" {
    const allocator = std.testing.allocator;
    var server: Server = .init(allocator, .{
        .name = "schema-owner-server",
        .version = "1.0.0",
    });
    defer server.deinit();

    const TestRuntime = struct { calls: usize = 0 };
    const TestHandler = struct {
        fn handler(runtime: *TestRuntime, _: std.mem.Allocator, _: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
            runtime.calls += 1;
            return .{ .content = &.{.{ .text = .{ .text = "ok" } }} };
        }

        fn record(_: *TestRuntime, _: []const u8, _: u64, _: bool, _: anytype) void {}
    };
    var runtime = TestRuntime{};

    // Together these specs exercise every schema allocation kind the registry
    // produces: required input fields plus an outputSchema with its own
    // required slice (regression gate), and an enum-hint array nested inside a
    // property map (compile error index). std.testing.allocator fails this
    // test if Server.deinit stops releasing any of them.
    try tool_registry.addTool(
        &server,
        allocator,
        &runtime,
        manifest.entryFor(.zig_bench_regression_gate).meta,
        TestHandler.handler,
        TestHandler.record,
    );
    try tool_registry.addTool(
        &server,
        allocator,
        &runtime,
        manifest.entryFor(.zig_compile_error_index).meta,
        TestHandler.handler,
        TestHandler.record,
    );

    const gate_tool = server.tools.get("zig_bench_regression_gate").?;
    try std.testing.expect(gate_tool.schema_allocator != null);
    try std.testing.expect(gate_tool.inputSchema.?.required != null);
    try std.testing.expect(gate_tool.outputSchema.?.required != null);

    // The registry derives Tool.cancellable from manifest risk: a backend/
    // project-code executor is worker-dispatched (cancellable); an artifact-only
    // gate is not.
    try std.testing.expect(server.tools.get("zig_compile_error_index").?.cancellable);
    try std.testing.expect(!gate_tool.cancellable);
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
    try std.testing.expect(std.mem.indexOf(u8, sent, "\"_meta\":{\"dev.zigars/correlation\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, sent, "\"resource_link\"") != null);
    // LOW-1 regression guard: the tool-handler `anyerror` fallback must NOT leak
    // the raw Zig `@errorName` (here `ExecutionFailed`) into client-visible
    // content or structuredContent. Only the coarsened `error_kind` and the safe
    // coarsened content text are exposed; `@errorName` stays in stderr only.
    try std.testing.expect(std.mem.indexOf(u8, sent, "ExecutionFailed") == null);
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

test "Server rejects repeated initialize requests without leaving ready state" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var server: Server = .init(allocator, .{
        .name = "repeat-init-server",
        .version = "1.0.0",
    });
    defer server.deinit();

    const messages = [_][]const u8{
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-11-25\",\"clientInfo\":{\"name\":\"tester\",\"version\":\"1\"}}}",
        "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}",
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-11-25\",\"clientInfo\":{\"name\":\"intruder\",\"version\":\"2\"}}}",
        "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"ping\"}",
    };
    var transport: ScriptTransport = .{ .messages = messages[0..] };
    defer transport.deinit(allocator);

    try server.runWithTransport(std.testing.io, allocator, transport.transport());

    const sent = try joinedSent(allocator, &transport);
    try std.testing.expect(std.mem.indexOf(u8, sent, "\"serverInfo\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, sent, "\"id\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, sent, "Server already initialized") != null);
    try std.testing.expect(std.mem.indexOf(u8, sent, "\"id\":3") != null);
    try std.testing.expect(std.mem.indexOf(u8, sent, "\"result\":{}") != null);
}

test "Server rejects malformed list cursors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var server: Server = .init(allocator, .{
        .name = "cursor-server",
        .version = "1.0.0",
    });
    defer server.deinit();

    const messages = [_][]const u8{
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-11-25\",\"clientInfo\":{\"name\":\"tester\",\"version\":\"1\"}}}",
        "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}",
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\",\"params\":{\"cursor\":\"-1\"}}",
    };
    var transport: ScriptTransport = .{ .messages = messages[0..] };
    defer transport.deinit(allocator);

    try server.runWithTransport(std.testing.io, allocator, transport.transport());

    const sent = try joinedSent(allocator, &transport);
    try std.testing.expect(std.mem.indexOf(u8, sent, "\"id\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, sent, "Pagination cursor must be a non-negative decimal offset") != null);
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
    try std.testing.expect(std.mem.indexOf(u8, sent, "unexpected_prompt_handler_error") != null);
    try std.testing.expect(std.mem.indexOf(u8, sent, "\"prompt\":\"fails\"") != null);
    // LOW-1 regression guard: the resource- and prompt-handler `anyerror`
    // fallbacks must not leak the raw Zig `@errorName` (`ReadFailed`,
    // `GenerationFailed`) into client-visible structuredContent. Only the
    // coarsened `error_kind` survives; both coarsen to `execution_failed`.
    try std.testing.expect(std.mem.indexOf(u8, sent, "ReadFailed") == null);
    try std.testing.expect(std.mem.indexOf(u8, sent, "GenerationFailed") == null);
    try std.testing.expect(std.mem.indexOf(u8, sent, "\"error_kind\":\"execution_failed\"") != null);
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
