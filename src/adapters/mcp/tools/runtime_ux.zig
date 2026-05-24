const std = @import("std");
const mcp = @import("mcp");

const app_context = @import("../../../app/context.zig");
const runtime_ux = @import("../../../app/usecases/runtime_ux/workflows.zig");
const mcp_errors = @import("../errors.zig");
const mcp_result = @import("../result.zig");

pub fn zigarJobStart(allocator: std.mem.Allocator, context: app_context.RuntimeUxContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return runJobTool(allocator, context, args, "zigar_job_start", false);
}

pub fn zigarRunStream(allocator: std.mem.Allocator, context: app_context.RuntimeUxContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return runJobTool(allocator, context, args, "zigar_run_stream", true);
}

pub fn zigarJobStatus(allocator: std.mem.Allocator, context: app_context.RuntimeUxContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const job_id = argString(args, "job_id") orelse return mcp_errors.missingArgument(allocator, "zigar_job_status", "job_id", "job id returned by zigar_job_start or zigar_run_stream");
    return structuredUsecase(allocator, runtime_ux.jobStatusValue, context, job_id, "zigar_job_status");
}

pub fn zigarJobResult(allocator: std.mem.Allocator, context: app_context.RuntimeUxContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const job_id = argString(args, "job_id") orelse return mcp_errors.missingArgument(allocator, "zigar_job_result", "job_id", "job id returned by zigar_job_start or zigar_run_stream");
    const request = runtime_ux.JobResultRequest{
        .job_id = job_id,
        .cursor = parseCursor(argString(args, "cursor")),
        .limit = clampLimit(argInt(args, "limit", 25), 1, 100),
        .mode = argString(args, "mode") orelse "standard",
    };
    return runtimeValue(allocator, context, "zigar_job_result", "read_job_result", "runtime_state", request, runtime_ux.jobResultValue);
}

pub fn zigarJobCancel(allocator: std.mem.Allocator, context: app_context.RuntimeUxContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const job_id = argString(args, "job_id") orelse return mcp_errors.missingArgument(allocator, "zigar_job_cancel", "job_id", "job id returned by zigar_job_start or zigar_run_stream");
    const reason = argString(args, "reason") orelse "client requested cancellation";
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const value = runtime_ux.jobCancelValue(arena.allocator(), context, job_id, reason) catch |err| return runtimeError(allocator, context, "zigar_job_cancel", "cancel_job", "runtime_state", job_id, err);
    return mcp_result.structured(allocator, value);
}

pub fn zigarCancelStatus(allocator: std.mem.Allocator, context: app_context.RuntimeUxContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const job_id = argString(args, "job_id");
    const value = runtime_ux.cancelStatusValue(arena.allocator(), context, job_id) catch |err| return runtimeError(allocator, context, "zigar_cancel_status", "read_cancel_status", "runtime_state", job_id orelse "", err);
    return mcp_result.structured(allocator, value);
}

pub fn zigarRunEvents(allocator: std.mem.Allocator, context: app_context.RuntimeUxContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const request = runtime_ux.EventsRequest{
        .job_id = argString(args, "job_id"),
        .cursor = parseCursor(argString(args, "cursor")),
        .limit = clampLimit(argInt(args, "limit", 50), 1, 200),
    };
    return runtimeValue(allocator, context, "zigar_run_events", "read_run_events", "runtime_state", request, runtime_ux.runEventsValue);
}

pub fn zigarResourceQuery(allocator: std.mem.Allocator, context: app_context.RuntimeUxContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const uri = argString(args, "uri") orelse return mcp_errors.missingArgument(allocator, "zigar_resource_query", "uri", "zigar resource URI");
    const request = runtime_ux.ResourceQueryRequest{
        .uri = uri,
        .cursor = parseCursor(argString(args, "cursor")),
        .limit = clampLimit(argInt(args, "limit", 50), 1, 200),
        .mode = argString(args, "mode") orelse "standard",
    };
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const value = runtime_ux.resourceQueryValue(arena.allocator(), context, request) catch |err| return resourceQueryError(allocator, context, uri, err);
    return mcp_result.structured(allocator, value);
}

pub fn zigarResourceSubscribe(allocator: std.mem.Allocator, context: app_context.RuntimeUxContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const uri = argString(args, "uri") orelse return mcp_errors.missingArgument(allocator, "zigar_resource_subscribe", "uri", "zigar resource URI");
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const value = runtime_ux.resourceSubscribeValue(arena.allocator(), context, uri) catch |err| return runtimeError(allocator, context, "zigar_resource_subscribe", "subscribe_resource", "runtime_state", uri, err);
    return mcp_result.structured(allocator, value);
}

