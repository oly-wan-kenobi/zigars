const std = @import("std");
const mcp = @import("mcp");
const zigar = @import("zigar");

const common = @import("common.zig");
const core = @import("core.zig");

const command = zigar.command;
const App = common.App;
const LspClient = common.LspClient;
const argInt = common.argInt;
const argString = common.argString;
const commandResultValue = common.commandResultValue;
const lspHasError = common.lspHasError;
const lspStructuredTool = common.lspStructuredTool;
const lspStructuredValue = common.lspStructuredValue;
const lspDiagnosticsInsightsValue = common.lspDiagnosticsInsightsValue;
const lspToolError = common.lspToolError;
const missingArgumentResult = common.missingArgumentResult;
const structured = common.structured;
const structuredText = common.structuredText;
const toolTimeout = common.toolTimeout;
const workspacePathErrorResult = common.workspacePathErrorResult;
const zigCheck = core.zigCheck;
const zlsFileUriFromArgs = common.zlsFileUriFromArgs;
const zlsSetupErrorResult = common.zlsSetupErrorResult;

pub fn waitForDiagnostics(a: *App, client: *LspClient, file_uri: []const u8, wait_ms: i64) void {
    var elapsed: i64 = 0;
    while (elapsed <= wait_ms) : (elapsed += 50) {
        if (cachedDiagnosticsOrNull(a, a.allocator, client, file_uri, "wait_for_diagnostics")) |diagnostics| {
            a.allocator.free(diagnostics);
            return;
        }
        if (elapsed == wait_ms) return;
        const step_ms = @min(@as(i64, 50), wait_ms - elapsed);
        if (step_ms <= 0) return;
        std.Io.Timeout.sleep(.{ .duration = .{ .raw = std.Io.Duration.fromMilliseconds(step_ms), .clock = .awake } }, a.io) catch |err| {
            a.logger.debug("zls", "diagnostics wait sleep failed: {}", .{err});
            return;
        };
    }
}

pub fn diagnosticPullOrNull(a: *App, allocator: std.mem.Allocator, client: *LspClient, file_uri: []const u8, tool: []const u8) ?[]const u8 {
    const Params = struct { textDocument: struct { uri: []const u8 } };
    return client.sendRequest(allocator, "textDocument/diagnostic", Params{ .textDocument = .{ .uri = file_uri } }) catch |err| {
        a.logger.debug("zls", "{s}: textDocument/diagnostic unavailable for {s}: {}", .{ tool, file_uri, err });
        return null;
    };
}

pub fn cachedDiagnosticsOrNull(a: *App, allocator: std.mem.Allocator, client: *LspClient, file_uri: []const u8, tool: []const u8) ?[]const u8 {
    return client.getDiagnostics(allocator, file_uri) catch |err| {
        a.logger.debug("zls", "{s}: diagnostics cache unavailable for {s}: {}", .{ tool, file_uri, err });
        return null;
    };
}

pub fn diagnosticWaitMs(args: ?std.json.Value) i64 {
    return @max(0, @min(argInt(args, "wait_ms", 500), 5000));
}

pub fn zigDiagnostics(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const file = argString(args, "file") orelse return missingArgumentResult(allocator, "zig_diagnostics", "file", "string");
    const file_uri = zlsFileUriFromArgs(a, allocator, args) catch |err| return zlsSetupErrorResult(a, allocator, "zig_diagnostics", file, err);
    defer allocator.free(file_uri);
    const client = a.lsp_client orelse return zigCheck(a, allocator, args);

    const pull = diagnosticPullOrNull(a, allocator, client, file_uri, "zig_diagnostics");
    if (pull) |response| {
        defer allocator.free(response);
        if (!lspHasError(allocator, response)) {
            return lspStructuredTool(allocator, "textDocument/diagnostic", response);
        }
    }

    const wait_ms = diagnosticWaitMs(args);
    waitForDiagnostics(a, client, file_uri, wait_ms);
    if (cachedDiagnosticsOrNull(a, allocator, client, file_uri, "zig_diagnostics")) |diagnostics| {
        defer allocator.free(diagnostics);
        const value = diagnosticsStructuredValue(allocator, diagnostics) catch |err| return lspToolError(allocator, "zig_diagnostics", "textDocument/publishDiagnostics", "parse_notification", "malformed_diagnostics", err, "Retry after checking the ZLS session; the diagnostics notification was not valid JSON.");
        return structured(allocator, value);
    }
    return zigCheck(a, allocator, args);
}

