const std = @import("std");
const mcp = @import("mcp");

const app_context = @import("../../../app/context.zig");
const ports = @import("../../../app/ports.zig");
const editing_workflows = @import("../../../app/usecases/editing/workflows.zig");
const code_intel = @import("../../../app/usecases/zls/code_intel.zig");
const zls_workflows = @import("../../../app/usecases/zls/workflows.zig");
const core_adapter = @import("core.zig");
const static_source_adapter = @import("static_source_summary.zig");
const mcp_errors = @import("../errors.zig");
const mcp_result = @import("../result.zig");

pub fn zigFormat(allocator: std.mem.Allocator, context: app_context.Context, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const file = argString(args, "file") orelse return mcp_errors.missingArgument(allocator, "zig_format", "file", "string");
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const value = editing_workflows.formatValue(scratch, context.coreCommands() catch |err| return contextError(allocator, "zig_format", "editing_format_context", err), file, argBool(args, "apply", false), toolTimeout(context, args)) catch |err| return formatError(allocator, file, err);
    return mcp_result.structured(allocator, value);
}

pub fn zigFormatCheck(allocator: std.mem.Allocator, context: app_context.Context, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const path = argString(args, "path") orelse return mcp_errors.missingArgument(allocator, "zig_format_check", "path", "string");
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const value = editing_workflows.formatCheckValue(scratch, context.coreCommands() catch |err| return contextError(allocator, "zig_format_check", "editing_format_context", err), path, toolTimeout(context, args)) catch |err| return workflowError(allocator, "zig_format_check", "format_check", path, err);
    return mcp_result.structured(allocator, value);
}

pub fn zigPatchPreview(allocator: std.mem.Allocator, context: app_context.Context, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const file = argString(args, "file") orelse return mcp_errors.missingArgument(allocator, "zig_patch_preview", "file", "string");
    const content = argString(args, "content") orelse return mcp_errors.missingArgument(allocator, "zig_patch_preview", "content", "string");
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const value = editing_workflows.patchPreviewValue(scratch, context.coreCommands() catch |err| return contextError(allocator, "zig_patch_preview", "editing_patch_context", err), file, content, argBool(args, "apply", false)) catch |err| return workflowError(allocator, "zig_patch_preview", "patch_preview", file, err);
    return mcp_result.structured(allocator, value);
}

pub fn zigDocumentOpen(allocator: std.mem.Allocator, context: app_context.Context, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return documentSync(allocator, context, args, "zig_document_open");
}

pub fn zigDocumentClose(allocator: std.mem.Allocator, _: app_context.Context, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const file = argString(args, "file") orelse return mcp_errors.missingArgument(allocator, "zig_document_close", "file", "string");
    var obj = std.json.ObjectMap.empty;
    defer obj.deinit(allocator);
    try obj.put(allocator, "file", .{ .string = file });
    try obj.put(allocator, "open", .{ .bool = false });
    try obj.put(allocator, "note", .{ .string = "Document close is a no-op when routed through the typed ZLS gateway; subsequent requests resync the document as needed." });
    return mcp_result.structured(allocator, .{ .object = obj });
}

pub fn zigDocumentStatus(allocator: std.mem.Allocator, context: app_context.Context, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const file = argString(args, "file") orelse return mcp_errors.missingArgument(allocator, "zig_document_status", "file", "string");
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const value = zls_workflows.documentStatusValue(scratch, context, file) catch |err| return workflowError(allocator, "zig_document_status", "document_status", file, err);
    return mcp_result.structured(allocator, value);
}

pub fn zigHover(allocator: std.mem.Allocator, context: app_context.Context, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return positionTool(allocator, context, args, "zig_hover", "textDocument/hover");
}

pub fn zigDefinition(allocator: std.mem.Allocator, context: app_context.Context, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return positionTool(allocator, context, args, "zig_definition", "textDocument/definition");
}

pub fn zigReferences(allocator: std.mem.Allocator, context: app_context.Context, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return positionTool(allocator, context, args, "zig_references", "textDocument/references");
}

