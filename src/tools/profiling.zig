const std = @import("std");
const mcp = @import("mcp");
const zigar = @import("zigar");

const backend_contracts = zigar.backend_contracts;
const command = zigar.command;
const common = @import("common.zig");
const doctor = zigar.doctor;
const profiling_backends = @import("profiling_backends.zig");
const profiling_plan = @import("profiling_plan.zig");

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
const freeArgList = common.freeArgList;
const argvValue = common.argvValue;
const cachedProbeValue = common.cachedProbeValue;
const capture_semantics = profiling_plan.capture_semantics;

pub const profilePlanValue = profiling_plan.profilePlanValue;

pub fn zigProfilePlan(_: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const value = profilePlanValue(arena.allocator(), args) catch return error.OutOfMemory;
    return structured(allocator, value);
}

pub fn zigProfileRun(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const cmd = argString(args, "command") orelse return missingArgumentResult(allocator, "zig_profile_run", "command", "shell-style command string");
    const split = splitToolArgs(allocator, cmd) catch |err| return splitToolArgsErrorResult(allocator, "zig_profile_run", "command", cmd, err);
    defer freeArgList(allocator, split);
    if (split.len == 0) return invalidArgumentResult(allocator, "zig_profile_run", "command", "non-empty command string", cmd, "Pass the executable and arguments to run under the profiler.");
    return runAndFormatTimeout(a, allocator, split, "explicit user profiler command (argv split without shell)", toolTimeout(a, args));
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
    if (try ensureInputReadable(a, allocator, "zig_flamegraph", "render_flamegraph", input, input_abs)) |result| return result;
    const output_abs = a.workspace.resolveOutput(output) catch |err| return workspacePathErrorResult(a, allocator, "zig_flamegraph", output, err);
    defer allocator.free(output_abs);

    var render = switch (try renderFlamegraphToWorkspace(a, allocator, .{
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
    defer render.deinit(allocator);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const value = flamegraphResultValue(arena.allocator(), a, .{
        .tool_name = "zig_flamegraph",
        .operation = "render_flamegraph",
        .input = input,
        .input_abs = input_abs,
        .output = output,
        .output_abs = output_abs,
        .format = format,
        .options = options,
    }, render) catch return error.OutOfMemory;
    return structured(allocator, value);
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
    if (try ensureInputReadable(a, allocator, "zig_flamegraph_diff", "diff_folded_stacks", before, before_abs)) |result| return result;
    const after_abs = a.workspace.resolve(after) catch |err| return workspacePathErrorResult(a, allocator, "zig_flamegraph_diff", after, err);
    defer allocator.free(after_abs);
    if (try ensureInputReadable(a, allocator, "zig_flamegraph_diff", "diff_folded_stacks", after, after_abs)) |result| return result;
    const output_abs = a.workspace.resolveOutput(output) catch |err| return workspacePathErrorResult(a, allocator, "zig_flamegraph_diff", output, err);
    defer allocator.free(output_abs);
    const folded_out = if (argString(args, "intermediate")) |path|
        allocator.dupe(u8, path) catch return error.OutOfMemory
    else blk: {
        const temp_id = a.temp_counter.fetchAdd(1, .monotonic);
        const folded_name = std.fmt.allocPrint(allocator, "diff-{d}.folded", .{temp_id}) catch return error.OutOfMemory;
        defer allocator.free(folded_name);
        break :blk std.fmt.allocPrint(allocator, ".zigar-cache/profile/{s}", .{folded_name}) catch return error.OutOfMemory;
    };
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
    var diff_render = DiffFoldedArtifact{
        .bytes = 0,
        .argv = cloneArgv(allocator, diff_argv.argv.items) catch return error.OutOfMemory,
    };
    defer diff_render.deinit(allocator);
    const folded = a.workspace.readFileAlloc(a.io, folded_out, command.output_limit) catch |err| return toolErrorFromError(allocator, .{
        .tool = "zig_flamegraph_diff",
        .operation = "verify_intermediate_diff",
        .phase = "read_intermediate_diff",
        .code = "workspace_artifact_read_failed",
        .category = "filesystem",
        .resolution = "Confirm diff-folded wrote the requested --output file inside .zigar-cache/profile and retry.",
        .details = &.{.{ .key = "output", .value = .{ .string = folded_out } }},
    }, err);
    diff_render.bytes = folded.len;
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
    var render = switch (try renderFlamegraphToWorkspace(a, allocator, .{
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
    defer render.deinit(allocator);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const value = flamegraphDiffResultValue(arena.allocator(), a, .{
        .tool_name = "zig_flamegraph_diff",
        .operation = "render_differential_flamegraph",
        .input = folded_out,
        .input_abs = folded_abs,
        .output = output,
        .output_abs = output_abs,
        .format = .recursive,
        .options = options,
    }, render, .{
        .before = before,
        .before_abs = before_abs,
        .after = after,
        .after_abs = after_abs,
        .intermediate = folded_out,
        .intermediate_abs = folded_abs,
        .artifact = diff_render,
    }) catch return error.OutOfMemory;
    return structured(allocator, value);
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

const OwnedArgv = struct {
    items: [][]const u8,

    fn deinit(self: *OwnedArgv, allocator: std.mem.Allocator) void {
        for (self.items) |arg| allocator.free(arg);
        allocator.free(self.items);
    }
};

const FlamegraphArtifact = struct {
    bytes: usize,
    argv: OwnedArgv,

    fn deinit(self: *FlamegraphArtifact, allocator: std.mem.Allocator) void {
        self.argv.deinit(allocator);
    }
};

const DiffFoldedArtifact = struct {
    bytes: usize,
    argv: OwnedArgv,

    fn deinit(self: *DiffFoldedArtifact, allocator: std.mem.Allocator) void {
        self.argv.deinit(allocator);
    }
};

const DiffMetadata = struct {
    before: []const u8,
    before_abs: []const u8,
    after: []const u8,
    after_abs: []const u8,
    intermediate: []const u8,
    intermediate_abs: []const u8,
    artifact: DiffFoldedArtifact,
};

const RenderResult = union(enum) {
    ok: FlamegraphArtifact,
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
    return .{ .ok = .{
        .bytes = result.stdout.len,
        .argv = cloneArgv(allocator, argv.argv.items) catch return error.OutOfMemory,
    } };
}

fn flamegraphResultValue(allocator: std.mem.Allocator, a: *App, request: RenderRequest, artifact: FlamegraphArtifact) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = request.tool_name });
    try obj.put(allocator, "backend", .{ .string = "zflame" });
    try obj.put(allocator, "input", .{ .string = request.input });
    try obj.put(allocator, "input_abs", .{ .string = request.input_abs });
    try obj.put(allocator, "output", .{ .string = request.output });
    try obj.put(allocator, "output_abs", .{ .string = request.output_abs });
    try obj.put(allocator, "format", .{ .string = request.format.name() });
    try obj.put(allocator, "input_format", .{ .string = request.format.name() });
    try obj.put(allocator, "bytes", .{ .integer = @intCast(artifact.bytes) });
    try obj.put(allocator, "backend_executable_path", .{ .string = a.config.zflame_path });
    try obj.put(allocator, "backend_metadata", try backendMetadataValue(allocator, a, .zflame, a.config.zflame_path, "rendered_ok", backend_contracts.zflame_compatibility_baseline));
    try obj.put(allocator, "argv_shape", .{ .string = zflameArgvShape() });
    try obj.put(allocator, "argv", try argvValue(allocator, artifact.argv.items));
    try obj.put(allocator, "warnings", try renderWarningsValue(allocator, cachedProbeFor(a, .zflame)));
    try obj.put(allocator, "compatibility_status", .{ .string = "rendered_ok" });
    try obj.put(allocator, "capture_semantics", .{ .string = capture_semantics });
    return .{ .object = obj };
}

fn flamegraphDiffResultValue(allocator: std.mem.Allocator, a: *App, request: RenderRequest, artifact: FlamegraphArtifact, diff: DiffMetadata) !std.json.Value {
    var obj = (try flamegraphResultValue(allocator, a, request, artifact)).object;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zig_flamegraph_diff" });
    try obj.put(allocator, "diff_backend", .{ .string = "diff-folded" });
    try obj.put(allocator, "before", .{ .string = diff.before });
    try obj.put(allocator, "before_abs", .{ .string = diff.before_abs });
    try obj.put(allocator, "after", .{ .string = diff.after });
    try obj.put(allocator, "after_abs", .{ .string = diff.after_abs });
    try obj.put(allocator, "intermediate", .{ .string = diff.intermediate });
    try obj.put(allocator, "intermediate_abs", .{ .string = diff.intermediate_abs });
    try obj.put(allocator, "intermediate_bytes", .{ .integer = @intCast(diff.artifact.bytes) });
    try obj.put(allocator, "intermediate_folded", try intermediateFoldedValue(allocator, a, diff));
    return .{ .object = obj };
}

fn intermediateFoldedValue(allocator: std.mem.Allocator, a: *App, diff: DiffMetadata) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "path", .{ .string = diff.intermediate });
    try obj.put(allocator, "abs_path", .{ .string = diff.intermediate_abs });
    try obj.put(allocator, "input_format", .{ .string = backend_contracts.ZflameFormat.recursive.name() });
    try obj.put(allocator, "bytes", .{ .integer = @intCast(diff.artifact.bytes) });
    try obj.put(allocator, "source_before", .{ .string = diff.before });
    try obj.put(allocator, "source_before_abs", .{ .string = diff.before_abs });
    try obj.put(allocator, "source_after", .{ .string = diff.after });
    try obj.put(allocator, "source_after_abs", .{ .string = diff.after_abs });
    try obj.put(allocator, "backend", .{ .string = "diff-folded" });
    try obj.put(allocator, "backend_executable_path", .{ .string = a.config.diff_folded_path });
    try obj.put(allocator, "backend_metadata", try backendMetadataValue(allocator, a, .diff_folded, a.config.diff_folded_path, "diff_written_and_read_ok", backend_contracts.diff_folded_compatibility_baseline));
    try obj.put(allocator, "argv_shape", .{ .string = diffFoldedArgvShape() });
    try obj.put(allocator, "argv", try argvValue(allocator, diff.artifact.argv.items));
    try obj.put(allocator, "warnings", try renderWarningsValue(allocator, cachedProbeFor(a, .diff_folded)));
    try obj.put(allocator, "compatibility_status", .{ .string = "diff_written_and_read_ok" });
    return .{ .object = obj };
}

fn backendMetadataValue(
    allocator: std.mem.Allocator,
    a: *App,
    id: backend_contracts.BackendId,
    executable_path: []const u8,
    compatibility_status: []const u8,
    compatibility_baseline: []const u8,
) !std.json.Value {
    const probe = cachedProbeFor(a, id);
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "name", .{ .string = id.name() });
    try obj.put(allocator, "executable_path", .{ .string = executable_path });
    try obj.put(allocator, "probe", try cachedProbeValue(allocator, probe));
    try obj.put(allocator, "version", try unknownVersionValue(allocator, id));
    try obj.put(allocator, "compatibility_status", .{ .string = compatibility_status });
    try obj.put(allocator, "compatibility_baseline", .{ .string = compatibility_baseline });
    try obj.put(allocator, "probe_status", .{ .string = if (probe) |p| if (p.ok) "probe_ok" else "probe_failed" else "unknown" });
    return .{ .object = obj };
}

fn unknownVersionValue(allocator: std.mem.Allocator, id: backend_contracts.BackendId) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "status", .{ .string = "unknown" });
    try obj.put(allocator, "value", .null);
    try obj.put(allocator, "source", .{ .string = try std.fmt.allocPrint(allocator, "{s} probe uses --help and does not define a stable version field for artifact metadata", .{id.name()}) });
    return .{ .object = obj };
}

