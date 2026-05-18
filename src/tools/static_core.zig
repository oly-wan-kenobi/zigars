const std = @import("std");
const mcp = @import("mcp");
const zigar = @import("zigar");

const analysis = zigar.analysis;
const command = zigar.command;
const docs = zigar.docs;
const common = @import("common.zig");
const docs_tools = @import("docs.zig");
const static_build = @import("static_build.zig");
const static_dependencies = @import("static_dependencies.zig");

const App = common.App;
const structured = common.structured;
const argString = common.argString;
const argInt = common.argInt;
const missingArgumentResult = common.missingArgumentResult;
const toolErrorResult = common.toolErrorResult;
const toolErrorFromError = common.toolErrorFromError;
const workspacePathErrorResult = common.workspacePathErrorResult;
const toolTimeout = common.toolTimeout;
const backendErrorResult = common.backendErrorResult;
const structuredText = common.structuredText;
const ownedString = common.ownedString;
const statusLinePath = common.statusLinePath;
const appendWorkspaceFormatCheckCommand = common.appendWorkspaceFormatCheckCommand;
const appendUniqueCommand = common.appendUniqueCommand;
const readSourceArg = docs_tools.readSourceArg;

pub const buildWorkspaceValue = static_build.buildWorkspaceValue;
pub const buildZigSummaryValue = static_build.buildZigSummaryValue;
pub const zonSummaryValue = static_build.zonSummaryValue;
pub const buildEntityValue = static_build.buildEntityValue;
pub const buildStepValue = static_build.buildStepValue;
pub const buildImportValue = static_build.buildImportValue;
pub const sourceFileOwnerValue = static_build.sourceFileOwnerValue;
pub const commandSuggestionValue = static_build.commandSuggestionValue;
pub const ownerVarName = static_build.ownerVarName;
pub const buildNameFromCall = static_build.buildNameFromCall;
pub const buildNameFromLine = static_build.buildNameFromLine;
pub const buildPathFromLine = static_build.buildPathFromLine;
pub const dependencyNameFromLine = static_build.dependencyNameFromLine;
pub const quotedString = static_build.quotedString;
pub const fileOwnerValue = static_build.fileOwnerValue;
pub const importResolveValue = static_build.importResolveValue;
pub const buildZigObject = static_build.buildZigObject;
pub const findModuleOrDependency = static_build.findModuleOrDependency;
pub const relativeImportCandidate = static_build.relativeImportCandidate;
pub const DependencyRecord = static_dependencies.DependencyRecord;
pub const cachePathStatusValue = static_dependencies.cachePathStatusValue;
pub const countTopLevelEntries = static_dependencies.countTopLevelEntries;
pub const dependencyInspectionValue = static_dependencies.dependencyInspectionValue;
pub const dependencyBlockNameFromLine = static_dependencies.dependencyBlockNameFromLine;
pub const appendDependencyRecord = static_dependencies.appendDependencyRecord;

fn readSourceArgError(a: *App, allocator: std.mem.Allocator, tool_name: []const u8, args: ?std.json.Value, err: anyerror) mcp.tools.ToolError!mcp.tools.ToolResult {
    return switch (err) {
        error.InvalidArguments, error.MissingFile => missingArgumentResult(allocator, tool_name, "file", "workspace-relative Zig source path"),
        error.PathOutsideWorkspace, error.EmptyPath => if (argString(args, "file")) |file|
            workspacePathErrorResult(a, allocator, tool_name, file, err)
        else
            missingArgumentResult(allocator, tool_name, "file", "workspace-relative Zig source path"),
        error.OutOfMemory => error.OutOfMemory,
        else => workspaceFileError(allocator, tool_name, argString(args, "file") orelse "<missing>", err, "Pass a readable workspace file or provide the content through a tool that explicitly supports inline content."),
    };
}

fn analysisToolError(allocator: std.mem.Allocator, tool_name: []const u8, operation: []const u8, err: anyerror) mcp.tools.ToolError!mcp.tools.ToolResult {
    return toolErrorFromError(allocator, .{
        .tool = tool_name,
        .operation = operation,
        .phase = "static_analysis",
        .code = "analysis_failed",
        .category = "analysis",
        .resolution = "Retry with a smaller limit or inspect the workspace files for syntax that the heuristic analyzer cannot scan.",
    }, err);
}

