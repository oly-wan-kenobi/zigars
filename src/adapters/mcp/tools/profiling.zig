//! Profiling MCP adapters for plan/run/flamegraph workflows and artifact paths.
const std = @import("std");
const builtin = @import("builtin");
const mcp = @import("mcp");

const app_context = @import("../../../app/context.zig");
const ports = @import("../../../app/ports.zig");
const flamegraph_model = @import("../../../domain/profiling/flamegraph.zig");
const flamegraph_usecase = @import("../../../app/usecases/profiling/flamegraph.zig");
const flamegraph_diff_usecase = @import("../../../app/usecases/profiling/flamegraph_diff.zig");
const plan_usecase = @import("../../../app/usecases/profiling/plan.zig");
const render_usecase = @import("../../../app/usecases/profiling/render.zig");
const run_usecase = @import("../../../app/usecases/profiling/run.zig");
const mcp_errors = @import("../errors.zig");
const mcp_result = @import("../result.zig");

const output_limit_mode = "truncate_on_limit";

/// Handles MCP `zig_profile_plan` requests by delegating to app logic and shaping owned results/errors.
pub fn zigProfilePlan(allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const value = try plan_usecase.profilePlanValue(arena.allocator(), .{
        .binary = argString(args, "binary") orelse "zig-out/bin/<app>",
        .detected_platform = detectedPlatform(),
        .platform = argString(args, "platform"),
        .output_prefix = argString(args, "output_prefix") orelse ".zigar-cache/profile/profile",
    });
    return mcp_result.structured(allocator, value);
}

/// Handles MCP `zig_profile_run` requests by delegating to app logic and shaping owned results/errors.
pub fn zigProfileRun(
    allocator: std.mem.Allocator,
    context: app_context.ProfilingContext,
    args: ?std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    const cmd = argString(args, "command") orelse return mcp_errors.missingArgument(allocator, "zig_profile_run", "command", "shell-style command string");
    const split = splitArgs(allocator, cmd) catch |err| return splitArgsError(allocator, "zig_profile_run", "command", cmd, err);
    defer freeArgList(allocator, split);
    if (split.len == 0) return mcp_errors.invalidArgument(allocator, "zig_profile_run", "command", "non-empty command string", cmd, "Pass the executable and arguments to run under the profiler.");

    var result = run_usecase.run(allocator, context, .{
        .argv = split,
        .timeout_ms = toolTimeout(context, args),
    }) catch |err| return usecaseError(allocator, "zig_profile_run", "profile_command", "run_command", err);
    defer result.deinit(allocator);
    return switch (result) {
        .ok => |command_result| blk: {
            var arena = std.heap.ArenaAllocator.init(allocator);
            defer arena.deinit();
            const value = commandResultValue(arena.allocator(), "explicit user profiler command (argv split without shell)", split, context.workspace.root, toolTimeout(context, args), command_result) catch return error.OutOfMemory;
            break :blk mcp_result.structured(allocator, value);
        },
        .err => |failure| commandRunErrorResult(allocator, "zig_profile_run", "profile_command", "run_command", "profile_command_failed", failure),
    };
}

/// Handles MCP `zig_flamegraph` requests by delegating to app logic and shaping owned results/errors.
pub fn zigFlamegraph(
    allocator: std.mem.Allocator,
    context: app_context.ProfilingContext,
    args: ?std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    const parsed = switch (try flamegraphRequestFromArgs(allocator, args)) {
        .ok => |value| value,
        .err => |result| return result,
    };
    var render = render_usecase.run(allocator, context, parsed) catch |err| return usecaseError(allocator, "zig_flamegraph", "render_flamegraph", "run_usecase", err);
    defer render.deinit(allocator);
    return switch (render) {
        .ok => |artifact| blk: {
            var arena = std.heap.ArenaAllocator.init(allocator);
            defer arena.deinit();
            const value = flamegraphResultValue(arena.allocator(), context.probe_cache.zflame, artifact.request, artifact.artifact) catch return error.OutOfMemory;
            break :blk mcp_result.structured(allocator, value);
        },
        .err => |failure| renderFailureResult(allocator, context, "zig_flamegraph", failure),
    };
}

/// Handles MCP `zig_flamegraph_diff` requests by delegating to app logic and shaping owned results/errors.
pub fn zigFlamegraphDiff(
    allocator: std.mem.Allocator,
    context: app_context.ProfilingContext,
    args: ?std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    const parsed = switch (try diffRequestFromArgs(allocator, args)) {
        .ok => |value| value,
        .err => |result| return result,
    };
    var result = flamegraph_diff_usecase.run(allocator, context, parsed) catch |err| return usecaseError(allocator, "zig_flamegraph_diff", "render_differential_flamegraph", "run_usecase", err);
    defer result.deinit(allocator);
    return switch (result) {
        .ok => |artifact| blk: {
            var arena = std.heap.ArenaAllocator.init(allocator);
            defer arena.deinit();
            const value = flamegraphDiffResultValue(arena.allocator(), context, artifact) catch return error.OutOfMemory;
            break :blk mcp_result.structured(allocator, value);
        },
        .err => |failure| diffFailureResult(allocator, context, failure),
    };
}

const FlamegraphParseResult = union(enum) {
    ok: render_usecase.Request,
    err: mcp.tools.ToolResult,
};

