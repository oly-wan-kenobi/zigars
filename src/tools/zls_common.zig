const std = @import("std");
const mcp = @import("mcp");
const zigar = @import("zigar");

const command = zigar.command;
const json_result = zigar.json_result;
const zls_session = zigar.zls_session;
const core = @import("shared_core.zig");

const App = core.App;
const structured = core.structured;
const argString = core.argString;
const workspacePathErrorResult = core.workspacePathErrorResult;
const backendErrorResult = core.backendErrorResult;
const missingArgumentResult = core.missingArgumentResult;
const toolErrorFromError = core.toolErrorFromError;
const splitToolArgs = core.splitToolArgs;
const classifyDiagnosticMessage = core.classifyDiagnosticMessage;
const backendProbeCacheValue = core.backendProbeCacheValue;
const ownedString = core.ownedString;
const workspacePathExists = core.workspacePathExists;
const zlsUnavailable = core.zlsUnavailable;

pub fn metricsValue(a: *App, allocator: std.mem.Allocator) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "command_calls", .{ .integer = @intCast(a.command_calls) });
    try obj.put(allocator, "zls_requests", .{ .integer = @intCast(a.zls_requests) });
    try obj.put(allocator, "tool_errors", .{ .integer = @intCast(a.tool_errors) });
    try obj.put(allocator, "zls_status", .{ .string = a.zls_status });
    try obj.put(allocator, "zls", try zlsStatusValue(allocator, a));
    try obj.put(allocator, "zls_running", .{ .bool = if (a.lsp_client) |client| client.isRunning() else false });
    try obj.put(allocator, "zls_restart_attempts", .{ .integer = @intCast(a.zls_restart_attempts) });
    if (a.zls_last_failure) |failure| {
        try obj.put(allocator, "zls_last_failure", .{ .string = failure });
    } else if (a.lsp_client) |client| {
        if (try client.lastError(allocator)) |err| {
            try obj.put(allocator, "zls_last_failure", .{ .string = err });
        } else {
            try obj.put(allocator, "zls_last_failure", .null);
        }
    } else {
        try obj.put(allocator, "zls_last_failure", .null);
    }
    try obj.put(allocator, "workspace", .{ .string = a.workspace.root });
    try obj.put(allocator, "backend_probe_cache", try backendProbeCacheValue(allocator, a.backend_probe_cache));
    try obj.put(allocator, "analysis_cache", try analysisCacheStatusValue(allocator, a));
    return .{ .object = obj };
}

pub fn analysisCacheStatusValue(allocator: std.mem.Allocator, a: *App) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "present", .{ .bool = a.analysis_cache.index_json != null });
    try obj.put(allocator, "signature", .{ .string = try std.fmt.allocPrint(allocator, "{x:0>16}", .{a.analysis_cache.signature}) });
    try obj.put(allocator, "hits", .{ .integer = @intCast(a.analysis_cache.hits) });
    try obj.put(allocator, "refreshes", .{ .integer = @intCast(a.analysis_cache.refreshes) });
    if (a.analysis_cache.index_json) |bytes| {
        try obj.put(allocator, "bytes", .{ .integer = @intCast(bytes.len) });
    } else {
        try obj.put(allocator, "bytes", .{ .integer = 0 });
    }
    return .{ .object = obj };
}

pub fn zlsStatusValue(allocator: std.mem.Allocator, a: *App) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    const running = if (a.lsp_client) |client| client.isRunning() else false;
    try obj.put(allocator, "status", .{ .string = a.zls_status });
    try obj.put(allocator, "configured_path", .{ .string = a.config.zls_path });
    try obj.put(allocator, "request_timeout_ms", .{ .integer = a.config.zls_timeout_ms });
    try obj.put(allocator, "restart_attempts", .{ .integer = @intCast(a.zls_restart_attempts) });
    try obj.put(allocator, "running", .{ .bool = running });
    try obj.put(allocator, "document_sync", .{ .bool = a.doc_state != null });
    if (a.lsp_client) |client| {
        const diagnostics = client.diagnosticsStatus();
        try obj.put(allocator, "diagnostics_cached_files", .{ .integer = @intCast(diagnostics.files) });
        try obj.put(allocator, "diagnostics_retained_bytes", .{ .integer = @intCast(diagnostics.retained_bytes) });
        try obj.put(allocator, "max_diagnostics_bytes", .{ .integer = @intCast(diagnostics.max_bytes) });
    }
    try obj.put(allocator, "initialize_response_present", .{ .bool = a.zls_initialize_response != null });
    if (a.zls_last_failure) |failure| {
        try obj.put(allocator, "last_failure", .{ .string = failure });
    } else if (a.lsp_client) |client| {
        if (try client.lastError(allocator)) |err| {
            try obj.put(allocator, "last_failure", .{ .string = err });
        } else {
            try obj.put(allocator, "last_failure", .null);
        }
    } else {
        try obj.put(allocator, "last_failure", .null);
    }
    try obj.put(allocator, "resolution", .{ .string = if (running)
        "ZLS-backed tools are available"
    else
        "confirm --zls-path points to a compatible ZLS binary; command-backed Zig tools remain available" });
    return .{ .object = obj };
}

