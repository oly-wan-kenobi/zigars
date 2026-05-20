const std = @import("std");
const builtin = @import("builtin");
const mcp = @import("mcp");
const zigar = @import("zigar");

const backend_contracts = zigar.backend_contracts;
const command = zigar.command;
const common = @import("common.zig");
const doctor = zigar.doctor;
const json_result = zigar.json_result;
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
const freeArgList = common.freeArgList;
const argvValue = common.argvValue;
const cachedProbeValue = common.cachedProbeValue;

const capture_semantics = "zigar does not execute or define profiler capture semantics; external profilers own sampling, permissions, symbols, privilege requirements, and output fidelity.";

fn profilePlanValue(allocator: std.mem.Allocator, args: ?std.json.Value) !std.json.Value {
    const binary = argString(args, "binary") orelse "zig-out/bin/<app>";
    const requested_platform = argString(args, "platform");
    const selected_platform = if (requested_platform) |platform| platform else detectedPlatform();
    const output_prefix = argString(args, "output_prefix") orelse ".zigar-cache/profile/profile";
    const svg_output = try std.fmt.allocPrint(allocator, "{s}.svg", .{output_prefix});

    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zig_profile_plan" });
    try obj.put(allocator, "binary", .{ .string = binary });
    try obj.put(allocator, "detected_platform", .{ .string = detectedPlatform() });
    if (requested_platform) |platform| {
        try obj.put(allocator, "requested_platform", .{ .string = platform });
    } else {
        try obj.put(allocator, "requested_platform", .null);
    }
    try obj.put(allocator, "selected_platform", .{ .string = selected_platform });
    try obj.put(allocator, "capture_semantics", .{ .string = capture_semantics });
    try obj.put(allocator, "supported_zflame_formats", try stringArrayValue(allocator, backend_contracts.zflame_format_names[0..]));
    try obj.put(allocator, "recommended_plan_ids", try recommendedPlanIdsValue(allocator, selected_platform));
    try obj.put(allocator, "plans", try capturePlansValue(allocator, binary, output_prefix, svg_output));
    try obj.put(allocator, "diff_workflow", try diffWorkflowValue(allocator, output_prefix));
    return .{ .object = obj };
}

fn detectedPlatform() []const u8 {
    return switch (builtin.os.tag) {
        .linux => "linux",
        .macos => "macos",
        .freebsd => "freebsd",
        .illumos => "illumos",
        .windows => "windows",
        else => @tagName(builtin.os.tag),
    };
}