fn flamegraphRequestFromArgs(allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!FlamegraphParseResult {
    const format_raw = argString(args, "format") orelse return .{ .err = try mcp_errors.missingArgument(allocator, "zig_flamegraph", "format", flamegraph_model.supportedZflameFormatsText()) };
    const format = flamegraph_model.parseZflameFormat(format_raw) orelse return .{ .err = try invalidZflameFormat(allocator, "zig_flamegraph", format_raw) };
    const input = argString(args, "input") orelse return .{ .err = try mcp_errors.missingArgument(allocator, "zig_flamegraph", "input", "workspace-relative profiler input path") };
    const output = argString(args, "output") orelse return .{ .err = try mcp_errors.missingArgument(allocator, "zig_flamegraph", "output", "workspace-relative SVG output path") };
    const options = switch (try zflameOptionsFromArgs(allocator, "zig_flamegraph", args)) {
        .ok => |value| value,
        .err => |result| return .{ .err = result },
    };
    return .{ .ok = .{
        .input = input,
        .output = output,
        .format = format,
        .options = options,
    } };
}

const DiffParseResult = union(enum) {
    ok: flamegraph_diff_usecase.Request,
    err: mcp.tools.ToolResult,
};

fn diffRequestFromArgs(allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!DiffParseResult {
    const before = argString(args, "before") orelse return .{ .err = try mcp_errors.missingArgument(allocator, "zig_flamegraph_diff", "before", "workspace-relative folded stack path") };
    const after = argString(args, "after") orelse return .{ .err = try mcp_errors.missingArgument(allocator, "zig_flamegraph_diff", "after", "workspace-relative folded stack path") };
    const output = argString(args, "output") orelse return .{ .err = try mcp_errors.missingArgument(allocator, "zig_flamegraph_diff", "output", "workspace-relative SVG output path") };
    const options = switch (try zflameOptionsFromArgs(allocator, "zig_flamegraph_diff", args)) {
        .ok => |value| value,
        .err => |result| return .{ .err = result },
    };
    return .{ .ok = .{
        .before = before,
        .after = after,
        .output = output,
        .intermediate = argString(args, "intermediate"),
        .options = options,
    } };
}

const OptionsResult = union(enum) {
    ok: flamegraph_model.ZflameRenderOptions,
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
    return .{ .err = try mcp_errors.invalidArgument(allocator, tool_name, name, "positive integer", "zero or negative", "Use positive pixel values for zflame sizing options.") };
}

fn invalidZflameFormat(allocator: std.mem.Allocator, tool_name: []const u8, actual: []const u8) mcp.tools.ToolError!mcp.tools.ToolResult {
    return mcp_errors.invalidArgument(
        allocator,
        tool_name,
        "format",
        flamegraph_model.supportedZflameFormatsText(),
        actual,
        "Choose an explicit zflame input format from the tools/list schema; zigar does not expose format guessing.",
    );
}

fn renderFailureResult(
    allocator: std.mem.Allocator,
    context: app_context.ProfilingContext,
    tool_name: []const u8,
    failure: render_usecase.Failure,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    return switch (failure) {
        .workspace_path_failed => |details| mcp_errors.workspacePath(allocator, tool_name, details.path, context.workspace.root, details.err),
        .render_failed => |details| flamegraphFailureResult(allocator, details.request, details.failure),
    };
}

fn usecaseError(allocator: std.mem.Allocator, tool_name: []const u8, operation: []const u8, phase: []const u8, err: anyerror) mcp.tools.ToolError!mcp.tools.ToolResult {
    if (err == error.OutOfMemory) return error.OutOfMemory;
    return mcp_errors.fromError(allocator, .{
        .tool = tool_name,
        .operation = operation,
        .phase = phase,
        .code = "profiling_usecase_failed",
        .category = "profiling",
        .resolution = "Retry after confirming the profiling workspace paths and configured backend paths.",
    }, err);
}

fn diffFailureResult(
    allocator: std.mem.Allocator,
    context: app_context.ProfilingContext,
    result: anytype,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    const failure = result.failure;
    return switch (failure) {
        .workspace_path_failed => |details| mcp_errors.workspacePath(allocator, "zig_flamegraph_diff", details.path, context.workspace.root, details.err),
        .workspace_input_read_failed => |details| workspaceToolError(allocator, "zig_flamegraph_diff", "diff_folded_stacks", "read_workspace_input", "workspace_input_read_failed", details.path, details.abs_path, details.err, "Pass an existing readable profiler input file inside the configured workspace."),
        .workspace_parent_prepare_failed => |details| workspaceToolError(allocator, "zig_flamegraph_diff", "prepare_backend_output", "create_output_parent", "workspace_artifact_write_failed", details.path, details.abs_path, details.err, "Choose a workspace-local output path whose parent directory can be created."),
        .backend_run_failed => |details| backendErrorResult(allocator, "diff-folded", "diff", details.err, "confirm --diff-folded-path points to an executable diff-folded binary and both folded inputs are readable"),
        .command_failed => |details| commandFailureResult(allocator, .{
            .tool = "zig_flamegraph_diff",
            .operation = "diff_folded_stacks",
            .phase = "run_diff_folded",
            .code = "diff_folded_command_failed",
            .backend = "diff-folded",
            .argv = details.argv.items,
            .cwd = details.cwd,
            .timeout_ms = details.timeout_ms,
            .term = details.term,
            .stdout = details.stdout,
            .stderr = details.stderr,
            .stdout_truncated = details.stdout_truncated,
            .stderr_truncated = details.stderr_truncated,
            .resolution = "Inspect stdout/stderr, confirm both folded-stack inputs are readable, and retry with a working diff-folded backend.",
        }),
        .workspace_intermediate_read_failed => |details| workspaceToolError(allocator, "zig_flamegraph_diff", "verify_intermediate_diff", "read_intermediate_diff", "workspace_artifact_read_failed", details.path, details.abs_path, details.err, "Confirm diff-folded wrote the requested --output file inside .zigar-cache/profile and retry."),
        .backend_output_malformed => |details| mcp_errors.result(allocator, .{
            .tool = "zig_flamegraph_diff",
            .operation = "verify_intermediate_diff",
            .phase = "read_intermediate_diff",
            .code = "backend_output_malformed",
            .category = "backend_output",
            .resolution = "The diff-folded command completed but wrote an empty folded diff file.",
            .details = &.{.{ .key = "output", .value = .{ .string = details.output } }},
        }),
        .render_failed => |details| flamegraphFailureResult(allocator, details.request, details.failure),
    };
}

fn flamegraphFailureResult(allocator: std.mem.Allocator, request: flamegraph_usecase.Request, failure: flamegraph_usecase.Failure) mcp.tools.ToolError!mcp.tools.ToolResult {
    return switch (failure) {
        .workspace_input_read_failed => |details| workspaceToolError(allocator, request.tool_name, request.operation, "read_workspace_input", "workspace_input_read_failed", details.path, details.abs_path, details.err, "Pass an existing readable profiler input file inside the configured workspace."),
        .backend_run_failed => |details| backendErrorResult(allocator, "zflame", "render", details.err, "confirm --zflame-path points to an executable zflame binary and that profiler input is readable"),
        .command_failed => |details| commandFailureResult(allocator, .{
            .tool = request.tool_name,
            .operation = request.operation,
            .phase = "run_zflame",
            .code = "zflame_command_failed",
            .backend = "zflame",
            .argv = details.argv.items,
            .cwd = details.cwd,
            .timeout_ms = details.timeout_ms,
            .term = details.term,
            .stdout = details.stdout,
            .stderr = details.stderr,
            .stdout_truncated = details.stdout_truncated,
            .stderr_truncated = details.stderr_truncated,
            .resolution = "Inspect stdout/stderr, confirm the profiler input format is correct, and retry with a supported zflame invocation.",
        }),
        .backend_output_malformed => |details| mcp_errors.result(allocator, .{
            .tool = request.tool_name,
            .operation = request.operation,
            .phase = "validate_svg",
            .code = "backend_output_malformed",
            .category = "backend_output",
            .resolution = "The zflame command completed but stdout did not look like an SVG document. Run zflame directly with the same input and options.",
            .details = &.{
                .{ .key = "backend", .value = .{ .string = details.backend } },
                .{ .key = "format", .value = .{ .string = details.format.name() } },
                .{ .key = "input", .value = .{ .string = details.input } },
            },
        }),
        .workspace_artifact_write_failed => |details| workspaceToolError(allocator, request.tool_name, request.operation, "workspace_write", "workspace_artifact_write_failed", details.path, details.abs_path, details.err, "Choose an output path inside the workspace that zigar can create or overwrite."),
    };
}

fn flamegraphResultValue(
    allocator: std.mem.Allocator,
    probe: app_context.CachedBackendProbe,
    request: flamegraph_usecase.Request,
    artifact: flamegraph_usecase.Artifact,
) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    var obj_owned = true;
    defer if (obj_owned) obj.deinit(allocator);
    try putFlamegraphBase(allocator, &obj, probe, request, artifact);
    obj_owned = false;
    return .{ .object = obj };
}

fn flamegraphDiffResultValue(
    allocator: std.mem.Allocator,
    context: app_context.ProfilingContext,
    artifact: flamegraph_diff_usecase.Artifact,
) !std.json.Value {
    const render_request = flamegraph_usecase.Request{
        .tool_name = "zig_flamegraph_diff",
        .operation = "render_differential_flamegraph",
        .input = artifact.request.intermediate,
        .input_abs = artifact.request.intermediate_abs,
        .output = artifact.request.output,
        .output_abs = artifact.request.output_abs,
        .format = .recursive,
        .options = artifact.request.options,
    };
    var obj = std.json.ObjectMap.empty;
    var obj_owned = true;
    defer if (obj_owned) obj.deinit(allocator);
    try putFlamegraphBase(allocator, &obj, context.probe_cache.zflame, render_request, artifact.render);
    try obj.put(allocator, "kind", .{ .string = "zig_flamegraph_diff" });
    try obj.put(allocator, "diff_backend", .{ .string = artifact.diff.backend });
    try obj.put(allocator, "before", .{ .string = artifact.request.before });
    try obj.put(allocator, "before_abs", .{ .string = artifact.request.before_abs });
    try obj.put(allocator, "after", .{ .string = artifact.request.after });
    try obj.put(allocator, "after_abs", .{ .string = artifact.request.after_abs });
    try obj.put(allocator, "intermediate", .{ .string = artifact.request.intermediate });
    try obj.put(allocator, "intermediate_abs", .{ .string = artifact.request.intermediate_abs });
    try obj.put(allocator, "intermediate_bytes", .{ .integer = @intCast(artifact.diff.bytes) });
    try obj.put(allocator, "intermediate_sha256", .{ .string = artifact.diff.sha256 });
    try obj.put(allocator, "intermediate_folded", try intermediateFoldedValue(allocator, context, artifact));
    obj_owned = false;
    return .{ .object = obj };
}

fn putFlamegraphBase(
    allocator: std.mem.Allocator,
    obj: *std.json.ObjectMap,
    probe: app_context.CachedBackendProbe,
    request: flamegraph_usecase.Request,
    artifact: flamegraph_usecase.Artifact,
) !void {
    try obj.put(allocator, "kind", .{ .string = request.tool_name });
    try obj.put(allocator, "backend", .{ .string = artifact.backend });
    try obj.put(allocator, "input", .{ .string = request.input });
    try obj.put(allocator, "input_abs", .{ .string = request.input_abs });
    try obj.put(allocator, "output", .{ .string = request.output });
    try obj.put(allocator, "output_abs", .{ .string = request.output_abs });
    try obj.put(allocator, "format", .{ .string = request.format.name() });
    try obj.put(allocator, "input_format", .{ .string = request.format.name() });
    try obj.put(allocator, "bytes", .{ .integer = @intCast(artifact.bytes) });
    try obj.put(allocator, "sha256", .{ .string = artifact.sha256 });
    try obj.put(allocator, "backend_executable_path", .{ .string = artifact.backend_executable_path });
    try obj.put(allocator, "backend_metadata", try backendMetadataValue(allocator, probe, "zflame", artifact.backend_executable_path, artifact.compatibility_status, flamegraph_model.zflame_compatibility_baseline));
    try obj.put(allocator, "argv_shape", .{ .string = flamegraph_model.zflame_argv_shape });
    try obj.put(allocator, "argv", try argvValue(allocator, artifact.argv.items));
    try obj.put(allocator, "warnings", try renderWarningsValue(allocator, probe));
    try obj.put(allocator, "compatibility_status", .{ .string = artifact.compatibility_status });
    try obj.put(allocator, "capture_semantics", .{ .string = flamegraph_model.capture_semantics });
}

fn intermediateFoldedValue(allocator: std.mem.Allocator, context: app_context.ProfilingContext, artifact: flamegraph_diff_usecase.Artifact) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    var obj_owned = true;
    defer if (obj_owned) obj.deinit(allocator);
    try obj.put(allocator, "path", .{ .string = artifact.request.intermediate });
    try obj.put(allocator, "abs_path", .{ .string = artifact.request.intermediate_abs });
    try obj.put(allocator, "input_format", .{ .string = flamegraph_model.ZflameFormat.recursive.name() });
    try obj.put(allocator, "bytes", .{ .integer = @intCast(artifact.diff.bytes) });
    try obj.put(allocator, "sha256", .{ .string = artifact.diff.sha256 });
    try obj.put(allocator, "source_before", .{ .string = artifact.request.before });
    try obj.put(allocator, "source_before_abs", .{ .string = artifact.request.before_abs });
    try obj.put(allocator, "source_after", .{ .string = artifact.request.after });
    try obj.put(allocator, "source_after_abs", .{ .string = artifact.request.after_abs });
    try obj.put(allocator, "backend", .{ .string = artifact.diff.backend });
    try obj.put(allocator, "backend_executable_path", .{ .string = artifact.diff.backend_executable_path });
    try obj.put(allocator, "backend_metadata", try backendMetadataValue(allocator, context.probe_cache.diff_folded, "diff-folded", artifact.diff.backend_executable_path, artifact.diff.compatibility_status, flamegraph_model.diff_folded_compatibility_baseline));
    try obj.put(allocator, "argv_shape", .{ .string = flamegraph_model.diff_folded_argv_shape });
    try obj.put(allocator, "argv", try argvValue(allocator, artifact.diff.argv.items));
    try obj.put(allocator, "warnings", try renderWarningsValue(allocator, context.probe_cache.diff_folded));
    try obj.put(allocator, "compatibility_status", .{ .string = artifact.diff.compatibility_status });
    obj_owned = false;
    return .{ .object = obj };
}

