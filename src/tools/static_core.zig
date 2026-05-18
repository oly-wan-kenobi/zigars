const std = @import("std");
const mcp = @import("mcp");
const zigar = @import("zigar");

const analysis = zigar.analysis;
const command = zigar.command;
const docs = zigar.docs;
const common = @import("common.zig");
const docs_tools = @import("docs.zig");

const App = common.App;
const structured = common.structured;
const argString = common.argString;
const argInt = common.argInt;
const workspacePathErrorResult = common.workspacePathErrorResult;
const toolTimeout = common.toolTimeout;
const backendErrorResult = common.backendErrorResult;
const structuredText = common.structuredText;
const ownedString = common.ownedString;
const statusLinePath = common.statusLinePath;
const appendWorkspaceFormatCheckCommand = common.appendWorkspaceFormatCheckCommand;
const appendUniqueCommand = common.appendUniqueCommand;
const readSourceArg = docs_tools.readSourceArg;

pub fn zigImportGraph(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const output = analysis.importGraph(allocator, a.io, a.workspace.root, @intCast(@max(1, argInt(args, "limit", 200)))) catch return error.ExecutionFailed;
    defer allocator.free(output);
    return structuredText(allocator, "zig_import_graph", output);
}

pub fn zigImportGraphJson(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const limit: usize = @intCast(@max(1, argInt(args, "limit", 200)));
    const value = analysis.importGraphJson(allocator, a.io, a.workspace.root, limit) catch return error.ExecutionFailed;
    return structured(allocator, value);
}

pub fn zigDeclSummary(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const source = readSourceArg(a, allocator, args) catch return error.InvalidArguments;
    defer allocator.free(source.bytes);
    const output = analysis.declSummary(allocator, source.name, source.bytes) catch return error.OutOfMemory;
    defer allocator.free(output);
    return structuredText(allocator, "zig_decl_summary", output);
}

pub fn zigDeclSummaryJson(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const source = readSourceArg(a, allocator, args) catch return error.InvalidArguments;
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
    const source = readSourceArg(a, allocator, args) catch return error.InvalidArguments;
    defer allocator.free(source.bytes);
    const output = analysis.allocationSummary(allocator, source.name, source.bytes) catch return error.OutOfMemory;
    defer allocator.free(output);
    return structuredText(allocator, "zig_allocations", output);
}

pub fn zigErrorSets(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const source = readSourceArg(a, allocator, args) catch return error.InvalidArguments;
    defer allocator.free(source.bytes);
    const output = analysis.errorSetSummary(allocator, source.name, source.bytes) catch return error.OutOfMemory;
    defer allocator.free(output);
    return structuredText(allocator, "zig_error_sets", output);
}

pub fn zigPublicApi(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const source = readSourceArg(a, allocator, args) catch return error.InvalidArguments;
    defer allocator.free(source.bytes);
    const output = analysis.publicApiSummary(allocator, source.name, source.bytes) catch return error.OutOfMemory;
    defer allocator.free(output);
    return structuredText(allocator, "zig_public_api", output);
}

