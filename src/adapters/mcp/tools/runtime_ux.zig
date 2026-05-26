const std = @import("std");
const mcp = @import("mcp");

const app_context = @import("../../../app/context.zig");
const ports = @import("../../../app/ports.zig");
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

const fakes = @import("../../../testing/fakes/root.zig");

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

test "runtime UX adapter covers resource subscriptions workspace selection and tool errors" {
    const allocator = std.testing.allocator;
    var commands = fakes.FakeCommandRunner.init(allocator);
    defer commands.deinit();
    var workspace = fakes.FakeWorkspaceStore.init(allocator);
    defer workspace.deinit();
    var scanner = fakes.FakeWorkspaceScanner.init(allocator);
    defer scanner.deinit();
    var session = fakes.FakeRuntimeSession{};
    defer session.deinit(allocator);
    var catalog = fakes.FakeToolCatalog.init("{}");
    const context = runtimeAdapterContext(&commands, &workspace, &scanner, &session, &catalog);

    var subscribe_args = std.json.ObjectMap.empty;
    defer subscribe_args.deinit(allocator);
    try subscribe_args.put(allocator, "uri", .{ .string = "zigar://jobs" });
    const subscribed = try zigarResourceSubscribe(allocator, context, .{ .object = subscribe_args });
    defer mcp_result.deinitToolResult(allocator, subscribed);
    const subscription_id = subscribed.structuredContent.?.object.get("subscription").?.object.get("subscription_id").?.string;

    var unsubscribe_args = std.json.ObjectMap.empty;
    defer unsubscribe_args.deinit(allocator);
    try unsubscribe_args.put(allocator, "subscription_id", .{ .string = subscription_id });
    const unsubscribed = try zigarResourceUnsubscribe(allocator, context, .{ .object = unsubscribe_args });
    defer mcp_result.deinitToolResult(allocator, unsubscribed);
    try std.testing.expect(!unsubscribed.structuredContent.?.object.get("subscription").?.object.get("active").?.bool);

    const missing_unsubscribe = try zigarResourceUnsubscribe(allocator, context, null);
    defer mcp_result.deinitToolResult(allocator, missing_unsubscribe);
    try std.testing.expectEqualStrings("argument_error", missing_unsubscribe.structuredContent.?.object.get("kind").?.string);

    var not_found_args = std.json.ObjectMap.empty;
    defer not_found_args.deinit(allocator);
    try not_found_args.put(allocator, "subscription_id", .{ .string = "sub-missing" });
    const not_found = try zigarResourceUnsubscribe(allocator, context, .{ .object = not_found_args });
    defer mcp_result.deinitToolResult(allocator, not_found);
    try std.testing.expectEqualStrings("argument_error", not_found.structuredContent.?.object.get("kind").?.string);

    try expectWorkspaceMapExists(&workspace);
    var select_args = std.json.ObjectMap.empty;
    defer select_args.deinit(allocator);
    try select_args.put(allocator, "workspace_id", .{ .string = "/repo" });
    try select_args.put(allocator, "apply", .{ .bool = true });
    const selected = try zigarWorkspaceSelect(allocator, context, .{ .object = select_args });
    defer mcp_result.deinitToolResult(allocator, selected);
    try std.testing.expect(selected.structuredContent.?.object.get("apply").?.bool);

    var select_missing_args = std.json.ObjectMap.empty;
    defer select_missing_args.deinit(allocator);
    try select_missing_args.put(allocator, "workspace_id", .{ .string = "unknown-root" });
    const selected_missing = try zigarWorkspaceSelect(allocator, context, .{ .object = select_missing_args });
    defer mcp_result.deinitToolResult(allocator, selected_missing);
    try std.testing.expectEqualStrings("argument_error", selected_missing.structuredContent.?.object.get("kind").?.string);

    const missing_select = try zigarWorkspaceSelect(allocator, context, null);
    defer mcp_result.deinitToolResult(allocator, missing_select);
    try std.testing.expectEqualStrings("argument_error", missing_select.structuredContent.?.object.get("kind").?.string);

    try workspace.verify();
    try scanner.verify();
    try commands.verify();
}