pub fn unsupportedCapability(allocator: std.mem.Allocator, method: []const u8, capability: []const u8) mcp.tools.ToolError!mcp.tools.ToolResult {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    obj.put(allocator, "ok", .{ .bool = false }) catch return error.OutOfMemory;
    obj.put(allocator, "method", .{ .string = method }) catch return error.OutOfMemory;
    obj.put(allocator, "capability", .{ .string = capability }) catch return error.OutOfMemory;
    obj.put(allocator, "error", .{ .string = "ZLS did not advertise this capability" }) catch return error.OutOfMemory;
    return structured(allocator, .{ .object = obj });
}

pub fn zlsCapabilityName(method: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, method, "textDocument/hover")) return "hoverProvider";
    if (std.mem.eql(u8, method, "textDocument/definition")) return "definitionProvider";
    if (std.mem.eql(u8, method, "textDocument/references")) return "referencesProvider";
    if (std.mem.eql(u8, method, "textDocument/completion")) return "completionProvider";
    if (std.mem.eql(u8, method, "textDocument/signatureHelp")) return "signatureHelpProvider";
    if (std.mem.eql(u8, method, "textDocument/documentSymbol")) return "documentSymbolProvider";
    if (std.mem.eql(u8, method, "textDocument/formatting")) return "documentFormattingProvider";
    if (std.mem.eql(u8, method, "textDocument/rename")) return "renameProvider";
    if (std.mem.eql(u8, method, "textDocument/codeAction")) return "codeActionProvider";
    if (std.mem.eql(u8, method, "workspace/symbol")) return "workspaceSymbolProvider";
    return null;
}

pub fn zlsSupportsCapability(a: *App, allocator: std.mem.Allocator, method: []const u8) bool {
    const capability = zlsCapabilityName(method) orelse return true;
    const response = a.zls_initialize_response orelse return false;
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, response, .{}) catch return false;
    defer parsed.deinit();
    const result = responseResult(parsed.value) orelse return false;
    const result_obj = switch (result) {
        .object => |o| o,
        else => return false,
    };
    const caps = switch (result_obj.get("capabilities") orelse .null) {
        .object => |o| o,
        else => return false,
    };
    const value = caps.get(capability) orelse return false;
    return switch (value) {
        .bool => |b| b,
        .object => true,
        .array => true,
        else => false,
    };
}

pub fn requireZlsCapability(a: *App, allocator: std.mem.Allocator, method: []const u8) ?mcp.tools.ToolResult {
    const capability = zlsCapabilityName(method) orelse return null;
    if (zlsSupportsCapability(a, allocator, method)) return null;
    return unsupportedCapability(allocator, method, capability) catch null;
}
pub const ExplainCommand = struct {
    argv: std.ArrayList([]const u8),
    owned_paths: std.ArrayList([]const u8),
    mode: []const u8,
};

const ExplainCommandError = mcp.tools.ToolError || error{WorkspacePathRejected};

