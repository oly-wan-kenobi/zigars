//! MCP adapters for ZLS/editor workflows, including formatting, document sync,
//! LSP position requests, and static-source fallbacks.
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

/// Formats a workspace Zig file and optionally applies the rewritten contents.
pub fn zigFormat(allocator: std.mem.Allocator, context: app_context.Context, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const file = argString(args, "file") orelse return mcp_errors.missingArgument(allocator, "zig_format", "file", "string");
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const value = editing_workflows.formatValue(scratch, context.coreCommands() catch |err| return contextError(allocator, "zig_format", "editing_format_context", err), file, argString(args, "content"), argBool(args, "apply", false), toolTimeout(context, args)) catch |err| return formatError(allocator, file, err);
    return mcp_result.structured(allocator, value);
}

/// Checks formatting for a workspace path without modifying files.
pub fn zigFormatCheck(allocator: std.mem.Allocator, context: app_context.Context, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const path = argString(args, "path") orelse return mcp_errors.missingArgument(allocator, "zig_format_check", "path", "string");
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const value = editing_workflows.formatCheckValue(scratch, context.coreCommands() catch |err| return contextError(allocator, "zig_format_check", "editing_format_context", err), path, toolTimeout(context, args)) catch |err| return workflowError(allocator, "zig_format_check", "format_check", path, err);
    return mcp_result.structured(allocator, value);
}

/// Previews or applies caller-supplied replacement content through editing policy.
pub fn zigPatchPreview(allocator: std.mem.Allocator, context: app_context.Context, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const file = argString(args, "file") orelse return mcp_errors.missingArgument(allocator, "zig_patch_preview", "file", "string");
    const content = argString(args, "content") orelse return mcp_errors.missingArgument(allocator, "zig_patch_preview", "content", "string");
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const value = editing_workflows.patchPreviewValue(scratch, context.coreCommands() catch |err| return contextError(allocator, "zig_patch_preview", "editing_patch_context", err), file, content, argBool(args, "apply", false)) catch |err| return workflowError(allocator, "zig_patch_preview", "patch_preview", file, err);
    return mcp_result.structured(allocator, value);
}

/// Opens/syncs a document snapshot for downstream ZLS requests.
pub fn zigDocumentOpen(allocator: std.mem.Allocator, context: app_context.Context, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return documentSync(allocator, context, args, "zig_document_open", "textDocument/didOpen");
}

/// Replaces/syncs a document snapshot for downstream ZLS requests.
pub fn zigDocumentChange(allocator: std.mem.Allocator, context: app_context.Context, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return documentSync(allocator, context, args, "zig_document_change", "textDocument/didChange");
}

/// Reports document closure as an idempotent no-op for stateless gateway clients.
pub fn zigDocumentClose(allocator: std.mem.Allocator, _: app_context.Context, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const file = argString(args, "file") orelse return mcp_errors.missingArgument(allocator, "zig_document_close", "file", "string");
    var obj = std.json.ObjectMap.empty;
    defer obj.deinit(allocator);
    try obj.put(allocator, "file", .{ .string = file });
    try obj.put(allocator, "open", .{ .bool = false });
    try obj.put(allocator, "note", .{ .string = "Document close is a no-op when routed through the typed ZLS gateway; subsequent requests resync the document as needed." });
    return mcp_result.structured(allocator, .{ .object = obj });
}

/// Returns the current document-sync status known to the ZLS workflow layer.
pub fn zigDocumentStatus(allocator: std.mem.Allocator, context: app_context.Context, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const file = argString(args, "file") orelse return mcp_errors.missingArgument(allocator, "zig_document_status", "file", "string");
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const value = zls_workflows.documentStatusValue(scratch, context, file) catch |err| return workflowError(allocator, "zig_document_status", "document_status", file, err);
    return mcp_result.structured(allocator, value);
}

/// Handles MCP `zig_hover` requests by delegating to app logic and shaping owned results/errors.
pub fn zigHover(allocator: std.mem.Allocator, context: app_context.Context, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return positionTool(allocator, context, args, "zig_hover", "textDocument/hover");
}