pub fn zigDeadDeclCandidates(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const source = readSourceArg(a, allocator, args) catch return error.InvalidArguments;
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
        else => return error.ExecutionFailed,
    };
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    obj.put(allocator, "workspace", .{ .string = a.workspace.root }) catch return error.OutOfMemory;
    if (graph_obj.get("build_zig")) |build_zig| {
        const build_obj = switch (build_zig) {
            .object => |o| o,
            else => return error.ExecutionFailed,
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
    const bytes = a.workspace.readFileAlloc(a.io, "build.zig", 1024 * 1024) catch return error.ResourceNotFound;
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
    const file = argString(args, "file") orelse return error.InvalidArguments;
    const resolved = a.workspace.resolve(file) catch |err| return workspacePathErrorResult(a, allocator, "zig_file_owner", file, err);
    defer allocator.free(resolved);
    const rel = a.workspace.relative(resolved);
    const graph = buildWorkspaceValue(allocator, a) catch return error.OutOfMemory;
    const owner = fileOwnerValue(allocator, graph, rel) catch return error.OutOfMemory;
    return structured(allocator, owner);
}

pub fn zigImportResolve(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const import_name = argString(args, "import") orelse return error.InvalidArguments;
    const from = argString(args, "from");
    const graph = buildWorkspaceValue(allocator, a) catch return error.OutOfMemory;
    const resolved = importResolveValue(allocator, a, graph, import_name, from) catch return error.OutOfMemory;
    return structured(allocator, resolved);
}

pub fn buildWorkspaceValue(allocator: std.mem.Allocator, a: *App) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "workspace", .{ .string = a.workspace.root });
    try obj.put(allocator, "analysis_kind", .{ .string = "heuristic_build_file_scan" });
    try obj.put(allocator, "confidence", .{ .string = "medium" });

    if (a.workspace.readFileAlloc(a.io, "build.zig", 1024 * 1024) catch null) |build_bytes| {
        defer allocator.free(build_bytes);
        try obj.put(allocator, "build_zig", try buildZigSummaryValue(allocator, build_bytes));
    } else {
        try obj.put(allocator, "build_zig", .null);
    }
    if (a.workspace.readFileAlloc(a.io, "build.zig.zon", 1024 * 1024) catch null) |zon_bytes| {
        defer allocator.free(zon_bytes);
        try obj.put(allocator, "build_zig_zon", try zonSummaryValue(allocator, zon_bytes));
    } else {
        try obj.put(allocator, "build_zig_zon", .null);
    }
    return .{ .object = obj };
}

pub fn buildZigSummaryValue(allocator: std.mem.Allocator, bytes: []const u8) !std.json.Value {
    var modules = std.json.Array.init(allocator);
    var artifacts = std.json.Array.init(allocator);
    var named_artifacts = std.json.Array.init(allocator);
    var tests = std.json.Array.init(allocator);
    var steps = std.json.Array.init(allocator);
    var imports = std.json.Array.init(allocator);
    var source_files = std.json.Array.init(allocator);
    var commands = std.json.Array.init(allocator);
    try commands.append(try commandSuggestionValue(allocator, "build", "zig build"));
    try commands.append(try commandSuggestionValue(allocator, "test", "zig build test"));

    var lines = std.mem.splitScalar(u8, bytes, '\n');
    var line_no: usize = 1;
    var current_owner: ?[]const u8 = null;
    var current_kind: ?[]const u8 = null;
    while (lines.next()) |line| : (line_no += 1) {
        const trimmed = std.mem.trim(u8, line, " \t");
        if (std.mem.indexOf(u8, trimmed, "addModule(") != null or std.mem.indexOf(u8, trimmed, "createModule(") != null) {
            const owner = ownerVarName(trimmed);
            current_owner = owner;
            current_kind = "module";
            try modules.append(try buildEntityValue(allocator, "module", owner, buildNameFromCall(trimmed), line_no, trimmed));
        }
        if (std.mem.indexOf(u8, trimmed, "addExecutable(") != null or std.mem.indexOf(u8, trimmed, "addLibrary(") != null) {
            const owner = ownerVarName(trimmed);
            current_owner = owner;
            current_kind = "artifact";
            try artifacts.append(try buildEntityValue(allocator, "artifact", owner, buildNameFromLine(trimmed), line_no, trimmed));
        }
        if (std.mem.indexOf(u8, trimmed, "addTest(") != null) {
            const owner = ownerVarName(trimmed);
            current_owner = owner;
            current_kind = "test";
            try tests.append(try buildEntityValue(allocator, "test", owner, null, line_no, trimmed));
        }
        if (std.mem.indexOf(u8, trimmed, ".step(") != null) {
            try steps.append(try buildStepValue(allocator, line_no, trimmed));
            if (buildNameFromCall(trimmed)) |step_name| {
                try commands.append(.{ .object = blk: {
                    var cmd = std.json.ObjectMap.empty;
                    try cmd.put(allocator, "kind", .{ .string = "step" });
                    try cmd.put(allocator, "name", try ownedString(allocator, step_name));
                    try cmd.put(allocator, "command", .{ .string = try std.fmt.allocPrint(allocator, "zig build {s}", .{step_name}) });
                    break :blk cmd;
                } });
            }
        }
        if (current_kind != null and std.mem.eql(u8, current_kind.?, "artifact") and std.mem.startsWith(u8, trimmed, ".name")) {
            if (quotedString(trimmed)) |name| try named_artifacts.append(try buildEntityValue(allocator, "artifact", current_owner, name, line_no, trimmed));
        }
        if (std.mem.indexOf(u8, trimmed, "addImport(") != null) {
            try imports.append(try buildImportValue(allocator, current_owner, line_no, trimmed));
        }
        if (std.mem.indexOf(u8, trimmed, "root_source_file") != null) {
            if (buildPathFromLine(trimmed)) |path| try source_files.append(try sourceFileOwnerValue(allocator, current_owner, current_kind, path, line_no));
        }
    }
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "modules", .{ .array = modules });
    try obj.put(allocator, "artifacts", .{ .array = artifacts });
    try obj.put(allocator, "named_artifacts", .{ .array = named_artifacts });
    try obj.put(allocator, "tests", .{ .array = tests });
    try obj.put(allocator, "steps", .{ .array = steps });
    try obj.put(allocator, "imports", .{ .array = imports });
    try obj.put(allocator, "source_files", .{ .array = source_files });
    try obj.put(allocator, "commands", .{ .array = commands });
    return .{ .object = obj };
}