pub fn zigCompletion(allocator: std.mem.Allocator, context: app_context.Context, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return positionTool(allocator, context, args, "zig_completion", "textDocument/completion");
}

pub fn zigSignatureHelp(allocator: std.mem.Allocator, context: app_context.Context, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return positionTool(allocator, context, args, "zig_signature_help", "textDocument/signatureHelp");
}

pub fn zigDocumentSymbols(allocator: std.mem.Allocator, context: app_context.Context, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const result = fileOnlyTool(allocator, context, args, "zig_document_symbols", "textDocument/documentSymbol");
    return result catch static_source_adapter.zigDeclSummary(allocator, context.staticAnalysis() catch |err| return contextError(allocator, "zig_document_symbols", "static_analysis_context", err), args);
}

pub fn zigWorkspaceSymbols(allocator: std.mem.Allocator, context: app_context.Context, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const query = argString(args, "query") orelse return mcp_errors.missingArgument(allocator, "zig_workspace_symbols", "query", "string");
    const zls_ctx = context.zls() catch |err| return contextError(allocator, "zig_workspace_symbols", "zls_context", err);
    var outcome = code_intel.workspaceSymbols(allocator, zls_ctx, .{ .query = query }) catch return error.OutOfMemory;
    defer outcome.deinit(allocator);
    return switch (outcome) {
        .ok => |response| lspStructuredTool(allocator, response.method, response.payload),
        .err => |failure| zlsFailureResult(allocator, context, "zig_workspace_symbols", "workspace/symbol", null, failure),
    };
}

pub fn zigCodeActions(allocator: std.mem.Allocator, context: app_context.Context, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return positionTool(allocator, context, args, "zig_code_actions", "textDocument/codeAction");
}

pub fn zigCodeActionApply(allocator: std.mem.Allocator, context: app_context.Context, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return zigCodeActions(allocator, context, args);
}

pub fn zigRename(allocator: std.mem.Allocator, context: app_context.Context, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    if (argString(args, "new_name") == null) return mcp_errors.missingArgument(allocator, "zig_rename", "new_name", "string");
    return positionTool(allocator, context, args, "zig_rename", "textDocument/rename");
}

pub fn zigDiagnostics(allocator: std.mem.Allocator, context: app_context.Context, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    _ = argString(args, "file") orelse return mcp_errors.missingArgument(allocator, "zig_diagnostics", "file", "string");
    const zls_result = fileOnlyTool(allocator, context, args, "zig_diagnostics", "textDocument/diagnostic");
    return zls_result catch core_adapter.zigCheck(allocator, context.coreCommands() catch |err| return contextError(allocator, "zig_diagnostics", "core_context", err), args);
}

pub fn zigDiagnosticsAll(allocator: std.mem.Allocator, context: app_context.Context, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return zigDiagnostics(allocator, context, args);
}

pub fn zigDiagnosticsWorkspace(allocator: std.mem.Allocator, context: app_context.Context, _: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    if (!context.zls_state.running) return structuredText(allocator, "zig_diagnostics_workspace", "ZLS session is unavailable; no workspace diagnostics cache exists.");
    var obj = std.json.ObjectMap.empty;
    defer obj.deinit(allocator);
    try obj.put(allocator, "files", .{ .array = std.json.Array.init(allocator) });
    try obj.put(allocator, "total", .{ .integer = 0 });
    try obj.put(allocator, "errors", .{ .integer = 0 });
    try obj.put(allocator, "warnings", .{ .integer = 0 });
    try obj.put(allocator, "information", .{ .integer = 0 });
    try obj.put(allocator, "hints", .{ .integer = 0 });
    try obj.put(allocator, "malformed_notifications", .{ .integer = 0 });
    return mcp_result.structured(allocator, .{ .object = obj });
}