fn workspaceFileError(allocator: std.mem.Allocator, tool_name: []const u8, file: []const u8, err: anyerror, resolution: []const u8) mcp.tools.ToolError!mcp.tools.ToolResult {
    return toolErrorFromError(allocator, .{
        .tool = tool_name,
        .operation = "read_workspace_file",
        .phase = "workspace_read",
        .code = "read_failed",
        .category = "filesystem",
        .resolution = resolution,
        .details = &.{.{ .key = "file", .value = .{ .string = file } }},
    }, err);
}

pub fn zigImportGraph(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const output = analysis.importGraph(allocator, a.io, a.workspace.root, @intCast(@max(1, argInt(args, "limit", 200)))) catch |err| return analysisToolError(allocator, "zig_import_graph", "scan_import_graph", err);
    defer allocator.free(output);
    return structuredText(allocator, "zig_import_graph", output);
}

pub fn zigImportGraphJson(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const limit: usize = @intCast(@max(1, argInt(args, "limit", 200)));
    const value = analysis.importGraphJson(allocator, a.io, a.workspace.root, limit) catch |err| return analysisToolError(allocator, "zig_import_graph_json", "scan_import_graph_json", err);
    return structured(allocator, value);
}

pub fn zigDeclSummary(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const source = readSourceArg(a, allocator, args) catch |err| return readSourceArgError(a, allocator, "zig_decl_summary", args, err);
    defer allocator.free(source.bytes);
    const output = analysis.declSummary(allocator, source.name, source.bytes) catch return error.OutOfMemory;
    defer allocator.free(output);
    return structuredText(allocator, "zig_decl_summary", output);
}

pub fn zigDeclSummaryJson(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const source = readSourceArg(a, allocator, args) catch |err| return readSourceArgError(a, allocator, "zig_decl_summary_json", args, err);
    defer allocator.free(source.bytes);
    const value = analysis.declSummaryJson(allocator, source.name, source.bytes) catch return error.OutOfMemory;
    return structured(allocator, value);
}

pub fn asciiLowerAllocLocal(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    const out = try allocator.alloc(u8, input.len);
    for (input, 0..) |c, i| out[i] = std.ascii.toLower(c);
    return out;
}

pub fn lineNumberLocal(text_value: []const u8, index: usize) usize {
    var line: usize = 1;
    for (text_value[0..@min(index, text_value.len)]) |c| {
        if (c == '\n') line += 1;
    }
    return line;
}

pub fn lineAtLocal(text_value: []const u8, index: usize) []const u8 {
    var start = index;
    while (start > 0 and text_value[start - 1] != '\n') start -= 1;
    var end = index;
    while (end < text_value.len and text_value[end] != '\n') end += 1;
    return text_value[start..end];
}

pub fn zigAllocations(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const source = readSourceArg(a, allocator, args) catch |err| return readSourceArgError(a, allocator, "zig_allocations", args, err);
    defer allocator.free(source.bytes);
    const output = analysis.allocationSummary(allocator, source.name, source.bytes) catch return error.OutOfMemory;
    defer allocator.free(output);
    return structuredText(allocator, "zig_allocations", output);
}

pub fn zigErrorSets(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const source = readSourceArg(a, allocator, args) catch |err| return readSourceArgError(a, allocator, "zig_error_sets", args, err);
    defer allocator.free(source.bytes);
    const output = analysis.errorSetSummary(allocator, source.name, source.bytes) catch return error.OutOfMemory;
    defer allocator.free(output);
    return structuredText(allocator, "zig_error_sets", output);
}

pub fn zigPublicApi(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const source = readSourceArg(a, allocator, args) catch |err| return readSourceArgError(a, allocator, "zig_public_api", args, err);
    defer allocator.free(source.bytes);
    const output = analysis.publicApiSummary(allocator, source.name, source.bytes) catch return error.OutOfMemory;
    defer allocator.free(output);
    return structuredText(allocator, "zig_public_api", output);
}

pub fn zigDeadDeclCandidates(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const source = readSourceArg(a, allocator, args) catch |err| return readSourceArgError(a, allocator, "zig_dead_decl_candidates", args, err);
    defer allocator.free(source.bytes);
    const output = analysis.deadDeclCandidates(allocator, source.name, source.bytes) catch return error.OutOfMemory;
    defer allocator.free(output);
    return structuredText(allocator, "zig_dead_decl_candidates", output);
}

pub fn zigBuildGraph(a: *App, allocator: std.mem.Allocator, _: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return structured(allocator, buildWorkspaceValue(allocator, a) catch return error.OutOfMemory);
}

