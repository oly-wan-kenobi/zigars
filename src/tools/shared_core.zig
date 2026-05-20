const std = @import("std");
const mcp = @import("mcp");
const zigar = @import("zigar");

const analysis = zigar.analysis;
const command = zigar.command;
const doctor = zigar.doctor;
const json_result = zigar.json_result;
const runtime_mod = zigar.runtime;
const tool_errors = zigar.tool_errors;
const command_result = @import("command_result.zig");

pub const App = runtime_mod.App;
pub const BackendProbeCache = runtime_mod.BackendProbeCache;
pub const LspClient = zigar.lsp_client.LspClient;
pub const source_read_limit = zigar.document_state.DocumentState.default_max_document_bytes;

pub fn scratchApp(a: *App, allocator: std.mem.Allocator) App {
    var copy = a.*;
    copy.allocator = allocator;
    copy.workspace.allocator = allocator;
    return copy;
}

pub const commandTermValue = command_result.commandTermValue;
pub const commandResultValue = command_result.commandResultValue;
pub const commandErrorValue = command_result.commandErrorValue;
pub const failureSummaryValue = command_result.failureSummaryValue;
pub const commandErrorSummaryValue = command_result.commandErrorSummaryValue;
pub const likelyFailureScopeValue = command_result.likelyFailureScopeValue;
pub const CompilerLine = command_result.CompilerLine;
pub const compilerInsightsValue = command_result.compilerInsightsValue;
pub const collectCompilerLines = command_result.collectCompilerLines;
pub const parseCompilerLine = command_result.parseCompilerLine;
pub const parseLocatedCompilerLine = command_result.parseLocatedCompilerLine;
pub const compilerLineValue = command_result.compilerLineValue;
pub const classifyDiagnosticMessage = command_result.classifyDiagnosticMessage;
pub const compilerNextCommand = command_result.compilerNextCommand;
pub const compilerNextActions = command_result.compilerNextActions;
pub const commandString = command_result.commandString;
pub const argvContains = command_result.argvContains;
pub const argvValue = command_result.argvValue;

pub fn structured(allocator: std.mem.Allocator, value: std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return json_result.structured(allocator, value);
}

pub fn structuredOwned(allocator: std.mem.Allocator, value: std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return json_result.structuredOwned(allocator, value);
}

pub fn putOwnedKey(allocator: std.mem.Allocator, obj: *std.json.ObjectMap, key: []const u8, value: std.json.Value) !void {
    const owned_key = try allocator.dupe(u8, key);
    errdefer allocator.free(owned_key);
    try obj.put(allocator, owned_key, value);
}

pub fn argString(args: ?std.json.Value, name: []const u8) ?[]const u8 {
    return mcp.tools.getString(args, name);
}

pub fn argBool(args: ?std.json.Value, name: []const u8, default: bool) bool {
    return mcp.tools.getBoolean(args, name) orelse default;
}

pub fn argInt(args: ?std.json.Value, name: []const u8, default: i64) i64 {
    return mcp.tools.getInteger(args, name) orelse default;
}

pub fn workspacePathErrorResult(a: *App, allocator: std.mem.Allocator, tool_name: []const u8, path: []const u8, err: anyerror) mcp.tools.ToolError!mcp.tools.ToolResult {
    switch (err) {
        error.PathOutsideWorkspace, error.EmptyPath => return tool_errors.workspacePath(allocator, tool_name, path, a.workspace.root, err),
        error.InvalidArguments => return tool_errors.invalidArgument(
            allocator,
            tool_name,
            "path",
            "workspace-relative path",
            path,
            "Pass a non-empty path string that resolves inside the configured zigar workspace.",
        ),
        error.NotConnected => return zlsUnavailable(a, allocator),
        error.DocumentTooLarge => return tool_errors.fromError(allocator, .{
            .tool = tool_name,
            .operation = "sync_document",
            .phase = "document_size_limit",
            .code = "document_too_large",
            .category = "document_state",
            .resolution = "Save the file on disk and call a file-based tool, or send a smaller unsaved document.",
            .details = &.{.{ .key = "path", .value = .{ .string = path } }},
        }, err),
        error.OpenDocumentLimitExceeded => return tool_errors.fromError(allocator, .{
            .tool = tool_name,
            .operation = "sync_document",
            .phase = "open_document_limit",
            .code = "open_document_limit_exceeded",
            .category = "document_state",
            .resolution = "Close unused documents with zig_document_close and retry.",
            .details = &.{.{ .key = "path", .value = .{ .string = path } }},
        }, err),
        else => return tool_errors.fromError(allocator, .{
            .tool = tool_name,
            .operation = "resolve_workspace_path",
            .phase = "resolve_path",
            .code = "path_resolution_failed",
            .category = "workspace_path",
            .resolution = "Confirm the path exists inside the configured zigar workspace and retry.",
            .details = &.{.{ .key = "path", .value = .{ .string = path } }},
        }, err),
    }
}