test "runtime UX adapter maps run job and resource query failures" {
    const allocator = std.testing.allocator;
    var commands = fakes.FakeCommandRunner.init(allocator);
    defer commands.deinit();
    var workspace = fakes.FakeWorkspaceStore.init(allocator);
    defer workspace.deinit();
    var scanner = fakes.FakeWorkspaceScanner.init(allocator);
    defer scanner.deinit();
    var session = fakes.FakeRuntimeSession{};
    defer session.deinit(allocator);
    var catalog = fakes.FakeToolCatalog.init("{}");
    const context = runtimeAdapterContext(&commands, &workspace, &scanner, &session, &catalog);

    var invalid_command_args = std.json.ObjectMap.empty;
    defer invalid_command_args.deinit(allocator);
    try invalid_command_args.put(allocator, "command", .{ .string = "unknown" });
    const invalid_command = try zigarJobStart(allocator, context, .{ .object = invalid_command_args });
    defer mcp_result.deinitToolResult(allocator, invalid_command);
    try std.testing.expectEqualStrings("argument_error", invalid_command.structuredContent.?.object.get("kind").?.string);

    var missing_file_args = std.json.ObjectMap.empty;
    defer missing_file_args.deinit(allocator);
    try missing_file_args.put(allocator, "command", .{ .string = "test" });
    const missing_file = try zigarJobStart(allocator, context, .{ .object = missing_file_args });
    defer mcp_result.deinitToolResult(allocator, missing_file);
    try std.testing.expectEqualStrings("argument_error", missing_file.structuredContent.?.object.get("kind").?.string);

    try workspace.expectResolveError(.{ .path = "../escape.zig", .provenance = "runtime_ux.run_plan" }, error.PathOutsideWorkspace);
    var outside_args = std.json.ObjectMap.empty;
    defer outside_args.deinit(allocator);
    try outside_args.put(allocator, "command", .{ .string = "check" });
    try outside_args.put(allocator, "file", .{ .string = "../escape.zig" });
    const outside = try zigarRunStream(allocator, context, .{ .object = outside_args });
    defer mcp_result.deinitToolResult(allocator, outside);
    try std.testing.expectEqualStrings("workspace_path_error", outside.structuredContent.?.object.get("kind").?.string);

    var split_args = std.json.ObjectMap.empty;
    defer split_args.deinit(allocator);
    try split_args.put(allocator, "command", .{ .string = "build" });
    try split_args.put(allocator, "args", .{ .string = "\"unterminated" });
    const split_error = try zigarJobStart(allocator, context, .{ .object = split_args });
    defer mcp_result.deinitToolResult(allocator, split_error);
    try std.testing.expectEqualStrings("argument_error", split_error.structuredContent.?.object.get("kind").?.string);

    var invalid_resource_args = std.json.ObjectMap.empty;
    defer invalid_resource_args.deinit(allocator);
    try invalid_resource_args.put(allocator, "uri", .{ .string = "zigar://unknown" });
    const invalid_resource = try zigarResourceQuery(allocator, context, .{ .object = invalid_resource_args });
    defer mcp_result.deinitToolResult(allocator, invalid_resource);
    try std.testing.expectEqualStrings("argument_error", invalid_resource.structuredContent.?.object.get("kind").?.string);

    try workspace.expectReadError(.{
        .path = "../escape.zig",
        .max_bytes = runtime_ux.max_resource_read,
        .provenance = "runtime_ux.dynamic_resource",
    }, error.PathOutsideWorkspace);
    var outside_resource_args = std.json.ObjectMap.empty;
    defer outside_resource_args.deinit(allocator);
    try outside_resource_args.put(allocator, "uri", .{ .string = "zigar://file/../escape.zig/symbols" });
    const outside_resource = try zigarResourceQuery(allocator, context, .{ .object = outside_resource_args });
    defer mcp_result.deinitToolResult(allocator, outside_resource);
    try std.testing.expectEqualStrings("workspace_path_error", outside_resource.structuredContent.?.object.get("kind").?.string);

    try workspace.expectReadError(.{
        .path = "src/missing.zig",
        .max_bytes = runtime_ux.max_resource_read,
        .provenance = "runtime_ux.dynamic_resource",
    }, error.FileNotFound);
    var missing_resource_args = std.json.ObjectMap.empty;
    defer missing_resource_args.deinit(allocator);
    try missing_resource_args.put(allocator, "uri", .{ .string = "zigar://file/src/missing.zig/imports" });
    const missing_resource = try zigarResourceQuery(allocator, context, .{ .object = missing_resource_args });
    defer mcp_result.deinitToolResult(allocator, missing_resource);
    try std.testing.expectEqualStrings("tool_error", missing_resource.structuredContent.?.object.get("kind").?.string);

    try workspace.verify();
    try scanner.verify();
    try commands.verify();
}