fn backendMetadataValue(allocator: std.mem.Allocator, probe: app_context.CachedBackendProbe, name: []const u8, executable_path: []const u8, compatibility_status: []const u8, compatibility_baseline: []const u8) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    var obj_owned = true;
    defer if (obj_owned) obj.deinit(allocator);
    try obj.put(allocator, "name", .{ .string = name });
    try obj.put(allocator, "executable_path", .{ .string = executable_path });
    try obj.put(allocator, "probe", try cachedProbeValue(allocator, probe));
    try obj.put(allocator, "version", try unknownVersionValue(allocator, name));
    try obj.put(allocator, "compatibility_status", .{ .string = compatibility_status });
    try obj.put(allocator, "compatibility_baseline", .{ .string = compatibility_baseline });
    try obj.put(allocator, "probe_status", .{ .string = if (probe.probed) if (probe.ok orelse false) "probe_ok" else "probe_failed" else "unknown" });
    obj_owned = false;
    return .{ .object = obj };
}

fn cachedProbeValue(allocator: std.mem.Allocator, probe: app_context.CachedBackendProbe) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    var obj_owned = true;
    defer if (obj_owned) obj.deinit(allocator);
    try obj.put(allocator, "probed", .{ .bool = probe.probed });
    try obj.put(allocator, "ok", if (probe.ok) |ok| .{ .bool = ok } else .null);
    try obj.put(allocator, "status", .{ .string = probe.status });
    try obj.put(allocator, "resolution", .{ .string = probe.resolution });
    obj_owned = false;
    return .{ .object = obj };
}

fn unknownVersionValue(allocator: std.mem.Allocator, name: []const u8) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    var obj_owned = true;
    defer if (obj_owned) obj.deinit(allocator);
    try obj.put(allocator, "status", .{ .string = "unknown" });
    try obj.put(allocator, "value", .null);
    try obj.put(allocator, "source", .{ .string = try std.fmt.allocPrint(allocator, "{s} probe uses --help and does not define a stable version field for artifact metadata", .{name}) });
    obj_owned = false;
    return .{ .object = obj };
}

fn renderWarningsValue(allocator: std.mem.Allocator, probe: app_context.CachedBackendProbe) !std.json.Value {
    var warnings = std.json.Array.init(allocator);
    var warnings_owned = true;
    defer if (warnings_owned) warnings.deinit();
    try warnings.append(.{ .string = flamegraph_model.capture_semantics });
    if (!probe.probed) {
        try warnings.append(.{ .string = "backend probe and version are unknown for this artifact; run zigar_doctor with probe_backends=true to cache probe status" });
    }
    warnings_owned = false;
    return .{ .array = warnings };
}

const CommandFailureSpec = struct {
    tool: []const u8,
    operation: []const u8,
    phase: []const u8,
    code: []const u8,
    backend: []const u8,
    argv: []const []const u8,
    cwd: []const u8,
    timeout_ms: i64,
    term: ports.CommandTerm,
    stdout: []const u8,
    stderr: []const u8,
    stdout_truncated: bool,
    stderr_truncated: bool,
    resolution: []const u8,
};

fn commandFailureResult(allocator: std.mem.Allocator, spec: CommandFailureSpec) mcp.tools.ToolError!mcp.tools.ToolResult {
    const command_text = commandText(allocator, spec.argv) catch return error.OutOfMemory;
    defer allocator.free(command_text);
    const stdout = safeTextAlloc(allocator, spec.stdout) catch return error.OutOfMemory;
    defer allocator.free(stdout.text);
    const stderr = safeTextAlloc(allocator, spec.stderr) catch return error.OutOfMemory;
    defer allocator.free(stderr.text);
    const details = [_]mcp_errors.Detail{
        .{ .key = "backend", .value = .{ .string = spec.backend } },
        .{ .key = "command", .value = .{ .string = command_text } },
        .{ .key = "cwd", .value = .{ .string = spec.cwd } },
        .{ .key = "timeout_ms", .value = .{ .integer = spec.timeout_ms } },
        .{ .key = "term", .value = .{ .string = spec.term.name() } },
        .{ .key = "exit_code", .value = if (spec.term.exitCode()) |code| .{ .integer = code } else .null },
        .{ .key = "stdout", .value = .{ .string = stdout.text } },
        .{ .key = "stderr", .value = .{ .string = stderr.text } },
        .{ .key = "stdout_invalid_utf8", .value = .{ .bool = stdout.invalid_utf8 } },
        .{ .key = "stderr_invalid_utf8", .value = .{ .bool = stderr.invalid_utf8 } },
        .{ .key = "stdout_encoding", .value = .{ .string = stdout.encoding } },
        .{ .key = "stderr_encoding", .value = .{ .string = stderr.encoding } },
        .{ .key = "stdout_byte_count", .value = .{ .integer = @intCast(stdout.byte_count) } },
        .{ .key = "stderr_byte_count", .value = .{ .integer = @intCast(stderr.byte_count) } },
        .{ .key = "stdout_truncated", .value = .{ .bool = spec.stdout_truncated } },
        .{ .key = "stderr_truncated", .value = .{ .bool = spec.stderr_truncated } },
        .{ .key = "output_limit_mode", .value = .{ .string = output_limit_mode } },
    };
    return mcp_errors.result(allocator, .{
        .tool = spec.tool,
        .operation = spec.operation,
        .phase = spec.phase,
        .code = spec.code,
        .category = "backend",
        .resolution = spec.resolution,
        .details = &details,
    });
}

fn workspaceToolError(allocator: std.mem.Allocator, tool_name: []const u8, operation: []const u8, phase: []const u8, code: []const u8, path: []const u8, abs_path: []const u8, err: anyerror, resolution: []const u8) mcp.tools.ToolError!mcp.tools.ToolResult {
    return mcp_errors.fromError(allocator, .{
        .tool = tool_name,
        .operation = operation,
        .phase = phase,
        .code = code,
        .category = "filesystem",
        .resolution = resolution,
        .details = &.{
            .{ .key = "input", .value = .{ .string = path } },
            .{ .key = "input_abs", .value = .{ .string = abs_path } },
            .{ .key = "output", .value = .{ .string = path } },
            .{ .key = "output_abs", .value = .{ .string = abs_path } },
        },
    }, err);
}

fn backendErrorResult(allocator: std.mem.Allocator, backend_name: []const u8, operation: []const u8, err: anyerror, resolution: []const u8) mcp.tools.ToolError!mcp.tools.ToolResult {
    var obj = std.json.ObjectMap.empty;
    var obj_owned = true;
    defer if (obj_owned) obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "backend_error" });
    try obj.put(allocator, "ok", .{ .bool = false });
    try obj.put(allocator, "backend", .{ .string = backend_name });
    try obj.put(allocator, "operation", .{ .string = operation });
    try obj.put(allocator, "error", .{ .string = @errorName(err) });
    try obj.put(allocator, "error_kind", .{ .string = kindForCommandError(err) });
    try obj.put(allocator, "resolution", .{ .string = resolution });
    const result = try mcp_result.structured(allocator, .{ .object = obj });
    obj_owned = false;
    return result;
}

fn commandRunErrorResult(allocator: std.mem.Allocator, tool: []const u8, operation: []const u8, phase: []const u8, code: []const u8, failure: run_usecase.CommandRunFailure) mcp.tools.ToolError!mcp.tools.ToolResult {
    const command_text = commandText(allocator, failure.argv.items) catch return error.OutOfMemory;
    defer allocator.free(command_text);
    return mcp_errors.fromError(allocator, .{
        .tool = tool,
        .operation = operation,
        .phase = phase,
        .code = code,
        .category = "command",
        .resolution = "Run the shown profiler command directly to inspect profiler-specific failures.",
        .details = &.{
            .{ .key = "command", .value = .{ .string = command_text } },
            .{ .key = "cwd", .value = .{ .string = failure.cwd } },
            .{ .key = "timeout_ms", .value = .{ .integer = failure.timeout_ms } },
            .{ .key = "command_error_kind", .value = .{ .string = kindForCommandError(failure.err) } },
        },
    }, failure.err);
}