fn capturePlansValue(allocator: std.mem.Allocator, binary: []const u8, output_prefix: []const u8, svg_output: []const u8) !std.json.Value {
    var plans = std.json.Array.init(allocator);
    errdefer plans.deinit();
    try plans.append(try capturePlanValue(allocator, .{
        .id = "linux_perf",
        .platforms = &.{"linux"},
        .required_profiler = "perf",
        .captured_output = try std.fmt.allocPrint(allocator, "{s}.perf.data", .{output_prefix}),
        .zflame_format = .perf,
        .command = try std.fmt.allocPrint(allocator, "perf record -F 997 -g -o {s}.perf.data -- {s}", .{ output_prefix, binary }),
        .prerequisites = &.{ "Linux perf installed", "kernel perf_event permissions allow sampling", "binary built with symbols or usable debug info" },
        .limitations = &.{ "perf privilege, callchain mode, kernel settings, and symbolization quality are external to zigar", capture_semantics },
        .svg_output = svg_output,
    }));
    try plans.append(try capturePlanValue(allocator, .{
        .id = "macos_sample",
        .platforms = &.{"macos"},
        .required_profiler = "sample",
        .captured_output = try std.fmt.allocPrint(allocator, "{s}.sample.txt", .{output_prefix}),
        .zflame_format = .sample,
        .command = try std.fmt.allocPrint(allocator, "sample <pid> 10 -file {s}.sample.txt", .{output_prefix}),
        .prerequisites = &.{ "macOS sample available", "target process is already running", "terminal has required sampling permissions" },
        .limitations = &.{ "sample attaches to an existing pid instead of launching the binary", capture_semantics },
        .svg_output = svg_output,
    }));
    try plans.append(try capturePlanValue(allocator, .{
        .id = "macos_xctrace",
        .platforms = &.{"macos"},
        .required_profiler = "xctrace",
        .captured_output = try std.fmt.allocPrint(allocator, "{s}.trace", .{output_prefix}),
        .zflame_format = .xctrace,
        .command = try std.fmt.allocPrint(allocator, "xcrun xctrace record --template \"Time Profiler\" --output {s}.trace --launch -- {s}", .{ output_prefix, binary }),
        .prerequisites = &.{ "Xcode command line tools", "Time Profiler template available", "binary can be launched by xctrace" },
        .limitations = &.{ "xctrace capture templates and trace contents are controlled by Apple tooling", capture_semantics },
        .svg_output = svg_output,
    }));
    try plans.append(try capturePlanValue(allocator, .{
        .id = "dtrace",
        .platforms = &.{ "macos", "freebsd", "illumos" },
        .required_profiler = "dtrace",
        .captured_output = try std.fmt.allocPrint(allocator, "{s}.dtrace.txt", .{output_prefix}),
        .zflame_format = .dtrace,
        .command = try std.fmt.allocPrint(allocator, "sudo dtrace -x ustackframes=100 -n 'profile-997 /pid == $target/ {{ @[ustack()] = count(); }}' -c '{s}' -o {s}.dtrace.txt", .{ binary, output_prefix }),
        .prerequisites = &.{ "DTrace available on the host", "required privileges granted", "target binary and symbols visible to DTrace" },
        .limitations = &.{ "DTrace availability and restrictions vary by OS release and security policy", capture_semantics },
        .svg_output = svg_output,
    }));
    try plans.append(try capturePlanValue(allocator, .{
        .id = "vtune",
        .platforms = &.{ "linux", "windows" },
        .required_profiler = "vtune",
        .captured_output = try std.fmt.allocPrint(allocator, "{s}.vtune", .{output_prefix}),
        .zflame_format = .vtune,
        .command = try std.fmt.allocPrint(allocator, "vtune -collect hotspots -result-dir {s}.vtune -- {s}", .{ output_prefix, binary }),
        .prerequisites = &.{ "Intel VTune installed", "project license/environment configured", "VTune can launch or attach to the target" },
        .limitations = &.{ "VTune collection mode, result schema, and permissions are external to zigar", capture_semantics },
        .svg_output = svg_output,
    }));
    try plans.append(try capturePlanValue(allocator, .{
        .id = "already_folded_recursive",
        .platforms = &.{ "linux", "macos", "freebsd", "illumos", "windows" },
        .required_profiler = "already-folded recursive stacks",
        .captured_output = try std.fmt.allocPrint(allocator, "{s}.folded", .{output_prefix}),
        .zflame_format = .recursive,
        .command = try std.fmt.allocPrint(allocator, "<external folded-stack producer> > {s}.folded", .{output_prefix}),
        .prerequisites = &.{ "input is folded-stack text in recursive format", "capture or stack collapsing happened outside zigar" },
        .limitations = &.{ "zigar renders folded stacks but does not verify how they were captured or collapsed", capture_semantics },
        .svg_output = svg_output,
    }));
    return .{ .array = plans };
}

const CapturePlanSpec = struct {
    id: []const u8,
    platforms: []const []const u8,
    required_profiler: []const u8,
    captured_output: []const u8,
    zflame_format: backend_contracts.ZflameFormat,
    command: []const u8,
    prerequisites: []const []const u8,
    limitations: []const []const u8,
    svg_output: []const u8,
};