/// Handles MCP `zig_definition` requests by delegating to app logic and shaping owned results/errors.
pub fn zigDefinition(allocator: std.mem.Allocator, context: app_context.Context, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return positionTool(allocator, context, args, "zig_definition", "textDocument/definition");
}

/// Handles MCP `zig_references` requests by delegating to app logic and shaping owned results/errors.
pub fn zigReferences(allocator: std.mem.Allocator, context: app_context.Context, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return positionTool(allocator, context, args, "zig_references", "textDocument/references");
}

/// Handles MCP `zig_completion` requests by delegating to app logic and shaping owned results/errors.
pub fn zigCompletion(allocator: std.mem.Allocator, context: app_context.Context, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return positionTool(allocator, context, args, "zig_completion", "textDocument/completion");
}

/// Handles MCP `zig_signature_help` requests by delegating to app logic and shaping owned results/errors.
pub fn zigSignatureHelp(allocator: std.mem.Allocator, context: app_context.Context, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return positionTool(allocator, context, args, "zig_signature_help", "textDocument/signatureHelp");
}

/// Handles MCP `zig_document_symbols` requests by delegating to app logic and shaping owned results/errors.
pub fn zigDocumentSymbols(allocator: std.mem.Allocator, context: app_context.Context, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const result = fileOnlyTool(allocator, context, args, "zig_document_symbols", "textDocument/documentSymbol");
    return result catch static_source_adapter.zigDeclSummary(allocator, context.staticAnalysis() catch |err| return contextError(allocator, "zig_document_symbols", "static_analysis_context", err), args);
}

/// Handles MCP `zig_workspace_symbols` requests by delegating to app logic and shaping owned results/errors.
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

/// Handles MCP `zig_code_actions` requests by delegating to app logic and shaping owned results/errors.
pub fn zigCodeActions(allocator: std.mem.Allocator, context: app_context.Context, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return rangeTool(allocator, context, args, "zig_code_actions");
}

/// Handles MCP `zig_code_action_apply` requests by delegating to app logic and shaping owned results/errors.
pub fn zigCodeActionApply(allocator: std.mem.Allocator, context: app_context.Context, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    // This tool is preview-only and does not register an `apply` argument, so it
    // never writes source. Central validation rejects an `apply` argument before
    // the handler runs, so no apply-gate guard is needed here.
    const file = argString(args, "file") orelse return mcp_errors.missingArgument(allocator, "zig_code_action_apply", "file", "string");
    const start_line = argIntRequired(args, "start_line") orelse return mcp_errors.missingArgument(allocator, "zig_code_action_apply", "start_line", "integer");
    const start_char = argIntRequired(args, "start_char") orelse return mcp_errors.missingArgument(allocator, "zig_code_action_apply", "start_char", "integer");
    const end_line = argIntRequired(args, "end_line") orelse return mcp_errors.missingArgument(allocator, "zig_code_action_apply", "end_line", "integer");
    const end_char = argIntRequired(args, "end_char") orelse return mcp_errors.missingArgument(allocator, "zig_code_action_apply", "end_char", "integer");
    const action_index = argIntRequired(args, "action_index") orelse return mcp_errors.missingArgument(allocator, "zig_code_action_apply", "action_index", "integer");
    const zls_ctx = context.zls() catch |err| return contextError(allocator, "zig_code_action_apply", "zls_context", err);
    var outcome = code_intel.codeActionSelection(allocator, zls_ctx, .{
        .file = file,
        .content = argString(args, "content"),
        .start_line = start_line,
        .start_character = start_char,
        .end_line = end_line,
        .end_character = end_char,
        .action_index = action_index,
    }) catch return error.OutOfMemory;
    defer outcome.deinit(allocator);
    return switch (outcome) {
        .ok => |response| lspStructuredTool(allocator, response.method, response.payload),
        .err => |failure| zlsFailureResult(allocator, context, "zig_code_action_apply", "textDocument/codeAction", file, failure),
    };
}