pub const toolErrorResult = tool_errors.result;
pub const toolErrorFromError = tool_errors.fromError;
pub const missingArgumentResult = tool_errors.missingArgument;
pub const invalidArgumentResult = tool_errors.invalidArgument;

pub fn splitToolArgsErrorResult(allocator: std.mem.Allocator, tool_name: []const u8, field: []const u8, actual: []const u8, err: anyerror) mcp.tools.ToolError!mcp.tools.ToolResult {
    return switch (err) {
        error.InvalidArguments => tool_errors.invalidArgument(
            allocator,
            tool_name,
            field,
            "shell-style argument string",
            actual,
            "Quote arguments the same way you would in a shell command, or omit the field when no extra arguments are needed.",
        ),
        error.OutOfMemory => error.OutOfMemory,
        else => tool_errors.fromError(allocator, .{
            .tool = tool_name,
            .operation = "parse_arguments",
            .phase = "split_extra_arguments",
            .code = "argument_parse_failed",
            .category = "argument",
            .resolution = "Inspect the extra argument string and retry with valid shell-style quoting.",
            .details = &.{
                .{ .key = "field", .value = .{ .string = field } },
                .{ .key = "actual", .value = .{ .string = actual } },
            },
        }, err),
    };
}

pub fn workspacePathErrorMessage(allocator: std.mem.Allocator, tool_name: []const u8, path: []const u8, root: []const u8, err: anyerror) ![]u8 {
    if (err == error.EmptyPath) {
        return std.fmt.allocPrint(
            allocator,
            "{s}: rejected an empty path.\n\nRun zigar_workspace_info to confirm the active workspace `{s}`. Pass a workspace-relative path, or restart/configure zigar with --workspace set to the Zig project you are editing.",
            .{ tool_name, root },
        );
    }
    return std.fmt.allocPrint(
        allocator,
        "{s}: rejected path `{s}` because it is outside the configured zigar workspace `{s}`.\n\nRun zigar_workspace_info to confirm the active workspace. Pass a workspace-relative path, or restart/configure zigar with --workspace set to the Zig project you are editing.",
        .{ tool_name, path, root },
    );
}

pub fn runAndFormat(a: *App, allocator: std.mem.Allocator, argv: []const []const u8, title: []const u8) mcp.tools.ToolError!mcp.tools.ToolResult {
    return runAndFormatTimeout(a, allocator, argv, title, a.config.timeout_ms);
}

pub fn runAndFormatTimeout(a: *App, allocator: std.mem.Allocator, argv: []const []const u8, title: []const u8, timeout_ms: i64) mcp.tools.ToolError!mcp.tools.ToolResult {
    a.command_calls += 1;
    const result = command.run(allocator, a.io, a.workspace.root, argv, timeout_ms) catch |err| {
        a.tool_errors += 1;
        const value = commandErrorValue(allocator, title, argv, a.workspace.root, timeout_ms, err) catch return error.OutOfMemory;
        return structured(allocator, value);
    };
    defer result.deinit(allocator);
    const value = commandResultValue(allocator, title, argv, a.workspace.root, timeout_ms, result) catch return error.OutOfMemory;
    return structured(allocator, value);
}

pub fn toolTimeout(a: *App, args: ?std.json.Value) i64 {
    return @max(1, @min(argInt(args, "timeout_ms", a.config.timeout_ms), 60 * 60 * 1000));
}

pub fn backendErrorKind(err: anyerror) []const u8 {
    return switch (err) {
        error.RequestTimeout, error.Timeout => "timeout",
        error.NotConnected, error.EndOfStream, error.BrokenPipe => "unavailable",
        error.FileNotFound => "executable_not_found",
        error.AccessDenied, error.PermissionDenied => "permission",
        error.StreamTooLong => "output_limit",
        else => command.errorKind(err),
    };
}