pub fn zonSummaryValue(allocator: std.mem.Allocator, bytes: []const u8) !std.json.Value {
    var deps = std.json.Array.init(allocator);
    var paths = std.json.Array.init(allocator);
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    var in_deps = false;
    var in_paths = false;
    var line_no: usize = 1;
    while (lines.next()) |line| : (line_no += 1) {
        const trimmed = std.mem.trim(u8, line, " \t");
        if (std.mem.startsWith(u8, trimmed, ".dependencies")) in_deps = true;
        if (std.mem.startsWith(u8, trimmed, ".paths")) in_paths = true;
        if (in_deps and std.mem.startsWith(u8, trimmed, ".")) {
            if (dependencyNameFromLine(trimmed)) |name| {
                var dep = std.json.ObjectMap.empty;
                try dep.put(allocator, "name", try ownedString(allocator, name));
                try dep.put(allocator, "line", .{ .integer = @intCast(line_no) });
                try dep.put(allocator, "text", try ownedString(allocator, trimmed));
                try deps.append(.{ .object = dep });
            }
        }
        if (in_paths and std.mem.startsWith(u8, trimmed, "\"")) {
            if (quotedString(trimmed)) |path| try paths.append(try ownedString(allocator, path));
        }
        if (in_deps and std.mem.eql(u8, trimmed, "},")) in_deps = false;
        if (in_paths and std.mem.eql(u8, trimmed, "},")) in_paths = false;
    }
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "dependencies", .{ .array = deps });
    try obj.put(allocator, "paths", .{ .array = paths });
    return .{ .object = obj };
}

pub fn buildEntityValue(allocator: std.mem.Allocator, kind: []const u8, owner: ?[]const u8, name: ?[]const u8, line_no: usize, text_value: []const u8) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "kind", .{ .string = kind });
    if (owner) |value| try obj.put(allocator, "var", try ownedString(allocator, value)) else try obj.put(allocator, "var", .null);
    if (name) |value| try obj.put(allocator, "name", try ownedString(allocator, value)) else try obj.put(allocator, "name", .null);
    try obj.put(allocator, "line", .{ .integer = @intCast(line_no) });
    try obj.put(allocator, "text", try ownedString(allocator, text_value));
    return .{ .object = obj };
}

pub fn buildStepValue(allocator: std.mem.Allocator, line_no: usize, text_value: []const u8) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    if (buildNameFromCall(text_value)) |name| try obj.put(allocator, "name", try ownedString(allocator, name)) else try obj.put(allocator, "name", .null);
    try obj.put(allocator, "line", .{ .integer = @intCast(line_no) });
    try obj.put(allocator, "command", if (buildNameFromCall(text_value)) |name| .{ .string = try std.fmt.allocPrint(allocator, "zig build {s}", .{name}) } else .null);
    try obj.put(allocator, "text", try ownedString(allocator, text_value));
    return .{ .object = obj };
}