test "runtime UX adapter helper errors and allocation failures are bounded" {
    const allocator = std.testing.allocator;
    var commands = fakes.FakeCommandRunner.init(allocator);
    defer commands.deinit();
    var workspace = fakes.FakeWorkspaceStore.init(allocator);
    defer workspace.deinit();
    var scanner = fakes.FakeWorkspaceScanner.init(allocator);
    defer scanner.deinit();
    var session = fakes.FakeRuntimeSession{};
    defer session.deinit(allocator);
    var catalog = fakes.FakeToolCatalog.init("{}");
    const context = runtimeAdapterContext(&commands, &workspace, &scanner, &session, &catalog);

    try std.testing.expectEqual(@as(u64, 0), parseCursor("not-a-number"));
    try std.testing.expectEqualStrings("src/main.zig", filePathFromUri("zigar://file/src/main.zig/imports").?);
    try std.testing.expect(filePathFromUri("zigar://jobs") == null);
    try std.testing.expect(filePathFromUri("zigar://file/main.zig") == null);

    const invalid = try resourceQueryError(allocator, context, "zigar://bad", error.InvalidArguments);
    defer mcp_result.deinitToolResult(allocator, invalid);
    try std.testing.expectEqualStrings("argument_error", invalid.structuredContent.?.object.get("kind").?.string);

    const outside = try resourceQueryError(allocator, context, "zigar://file/../escape.zig/imports", error.PathOutsideWorkspace);
    defer mcp_result.deinitToolResult(allocator, outside);
    try std.testing.expectEqualStrings("workspace_path_error", outside.structuredContent.?.object.get("kind").?.string);

    const read_failed = try resourceQueryError(allocator, context, "zigar://file/src/missing.zig/imports", error.AccessDenied);
    defer mcp_result.deinitToolResult(allocator, read_failed);
    try std.testing.expectEqualStrings("tool_error", read_failed.structuredContent.?.object.get("kind").?.string);

    const generic_resource = try resourceQueryError(allocator, context, "zigar://jobs", error.UnexpectedCall);
    defer mcp_result.deinitToolResult(allocator, generic_resource);
    try std.testing.expectEqualStrings("tool_error", generic_resource.structuredContent.?.object.get("kind").?.string);

    try std.testing.expectError(error.OutOfMemory, runtimeError(allocator, context, "zigar_job_status", "read_runtime_state", "runtime_state", "job-1", error.OutOfMemory));
    const missing_job = try runtimeError(allocator, context, "zigar_job_status", "read_runtime_state", "runtime_state", "job-missing", error.NotFound);
    defer mcp_result.deinitToolResult(allocator, missing_job);
    try std.testing.expectEqualStrings("argument_error", missing_job.structuredContent.?.object.get("kind").?.string);
    const missing_cancel = try runtimeError(allocator, context, "zigar_cancel_status", "read_cancel_status", "runtime_state", "job-missing", error.NotFound);
    defer mcp_result.deinitToolResult(allocator, missing_cancel);
    try std.testing.expectEqualStrings("argument_error", missing_cancel.structuredContent.?.object.get("kind").?.string);
    const invalid_runtime = try runtimeError(allocator, context, "zigar_roots_sync", "sync_roots", "runtime_state", "bad", error.InvalidArguments);
    defer mcp_result.deinitToolResult(allocator, invalid_runtime);
    try std.testing.expectEqualStrings("argument_error", invalid_runtime.structuredContent.?.object.get("kind").?.string);
    const runtime_outside = try runtimeError(allocator, context, "zigar_roots_sync", "sync_roots", "runtime_state", "../bad", error.EmptyPath);
    defer mcp_result.deinitToolResult(allocator, runtime_outside);
    try std.testing.expectEqualStrings("workspace_path_error", runtime_outside.structuredContent.?.object.get("kind").?.string);
    const generic_runtime = try runtimeError(allocator, context, "zigar_roots_sync", "sync_roots", "runtime_state", "root", error.UnexpectedCall);
    defer mcp_result.deinitToolResult(allocator, generic_runtime);
    try std.testing.expectEqualStrings("tool_error", generic_runtime.structuredContent.?.object.get("kind").?.string);

    var failing_session = FailingRuntimeSession{ .failure = .unsubscribe };
    var failing_context = context;
    failing_context.runtime_session = failing_session.port();
    var unsubscribe_args = std.json.ObjectMap.empty;
    defer unsubscribe_args.deinit(allocator);
    try unsubscribe_args.put(allocator, "subscription_id", .{ .string = "sub-1" });
    const unsubscribe_failed = try zigarResourceUnsubscribe(allocator, failing_context, .{ .object = unsubscribe_args });
    defer mcp_result.deinitToolResult(allocator, unsubscribe_failed);
    try std.testing.expectEqualStrings("tool_error", unsubscribe_failed.structuredContent.?.object.get("kind").?.string);

    failing_session.failure = .select_root;
    var select_args = std.json.ObjectMap.empty;
    defer select_args.deinit(allocator);
    try select_args.put(allocator, "workspace_id", .{ .string = "/repo" });
    const select_failed = try zigarWorkspaceSelect(allocator, failing_context, .{ .object = select_args });
    defer mcp_result.deinitToolResult(allocator, select_failed);
    try std.testing.expectEqualStrings("tool_error", select_failed.structuredContent.?.object.get("kind").?.string);

    failing_session.failure = .ensure_root;
    var job_args = std.json.ObjectMap.empty;
    defer job_args.deinit(allocator);
    try job_args.put(allocator, "command", .{ .string = "build" });
    const job_failed = try zigarJobStart(allocator, failing_context, .{ .object = job_args });
    defer mcp_result.deinitToolResult(allocator, job_failed);
    try std.testing.expectEqualStrings("tool_error", job_failed.structuredContent.?.object.get("kind").?.string);

    const failing_port = failing_session.port();
    try std.testing.expectError(error.UnexpectedCall, failing_port.startJob("label", "zig build", 1000));
    try std.testing.expectError(error.UnexpectedCall, failing_port.finishJob("job-1", .{
        .status = .completed,
        .ok = true,
        .duration_ms = 1,
        .term = "exited",
        .exit_code = 0,
        .stdout_tail = "",
        .stderr_tail = "",
        .stdout_truncated = false,
        .stderr_truncated = false,
    }));
    try std.testing.expectError(error.UnexpectedCall, failing_port.failJob("job-1", "AccessDenied", 1));
    try std.testing.expectError(error.UnexpectedCall, failing_port.cancelJob("job-1", "stop"));
    try std.testing.expectError(error.NotFound, failing_port.jobById("job-1"));
    try std.testing.expectEqual(@as(usize, 0), try failing_port.jobCount());
    try std.testing.expectError(error.NotFound, failing_port.jobAt(0));
    try std.testing.expectEqual(@as(u64, 0), try failing_port.eventCount());
    try std.testing.expectError(error.NotFound, failing_port.eventAtSequence(1));
    try std.testing.expectError(error.UnexpectedCall, failing_port.subscribe("zigar://jobs"));
    try std.testing.expectError(error.NotFound, failing_port.unsubscribe("sub-1", null));
    try failing_port.syncRoots("/repo", "/repo", false);
    const root = try failing_port.selectRoot("/repo", false);
    try std.testing.expectEqualStrings("root-1", root.id);
    try std.testing.expectEqual(@as(usize, 1), try failing_port.rootCount());
    try std.testing.expectEqual(@as(usize, 0), try failing_port.selectedRootIndex());
    try std.testing.expectEqualStrings("/repo", (try failing_port.rootAt(0)).path);

    try std.testing.checkAllAllocationFailures(std.testing.allocator, exerciseRuntimeUxArgSplitting, .{});

    var oom_args = std.json.ObjectMap.empty;
    defer oom_args.deinit(allocator);
    try oom_args.put(allocator, "command", .{ .string = "build" });
    try oom_args.put(allocator, "args", .{ .string = "one" });
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, zigarJobStart(failing.allocator(), context, .{ .object = oom_args }));

    try workspace.verify();
    try scanner.verify();
    try commands.verify();
}

