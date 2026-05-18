const std = @import("std");
const mcp = @import("mcp");
const zigar = @import("zigar");

const command = zigar.command;
const common = @import("common.zig");

const App = common.App;
const structured = common.structured;
const argString = common.argString;
const argBool = common.argBool;
const missingArgumentResult = common.missingArgumentResult;
const invalidArgumentResult = common.invalidArgumentResult;
const toolErrorFromError = common.toolErrorFromError;
const workspacePathErrorResult = common.workspacePathErrorResult;
const runAndFormatTimeout = common.runAndFormatTimeout;
const toolTimeout = common.toolTimeout;
const backendErrorResult = common.backendErrorResult;
const commandResultErrorResult = common.commandResultErrorResult;
const splitToolArgs = common.splitToolArgs;
const splitToolArgsErrorResult = common.splitToolArgsErrorResult;
const structuredText = common.structuredText;
const freeArgList = common.freeArgList;

pub fn zigProfilePlan(_: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const binary = argString(args, "binary") orelse "zig-out/bin/<app>";
    const msg = std.fmt.allocPrint(allocator,
        \\Profiling plan for {s}
        \\
        \\1. Build with symbols: zig build -Doptimize=ReleaseFast
        \\2. Capture with the platform profiler:
        \\   macOS: xcrun xctrace record --template "Time Profiler" --launch -- {s}
        \\   Linux: perf record -F 997 -g -- {s}
        \\3. Convert profiler output to a supported zflame input.
        \\4. Use zig_flamegraph with format=guess|perf|dtrace|sample|vtune|xctrace.
        \\5. For comparisons, generate folded stacks for before/after and call zig_flamegraph_diff.
        \\
    , .{ binary, binary, binary }) catch return error.OutOfMemory;
    defer allocator.free(msg);
    return structuredText(allocator, "zig_profile_plan", msg);
}

pub fn zigProfileRun(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const cmd = argString(args, "command") orelse return missingArgumentResult(allocator, "zig_profile_run", "command", "shell-style command string");
    const split = splitToolArgs(allocator, cmd) catch |err| return splitToolArgsErrorResult(allocator, "zig_profile_run", "command", cmd, err);
    defer freeArgList(allocator, split);
    if (split.len == 0) return invalidArgumentResult(allocator, "zig_profile_run", "command", "non-empty command string", cmd, "Pass the executable and arguments to run under the profiler.");
    return runAndFormatTimeout(a, allocator, split, "profile command", toolTimeout(a, args));
}

pub fn zigFlamegraph(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const format = argString(args, "format") orelse "guess";
    const input = argString(args, "input") orelse return missingArgumentResult(allocator, "zig_flamegraph", "input", "workspace-relative profiler input path");
    const output = argString(args, "output") orelse return missingArgumentResult(allocator, "zig_flamegraph", "output", "workspace-relative SVG output path");
    const input_abs = a.workspace.resolve(input) catch |err| return workspacePathErrorResult(a, allocator, "zig_flamegraph", input, err);
    defer allocator.free(input_abs);
    const output_abs = a.workspace.resolveOutput(output) catch |err| return workspacePathErrorResult(a, allocator, "zig_flamegraph", output, err);
    defer allocator.free(output_abs);

    var list: std.ArrayList([]const u8) = .empty;
    defer list.deinit(allocator);
    list.appendSlice(allocator, &.{ a.config.zflame_path, format }) catch return error.OutOfMemory;
    if (argString(args, "title")) |title_value| {
        list.appendSlice(allocator, &.{ "--title", title_value }) catch return error.OutOfMemory;
    }
    if (argString(args, "palette")) |palette| {
        list.appendSlice(allocator, &.{ "--palette", palette }) catch return error.OutOfMemory;
    }
    if (argString(args, "min_width")) |min_width| {
        list.appendSlice(allocator, &.{ "--min-width", min_width }) catch return error.OutOfMemory;
    }
    if (argBool(args, "hash", false)) {
        list.append(allocator, "--hash") catch return error.OutOfMemory;
    }
    list.append(allocator, input_abs) catch return error.OutOfMemory;

    const result = command.run(allocator, a.io, a.workspace.root, list.items, a.config.timeout_ms) catch |err| {
        return backendErrorResult(allocator, "zflame", "render", err, "confirm --zflame-path points to an executable zflame binary and that profiler input is readable");
    };
    defer result.deinit(allocator);
    if (!result.succeeded()) {
        return commandResultErrorResult(allocator, .{
            .tool = "zig_flamegraph",
            .operation = "render_flamegraph",
            .phase = "run_zflame",
            .code = "zflame_command_failed",
            .backend = "zflame",
            .argv = list.items,
            .cwd = a.workspace.root,
            .timeout_ms = a.config.timeout_ms,
            .result = result,
            .resolution = "Inspect stdout/stderr, confirm the profiler input format is correct, and retry with a supported zflame invocation.",
        });
    }
    a.workspace.writeFile(a.io, output, result.stdout) catch |err| return toolErrorFromError(allocator, .{
        .tool = "zig_flamegraph",
        .operation = "write_output",
        .phase = "workspace_write",
        .code = "write_failed",
        .category = "filesystem",
        .resolution = "Choose an output path inside the workspace that zigar can create or overwrite.",
        .details = &.{.{ .key = "output", .value = .{ .string = output } }},
    }, err);
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    obj.put(allocator, "kind", .{ .string = "zig_flamegraph" }) catch return error.OutOfMemory;
    obj.put(allocator, "output", .{ .string = output }) catch return error.OutOfMemory;
    obj.put(allocator, "output_abs", .{ .string = output_abs }) catch return error.OutOfMemory;
    obj.put(allocator, "format", .{ .string = format }) catch return error.OutOfMemory;
    obj.put(allocator, "bytes", .{ .integer = @intCast(result.stdout.len) }) catch return error.OutOfMemory;
    return structured(allocator, .{ .object = obj });
}