pub fn backendErrorValue(allocator: std.mem.Allocator, backend_name: []const u8, operation: []const u8, err: anyerror, resolution: []const u8) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "backend_error" });
    try obj.put(allocator, "ok", .{ .bool = false });
    try obj.put(allocator, "backend", .{ .string = backend_name });
    try obj.put(allocator, "operation", .{ .string = operation });
    try obj.put(allocator, "error", .{ .string = @errorName(err) });
    try obj.put(allocator, "error_kind", .{ .string = backendErrorKind(err) });
    try obj.put(allocator, "resolution", .{ .string = resolution });
    return .{ .object = obj };
}

pub fn backendErrorResult(allocator: std.mem.Allocator, backend_name: []const u8, operation: []const u8, err: anyerror, resolution: []const u8) mcp.tools.ToolError!mcp.tools.ToolResult {
    var value = backendErrorValue(allocator, backend_name, operation, err, resolution) catch return error.OutOfMemory;
    defer switch (value) {
        .object => |*obj| obj.deinit(allocator),
        else => {},
    };
    return structured(allocator, value);
}

pub fn backendUnavailableResult(allocator: std.mem.Allocator, backend_name: []const u8, operation: []const u8, configured_path: []const u8, status: []const u8, resolution: []const u8) mcp.tools.ToolError!mcp.tools.ToolResult {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    defer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "backend_error" });
    try obj.put(allocator, "ok", .{ .bool = false });
    try obj.put(allocator, "backend", .{ .string = backend_name });
    try obj.put(allocator, "operation", .{ .string = operation });
    try obj.put(allocator, "error", .{ .string = "Unavailable" });
    try obj.put(allocator, "error_kind", .{ .string = "unavailable" });
    try obj.put(allocator, "configured_path", .{ .string = configured_path });
    try obj.put(allocator, "status", .{ .string = status });
    try obj.put(allocator, "resolution", .{ .string = resolution });
    return structured(allocator, .{ .object = obj });
}

pub fn splitToolArgs(allocator: std.mem.Allocator, text_value: ?[]const u8) mcp.tools.ToolError![]const []const u8 {
    return command.splitArgs(allocator, text_value) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidArguments => error.InvalidArguments,
    };
}

pub fn structuredText(allocator: std.mem.Allocator, kind: []const u8, body: []const u8) mcp.tools.ToolError!mcp.tools.ToolResult {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    defer obj.deinit(allocator);
    obj.put(allocator, "kind", .{ .string = kind }) catch return error.OutOfMemory;
    obj.put(allocator, "text", .{ .string = body }) catch return error.OutOfMemory;
    return structured(allocator, .{ .object = obj });
}

pub fn jsonTextOnly(allocator: std.mem.Allocator, bytes: []u8) mcp.tools.ToolError!mcp.tools.ToolResult {
    errdefer allocator.free(bytes);
    const content = allocator.alloc(mcp.types.ContentBlock, 1) catch return error.OutOfMemory;
    content[0] = .{ .text = .{ .text = bytes } };
    return .{ .content = content };
}

pub fn probeBackend(a: *App, allocator: std.mem.Allocator, name: []const u8, argv: []const []const u8, timeout_ms: i64) doctor.Probe {
    if (backendProbeSlot(a, name)) |slot| {
        if (slot.*) |probe| return probe;
        const probe = probeBackendDirect(allocator, a, argv, timeout_ms);
        slot.* = probe;
        return probe;
    }
    return probeBackendDirect(allocator, a, argv, timeout_ms);
}

pub fn backendProbeSlot(a: *App, name: []const u8) ?*?doctor.Probe {
    if (std.mem.eql(u8, name, "zig")) return &a.backend_probe_cache.zig;
    if (std.mem.eql(u8, name, "zls")) return &a.backend_probe_cache.zls;
    if (std.mem.eql(u8, name, "zwanzig")) return &a.backend_probe_cache.zwanzig;
    if (std.mem.eql(u8, name, "zflame")) return &a.backend_probe_cache.zflame;
    if (std.mem.eql(u8, name, "diff-folded")) return &a.backend_probe_cache.diff_folded;
    return null;
}