pub fn buildImportValue(allocator: std.mem.Allocator, owner: ?[]const u8, line_no: usize, text_value: []const u8) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    if (owner) |value| try obj.put(allocator, "owner", try ownedString(allocator, value)) else try obj.put(allocator, "owner", .null);
    if (buildNameFromCall(text_value)) |name| try obj.put(allocator, "import", try ownedString(allocator, name)) else try obj.put(allocator, "import", .null);
    try obj.put(allocator, "line", .{ .integer = @intCast(line_no) });
    try obj.put(allocator, "text", try ownedString(allocator, text_value));
    return .{ .object = obj };
}

pub fn sourceFileOwnerValue(allocator: std.mem.Allocator, owner: ?[]const u8, kind: ?[]const u8, path: []const u8, line_no: usize) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "path", try ownedString(allocator, path));
    if (owner) |value| try obj.put(allocator, "owner", try ownedString(allocator, value)) else try obj.put(allocator, "owner", .null);
    if (kind) |value| try obj.put(allocator, "kind", .{ .string = value }) else try obj.put(allocator, "kind", .null);
    try obj.put(allocator, "line", .{ .integer = @intCast(line_no) });
    return .{ .object = obj };
}

pub fn commandSuggestionValue(allocator: std.mem.Allocator, kind: []const u8, command_text: []const u8) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "kind", .{ .string = kind });
    try obj.put(allocator, "command", .{ .string = command_text });
    return .{ .object = obj };
}

pub fn ownerVarName(line: []const u8) ?[]const u8 {
    const eq = std.mem.indexOf(u8, line, " = ") orelse return null;
    const before = std.mem.trim(u8, line[0..eq], " \t");
    if (std.mem.startsWith(u8, before, "const ")) return std.mem.trim(u8, before["const ".len..], " \t");
    if (std.mem.startsWith(u8, before, "var ")) return std.mem.trim(u8, before["var ".len..], " \t");
    return null;
}

pub fn buildNameFromCall(line: []const u8) ?[]const u8 {
    const open = std.mem.indexOfScalar(u8, line, '(') orelse return null;
    const first_quote = std.mem.indexOfScalarPos(u8, line, open, '"') orelse return null;
    const second_quote = std.mem.indexOfScalarPos(u8, line, first_quote + 1, '"') orelse return null;
    return line[first_quote + 1 .. second_quote];
}

pub fn buildNameFromLine(line: []const u8) ?[]const u8 {
    if (std.mem.indexOf(u8, line, ".name")) |_| {
        if (quotedString(line)) |name| return name;
    }
    return buildNameFromCall(line);
}

pub fn buildPathFromLine(line: []const u8) ?[]const u8 {
    if (std.mem.indexOf(u8, line, "b.path(")) |pos| {
        const first_quote = std.mem.indexOfScalarPos(u8, line, pos, '"') orelse return null;
        const second_quote = std.mem.indexOfScalarPos(u8, line, first_quote + 1, '"') orelse return null;
        return line[first_quote + 1 .. second_quote];
    }
    return quotedString(line);
}

pub fn dependencyNameFromLine(line: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, line, ".")) return null;
    const rest = line[1..];
    const end = std.mem.indexOfAny(u8, rest, " \t=") orelse return null;
    if (end == 0) return null;
    return rest[0..end];
}

pub fn quotedString(line: []const u8) ?[]const u8 {
    const first_quote = std.mem.indexOfScalar(u8, line, '"') orelse return null;
    const second_quote = std.mem.indexOfScalarPos(u8, line, first_quote + 1, '"') orelse return null;
    return line[first_quote + 1 .. second_quote];
}

