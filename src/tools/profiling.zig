const std = @import("std");
const mcp = @import("mcp");
const zigar = @import("zigar");

const backend_contracts = zigar.backend_contracts;
const command = zigar.command;
const common = @import("common.zig");
const profiling_backends = @import("profiling_backends.zig");

const App = common.App;
const ZflameRenderOptions = profiling_backends.ZflameRenderOptions;
const structured = common.structured;
const argString = common.argString;
const argBool = common.argBool;
const invalidArgumentResult = common.invalidArgumentResult;
const missingArgumentResult = common.missingArgumentResult;
const toolErrorResult = common.toolErrorResult;
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
        \\4. Use zig_flamegraph with an explicit format: {s}.
        \\5. For comparisons, generate folded stacks for before/after and call zig_flamegraph_diff.
        \\
    , .{ binary, binary, binary, backend_contracts.supportedZflameFormatsText() }) catch return error.OutOfMemory;
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
    const format_raw = argString(args, "format") orelse return missingArgumentResult(allocator, "zig_flamegraph", "format", backend_contracts.supportedZflameFormatsText());
    const format = backend_contracts.parseZflameFormat(format_raw) orelse return invalidZflameFormat(allocator, "zig_flamegraph", format_raw);
    const input = argString(args, "input") orelse return missingArgumentResult(allocator, "zig_flamegraph", "input", "workspace-relative profiler input path");
    const output = argString(args, "output") orelse return missingArgumentResult(allocator, "zig_flamegraph", "output", "workspace-relative SVG output path");
    const options = switch (try zflameOptionsFromArgs(allocator, "zig_flamegraph", args)) {
        .ok => |value| value,
        .err => |result| return result,
    };
    const input_abs = a.workspace.resolve(input) catch |err| return workspacePathErrorResult(a, allocator, "zig_flamegraph", input, err);
    defer allocator.free(input_abs);
    const output_abs = a.workspace.resolveOutput(output) catch |err| return workspacePathErrorResult(a, allocator, "zig_flamegraph", output, err);
    defer allocator.free(output_abs);

    const bytes = switch (try renderFlamegraphToWorkspace(a, allocator, .{
        .tool_name = "zig_flamegraph",
        .operation = "render_flamegraph",
        .input = input,
        .input_abs = input_abs,
        .output = output,
        .output_abs = output_abs,
        .format = format,
        .options = options,
    })) {
        .ok => |value| value,
        .err => |result| return result,
    };
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    obj.put(allocator, "kind", .{ .string = "zig_flamegraph" }) catch return error.OutOfMemory;
    obj.put(allocator, "backend", .{ .string = "zflame" }) catch return error.OutOfMemory;
    obj.put(allocator, "input", .{ .string = input }) catch return error.OutOfMemory;
    obj.put(allocator, "input_abs", .{ .string = input_abs }) catch return error.OutOfMemory;
    obj.put(allocator, "output", .{ .string = output }) catch return error.OutOfMemory;
    obj.put(allocator, "output_abs", .{ .string = output_abs }) catch return error.OutOfMemory;
    obj.put(allocator, "format", .{ .string = format.name() }) catch return error.OutOfMemory;
    obj.put(allocator, "bytes", .{ .integer = @intCast(bytes) }) catch return error.OutOfMemory;
    return structured(allocator, .{ .object = obj });
}