pub fn probeBackendDirect(allocator: std.mem.Allocator, a: *App, argv: []const []const u8, timeout_ms: i64) doctor.Probe {
    const result = command.run(allocator, a.io, a.workspace.root, argv, timeout_ms) catch |err| {
        return .{ .ok = false, .status = @errorName(err), .resolution = "confirm the configured backend path and executable permissions" };
    };
    defer result.deinit(allocator);
    if (result.succeeded()) {
        return .{ .ok = true, .status = "ok", .resolution = "backend command completed" };
    }
    return .{ .ok = false, .status = command.termText(result.term), .resolution = "backend command exited non-zero; run the configured command directly to inspect stderr" };
}

pub fn backendProbeCacheValue(allocator: std.mem.Allocator, cache: BackendProbeCache) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "zig", try cachedProbeValue(allocator, cache.zig));
    try obj.put(allocator, "zls", try cachedProbeValue(allocator, cache.zls));
    try obj.put(allocator, "zwanzig", try cachedProbeValue(allocator, cache.zwanzig));
    try obj.put(allocator, "zflame", try cachedProbeValue(allocator, cache.zflame));
    try obj.put(allocator, "diff_folded", try cachedProbeValue(allocator, cache.diff_folded));
    return .{ .object = obj };
}

pub fn cachedProbeValue(allocator: std.mem.Allocator, probe: ?doctor.Probe) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    if (probe) |p| {
        try obj.put(allocator, "probed", .{ .bool = true });
        try obj.put(allocator, "ok", .{ .bool = p.ok });
        try obj.put(allocator, "status", .{ .string = p.status });
        try obj.put(allocator, "resolution", .{ .string = p.resolution });
    } else {
        try obj.put(allocator, "probed", .{ .bool = false });
        try obj.put(allocator, "ok", .null);
        try obj.put(allocator, "status", .{ .string = "not probed" });
        try obj.put(allocator, "resolution", .{ .string = "call zigar_doctor with probe_backends=true to cache backend availability" });
    }
    return .{ .object = obj };
}

pub fn ownedString(allocator: std.mem.Allocator, value: []const u8) !std.json.Value {
    return .{ .string = try allocator.dupe(u8, value) };
}
pub fn statusLinePath(line: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, if (line.len > 3) line[3..] else "", " \t");
    if (std.mem.indexOf(u8, trimmed, " -> ")) |arrow| return trimmed[arrow + " -> ".len ..];
    return trimmed;
}

pub fn workspacePathExists(allocator: std.mem.Allocator, a: *App, path: []const u8) bool {
    const resolved = a.workspace.resolve(path) catch return false;
    defer allocator.free(resolved);
    var dir = std.Io.Dir.openDirAbsolute(a.io, resolved, .{}) catch {
        var file = std.Io.Dir.cwd().openFile(a.io, resolved, .{}) catch return false;
        file.close(a.io);
        return true;
    };
    dir.close(a.io);
    return true;
}

pub fn changedPathList(allocator: std.mem.Allocator, a: *App, explicit_files: ?[]const u8, timeout_ms: i64) !std.ArrayList([]const u8) {
    var list = std.ArrayList([]const u8).empty;
    errdefer {
        freeStringList(allocator, list.items);
        list.deinit(allocator);
    }
    try appendPathTokens(allocator, &list, explicit_files);
    if (list.items.len > 0) return list;
    const result = command.run(allocator, a.io, a.workspace.root, &.{ "git", "status", "--porcelain" }, @min(timeout_ms, 5000)) catch return list;
    defer result.deinit(allocator);
    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    while (lines.next()) |line| {
        if (line.len < 4) continue;
        const path = statusLinePath(line);
        if (path.len == 0 or analysis.skipWorkspacePath(path)) continue;
        try appendUniqueString(allocator, &list, path);
    }
    return list;
}

pub fn appendPathTokens(allocator: std.mem.Allocator, list: *std.ArrayList([]const u8), text_value: ?[]const u8) !void {
    const text_input = text_value orelse return;
    var tokens = std.mem.tokenizeAny(u8, text_input, ", \t\r\n");
    while (tokens.next()) |token| {
        if (token.len == 0) continue;
        try appendUniqueString(allocator, list, token);
    }
}