fn capturePlanValue(allocator: std.mem.Allocator, spec: CapturePlanSpec) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "id", .{ .string = spec.id });
    try obj.put(allocator, "platforms", try stringArrayValue(allocator, spec.platforms));
    try obj.put(allocator, "required_profiler", .{ .string = spec.required_profiler });
    try obj.put(allocator, "recommended_external_command", .{ .string = spec.command });
    try obj.put(allocator, "expected_captured_output_path", .{ .string = spec.captured_output });
    try obj.put(allocator, "zflame_input_format", .{ .string = spec.zflame_format.name() });
    try obj.put(allocator, "next_zigar_command", try nextZigarCommandValue(allocator, spec.zflame_format, spec.captured_output, spec.svg_output));
    try obj.put(allocator, "prerequisites", try stringArrayValue(allocator, spec.prerequisites));
    try obj.put(allocator, "limitations", try stringArrayValue(allocator, spec.limitations));
    try obj.put(allocator, "capture_owned_by", .{ .string = "external_profiler" });
    try obj.put(allocator, "capture_semantics", .{ .string = capture_semantics });
    return .{ .object = obj };
}

fn nextZigarCommandValue(allocator: std.mem.Allocator, format: backend_contracts.ZflameFormat, input: []const u8, output: []const u8) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "tool", .{ .string = "zig_flamegraph" });
    try obj.put(allocator, "format", .{ .string = format.name() });
    try obj.put(allocator, "input", .{ .string = input });
    try obj.put(allocator, "output", .{ .string = output });
    try obj.put(allocator, "command", .{ .string = try std.fmt.allocPrint(allocator, "zig_flamegraph {{\"format\":\"{s}\",\"input\":\"{s}\",\"output\":\"{s}\"}}", .{ format.name(), input, output }) });
    return .{ .object = obj };
}

fn recommendedPlanIdsValue(allocator: std.mem.Allocator, platform: []const u8) !std.json.Value {
    if (std.mem.eql(u8, platform, "linux")) return stringArrayValue(allocator, &.{ "linux_perf", "vtune", "already_folded_recursive" });
    if (std.mem.eql(u8, platform, "macos")) return stringArrayValue(allocator, &.{ "macos_xctrace", "macos_sample", "dtrace", "already_folded_recursive" });
    if (std.mem.eql(u8, platform, "freebsd") or std.mem.eql(u8, platform, "illumos")) return stringArrayValue(allocator, &.{ "dtrace", "already_folded_recursive" });
    if (std.mem.eql(u8, platform, "windows")) return stringArrayValue(allocator, &.{ "vtune", "already_folded_recursive" });
    return stringArrayValue(allocator, &.{"already_folded_recursive"});
}

fn diffWorkflowValue(allocator: std.mem.Allocator, output_prefix: []const u8) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "tool", .{ .string = "zig_flamegraph_diff" });
    try obj.put(allocator, "required_inputs", try stringArrayValue(allocator, &.{ "before.folded", "after.folded" }));
    try obj.put(allocator, "canonical_diff_backend", .{ .string = "diff-folded" });
    try obj.put(allocator, "canonical_renderer", .{ .string = "zflame recursive" });
    try obj.put(allocator, "suggested_output", .{ .string = try std.fmt.allocPrint(allocator, "{s}-diff.svg", .{output_prefix}) });
    try obj.put(allocator, "capture_semantics", .{ .string = capture_semantics });
    return .{ .object = obj };
}

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