pub fn fileOwnerValue(allocator: std.mem.Allocator, graph: std.json.Value, rel: []const u8) !std.json.Value {
    var owners = std.json.Array.init(allocator);
    const build_zig = buildZigObject(graph);
    if (build_zig) |build_obj| {
        if (build_obj.get("source_files")) |source_files| {
            if (source_files == .array) {
                for (source_files.array.items) |item| {
                    const item_obj = switch (item) {
                        .object => |o| o,
                        else => continue,
                    };
                    const path = switch (item_obj.get("path") orelse .null) {
                        .string => |s| s,
                        else => continue,
                    };
                    if (std.mem.eql(u8, path, rel)) try owners.append(item);
                }
            }
        }
    }

    var commands = std.json.Array.init(allocator);
    try commands.append(.{ .string = try std.fmt.allocPrint(allocator, "zig ast-check {s}", .{rel}) });
    try commands.append(.{ .string = try std.fmt.allocPrint(allocator, "zig test {s}", .{rel}) });
    try commands.append(try ownedString(allocator, "zig build test"));

    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "file", try ownedString(allocator, rel));
    try obj.put(allocator, "owners", .{ .array = owners });
    try obj.put(allocator, "owner_count", .{ .integer = @intCast(owners.items.len) });
    try obj.put(allocator, "likely_commands", .{ .array = commands });
    if (owners.items.len == 0) {
        try obj.put(allocator, "confidence", .{ .string = "low" });
        try obj.put(allocator, "reason", try ownedString(allocator, "No exact root_source_file match found in build.zig; commands are file-focused fallbacks."));
    } else {
        try obj.put(allocator, "confidence", .{ .string = "high" });
        try obj.put(allocator, "reason", try ownedString(allocator, "File is referenced directly by build.zig root_source_file metadata."));
    }
    return .{ .object = obj };
}

pub fn importResolveValue(allocator: std.mem.Allocator, a: *App, graph: std.json.Value, import_name: []const u8, from: ?[]const u8) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "import", try ownedString(allocator, import_name));
    if (from) |from_file| try obj.put(allocator, "from", try ownedString(allocator, from_file)) else try obj.put(allocator, "from", .null);

    if (std.mem.eql(u8, import_name, "std")) {
        try obj.put(allocator, "kind", .{ .string = "stdlib" });
        try obj.put(allocator, "resolved", .{ .bool = true });
        try obj.put(allocator, "next_action", try ownedString(allocator, "Use zig_std_search or zig_std_item for stdlib details."));
        return .{ .object = obj };
    }
    if (std.mem.eql(u8, import_name, "builtin") or std.mem.eql(u8, import_name, "root")) {
        try obj.put(allocator, "kind", .{ .string = "compiler_builtin" });
        try obj.put(allocator, "resolved", .{ .bool = true });
        try obj.put(allocator, "next_action", try ownedString(allocator, "This import is supplied by Zig or by the current root module."));
        return .{ .object = obj };
    }

    if (findModuleOrDependency(allocator, &obj, graph, import_name)) return .{ .object = obj };

    if (std.mem.endsWith(u8, import_name, ".zig")) {
        const candidate = try relativeImportCandidate(allocator, from, import_name);
        defer allocator.free(candidate);
        if (a.workspace.resolve(candidate) catch null) |resolved| {
            defer allocator.free(resolved);
            try obj.put(allocator, "kind", .{ .string = "workspace_file" });
            try obj.put(allocator, "resolved", .{ .bool = true });
            try obj.put(allocator, "path", try ownedString(allocator, a.workspace.relative(resolved)));
            try obj.put(allocator, "next_action", .{ .string = try std.fmt.allocPrint(allocator, "Run zig ast-check {s}", .{a.workspace.relative(resolved)}) });
            return .{ .object = obj };
        }
    }

    try obj.put(allocator, "kind", .{ .string = "unresolved" });
    try obj.put(allocator, "resolved", .{ .bool = false });
    try obj.put(allocator, "next_action", try ownedString(allocator, "Check build.zig addImport calls and build.zig.zon dependencies for this import name."));
    return .{ .object = obj };
}

pub fn buildZigObject(graph: std.json.Value) ?std.json.ObjectMap {
    const graph_obj = switch (graph) {
        .object => |o| o,
        else => return null,
    };
    const build_zig = graph_obj.get("build_zig") orelse return null;
    return switch (build_zig) {
        .object => |o| o,
        else => null,
    };
}