fn runtimeAdapterContext(
    command_runner: *fakes.FakeCommandRunner,
    workspace_store: *fakes.FakeWorkspaceStore,
    workspace_scanner: *fakes.FakeWorkspaceScanner,
    runtime_session: *fakes.FakeRuntimeSession,
    tool_catalog: *fakes.FakeToolCatalog,
) app_context.RuntimeUxContext {
    return .{
        .workspace = .{ .root = "/repo", .cache_root = "/repo/.zigar-cache" },
        .tool_paths = .{ .zig = "/bin/zig" },
        .timeouts = .{ .command_ms = 1000, .zls_ms = 2000 },
        .zls_state = .{},
        .command_runner = command_runner.port(),
        .workspace_store = workspace_store.port(),
        .workspace_scanner = workspace_scanner.port(),
        .runtime_session = runtime_session.port(),
        .tool_catalog = tool_catalog.port(),
    };
}

fn expectWorkspaceMapExists(workspace: *fakes.FakeWorkspaceStore) !void {
    try workspace.expectExists(.{ .path = "build.zig", .provenance = "runtime_ux.workspace_map" }, .{ .exists = true, .kind = .file });
    try workspace.expectExists(.{ .path = "build.zig.zon", .provenance = "runtime_ux.workspace_map" }, .{ .exists = false });
    try workspace.expectExists(.{ .path = "src", .provenance = "runtime_ux.workspace_map" }, .{ .exists = true, .kind = .directory });
}