fn stringArrayValue(allocator: std.mem.Allocator, values: []const []const u8) !std.json.Value {
    var array = std.json.Array.init(allocator);
    errdefer array.deinit();
    for (values) |value| try array.append(.{ .string = value });
    return .{ .array = array };
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

test "profile plan returns structured external capture plans" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var args = std.json.ObjectMap.empty;
    try args.put(arena.allocator(), "binary", .{ .string = "zig-out/bin/demo" });
    try args.put(arena.allocator(), "platform", .{ .string = "linux" });
    try args.put(arena.allocator(), "output_prefix", .{ .string = ".zigar-cache/profile/demo" });

    const value = try profilePlanValue(arena.allocator(), .{ .object = args });
    const root = value.object;
    try std.testing.expectEqualStrings("zig_profile_plan", root.get("kind").?.string);
    try std.testing.expectEqualStrings("linux", root.get("selected_platform").?.string);
    try std.testing.expect(std.mem.indexOf(u8, root.get("capture_semantics").?.string, "does not execute or define") != null);
    try std.testing.expectEqual(@as(usize, 6), root.get("plans").?.array.items.len);
    try std.testing.expectEqual(@as(usize, backend_contracts.zflame_format_names.len), root.get("supported_zflame_formats").?.array.items.len);
    try std.testing.expectEqualStrings("linux_perf", root.get("recommended_plan_ids").?.array.items[0].string);
    try std.testing.expectEqualStrings("diff-folded", root.get("diff_workflow").?.object.get("canonical_diff_backend").?.string);
    try std.testing.expectEqualStrings("zflame recursive", root.get("diff_workflow").?.object.get("canonical_renderer").?.string);

    const perf = root.get("plans").?.array.items[0].object;
    try std.testing.expectEqualStrings("linux_perf", perf.get("id").?.string);
    try std.testing.expectEqualStrings("perf", perf.get("zflame_input_format").?.string);
    try std.testing.expectEqualStrings("zig_flamegraph", perf.get("next_zigar_command").?.object.get("tool").?.string);
    try std.testing.expect(std.mem.indexOf(u8, perf.get("next_zigar_command").?.object.get("command").?.string, "zig_flamegraph") != null);

    const folded = root.get("plans").?.array.items[5].object;
    try std.testing.expectEqualStrings("already_folded_recursive", folded.get("id").?.string);
    try std.testing.expectEqualStrings("recursive", folded.get("zflame_input_format").?.string);
}

const zflame_ok_script =
    \\#!/bin/sh
    \\if [ "$1" = "--help" ]; then echo "fake zflame help"; exit 0; fi
    \\printf '<svg xmlns="http://www.w3.org/2000/svg"><title>%s</title></svg>\n' "$1"
    \\
;

const zflame_non_svg_script =
    \\#!/bin/sh
    \\if [ "$1" = "--help" ]; then echo "fake zflame help"; exit 0; fi
    \\echo "main;not-svg 1"
    \\
;