pub fn appendPatchPaths(allocator: std.mem.Allocator, list: *std.ArrayList([]const u8), patch_text: ?[]const u8) !void {
    const patch = patch_text orelse return;
    var lines = std.mem.splitScalar(u8, patch, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (std.mem.startsWith(u8, trimmed, "+++ ")) {
            try appendPatchPathToken(allocator, list, std.mem.trim(u8, trimmed["+++ ".len..], " \t"));
        } else if (std.mem.startsWith(u8, trimmed, "--- ")) {
            try appendPatchPathToken(allocator, list, std.mem.trim(u8, trimmed["--- ".len..], " \t"));
        } else if (std.mem.startsWith(u8, trimmed, "diff --git ")) {
            var parts = std.mem.tokenizeScalar(u8, trimmed, ' ');
            _ = parts.next();
            _ = parts.next();
            if (parts.next()) |left| try appendPatchPathToken(allocator, list, left);
            if (parts.next()) |right| try appendPatchPathToken(allocator, list, right);
        }
    }
}

pub fn appendPatchPathToken(allocator: std.mem.Allocator, list: *std.ArrayList([]const u8), raw: []const u8) !void {
    var path = raw;
    if (std.mem.startsWith(u8, path, "a/") or std.mem.startsWith(u8, path, "b/")) path = path[2..];
    if (std.mem.eql(u8, path, "/dev/null")) return;
    try appendUniqueString(allocator, list, path);
}

pub fn appendUniqueString(allocator: std.mem.Allocator, list: *std.ArrayList([]const u8), value: []const u8) !void {
    if (stringListContains(list.items, value)) return;
    try list.append(allocator, try allocator.dupe(u8, value));
}

pub fn stringListContains(list: []const []const u8, value: []const u8) bool {
    for (list) |item| {
        if (std.mem.eql(u8, item, value)) return true;
    }
    return false;
}

pub fn freeStringList(allocator: std.mem.Allocator, list: []const []const u8) void {
    for (list) |item| allocator.free(item);
}

pub fn jsonArrayLen(value: std.json.Value) usize {
    return switch (value) {
        .array => |a| a.items.len,
        else => 0,
    };
}

pub fn asciiLowerAllocLocal(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    const out = try allocator.dupe(u8, input);
    for (out) |*ch| ch.* = std.ascii.toLower(ch.*);
    return out;
}

pub fn lineNumberLocal(text_value: []const u8, index: usize) usize {
    var line: usize = 1;
    for (text_value[0..@min(index, text_value.len)]) |ch| {
        if (ch == '\n') line += 1;
    }
    return line;
}

pub fn lineAtLocal(text_value: []const u8, index: usize) []const u8 {
    const safe_index = @min(index, text_value.len);
    const start = std.mem.lastIndexOfScalar(u8, text_value[0..safe_index], '\n') orelse 0;
    const end = std.mem.indexOfScalarPos(u8, text_value, safe_index, '\n') orelse text_value.len;
    return std.mem.trim(u8, text_value[if (start == 0) 0 else start + 1..end], " \t\r\n");
}

pub fn zlsUnavailable(a: *App, allocator: std.mem.Allocator) mcp.tools.ToolError!mcp.tools.ToolResult {
    var obj = std.json.ObjectMap.empty;
    defer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "backend_error" });
    try obj.put(allocator, "ok", .{ .bool = false });
    try obj.put(allocator, "backend", .{ .string = "zls" });
    try obj.put(allocator, "operation", .{ .string = "lsp_session" });
    try obj.put(allocator, "error", .{ .string = "Unavailable" });
    try obj.put(allocator, "error_kind", .{ .string = "unavailable" });
    try obj.put(allocator, "configured_path", .{ .string = a.config.zls_path });
    try obj.put(allocator, "status", .{ .string = a.zls_status });
    try obj.put(allocator, "restart_attempts", .{ .integer = @intCast(a.zls_restart_attempts) });
    if (a.zls_last_failure) |failure| {
        try obj.put(allocator, "last_failure", .{ .string = failure });
    } else {
        try obj.put(allocator, "last_failure", .null);
    }
    try obj.put(allocator, "resolution", .{ .string = "confirm --zls-path points to a ZLS build compatible with the configured Zig version, then restart the MCP client" });
    return structured(allocator, .{ .object = obj });
}