pub fn zigBuildTargets(a: *App, allocator: std.mem.Allocator, _: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const graph = buildWorkspaceValue(allocator, a) catch return error.OutOfMemory;
    const graph_obj = switch (graph) {
        .object => |o| o,
        else => return toolErrorResult(allocator, .{
            .tool = "zig_build_targets",
            .operation = "inspect_build_graph",
            .phase = "decode_graph",
            .code = "unexpected_build_graph_shape",
            .category = "internal_contract",
            .resolution = "Run zigar_workspace_info and zig_build_graph to inspect the workspace graph, then report this mismatch with the captured response.",
        }),
    };
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    obj.put(allocator, "workspace", .{ .string = a.workspace.root }) catch return error.OutOfMemory;
    if (graph_obj.get("build_zig")) |build_zig| {
        const build_obj = switch (build_zig) {
            .object => |o| o,
            else => return toolErrorResult(allocator, .{
                .tool = "zig_build_targets",
                .operation = "inspect_build_graph",
                .phase = "decode_build_zig",
                .code = "unexpected_build_zig_shape",
                .category = "internal_contract",
                .resolution = "Run zig_build_graph and report the malformed build_zig section with the zigar version.",
            }),
        };
        obj.put(allocator, "modules", build_obj.get("modules") orelse .null) catch return error.OutOfMemory;
        obj.put(allocator, "artifacts", build_obj.get("artifacts") orelse .null) catch return error.OutOfMemory;
        obj.put(allocator, "named_artifacts", build_obj.get("named_artifacts") orelse .null) catch return error.OutOfMemory;
        obj.put(allocator, "tests", build_obj.get("tests") orelse .null) catch return error.OutOfMemory;
        obj.put(allocator, "steps", build_obj.get("steps") orelse .null) catch return error.OutOfMemory;
        obj.put(allocator, "commands", build_obj.get("commands") orelse .null) catch return error.OutOfMemory;
    }
    return structured(allocator, .{ .object = obj });
}

pub fn zigBuildOptions(a: *App, allocator: std.mem.Allocator, _: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const bytes = a.workspace.readFileAlloc(a.io, "build.zig", 1024 * 1024) catch |err| return workspaceFileError(allocator, "zig_build_options", "build.zig", err, "Create a build.zig file in the workspace root or call zig_build_graph for a nullable workspace summary.");
    defer allocator.free(bytes);
    var options = std.json.Array.init(allocator);
    var commands = std.json.Array.init(allocator);
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    var line_no: usize = 1;
    var has_target = false;
    var has_optimize = false;
    while (lines.next()) |line| : (line_no += 1) {
        const trimmed = std.mem.trim(u8, line, " \t");
        if (std.mem.indexOf(u8, trimmed, "standardTargetOptions") != null) {
            has_target = true;
            try options.append(try buildOptionValue(allocator, "target", "std.Build.ResolvedTarget", "standardTargetOptions", line_no, trimmed));
        }
        if (std.mem.indexOf(u8, trimmed, "standardOptimizeOption") != null) {
            has_optimize = true;
            try options.append(try buildOptionValue(allocator, "optimize", "std.builtin.OptimizeMode", "standardOptimizeOption", line_no, trimmed));
        }
        if (std.mem.indexOf(u8, trimmed, "b.option(")) |_| {
            const name = optionNameFromLine(trimmed) orelse continue;
            const type_name = optionTypeFromLine(trimmed) orelse "unknown";
            try options.append(try buildOptionValue(allocator, name, type_name, "b.option", line_no, trimmed));
        }
    }
    try commands.append(try ownedString(allocator, "zig build --help"));
    if (has_target) try commands.append(try ownedString(allocator, "zig build -Dtarget=<triple>"));
    if (has_optimize) try commands.append(try ownedString(allocator, "zig build -Doptimize=Debug|ReleaseSafe|ReleaseFast|ReleaseSmall"));
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zig_build_options" });
    try obj.put(allocator, "analysis_kind", .{ .string = "heuristic_build_option_scan" });
    try obj.put(allocator, "confidence", .{ .string = "medium" });
    try obj.put(allocator, "options", .{ .array = options });
    try obj.put(allocator, "commands", .{ .array = commands });
    return structured(allocator, .{ .object = obj });
}