fn documentSync(allocator: std.mem.Allocator, context: app_context.Context, args: ?std.json.Value, tool_name: []const u8) mcp.tools.ToolError!mcp.tools.ToolResult {
    const file = argString(args, "file") orelse return mcp_errors.missingArgument(allocator, tool_name, "file", "string");
    const content = argString(args, "content") orelse return mcp_errors.missingArgument(allocator, tool_name, "content", "string");
    const zls_ctx = context.zls() catch |err| return contextError(allocator, tool_name, "zls_context", err);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const value = zls_workflows.documentSyncValue(scratch, zls_ctx, tool_name, file, content) catch |err| return zlsPortError(allocator, context, tool_name, "textDocument/didOpen", file, err);
    return mcp_result.structured(allocator, value);
}

fn positionTool(allocator: std.mem.Allocator, context: app_context.Context, args: ?std.json.Value, tool_name: []const u8, method: []const u8) mcp.tools.ToolError!mcp.tools.ToolResult {
    const zls_ctx = context.zls() catch |err| return contextError(allocator, tool_name, "zls_context", err);
    var outcome = code_intel.position(allocator, zls_ctx, .{
        .method = method,
        .file = argString(args, "file"),
        .content = argString(args, "content"),
        .line = argInt(args, "line", 0),
        .character = argInt(args, "character", 0),
        .include_declaration = argBool(args, "include_declaration", true),
    }) catch return error.OutOfMemory;
    defer outcome.deinit(allocator);
    return switch (outcome) {
        .ok => |response| lspStructuredTool(allocator, response.method, response.payload),
        .err => |failure| zlsFailureResult(allocator, context, tool_name, method, argString(args, "file"), failure),
    };
}

fn fileOnlyTool(allocator: std.mem.Allocator, context: app_context.Context, args: ?std.json.Value, tool_name: []const u8, method: []const u8) mcp.tools.ToolError!mcp.tools.ToolResult {
    const zls_ctx = context.zls() catch |err| return contextError(allocator, tool_name, "zls_context", err);
    var outcome = code_intel.fileOnly(allocator, zls_ctx, .{
        .method = method,
        .file = argString(args, "file"),
        .content = argString(args, "content"),
    }) catch return error.OutOfMemory;
    defer outcome.deinit(allocator);
    return switch (outcome) {
        .ok => |response| lspStructuredTool(allocator, response.method, response.payload),
        .err => |failure| zlsFailureResult(allocator, context, tool_name, method, argString(args, "file"), failure),
    };
}

fn zlsFailureResult(allocator: std.mem.Allocator, context: app_context.Context, tool_name: []const u8, method: []const u8, file: ?[]const u8, failure: code_intel.Failure) mcp.tools.ToolError!mcp.tools.ToolResult {
    return switch (failure) {
        .unavailable => zlsUnavailable(allocator, context),
        .unsupported_capability => |capability| unsupportedCapability(allocator, method, capability),
        .missing_file => mcp_errors.missingArgument(allocator, tool_name, "file", "string"),
        .sync_failed => |port_failure| zlsPortError(allocator, context, tool_name, method, file orelse port_failure.file orelse "", port_failure.err),
        .request_failed => |port_failure| zlsPortError(allocator, context, tool_name, method, file orelse port_failure.file orelse "", port_failure.err),
    };
}

fn zlsPortError(allocator: std.mem.Allocator, context: app_context.Context, tool_name: []const u8, method: []const u8, file: []const u8, err: anyerror) mcp.tools.ToolError!mcp.tools.ToolResult {
    if (err == error.Unavailable) return zlsUnavailable(allocator, context);
    if (err == error.PathOutsideWorkspace or err == error.EmptyPath or err == error.DocumentTooLarge or err == error.OpenDocumentLimitExceeded or err == error.RetainedContentLimitExceeded) {
        return mcp_errors.workspacePath(allocator, tool_name, file, context.workspace.root, err);
    }
    return mcp_errors.fromError(allocator, .{
        .tool = tool_name,
        .operation = method,
        .phase = "zls_gateway",
        .code = "zls_request_failed",
        .category = "zls",
        .resolution = "Check the ZLS session status and retry; command-backed Zig tools remain available without ZLS.",
    }, err);
}

