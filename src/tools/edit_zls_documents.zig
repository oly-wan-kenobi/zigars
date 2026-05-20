const std = @import("std");
const mcp = @import("mcp");
const zigar = @import("zigar");
const common = @import("common.zig");

const uri_util = zigar.uri;
const zls_session = zigar.zls_session;

const App = common.App;
const structured = common.structured;
const argString = common.argString;
const workspacePathErrorResult = common.workspacePathErrorResult;
const missingArgumentResult = common.missingArgumentResult;
const backendErrorResult = common.backendErrorResult;
const zlsUnavailable = common.zlsUnavailable;
const zlsSetupErrorResult = common.zlsSetupErrorResult;
const lspToolError = common.lspToolError;

pub fn zigDocumentOpen(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const file = argString(args, "file") orelse return missingArgumentResult(allocator, "zig_document_open", "file", "string");
    const content = argString(args, "content") orelse return missingArgumentResult(allocator, "zig_document_open", "content", "string");
    zls_session.ensureReady(a) catch |err| return backendErrorResult(allocator, "zls", "zig_document_open", err, "confirm --zls-path points to a compatible ZLS binary before opening unsaved document content");
    const client = a.lsp_client orelse return zlsUnavailable(a, allocator);
    const doc_state = a.doc_state orelse return zlsUnavailable(a, allocator);
    const resolved = a.workspace.resolve(file) catch |err| return workspacePathErrorResult(a, allocator, "zig_document_open", file, err);
    defer allocator.free(resolved);
    const uri = doc_state.syncText(client, resolved, content, allocator) catch |err| return zlsSetupErrorResult(a, allocator, "zig_document_open", file, err);
    defer allocator.free(uri);

    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    obj.put(allocator, "uri", .{ .string = uri }) catch return error.OutOfMemory;
    obj.put(allocator, "version", .{ .integer = doc_state.versionForUri(uri) orelse 0 }) catch return error.OutOfMemory;
    obj.put(allocator, "open", .{ .bool = true }) catch return error.OutOfMemory;
    return structured(allocator, .{ .object = obj });
}

pub fn zigDocumentClose(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const file = argString(args, "file") orelse return missingArgumentResult(allocator, "zig_document_close", "file", "string");
    zls_session.ensureReady(a) catch |err| return backendErrorResult(allocator, "zls", "zig_document_close", err, "confirm --zls-path points to a compatible ZLS binary before closing document state");
    const client = a.lsp_client orelse return zlsUnavailable(a, allocator);
    const doc_state = a.doc_state orelse return zlsUnavailable(a, allocator);
    const resolved = a.workspace.resolve(file) catch |err| return workspacePathErrorResult(a, allocator, "zig_document_close", file, err);
    defer allocator.free(resolved);
    const uri = uri_util.pathToUri(allocator, resolved) catch return error.OutOfMemory;
    defer allocator.free(uri);
    doc_state.closeDoc(client, uri) catch |err| return lspToolError(allocator, "zig_document_close", "textDocument/didClose", "notify_close", "document_close_failed", err, "Check the ZLS session status, then retry closing the document.");

    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    obj.put(allocator, "uri", .{ .string = uri }) catch return error.OutOfMemory;
    obj.put(allocator, "open", .{ .bool = false }) catch return error.OutOfMemory;
    return structured(allocator, .{ .object = obj });
}

pub fn zigDocumentStatus(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const file = argString(args, "file") orelse return missingArgumentResult(allocator, "zig_document_status", "file", "string");
    const resolved = a.workspace.resolve(file) catch |err| return workspacePathErrorResult(a, allocator, "zig_document_status", file, err);
    defer allocator.free(resolved);
    const uri = uri_util.pathToUri(allocator, resolved) catch return error.OutOfMemory;
    defer allocator.free(uri);

    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    obj.put(allocator, "file", .{ .string = file }) catch return error.OutOfMemory;
    obj.put(allocator, "uri", .{ .string = uri }) catch return error.OutOfMemory;
    if (a.doc_state) |doc_state| {
        if (doc_state.statusForUri(uri)) |status| {
            obj.put(allocator, "open", .{ .bool = true }) catch return error.OutOfMemory;
            obj.put(allocator, "version", .{ .integer = status.version }) catch return error.OutOfMemory;
            obj.put(allocator, "dirty", .{ .bool = status.dirty }) catch return error.OutOfMemory;
            obj.put(allocator, "content_hash", .{ .string = std.fmt.allocPrint(allocator, "{x:0>16}", .{status.content_hash}) catch return error.OutOfMemory }) catch return error.OutOfMemory;
            obj.put(allocator, "content_bytes", .{ .integer = @intCast(status.content_bytes) }) catch return error.OutOfMemory;
            obj.put(allocator, "retained_content_bytes", .{ .integer = @intCast(status.retained_content_bytes) }) catch return error.OutOfMemory;
            obj.put(allocator, "open_documents", .{ .integer = @intCast(status.open_documents) }) catch return error.OutOfMemory;
            obj.put(allocator, "max_document_bytes", .{ .integer = @intCast(status.max_document_bytes) }) catch return error.OutOfMemory;
            obj.put(allocator, "max_retained_content_bytes", .{ .integer = @intCast(status.max_retained_content_bytes) }) catch return error.OutOfMemory;
            obj.put(allocator, "max_open_documents", .{ .integer = @intCast(status.max_open_documents) }) catch return error.OutOfMemory;
            obj.put(allocator, "last_reopen", reopenSummaryValue(allocator, status.last_reopen) catch return error.OutOfMemory) catch return error.OutOfMemory;
            return structured(allocator, .{ .object = obj });
        }
    }
    obj.put(allocator, "open", .{ .bool = false }) catch return error.OutOfMemory;
    return structured(allocator, .{ .object = obj });
}

pub fn reopenSummaryValue(allocator: std.mem.Allocator, summary: zigar.document_state.DocumentState.ReopenSummary) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "attempted", .{ .integer = @intCast(summary.attempted) });
    try obj.put(allocator, "succeeded", .{ .integer = @intCast(summary.succeeded) });
    try obj.put(allocator, "skipped", .{ .integer = @intCast(summary.skipped) });
    try obj.put(allocator, "failed", .{ .integer = @intCast(summary.failed) });
    return .{ .object = obj };
}