pub fn buildOptionValue(allocator: std.mem.Allocator, name: []const u8, type_name: []const u8, source: []const u8, line_no: usize, text_value: []const u8) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "name", try ownedString(allocator, name));
    try obj.put(allocator, "flag", .{ .string = try std.fmt.allocPrint(allocator, "-D{s}=<value>", .{name}) });
    try obj.put(allocator, "type", try ownedString(allocator, type_name));
    try obj.put(allocator, "source", try ownedString(allocator, source));
    try obj.put(allocator, "line", .{ .integer = @intCast(line_no) });
    try obj.put(allocator, "text", try ownedString(allocator, text_value));
    return .{ .object = obj };
}

pub fn optionNameFromLine(line: []const u8) ?[]const u8 {
    const pos = std.mem.indexOf(u8, line, "b.option(") orelse return null;
    const first_quote = std.mem.indexOfScalarPos(u8, line, pos, '"') orelse return null;
    const second_quote = std.mem.indexOfScalarPos(u8, line, first_quote + 1, '"') orelse return null;
    return line[first_quote + 1 .. second_quote];
}

pub fn optionTypeFromLine(line: []const u8) ?[]const u8 {
    const start = (std.mem.indexOf(u8, line, "b.option(") orelse return null) + "b.option(".len;
    const comma = std.mem.indexOfScalarPos(u8, line, start, ',') orelse return null;
    return std.mem.trim(u8, line[start..comma], " \t");
}

pub fn zigFileOwner(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const file = argString(args, "file") orelse return missingArgumentResult(allocator, "zig_file_owner", "file", "workspace-relative Zig file path");
    const resolved = a.workspace.resolve(file) catch |err| return workspacePathErrorResult(a, allocator, "zig_file_owner", file, err);
    defer allocator.free(resolved);
    const rel = a.workspace.relative(resolved);
    const graph = buildWorkspaceValue(allocator, a) catch return error.OutOfMemory;
    const owner = fileOwnerValue(allocator, graph, rel) catch return error.OutOfMemory;
    return structured(allocator, owner);
}

pub fn zigImportResolve(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const import_name = argString(args, "import") orelse return missingArgumentResult(allocator, "zig_import_resolve", "import", "Zig import name");
    const from = argString(args, "from");
    const graph = buildWorkspaceValue(allocator, a) catch return error.OutOfMemory;
    const resolved = importResolveValue(allocator, a, graph, import_name, from) catch return error.OutOfMemory;
    return structured(allocator, resolved);
}

pub fn appendLineRecord(allocator: std.mem.Allocator, array: *std.json.Array, line_no: usize, text_value: []const u8) !void {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "line", .{ .integer = @intCast(line_no) });
    try obj.put(allocator, "text", try ownedString(allocator, text_value));
    try array.append(.{ .object = obj });
}

pub fn zigTestDiscover(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const limit: usize = @intCast(@max(1, argInt(args, "limit", 500)));
    const value = analysis.testDiscoverJson(allocator, a.io, a.workspace.root, limit) catch |err| return analysisToolError(allocator, "zig_test_discover", "scan_test_declarations", err);
    return structured(allocator, value);
}

pub fn zigChangedFilesPlan(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const result = command.run(allocator, a.io, a.workspace.root, &.{ "git", "status", "--porcelain" }, toolTimeout(a, args)) catch |err| {
        return backendErrorResult(allocator, "git", "status", err, "run this tool inside a git checkout or inspect changed files manually");
    };
    defer result.deinit(allocator);

    var files = std.json.Array.init(allocator);
    var commands = std.json.Array.init(allocator);
    var saw_zig = false;
    var saw_build = false;
    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    while (lines.next()) |line| {
        if (line.len < 4) continue;
        const path = statusLinePath(line);
        if (path.len == 0 or analysis.skipWorkspacePath(path)) continue;
        var item = std.json.ObjectMap.empty;
        try item.put(allocator, "status", try ownedString(allocator, std.mem.trim(u8, line[0..2], " ")));
        try item.put(allocator, "path", try ownedString(allocator, path));
        try files.append(.{ .object = item });
        if (std.mem.endsWith(u8, path, ".zig") and workspacePathExists(allocator, a, path)) {
            saw_zig = true;
            const fmt_cmd = try std.fmt.allocPrint(allocator, "zig fmt --check {s}", .{path});
            defer allocator.free(fmt_cmd);
            try appendUniqueCommand(allocator, &commands, fmt_cmd);
            const check_cmd = try std.fmt.allocPrint(allocator, "zig ast-check {s}", .{path});
            defer allocator.free(check_cmd);
            try appendUniqueCommand(allocator, &commands, check_cmd);
            const test_cmd = try std.fmt.allocPrint(allocator, "zig test {s}", .{path});
            defer allocator.free(test_cmd);
            try appendUniqueCommand(allocator, &commands, test_cmd);
        }
        if ((std.mem.eql(u8, path, "build.zig") or std.mem.eql(u8, path, "build.zig.zon")) and workspacePathExists(allocator, a, path)) saw_build = true;
    }
    if (saw_build) {
        try appendUniqueCommand(allocator, &commands, "zig build --help");
        try appendUniqueCommand(allocator, &commands, "zig build test");
    } else if (saw_zig) {
        try appendUniqueCommand(allocator, &commands, "zig build test");
    }
    try appendWorkspaceFormatCheckCommand(allocator, a, &commands);

    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zig_changed_files_plan" });
    try obj.put(allocator, "ok", .{ .bool = result.succeeded() });
    try obj.put(allocator, "files", .{ .array = files });
    try obj.put(allocator, "commands", .{ .array = commands });
    try obj.put(allocator, "raw_status", .{ .string = result.stdout });
    return structured(allocator, .{ .object = obj });
}