pub fn zigDiagnosticsAll(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const file = argString(args, "file") orelse return missingArgumentResult(allocator, "zig_diagnostics_all", "file", "string");
    const file_uri = zlsFileUriFromArgs(a, allocator, args) catch |err| return zlsSetupErrorResult(a, allocator, "zig_diagnostics_all", file, err);
    defer allocator.free(file_uri);

    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    obj.put(allocator, "file", .{ .string = file }) catch return error.OutOfMemory;
    obj.put(allocator, "uri", .{ .string = file_uri }) catch return error.OutOfMemory;
    var sources = std.json.Array.init(allocator);

    if (a.lsp_client) |client| {
        const pull = diagnosticPullOrNull(a, allocator, client, file_uri, "zig_diagnostics_all");
        if (pull) |response| {
            defer allocator.free(response);
            sources.append(lspStructuredValue(allocator, "textDocument/diagnostic", response) catch |err| return lspToolError(allocator, "zig_diagnostics_all", "textDocument/diagnostic", "parse_response", "malformed_backend_response", err, "Retry after checking the ZLS session; the diagnostics response was not valid structured JSON.")) catch return error.OutOfMemory;
        }

        const wait_ms = diagnosticWaitMs(args);
        waitForDiagnostics(a, client, file_uri, wait_ms);
        if (cachedDiagnosticsOrNull(a, allocator, client, file_uri, "zig_diagnostics_all")) |diagnostics| {
            defer allocator.free(diagnostics);
            sources.append(diagnosticsStructuredValue(allocator, diagnostics) catch |err| return lspToolError(allocator, "zig_diagnostics_all", "textDocument/publishDiagnostics", "parse_notification", "malformed_diagnostics", err, "Retry after checking the ZLS session; the diagnostics notification was not valid JSON.")) catch return error.OutOfMemory;
        }
    }

    const resolved = a.workspace.resolve(file) catch |err| return workspacePathErrorResult(a, allocator, "zig_diagnostics_all", file, err);
    defer allocator.free(resolved);
    const ast = command.run(allocator, a.io, a.workspace.root, &.{ a.config.zig_path, "ast-check", resolved }, toolTimeout(a, args)) catch |err| {
        var err_obj = std.json.ObjectMap.empty;
        err_obj.put(allocator, "method", .{ .string = "zig ast-check" }) catch return error.OutOfMemory;
        err_obj.put(allocator, "ok", .{ .bool = false }) catch return error.OutOfMemory;
        err_obj.put(allocator, "error", .{ .string = @errorName(err) }) catch return error.OutOfMemory;
        sources.append(.{ .object = err_obj }) catch return error.OutOfMemory;
        obj.put(allocator, "sources", .{ .array = sources }) catch return error.OutOfMemory;
        return structured(allocator, .{ .object = obj });
    };
    defer ast.deinit(allocator);
    sources.append(commandResultValue(allocator, "zig ast-check", &.{ a.config.zig_path, "ast-check", resolved }, a.workspace.root, toolTimeout(a, args), ast) catch return error.OutOfMemory) catch return error.OutOfMemory;
    obj.put(allocator, "sources", .{ .array = sources }) catch return error.OutOfMemory;
    return structured(allocator, .{ .object = obj });
}