pub fn buildExplainCommand(allocator: std.mem.Allocator, args: ?std.json.Value, a: *App) ExplainCommandError!ExplainCommand {
    const mode = argString(args, "command") orelse if (argString(args, "file") != null) "check" else "build-test";
    var list: std.ArrayList([]const u8) = .empty;
    var owned_paths: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (owned_paths.items) |path| allocator.free(path);
        owned_paths.deinit(allocator);
        list.deinit(allocator);
    }
    list.append(allocator, a.config.zig_path) catch return error.OutOfMemory;

    if (std.mem.eql(u8, mode, "check")) {
        const file = argString(args, "file") orelse return error.InvalidArguments;
        const resolved = a.workspace.resolve(file) catch return error.WorkspacePathRejected;
        owned_paths.append(allocator, resolved) catch return error.OutOfMemory;
        list.append(allocator, "ast-check") catch return error.OutOfMemory;
        list.append(allocator, resolved) catch return error.OutOfMemory;
    } else if (std.mem.eql(u8, mode, "test")) {
        if (argString(args, "file")) |file| {
            const resolved = a.workspace.resolve(file) catch return error.WorkspacePathRejected;
            owned_paths.append(allocator, resolved) catch return error.OutOfMemory;
            list.append(allocator, "test") catch return error.OutOfMemory;
            list.append(allocator, resolved) catch return error.OutOfMemory;
        } else {
            list.append(allocator, "build") catch return error.OutOfMemory;
            list.append(allocator, "test") catch return error.OutOfMemory;
        }
    } else if (std.mem.eql(u8, mode, "build")) {
        list.append(allocator, "build") catch return error.OutOfMemory;
    } else if (std.mem.eql(u8, mode, "build-test")) {
        list.append(allocator, "build") catch return error.OutOfMemory;
        list.append(allocator, "test") catch return error.OutOfMemory;
    } else if (std.mem.eql(u8, mode, "fmt-check")) {
        const file = argString(args, "file") orelse ".";
        const resolved = a.workspace.resolve(file) catch return error.WorkspacePathRejected;
        owned_paths.append(allocator, resolved) catch return error.OutOfMemory;
        list.append(allocator, "fmt") catch return error.OutOfMemory;
        list.append(allocator, "--check") catch return error.OutOfMemory;
        list.append(allocator, resolved) catch return error.OutOfMemory;
    } else {
        return error.InvalidArguments;
    }

    const extra = try splitToolArgs(allocator, argString(args, "args"));
    defer freeArgList(allocator, extra);
    list.appendSlice(allocator, extra) catch return error.OutOfMemory;
    return .{ .argv = list, .owned_paths = owned_paths, .mode = mode };
}

pub fn explainCommandSetupError(a: *App, allocator: std.mem.Allocator, tool_name: []const u8, args: ?std.json.Value, err: anyerror) mcp.tools.ToolError!mcp.tools.ToolResult {
    return switch (err) {
        error.WorkspacePathRejected => if (argString(args, "file")) |file|
            workspacePathErrorResult(a, allocator, tool_name, file, error.PathOutsideWorkspace)
        else
            error.PermissionDenied,
        error.InvalidArguments => error.InvalidArguments,
        error.OutOfMemory => error.OutOfMemory,
        else => error.ExecutionFailed,
    };
}

pub fn zlsFileUri(a: *App, allocator: std.mem.Allocator, file: []const u8) ![]const u8 {
    try zls_session.ensureReady(a);
    const client = a.lsp_client orelse return error.NotConnected;
    const doc_state = a.doc_state orelse return error.NotConnected;
    const resolved = try a.workspace.resolve(file);
    defer allocator.free(resolved);
    return doc_state.ensureOpen(client, resolved, allocator);
}

pub fn zlsFileUriFromArgs(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) ![]const u8 {
    const file = argString(args, "file") orelse return error.InvalidArguments;
    if (argString(args, "content")) |content| {
        try zls_session.ensureReady(a);
        const client = a.lsp_client orelse return error.NotConnected;
        const doc_state = a.doc_state orelse return error.NotConnected;
        const resolved = try a.workspace.resolve(file);
        defer allocator.free(resolved);
        return doc_state.syncText(client, resolved, content, allocator);
    }
    return zlsFileUri(a, allocator, file);
}