const diff_ok_script =
    \\#!/bin/sh
    \\if [ "$1" = "--help" ]; then echo "fake diff-folded help"; exit 0; fi
    \\case "$1" in --output=*) out=${1#--output=};; *) echo "missing output" >&2; exit 2;; esac
    \\mkdir -p "$(dirname "$out")"
    \\printf 'main;delta 2\n' > "$out"
    \\
;

const diff_empty_script =
    \\#!/bin/sh
    \\case "$1" in --output=*) out=${1#--output=};; *) echo "missing output" >&2; exit 2;; esac
    \\mkdir -p "$(dirname "$out")"
    \\: > "$out"
    \\
;

const diff_fail_script =
    \\#!/bin/sh
    \\echo "diff failed" >&2
    \\exit 9
    \\
;

var profiling_test_counter = std.atomic.Value(u64).init(0);

const ProfilingTestEnv = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    tmp_root: []const u8,
    root: []const u8,
    zflame_path: []const u8,
    diff_folded_path: []const u8,
    app: App,

    fn init(allocator: std.mem.Allocator, zflame_script: []const u8, diff_script: []const u8) !ProfilingTestEnv {
        const io = std.testing.io;
        const tmp_id = profiling_test_counter.fetchAdd(1, .monotonic);
        const tmp_root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/profiling-test-{x}-{d}", .{ std.Thread.getCurrentId(), tmp_id });
        errdefer allocator.free(tmp_root);
        errdefer cleanupProfilingTemp(io, tmp_root);
        const root_rel = try std.fs.path.join(allocator, &.{ tmp_root, "root" });
        defer allocator.free(root_rel);
        const bin_rel = try std.fs.path.join(allocator, &.{ root_rel, "bin" });
        defer allocator.free(bin_rel);
        try std.Io.Dir.cwd().createDirPath(io, bin_rel);
        try writeFixtureFile(io, allocator, root_rel, "stacks.folded", "main;work 7\n");
        try writeFixtureFile(io, allocator, root_rel, "before.folded", "main;old 3\n");
        try writeFixtureFile(io, allocator, root_rel, "after.folded", "main;new 5\n");

        const rel_base = tmp_root;
        const base_z = try std.Io.Dir.cwd().realPathFileAlloc(io, rel_base, allocator);
        defer allocator.free(base_z);
        const root = try std.fs.path.join(allocator, &.{ base_z[0..], "root" });
        errdefer allocator.free(root);
        const zflame_path = try std.fs.path.join(allocator, &.{ root, "bin", "zflame-fixture" });
        errdefer allocator.free(zflame_path);
        const diff_folded_path = try std.fs.path.join(allocator, &.{ root, "bin", "diff-folded-fixture" });
        errdefer allocator.free(diff_folded_path);
        try writeExecutableFile(io, zflame_path, zflame_script);
        try writeExecutableFile(io, diff_folded_path, diff_script);

        var config = try zigar.config.parse(allocator, io, &.{
            "zigar",
            "--workspace",
            root,
            "--zflame-path",
            zflame_path,
            "--diff-folded-path",
            diff_folded_path,
            "--timeout-ms",
            "5000",
        });
        errdefer config.deinit(allocator);
        var workspace = try zigar.workspace.Workspace.init(allocator, io, root, null);
        errdefer workspace.deinit();
        return .{
            .allocator = allocator,
            .io = io,
            .tmp_root = tmp_root,
            .root = root,
            .zflame_path = zflame_path,
            .diff_folded_path = diff_folded_path,
            .app = .{ .allocator = allocator, .io = io, .config = config, .workspace = workspace },
        };
    }

    fn deinit(self: *ProfilingTestEnv) void {
        self.app.workspace.deinit();
        self.app.config.deinit(self.allocator);
        self.allocator.free(self.root);
        self.allocator.free(self.zflame_path);
        self.allocator.free(self.diff_folded_path);
        cleanupProfilingTemp(self.io, self.tmp_root);
        self.allocator.free(self.tmp_root);
    }

    fn readWorkspaceFile(self: *ProfilingTestEnv, path: []const u8) ![]u8 {
        return self.app.workspace.readFileAlloc(self.io, path, 1024 * 1024);
    }
};

fn cleanupProfilingTemp(io: std.Io, path: []const u8) void {
    std.Io.Dir.cwd().deleteTree(io, path) catch |err| {
        std.debug.print("profiling test cleanup failed for {s}: {s}\n", .{ path, @errorName(err) });
    };
}

fn writeFixtureFile(io: std.Io, allocator: std.mem.Allocator, root: []const u8, name: []const u8, data: []const u8) !void {
    const path = try std.fs.path.join(allocator, &.{ root, name });
    defer allocator.free(path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = data });
}

fn writeExecutableFile(io: std.Io, path: []const u8, bytes: []const u8) !void {
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes, .flags = .{ .permissions = .executable_file } });
}

fn parseArgs(allocator: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
}