pub fn workspacePathExists(allocator: std.mem.Allocator, a: *App, path: []const u8) bool {
    const resolved = a.workspace.resolve(path) catch return false;
    defer allocator.free(resolved);
    if (countTopLevelEntries(allocator, a.io, resolved)) |_| {
        return true;
    } else |_| {}
    if (std.Io.Dir.cwd().readFileAlloc(a.io, resolved, allocator, .limited(1)) catch null) |bytes| {
        allocator.free(bytes);
        return true;
    }
    return false;
}

pub fn zigDependencyInspect(a: *App, allocator: std.mem.Allocator, _: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const bytes = a.workspace.readFileAlloc(a.io, "build.zig.zon", 1024 * 1024) catch |err| return workspaceFileError(allocator, "zig_dependency_inspect", "build.zig.zon", err, "Create build.zig.zon or use zig_build_graph for a nullable workspace summary.");
    defer allocator.free(bytes);
    const value = dependencyInspectionValue(allocator, a, bytes) catch return error.OutOfMemory;
    return structured(allocator, value);
}

pub fn zigTargetMatrixPlan(_: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const targets_text = argString(args, "targets") orelse "native x86_64-linux-gnu x86_64-macos-none aarch64-macos-none x86_64-windows-gnu wasm32-freestanding";
    const steps_text = argString(args, "steps") orelse "build test";
    var targets = std.mem.tokenizeAny(u8, targets_text, ", \t\r\n");
    var matrix = std.json.Array.init(allocator);
    while (targets.next()) |target| {
        var commands = std.json.Array.init(allocator);
        var steps = std.mem.tokenizeAny(u8, steps_text, ", \t\r\n");
        while (steps.next()) |step| {
            if (std.mem.eql(u8, target, "native")) {
                try commands.append(.{ .string = try std.fmt.allocPrint(allocator, "zig build {s}", .{step}) });
            } else {
                try commands.append(.{ .string = try std.fmt.allocPrint(allocator, "zig build {s} -Dtarget={s}", .{ step, target }) });
            }
        }
        var item = std.json.ObjectMap.empty;
        try item.put(allocator, "target", try ownedString(allocator, target));
        try item.put(allocator, "commands", .{ .array = commands });
        try item.put(allocator, "note", .{ .string = targetMatrixNote(target) });
        try matrix.append(.{ .object = item });
    }
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zig_target_matrix_plan" });
    try obj.put(allocator, "matrix", .{ .array = matrix });
    try obj.put(allocator, "resolution", .{ .string = "Use zig_matrix_check when you have concrete Zig binaries to execute; this tool only plans commands." });
    return structured(allocator, .{ .object = obj });
}

pub fn targetMatrixNote(target: []const u8) []const u8 {
    if (std.mem.eql(u8, target, "native")) return "uses the active host target";
    if (std.mem.indexOf(u8, target, "windows") != null) return "may require avoiding host-only libc/system-library assumptions";
    if (std.mem.indexOf(u8, target, "wasm") != null) return "freestanding/web targets commonly need custom entrypoints and no OS APIs";
    if (std.mem.indexOf(u8, target, "linux") != null) return "Linux cross-target checks catch many libc and target-feature issues";
    if (std.mem.indexOf(u8, target, "macos") != null) return "macOS targets may require SDK availability for linked artifacts";
    return "generic cross-target check";
}