pub fn zlsSetupErrorResult(a: *App, allocator: std.mem.Allocator, operation: []const u8, file: ?[]const u8, err: anyerror) mcp.tools.ToolError!mcp.tools.ToolResult {
    switch (err) {
        error.InvalidArguments => return missingArgumentResult(allocator, operation, "file", "string"),
        error.PathOutsideWorkspace, error.EmptyPath => {
            if (file) |path| return workspacePathErrorResult(a, allocator, operation, path, err);
            return missingArgumentResult(allocator, operation, "file", "string");
        },
        error.NotConnected => return zlsUnavailable(a, allocator),
        error.DocumentTooLarge => return toolErrorFromError(allocator, .{
            .tool = operation,
            .operation = "sync_document",
            .phase = "document_size_limit",
            .code = "document_too_large",
            .category = "document_state",
            .resolution = "Save the file on disk and call a file-based tool, or send a smaller unsaved document.",
        }, err),
        error.OpenDocumentLimitExceeded => return toolErrorFromError(allocator, .{
            .tool = operation,
            .operation = "sync_document",
            .phase = "open_document_limit",
            .code = "open_document_limit_exceeded",
            .category = "document_state",
            .resolution = "Close unused documents with zig_document_close and retry.",
        }, err),
        else => return backendErrorResult(
            allocator,
            "zls",
            operation,
            err,
            "confirm --zls-path points to a compatible ZLS binary and retry; command-backed Zig tools remain available without ZLS",
        ),
    }
}

pub fn lspResultJson(allocator: std.mem.Allocator, response: []const u8) ![]const u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, response, .{});
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return allocator.dupe(u8, response),
    };
    const value = obj.get("result") orelse obj.get("error") orelse parsed.value;
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    try std.json.Stringify.value(value, .{ .whitespace = .indent_2 }, &aw.writer);
    return try aw.toOwnedSlice();
}

pub fn lspDiagnosticsInsightsValue(allocator: std.mem.Allocator, value: std.json.Value) !std.json.Value {
    const value_obj = switch (value) {
        .object => |o| o,
        else => {
            var empty = std.json.ObjectMap.empty;
            try empty.put(allocator, "finding_count", .{ .integer = 0 });
            try empty.put(allocator, "findings", .{ .array = std.json.Array.init(allocator) });
            try empty.put(allocator, "primary", .null);
            try empty.put(allocator, "next_actions", .{ .array = std.json.Array.init(allocator) });
            return .{ .object = empty };
        },
    };
    const uri = switch (value_obj.get("uri") orelse .null) {
        .string => |s| s,
        else => null,
    };
    const items = value_obj.get("diagnostics") orelse value_obj.get("items") orelse std.json.Value{ .array = std.json.Array.init(allocator) };
    const item_array = switch (items) {
        .array => |a| a,
        else => std.json.Array.init(allocator),
    };

    var findings = std.json.Array.init(allocator);
    var error_count: i64 = 0;
    var warning_count: i64 = 0;
    var info_count: i64 = 0;
    var primary_message: ?[]const u8 = null;
    var primary_path: ?[]const u8 = uri;
    var primary_line: ?i64 = null;
    var primary_column: ?i64 = null;
    var primary_severity: []const u8 = "info";

    for (item_array.items) |item| {
        const item_obj = switch (item) {
            .object => |o| o,
            else => continue,
        };
        const message = switch (item_obj.get("message") orelse .null) {
            .string => |s| s,
            else => continue,
        };
        const severity_code = switch (item_obj.get("severity") orelse .null) {
            .integer => |i| i,
            else => 3,
        };
        const severity = lspSeverityName(severity_code);
        if (std.mem.eql(u8, severity, "error")) {
            error_count += 1;
        } else if (std.mem.eql(u8, severity, "warning")) {
            warning_count += 1;
        } else {
            info_count += 1;
        }
        const start = lspDiagnosticStart(item_obj.get("range") orelse .null);
        var finding = std.json.ObjectMap.empty;
        try finding.put(allocator, "source", .{ .string = "zls" });
        try finding.put(allocator, "severity", .{ .string = severity });
        try finding.put(allocator, "message", try ownedString(allocator, message));
        if (uri) |u| {
            try finding.put(allocator, "uri", try ownedString(allocator, u));
        } else {
            try finding.put(allocator, "uri", .null);
        }
        if (start.line) |line_no| {
            try finding.put(allocator, "line", .{ .integer = line_no });
        } else {
            try finding.put(allocator, "line", .null);
        }
        if (start.column) |col_no| {
            try finding.put(allocator, "column", .{ .integer = col_no });
        } else {
            try finding.put(allocator, "column", .null);
        }
        try findings.append(.{ .object = finding });

        if (primary_message == null or (std.mem.eql(u8, severity, "error") and !std.mem.eql(u8, primary_severity, "error"))) {
            primary_message = message;
            primary_line = start.line;
            primary_column = start.column;
            primary_severity = severity;
            primary_path = uri;
        }
    }

    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "finding_count", .{ .integer = @intCast(findings.items.len) });
    try obj.put(allocator, "error_count", .{ .integer = error_count });
    try obj.put(allocator, "warning_count", .{ .integer = warning_count });
    try obj.put(allocator, "info_count", .{ .integer = info_count });
    try obj.put(allocator, "findings", .{ .array = findings });
    if (primary_message) |message| {
        var primary = std.json.ObjectMap.empty;
        try primary.put(allocator, "source", .{ .string = "zls" });
        try primary.put(allocator, "severity", .{ .string = primary_severity });
        try primary.put(allocator, "message", try ownedString(allocator, message));
        if (primary_path) |path| {
            try primary.put(allocator, "uri", try ownedString(allocator, path));
        } else {
            try primary.put(allocator, "uri", .null);
        }
        if (primary_line) |line_no| {
            try primary.put(allocator, "line", .{ .integer = line_no });
        } else {
            try primary.put(allocator, "line", .null);
        }
        if (primary_column) |col_no| {
            try primary.put(allocator, "column", .{ .integer = col_no });
        } else {
            try primary.put(allocator, "column", .null);
        }
        try obj.put(allocator, "primary", .{ .object = primary });
        try obj.put(allocator, "category", .{ .string = classifyDiagnosticMessage(message) });
        try obj.put(allocator, "next_actions", try lspNextActions(allocator, primary_path, primary_line, primary_column, primary_severity, message));
    } else {
        try obj.put(allocator, "primary", .null);
        try obj.put(allocator, "category", .{ .string = "none" });
        try obj.put(allocator, "next_actions", .{ .array = std.json.Array.init(allocator) });
    }
    return .{ .object = obj };
}