test "flamegraph handler writes svg and reports zflame metadata" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var env = try ProfilingTestEnv.init(allocator, zflame_ok_script, diff_ok_script);
    defer env.deinit();
    env.app.backend_probe_cache.zflame = .{ .ok = true, .status = "ok", .resolution = "cached zflame probe" };

    const args = try parseArgs(allocator, "{\"format\":\"recursive\",\"input\":\"stacks.folded\",\"output\":\"profile.svg\",\"title\":\"fixture\",\"subtitle\":\"unit\",\"colors\":\"hot\",\"width\":1200,\"min_width\":5,\"hash\":true}");
    defer args.deinit();
    const result = try zigFlamegraph(&env.app, allocator, args.value);
    defer json_result.deinitToolResult(allocator, result);

    try std.testing.expect(!result.is_error);
    const obj = result.structuredContent.?.object;
    try std.testing.expectEqualStrings("zig_flamegraph", obj.get("kind").?.string);
    try std.testing.expectEqualStrings("zflame", obj.get("backend").?.string);
    try std.testing.expectEqualStrings("recursive", obj.get("format").?.string);
    try std.testing.expectEqualStrings("recursive", obj.get("input_format").?.string);
    try std.testing.expect(obj.get("bytes").?.integer > 0);
    try std.testing.expectEqualStrings(env.zflame_path, obj.get("backend_executable_path").?.string);
    try std.testing.expectEqualStrings("rendered_ok", obj.get("compatibility_status").?.string);
    try std.testing.expectEqualStrings("rendered_ok", obj.get("backend_metadata").?.object.get("compatibility_status").?.string);
    try std.testing.expectEqualStrings("probe_ok", obj.get("backend_metadata").?.object.get("probe_status").?.string);
    try std.testing.expectEqualStrings("recursive", obj.get("argv").?.array.items[1].string);
    try std.testing.expectEqualStrings("--title=fixture", obj.get("argv").?.array.items[2].string);
    try std.testing.expectEqualStrings("--hash", obj.get("argv").?.array.items[7].string);
    try std.testing.expect(std.mem.indexOf(u8, obj.get("argv_shape").?.string, "zflame") != null);
    try std.testing.expect(obj.get("warnings").?.array.items.len >= 1);

    const svg = try env.readWorkspaceFile("profile.svg");
    defer allocator.free(svg);
    try std.testing.expect(std.mem.startsWith(u8, svg, "<svg"));
}

test "flamegraph diff handler reports diff-folded metadata and rendered svg" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var env = try ProfilingTestEnv.init(allocator, zflame_ok_script, diff_ok_script);
    defer env.deinit();
    env.app.backend_probe_cache.diff_folded = .{ .ok = true, .status = "ok", .resolution = "cached diff-folded probe" };

    const args = try parseArgs(allocator, "{\"before\":\"before.folded\",\"after\":\"after.folded\",\"output\":\"diff.svg\",\"intermediate\":\"profile/delta.folded\",\"title\":\"diff fixture\"}");
    defer args.deinit();
    const result = try zigFlamegraphDiff(&env.app, allocator, args.value);
    defer json_result.deinitToolResult(allocator, result);

    try std.testing.expect(!result.is_error);
    const obj = result.structuredContent.?.object;
    try std.testing.expectEqualStrings("zig_flamegraph_diff", obj.get("kind").?.string);
    try std.testing.expectEqualStrings("diff-folded", obj.get("diff_backend").?.string);
    try std.testing.expectEqualStrings("profile/delta.folded", obj.get("intermediate").?.string);
    try std.testing.expect(obj.get("intermediate_bytes").?.integer > 0);
    try std.testing.expectEqualStrings("recursive", obj.get("argv").?.array.items[1].string);

    const folded_meta = obj.get("intermediate_folded").?.object;
    try std.testing.expectEqualStrings("diff-folded", folded_meta.get("backend").?.string);
    try std.testing.expectEqualStrings("diff_written_and_read_ok", folded_meta.get("compatibility_status").?.string);
    try std.testing.expectEqualStrings("diff_written_and_read_ok", folded_meta.get("backend_metadata").?.object.get("compatibility_status").?.string);
    try std.testing.expectEqualStrings("probe_ok", folded_meta.get("backend_metadata").?.object.get("probe_status").?.string);
    try std.testing.expectEqualStrings(env.diff_folded_path, folded_meta.get("argv").?.array.items[0].string);
    try std.testing.expect(std.mem.indexOf(u8, folded_meta.get("argv_shape").?.string, "diff-folded") != null);

    const svg = try env.readWorkspaceFile("diff.svg");
    defer allocator.free(svg);
    try std.testing.expect(std.mem.startsWith(u8, svg, "<svg"));
    const folded = try env.readWorkspaceFile("profile/delta.folded");
    defer allocator.free(folded);
    try std.testing.expectEqualStrings("main;delta 2", std.mem.trim(u8, folded, " \t\r\n"));
}