pub fn zigFlamegraphDiff(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const before = argString(args, "before") orelse return missingArgumentResult(allocator, "zig_flamegraph_diff", "before", "workspace-relative folded stack path");
    const after = argString(args, "after") orelse return missingArgumentResult(allocator, "zig_flamegraph_diff", "after", "workspace-relative folded stack path");
    const output = argString(args, "output") orelse return missingArgumentResult(allocator, "zig_flamegraph_diff", "output", "workspace-relative SVG output path");
    const options = switch (try zflameOptionsFromArgs(allocator, "zig_flamegraph_diff", args)) {
        .ok => |value| value,
        .err => |result| return result,
    };
    const before_abs = a.workspace.resolve(before) catch |err| return workspacePathErrorResult(a, allocator, "zig_flamegraph_diff", before, err);
    defer allocator.free(before_abs);
    const after_abs = a.workspace.resolve(after) catch |err| return workspacePathErrorResult(a, allocator, "zig_flamegraph_diff", after, err);
    defer allocator.free(after_abs);
    const output_abs = a.workspace.resolveOutput(output) catch |err| return workspacePathErrorResult(a, allocator, "zig_flamegraph_diff", output, err);
    defer allocator.free(output_abs);
    const temp_id = a.temp_counter.fetchAdd(1, .monotonic);
    const folded_name = std.fmt.allocPrint(allocator, "diff-{d}.folded", .{temp_id}) catch return error.OutOfMemory;
    defer allocator.free(folded_name);
    const folded_out = std.fmt.allocPrint(allocator, ".zigar-cache/profile/{s}", .{folded_name}) catch return error.OutOfMemory;
    defer allocator.free(folded_out);
    const folded_abs = a.workspace.resolveOutput(folded_out) catch |err| return workspacePathErrorResult(a, allocator, "zig_flamegraph_diff", folded_out, err);
    defer allocator.free(folded_abs);
    if (try ensureOutputParent(a, allocator, "zig_flamegraph_diff", folded_out, folded_abs)) |result| return result;
    var diff_argv = profiling_backends.buildDiffFoldedArgv(allocator, .{
        .executable = a.config.diff_folded_path,
        .output = folded_abs,
        .before = before_abs,
        .after = after_abs,
    }) catch return error.OutOfMemory;
    defer diff_argv.deinit(allocator);
    a.command_calls += 1;
    const diff = command.run(allocator, a.io, a.workspace.root, diff_argv.argv.items, a.config.timeout_ms) catch |err| {
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
            .argv = diff_argv.argv.items,
            .cwd = a.workspace.root,
            .timeout_ms = a.config.timeout_ms,
            .result = diff,
            .resolution = "Inspect stdout/stderr, confirm both folded-stack inputs are readable, and retry with a working diff-folded backend.",
        });
    }
    const folded = a.workspace.readFileAlloc(a.io, folded_out, command.output_limit) catch |err| return toolErrorFromError(allocator, .{
        .tool = "zig_flamegraph_diff",
        .operation = "verify_intermediate_diff",
        .phase = "read_intermediate_diff",
        .code = "workspace_artifact_read_failed",
        .category = "filesystem",
        .resolution = "Confirm diff-folded wrote the requested --output file inside .zigar-cache/profile and retry.",
        .details = &.{.{ .key = "output", .value = .{ .string = folded_out } }},
    }, err);
    defer allocator.free(folded);
    if (std.mem.trim(u8, folded, " \t\r\n").len == 0) return toolErrorResult(allocator, .{
        .tool = "zig_flamegraph_diff",
        .operation = "verify_intermediate_diff",
        .phase = "read_intermediate_diff",
        .code = "backend_output_malformed",
        .category = "backend_output",
        .resolution = "The diff-folded command completed but wrote an empty folded diff file.",
        .details = &.{.{ .key = "output", .value = .{ .string = folded_out } }},
    });
    const bytes = switch (try renderFlamegraphToWorkspace(a, allocator, .{
        .tool_name = "zig_flamegraph_diff",
        .operation = "render_differential_flamegraph",
        .input = folded_out,
        .input_abs = folded_abs,
        .output = output,
        .output_abs = output_abs,
        .format = .recursive,
        .options = options,
    })) {
        .ok => |value| value,
        .err => |result| return result,
    };
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    obj.put(allocator, "kind", .{ .string = "zig_flamegraph_diff" }) catch return error.OutOfMemory;
    obj.put(allocator, "backend", .{ .string = "zflame" }) catch return error.OutOfMemory;
    obj.put(allocator, "diff_backend", .{ .string = "diff-folded" }) catch return error.OutOfMemory;
    obj.put(allocator, "before", .{ .string = before }) catch return error.OutOfMemory;
    obj.put(allocator, "after", .{ .string = after }) catch return error.OutOfMemory;
    obj.put(allocator, "intermediate", .{ .string = folded_out }) catch return error.OutOfMemory;
    obj.put(allocator, "intermediate_abs", .{ .string = folded_abs }) catch return error.OutOfMemory;
    obj.put(allocator, "intermediate_bytes", .{ .integer = @intCast(folded.len) }) catch return error.OutOfMemory;
    obj.put(allocator, "input", .{ .string = folded_out }) catch return error.OutOfMemory;
    obj.put(allocator, "output", .{ .string = output }) catch return error.OutOfMemory;
    obj.put(allocator, "output_abs", .{ .string = output_abs }) catch return error.OutOfMemory;
    obj.put(allocator, "format", .{ .string = backend_contracts.ZflameFormat.recursive.name() }) catch return error.OutOfMemory;
    obj.put(allocator, "bytes", .{ .integer = @intCast(bytes) }) catch return error.OutOfMemory;
    return structured(allocator, .{ .object = obj });
}

const OptionsResult = union(enum) {
    ok: ZflameRenderOptions,
    err: mcp.tools.ToolResult,
};

fn zflameOptionsFromArgs(allocator: std.mem.Allocator, tool_name: []const u8, args: ?std.json.Value) mcp.tools.ToolError!OptionsResult {
    const width = switch (try positiveIntArg(allocator, tool_name, args, "width")) {
        .ok => |value| value,
        .err => |result| return .{ .err = result },
    };
    const min_width = switch (try positiveIntArg(allocator, tool_name, args, "min_width")) {
        .ok => |value| value,
        .err => |result| return .{ .err = result },
    };
    return .{ .ok = .{
        .title = argString(args, "title"),
        .subtitle = argString(args, "subtitle"),
        .colors = argString(args, "colors"),
        .width = width,
        .min_width = min_width,
        .hash = argBool(args, "hash", false),
    } };
}