pub fn zigarResourceUnsubscribe(allocator: std.mem.Allocator, context: app_context.RuntimeUxContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const subscription_id = argString(args, "subscription_id");
    const uri = argString(args, "uri");
    if (subscription_id == null and uri == null) return mcp_errors.missingArgument(allocator, "zigar_resource_unsubscribe", "subscription_id", "subscription id or uri");
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const value = runtime_ux.resourceUnsubscribeValue(arena.allocator(), context, subscription_id, uri) catch |err| switch (err) {
        error.InvalidArguments => return mcp_errors.missingArgument(allocator, "zigar_resource_unsubscribe", "subscription_id", "subscription id or uri"),
        error.NotFound => return mcp_errors.invalidArgument(allocator, "zigar_resource_unsubscribe", "subscription_id", "active subscription id or uri", subscription_id orelse "", "Call zigar_resource_subscribe first, or pass a retained active subscription id."),
        else => return runtimeError(allocator, context, "zigar_resource_unsubscribe", "unsubscribe_resource", "runtime_state", subscription_id orelse uri orelse "", err),
    };
    return mcp_result.structured(allocator, value);
}

pub fn zigarRootsSync(allocator: std.mem.Allocator, context: app_context.RuntimeUxContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const roots = argString(args, "roots") orelse context.workspace.root;
    const apply = argBool(args, "apply", false);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const value = runtime_ux.rootsSyncValue(arena.allocator(), context, roots, apply) catch |err| return runtimeError(allocator, context, "zigar_roots_sync", "sync_roots", "runtime_state", roots, err);
    return mcp_result.structured(allocator, value);
}

pub fn zigarWorkspaceMap(allocator: std.mem.Allocator, context: app_context.RuntimeUxContext, _: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return runtimeValue(allocator, context, "zigar_workspace_map", "map_workspace", "runtime_state", @as(?[]const u8, null), workspaceMapThunk);
}

pub fn zigarWorkspaceSelect(allocator: std.mem.Allocator, context: app_context.RuntimeUxContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const workspace_id = argString(args, "workspace_id") orelse return mcp_errors.missingArgument(allocator, "zigar_workspace_select", "workspace_id", "root id or path from zigar_workspace_map");
    const apply = argBool(args, "apply", false);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const value = runtime_ux.workspaceSelectValue(arena.allocator(), context, workspace_id, apply) catch |err| switch (err) {
        error.NotFound => return mcp_errors.invalidArgument(allocator, "zigar_workspace_select", "workspace_id", "known workspace root id or path", workspace_id, "Call zigar_workspace_map and pass one of the returned root ids."),
        else => return runtimeError(allocator, context, "zigar_workspace_select", "select_workspace", "runtime_state", workspace_id, err),
    };
    return mcp_result.structured(allocator, value);
}

pub fn zigarAgentGuideV2(allocator: std.mem.Allocator, _: app_context.RuntimeUxContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const value = runtime_ux.agentGuideV2Value(arena.allocator(), argString(args, "client") orelse "generic", argString(args, "task") orelse "zig development") catch return error.OutOfMemory;
    return mcp_result.structured(allocator, value);
}

pub fn zigarClientGuide(allocator: std.mem.Allocator, _: app_context.RuntimeUxContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const value = runtime_ux.clientGuideValue(arena.allocator(), argString(args, "client") orelse "generic", argString(args, "task") orelse "mcp integration") catch return error.OutOfMemory;
    return mcp_result.structured(allocator, value);
}

pub fn zigarPromptPack(allocator: std.mem.Allocator, _: app_context.RuntimeUxContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const value = runtime_ux.promptPackValue(arena.allocator(), argString(args, "workflow"), "standard") catch return error.OutOfMemory;
    return mcp_result.structured(allocator, value);
}

