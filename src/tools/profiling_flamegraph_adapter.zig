const std = @import("std");
const mcp = @import("mcp");
const zigar = @import("zigar");

const backend_contracts = zigar.backend_contracts;
const command = zigar.command;
const command_output = zigar.command_output;
const common = @import("common.zig");
const app_errors = zigar.app.errors;
const bootstrap_runtime_ports = zigar.bootstrap.runtime_ports;
const doctor = zigar.doctor;
const flamegraph_model = zigar.domain.profiling.flamegraph;
const flamegraph_usecase = zigar.app.usecases.profiling.flamegraph;
const json_result = zigar.json_result;
const tool_errors = zigar.tool_errors;

const App = common.App;
const argBool = common.argBool;
const argString = common.argString;
const argvValue = common.argvValue;
const backendErrorResult = common.backendErrorResult;
const cachedProbeValue = common.cachedProbeValue;
const invalidArgumentResult = common.invalidArgumentResult;
const missingArgumentResult = common.missingArgumentResult;
const structured = common.structured;
const toolErrorFromError = common.toolErrorFromError;
const toolErrorResult = common.toolErrorResult;
const workspacePathErrorResult = common.workspacePathErrorResult;

const tool_name = "zig_flamegraph";
const operation_name = "render_flamegraph";

pub fn zigFlamegraph(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    var runtime_ports = bootstrap_runtime_ports.RuntimePorts.init(a, .{});
    var resolved = switch (try requestFromArgs(allocator, &runtime_ports, args)) {
        .ok => |request| request,
        .err => |result| return result,
    };
    defer resolved.deinit();

    const profiling_ctx = runtime_ports.profilingContext() catch |err| return toolErrorFromError(allocator, .{
        .tool = tool_name,
        .operation = operation_name,
        .phase = "build_app_context",
        .code = "profiling_context_unavailable",
        .category = "configuration",
        .resolution = "The profiling use case requires command runner and workspace ports from the runtime bridge.",
    }, err);

    var render = try flamegraph_usecase.run(allocator, profiling_ctx, resolved.request);
    defer render.deinit(allocator);
    const artifact = switch (render) {
        .ok => |value| value,
        .err => |failure| return failureResult(allocator, resolved.request, failure),
    };

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const value = flamegraphResultValue(arena.allocator(), .{
        .zflame_probe = cachedProbeFor(a, .zflame),
    }, resolved.request, artifact) catch return error.OutOfMemory;
    return structured(allocator, value);
}

const ParsedRequest = struct {
    format: flamegraph_model.ZflameFormat,
    input: []const u8,
    output: []const u8,
    options: flamegraph_model.ZflameRenderOptions,
};

const ParseResult = union(enum) {
    ok: ParsedRequest,
    err: mcp.tools.ToolResult,
};