fn exerciseRuntimeUxArgSplitting(backing_allocator: std.mem.Allocator) !void {
    const args = try splitToolArgs(backing_allocator, "alpha beta");
    defer {
        for (args) |arg| backing_allocator.free(arg);
        backing_allocator.free(args);
    }
    try std.testing.expectEqual(@as(usize, 2), args.len);
    try std.testing.expectEqualStrings("alpha", args[0]);
    try std.testing.expectEqualStrings("beta", args[1]);
}

const RuntimeFailure = enum {
    ensure_root,
    unsubscribe,
    select_root,
};

const FailingRuntimeSession = struct {
    failure: RuntimeFailure,

    fn port(self: *FailingRuntimeSession) ports.RuntimeSession {
        return .{
            .ptr = self,
            .vtable = &.{
                .ensure_default_root = ensureDefaultRoot,
                .start_job = startJob,
                .finish_job = finishJob,
                .fail_job = failJob,
                .cancel_job = cancelJob,
                .job_by_id = jobById,
                .job_count = jobCount,
                .job_at = jobAt,
                .event_count = eventCount,
                .event_at_sequence = eventAtSequence,
                .subscribe = subscribe,
                .unsubscribe = unsubscribe,
                .sync_roots = syncRoots,
                .select_root = selectRoot,
                .root_count = rootCount,
                .selected_root_index = selectedRootIndex,
                .root_at = rootAt,
            },
        };
    }

    fn ensureDefaultRoot(ptr: *anyopaque, _: []const u8) ports.PortError!void {
        const self: *FailingRuntimeSession = @ptrCast(@alignCast(ptr));
        if (self.failure == .ensure_root) return error.AccessDenied;
    }

    fn startJob(_: *anyopaque, _: []const u8, _: []const u8, _: i64) ports.PortError!ports.RuntimeJobSnapshot {
        return error.UnexpectedCall;
    }

    fn finishJob(_: *anyopaque, _: []const u8, _: ports.RuntimeJobFinish) ports.PortError!ports.RuntimeJobSnapshot {
        return error.UnexpectedCall;
    }

    fn failJob(_: *anyopaque, _: []const u8, _: []const u8, _: i64) ports.PortError!ports.RuntimeJobSnapshot {
        return error.UnexpectedCall;
    }

    fn cancelJob(_: *anyopaque, _: []const u8, _: []const u8) ports.PortError!ports.RuntimeJobSnapshot {
        return error.UnexpectedCall;
    }

    fn jobById(_: *anyopaque, _: []const u8) ports.PortError!ports.RuntimeJobSnapshot {
        return error.NotFound;
    }

    fn jobCount(_: *anyopaque) ports.PortError!usize {
        return 0;
    }

    fn jobAt(_: *anyopaque, _: usize) ports.PortError!ports.RuntimeJobSnapshot {
        return error.NotFound;
    }

    fn eventCount(_: *anyopaque) ports.PortError!u64 {
        return 0;
    }

    fn eventAtSequence(_: *anyopaque, _: u64) ports.PortError!ports.RuntimeEventSnapshot {
        return error.NotFound;
    }

    fn subscribe(_: *anyopaque, _: []const u8) ports.PortError!ports.RuntimeSubscriptionSnapshot {
        return error.UnexpectedCall;
    }

    fn unsubscribe(ptr: *anyopaque, _: []const u8, _: ?[]const u8) ports.PortError!ports.RuntimeSubscriptionSnapshot {
        const self: *FailingRuntimeSession = @ptrCast(@alignCast(ptr));
        if (self.failure == .unsubscribe) return error.AccessDenied;
        return error.NotFound;
    }

    fn syncRoots(_: *anyopaque, _: []const u8, _: []const u8, _: bool) ports.PortError!void {}

    fn selectRoot(ptr: *anyopaque, _: []const u8, _: bool) ports.PortError!ports.RuntimeRootSnapshot {
        const self: *FailingRuntimeSession = @ptrCast(@alignCast(ptr));
        if (self.failure == .select_root) return error.AccessDenied;
        return root();
    }

    fn rootCount(_: *anyopaque) ports.PortError!usize {
        return 1;
    }

    fn selectedRootIndex(_: *anyopaque) ports.PortError!usize {
        return 0;
    }

    fn rootAt(_: *anyopaque, _: usize) ports.PortError!ports.RuntimeRootSnapshot {
        return root();
    }

    fn root() ports.RuntimeRootSnapshot {
        return .{ .id = "root-1", .path = "/repo", .uri = "file:///repo", .name = "repo", .selected = true };
    }
};