fn runJobTool(allocator: std.mem.Allocator, context: app_context.RuntimeUxContext, args: ?std.json.Value, tool_name: []const u8, include_events: bool) mcp.tools.ToolError!mcp.tools.ToolResult {
    const command_name = argString(args, "command") orelse return mcp_errors.missingArgument(allocator, tool_name, "command", "one of build, build-test, test, check, fmt-check");
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const extra_args = splitToolArgs(arena.allocator(), argString(args, "args")) catch |err| switch (err) {
        error.InvalidArguments => return mcp_errors.invalidArgument(allocator, tool_name, "args", "shell-like argument string", argString(args, "args") orelse "", "Use balanced quotes and escapes, or omit args for no extra Zig arguments."),
        error.OutOfMemory => return error.OutOfMemory,
    };
    const request = runtime_ux.RunJobRequest{
        .tool_name = tool_name,
        .command = command_name,
        .file = argString(args, "file"),
        .extra_args = extra_args,
        .timeout_ms = timeoutMs(context, args),
        .include_events = include_events,
    };
    const value = runtime_ux.runJobValue(arena.allocator(), context, request) catch |err| switch (err) {
        error.InvalidArguments => return mcp_errors.invalidArgument(allocator, tool_name, "command", "one of build, build-test, test, check, fmt-check", command_name, "Choose an allow-listed command; zigar does not accept arbitrary shell commands here."),
        error.MissingFile => return mcp_errors.missingArgument(allocator, tool_name, "file", "workspace-relative Zig file for test, check, or fmt-check"),
        error.PathOutsideWorkspace, error.EmptyPath => return mcp_errors.workspacePath(allocator, tool_name, argString(args, "file") orelse "", context.workspace.root, err),
        else => return runtimeError(allocator, context, tool_name, "run_job", "execution", command_name, err),
    };
    return mcp_result.structured(allocator, value);
}

fn structuredUsecase(
    allocator: std.mem.Allocator,
    comptime func: fn (std.mem.Allocator, app_context.RuntimeUxContext, []const u8) runtime_ux.RuntimeUxError!std.json.Value,
    context: app_context.RuntimeUxContext,
    arg: []const u8,
    tool_name: []const u8,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const value = func(arena.allocator(), context, arg) catch |err| return runtimeError(allocator, context, tool_name, "read_runtime_state", "runtime_state", arg, err);
    return mcp_result.structured(allocator, value);
}

fn runtimeValue(
    allocator: std.mem.Allocator,
    context: app_context.RuntimeUxContext,
    tool_name: []const u8,
    operation: []const u8,
    category: []const u8,
    request: anytype,
    comptime func: fn (std.mem.Allocator, app_context.RuntimeUxContext, @TypeOf(request)) runtime_ux.RuntimeUxError!std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const value = func(arena.allocator(), context, request) catch |err| return runtimeError(allocator, context, tool_name, operation, category, "", err);
    return mcp_result.structured(allocator, value);
}

fn workspaceMapThunk(allocator: std.mem.Allocator, context: app_context.RuntimeUxContext, _: ?[]const u8) runtime_ux.RuntimeUxError!std.json.Value {
    return runtime_ux.workspaceMapResultValue(allocator, context, "zigar_workspace_map", null);
}

fn resourceQueryError(allocator: std.mem.Allocator, context: app_context.RuntimeUxContext, uri: []const u8, err: anyerror) mcp.tools.ToolError!mcp.tools.ToolResult {
    switch (err) {
        error.InvalidArguments => return mcp_errors.invalidArgument(allocator, "zigar_resource_query", "uri", "registered zigar URI or zigar://file/{path}/{symbols|diagnostics|imports}", uri, "Use resources/list, resources/templates/list, or zigar_workspace_map to discover supported URIs."),
        error.PathOutsideWorkspace, error.EmptyPath => return mcp_errors.workspacePath(allocator, "zigar_resource_query", filePathFromUri(uri) orelse uri, context.workspace.root, err),
        error.FileNotFound, error.AccessDenied, error.PermissionDenied => return mcp_errors.fromError(allocator, .{
            .tool = "zigar_resource_query",
            .operation = "read_dynamic_file_resource",
            .phase = "workspace_read",
            .code = "resource_file_read_failed",
            .category = "filesystem",
            .resolution = "Confirm the file exists inside the configured zigar workspace and retry.",
            .details = &.{.{ .key = "uri", .value = .{ .string = uri } }},
        }, err),
        else => return runtimeError(allocator, context, "zigar_resource_query", "read_resource", "runtime_state", uri, err),
    }
}

fn runtimeError(allocator: std.mem.Allocator, context: app_context.RuntimeUxContext, tool_name: []const u8, operation: []const u8, category: []const u8, actual: []const u8, err: anyerror) mcp.tools.ToolError!mcp.tools.ToolResult {
    if (err == error.OutOfMemory) return error.OutOfMemory;
    if (err == error.NotFound and std.mem.indexOf(u8, tool_name, "job") != null) return jobNotFound(allocator, tool_name, actual);
    if (err == error.NotFound and std.mem.eql(u8, tool_name, "zigar_cancel_status")) return jobNotFound(allocator, tool_name, actual);
    if (err == error.InvalidArguments) return mcp_errors.invalidArgument(allocator, tool_name, null, "valid runtime UX request", actual, "Inspect the tool inputSchema and retry with supported values.");
    if (err == error.PathOutsideWorkspace or err == error.EmptyPath) return mcp_errors.workspacePath(allocator, tool_name, actual, context.workspace.root, err);
    return mcp_errors.fromError(allocator, .{
        .tool = tool_name,
        .operation = operation,
        .phase = "execute_use_case",
        .code = "runtime_ux_failed",
        .category = category,
        .resolution = "Retry after inspecting zigar_workspace_map, zigar_run_events, or the relevant MCP resource for current process-local state.",
        .details = &.{.{ .key = "input", .value = .{ .string = actual } }},
    }, err);
}