const OptionalIntResult = union(enum) {
    ok: ?i64,
    err: mcp.tools.ToolResult,
};

fn positiveIntArg(allocator: std.mem.Allocator, tool_name: []const u8, args: ?std.json.Value, name: []const u8) mcp.tools.ToolError!OptionalIntResult {
    const value = mcp.tools.getInteger(args, name) orelse return .{ .ok = null };
    if (value > 0) return .{ .ok = value };
    return .{ .err = try invalidArgumentResult(allocator, tool_name, name, "positive integer", "zero or negative", "Use positive pixel values for zflame sizing options.") };
}

fn invalidZflameFormat(allocator: std.mem.Allocator, tool_name: []const u8, actual: []const u8) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invalidArgumentResult(
        allocator,
        tool_name,
        "format",
        backend_contracts.supportedZflameFormatsText(),
        actual,
        "Choose an explicit zflame input format from the tools/list schema; zigar does not expose format guessing.",
    );
}

const RenderRequest = struct {
    tool_name: []const u8,
    operation: []const u8,
    input: []const u8,
    input_abs: []const u8,
    output: []const u8,
    output_abs: []const u8,
    format: backend_contracts.ZflameFormat,
    options: ZflameRenderOptions,
};

const RenderResult = union(enum) {
    ok: usize,
    err: mcp.tools.ToolResult,
};

fn renderFlamegraphToWorkspace(a: *App, allocator: std.mem.Allocator, request: RenderRequest) mcp.tools.ToolError!RenderResult {
    var argv = profiling_backends.buildZflameArgv(allocator, .{
        .executable = a.config.zflame_path,
        .format = request.format,
        .input = request.input_abs,
        .options = request.options,
    }) catch return error.OutOfMemory;
    defer argv.deinit(allocator);
    a.command_calls += 1;
    const result = command.run(allocator, a.io, a.workspace.root, argv.argv.items, a.config.timeout_ms) catch |err| {
        return .{ .err = try backendErrorResult(allocator, "zflame", "render", err, "confirm --zflame-path points to an executable zflame binary and that profiler input is readable") };
    };
    defer result.deinit(allocator);
    if (!result.succeeded()) {
        return .{ .err = try commandResultErrorResult(allocator, .{
            .tool = request.tool_name,
            .operation = request.operation,
            .phase = "run_zflame",
            .code = "zflame_command_failed",
            .backend = "zflame",
            .argv = argv.argv.items,
            .cwd = a.workspace.root,
            .timeout_ms = a.config.timeout_ms,
            .result = result,
            .resolution = "Inspect stdout/stderr, confirm the profiler input format is correct, and retry with a supported zflame invocation.",
        }) };
    }
    if (!profiling_backends.looksLikeSvg(result.stdout)) return .{ .err = try toolErrorResult(allocator, .{
        .tool = request.tool_name,
        .operation = request.operation,
        .phase = "validate_svg",
        .code = "backend_output_malformed",
        .category = "backend_output",
        .resolution = "The zflame command completed but stdout did not look like an SVG document. Run zflame directly with the same input and options.",
        .details = &.{
            .{ .key = "backend", .value = .{ .string = "zflame" } },
            .{ .key = "format", .value = .{ .string = request.format.name() } },
            .{ .key = "input", .value = .{ .string = request.input } },
        },
    }) };
    a.workspace.writeFile(a.io, request.output, result.stdout) catch |err| return .{ .err = try toolErrorFromError(allocator, .{
        .tool = request.tool_name,
        .operation = request.operation,
        .phase = "workspace_write",
        .code = "workspace_artifact_write_failed",
        .category = "filesystem",
        .resolution = "Choose an output path inside the workspace that zigar can create or overwrite.",
        .details = &.{
            .{ .key = "output", .value = .{ .string = request.output } },
            .{ .key = "output_abs", .value = .{ .string = request.output_abs } },
        },
    }, err) };
    return .{ .ok = result.stdout.len };
}

fn ensureOutputParent(a: *App, allocator: std.mem.Allocator, tool_name: []const u8, output: []const u8, output_abs: []const u8) mcp.tools.ToolError!?mcp.tools.ToolResult {
    const parent = std.fs.path.dirname(output_abs) orelse return null;
    std.Io.Dir.cwd().createDirPath(a.io, parent) catch |err| return try toolErrorFromError(allocator, .{
        .tool = tool_name,
        .operation = "prepare_backend_output",
        .phase = "create_output_parent",
        .code = "workspace_artifact_write_failed",
        .category = "filesystem",
        .resolution = "Choose a workspace-local output path whose parent directory can be created.",
        .details = &.{.{ .key = "output", .value = .{ .string = output } }},
    }, err);
    return null;
}