/// Handles MCP `zig_rename` requests by delegating to app logic and shaping owned results/errors.
pub fn zigRename(allocator: std.mem.Allocator, context: app_context.Context, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    // This tool is preview-only and does not register an `apply` argument, so it
    // never writes source. Central validation rejects an `apply` argument before
    // the handler runs, so no apply-gate guard is needed here.
    const file = argString(args, "file") orelse return mcp_errors.missingArgument(allocator, "zig_rename", "file", "string");
    const line = argIntRequired(args, "line") orelse return mcp_errors.missingArgument(allocator, "zig_rename", "line", "integer");
    const character = argIntRequired(args, "character") orelse return mcp_errors.missingArgument(allocator, "zig_rename", "character", "integer");
    const new_name = argString(args, "new_name") orelse return mcp_errors.missingArgument(allocator, "zig_rename", "new_name", "string");
    const zls_ctx = context.zls() catch |err| return contextError(allocator, "zig_rename", "zls_context", err);
    var outcome = code_intel.rename(allocator, zls_ctx, .{
        .file = file,
        .content = argString(args, "content"),
        .line = line,
        .character = character,
        .new_name = new_name,
    }) catch return error.OutOfMemory;
    defer outcome.deinit(allocator);
    return switch (outcome) {
        .ok => |response| lspStructuredTool(allocator, response.method, response.payload),
        .err => |failure| zlsFailureResult(allocator, context, "zig_rename", "textDocument/rename", file, failure),
    };
}

/// Handles MCP `zig_diagnostics` requests by delegating to app logic and shaping owned results/errors.
pub fn zigDiagnostics(allocator: std.mem.Allocator, context: app_context.Context, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    _ = argString(args, "file") orelse return mcp_errors.missingArgument(allocator, "zig_diagnostics", "file", "string");
    const zls_result = fileOnlyTool(allocator, context, args, "zig_diagnostics", "textDocument/diagnostic");
    return zls_result catch core_adapter.zigCheck(allocator, context.coreCommands() catch |err| return contextError(allocator, "zig_diagnostics", "core_context", err), args);
}

/// Handles MCP `zig_diagnostics_all` requests by delegating to app logic and shaping owned results/errors.
pub fn zigDiagnosticsAll(allocator: std.mem.Allocator, context: app_context.Context, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return zigDiagnostics(allocator, context, args);
}

/// Handles MCP `zig_diagnostics_workspace` requests by delegating to app logic and shaping owned results/errors.
pub fn zigDiagnosticsWorkspace(allocator: std.mem.Allocator, context: app_context.Context, _: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    if (!context.zls_state.running) return structuredText(allocator, "zig_diagnostics_workspace", "ZLS session is unavailable; no workspace diagnostics cache exists.");
    const zls_ctx = context.zls() catch |err| return contextError(allocator, "zig_diagnostics_workspace", "zls_context", err);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const value = zls_workflows.workspaceDiagnosticsValue(scratch, zls_ctx) catch |err| return zlsPortError(allocator, context, "zig_diagnostics_workspace", "textDocument/publishDiagnostics", "", err);
    return mcp_result.structured(allocator, value);
}

/// Validates document sync arguments and forwards them to the ZLS workflow.
fn documentSync(allocator: std.mem.Allocator, context: app_context.Context, args: ?std.json.Value, tool_name: []const u8, method: []const u8) mcp.tools.ToolError!mcp.tools.ToolResult {
    const file = argString(args, "file") orelse return mcp_errors.missingArgument(allocator, tool_name, "file", "string");
    const content = argString(args, "content") orelse return mcp_errors.missingArgument(allocator, tool_name, "content", "string");
    const zls_ctx = context.zls() catch |err| return contextError(allocator, tool_name, "zls_context", err);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const value = zls_workflows.documentSyncValue(scratch, zls_ctx, tool_name, file, content) catch |err| return zlsPortError(allocator, context, tool_name, method, file, err);
    return mcp_result.structured(allocator, value);
}

