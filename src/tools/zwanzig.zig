const std = @import("std");
const mcp = @import("mcp");
const zigar = @import("zigar");

const backend_contracts = zigar.backend_contracts;
const command = zigar.command;
const common = @import("common.zig");

const App = common.App;
const structured = common.structured;
const argString = common.argString;
const missingArgumentResult = common.missingArgumentResult;
const invalidArgumentResult = common.invalidArgumentResult;
const toolErrorResult = common.toolErrorResult;
const toolErrorFromError = common.toolErrorFromError;
const workspacePathErrorResult = common.workspacePathErrorResult;
const runAndFormat = common.runAndFormat;
const backendErrorResult = common.backendErrorResult;
const commandResultErrorResult = common.commandResultErrorResult;
const splitToolArgs = common.splitToolArgs;
const splitToolArgsErrorResult = common.splitToolArgsErrorResult;
const freeArgList = common.freeArgList;

pub fn zigLint(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return runZwanzig(a, allocator, args, .json, "zig_lint");
}

pub fn zigLintSarif(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return runZwanzig(a, allocator, args, .sarif, "zig_lint_sarif");
}

const ZwanzigLintCommand = struct {
    executable: []const u8,
    format: backend_contracts.ZwanzigLintFormat,
    path: []const u8,
    config: ?[]const u8 = null,
    rules_do: ?[]const u8 = null,
    rules_skip: ?[]const u8 = null,
    extra: []const []const u8 = &.{},
};

const ZwanzigGraphCommand = struct {
    executable: []const u8,
    mode: backend_contracts.ZwanzigGraphMode,
    source_path: []const u8,
    output_dir: []const u8,
    extra: []const []const u8 = &.{},
};

pub fn buildZwanzigLintArgv(allocator: std.mem.Allocator, spec: ZwanzigLintCommand) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer list.deinit(allocator);
    try list.appendSlice(allocator, &.{ spec.executable, "--format", spec.format.name() });
    if (spec.config) |config| try list.appendSlice(allocator, &.{ "--config", config });
    if (spec.rules_do) |rules| try list.appendSlice(allocator, &.{ "--do", rules });
    if (spec.rules_skip) |rules| try list.appendSlice(allocator, &.{ "--skip", rules });
    try list.append(allocator, spec.path);
    try list.appendSlice(allocator, spec.extra);
    return list.toOwnedSlice(allocator);
}

pub fn buildZwanzigGraphArgv(allocator: std.mem.Allocator, spec: ZwanzigGraphCommand) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer list.deinit(allocator);
    try list.appendSlice(allocator, &.{ spec.executable, spec.mode.flag(), spec.output_dir, spec.source_path });
    try list.appendSlice(allocator, spec.extra);
    return list.toOwnedSlice(allocator);
}

pub fn runZwanzig(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value, format: backend_contracts.ZwanzigLintFormat, tool_name: []const u8) mcp.tools.ToolError!mcp.tools.ToolResult {
    var resolved_config: ?[]const u8 = null;
    defer if (resolved_config) |path| allocator.free(path);
    if (argString(args, "config")) |path| {
        resolved_config = a.workspace.resolve(path) catch |err| return workspacePathErrorResult(a, allocator, tool_name, path, err);
    }
    const path = argString(args, "path") orelse ".";
    const resolved_path = a.workspace.resolve(path) catch |err| return workspacePathErrorResult(a, allocator, tool_name, path, err);
    defer allocator.free(resolved_path);
    const raw_extra_args = argString(args, "args") orelse "";
    const extra = splitToolArgs(allocator, raw_extra_args) catch |err| return splitToolArgsErrorResult(allocator, tool_name, "args", raw_extra_args, err);
    defer freeArgList(allocator, extra);
    const argv = buildZwanzigLintArgv(allocator, .{
        .executable = a.config.zwanzig_path,
        .format = format,
        .path = resolved_path,
        .config = resolved_config,
        .rules_do = argString(args, "rules_do"),
        .rules_skip = argString(args, "rules_skip"),
        .extra = extra,
    }) catch return error.OutOfMemory;
    defer allocator.free(argv);
    return runAndFormat(a, allocator, argv, "zwanzig lint");
}

pub fn zigLintRules(a: *App, allocator: std.mem.Allocator, _: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return runAndFormat(a, allocator, &.{ a.config.zwanzig_path, "--help" }, "zwanzig rules/help");
}