pub const LspStart = struct {
    line: ?i64 = null,
    column: ?i64 = null,
};

pub fn lspDiagnosticStart(range_value: std.json.Value) LspStart {
    const range_obj = switch (range_value) {
        .object => |o| o,
        else => return .{},
    };
    const start_obj = switch (range_obj.get("start") orelse .null) {
        .object => |o| o,
        else => return .{},
    };
    const line_no = switch (start_obj.get("line") orelse .null) {
        .integer => |i| i + 1,
        else => null,
    };
    const col_no = switch (start_obj.get("character") orelse .null) {
        .integer => |i| i + 1,
        else => null,
    };
    return .{ .line = line_no, .column = col_no };
}

pub fn lspSeverityName(code: i64) []const u8 {
    return switch (code) {
        1 => "error",
        2 => "warning",
        3 => "info",
        4 => "hint",
        else => "info",
    };
}

pub fn lspNextActions(allocator: std.mem.Allocator, uri: ?[]const u8, line_no: ?i64, col_no: ?i64, severity: []const u8, message: []const u8) !std.json.Value {
    var actions = std.json.Array.init(allocator);
    if (uri) |u| {
        if (line_no) |line_value| {
            if (col_no) |col_value| {
                try actions.append(.{ .string = try std.fmt.allocPrint(allocator, "Open {s}:{d}:{d} and address the primary ZLS {s}: {s}", .{ u, line_value, col_value, severity, message }) });
            } else {
                try actions.append(.{ .string = try std.fmt.allocPrint(allocator, "Open {s}:{d} and address the primary ZLS {s}: {s}", .{ u, line_value, severity, message }) });
            }
        } else {
            try actions.append(.{ .string = try std.fmt.allocPrint(allocator, "Inspect {s} and address the primary ZLS {s}: {s}", .{ u, severity, message }) });
        }
    } else {
        try actions.append(.{ .string = try std.fmt.allocPrint(allocator, "Address the primary ZLS {s}: {s}", .{ severity, message }) });
    }
    try actions.append(try ownedString(allocator, "Rerun zig_diagnostics after the focused edit."));
    return .{ .array = actions };
}