pub fn zigFlamegraphDiff(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const before = argString(args, "before") orelse return missingArgumentResult(allocator, "zig_flamegraph_diff", "before", "workspace-relative folded stack path");
    const after = argString(args, "after") orelse return missingArgumentResult(allocator, "zig_flamegraph_diff", "after", "workspace-relative folded stack path");
    const output = argString(args, "output") orelse return missingArgumentResult(allocator, "zig_flamegraph_diff", "output", "workspace-relative SVG output path");
    const before_abs = a.workspace.resolve(before) catch |err| return workspacePathErrorResult(a, allocator, "zig_flamegraph_diff", before, err);
    defer allocator.free(before_abs);
    const after_abs = a.workspace.resolve(after) catch |err| return workspacePathErrorResult(a, allocator, "zig_flamegraph_diff", after, err);
    defer allocator.free(after_abs);
    const temp_id = a.temp_counter.fetchAdd(1, .monotonic);
    const folded_name = std.fmt.allocPrint(allocator, "diff-{d}.folded", .{temp_id}) catch return error.OutOfMemory;
    defer allocator.free(folded_name);
    const folded_out = std.fs.path.join(allocator, &.{ ".zigar-cache", "profile", folded_name }) catch return error.OutOfMemory;
    defer allocator.free(folded_out);
    const folded_abs = a.workspace.resolveOutput(folded_out) catch |err| return workspacePathErrorResult(a, allocator, "zig_flamegraph_diff", folded_out, err);
    defer allocator.free(folded_abs);
    const diff = command.run(allocator, a.io, a.workspace.root, &.{ a.config.diff_folded_path, before_abs, after_abs }, a.config.timeout_ms) catch |err| {
        return backendErrorResult(allocator, "diff-folded", "diff", err, "confirm --diff-folded-path points to an executable diff-folded binary and both folded inputs are readable");
    };
    defer diff.deinit(allocator);
    if (!diff.succeeded()) {
        return commandResultErrorResult(allocator, .{
            .tool = "zig_flamegraph_diff",
            .operation = "diff_folded_stacks",
            .phase = "run_diff_folded",
            .code = "diff_folded_command_failed",
            .backend = "diff-folded",
            .argv = &.{ a.config.diff_folded_path, before_abs, after_abs },
            .cwd = a.workspace.root,
            .timeout_ms = a.config.timeout_ms,
            .result = diff,
            .resolution = "Inspect stdout/stderr, confirm both folded-stack inputs are readable, and retry with a working diff-folded backend.",
        });
    }
    a.workspace.writeFile(a.io, folded_out, diff.stdout) catch |err| return toolErrorFromError(allocator, .{
        .tool = "zig_flamegraph_diff",
        .operation = "write_intermediate_diff",
        .phase = "workspace_write",
        .code = "write_failed",
        .category = "filesystem",
        .resolution = "Confirm the .zigar-cache/profile directory can be created inside the workspace and retry.",
        .details = &.{.{ .key = "output", .value = .{ .string = folded_out } }},
    }, err);
    var obj = std.json.ObjectMap.empty;
    obj.put(allocator, "input", .{ .string = folded_out }) catch return error.OutOfMemory;
    obj.put(allocator, "output", .{ .string = output }) catch return error.OutOfMemory;
    if (argString(args, "title")) |title_value| obj.put(allocator, "title", .{ .string = title_value }) catch return error.OutOfMemory;
    const tmp_args = std.json.Value{ .object = obj };
    return zigFlamegraph(a, allocator, tmp_args);
}