fn commandResultValue(allocator: std.mem.Allocator, title: []const u8, argv: []const []const u8, cwd: []const u8, timeout_ms: i64, result: ports.CommandResult) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    var obj_owned = true;
    defer if (obj_owned) obj.deinit(allocator);
    const term = result.effectiveTerm();
    const stdout = try safeTextAlloc(allocator, result.stdout);
    const stderr = try safeTextAlloc(allocator, result.stderr);
    try obj.put(allocator, "kind", .{ .string = "command" });
    try obj.put(allocator, "title", .{ .string = title });
    try obj.put(allocator, "ok", .{ .bool = !term.failed() and !result.timed_out });
    try obj.put(allocator, "cwd", .{ .string = cwd });
    try obj.put(allocator, "argv", try argvValue(allocator, argv));
    try obj.put(allocator, "timeout_ms", .{ .integer = timeout_ms });
    try obj.put(allocator, "duration_ms", .{ .integer = @intCast(result.duration_ms) });
    try obj.put(allocator, "term", try commandTermValue(allocator, term));
    try putStreamFields(allocator, &obj, "stdout", stdout);
    try putStreamFields(allocator, &obj, "stderr", stderr);
    try obj.put(allocator, "stdout_truncated", .{ .bool = result.stdout_truncated });
    try obj.put(allocator, "stderr_truncated", .{ .bool = result.stderr_truncated });
    try obj.put(allocator, "stdout_limit", .{ .integer = @intCast(run_usecase.command_output_limit) });
    try obj.put(allocator, "stderr_limit", .{ .integer = @intCast(run_usecase.command_output_limit) });
    try obj.put(allocator, "output_limit_mode", .{ .string = output_limit_mode });
    try obj.put(allocator, "output_limit_exceeded", .{ .bool = result.stdout_truncated or result.stderr_truncated });
    try obj.put(allocator, "diagnostics", emptyDiagnosticsValue(allocator));
    try obj.put(allocator, "failure_summary", try simpleFailureSummaryValue(allocator, !term.failed() and !result.timed_out, argv));
    obj_owned = false;
    return .{ .object = obj };
}

fn commandTermValue(allocator: std.mem.Allocator, term: ports.CommandTerm) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    var obj_owned = true;
    defer if (obj_owned) obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = term.name() });
    if (term.exitCode()) |code| try obj.put(allocator, "code", .{ .integer = code });
    obj_owned = false;
    return .{ .object = obj };
}

fn emptyDiagnosticsValue(allocator: std.mem.Allocator) std.json.Value {
    var obj = std.json.ObjectMap.empty;
    obj.put(allocator, "finding_count", .{ .integer = 0 }) catch unreachable;
    obj.put(allocator, "error_count", .{ .integer = 0 }) catch unreachable;
    obj.put(allocator, "warning_count", .{ .integer = 0 }) catch unreachable;
    obj.put(allocator, "note_count", .{ .integer = 0 }) catch unreachable;
    obj.put(allocator, "findings", .{ .array = std.json.Array.init(allocator) }) catch unreachable;
    obj.put(allocator, "primary", .null) catch unreachable;
    obj.put(allocator, "category", .{ .string = "none" }) catch unreachable;
    obj.put(allocator, "next_command", .null) catch unreachable;
    obj.put(allocator, "next_actions", .{ .array = std.json.Array.init(allocator) }) catch unreachable;
    return .{ .object = obj };
}

fn simpleFailureSummaryValue(allocator: std.mem.Allocator, ok: bool, argv: []const []const u8) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    var obj_owned = true;
    defer if (obj_owned) obj.deinit(allocator);
    try obj.put(allocator, "ok", .{ .bool = ok });
    try obj.put(allocator, "primary", .null);
    try obj.put(allocator, "error_class", .{ .string = if (ok) "none" else "execution" });
    try obj.put(allocator, "rerun_command", if (ok) .null else .{ .string = try commandText(allocator, argv) });
    var suggested = std.json.Array.init(allocator);
    if (!ok) {
        try suggested.append(.{ .string = "zigar_doctor" });
        try suggested.append(.{ .string = "zigar_context_pack" });
    }
    try obj.put(allocator, "suggested_tools", .{ .array = suggested });
    try obj.put(allocator, "likely_scope", .{ .string = if (ok) "none" else "tool_or_backend_configuration" });
    obj_owned = false;
    return .{ .object = obj };
}

const SafeText = struct {
    text: []const u8,
    invalid_utf8: bool,
    encoding: []const u8,
    byte_count: usize,
};

fn safeTextAlloc(allocator: std.mem.Allocator, bytes: []const u8) !SafeText {
    if (std.unicode.utf8ValidateSlice(bytes)) return .{
        .text = try allocator.dupe(u8, bytes),
        .invalid_utf8 = false,
        .encoding = "utf-8",
        .byte_count = bytes.len,
    };
    var out: std.ArrayList(u8) = .empty;
    var out_owned = true;
    defer if (out_owned) out.deinit(allocator);
    var index: usize = 0;
    while (index < bytes.len) {
        const len = std.unicode.utf8ByteSequenceLength(bytes[index]) catch {
            try out.appendSlice(allocator, &std.unicode.replacement_character_utf8);
            index += 1;
            continue;
        };
        if (index + len <= bytes.len and std.unicode.utf8ValidateSlice(bytes[index .. index + len])) {
            try out.appendSlice(allocator, bytes[index .. index + len]);
            index += len;
        } else {
            try out.appendSlice(allocator, &std.unicode.replacement_character_utf8);
            index += 1;
        }
    }
    const text = try out.toOwnedSlice(allocator);
    out_owned = false;
    return .{
        .text = text,
        .invalid_utf8 = true,
        .encoding = "utf-8-lossy",
        .byte_count = bytes.len,
    };
}

fn putStreamFields(allocator: std.mem.Allocator, obj: *std.json.ObjectMap, name: []const u8, safe: SafeText) !void {
    try obj.put(allocator, name, .{ .string = safe.text });
    try obj.put(allocator, try std.fmt.allocPrint(allocator, "{s}_invalid_utf8", .{name}), .{ .bool = safe.invalid_utf8 });
    try obj.put(allocator, try std.fmt.allocPrint(allocator, "{s}_encoding", .{name}), .{ .string = safe.encoding });
    try obj.put(allocator, try std.fmt.allocPrint(allocator, "{s}_byte_count", .{name}), .{ .integer = @intCast(safe.byte_count) });
}

fn argvValue(allocator: std.mem.Allocator, argv: []const []const u8) !std.json.Value {
    var array = std.json.Array.init(allocator);
    var array_owned = true;
    defer if (array_owned) array.deinit();
    for (argv) |arg| try array.append(.{ .string = arg });
    array_owned = false;
    return .{ .array = array };
}

fn commandText(allocator: std.mem.Allocator, argv: []const []const u8) ![]const u8 {
    return std.mem.join(allocator, " ", argv);
}

fn splitArgs(allocator: std.mem.Allocator, text: []const u8) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    var current: std.ArrayList(u8) = .empty;
    errdefer {
        freeArgList(allocator, list.items);
        current.deinit(allocator);
    }
    var quote: ?u8 = null;
    var escaping = false;
    var in_token = false;
    for (text) |c| {
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
    return list.toOwnedSlice(allocator);
}

fn finishArg(allocator: std.mem.Allocator, list: *std.ArrayList([]const u8), current: *std.ArrayList(u8)) !void {
    const arg = try current.toOwnedSlice(allocator);
    var arg_owned = true;
    defer if (arg_owned) allocator.free(arg);
    try list.append(allocator, arg);
    arg_owned = false;
}

fn freeArgList(allocator: std.mem.Allocator, args: []const []const u8) void {
    for (args) |arg| allocator.free(arg);
    allocator.free(args);
}

fn splitArgsError(allocator: std.mem.Allocator, tool_name: []const u8, field: []const u8, actual: []const u8, err: anyerror) mcp.tools.ToolError!mcp.tools.ToolResult {
    if (err == error.OutOfMemory) return error.OutOfMemory;
    return mcp_errors.invalidArgument(allocator, tool_name, field, "shell-style argument string", actual, "Quote arguments the same way you would in a shell command, or omit the field when no extra arguments are needed.");
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

fn toolTimeout(context: app_context.ProfilingContext, args: ?std.json.Value) i64 {
    return @max(1, @min(argInt(args, "timeout_ms", context.timeouts.command_ms), 60 * 60 * 1000));
}

fn kindForCommandError(err: anyerror) []const u8 {
    return switch (err) {
        error.RequestTimeout, error.Timeout => "timeout",
        error.StreamTooLong => "output_limit",
        error.FileNotFound => "executable_not_found",
        error.AccessDenied, error.PermissionDenied => "permission",
        else => "execution",
    };
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

const fakes = @import("../../../testing/fakes/root.zig");

test "profiling adapter splits shell-style command arguments" {
    const allocator = std.testing.allocator;
    const args = try splitArgs(allocator, "zig build \"arg with spaces\" 'single quoted' escaped\\ space \"\"");
    defer freeArgList(allocator, args);

    try std.testing.expectEqual(@as(usize, 6), args.len);
    try std.testing.expectEqualStrings("zig", args[0]);
    try std.testing.expectEqualStrings("build", args[1]);
    try std.testing.expectEqualStrings("arg with spaces", args[2]);
    try std.testing.expectEqualStrings("single quoted", args[3]);
    try std.testing.expectEqualStrings("escaped space", args[4]);
    try std.testing.expectEqualStrings("", args[5]);
}

test "profiling adapter rejects unfinished shell quoting" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.InvalidArguments, splitArgs(allocator, "'unterminated"));
    try std.testing.expectError(error.InvalidArguments, splitArgs(allocator, "escaped\\"));
}