pub fn lspStructuredValue(allocator: std.mem.Allocator, method: []const u8, response: []const u8) !std.json.Value {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, response, .{});
    defer parsed.deinit();

    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "method", .{ .string = method });

    const response_obj = switch (parsed.value) {
        .object => |o| o,
        else => {
            try obj.put(allocator, "ok", .{ .bool = false });
            try obj.put(allocator, "raw", try json_result.cloneValue(allocator, parsed.value));
            return .{ .object = obj };
        },
    };

    if (response_obj.get("error")) |err_value| {
        try obj.put(allocator, "ok", .{ .bool = false });
        try obj.put(allocator, "error", try json_result.cloneValue(allocator, err_value));
    } else {
        try obj.put(allocator, "ok", .{ .bool = true });
        const result = response_obj.get("result") orelse .null;
        try obj.put(allocator, "result", try json_result.cloneValue(allocator, result));
        if (std.mem.eql(u8, method, "textDocument/diagnostic")) {
            try obj.put(allocator, "diagnostics", try lspDiagnosticsInsightsValue(allocator, result));
        }
    }
    return .{ .object = obj };
}

pub fn lspStructuredTool(allocator: std.mem.Allocator, method: []const u8, response: []const u8) mcp.tools.ToolError!mcp.tools.ToolResult {
    const value = lspStructuredValue(allocator, method, response) catch |err| return toolErrorFromError(allocator, .{
        .tool = method,
        .operation = method,
        .phase = "parse_response",
        .code = "malformed_backend_response",
        .category = "lsp",
        .resolution = "Retry after checking the ZLS session; the backend response could not be parsed as structured JSON.",
    }, err);
    return structured(allocator, value);
}

pub fn lspHasError(allocator: std.mem.Allocator, response: []const u8) bool {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, response, .{}) catch return true;
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return true,
    };
    return obj.get("error") != null;
}
pub fn responseResult(value: std.json.Value) ?std.json.Value {
    const obj = switch (value) {
        .object => |o| o,
        else => return null,
    };
    return obj.get("result");
}
pub fn appendWorkspaceFormatCheckCommand(allocator: std.mem.Allocator, a: *App, commands: *std.json.Array) !void {
    const candidates = [_][]const u8{ "build.zig", "build.zig.zon", "src" };
    var command_text: std.ArrayList(u8) = .empty;
    defer command_text.deinit(allocator);
    try command_text.appendSlice(allocator, "zig fmt --check");
    var appended_path = false;
    for (candidates) |candidate| {
        if (!workspacePathExists(allocator, a, candidate)) continue;
        try command_text.print(allocator, " {s}", .{candidate});
        appended_path = true;
    }
    if (appended_path) try appendUniqueCommand(allocator, commands, command_text.items);
}

pub fn appendUniqueCommand(allocator: std.mem.Allocator, commands: *std.json.Array, command_text: []const u8) !void {
    for (commands.items) |item| {
        const existing = switch (item) {
            .string => |s| s,
            else => continue,
        };
        if (std.mem.eql(u8, existing, command_text)) return;
    }
    try commands.append(try ownedString(allocator, command_text));
}

pub fn zigEnvValue(a: *App, allocator: std.mem.Allocator, key: []const u8) ![]u8 {
    const result = try command.run(allocator, a.io, a.workspace.root, &.{ a.config.zig_path, "env" }, a.config.timeout_ms);
    defer result.deinit(allocator);
    const needle = try std.fmt.allocPrint(allocator, ".{s} = \"", .{key});
    defer allocator.free(needle);
    const start_needle = std.mem.indexOf(u8, result.stdout, needle) orelse return error.NotFound;
    const start = start_needle + needle.len;
    const end = std.mem.indexOfScalarPos(u8, result.stdout, start, '"') orelse return error.NotFound;
    return allocator.dupe(u8, result.stdout[start..end]);
}

pub fn makeArgs2(allocator: std.mem.Allocator, key1: []const u8, value1: []const u8, key2: []const u8, value2: i64) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, key1, .{ .string = value1 });
    try obj.put(allocator, key2, .{ .integer = value2 });
    return .{ .object = obj };
}

pub fn freeArgList(allocator: std.mem.Allocator, args: []const []const u8) void {
    for (args) |arg| allocator.free(arg);
    allocator.free(args);
}