fn parseRequestArgs(allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!ParseResult {
    const format_raw = argString(args, "format") orelse return .{ .err = try missingArgumentResult(allocator, tool_name, "format", flamegraph_model.supportedZflameFormatsText()) };
    const format = flamegraph_model.parseZflameFormat(format_raw) orelse return .{ .err = try invalidZflameFormat(allocator, format_raw) };
    const input = argString(args, "input") orelse return .{ .err = try missingArgumentResult(allocator, tool_name, "input", "workspace-relative profiler input path") };
    const output = argString(args, "output") orelse return .{ .err = try missingArgumentResult(allocator, tool_name, "output", "workspace-relative SVG output path") };
    const options = switch (try zflameOptionsFromArgs(allocator, args)) {
        .ok => |value| value,
        .err => |result| return .{ .err = result },
    };
    return .{ .ok = .{
        .format = format,
        .input = input,
        .output = output,
        .options = options,
    } };
}

const ResolvedRequest = struct {
    request: flamegraph_usecase.Request,
    input_abs: []const u8,
    output_abs: []const u8,
    path_allocator: std.mem.Allocator,

    fn deinit(self: *ResolvedRequest) void {
        self.path_allocator.free(self.input_abs);
        self.path_allocator.free(self.output_abs);
    }
};

const RequestResult = union(enum) {
    ok: ResolvedRequest,
    err: mcp.tools.ToolResult,
};

fn requestFromArgs(allocator: std.mem.Allocator, runtime_ports: *bootstrap_runtime_ports.RuntimePorts, args: ?std.json.Value) mcp.tools.ToolError!RequestResult {
    const parsed = switch (try parseRequestArgs(allocator, args)) {
        .ok => |value| value,
        .err => |result| return .{ .err = result },
    };
    const input_abs = runtime_ports.resolveInputPath(parsed.input) catch |err| {
        return .{ .err = try workspacePathErrorResult(runtime_ports.app, allocator, tool_name, parsed.input, err) };
    };
    const output_abs = runtime_ports.resolveOutputPath(parsed.output) catch |err| {
        const result = workspacePathErrorResult(runtime_ports.app, allocator, tool_name, parsed.output, err) catch |map_err| {
            runtime_ports.freeResolvedPath(input_abs);
            return map_err;
        };
        runtime_ports.freeResolvedPath(input_abs);
        return .{ .err = result };
    };
    return .{ .ok = .{
        .request = .{
            .tool_name = tool_name,
            .operation = operation_name,
            .input = parsed.input,
            .input_abs = input_abs,
            .output = parsed.output,
            .output_abs = output_abs,
            .format = parsed.format,
            .options = parsed.options,
        },
        .input_abs = input_abs,
        .output_abs = output_abs,
        .path_allocator = runtime_ports.pathAllocator(),
    } };
}

const OptionsResult = union(enum) {
    ok: flamegraph_model.ZflameRenderOptions,
    err: mcp.tools.ToolResult,
};

fn zflameOptionsFromArgs(allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!OptionsResult {
    const width = switch (try positiveIntArg(allocator, args, "width")) {
        .ok => |value| value,
        .err => |result| return .{ .err = result },
    };
    const min_width = switch (try positiveIntArg(allocator, args, "min_width")) {
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

fn positiveIntArg(allocator: std.mem.Allocator, args: ?std.json.Value, name: []const u8) mcp.tools.ToolError!OptionalIntResult {
    const value = mcp.tools.getInteger(args, name) orelse return .{ .ok = null };
    if (value > 0) return .{ .ok = value };
    return .{ .err = try invalidArgumentResult(allocator, tool_name, name, "positive integer", "zero or negative", "Use positive pixel values for zflame sizing options.") };
}

fn invalidZflameFormat(allocator: std.mem.Allocator, actual: []const u8) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invalidArgumentResult(
        allocator,
        tool_name,
        "format",
        flamegraph_model.supportedZflameFormatsText(),
        actual,
        "Choose an explicit zflame input format from the tools/list schema; zigar does not expose format guessing.",
    );
}

const ResultRenderContext = struct {
    zflame_probe: ?doctor.Probe = null,
};

fn flamegraphResultValue(
    allocator: std.mem.Allocator,
    context: ResultRenderContext,
    request: flamegraph_usecase.Request,
    artifact: flamegraph_usecase.Artifact,
) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
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
    try obj.put(allocator, "backend_metadata", try backendMetadataValue(allocator, context.zflame_probe, .zflame, artifact.backend_executable_path, artifact.compatibility_status, flamegraph_model.zflame_compatibility_baseline));
    try obj.put(allocator, "argv_shape", .{ .string = zflameArgvShape() });
    try obj.put(allocator, "argv", try argvValue(allocator, artifact.argv.items));
    try obj.put(allocator, "warnings", try renderWarningsValue(allocator, context.zflame_probe));
    try obj.put(allocator, "compatibility_status", .{ .string = artifact.compatibility_status });
    try obj.put(allocator, "capture_semantics", .{ .string = flamegraph_model.capture_semantics });
    return .{ .object = obj };
}

fn backendMetadataValue(
    allocator: std.mem.Allocator,
    probe: ?doctor.Probe,
    id: backend_contracts.BackendId,
    executable_path: []const u8,
    compatibility_status: []const u8,
    compatibility_baseline: []const u8,
) !std.json.Value {
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
    try warnings.append(.{ .string = flamegraph_model.capture_semantics });
    if (probe == null) {
        try warnings.append(.{ .string = "backend probe and version are unknown for this artifact; run zigar_doctor with probe_backends=true to cache probe status" });
    }
    return .{ .array = warnings };
}

fn cachedProbeFor(a: *App, id: backend_contracts.BackendId) ?doctor.Probe {
    return switch (id) {
        .zig => a.backend_probe_cache.zig,
        .zls => a.backend_probe_cache.zls,
        .zlint => a.backend_probe_cache.zlint,
        .zwanzig => a.backend_probe_cache.zwanzig,
        .zflame => a.backend_probe_cache.zflame,
        .diff_folded => a.backend_probe_cache.diff_folded,
    };
}

fn zflameArgvShape() []const u8 {
    return backend_contracts.capabilityFor("zig_flamegraph").?.argv_shape;
}

pub fn failureResult(allocator: std.mem.Allocator, request: flamegraph_usecase.Request, failure: flamegraph_usecase.Failure) mcp.tools.ToolError!mcp.tools.ToolResult {
    return switch (failure) {
        .workspace_input_read_failed => |details| toolErrorFromError(allocator, .{
            .tool = request.tool_name,
            .operation = request.operation,
            .phase = "read_workspace_input",
            .code = "workspace_input_read_failed",
            .category = "filesystem",
            .resolution = "Pass an existing readable profiler input file inside the configured workspace.",
            .details = &.{
                .{ .key = "input", .value = .{ .string = details.path } },
                .{ .key = "input_abs", .value = .{ .string = details.abs_path } },
            },
        }, details.err),
        .backend_run_failed => |details| backendErrorResult(
            allocator,
            "zflame",
            "render",
            details.err,
            "confirm --zflame-path points to an executable zflame binary and that profiler input is readable",
        ),
        .command_failed => |details| commandFailureResult(allocator, request, details),
        .backend_output_malformed => |details| toolErrorResult(allocator, .{
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
        .workspace_artifact_write_failed => |details| toolErrorFromError(allocator, .{
            .tool = request.tool_name,
            .operation = request.operation,
            .phase = "workspace_write",
            .code = "workspace_artifact_write_failed",
            .category = "filesystem",
            .resolution = "Choose an output path inside the workspace that zigar can create or overwrite.",
            .details = &.{
                .{ .key = "output", .value = .{ .string = details.path } },
                .{ .key = "output_abs", .value = .{ .string = details.abs_path } },
            },
        }, details.err),
    };
}

fn commandFailureResult(allocator: std.mem.Allocator, request: flamegraph_usecase.Request, failure: flamegraph_usecase.CommandFailure) mcp.tools.ToolError!mcp.tools.ToolResult {
    const command_text = commandText(allocator, failure.argv.items) catch return error.OutOfMemory;
    defer allocator.free(command_text);
    const stdout = command_output.safeTextAlloc(allocator, failure.stdout) catch return error.OutOfMemory;
    defer allocator.free(stdout.text);
    const stderr = command_output.safeTextAlloc(allocator, failure.stderr) catch return error.OutOfMemory;
    defer allocator.free(stderr.text);
    const details = [_]tool_errors.Detail{
        .{ .key = "backend", .value = .{ .string = "zflame" } },
        .{ .key = "command", .value = .{ .string = command_text } },
        .{ .key = "cwd", .value = .{ .string = failure.cwd } },
        .{ .key = "timeout_ms", .value = .{ .integer = failure.timeout_ms } },
        .{ .key = "term", .value = .{ .string = failure.term.name() } },
        .{ .key = "exit_code", .value = if (failure.term.exitCode()) |code| .{ .integer = code } else .null },
        .{ .key = "stdout", .value = .{ .string = stdout.text } },
        .{ .key = "stderr", .value = .{ .string = stderr.text } },
        .{ .key = "stdout_invalid_utf8", .value = .{ .bool = stdout.invalid_utf8 } },
        .{ .key = "stderr_invalid_utf8", .value = .{ .bool = stderr.invalid_utf8 } },
        .{ .key = "stdout_encoding", .value = .{ .string = stdout.encoding } },
        .{ .key = "stderr_encoding", .value = .{ .string = stderr.encoding } },
        .{ .key = "stdout_byte_count", .value = .{ .integer = @intCast(stdout.byte_count) } },
        .{ .key = "stderr_byte_count", .value = .{ .integer = @intCast(stderr.byte_count) } },
        .{ .key = "stdout_truncated", .value = .{ .bool = failure.stdout_truncated } },
        .{ .key = "stderr_truncated", .value = .{ .bool = failure.stderr_truncated } },
        .{ .key = "output_limit_mode", .value = .{ .string = command.output_limit_mode } },
    };
    return toolErrorResult(allocator, .{
        .tool = request.tool_name,
        .operation = request.operation,
        .phase = "run_zflame",
        .code = "zflame_command_failed",
        .category = "backend",
        .resolution = "Inspect stdout/stderr, confirm the profiler input format is correct, and retry with a supported zflame invocation.",
        .details = &details,
    });
}

fn commandText(allocator: std.mem.Allocator, argv: []const []const u8) ![]u8 {
    if (argv.len == 0) return allocator.dupe(u8, "");
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (argv, 0..) |arg, index| {
        if (index > 0) try out.append(allocator, ' ');
        try out.appendSlice(allocator, arg);
    }
    return out.toOwnedSlice(allocator);
}

fn cloneArgvForTest(allocator: std.mem.Allocator, argv: []const []const u8) !flamegraph_usecase.OwnedArgv {
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

fn parseArgsForTest(allocator: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
}

fn requestForTest() flamegraph_usecase.Request {
    return .{
        .input = "stacks.folded",
        .input_abs = "/workspace/stacks.folded",
        .output = "profile.svg",
        .output_abs = "/workspace/profile.svg",
        .format = .recursive,
    };
}

test "flamegraph adapter parses json arguments and defaults" {
    const allocator = std.testing.allocator;
    const args = try parseArgsForTest(allocator, "{\"format\":\"recursive\",\"input\":\"stacks.folded\",\"output\":\"profile.svg\",\"title\":\"fixture\"}");
    defer args.deinit();

    const parsed = switch (try parseRequestArgs(allocator, args.value)) {
        .ok => |value| value,
        .err => |result| {
            defer json_result.deinitToolResult(allocator, result);
            return error.ExpectedParsedRequest;
        },
    };

    try std.testing.expectEqual(flamegraph_model.ZflameFormat.recursive, parsed.format);
    try std.testing.expectEqualStrings("stacks.folded", parsed.input);
    try std.testing.expectEqualStrings("profile.svg", parsed.output);
    try std.testing.expectEqualStrings("fixture", parsed.options.title.?);
    try std.testing.expect(parsed.options.subtitle == null);
    try std.testing.expect(parsed.options.colors == null);
    try std.testing.expectEqual(@as(?i64, null), parsed.options.width);
    try std.testing.expectEqual(@as(?i64, null), parsed.options.min_width);
    try std.testing.expect(!parsed.options.hash);
}

test "flamegraph adapter maps argument parse errors to MCP JSON shape" {
    const allocator = std.testing.allocator;
    const args = try parseArgsForTest(allocator, "{\"format\":\"recursive\",\"input\":\"stacks.folded\",\"output\":\"profile.svg\",\"width\":0}");
    defer args.deinit();

    const result = switch (try parseRequestArgs(allocator, args.value)) {
        .ok => return error.ExpectedArgumentError,
        .err => |value| value,
    };
    defer json_result.deinitToolResult(allocator, result);

    try std.testing.expect(result.is_error);
    const obj = result.structuredContent.?.object;
    try std.testing.expectEqualStrings("argument_error", obj.get("kind").?.string);
    try std.testing.expectEqualStrings("invalid_argument", obj.get("code").?.string);
    try std.testing.expectEqualStrings("width", obj.get("field").?.string);
    try std.testing.expectEqualStrings("positive integer", obj.get("expected").?.string);
}

test "flamegraph adapter renders public result fields from use case artifact" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var argv = try cloneArgvForTest(allocator, &.{ "/bin/zflame", "recursive", "/workspace/stacks.folded" });
    defer argv.deinit(allocator);
    const artifact = flamegraph_usecase.Artifact{
        .backend_executable_path = "/bin/zflame",
        .bytes = 77,
        .sha256 = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
        .argv = argv,
    };
    const value = try flamegraphResultValue(arena.allocator(), .{
        .zflame_probe = .{ .ok = true, .status = "ok", .resolution = "cached zflame probe" },
    }, requestForTest(), artifact);
    const obj = value.object;

    try std.testing.expectEqualStrings("zig_flamegraph", obj.get("kind").?.string);
    try std.testing.expectEqualStrings("zflame", obj.get("backend").?.string);
    try std.testing.expectEqualStrings("recursive", obj.get("format").?.string);
    try std.testing.expectEqualStrings("recursive", obj.get("input_format").?.string);
    try std.testing.expectEqual(@as(i64, 77), obj.get("bytes").?.integer);
    try std.testing.expectEqualStrings("/bin/zflame", obj.get("backend_executable_path").?.string);
    try std.testing.expectEqualStrings("rendered_ok", obj.get("compatibility_status").?.string);
    try std.testing.expectEqualStrings("zflame", obj.get("backend_metadata").?.object.get("name").?.string);
    try std.testing.expectEqualStrings("probe_ok", obj.get("backend_metadata").?.object.get("probe_status").?.string);
    try std.testing.expectEqualStrings("recursive", obj.get("argv").?.array.items[1].string);
    try std.testing.expect(std.mem.indexOf(u8, obj.get("argv_shape").?.string, "zflame") != null);
    try std.testing.expectEqualStrings(flamegraph_model.capture_semantics, obj.get("capture_semantics").?.string);
    try std.testing.expect(obj.get("warnings").?.array.items.len >= 1);
}

test "flamegraph adapter maps malformed backend output failure to MCP error" {
    const allocator = std.testing.allocator;
    const result = try failureResult(allocator, requestForTest(), .{
        .backend_output_malformed = .{
            .error_info = app_errors.toolFailure(
                operation_name,
                "validate_svg",
                "backend_output_malformed",
                "zflame stdout was not SVG",
                "The zflame command completed but stdout did not look like an SVG document.",
            ),
            .backend = "zflame",
            .format = .recursive,
            .input = "stacks.folded",
        },
    });
    defer json_result.deinitToolResult(allocator, result);

    try std.testing.expect(result.is_error);
    const obj = result.structuredContent.?.object;
    try std.testing.expectEqualStrings("tool_error", obj.get("kind").?.string);
    try std.testing.expectEqualStrings("backend_output_malformed", obj.get("code").?.string);
    try std.testing.expectEqualStrings("validate_svg", obj.get("phase").?.string);
    try std.testing.expectEqualStrings("zflame", obj.get("backend").?.string);
    try std.testing.expectEqualStrings("recursive", obj.get("format").?.string);
}

test "flamegraph adapter renders non-exited command term with null exit code" {
    const allocator = std.testing.allocator;
    var argv = try cloneArgvForTest(allocator, &.{ "zflame", "recursive", "/workspace/stacks.folded" });
    var argv_transferred = false;
    errdefer if (!argv_transferred) argv.deinit(allocator);
    const stdout = try allocator.dupe(u8, "partial");
    var stdout_transferred = false;
    errdefer if (!stdout_transferred) allocator.free(stdout);
    const stderr = try allocator.dupe(u8, "terminated");
    var stderr_transferred = false;
    errdefer if (!stderr_transferred) allocator.free(stderr);

    var failure = flamegraph_usecase.CommandFailure{
        .error_info = app_errors.toolFailure(
            "render_flamegraph",
            "run_zflame",
            "zflame_command_failed",
            "Signal",
            "Inspect stdout/stderr.",
        ),
        .argv = argv,
        .cwd = "/workspace",
        .timeout_ms = 5000,
        .exit_code = -1,
        .term = .signal,
        .stdout = stdout,
        .stderr = stderr,
        .stdout_truncated = false,
        .stderr_truncated = false,
    };
    argv_transferred = true;
    stdout_transferred = true;
    stderr_transferred = true;
    defer failure.deinit(allocator);

    const result = try commandFailureResult(allocator, .{
        .input = "stacks.folded",
        .input_abs = "/workspace/stacks.folded",
        .output = "profile.svg",
        .output_abs = "/workspace/profile.svg",
        .format = .recursive,
    }, failure);
    defer json_result.deinitToolResult(allocator, result);

    const obj = result.structuredContent.?.object;
    try std.testing.expect(result.is_error);
    try std.testing.expectEqualStrings("zflame_command_failed", obj.get("code").?.string);
    try std.testing.expectEqualStrings("signal", obj.get("term").?.string);
    switch (obj.get("exit_code").?) {
        .null => {},
        else => return error.ExpectedNullExitCode,
    }
    try std.testing.expectEqualStrings("terminated", obj.get("stderr").?.string);
}