/// Validates file/position arguments and invokes a positional ZLS request.
fn positionTool(allocator: std.mem.Allocator, context: app_context.Context, args: ?std.json.Value, tool_name: []const u8, method: []const u8) mcp.tools.ToolError!mcp.tools.ToolResult {
    const file = argString(args, "file") orelse return mcp_errors.missingArgument(allocator, tool_name, "file", "string");
    const line = argIntRequired(args, "line") orelse return mcp_errors.missingArgument(allocator, tool_name, "line", "integer");
    const character = argIntRequired(args, "character") orelse return mcp_errors.missingArgument(allocator, tool_name, "character", "integer");
    const zls_ctx = context.zls() catch |err| return contextError(allocator, tool_name, "zls_context", err);
    var outcome = code_intel.position(allocator, zls_ctx, .{
        .method = method,
        .file = file,
        .content = argString(args, "content"),
        .line = line,
        .character = character,
        .include_declaration = argBool(args, "include_declaration", true),
    }) catch return error.OutOfMemory;
    defer outcome.deinit(allocator);
    return switch (outcome) {
        .ok => |response| lspStructuredTool(allocator, response.method, response.payload),
        .err => |failure| zlsFailureResult(allocator, context, tool_name, method, argString(args, "file"), failure),
    };
}

/// Validates the file/range arguments and invokes a range-scoped ZLS request.
fn rangeTool(allocator: std.mem.Allocator, context: app_context.Context, args: ?std.json.Value, tool_name: []const u8) mcp.tools.ToolError!mcp.tools.ToolResult {
    const file = argString(args, "file") orelse return mcp_errors.missingArgument(allocator, tool_name, "file", "string");
    const start_line = argIntRequired(args, "start_line") orelse return mcp_errors.missingArgument(allocator, tool_name, "start_line", "integer");
    const start_char = argIntRequired(args, "start_char") orelse return mcp_errors.missingArgument(allocator, tool_name, "start_char", "integer");
    const end_line = argIntRequired(args, "end_line") orelse return mcp_errors.missingArgument(allocator, tool_name, "end_line", "integer");
    const end_char = argIntRequired(args, "end_char") orelse return mcp_errors.missingArgument(allocator, tool_name, "end_char", "integer");
    const zls_ctx = context.zls() catch |err| return contextError(allocator, tool_name, "zls_context", err);
    var outcome = code_intel.range(allocator, zls_ctx, .{
        .method = "textDocument/codeAction",
        .file = file,
        .content = argString(args, "content"),
        .start_line = start_line,
        .start_character = start_char,
        .end_line = end_line,
        .end_character = end_char,
    }) catch return error.OutOfMemory;
    defer outcome.deinit(allocator);
    return switch (outcome) {
        .ok => |response| lspStructuredTool(allocator, response.method, response.payload),
        .err => |failure| zlsFailureResult(allocator, context, tool_name, "textDocument/codeAction", file, failure),
    };
}

/// Validates the file argument and invokes a file-scoped ZLS request.
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

/// Returns the MCP tool result for ZLS failure.
fn zlsFailureResult(allocator: std.mem.Allocator, context: app_context.Context, tool_name: []const u8, method: []const u8, file: ?[]const u8, failure: code_intel.Failure) mcp.tools.ToolError!mcp.tools.ToolResult {
    return switch (failure) {
        .unavailable => zlsUnavailable(allocator, context),
        .unsupported_capability => |capability| unsupportedCapability(allocator, method, capability),
        .missing_file => mcp_errors.missingArgument(allocator, tool_name, "file", "string"),
        .invalid_action_index => |selection| invalidCodeActionIndex(allocator, selection.index, selection.count),
        .invalid_response => |message| invalidZlsResponse(allocator, tool_name, method, message),
        .sync_failed => |port_failure| zlsPortError(allocator, context, tool_name, method, file orelse port_failure.file orelse "", port_failure.err),
        .request_failed => |port_failure| zlsPortError(allocator, context, tool_name, method, file orelse port_failure.file orelse "", port_failure.err),
    };
}