fn renderWarningsValue(allocator: std.mem.Allocator, probe: ?doctor.Probe) !std.json.Value {
    var warnings = std.json.Array.init(allocator);
    errdefer warnings.deinit();
    try warnings.append(.{ .string = capture_semantics });
    if (probe == null) {
        try warnings.append(.{ .string = "backend probe and version are unknown for this artifact; run zigar_doctor with probe_backends=true to cache probe status" });
    }
    return .{ .array = warnings };
}

fn cachedProbeFor(a: *App, id: backend_contracts.BackendId) ?doctor.Probe {
    return switch (id) {
        .zig => a.backend_probe_cache.zig,
        .zls => a.backend_probe_cache.zls,
        .zwanzig => a.backend_probe_cache.zwanzig,
        .zflame => a.backend_probe_cache.zflame,
        .diff_folded => a.backend_probe_cache.diff_folded,
    };
}

fn zflameArgvShape() []const u8 {
    return backend_contracts.capabilityFor("zig_flamegraph").?.argv_shape;
}

fn diffFoldedArgvShape() []const u8 {
    return backend_contracts.capabilityFor("zig_flamegraph_diff").?.argv_shape;
}

fn cloneArgv(allocator: std.mem.Allocator, argv: []const []const u8) !OwnedArgv {
    const items = try allocator.alloc([]const u8, argv.len);
    var filled: usize = 0;
    errdefer {
        for (items[0..filled]) |arg| allocator.free(arg);
        allocator.free(items);
    }
    for (argv, 0..) |arg, index| {
        items[index] = try allocator.dupe(u8, arg);
        filled += 1;
    }
    return .{ .items = items };
}

fn ensureInputReadable(
    a: *App,
    allocator: std.mem.Allocator,
    tool_name: []const u8,
    operation: []const u8,
    input: []const u8,
    input_abs: []const u8,
) mcp.tools.ToolError!?mcp.tools.ToolResult {
    var file = std.Io.Dir.cwd().openFile(a.io, input_abs, .{}) catch |err| return try toolErrorFromError(allocator, .{
        .tool = tool_name,
        .operation = operation,
        .phase = "read_workspace_input",
        .code = "workspace_input_read_failed",
        .category = "filesystem",
        .resolution = "Pass an existing readable profiler input file inside the configured workspace.",
        .details = &.{
            .{ .key = "input", .value = .{ .string = input } },
            .{ .key = "input_abs", .value = .{ .string = input_abs } },
        },
    }, err);
    file.close(a.io);
    return null;
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