test "profiling adapter normalizes lossy command output and command errors" {
    const allocator = std.testing.allocator;
    const bytes = [_]u8{ 0xff, 'o', 'k' };
    const safe = try safeTextAlloc(allocator, bytes[0..]);
    defer allocator.free(safe.text);

    try std.testing.expect(safe.invalid_utf8);
    try std.testing.expectEqualStrings("utf-8-lossy", safe.encoding);
    try std.testing.expectEqual(@as(usize, bytes.len), safe.byte_count);
    try std.testing.expect(std.mem.indexOf(u8, safe.text, &std.unicode.replacement_character_utf8) != null);
    try std.testing.expectEqualStrings("timeout", kindForCommandError(error.Timeout));
    try std.testing.expectEqualStrings("output_limit", kindForCommandError(error.StreamTooLong));
    try std.testing.expectEqualStrings("executable_not_found", kindForCommandError(error.FileNotFound));
    try std.testing.expectEqualStrings("permission", kindForCommandError(error.AccessDenied));
    try std.testing.expectEqualStrings("execution", kindForCommandError(error.Unexpected));

    const truncated = [_]u8{ 0xe2, 0x82 };
    const lossy = try safeTextAlloc(allocator, truncated[0..]);
    defer allocator.free(lossy.text);
    try std.testing.expect(lossy.invalid_utf8);
    try std.testing.expectEqual(@as(usize, std.unicode.replacement_character_utf8.len * 2), lossy.text.len);
    try std.testing.expect(std.mem.startsWith(u8, lossy.text, &std.unicode.replacement_character_utf8));
}