test "profiling handlers return structured argument and input errors" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var env = try ProfilingTestEnv.init(allocator, zflame_ok_script, diff_ok_script);
    defer env.deinit();

    const missing_input_args = try parseArgs(allocator, "{\"format\":\"recursive\",\"output\":\"profile.svg\"}");
    defer missing_input_args.deinit();
    const missing_input = try zigFlamegraph(&env.app, allocator, missing_input_args.value);
    defer json_result.deinitToolResult(allocator, missing_input);
    try std.testing.expect(missing_input.is_error);
    try std.testing.expectEqualStrings("argument_error", missing_input.structuredContent.?.object.get("kind").?.string);
    try std.testing.expectEqualStrings("missing_required_argument", missing_input.structuredContent.?.object.get("code").?.string);
    try std.testing.expectEqualStrings("input", missing_input.structuredContent.?.object.get("field").?.string);

    const guess_args = try parseArgs(allocator, "{\"format\":\"guess\",\"input\":\"stacks.folded\",\"output\":\"profile.svg\"}");
    defer guess_args.deinit();
    const guess = try zigFlamegraph(&env.app, allocator, guess_args.value);
    defer json_result.deinitToolResult(allocator, guess);
    try std.testing.expect(guess.is_error);
    try std.testing.expectEqualStrings("invalid_argument", guess.structuredContent.?.object.get("code").?.string);
    try std.testing.expectEqualStrings("format", guess.structuredContent.?.object.get("field").?.string);
    try std.testing.expectEqualStrings("guess", guess.structuredContent.?.object.get("actual").?.string);

    const width_args = try parseArgs(allocator, "{\"format\":\"recursive\",\"input\":\"stacks.folded\",\"output\":\"profile.svg\",\"width\":0}");
    defer width_args.deinit();
    const width = try zigFlamegraph(&env.app, allocator, width_args.value);
    defer json_result.deinitToolResult(allocator, width);
    try std.testing.expect(width.is_error);
    try std.testing.expectEqualStrings("width", width.structuredContent.?.object.get("field").?.string);

    const missing_file_args = try parseArgs(allocator, "{\"format\":\"recursive\",\"input\":\"missing.folded\",\"output\":\"profile.svg\"}");
    defer missing_file_args.deinit();
    const missing_file = try zigFlamegraph(&env.app, allocator, missing_file_args.value);
    defer json_result.deinitToolResult(allocator, missing_file);
    try std.testing.expect(missing_file.is_error);
    try std.testing.expectEqualStrings("workspace_input_read_failed", missing_file.structuredContent.?.object.get("code").?.string);
    try std.testing.expectEqualStrings("read_workspace_input", missing_file.structuredContent.?.object.get("phase").?.string);
}

test "flamegraph handler rejects non-svg backend output" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var env = try ProfilingTestEnv.init(allocator, zflame_non_svg_script, diff_ok_script);
    defer env.deinit();

    const args = try parseArgs(allocator, "{\"format\":\"recursive\",\"input\":\"stacks.folded\",\"output\":\"profile.svg\"}");
    defer args.deinit();
    const result = try zigFlamegraph(&env.app, allocator, args.value);
    defer json_result.deinitToolResult(allocator, result);

    try std.testing.expect(result.is_error);
    const obj = result.structuredContent.?.object;
    try std.testing.expectEqualStrings("backend_output_malformed", obj.get("code").?.string);
    try std.testing.expectEqualStrings("validate_svg", obj.get("phase").?.string);
    try std.testing.expectEqualStrings("zflame", obj.get("backend").?.string);
    try std.testing.expectEqualStrings("recursive", obj.get("format").?.string);
}