fn jobNotFound(allocator: std.mem.Allocator, tool_name: []const u8, job_id: []const u8) mcp.tools.ToolError!mcp.tools.ToolResult {
    return mcp_errors.invalidArgument(allocator, tool_name, "job_id", "retained zigar job id", job_id, "Use zigar_job_start, zigar_run_stream, zigar_run_events, or zigar://jobs to discover retained job ids.");
}

fn argString(args: ?std.json.Value, name: []const u8) ?[]const u8 {
    return mcp.tools.getString(args, name);
}

fn argBool(args: ?std.json.Value, name: []const u8, default: bool) bool {
    return mcp.tools.getBoolean(args, name) orelse default;
}

fn argInt(args: ?std.json.Value, name: []const u8, default: i64) i64 {
    return mcp.tools.getInteger(args, name) orelse default;
}

fn timeoutMs(context: app_context.RuntimeUxContext, args: ?std.json.Value) i64 {
    return @max(1, @min(argInt(args, "timeout_ms", context.timeouts.command_ms), 60 * 60 * 1000));
}

fn parseCursor(cursor: ?[]const u8) u64 {
    const text = cursor orelse return 0;
    return std.fmt.parseUnsigned(u64, text, 10) catch 0;
}

fn clampLimit(value: i64, min: usize, max: usize) usize {
    if (value < @as(i64, @intCast(min))) return min;
    if (value > @as(i64, @intCast(max))) return max;
    return @intCast(value);
}

fn filePathFromUri(uri: []const u8) ?[]const u8 {
    const prefix = "zigar://file/";
    if (!std.mem.startsWith(u8, uri, prefix)) return null;
    const rest = uri[prefix.len..];
    const slash = std.mem.lastIndexOfScalar(u8, rest, '/') orelse return null;
    return rest[0..slash];
}

fn splitToolArgs(allocator: std.mem.Allocator, text_value: ?[]const u8) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    var current: std.ArrayList(u8) = .empty;
    errdefer {
        for (list.items) |arg| allocator.free(arg);
        list.deinit(allocator);
        current.deinit(allocator);
    }
    if (text_value) |value| {
        var quote: ?u8 = null;
        var escaping = false;
        var in_token = false;
        for (value) |c| {
            if (escaping) {
                try current.append(allocator, c);
                in_token = true;
                escaping = false;
                continue;
            }
            if (c == '\\') {
                escaping = true;
                in_token = true;
                continue;
            }
            if (quote) |q| {
                if (c == q) {
                    quote = null;
                } else {
                    try current.append(allocator, c);
                }
                in_token = true;
                continue;
            }
            switch (c) {
                '\'', '"' => {
                    quote = c;
                    in_token = true;
                },
                ' ', '\t', '\r', '\n' => {
                    if (in_token) {
                        try finishArg(allocator, &list, &current);
                        in_token = false;
                    }
                },
                else => {
                    try current.append(allocator, c);
                    in_token = true;
                },
            }
        }
        if (escaping or quote != null) return error.InvalidArguments;
        if (in_token) try finishArg(allocator, &list, &current);
    }
    return list.toOwnedSlice(allocator);
}

fn finishArg(allocator: std.mem.Allocator, list: *std.ArrayList([]const u8), current: *std.ArrayList(u8)) !void {
    const arg = try current.toOwnedSlice(allocator);
    errdefer allocator.free(arg);
    try list.append(allocator, arg);
}

test "runtime UX adapter preserves shell-like extra argument parsing" {
    const args = try splitToolArgs(std.testing.allocator, "--summary 'all tests' --flag\\ value");
    defer {
        for (args) |arg| std.testing.allocator.free(arg);
        std.testing.allocator.free(args);
    }
    try std.testing.expectEqual(@as(usize, 3), args.len);
    try std.testing.expectEqualStrings("--summary", args[0]);
    try std.testing.expectEqualStrings("all tests", args[1]);
    try std.testing.expectEqualStrings("--flag value", args[2]);
}