fn lspStructuredTool(allocator: std.mem.Allocator, method: []const u8, response: []const u8) mcp.tools.ToolError!mcp.tools.ToolResult {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, response, .{}) catch |err| return mcp_errors.fromError(allocator, .{
        .tool = method,
        .operation = method,
        .phase = "parse_response",
        .code = "malformed_backend_response",
        .category = "lsp",
        .resolution = "Retry after checking the ZLS session; the backend response could not be parsed as structured JSON.",
    }, err);
    defer parsed.deinit();
    var obj = std.json.ObjectMap.empty;
    defer obj.deinit(allocator);
    try obj.put(allocator, "method", .{ .string = method });
    const response_obj = switch (parsed.value) {
        .object => |object| object,
        else => {
            try obj.put(allocator, "ok", .{ .bool = false });
            try obj.put(allocator, "raw", parsed.value);
            return mcp_result.structured(allocator, .{ .object = obj });
        },
    };
    if (response_obj.get("error")) |err_value| {
        try obj.put(allocator, "ok", .{ .bool = false });
        try obj.put(allocator, "error", err_value);
    } else {
        try obj.put(allocator, "ok", .{ .bool = true });
        try obj.put(allocator, "result", response_obj.get("result") orelse .null);
    }
    return mcp_result.structured(allocator, .{ .object = obj });
}

fn unsupportedCapability(allocator: std.mem.Allocator, method: []const u8, capability: []const u8) mcp.tools.ToolError!mcp.tools.ToolResult {
    var obj = std.json.ObjectMap.empty;
    defer obj.deinit(allocator);
    try obj.put(allocator, "ok", .{ .bool = false });
    try obj.put(allocator, "kind", .{ .string = "zls_unsupported_capability" });
    try obj.put(allocator, "backend", .{ .string = "zls" });
    try obj.put(allocator, "method", .{ .string = method });
    try obj.put(allocator, "capability", .{ .string = capability });
    try obj.put(allocator, "category", .{ .string = "lsp_capability" });
    try obj.put(allocator, "error", .{ .string = "ZLS did not advertise this capability" });
    try obj.put(allocator, "resolution", .{ .string = "Upgrade or reconfigure ZLS, or choose a tool that does not require this LSP capability." });
    return mcp_result.structured(allocator, .{ .object = obj });
}

fn zlsUnavailable(allocator: std.mem.Allocator, context: app_context.Context) mcp.tools.ToolError!mcp.tools.ToolResult {
    var obj = std.json.ObjectMap.empty;
    defer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "backend_error" });
    try obj.put(allocator, "ok", .{ .bool = false });
    try obj.put(allocator, "backend", .{ .string = "zls" });
    try obj.put(allocator, "operation", .{ .string = "lsp_session" });
    try obj.put(allocator, "error", .{ .string = "Unavailable" });
    try obj.put(allocator, "error_kind", .{ .string = "unavailable" });
    try obj.put(allocator, "configured_path", .{ .string = context.tool_paths.zls });
    try obj.put(allocator, "status", .{ .string = context.zls_state.status });
    try obj.put(allocator, "restart_attempts", .{ .integer = @intCast(context.zls_state.restart_attempts) });
    try obj.put(allocator, "last_failure", if (context.zls_state.last_failure) |failure| .{ .string = failure } else .null);
    try obj.put(allocator, "resolution", .{ .string = "confirm --zls-path points to a ZLS build compatible with the configured Zig version, then restart the MCP client" });
    return mcp_result.structured(allocator, .{ .object = obj });
}

fn structuredText(allocator: std.mem.Allocator, kind: []const u8, text: []const u8) mcp.tools.ToolError!mcp.tools.ToolResult {
    var obj = std.json.ObjectMap.empty;
    defer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = kind });
    try obj.put(allocator, "text", .{ .string = text });
    return mcp_result.structured(allocator, .{ .object = obj });
}