pub fn zigAnalysisGraphs(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const mode_raw = argString(args, "mode") orelse return missingArgumentResult(allocator, "zig_analysis_graphs", "mode", backend_contracts.supportedZwanzigGraphModesText());
    const mode = backend_contracts.parseZwanzigGraphMode(mode_raw) orelse return invalidArgumentResult(
        allocator,
        "zig_analysis_graphs",
        "mode",
        backend_contracts.supportedZwanzigGraphModesText(),
        mode_raw,
        "Choose one of the graph modes published in tools/list; raw zwanzig graph flags are not accepted as public zigar API.",
    );
    const path = argString(args, "path") orelse return missingArgumentResult(allocator, "zig_analysis_graphs", "path", "workspace-relative Zig source path");
    const output = argString(args, "output") orelse return missingArgumentResult(allocator, "zig_analysis_graphs", "output", "workspace-relative graph output directory");
    const resolved_path = a.workspace.resolve(path) catch |err| return workspacePathErrorResult(a, allocator, "zig_analysis_graphs", path, err);
    defer allocator.free(resolved_path);
    const resolved_output = a.workspace.resolveOutput(output) catch |err| return workspacePathErrorResult(a, allocator, "zig_analysis_graphs", output, err);
    defer allocator.free(resolved_output);
    std.Io.Dir.cwd().createDirPath(a.io, resolved_output) catch |err| return toolErrorFromError(allocator, .{
        .tool = "zig_analysis_graphs",
        .operation = "prepare_graph_output",
        .phase = "create_output_directory",
        .code = "workspace_artifact_write_failed",
        .category = "filesystem",
        .resolution = "Choose a workspace-local output directory that zigar can create or reuse.",
        .details = &.{.{ .key = "output", .value = .{ .string = output } }},
    }, err);
    const raw_extra_args = argString(args, "args") orelse "";
    const extra = splitToolArgs(allocator, raw_extra_args) catch |err| return splitToolArgsErrorResult(allocator, "zig_analysis_graphs", "args", raw_extra_args, err);
    defer freeArgList(allocator, extra);
    const argv = buildZwanzigGraphArgv(allocator, .{
        .executable = a.config.zwanzig_path,
        .mode = mode,
        .source_path = resolved_path,
        .output_dir = resolved_output,
        .extra = extra,
    }) catch return error.OutOfMemory;
    defer allocator.free(argv);
    const result = command.run(allocator, a.io, a.workspace.root, argv, a.config.timeout_ms) catch |err| {
        return backendErrorResult(allocator, "zwanzig", "analysis_graphs", err, "confirm --zwanzig-path points to an executable zwanzig binary and the source path is readable");
    };
    defer result.deinit(allocator);
    if (!result.succeeded()) {
        return commandResultErrorResult(allocator, .{
            .tool = "zig_analysis_graphs",
            .operation = "generate_analysis_graphs",
            .phase = "run_zwanzig_graph",
            .code = "zwanzig_graph_command_failed",
            .backend = "zwanzig",
            .argv = argv,
            .cwd = a.workspace.root,
            .timeout_ms = a.config.timeout_ms,
            .result = result,
            .resolution = "Inspect stdout/stderr, confirm the selected graph mode is supported by the configured zwanzig binary, and retry.",
        });
    }
    const wrote_dot = graphDirectoryHasDot(allocator, a.io, resolved_output) catch |err| return toolErrorFromError(allocator, .{
        .tool = "zig_analysis_graphs",
        .operation = "verify_graph_output",
        .phase = "inspect_output_directory",
        .code = "backend_output_malformed",
        .category = "backend_output",
        .resolution = "Confirm zwanzig wrote DOT graph files to the requested workspace output directory.",
        .details = &.{.{ .key = "output", .value = .{ .string = output } }},
    }, err);
    if (!wrote_dot) return toolErrorResult(allocator, .{
        .tool = "zig_analysis_graphs",
        .operation = "verify_graph_output",
        .phase = "inspect_output_directory",
        .code = "backend_output_malformed",
        .category = "backend_output",
        .resolution = "The zwanzig command completed but no .dot graph files were found in the requested output directory.",
        .details = &.{.{ .key = "output", .value = .{ .string = output } }},
    });
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    obj.put(allocator, "kind", .{ .string = "zig_analysis_graphs" }) catch return error.OutOfMemory;
    obj.put(allocator, "backend", .{ .string = "zwanzig" }) catch return error.OutOfMemory;
    obj.put(allocator, "mode", .{ .string = mode.name() }) catch return error.OutOfMemory;
    obj.put(allocator, "mode_flag", .{ .string = mode.flag() }) catch return error.OutOfMemory;
    obj.put(allocator, "path", .{ .string = path }) catch return error.OutOfMemory;
    obj.put(allocator, "output", .{ .string = output }) catch return error.OutOfMemory;
    obj.put(allocator, "output_abs", .{ .string = resolved_output }) catch return error.OutOfMemory;
    return structured(allocator, .{ .object = obj });
}

fn graphDirectoryHasDot(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !bool {
    var dir = try std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(allocator);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.path, ".dot")) return true;
    }
    return false;
}

test "zwanzig lint argv uses supported format, filters, config, and extras" {
    const argv = try buildZwanzigLintArgv(std.testing.allocator, .{
        .executable = "zwanzig",
        .format = .sarif,
        .path = "/workspace/src",
        .config = "/workspace/zwanzig.json",
        .rules_do = "empty-catch-engine",
        .rules_skip = "style",
        .extra = &.{"--verbose"},
    });
    defer std.testing.allocator.free(argv);
    const expected = [_][]const u8{ "zwanzig", "--format", "sarif", "--config", "/workspace/zwanzig.json", "--do", "empty-catch-engine", "--skip", "style", "/workspace/src", "--verbose" };
    try std.testing.expectEqual(expected.len, argv.len);
    for (expected, argv) |expected_arg, actual_arg| try std.testing.expectEqualStrings(expected_arg, actual_arg);
}

test "zwanzig graph argv uses typed upstream dump flags" {
    const modes = [_]backend_contracts.ZwanzigGraphMode{ .cfg, .exploded_graph, .annotated_cfg, .path_trace };
    const flags = [_][]const u8{ "--dump-cfg", "--dump-exploded-graph", "--dump-annotated-cfg", "--dump-path-trace" };
    for (modes, flags) |mode, flag| {
        const argv = try buildZwanzigGraphArgv(std.testing.allocator, .{
            .executable = "zwanzig",
            .mode = mode,
            .source_path = "/workspace/src/main.zig",
            .output_dir = "/workspace/.zigar-cache/graphs",
        });
        defer std.testing.allocator.free(argv);
        try std.testing.expectEqualStrings("zwanzig", argv[0]);
        try std.testing.expectEqualStrings(flag, argv[1]);
        try std.testing.expectEqualStrings("/workspace/.zigar-cache/graphs", argv[2]);
        try std.testing.expectEqualStrings("/workspace/src/main.zig", argv[3]);
    }
}