pub fn zigDiagnosticsWorkspace(a: *App, allocator: std.mem.Allocator, _: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const client = a.lsp_client orelse return structuredText(allocator, "zig_diagnostics_workspace", "ZLS session is unavailable; no workspace diagnostics cache exists.");
    const snapshot = client.diagnosticsSnapshot(allocator) catch |err| return lspToolError(allocator, "zig_diagnostics_workspace", "textDocument/publishDiagnostics", "read_snapshot", "diagnostics_snapshot_failed", err, "Retry after checking the ZLS session diagnostics cache.");
    defer {
        for (snapshot) |item| allocator.free(item);
        allocator.free(snapshot);
    }

    var files = std.json.Array.init(allocator);
    var total: usize = 0;
    var errors: usize = 0;
    var warnings: usize = 0;
    var info: usize = 0;
    var hints: usize = 0;
    var malformed_notifications: usize = 0;

    for (snapshot) |notification| {
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, notification, .{}) catch |err| {
            malformed_notifications += 1;
            a.logger.warn("zls", "skipping malformed diagnostics notification: {}", .{err});
            continue;
        };
        const obj = switch (parsed.value) {
            .object => |o| o,
            else => continue,
        };
        const params = switch (obj.get("params") orelse .null) {
            .object => |o| o,
            else => continue,
        };
        const uri = switch (params.get("uri") orelse .null) {
            .string => |s| s,
            else => "",
        };
        const diagnostics = switch (params.get("diagnostics") orelse .null) {
            .array => |array| array,
            else => continue,
        };
        var file_errors: usize = 0;
        var file_warnings: usize = 0;
        var file_info: usize = 0;
        var file_hints: usize = 0;
        for (diagnostics.items) |diag| {
            total += 1;
            const diag_obj = switch (diag) {
                .object => |o| o,
                else => continue,
            };
            const severity = switch (diag_obj.get("severity") orelse .null) {
                .integer => |i| i,
                else => 0,
            };
            switch (severity) {
                1 => {
                    errors += 1;
                    file_errors += 1;
                },
                2 => {
                    warnings += 1;
                    file_warnings += 1;
                },
                3 => {
                    info += 1;
                    file_info += 1;
                },
                4 => {
                    hints += 1;
                    file_hints += 1;
                },
                else => {},
            }
        }
        var file_obj = std.json.ObjectMap.empty;
        file_obj.put(allocator, "uri", .{ .string = uri }) catch return error.OutOfMemory;
        file_obj.put(allocator, "total", .{ .integer = @intCast(diagnostics.items.len) }) catch return error.OutOfMemory;
        file_obj.put(allocator, "errors", .{ .integer = @intCast(file_errors) }) catch return error.OutOfMemory;
        file_obj.put(allocator, "warnings", .{ .integer = @intCast(file_warnings) }) catch return error.OutOfMemory;
        file_obj.put(allocator, "information", .{ .integer = @intCast(file_info) }) catch return error.OutOfMemory;
        file_obj.put(allocator, "hints", .{ .integer = @intCast(file_hints) }) catch return error.OutOfMemory;
        files.append(.{ .object = file_obj }) catch return error.OutOfMemory;
    }

    var out = std.json.ObjectMap.empty;
    errdefer out.deinit(allocator);
    out.put(allocator, "files", .{ .array = files }) catch return error.OutOfMemory;
    out.put(allocator, "total", .{ .integer = @intCast(total) }) catch return error.OutOfMemory;
    out.put(allocator, "errors", .{ .integer = @intCast(errors) }) catch return error.OutOfMemory;
    out.put(allocator, "warnings", .{ .integer = @intCast(warnings) }) catch return error.OutOfMemory;
    out.put(allocator, "information", .{ .integer = @intCast(info) }) catch return error.OutOfMemory;
    out.put(allocator, "hints", .{ .integer = @intCast(hints) }) catch return error.OutOfMemory;
    out.put(allocator, "malformed_notifications", .{ .integer = @intCast(malformed_notifications) }) catch return error.OutOfMemory;
    return structured(allocator, .{ .object = out });
}

pub fn diagnosticsStructuredValue(allocator: std.mem.Allocator, notification: []const u8) !std.json.Value {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, notification, .{});
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "method", .{ .string = "textDocument/publishDiagnostics" });
    try obj.put(allocator, "ok", .{ .bool = true });

    const notification_obj = switch (parsed.value) {
        .object => |o| o,
        else => {
            try obj.put(allocator, "raw", parsed.value);
            return .{ .object = obj };
        },
    };
    const params = notification_obj.get("params") orelse .null;
    try obj.put(allocator, "result", params);
    try obj.put(allocator, "diagnostics", try lspDiagnosticsInsightsValue(allocator, params));
    return .{ .object = obj };
}