fn workflowError(allocator: std.mem.Allocator, tool_name: []const u8, operation: []const u8, path: []const u8, err: anyerror) mcp.tools.ToolError!mcp.tools.ToolResult {
    if (err == error.OutOfMemory) return error.OutOfMemory;
    if (err == error.PathOutsideWorkspace or err == error.EmptyPath) return mcp_errors.workspacePath(allocator, tool_name, path, "", err);
    return mcp_errors.fromError(allocator, .{
        .tool = tool_name,
        .operation = operation,
        .phase = "run_workflow",
        .code = "editing_workflow_failed",
        .category = "editing",
        .resolution = "Inspect the path, backend availability, and workspace permissions, then retry.",
    }, err);
}

fn formatError(allocator: std.mem.Allocator, file: []const u8, err: anyerror) mcp.tools.ToolError!mcp.tools.ToolResult {
    if (err == error.OutOfMemory) return error.OutOfMemory;
    if (err == error.PathOutsideWorkspace or err == error.EmptyPath) return mcp_errors.workspacePath(allocator, "zig_format", file, "", err);
    return mcp_errors.fromError(allocator, .{
        .tool = "zig_format",
        .operation = "format_preview",
        .phase = if (err == error.FileNotFound or err == error.NotFound) "read_source" else "run_workflow",
        .code = if (err == error.FileNotFound or err == error.NotFound) "read_failed" else "format_failed",
        .category = if (err == error.FileNotFound or err == error.NotFound) "filesystem" else "editing",
        .resolution = "Confirm the file exists inside the zigar workspace and retry.",
        .details = &.{.{ .key = "file", .value = .{ .string = file } }},
    }, err);
}

fn contextError(allocator: std.mem.Allocator, tool_name: []const u8, operation: []const u8, err: anyerror) mcp.tools.ToolError!mcp.tools.ToolResult {
    return mcp_errors.fromError(allocator, .{
        .tool = tool_name,
        .operation = operation,
        .phase = "build_app_context",
        .code = "app_context_unavailable",
        .category = "configuration",
        .resolution = "The migrated MCP handler requires typed app ports from the runtime bridge.",
    }, err);
}

fn toolTimeout(context: app_context.Context, args: ?std.json.Value) i64 {
    return @max(1, @min(argInt(args, "timeout_ms", context.timeouts.command_ms), 60 * 60 * 1000));
}

fn argString(args: ?std.json.Value, name: []const u8) ?[]const u8 {
    const obj = switch (args orelse return null) {
        .object => |o| o,
        else => return null,
    };
    return switch (obj.get(name) orelse .null) {
        .string => |s| s,
        else => null,
    };
}

fn argBool(args: ?std.json.Value, name: []const u8, default: bool) bool {
    const obj = switch (args orelse return default) {
        .object => |o| o,
        else => return default,
    };
    return switch (obj.get(name) orelse .null) {
        .bool => |b| b,
        else => default,
    };
}

fn argInt(args: ?std.json.Value, name: []const u8, default: i64) i64 {
    const obj = switch (args orelse return default) {
        .object => |o| o,
        else => return default,
    };
    return switch (obj.get(name) orelse .null) {
        .integer => |i| i,
        else => default,
    };
}

fn zlsAdapterTestContext(gateway: ports.ZlsGateway) app_context.Context {
    return .{
        .workspace = .{ .root = "/repo", .cache_root = "/repo/.zigar-cache", .transport = "test" },
        .tool_paths = .{ .zig = "zig", .zls = "zls-test" },
        .timeouts = .{ .command_ms = 1000, .zls_ms = 1000 },
        .zls_state = .{ .status = "connected", .running = true },
        .ports = .{ .zls_gateway = gateway },
    };
}

fn expectCapability(gateway: anytype, capability: []const u8, supported: bool) !void {
    try gateway.expectCapability(.{ .capability = capability }, .{
        .capability = capability,
        .supported = supported,
        .basis = "unit",
    });
}