pub fn findModuleOrDependency(allocator: std.mem.Allocator, obj: *std.json.ObjectMap, graph: std.json.Value, import_name: []const u8) bool {
    if (buildZigObject(graph)) |build_obj| {
        if (build_obj.get("modules")) |modules| {
            if (modules == .array) {
                for (modules.array.items) |item| {
                    const item_obj = switch (item) {
                        .object => |o| o,
                        else => continue,
                    };
                    const name = switch (item_obj.get("name") orelse item_obj.get("var") orelse .null) {
                        .string => |s| s,
                        else => continue,
                    };
                    if (std.mem.eql(u8, name, import_name)) {
                        obj.put(allocator, "kind", .{ .string = "build_module" }) catch return false;
                        obj.put(allocator, "resolved", .{ .bool = true }) catch return false;
                        obj.put(allocator, "module", item) catch return false;
                        obj.put(allocator, "next_action", .{ .string = "Inspect build.zig module addImport wiring for this module." }) catch return false;
                        return true;
                    }
                }
            }
        }
    }
    const graph_obj = switch (graph) {
        .object => |o| o,
        else => return false,
    };
    const zon = graph_obj.get("build_zig_zon") orelse return false;
    const zon_obj = switch (zon) {
        .object => |o| o,
        else => return false,
    };
    const deps = zon_obj.get("dependencies") orelse return false;
    if (deps == .array) {
        for (deps.array.items) |item| {
            const item_obj = switch (item) {
                .object => |o| o,
                else => continue,
            };
            const name = switch (item_obj.get("name") orelse .null) {
                .string => |s| s,
                else => continue,
            };
            if (std.mem.eql(u8, name, import_name)) {
                obj.put(allocator, "kind", .{ .string = "package_dependency" }) catch return false;
                obj.put(allocator, "resolved", .{ .bool = true }) catch return false;
                obj.put(allocator, "dependency", item) catch return false;
                obj.put(allocator, "next_action", .{ .string = "Check b.dependency(...) and module addImport(...) wiring for this dependency." }) catch return false;
                return true;
            }
        }
    }
    return false;
}

pub fn relativeImportCandidate(allocator: std.mem.Allocator, from: ?[]const u8, import_name: []const u8) ![]u8 {
    if (from) |from_file| {
        if (std.fs.path.dirname(from_file)) |dir| return std.fs.path.join(allocator, &.{ dir, import_name });
    }
    return allocator.dupe(u8, import_name);
}

pub fn appendLineRecord(allocator: std.mem.Allocator, array: *std.json.Array, line_no: usize, text_value: []const u8) !void {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "line", .{ .integer = @intCast(line_no) });
    try obj.put(allocator, "text", try ownedString(allocator, text_value));
    try array.append(.{ .object = obj });
}

pub fn zigTestDiscover(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const limit: usize = @intCast(@max(1, argInt(args, "limit", 500)));
    const value = analysis.testDiscoverJson(allocator, a.io, a.workspace.root, limit) catch return error.ExecutionFailed;
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
    const bytes = a.workspace.readFileAlloc(a.io, "build.zig.zon", 1024 * 1024) catch return error.ResourceNotFound;
    defer allocator.free(bytes);
    const value = dependencyInspectionValue(allocator, a, bytes) catch return error.OutOfMemory;
    return structured(allocator, value);
}

pub const DependencyRecord = struct {
    name: []const u8,
    url: ?[]const u8 = null,
    hash: ?[]const u8 = null,
    path: ?[]const u8 = null,
    line: usize,
};

pub fn cachePathStatusValue(allocator: std.mem.Allocator, a: *App, path: []const u8) !std.json.Value {
    const resolved = a.workspace.resolve(path) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => a.workspace.resolveOutput(path) catch null,
    };
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "path", try ownedString(allocator, path));
    if (resolved) |abs| {
        defer allocator.free(abs);
        try obj.put(allocator, "abs", try ownedString(allocator, abs));
        const count = countTopLevelEntries(allocator, a.io, abs) catch null;
        if (count) |n| {
            try obj.put(allocator, "exists", .{ .bool = true });
            try obj.put(allocator, "kind", .{ .string = "directory" });
            try obj.put(allocator, "entry_count", .{ .integer = @intCast(n) });
        } else if (std.Io.Dir.cwd().readFileAlloc(a.io, abs, allocator, .limited(1)) catch null) |bytes| {
            allocator.free(bytes);
            try obj.put(allocator, "exists", .{ .bool = true });
            try obj.put(allocator, "kind", .{ .string = "file" });
            try obj.put(allocator, "entry_count", .null);
        } else {
            try obj.put(allocator, "exists", .{ .bool = false });
            try obj.put(allocator, "kind", .null);
            try obj.put(allocator, "entry_count", .null);
        }
    } else {
        try obj.put(allocator, "abs", .null);
        try obj.put(allocator, "exists", .{ .bool = false });
        try obj.put(allocator, "kind", .null);
        try obj.put(allocator, "entry_count", .null);
    }
    return .{ .object = obj };
}