test "profiling adapters execute profile commands and render flamegraph artifacts" {
    const backing_allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(backing_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var commands = fakes.FakeCommandRunner.init(backing_allocator);
    defer commands.deinit();
    var workspace = fakes.FakeWorkspaceStore.init(backing_allocator);
    defer workspace.deinit();
    const context = testProfilingContext(&commands, &workspace);

    const plan = try zigProfilePlan(allocator, try profilingTestArgs(allocator, "{\"binary\":\"zig-out/bin/demo\",\"platform\":\"linux\",\"output_prefix\":\"profiles/demo\"}"));
    defer mcp_result.deinitToolResult(allocator, plan);
    try expectProfilingKind(plan, "zig_profile_plan");

    const default_plan = try zigProfilePlan(allocator, null);
    defer mcp_result.deinitToolResult(allocator, default_plan);
    try expectProfilingKind(default_plan, "zig_profile_plan");

    try commands.expectRun(.{
        .argv = &.{ "zig", "build", "test" },
        .cwd = "/workspace",
        .timeout_ms = 222,
        .max_stdout_bytes = run_usecase.command_output_limit,
        .max_stderr_bytes = run_usecase.command_output_limit,
        .provenance = "explicit user profiler command (argv split without shell)",
    }, .{ .stdout = "ok\n", .stderr = &[_]u8{0xff}, .duration_ms = 8, .stderr_truncated = true });
    const run_ok = try zigProfileRun(allocator, context, try profilingTestArgs(allocator, "{\"command\":\"zig build test\",\"timeout_ms\":222}"));
    defer mcp_result.deinitToolResult(allocator, run_ok);
    try expectProfilingKind(run_ok, "command");
    try std.testing.expect(run_ok.structuredContent.?.object.get("stderr_invalid_utf8").?.bool);

    try commands.expectRun(.{
        .argv = &.{ "zig", "run", "fail" },
        .cwd = "/workspace",
        .timeout_ms = 1,
        .max_stdout_bytes = run_usecase.command_output_limit,
        .max_stderr_bytes = run_usecase.command_output_limit,
        .provenance = "explicit user profiler command (argv split without shell)",
    }, .{ .exit_code = 2, .stdout = "failed\n", .stderr = "bad\n", .duration_ms = 3 });
    const run_failed_exit = try zigProfileRun(allocator, context, try profilingTestArgs(allocator, "{\"command\":\"zig run fail\",\"timeout_ms\":0}"));
    defer mcp_result.deinitToolResult(allocator, run_failed_exit);
    try expectProfilingKind(run_failed_exit, "command");
    try std.testing.expect(!run_failed_exit.structuredContent.?.object.get("ok").?.bool);
    try std.testing.expect(run_failed_exit.structuredContent.?.object.get("failure_summary").?.object.get("suggested_tools").?.array.items.len > 0);

    try commands.expectRunError(.{
        .argv = &.{"missing-profiler"},
        .cwd = "/workspace",
        .timeout_ms = 5000,
        .max_stdout_bytes = run_usecase.command_output_limit,
        .max_stderr_bytes = run_usecase.command_output_limit,
        .provenance = "explicit user profiler command (argv split without shell)",
    }, error.FileNotFound);
    const run_err = try zigProfileRun(allocator, context, try profilingTestArgs(allocator, "{\"command\":\"missing-profiler\"}"));
    defer mcp_result.deinitToolResult(allocator, run_err);
    try std.testing.expect(run_err.is_error);

    try workspace.expectResolve(.{ .path = "stacks.folded", .provenance = "profiling input path resolution" }, "/workspace/stacks.folded");
    try workspace.expectResolve(.{ .path = "profile.svg", .for_output = true, .provenance = "profiling output path resolution" }, "/workspace/profile.svg");
    try workspace.expectRead(.{ .path = "stacks.folded", .max_bytes = 0, .provenance = "zig_flamegraph input readability" }, "");
    try commands.expectRun(.{
        .argv = &.{ "/bin/zflame", "recursive", "--title=fixture", "--subtitle=unit", "--colors=hot", "--width=1200", "--min-width=5", "--hash", "/workspace/stacks.folded" },
        .cwd = "/workspace",
        .timeout_ms = 5000,
        .max_stdout_bytes = flamegraph_usecase.command_output_limit,
        .max_stderr_bytes = flamegraph_usecase.command_output_limit,
        .provenance = "zig_flamegraph zflame render",
    }, .{ .stdout = profiling_svg, .duration_ms = 12 });
    try workspace.expectWrite(.{
        .path = "profile.svg",
        .bytes = profiling_svg,
        .create_parent_dirs = true,
        .replace_existing = true,
        .provenance = "zig_flamegraph SVG artifact",
    }, .{ .bytes_written = profiling_svg.len });
    const flame = try zigFlamegraph(allocator, context, try profilingTestArgs(allocator,
        \\{"format":"recursive","input":"stacks.folded","output":"profile.svg","title":"fixture","subtitle":"unit","colors":"hot","width":1200,"min_width":5,"hash":true}
    ));
    defer mcp_result.deinitToolResult(allocator, flame);
    try expectProfilingKind(flame, "zig_flamegraph");

    try commands.verify();
    try workspace.verify();
}

test "profiling adapters validate malformed tool arguments" {
    const backing_allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(backing_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var commands = fakes.FakeCommandRunner.init(backing_allocator);
    defer commands.deinit();
    var workspace = fakes.FakeWorkspaceStore.init(backing_allocator);
    defer workspace.deinit();
    const context = testProfilingContext(&commands, &workspace);

    const missing_command = try zigProfileRun(allocator, context, null);
    defer mcp_result.deinitToolResult(allocator, missing_command);
    try expectToolErrorCode(missing_command, "missing_required_argument");

    const empty_command = try zigProfileRun(allocator, context, try profilingTestArgs(allocator, "{\"command\":\"   \\t\"}"));
    defer mcp_result.deinitToolResult(allocator, empty_command);
    try expectToolErrorCode(empty_command, "invalid_argument");

    const bad_quote = try zigProfileRun(allocator, context, try profilingTestArgs(allocator, "{\"command\":\"zig 'unterminated\"}"));
    defer mcp_result.deinitToolResult(allocator, bad_quote);
    try expectToolErrorCode(bad_quote, "invalid_argument");

    const missing_format = try zigFlamegraph(allocator, context, try profilingTestArgs(allocator, "{}"));
    defer mcp_result.deinitToolResult(allocator, missing_format);
    try expectToolErrorCode(missing_format, "missing_required_argument");

    const invalid_flamegraph_min_width = try zigFlamegraph(allocator, context, try profilingTestArgs(allocator, "{\"format\":\"recursive\",\"input\":\"a.folded\",\"output\":\"a.svg\",\"min_width\":0}"));
    defer mcp_result.deinitToolResult(allocator, invalid_flamegraph_min_width);
    try expectToolErrorCode(invalid_flamegraph_min_width, "invalid_argument");

    const missing_diff_output = try zigFlamegraphDiff(allocator, context, try profilingTestArgs(allocator, "{\"before\":\"a.folded\",\"after\":\"b.folded\"}"));
    defer mcp_result.deinitToolResult(allocator, missing_diff_output);
    try expectToolErrorCode(missing_diff_output, "missing_required_argument");

    const invalid_diff_min_width = try zigFlamegraphDiff(allocator, context, try profilingTestArgs(allocator, "{\"before\":\"a.folded\",\"after\":\"b.folded\",\"output\":\"diff.svg\",\"min_width\":-1}"));
    defer mcp_result.deinitToolResult(allocator, invalid_diff_min_width);
    try expectToolErrorCode(invalid_diff_min_width, "invalid_argument");

    try commands.verify();
    try workspace.verify();
}

test "profiling flamegraph adapter reports workspace backend and artifact failures" {
    const backing_allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(backing_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const invalid_utf8 = [_]u8{0xff};

    {
        var commands = fakes.FakeCommandRunner.init(backing_allocator);
        defer commands.deinit();
        var workspace = fakes.FakeWorkspaceStore.init(backing_allocator);
        defer workspace.deinit();
        const context = testProfilingContext(&commands, &workspace);

        try workspace.expectResolveError(.{ .path = "../escape.folded", .provenance = "profiling input path resolution" }, error.PathOutsideWorkspace);
        const result = try zigFlamegraph(allocator, context, try profilingTestArgs(allocator, "{\"format\":\"recursive\",\"input\":\"../escape.folded\",\"output\":\"profile.svg\"}"));
        defer mcp_result.deinitToolResult(allocator, result);
        try expectToolErrorCode(result, "path_outside_workspace");
        try commands.verify();
        try workspace.verify();
    }

    {
        var commands = fakes.FakeCommandRunner.init(backing_allocator);
        defer commands.deinit();
        var workspace = fakes.FakeWorkspaceStore.init(backing_allocator);
        defer workspace.deinit();
        const context = testProfilingContext(&commands, &workspace);

        try workspace.expectResolve(.{ .path = "missing.folded", .provenance = "profiling input path resolution" }, "/workspace/missing.folded");
        try workspace.expectResolve(.{ .path = "profile.svg", .for_output = true, .provenance = "profiling output path resolution" }, "/workspace/profile.svg");
        try workspace.expectReadError(.{ .path = "missing.folded", .max_bytes = 0, .provenance = "zig_flamegraph input readability" }, error.FileNotFound);
        const result = try zigFlamegraph(allocator, context, try profilingTestArgs(allocator, "{\"format\":\"recursive\",\"input\":\"missing.folded\",\"output\":\"profile.svg\"}"));
        defer mcp_result.deinitToolResult(allocator, result);
        try expectToolErrorCode(result, "workspace_input_read_failed");
        try commands.verify();
        try workspace.verify();
    }

    {
        var commands = fakes.FakeCommandRunner.init(backing_allocator);
        defer commands.deinit();
        var workspace = fakes.FakeWorkspaceStore.init(backing_allocator);
        defer workspace.deinit();
        const context = testProfilingContext(&commands, &workspace);

        try workspace.expectResolve(.{ .path = "stacks.folded", .provenance = "profiling input path resolution" }, "/workspace/stacks.folded");
        try workspace.expectResolve(.{ .path = "profile.svg", .for_output = true, .provenance = "profiling output path resolution" }, "/workspace/profile.svg");
        try workspace.expectRead(.{ .path = "stacks.folded", .max_bytes = 0, .provenance = "zig_flamegraph input readability" }, "");
        try commands.expectRunError(.{
            .argv = &.{ "/bin/zflame", "recursive", "/workspace/stacks.folded" },
            .cwd = "/workspace",
            .timeout_ms = 5000,
            .max_stdout_bytes = flamegraph_usecase.command_output_limit,
            .max_stderr_bytes = flamegraph_usecase.command_output_limit,
            .provenance = "zig_flamegraph zflame render",
        }, error.AccessDenied);
        const result = try zigFlamegraph(allocator, context, try profilingTestArgs(allocator, "{\"format\":\"recursive\",\"input\":\"stacks.folded\",\"output\":\"profile.svg\"}"));
        defer mcp_result.deinitToolResult(allocator, result);
        try expectProfilingKind(result, "backend_error");
        try commands.verify();
        try workspace.verify();
    }

    {
        var commands = fakes.FakeCommandRunner.init(backing_allocator);
        defer commands.deinit();
        var workspace = fakes.FakeWorkspaceStore.init(backing_allocator);
        defer workspace.deinit();
        const context = testProfilingContext(&commands, &workspace);

        try workspace.expectResolve(.{ .path = "stacks.folded", .provenance = "profiling input path resolution" }, "/workspace/stacks.folded");
        try workspace.expectResolve(.{ .path = "profile.svg", .for_output = true, .provenance = "profiling output path resolution" }, "/workspace/profile.svg");
        try workspace.expectRead(.{ .path = "stacks.folded", .max_bytes = 0, .provenance = "zig_flamegraph input readability" }, "");
        try commands.expectRun(.{
            .argv = &.{ "/bin/zflame", "recursive", "/workspace/stacks.folded" },
            .cwd = "/workspace",
            .timeout_ms = 5000,
            .max_stdout_bytes = flamegraph_usecase.command_output_limit,
            .max_stderr_bytes = flamegraph_usecase.command_output_limit,
            .provenance = "zig_flamegraph zflame render",
        }, .{ .exit_code = 9, .stdout = "partial\n", .stderr = invalid_utf8[0..], .stderr_truncated = true });
        const result = try zigFlamegraph(allocator, context, try profilingTestArgs(allocator, "{\"format\":\"recursive\",\"input\":\"stacks.folded\",\"output\":\"profile.svg\"}"));
        defer mcp_result.deinitToolResult(allocator, result);
        try expectToolErrorCode(result, "zflame_command_failed");
        try std.testing.expect(result.structuredContent.?.object.get("stderr_invalid_utf8").?.bool);
        try commands.verify();
        try workspace.verify();
    }

    {
        var commands = fakes.FakeCommandRunner.init(backing_allocator);
        defer commands.deinit();
        var workspace = fakes.FakeWorkspaceStore.init(backing_allocator);
        defer workspace.deinit();
        const context = testProfilingContext(&commands, &workspace);

        try workspace.expectResolve(.{ .path = "stacks.folded", .provenance = "profiling input path resolution" }, "/workspace/stacks.folded");
        try workspace.expectResolve(.{ .path = "profile.svg", .for_output = true, .provenance = "profiling output path resolution" }, "/workspace/profile.svg");
        try workspace.expectRead(.{ .path = "stacks.folded", .max_bytes = 0, .provenance = "zig_flamegraph input readability" }, "");
        try commands.expectRun(.{
            .argv = &.{ "/bin/zflame", "recursive", "/workspace/stacks.folded" },
            .cwd = "/workspace",
            .timeout_ms = 5000,
            .max_stdout_bytes = flamegraph_usecase.command_output_limit,
            .max_stderr_bytes = flamegraph_usecase.command_output_limit,
            .provenance = "zig_flamegraph zflame render",
        }, .{ .stdout = "not svg" });
        const result = try zigFlamegraph(allocator, context, try profilingTestArgs(allocator, "{\"format\":\"recursive\",\"input\":\"stacks.folded\",\"output\":\"profile.svg\"}"));
        defer mcp_result.deinitToolResult(allocator, result);
        try expectToolErrorCode(result, "backend_output_malformed");
        try commands.verify();
        try workspace.verify();
    }

    {
        var commands = fakes.FakeCommandRunner.init(backing_allocator);
        defer commands.deinit();
        var workspace = fakes.FakeWorkspaceStore.init(backing_allocator);
        defer workspace.deinit();
        var context = testProfilingContext(&commands, &workspace);
        context.probe_cache.zflame = .{};

        try workspace.expectResolve(.{ .path = "stacks.folded", .provenance = "profiling input path resolution" }, "/workspace/stacks.folded");
        try workspace.expectResolve(.{ .path = "profile.svg", .for_output = true, .provenance = "profiling output path resolution" }, "/workspace/profile.svg");
        try workspace.expectRead(.{ .path = "stacks.folded", .max_bytes = 0, .provenance = "zig_flamegraph input readability" }, "");
        try commands.expectRun(.{
            .argv = &.{ "/bin/zflame", "recursive", "/workspace/stacks.folded" },
            .cwd = "/workspace",
            .timeout_ms = 5000,
            .max_stdout_bytes = flamegraph_usecase.command_output_limit,
            .max_stderr_bytes = flamegraph_usecase.command_output_limit,
            .provenance = "zig_flamegraph zflame render",
        }, .{ .stdout = profiling_svg });
        try workspace.expectWriteError(.{
            .path = "profile.svg",
            .bytes = profiling_svg,
            .create_parent_dirs = true,
            .replace_existing = true,
            .provenance = "zig_flamegraph SVG artifact",
        }, error.PermissionDenied);
        const result = try zigFlamegraph(allocator, context, try profilingTestArgs(allocator, "{\"format\":\"recursive\",\"input\":\"stacks.folded\",\"output\":\"profile.svg\"}"));
        defer mcp_result.deinitToolResult(allocator, result);
        try expectToolErrorCode(result, "workspace_artifact_write_failed");
        try commands.verify();
        try workspace.verify();
    }
}

test "profiling adapter renders differential flamegraphs and validates arguments" {
    const backing_allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(backing_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var commands = fakes.FakeCommandRunner.init(backing_allocator);
    defer commands.deinit();
    var workspace = fakes.FakeWorkspaceStore.init(backing_allocator);
    defer workspace.deinit();
    const context = testProfilingContext(&commands, &workspace);

    const missing = try zigFlamegraph(allocator, context, try profilingTestArgs(allocator, "{\"format\":\"recursive\"}"));
    defer mcp_result.deinitToolResult(allocator, missing);
    try std.testing.expect(missing.is_error);

    const invalid_format = try zigFlamegraph(allocator, context, try profilingTestArgs(allocator, "{\"format\":\"guess\",\"input\":\"a\",\"output\":\"b\"}"));
    defer mcp_result.deinitToolResult(allocator, invalid_format);
    try std.testing.expect(invalid_format.is_error);

    const invalid_width = try zigFlamegraphDiff(allocator, context, try profilingTestArgs(allocator, "{\"before\":\"before.folded\",\"after\":\"after.folded\",\"output\":\"diff.svg\",\"width\":0}"));
    defer mcp_result.deinitToolResult(allocator, invalid_width);
    try std.testing.expect(invalid_width.is_error);

    try workspace.expectResolve(.{ .path = "before.folded", .provenance = "profiling input path resolution" }, "/workspace/before.folded");
    try workspace.expectResolve(.{ .path = "after.folded", .provenance = "profiling input path resolution" }, "/workspace/after.folded");
    try workspace.expectResolve(.{ .path = "diff.svg", .for_output = true, .provenance = "profiling output path resolution" }, "/workspace/diff.svg");
    try workspace.expectResolve(.{ .path = "diff.folded", .for_output = true, .provenance = "profiling output path resolution" }, "/workspace/diff.folded");
    try workspace.expectRead(.{ .path = "before.folded", .max_bytes = 0, .provenance = "zig_flamegraph_diff input readability" }, "");
    try workspace.expectRead(.{ .path = "after.folded", .max_bytes = 0, .provenance = "zig_flamegraph_diff input readability" }, "");
    try commands.expectRun(.{
        .argv = &.{ "/bin/diff-folded", "--output=/workspace/diff.folded", "/workspace/before.folded", "/workspace/after.folded" },
        .cwd = "/workspace",
        .timeout_ms = 5000,
        .max_stdout_bytes = flamegraph_diff_usecase.command_output_limit,
        .max_stderr_bytes = flamegraph_diff_usecase.command_output_limit,
        .provenance = "zig_flamegraph_diff diff-folded render",
    }, .{ .stdout = "diff ok\n" });
    try workspace.expectRead(.{ .path = "diff.folded", .max_bytes = flamegraph_diff_usecase.command_output_limit, .provenance = "zig_flamegraph_diff intermediate folded diff" }, "main;before 1\nmain;after 2\n");
    try workspace.expectRead(.{ .path = "diff.folded", .max_bytes = 0, .provenance = "zig_flamegraph input readability" }, "");
    try commands.expectRun(.{
        .argv = &.{ "/bin/zflame", "recursive", "--title=delta", "/workspace/diff.folded" },
        .cwd = "/workspace",
        .timeout_ms = 5000,
        .max_stdout_bytes = flamegraph_usecase.command_output_limit,
        .max_stderr_bytes = flamegraph_usecase.command_output_limit,
        .provenance = "zig_flamegraph zflame render",
    }, .{ .stdout = profiling_svg });
    try workspace.expectWrite(.{
        .path = "diff.svg",
        .bytes = profiling_svg,
        .create_parent_dirs = true,
        .replace_existing = true,
        .provenance = "zig_flamegraph SVG artifact",
    }, .{ .bytes_written = profiling_svg.len });

    const diff = try zigFlamegraphDiff(allocator, context, try profilingTestArgs(allocator,
        \\{"before":"before.folded","after":"after.folded","output":"diff.svg","intermediate":"diff.folded","title":"delta"}
    ));
    defer mcp_result.deinitToolResult(allocator, diff);
    try expectProfilingKind(diff, "zig_flamegraph_diff");
    try std.testing.expect(diff.structuredContent.?.object.get("intermediate_folded") != null);

    try commands.verify();
    try workspace.verify();
}

test "profiling diff adapter reports workspace and backend failures" {
    const backing_allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(backing_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    {
        var commands = fakes.FakeCommandRunner.init(backing_allocator);
        defer commands.deinit();
        var workspace = fakes.FakeWorkspaceStore.init(backing_allocator);
        defer workspace.deinit();
        const context = testProfilingContext(&commands, &workspace);

        try workspace.expectResolve(.{ .path = "before.folded", .provenance = "profiling input path resolution" }, "/workspace/before.folded");
        try workspace.expectResolve(.{ .path = "after.folded", .provenance = "profiling input path resolution" }, "/workspace/after.folded");
        try workspace.expectResolve(.{ .path = "diff.svg", .for_output = true, .provenance = "profiling output path resolution" }, "/workspace/diff.svg");
        const result = try zigFlamegraphDiff(allocator, context, try profilingTestArgs(allocator, "{\"before\":\"before.folded\",\"after\":\"after.folded\",\"output\":\"diff.svg\"}"));
        defer mcp_result.deinitToolResult(allocator, result);
        try expectToolErrorCode(result, "profiling_usecase_failed");
        try commands.verify();
        try workspace.verify();
    }

    {
        var commands = fakes.FakeCommandRunner.init(backing_allocator);
        defer commands.deinit();
        var workspace = fakes.FakeWorkspaceStore.init(backing_allocator);
        defer workspace.deinit();
        const context = testProfilingContext(&commands, &workspace);

        try workspace.expectResolveError(.{ .path = "../before.folded", .provenance = "profiling input path resolution" }, error.PathOutsideWorkspace);
        const result = try zigFlamegraphDiff(allocator, context, try profilingTestArgs(allocator, "{\"before\":\"../before.folded\",\"after\":\"after.folded\",\"output\":\"diff.svg\",\"intermediate\":\"diff.folded\"}"));
        defer mcp_result.deinitToolResult(allocator, result);
        try expectToolErrorCode(result, "path_outside_workspace");
        try commands.verify();
        try workspace.verify();
    }

    {
        var commands = fakes.FakeCommandRunner.init(backing_allocator);
        defer commands.deinit();
        var workspace = fakes.FakeWorkspaceStore.init(backing_allocator);
        defer workspace.deinit();
        const context = testProfilingContext(&commands, &workspace);

        try expectDiffResolves(&workspace, "before.folded", "/workspace/before.folded", "after.folded", "/workspace/after.folded", "diff.svg", "/workspace/diff.svg", "diff.folded", "/workspace/diff.folded");
        try workspace.expectReadError(.{ .path = "before.folded", .max_bytes = 0, .provenance = "zig_flamegraph_diff input readability" }, error.FileNotFound);
        const result = try zigFlamegraphDiff(allocator, context, try profilingTestArgs(allocator, "{\"before\":\"before.folded\",\"after\":\"after.folded\",\"output\":\"diff.svg\",\"intermediate\":\"diff.folded\"}"));
        defer mcp_result.deinitToolResult(allocator, result);
        try expectToolErrorCode(result, "workspace_input_read_failed");
        try commands.verify();
        try workspace.verify();
    }

    {
        var commands = fakes.FakeCommandRunner.init(backing_allocator);
        defer commands.deinit();
        var workspace = fakes.FakeWorkspaceStore.init(backing_allocator);
        defer workspace.deinit();
        const context = testProfilingContext(&commands, &workspace);

        try expectDiffResolves(&workspace, "before.folded", "/workspace/before.folded", "after.folded", "/workspace/after.folded", "diff.svg", "/workspace/diff.svg", ".zigar-cache/profile/diff.folded", "/workspace/.zigar-cache/profile/diff.folded");
        try workspace.expectRead(.{ .path = "before.folded", .max_bytes = 0, .provenance = "zig_flamegraph_diff input readability" }, "");
        try workspace.expectRead(.{ .path = "after.folded", .max_bytes = 0, .provenance = "zig_flamegraph_diff input readability" }, "");
        const result = try zigFlamegraphDiff(allocator, context, try profilingTestArgs(allocator, "{\"before\":\"before.folded\",\"after\":\"after.folded\",\"output\":\"diff.svg\",\"intermediate\":\".zigar-cache/profile/diff.folded\"}"));
        defer mcp_result.deinitToolResult(allocator, result);
        try expectToolErrorCode(result, "workspace_artifact_write_failed");
        try commands.verify();
        try workspace.verify();
    }

    {
        var commands = fakes.FakeCommandRunner.init(backing_allocator);
        defer commands.deinit();
        var workspace = fakes.FakeWorkspaceStore.init(backing_allocator);
        defer workspace.deinit();
        const context = testProfilingContext(&commands, &workspace);

        try expectDiffResolves(&workspace, "before.folded", "/workspace/before.folded", "after.folded", "/workspace/after.folded", "diff.svg", "/workspace/diff.svg", "diff.folded", "/workspace/diff.folded");
        try workspace.expectRead(.{ .path = "before.folded", .max_bytes = 0, .provenance = "zig_flamegraph_diff input readability" }, "");
        try workspace.expectRead(.{ .path = "after.folded", .max_bytes = 0, .provenance = "zig_flamegraph_diff input readability" }, "");
        try commands.expectRunError(.{
            .argv = &.{ "/bin/diff-folded", "--output=/workspace/diff.folded", "/workspace/before.folded", "/workspace/after.folded" },
            .cwd = "/workspace",
            .timeout_ms = 5000,
            .max_stdout_bytes = flamegraph_diff_usecase.command_output_limit,
            .max_stderr_bytes = flamegraph_diff_usecase.command_output_limit,
            .provenance = "zig_flamegraph_diff diff-folded render",
        }, error.FileNotFound);
        const result = try zigFlamegraphDiff(allocator, context, try profilingTestArgs(allocator, "{\"before\":\"before.folded\",\"after\":\"after.folded\",\"output\":\"diff.svg\",\"intermediate\":\"diff.folded\"}"));
        defer mcp_result.deinitToolResult(allocator, result);
        try expectProfilingKind(result, "backend_error");
        try commands.verify();
        try workspace.verify();
    }

    {
        var commands = fakes.FakeCommandRunner.init(backing_allocator);
        defer commands.deinit();
        var workspace = fakes.FakeWorkspaceStore.init(backing_allocator);
        defer workspace.deinit();
        const context = testProfilingContext(&commands, &workspace);

        try expectDiffResolves(&workspace, "before.folded", "/workspace/before.folded", "after.folded", "/workspace/after.folded", "diff.svg", "/workspace/diff.svg", "diff.folded", "/workspace/diff.folded");
        try workspace.expectRead(.{ .path = "before.folded", .max_bytes = 0, .provenance = "zig_flamegraph_diff input readability" }, "");
        try workspace.expectRead(.{ .path = "after.folded", .max_bytes = 0, .provenance = "zig_flamegraph_diff input readability" }, "");
        try commands.expectRun(.{
            .argv = &.{ "/bin/diff-folded", "--output=/workspace/diff.folded", "/workspace/before.folded", "/workspace/after.folded" },
            .cwd = "/workspace",
            .timeout_ms = 5000,
            .max_stdout_bytes = flamegraph_diff_usecase.command_output_limit,
            .max_stderr_bytes = flamegraph_diff_usecase.command_output_limit,
            .provenance = "zig_flamegraph_diff diff-folded render",
        }, .{ .term = .signal, .stdout = "partial\n", .stderr = "boom\n", .stdout_truncated = true });
        const result = try zigFlamegraphDiff(allocator, context, try profilingTestArgs(allocator, "{\"before\":\"before.folded\",\"after\":\"after.folded\",\"output\":\"diff.svg\",\"intermediate\":\"diff.folded\"}"));
        defer mcp_result.deinitToolResult(allocator, result);
        try expectToolErrorCode(result, "diff_folded_command_failed");
        try commands.verify();
        try workspace.verify();
    }

    {
        var commands = fakes.FakeCommandRunner.init(backing_allocator);
        defer commands.deinit();
        var workspace = fakes.FakeWorkspaceStore.init(backing_allocator);
        defer workspace.deinit();
        const context = testProfilingContext(&commands, &workspace);

        try expectDiffResolves(&workspace, "before.folded", "/workspace/before.folded", "after.folded", "/workspace/after.folded", "diff.svg", "/workspace/diff.svg", "diff.folded", "/workspace/diff.folded");
        try workspace.expectRead(.{ .path = "before.folded", .max_bytes = 0, .provenance = "zig_flamegraph_diff input readability" }, "");
        try workspace.expectRead(.{ .path = "after.folded", .max_bytes = 0, .provenance = "zig_flamegraph_diff input readability" }, "");
        try commands.expectRun(.{
            .argv = &.{ "/bin/diff-folded", "--output=/workspace/diff.folded", "/workspace/before.folded", "/workspace/after.folded" },
            .cwd = "/workspace",
            .timeout_ms = 5000,
            .max_stdout_bytes = flamegraph_diff_usecase.command_output_limit,
            .max_stderr_bytes = flamegraph_diff_usecase.command_output_limit,
            .provenance = "zig_flamegraph_diff diff-folded render",
        }, .{ .stdout = "ok\n" });
        try workspace.expectReadError(.{ .path = "diff.folded", .max_bytes = flamegraph_diff_usecase.command_output_limit, .provenance = "zig_flamegraph_diff intermediate folded diff" }, error.AccessDenied);
        const result = try zigFlamegraphDiff(allocator, context, try profilingTestArgs(allocator, "{\"before\":\"before.folded\",\"after\":\"after.folded\",\"output\":\"diff.svg\",\"intermediate\":\"diff.folded\"}"));
        defer mcp_result.deinitToolResult(allocator, result);
        try expectToolErrorCode(result, "workspace_artifact_read_failed");
        try commands.verify();
        try workspace.verify();
    }

    {
        var commands = fakes.FakeCommandRunner.init(backing_allocator);
        defer commands.deinit();
        var workspace = fakes.FakeWorkspaceStore.init(backing_allocator);
        defer workspace.deinit();
        const context = testProfilingContext(&commands, &workspace);

        try expectDiffResolves(&workspace, "before.folded", "/workspace/before.folded", "after.folded", "/workspace/after.folded", "diff.svg", "/workspace/diff.svg", "diff.folded", "/workspace/diff.folded");
        try workspace.expectRead(.{ .path = "before.folded", .max_bytes = 0, .provenance = "zig_flamegraph_diff input readability" }, "");
        try workspace.expectRead(.{ .path = "after.folded", .max_bytes = 0, .provenance = "zig_flamegraph_diff input readability" }, "");
        try commands.expectRun(.{
            .argv = &.{ "/bin/diff-folded", "--output=/workspace/diff.folded", "/workspace/before.folded", "/workspace/after.folded" },
            .cwd = "/workspace",
            .timeout_ms = 5000,
            .max_stdout_bytes = flamegraph_diff_usecase.command_output_limit,
            .max_stderr_bytes = flamegraph_diff_usecase.command_output_limit,
            .provenance = "zig_flamegraph_diff diff-folded render",
        }, .{ .stdout = "ok\n" });
        try workspace.expectRead(.{ .path = "diff.folded", .max_bytes = flamegraph_diff_usecase.command_output_limit, .provenance = "zig_flamegraph_diff intermediate folded diff" }, "  \n\t");
        const result = try zigFlamegraphDiff(allocator, context, try profilingTestArgs(allocator, "{\"before\":\"before.folded\",\"after\":\"after.folded\",\"output\":\"diff.svg\",\"intermediate\":\"diff.folded\"}"));
        defer mcp_result.deinitToolResult(allocator, result);
        try expectToolErrorCode(result, "backend_output_malformed");
        try commands.verify();
        try workspace.verify();
    }

    {
        var commands = fakes.FakeCommandRunner.init(backing_allocator);
        defer commands.deinit();
        var workspace = fakes.FakeWorkspaceStore.init(backing_allocator);
        defer workspace.deinit();
        const context = testProfilingContext(&commands, &workspace);

        try expectDiffResolves(&workspace, "before.folded", "/workspace/before.folded", "after.folded", "/workspace/after.folded", "diff.svg", "/workspace/diff.svg", "diff.folded", "/workspace/diff.folded");
        try workspace.expectRead(.{ .path = "before.folded", .max_bytes = 0, .provenance = "zig_flamegraph_diff input readability" }, "");
        try workspace.expectRead(.{ .path = "after.folded", .max_bytes = 0, .provenance = "zig_flamegraph_diff input readability" }, "");
        try commands.expectRun(.{
            .argv = &.{ "/bin/diff-folded", "--output=/workspace/diff.folded", "/workspace/before.folded", "/workspace/after.folded" },
            .cwd = "/workspace",
            .timeout_ms = 5000,
            .max_stdout_bytes = flamegraph_diff_usecase.command_output_limit,
            .max_stderr_bytes = flamegraph_diff_usecase.command_output_limit,
            .provenance = "zig_flamegraph_diff diff-folded render",
        }, .{ .stdout = "ok\n" });
        try workspace.expectRead(.{ .path = "diff.folded", .max_bytes = flamegraph_diff_usecase.command_output_limit, .provenance = "zig_flamegraph_diff intermediate folded diff" }, "main;before 1\nmain;after 2\n");
        try workspace.expectRead(.{ .path = "diff.folded", .max_bytes = 0, .provenance = "zig_flamegraph input readability" }, "");
        try commands.expectRunError(.{
            .argv = &.{ "/bin/zflame", "recursive", "/workspace/diff.folded" },
            .cwd = "/workspace",
            .timeout_ms = 5000,
            .max_stdout_bytes = flamegraph_usecase.command_output_limit,
            .max_stderr_bytes = flamegraph_usecase.command_output_limit,
            .provenance = "zig_flamegraph zflame render",
        }, error.AccessDenied);
        const result = try zigFlamegraphDiff(allocator, context, try profilingTestArgs(allocator, "{\"before\":\"before.folded\",\"after\":\"after.folded\",\"output\":\"diff.svg\",\"intermediate\":\"diff.folded\"}"));
        defer mcp_result.deinitToolResult(allocator, result);
        try expectProfilingKind(result, "backend_error");
        try commands.verify();
        try workspace.verify();
    }
}

const profiling_svg = "<svg xmlns=\"http://www.w3.org/2000/svg\"><title>fixture</title></svg>\n";

fn testProfilingContext(commands: *fakes.FakeCommandRunner, workspace: *fakes.FakeWorkspaceStore) app_context.ProfilingContext {
    return .{
        .workspace = .{ .root = "/workspace", .cache_root = "/workspace/.zigar-cache" },
        .tool_paths = .{ .zflame = "/bin/zflame", .diff_folded = "/bin/diff-folded" },
        .timeouts = .{ .command_ms = 5000 },
        .command_runner = commands.port(),
        .workspace_store = workspace.port(),
        .probe_cache = .{
            .zflame = .{ .probed = true, .ok = true, .status = "ok", .resolution = "ready" },
            .diff_folded = .{ .probed = true, .ok = false, .status = "missing", .resolution = "install diff-folded" },
        },
    };
}

fn profilingTestArgs(allocator: std.mem.Allocator, text: []const u8) !std.json.Value {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, text, .{});
    return parsed.value;
}

fn expectDiffResolves(
    workspace: *fakes.FakeWorkspaceStore,
    before: []const u8,
    before_abs: []const u8,
    after: []const u8,
    after_abs: []const u8,
    output: []const u8,
    output_abs: []const u8,
    intermediate: []const u8,
    intermediate_abs: []const u8,
) !void {
    try workspace.expectResolve(.{ .path = before, .provenance = "profiling input path resolution" }, before_abs);
    try workspace.expectResolve(.{ .path = after, .provenance = "profiling input path resolution" }, after_abs);
    try workspace.expectResolve(.{ .path = output, .for_output = true, .provenance = "profiling output path resolution" }, output_abs);
    try workspace.expectResolve(.{ .path = intermediate, .for_output = true, .provenance = "profiling output path resolution" }, intermediate_abs);
}

fn expectProfilingKind(result: mcp.tools.ToolResult, expected: []const u8) !void {
    const structured = result.structuredContent orelse return error.MissingStructuredContent;
    try std.testing.expect(structured == .object);
    const kind = structured.object.get("kind") orelse return error.MissingKind;
    try std.testing.expect(kind == .string);
    try std.testing.expectEqualStrings(expected, kind.string);
}

fn expectToolErrorCode(result: mcp.tools.ToolResult, expected: []const u8) !void {
    try std.testing.expect(result.is_error);
    const structured = result.structuredContent orelse return error.MissingStructuredContent;
    try std.testing.expect(structured == .object);
    const code = structured.object.get("code") orelse return error.MissingCode;
    try std.testing.expect(code == .string);
    try std.testing.expectEqualStrings(expected, code.string);
}