test "zls MCP adapter exercises document workspace and position wrappers" {
    const fakes = @import("../../../testing/fakes/root.zig");
    const allocator = std.testing.allocator;
    var gateway = fakes.FakeZlsGateway.init(allocator);
    defer gateway.deinit();
    const context = zlsAdapterTestContext(gateway.port());

    try gateway.expectSync(.{
        .file = "src/main.zig",
        .content = "pub fn main() void {}",
        .provenance = "zig_document_open",
    }, .{ .uri = "file:///repo/src/main.zig", .basis = "content" });
    const open_args = try std.json.parseFromSlice(std.json.Value, allocator, "{\"file\":\"src/main.zig\",\"content\":\"pub fn main() void {}\"}", .{});
    defer open_args.deinit();
    const opened = try zigDocumentOpen(allocator, context, open_args.value);
    defer mcp_result.deinitToolResult(allocator, opened);
    try std.testing.expect(opened.structuredContent.?.object.get("open").?.bool);

    try expectCapability(&gateway, "documentSymbolProvider", true);
    try gateway.expectSync(.{
        .file = "src/main.zig",
        .content = null,
        .provenance = code_intel.provenance,
    }, .{ .uri = "file:///repo/src/main.zig", .basis = "workspace" });
    try gateway.expectRequest(.{
        .method = "textDocument/documentSymbol",
        .uri = "file:///repo/src/main.zig",
        .payload = "{\"textDocument\":{\"uri\":\"file:///repo/src/main.zig\"}}",
    }, .{ .method = "textDocument/documentSymbol", .payload = "{\"result\":[{\"name\":\"main\"}]}" });
    const file_args = try std.json.parseFromSlice(std.json.Value, allocator, "{\"file\":\"src/main.zig\"}", .{});
    defer file_args.deinit();
    const symbols = try zigDocumentSymbols(allocator, context, file_args.value);
    defer mcp_result.deinitToolResult(allocator, symbols);
    try std.testing.expect(symbols.structuredContent.?.object.get("ok").?.bool);

    try expectCapability(&gateway, "workspaceSymbolProvider", true);
    try gateway.expectRequest(.{
        .method = "workspace/symbol",
        .payload = "{\"query\":\"main\"}",
    }, .{ .method = "workspace/symbol", .payload = "{\"result\":[]}" });
    const workspace_args = try std.json.parseFromSlice(std.json.Value, allocator, "{\"query\":\"main\"}", .{});
    defer workspace_args.deinit();
    const workspace_symbols = try zigWorkspaceSymbols(allocator, context, workspace_args.value);
    defer mcp_result.deinitToolResult(allocator, workspace_symbols);
    try std.testing.expect(workspace_symbols.structuredContent.?.object.get("ok").?.bool);

    try expectCapability(&gateway, "hoverProvider", true);
    try gateway.expectSync(.{
        .file = "src/main.zig",
        .content = null,
        .provenance = code_intel.provenance,
    }, .{ .uri = "file:///repo/src/main.zig", .basis = "workspace" });
    try gateway.expectRequest(.{
        .method = "textDocument/hover",
        .uri = "file:///repo/src/main.zig",
        .payload = "{\"textDocument\":{\"uri\":\"file:///repo/src/main.zig\"},\"position\":{\"line\":1,\"character\":2}}",
    }, .{ .method = "textDocument/hover", .payload = "{\"result\":{\"contents\":\"ok\"}}" });
    const hover_args = try std.json.parseFromSlice(std.json.Value, allocator, "{\"file\":\"src/main.zig\",\"line\":1,\"character\":2}", .{});
    defer hover_args.deinit();
    const hover = try zigHover(allocator, context, hover_args.value);
    defer mcp_result.deinitToolResult(allocator, hover);
    try std.testing.expect(hover.structuredContent.?.object.get("ok").?.bool);

    try expectCapability(&gateway, "hoverProvider", true);
    const missing_file = try zigHover(allocator, context, null);
    defer mcp_result.deinitToolResult(allocator, missing_file);
    try std.testing.expect(missing_file.is_error);

    try expectCapability(&gateway, "codeActionProvider", false);
    const code_actions = try zigCodeActionApply(allocator, context, hover_args.value);
    defer mcp_result.deinitToolResult(allocator, code_actions);
    try std.testing.expect(!code_actions.structuredContent.?.object.get("ok").?.bool);

    try gateway.verify();
}