pub fn countTopLevelEntries(allocator: std.mem.Allocator, io: std.Io, abs: []const u8) !usize {
    var dir = try std.Io.Dir.openDirAbsolute(io, abs, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(allocator);
    defer walker.deinit();
    var count: usize = 0;
    while ((walker.next(io) catch null)) |entry| {
        if (std.mem.indexOfScalar(u8, entry.path, std.fs.path.sep) == null) count += 1;
    }
    return count;
}

pub fn dependencyInspectionValue(allocator: std.mem.Allocator, a: *App, bytes: []const u8) !std.json.Value {
    var deps = std.json.Array.init(allocator);
    var issues = std.json.Array.init(allocator);
    var current: ?DependencyRecord = null;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    var line_no: usize = 1;
    while (lines.next()) |line| : (line_no += 1) {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (dependencyBlockNameFromLine(trimmed)) |name| {
            if (current) |record| try appendDependencyRecord(allocator, &deps, &issues, record);
            current = .{ .name = name, .line = line_no };
            continue;
        }
        if (current) |*record| {
            if (std.mem.indexOf(u8, trimmed, ".url") != null) {
                record.url = quotedString(trimmed);
            } else if (std.mem.indexOf(u8, trimmed, ".hash") != null) {
                record.hash = quotedString(trimmed);
            } else if (std.mem.indexOf(u8, trimmed, ".path") != null) {
                record.path = quotedString(trimmed);
            } else if (std.mem.startsWith(u8, trimmed, "},")) {
                try appendDependencyRecord(allocator, &deps, &issues, record.*);
                current = null;
            }
        }
    }
    if (current) |record| try appendDependencyRecord(allocator, &deps, &issues, record);

    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zig_dependency_inspect" });
    try obj.put(allocator, "workspace", .{ .string = a.workspace.root });
    try obj.put(allocator, "dependencies", .{ .array = deps });
    try obj.put(allocator, "dependency_count", .{ .integer = @intCast(deps.items.len) });
    try obj.put(allocator, "issues", .{ .array = issues });
    try obj.put(allocator, "zig_pkg_cache", try cachePathStatusValue(allocator, a, "zig-pkg"));
    try obj.put(allocator, "analysis_kind", .{ .string = "heuristic_zon_dependency_scan" });
    try obj.put(allocator, "confidence", .{ .string = "medium" });
    return .{ .object = obj };
}

pub fn dependencyBlockNameFromLine(line: []const u8) ?[]const u8 {
    if (std.mem.indexOf(u8, line, "= .{") == null) return null;
    const name = dependencyNameFromLine(line) orelse return null;
    if (std.mem.eql(u8, name, "dependencies") or
        std.mem.eql(u8, name, "paths") or
        std.mem.eql(u8, name, "url") or
        std.mem.eql(u8, name, "hash") or
        std.mem.eql(u8, name, "path")) return null;
    return name;
}

pub fn appendDependencyRecord(allocator: std.mem.Allocator, deps: *std.json.Array, issues: *std.json.Array, record: DependencyRecord) !void {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "name", try ownedString(allocator, record.name));
    try obj.put(allocator, "line", .{ .integer = @intCast(record.line) });
    if (record.url) |url| try obj.put(allocator, "url", try ownedString(allocator, url)) else try obj.put(allocator, "url", .null);
    if (record.hash) |hash| try obj.put(allocator, "hash", try ownedString(allocator, hash)) else try obj.put(allocator, "hash", .null);
    if (record.path) |path| try obj.put(allocator, "path", try ownedString(allocator, path)) else try obj.put(allocator, "path", .null);
    try deps.append(.{ .object = obj });
    if (record.url != null and record.hash == null) {
        try issues.append(.{ .string = try std.fmt.allocPrint(allocator, "dependency `{s}` has a URL but no hash", .{record.name}) });
    }
    if (record.url != null and record.path != null) {
        try issues.append(.{ .string = try std.fmt.allocPrint(allocator, "dependency `{s}` declares both url and path", .{record.name}) });
    }
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