/// Maps ZLS gateway failures to user-facing MCP tool errors.
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

/// Wraps a raw LSP JSON response in the structured MCP result envelope.
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

/// Returns a structured result for a ZLS capability the server does not expose.
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

/// Returns a structured result for an out-of-range code-action selection.
fn invalidCodeActionIndex(allocator: std.mem.Allocator, index: i64, count: usize) mcp.tools.ToolError!mcp.tools.ToolResult {
    var obj = std.json.ObjectMap.empty;
    defer obj.deinit(allocator);
    try obj.put(allocator, "ok", .{ .bool = false });
    try obj.put(allocator, "kind", .{ .string = "zls_invalid_code_action_index" });
    try obj.put(allocator, "action_index", .{ .integer = index });
    try obj.put(allocator, "available_actions", .{ .integer = @intCast(count) });
    try obj.put(allocator, "error", .{ .string = "Requested code action index is outside the ZLS result array." });
    try obj.put(allocator, "resolution", .{ .string = "Call zig_code_actions again and choose an index from the returned result array." });
    return mcp_result.structured(allocator, .{ .object = obj });
}

/// Returns a structured result for a malformed ZLS payload.
fn invalidZlsResponse(allocator: std.mem.Allocator, tool_name: []const u8, method: []const u8, message: []const u8) mcp.tools.ToolError!mcp.tools.ToolResult {
    return mcp_errors.fromError(allocator, .{
        .tool = tool_name,
        .operation = method,
        .phase = "parse_response",
        .code = "malformed_backend_response",
        .category = "lsp",
        .resolution = message,
    }, error.InvalidRequest);
}

/// Returns a structured result describing the configured ZLS backend status.
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

/// Wraps plain text output with a `kind` discriminator for structured tools.
fn structuredText(allocator: std.mem.Allocator, kind: []const u8, text: []const u8) mcp.tools.ToolError!mcp.tools.ToolResult {
    var obj = std.json.ObjectMap.empty;
    defer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = kind });
    try obj.put(allocator, "text", .{ .string = text });
    return mcp_result.structured(allocator, .{ .object = obj });
}

/// Maps workflow failures to structured MCP tool errors.
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

/// Maps format workflow failures to structured MCP tool errors.
fn formatError(allocator: std.mem.Allocator, file: []const u8, err: anyerror) mcp.tools.ToolError!mcp.tools.ToolResult {
    if (err == error.OutOfMemory) return error.OutOfMemory;
    if (err == error.PathOutsideWorkspace or err == error.EmptyPath) return mcp_errors.workspacePath(allocator, "zig_format", file, "", err);
    return mcp_errors.fromError(allocator, .{
        .tool = "zig_format",
        .operation = "format_preview",
        .phase = if (err == error.FileNotFound or err == error.NotFound) "read_source" else "run_workflow",
        .code = if (err == error.FileNotFound or err == error.NotFound) "read_failed" else "format_failed",
        .category = if (err == error.FileNotFound or err == error.NotFound) "filesystem" else "editing",
        .resolution = "Confirm the file exists inside the zigars workspace and retry.",
        .details = &.{.{ .key = "file", .value = .{ .string = file } }},
    }, err);
}

/// Maps runtime context construction failures to structured MCP tool errors.
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

/// Clamps requested tool timeout to the supported command timeout range.
fn toolTimeout(context: app_context.Context, args: ?std.json.Value) i64 {
    return @max(1, @min(argInt(args, "timeout_ms", context.timeouts.command_ms), 60 * 60 * 1000));
}

/// Reads a string argument when it is present with the expected type.
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

/// Reads a bool argument when it is present with the expected type.
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

/// Reads an int argument when it is present with the expected type.
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