test "zls MCP adapter maps failures malformed payloads and diagnostics summaries" {
    const fakes = @import("../../../testing/fakes/root.zig");
    const allocator = std.testing.allocator;
    var gateway = fakes.FakeZlsGateway.init(allocator);
    defer gateway.deinit();
    const context = zlsAdapterTestContext(gateway.port());

    try expectCapability(&gateway, "hoverProvider", true);
    try gateway.expectSync(.{
        .file = "src/main.zig",
        .content = null,
        .provenance = code_intel.provenance,
    }, .{ .uri = "file:///repo/src/main.zig", .basis = "workspace" });
    try gateway.expectRequestError(.{
        .method = "textDocument/hover",
        .uri = "file:///repo/src/main.zig",
        .payload = "{\"textDocument\":{\"uri\":\"file:///repo/src/main.zig\"},\"position\":{\"line\":0,\"character\":0}}",
    }, error.Timeout);
    const file_args = try std.json.parseFromSlice(std.json.Value, allocator, "{\"file\":\"src/main.zig\"}", .{});
    defer file_args.deinit();
    const timed_out = try zigHover(allocator, context, file_args.value);
    defer mcp_result.deinitToolResult(allocator, timed_out);
    try std.testing.expect(timed_out.is_error);

    try expectCapability(&gateway, "documentSymbolProvider", true);
    try gateway.expectSyncError(.{
        .file = "../escape.zig",
        .content = null,
        .provenance = code_intel.provenance,
    }, error.PathOutsideWorkspace);
    const escape_args = try std.json.parseFromSlice(std.json.Value, allocator, "{\"file\":\"../escape.zig\"}", .{});
    defer escape_args.deinit();
    const escaped = try zigDocumentSymbols(allocator, context, escape_args.value);
    defer mcp_result.deinitToolResult(allocator, escaped);
    try std.testing.expect(escaped.is_error);

    const diagnostics = try zigDiagnosticsWorkspace(allocator, context, null);
    defer mcp_result.deinitToolResult(allocator, diagnostics);
    try std.testing.expectEqual(@as(i64, 0), diagnostics.structuredContent.?.object.get("total").?.integer);

    const malformed = try lspStructuredTool(allocator, "textDocument/hover", "{not json");
    defer mcp_result.deinitToolResult(allocator, malformed);
    try std.testing.expect(malformed.is_error);
    const scalar = try lspStructuredTool(allocator, "textDocument/hover", "42");
    defer mcp_result.deinitToolResult(allocator, scalar);
    try std.testing.expect(!scalar.structuredContent.?.object.get("ok").?.bool);
    const error_payload = try lspStructuredTool(allocator, "textDocument/hover", "{\"error\":{\"code\":-1}}");
    defer mcp_result.deinitToolResult(allocator, error_payload);
    try std.testing.expect(!error_payload.structuredContent.?.object.get("ok").?.bool);

    try std.testing.expectError(error.OutOfMemory, workflowError(allocator, "tool", "op", "file.zig", error.OutOfMemory));
    const workflow_path = try workflowError(allocator, "tool", "op", "../escape.zig", error.PathOutsideWorkspace);
    defer mcp_result.deinitToolResult(allocator, workflow_path);
    try std.testing.expect(workflow_path.is_error);
    const workflow_generic = try workflowError(allocator, "tool", "op", "file.zig", error.FileNotFound);
    defer mcp_result.deinitToolResult(allocator, workflow_generic);
    try std.testing.expect(workflow_generic.is_error);
    const context_failure = try contextError(allocator, "tool", "context", error.MissingPort);
    defer mcp_result.deinitToolResult(allocator, context_failure);
    try std.testing.expect(context_failure.is_error);

    try gateway.verify();
}
