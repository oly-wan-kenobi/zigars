const std = @import("std");
const mcp = @import("mcp");
const zigar = @import("zigar");

const command = zigar.command;
const json_result = zigar.json_result;
const zls_session = zigar.zls_session;
const core = @import("shared_core.zig");
const zls_document = @import("zls_document.zig");
const zls_diagnostics_values = @import("zls_diagnostics_values.zig");
const zls_status = @import("zls_status.zig");

const App = core.App;
const structured = core.structured;
const argString = core.argString;
const workspacePathErrorResult = core.workspacePathErrorResult;
const backendErrorResult = core.backendErrorResult;
const missingArgumentResult = core.missingArgumentResult;
const invalidArgumentResult = core.invalidArgumentResult;
const toolErrorFromError = core.toolErrorFromError;
const splitToolArgs = core.splitToolArgs;
const splitToolArgsErrorResult = core.splitToolArgsErrorResult;
const ownedString = core.ownedString;
const workspacePathExists = core.workspacePathExists;
const zlsUnavailable = core.zlsUnavailable;

pub const ZlsDocumentSource = zls_document.Source;
pub const ZlsDocument = zls_document.Document;
pub const zlsDocumentFromArgs = zls_document.fromArgs;
pub const metricsValue = zls_status.metricsValue;
pub const analysisCacheStatusValue = zls_status.analysisCacheStatusValue;
pub const zlsStatusValue = zls_status.zlsStatusValue;
pub const zlsDocumentStateSummaryValue = zls_status.zlsDocumentStateSummaryValue;
pub const LspStart = zls_diagnostics_values.LspStart;
pub const lspDiagnosticsInsightsValue = zls_diagnostics_values.lspDiagnosticsInsightsValue;
pub const lspDiagnosticStart = zls_diagnostics_values.lspDiagnosticStart;
pub const lspSeverityName = zls_diagnostics_values.lspSeverityName;
pub const lspNextActions = zls_diagnostics_values.lspNextActions;

pub fn unsupportedCapability(allocator: std.mem.Allocator, method: []const u8, capability: []const u8) mcp.tools.ToolError!mcp.tools.ToolResult {
    var obj = std.json.ObjectMap.empty;
    defer obj.deinit(allocator);
    obj.put(allocator, "ok", .{ .bool = false }) catch return error.OutOfMemory;
    obj.put(allocator, "kind", .{ .string = "zls_unsupported_capability" }) catch return error.OutOfMemory;
    obj.put(allocator, "backend", .{ .string = "zls" }) catch return error.OutOfMemory;
    obj.put(allocator, "method", .{ .string = method }) catch return error.OutOfMemory;
    obj.put(allocator, "capability", .{ .string = capability }) catch return error.OutOfMemory;
    obj.put(allocator, "category", .{ .string = "lsp_capability" }) catch return error.OutOfMemory;
    obj.put(allocator, "error", .{ .string = "ZLS did not advertise this capability" }) catch return error.OutOfMemory;
    obj.put(allocator, "resolution", .{ .string = "Upgrade or reconfigure ZLS, or choose a tool that does not require this LSP capability." }) catch return error.OutOfMemory;
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

pub const ZlsCapabilityState = union(enum) {
    no_capability_required,
    unavailable: []const u8,
    supported,
    unsupported: []const u8,
};

pub fn zlsCapabilityState(a: *App, allocator: std.mem.Allocator, method: []const u8) ZlsCapabilityState {
    const capability = zlsCapabilityName(method) orelse return .no_capability_required;
    if (a.lsp_client == null) return .{ .unavailable = capability };
    const response = a.zls_initialize_response orelse return .{ .unavailable = capability };
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, response, .{}) catch return .{ .unavailable = capability };
    defer parsed.deinit();
    const result = responseResult(parsed.value) orelse return .{ .unavailable = capability };
    const result_obj = switch (result) {
        .object => |o| o,
        else => return .{ .unavailable = capability },
    };
    const caps = switch (result_obj.get("capabilities") orelse .null) {
        .object => |o| o,
        else => return .{ .unavailable = capability },
    };
    const value = caps.get(capability) orelse return .{ .unsupported = capability };
    return switch (value) {
        .bool => |b| if (b) .supported else .{ .unsupported = capability },
        .object, .array => .supported,
        else => .{ .unsupported = capability },
    };
}

pub fn zlsSupportsCapability(a: *App, allocator: std.mem.Allocator, method: []const u8) bool {
    return switch (zlsCapabilityState(a, allocator, method)) {
        .no_capability_required, .supported => true,
        .unavailable, .unsupported => false,
    };
}

pub fn requireZlsCapability(a: *App, allocator: std.mem.Allocator, method: []const u8) ?mcp.tools.ToolResult {
    return switch (zlsCapabilityState(a, allocator, method)) {
        .no_capability_required, .supported => null,
        .unavailable => zlsUnavailable(a, allocator) catch null,
        .unsupported => |capability| unsupportedCapability(allocator, method, capability) catch null,
    };
}

pub const ExplainCommand = struct {
    argv: std.ArrayList([]const u8),
    owned_paths: std.ArrayList([]const u8),
    mode: []const u8,
};

const ExplainCommandError = mcp.tools.ToolError || error{ WorkspacePathRejected, MissingFile, UnsupportedCommand, InvalidExtraArgs };

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
        const file = argString(args, "file") orelse return error.MissingFile;
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
        return error.UnsupportedCommand;
    }

    const raw_extra_args = argString(args, "args") orelse "";
    const extra = splitToolArgs(allocator, raw_extra_args) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidExtraArgs,
    };
    var extra_transferred = false;
    defer if (!extra_transferred) freeArgList(allocator, extra);
    list.appendSlice(allocator, extra) catch return error.OutOfMemory;
    owned_paths.appendSlice(allocator, extra) catch return error.OutOfMemory;
    allocator.free(extra);
    extra_transferred = true;
    return .{ .argv = list, .owned_paths = owned_paths, .mode = mode };
}

pub fn explainCommandSetupError(a: *App, allocator: std.mem.Allocator, tool_name: []const u8, args: ?std.json.Value, err: anyerror) mcp.tools.ToolError!mcp.tools.ToolResult {
    return switch (err) {
        error.WorkspacePathRejected => if (argString(args, "file")) |file|
            workspacePathErrorResult(a, allocator, tool_name, file, error.PathOutsideWorkspace)
        else
            error.PermissionDenied,
        error.MissingFile => missingArgumentResult(allocator, tool_name, "file", "workspace-relative Zig source path"),
        error.UnsupportedCommand => invalidArgumentResult(allocator, tool_name, "command", "check|test|build|build-test|fmt-check", argString(args, "command") orelse "<invalid args>", "Use one of the supported command modes, or omit command to let zigar choose build-test/check from the provided arguments."),
        error.InvalidExtraArgs => splitToolArgsErrorResult(allocator, tool_name, "args", argString(args, "args") orelse "", error.InvalidArguments),
        error.OutOfMemory => error.OutOfMemory,
        else => toolErrorFromError(allocator, .{
            .tool = tool_name,
            .operation = "prepare_zig_command",
            .phase = "command_setup",
            .code = "command_setup_failed",
            .category = "argument",
            .resolution = "Inspect command, file, and args fields, then retry with valid workspace paths and shell-style extra arguments.",
        }, err),
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
    const file = argString(args, "file") orelse return error.MissingFile;
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
        error.InvalidArguments, error.MissingFile => return missingArgumentResult(allocator, operation, "file", "string"),
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