/// Reads an int argument only when present with the expected type.
fn argIntRequired(args: ?std.json.Value, name: []const u8) ?i64 {
    const obj = switch (args orelse return null) {
        .object => |o| o,
        else => return null,
    };
    return switch (obj.get(name) orelse .null) {
        .integer => |i| i,
        else => null,
    };
}

/// Creates zls adapter test context from the ports required by the adapter.
fn zlsAdapterTestContext(gateway: ports.ZlsGateway) app_context.Context {
    return .{
        .workspace = .{ .root = "/repo", .cache_root = "/repo/.zigars-cache", .transport = "test" },
        .tool_paths = .{ .zig = "zig", .zls = "zls-test" },
        .timeouts = .{ .command_ms = 1000, .zls_ms = 1000 },
        .zls_state = .{ .status = "connected", .running = true },
        .ports = .{ .zls_gateway = gateway },
    };
}

/// Asserts capability in adapter tests.
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

    try gateway.expectSync(.{
        .file = "src/main.zig",
        .content = "pub fn main() void { return; }",
        .provenance = "zig_document_change",
    }, .{ .uri = "file:///repo/src/main.zig", .basis = "content" });
    const change_args = try std.json.parseFromSlice(std.json.Value, allocator, "{\"file\":\"src/main.zig\",\"content\":\"pub fn main() void { return; }\"}", .{});
    defer change_args.deinit();
    const changed = try zigDocumentChange(allocator, context, change_args.value);
    defer mcp_result.deinitToolResult(allocator, changed);
    try std.testing.expect(changed.structuredContent.?.object.get("open").?.bool);

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
    const file_args = try std.json.parseFromSlice(std.json.Value, allocator, "{\"file\":\"src/main.zig\",\"line\":0,\"character\":0}", .{});
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

    const missing_file = try zigHover(allocator, context, null);
    defer mcp_result.deinitToolResult(allocator, missing_file);
    try std.testing.expect(missing_file.is_error);

    try expectCapability(&gateway, "codeActionProvider", false);
    const code_action_args = try std.json.parseFromSlice(std.json.Value, allocator, "{\"file\":\"src/main.zig\",\"start_line\":1,\"start_char\":0,\"end_line\":1,\"end_char\":4,\"action_index\":0}", .{});
    defer code_action_args.deinit();
    const code_actions = try zigCodeActionApply(allocator, context, code_action_args.value);
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
    const file_args = try std.json.parseFromSlice(std.json.Value, allocator, "{\"file\":\"src/main.zig\",\"line\":0,\"character\":0}", .{});
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
    try std.testing.expect(!escaped.structuredContent.?.object.get("ok").?.bool);

    try gateway.setDiagnosticsMessages(&.{
        "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/publishDiagnostics\",\"params\":{\"uri\":\"file:///repo/src/main.zig\",\"diagnostics\":[{\"severity\":1},{\"severity\":2},{\"message\":\"missing severity\"}]}}",
        "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/publishDiagnostics\",\"params\":{\"uri\":\"file:///repo/invalid.zig\",\"diagnostics\":\"not an array\"}}",
    });
    const diagnostics = try zigDiagnosticsWorkspace(allocator, context, null);
    defer mcp_result.deinitToolResult(allocator, diagnostics);
    const diagnostics_obj = diagnostics.structuredContent.?.object;
    try std.testing.expectEqual(@as(i64, 3), diagnostics_obj.get("total").?.integer);
    try std.testing.expectEqual(@as(i64, 1), diagnostics_obj.get("errors").?.integer);
    try std.testing.expectEqual(@as(i64, 1), diagnostics_obj.get("warnings").?.integer);
    try std.testing.expectEqual(@as(i64, 1), diagnostics_obj.get("unknown").?.integer);
    try std.testing.expectEqual(@as(i64, 1), diagnostics_obj.get("malformed_notifications").?.integer);
    try std.testing.expectEqual(@as(usize, 1), diagnostics_obj.get("files").?.array.items.len);
    try std.testing.expectEqual(@as(usize, 1), gateway.diagnosticsCalls());

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