test "flamegraph diff reports empty and nonzero diff-folded outputs" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var empty_env = try ProfilingTestEnv.init(allocator, zflame_ok_script, diff_empty_script);
    defer empty_env.deinit();
    const empty_args = try parseArgs(allocator, "{\"before\":\"before.folded\",\"after\":\"after.folded\",\"output\":\"diff.svg\",\"intermediate\":\"profile/empty.folded\"}");
    defer empty_args.deinit();
    const empty = try zigFlamegraphDiff(&empty_env.app, allocator, empty_args.value);
    defer json_result.deinitToolResult(allocator, empty);
    try std.testing.expect(empty.is_error);
    try std.testing.expectEqualStrings("backend_output_malformed", empty.structuredContent.?.object.get("code").?.string);
    try std.testing.expectEqualStrings("verify_intermediate_diff", empty.structuredContent.?.object.get("operation").?.string);

    var fail_env = try ProfilingTestEnv.init(allocator, zflame_ok_script, diff_fail_script);
    defer fail_env.deinit();
    const fail_args = try parseArgs(allocator, "{\"before\":\"before.folded\",\"after\":\"after.folded\",\"output\":\"diff.svg\"}");
    defer fail_args.deinit();
    const failed = try zigFlamegraphDiff(&fail_env.app, allocator, fail_args.value);
    defer json_result.deinitToolResult(allocator, failed);
    try std.testing.expect(failed.is_error);
    try std.testing.expectEqualStrings("diff_folded_command_failed", failed.structuredContent.?.object.get("code").?.string);
    try std.testing.expectEqualStrings("run_diff_folded", failed.structuredContent.?.object.get("phase").?.string);
    try std.testing.expectEqualStrings("diff-folded", failed.structuredContent.?.object.get("backend").?.string);
    try std.testing.expectEqual(@as(i64, 9), failed.structuredContent.?.object.get("exit_code").?.integer);
}

test "profiling handlers reject workspace escapes before backend execution" {
    const allocator = std.testing.allocator;
    var config = try zigar.config.parse(allocator, std.testing.io, &.{ "zigar", "--timeout-ms", "1" });
    defer config.deinit(allocator);
    var workspace = try zigar.workspace.Workspace.init(allocator, std.testing.io, ".", null);
    defer workspace.deinit();
    var app = App{ .allocator = allocator, .io = std.testing.io, .config = config, .workspace = workspace };

    const flame_args = try std.json.parseFromSlice(std.json.Value, allocator, "{\"format\":\"recursive\",\"input\":\"build.zig\",\"output\":\"../outside.svg\"}", .{});
    defer flame_args.deinit();
    const flame = try zigFlamegraph(&app, allocator, flame_args.value);
    defer json_result.deinitToolResult(allocator, flame);
    try std.testing.expect(flame.is_error);
    try std.testing.expectEqualStrings("workspace_path_error", flame.structuredContent.?.object.get("kind").?.string);
    try std.testing.expectEqualStrings("path_outside_workspace", flame.structuredContent.?.object.get("code").?.string);

    const diff_args = try std.json.parseFromSlice(std.json.Value, allocator, "{\"before\":\"build.zig\",\"after\":\"build.zig\",\"output\":\".zigar-cache/profile/diff.svg\",\"intermediate\":\"../outside.folded\"}", .{});
    defer diff_args.deinit();
    const diff = try zigFlamegraphDiff(&app, allocator, diff_args.value);
    defer json_result.deinitToolResult(allocator, diff);
    try std.testing.expect(diff.is_error);
    try std.testing.expectEqualStrings("workspace_path_error", diff.structuredContent.?.object.get("kind").?.string);
    try std.testing.expectEqualStrings("../outside.folded", diff.structuredContent.?.object.get("path").?.string);

    const diff_output_args = try std.json.parseFromSlice(std.json.Value, allocator, "{\"before\":\"build.zig\",\"after\":\"build.zig\",\"output\":\"../outside.svg\"}", .{});
    defer diff_output_args.deinit();
    const diff_output = try zigFlamegraphDiff(&app, allocator, diff_output_args.value);
    defer json_result.deinitToolResult(allocator, diff_output);
    try std.testing.expect(diff_output.is_error);
    try std.testing.expectEqualStrings("workspace_path_error", diff_output.structuredContent.?.object.get("kind").?.string);
    try std.testing.expectEqualStrings("../outside.svg", diff_output.structuredContent.?.object.get("path").?.string);
}
