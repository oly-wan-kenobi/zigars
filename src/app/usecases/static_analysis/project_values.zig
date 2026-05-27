//! Project-level static-analysis value builders for dependencies, build health, and metadata.
const std = @import("std");

const app_context = @import("../../context.zig");
const ports = @import("../../ports.zig");
const support = @import("../usecase_support.zig");
const zig_analysis = @import("../../../domain/zig/analysis.zig");
const compiler_output = @import("../../../domain/zig/compiler_output.zig");

/// Default build read limit used when the caller omits an explicit value.
pub const default_build_read_limit: usize = 1024 * 1024;
/// Default source read limit used when the caller omits an explicit value.
pub const default_source_read_limit: usize = 512 * 1024;

/// Carries dependency record data across use case and port boundaries.
pub const DependencyRecord = struct {
    name: []const u8,
    url: ?[]const u8 = null,
    hash: ?[]const u8 = null,
    path: ?[]const u8 = null,
    line: usize,
};

/// Error set returned by static project workflow failures.
pub const StaticProjectError = std.mem.Allocator.Error || ports.PortError || error{ InvalidArguments, MissingCommandRunner };

/// Carries test failure triage request data across use case and port boundaries.
pub const TestFailureTriageRequest = struct {
    text: ?[]const u8 = null,
    file: ?[]const u8 = null,
    filter: ?[]const u8 = null,
    args: []const u8 = "",
    timeout_ms: ?u64 = null,
};

/// Carries public api diff request data across use case and port boundaries.
pub const PublicApiDiffRequest = struct {
    file: ?[]const u8 = null,
    before: ?[]const u8 = null,
    after: ?[]const u8 = null,
    baseline_ref: []const u8 = "HEAD",
};

/// Serializes build workspace fields into an allocator-owned JSON value; allocation failures propagate.
pub fn buildWorkspaceValue(allocator: std.mem.Allocator, context: app_context.StaticAnalysisContext) ports.PortError!std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "workspace", .{ .string = context.workspace.root });

    if (context.workspace_store.read(allocator, .{
        .path = "build.zig",
        .max_bytes = default_build_read_limit,
        .provenance = "static_analysis.build_graph",
    }) catch null) |build_bytes| {
        defer build_bytes.deinit(allocator);
        try obj.put(allocator, "build_zig", try buildZigSummaryValue(allocator, build_bytes.bytes));
    } else {
        try obj.put(allocator, "build_zig", .null);
    }

    if (context.workspace_store.read(allocator, .{
        .path = "build.zig.zon",
        .max_bytes = default_build_read_limit,
        .provenance = "static_analysis.build_graph",
    }) catch null) |zon_bytes| {
        defer zon_bytes.deinit(allocator);
        try obj.put(allocator, "build_zig_zon", try zonSummaryValue(allocator, zon_bytes.bytes));
    } else {
        try obj.put(allocator, "build_zig_zon", .null);
    }

    return .{ .object = obj };
}

/// Serializes build zig summary fields into an allocator-owned JSON value; allocation failures propagate.
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
                var cmd = std.json.ObjectMap.empty;
                try cmd.put(allocator, "kind", .{ .string = "step" });
                try cmd.put(allocator, "name", try ownedString(allocator, step_name));
                try cmd.put(allocator, "command", .{ .string = try std.fmt.allocPrint(allocator, "zig build {s}", .{step_name}) });
                try commands.append(.{ .object = cmd });
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

/// Serializes zon summary fields into an allocator-owned JSON value; allocation failures propagate.
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

/// Serializes build entity fields into an allocator-owned JSON value; allocation failures propagate.
pub fn buildEntityValue(allocator: std.mem.Allocator, kind: []const u8, owner: ?[]const u8, name: ?[]const u8, line_no: usize, text_value: []const u8) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "kind", .{ .string = kind });
    if (owner) |value| try obj.put(allocator, "var", try ownedString(allocator, value)) else try obj.put(allocator, "var", .null);
    if (name) |value| try obj.put(allocator, "name", try ownedString(allocator, value)) else try obj.put(allocator, "name", .null);
    try obj.put(allocator, "line", .{ .integer = @intCast(line_no) });
    try obj.put(allocator, "text", try ownedString(allocator, text_value));
    return .{ .object = obj };
}

/// Serializes build step fields into an allocator-owned JSON value; allocation failures propagate.
pub fn buildStepValue(allocator: std.mem.Allocator, line_no: usize, text_value: []const u8) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    if (buildNameFromCall(text_value)) |name| try obj.put(allocator, "name", try ownedString(allocator, name)) else try obj.put(allocator, "name", .null);
    try obj.put(allocator, "line", .{ .integer = @intCast(line_no) });
    try obj.put(allocator, "command", if (buildNameFromCall(text_value)) |name| .{ .string = try std.fmt.allocPrint(allocator, "zig build {s}", .{name}) } else .null);
    try obj.put(allocator, "text", try ownedString(allocator, text_value));
    return .{ .object = obj };
}

/// Serializes build import fields into an allocator-owned JSON value; allocation failures propagate.
pub fn buildImportValue(allocator: std.mem.Allocator, owner: ?[]const u8, line_no: usize, text_value: []const u8) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    if (owner) |value| try obj.put(allocator, "owner", try ownedString(allocator, value)) else try obj.put(allocator, "owner", .null);
    if (buildNameFromCall(text_value)) |name| try obj.put(allocator, "import", try ownedString(allocator, name)) else try obj.put(allocator, "import", .null);
    try obj.put(allocator, "line", .{ .integer = @intCast(line_no) });
    try obj.put(allocator, "text", try ownedString(allocator, text_value));
    return .{ .object = obj };
}

/// Serializes source file owner fields into an allocator-owned JSON value; allocation failures propagate.
pub fn sourceFileOwnerValue(allocator: std.mem.Allocator, owner: ?[]const u8, kind: ?[]const u8, path: []const u8, line_no: usize) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "path", try ownedString(allocator, path));
    if (owner) |value| try obj.put(allocator, "owner", try ownedString(allocator, value)) else try obj.put(allocator, "owner", .null);
    if (kind) |value| try obj.put(allocator, "kind", .{ .string = value }) else try obj.put(allocator, "kind", .null);
    try obj.put(allocator, "line", .{ .integer = @intCast(line_no) });
    return .{ .object = obj };
}

/// Serializes command suggestion fields into an allocator-owned JSON value; allocation failures propagate.
pub fn commandSuggestionValue(allocator: std.mem.Allocator, kind: []const u8, command_text: []const u8) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "kind", .{ .string = kind });
    try obj.put(allocator, "command", .{ .string = command_text });
    return .{ .object = obj };
}

/// Implements owner var name workflow logic using caller-owned inputs.
pub fn ownerVarName(line: []const u8) ?[]const u8 {
    const eq = std.mem.indexOf(u8, line, " = ") orelse return null;
    const before = std.mem.trim(u8, line[0..eq], " \t");
    if (std.mem.startsWith(u8, before, "const ")) return std.mem.trim(u8, before["const ".len..], " \t");
    if (std.mem.startsWith(u8, before, "var ")) return std.mem.trim(u8, before["var ".len..], " \t");
    return null;
}

/// Constructs name from call data from caller-owned inputs, propagating allocation failures.
pub fn buildNameFromCall(line: []const u8) ?[]const u8 {
    const open = std.mem.indexOfScalar(u8, line, '(') orelse return null;
    const first_quote = std.mem.indexOfScalarPos(u8, line, open, '"') orelse return null;
    const second_quote = std.mem.indexOfScalarPos(u8, line, first_quote + 1, '"') orelse return null;
    return line[first_quote + 1 .. second_quote];
}

/// Constructs name from line data from caller-owned inputs, propagating allocation failures.
pub fn buildNameFromLine(line: []const u8) ?[]const u8 {
    if (std.mem.indexOf(u8, line, ".name")) |_| {
        if (quotedString(line)) |name| return name;
    }
    return buildNameFromCall(line);
}

/// Constructs path from line data from caller-owned inputs, propagating allocation failures.
pub fn buildPathFromLine(line: []const u8) ?[]const u8 {
    if (std.mem.indexOf(u8, line, "b.path(")) |pos| {
        const first_quote = std.mem.indexOfScalarPos(u8, line, pos, '"') orelse return null;
        const second_quote = std.mem.indexOfScalarPos(u8, line, first_quote + 1, '"') orelse return null;
        return line[first_quote + 1 .. second_quote];
    }
    return quotedString(line);
}

/// Implements dependency name from line workflow logic using caller-owned inputs.
pub fn dependencyNameFromLine(line: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, line, ".")) return null;
    const rest = line[1..];
    const end = std.mem.indexOfAny(u8, rest, " \t=") orelse return null;
    if (end == 0) return null;
    return rest[0..end];
}

/// Extracts declaration identity data from Zig source text.
pub fn declName(line: []const u8, kind: []const u8) ?[]const u8 {
    const rest = if (std.mem.startsWith(u8, line, "pub ")) line["pub ".len..] else line;
    const prefix_len = kind.len + 1;
    if (rest.len <= prefix_len) return null;
    var name = std.mem.trim(u8, rest[prefix_len..], " \t");
    // Stop at declaration syntax rather than parsing Zig fully; callers use the
    // result as a heuristic name hint, not a compiler-backed symbol.
    const end = std.mem.indexOfAny(u8, name, " (:=,{") orelse name.len;
    name = name[0..end];
    return if (name.len == 0) null else name;
}

/// Implements quoted string workflow logic using caller-owned inputs.
pub fn quotedString(line: []const u8) ?[]const u8 {
    const first_quote = std.mem.indexOfScalar(u8, line, '"') orelse return null;
    const second_quote = std.mem.indexOfScalarPos(u8, line, first_quote + 1, '"') orelse return null;
    return line[first_quote + 1 .. second_quote];
}

/// Constructs zig object data from caller-owned inputs, propagating allocation failures.
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

/// Serializes build targets fields into an allocator-owned JSON value; allocation failures propagate.
pub fn buildTargetsValue(allocator: std.mem.Allocator, context: app_context.StaticAnalysisContext) ports.PortError!std.json.Value {
    const graph = try buildWorkspaceValue(allocator, context);
    const graph_obj = switch (graph) {
        .object => |o| o,
        else => return error.InvalidRequest,
    };
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "workspace", .{ .string = context.workspace.root });
    if (graph_obj.get("build_zig")) |build_zig| {
        const build_obj = switch (build_zig) {
            .object => |o| o,
            else => return error.InvalidRequest,
        };
        try obj.put(allocator, "modules", build_obj.get("modules") orelse .null);
        try obj.put(allocator, "artifacts", build_obj.get("artifacts") orelse .null);
        try obj.put(allocator, "named_artifacts", build_obj.get("named_artifacts") orelse .null);
        try obj.put(allocator, "tests", build_obj.get("tests") orelse .null);
        try obj.put(allocator, "steps", build_obj.get("steps") orelse .null);
        try obj.put(allocator, "commands", build_obj.get("commands") orelse .null);
    }
    return .{ .object = obj };
}

/// Serializes build options fields into an allocator-owned JSON value; allocation failures propagate.
pub fn buildOptionsValue(allocator: std.mem.Allocator, context: app_context.StaticAnalysisContext) ports.PortError!std.json.Value {
    const read = try context.workspace_store.read(allocator, .{
        .path = "build.zig",
        .max_bytes = default_build_read_limit,
        .provenance = "static_analysis.build_options",
    });
    defer read.deinit(allocator);

    var options = std.json.Array.init(allocator);
    var commands = std.json.Array.init(allocator);
    var lines = std.mem.splitScalar(u8, read.bytes, '\n');
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
    try obj.put(allocator, "options", .{ .array = options });
    try obj.put(allocator, "commands", .{ .array = commands });
    return .{ .object = obj };
}

/// Serializes build option fields into an allocator-owned JSON value; allocation failures propagate.
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

/// Implements option name from line workflow logic using caller-owned inputs.
pub fn optionNameFromLine(line: []const u8) ?[]const u8 {
    const pos = std.mem.indexOf(u8, line, "b.option(") orelse return null;
    const first_quote = std.mem.indexOfScalarPos(u8, line, pos, '"') orelse return null;
    const second_quote = std.mem.indexOfScalarPos(u8, line, first_quote + 1, '"') orelse return null;
    return line[first_quote + 1 .. second_quote];
}

/// Implements option type from line workflow logic using caller-owned inputs.
pub fn optionTypeFromLine(line: []const u8) ?[]const u8 {
    const start = (std.mem.indexOf(u8, line, "b.option(") orelse return null) + "b.option(".len;
    const comma = std.mem.indexOfScalarPos(u8, line, start, ',') orelse return null;
    return std.mem.trim(u8, line[start..comma], " \t");
}

/// Serializes file owner fields into an allocator-owned JSON value; allocation failures propagate.
pub fn fileOwnerValue(allocator: std.mem.Allocator, graph: std.json.Value, rel: []const u8) !std.json.Value {
    var owners = std.json.Array.init(allocator);
    if (buildZigObject(graph)) |build_obj| {
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
        try obj.put(allocator, "owner_match_confidence", .{ .string = "low" });
        try obj.put(allocator, "reason", try ownedString(allocator, "No exact root_source_file match found in build.zig; commands are file-focused fallbacks."));
    } else {
        try obj.put(allocator, "owner_match_confidence", .{ .string = "high" });
        try obj.put(allocator, "reason", try ownedString(allocator, "File is referenced directly by build.zig root_source_file metadata."));
    }
    return .{ .object = obj };
}

/// Serializes file owner for path fields into an allocator-owned JSON value; allocation failures propagate.
pub fn fileOwnerForPathValue(allocator: std.mem.Allocator, context: app_context.StaticAnalysisContext, file: []const u8) StaticProjectError!std.json.Value {
    const resolved = try context.workspace_store.resolve(allocator, .{
        .path = file,
        .provenance = "static_analysis.file_owner",
    });
    defer resolved.deinit(allocator);
    const rel = workspaceRelative(context.workspace.root, resolved.path);
    const graph = try buildWorkspaceValue(allocator, context);
    return fileOwnerValue(allocator, graph, rel);
}

/// Serializes import resolve fields into an allocator-owned JSON value; allocation failures propagate.
pub fn importResolveValue(allocator: std.mem.Allocator, context: app_context.StaticAnalysisContext, graph: std.json.Value, import_name: []const u8, from: ?[]const u8) !std.json.Value {
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
        const exists = context.workspace_store.exists(allocator, .{
            .path = candidate,
            .provenance = "static_analysis.import_resolve",
        }) catch ports.WorkspaceExistsResult{ .exists = false };
        if (exists.exists) {
            try obj.put(allocator, "kind", .{ .string = "workspace_file" });
            try obj.put(allocator, "resolved", .{ .bool = true });
            try obj.put(allocator, "path", try ownedString(allocator, candidate));
            try obj.put(allocator, "next_action", .{ .string = try std.fmt.allocPrint(allocator, "Run zig ast-check {s}", .{candidate}) });
            return .{ .object = obj };
        }
    }

    try obj.put(allocator, "kind", .{ .string = "unresolved" });
    try obj.put(allocator, "resolved", .{ .bool = false });
    try obj.put(allocator, "next_action", try ownedString(allocator, "Check build.zig addImport calls and build.zig.zon dependencies for this import name."));
    return .{ .object = obj };
}

/// Finds module or dependency data in the provided collection without taking ownership.
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

/// Implements relative import candidate workflow logic using caller-owned inputs.
pub fn relativeImportCandidate(allocator: std.mem.Allocator, from: ?[]const u8, import_name: []const u8) ![]u8 {
    if (from) |from_file| {
        if (std.fs.path.dirname(from_file)) |dir| return std.fs.path.join(allocator, &.{ dir, import_name });
    }
    return allocator.dupe(u8, import_name);
}

/// Serializes dependency inspection fields into an allocator-owned JSON value; allocation failures propagate.
pub fn dependencyInspectionValue(allocator: std.mem.Allocator, context: app_context.StaticAnalysisContext, bytes: []const u8) ports.PortError!std.json.Value {
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
    try obj.put(allocator, "workspace", .{ .string = context.workspace.root });
    try obj.put(allocator, "dependencies", .{ .array = deps });
    try obj.put(allocator, "dependency_count", .{ .integer = @intCast(deps.items.len) });
    try obj.put(allocator, "issues", .{ .array = issues });
    try obj.put(allocator, "zig_pkg_cache", try cachePathStatusValue(allocator, context, "zig-pkg"));
    return .{ .object = obj };
}

/// Serializes dependency inspection from workspace fields into an allocator-owned JSON value; allocation failures propagate.
pub fn dependencyInspectionFromWorkspaceValue(allocator: std.mem.Allocator, context: app_context.StaticAnalysisContext) StaticProjectError!std.json.Value {
    const read = try context.workspace_store.read(allocator, .{
        .path = "build.zig.zon",
        .max_bytes = default_build_read_limit,
        .provenance = "static_analysis.dependency_inspect",
    });
    defer read.deinit(allocator);
    return dependencyInspectionValue(allocator, context, read.bytes);
}

/// Serializes cache path status fields into an allocator-owned JSON value; allocation failures propagate.
pub fn cachePathStatusValue(allocator: std.mem.Allocator, context: app_context.StaticAnalysisContext, path: []const u8) ports.PortError!std.json.Value {
    var resolved_for_output = false;
    const resolved: ?ports.WorkspaceResolveResult = context.workspace_store.resolve(allocator, .{
        .path = path,
        .provenance = "static_analysis.cache_path_status",
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => blk: {
            resolved_for_output = true;
            break :blk context.workspace_store.resolve(allocator, .{
                .path = path,
                .for_output = true,
                .provenance = "static_analysis.cache_path_status",
            }) catch |output_err| switch (output_err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => null,
            };
        },
    };
    defer if (resolved) |value| value.deinit(allocator);

    const exists = if (resolved != null)
        context.workspace_store.exists(allocator, .{
            .path = path,
            .for_output = resolved_for_output,
            .provenance = "static_analysis.cache_path_status",
        }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => ports.WorkspaceExistsResult{ .exists = false },
        }
    else
        ports.WorkspaceExistsResult{ .exists = false };

    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "path", try ownedString(allocator, path));
    if (resolved) |value| {
        try obj.put(allocator, "abs", try ownedString(allocator, value.path));
    } else {
        try obj.put(allocator, "abs", .null);
    }
    try obj.put(allocator, "exists", .{ .bool = exists.exists });
    if (exists.exists) {
        try obj.put(allocator, "kind", .{ .string = switch (exists.kind orelse .file) {
            .file => "file",
            .directory => "directory",
        } });
    } else {
        try obj.put(allocator, "kind", .null);
    }
    if (exists.entry_count) |count| try obj.put(allocator, "entry_count", .{ .integer = @intCast(count) }) else try obj.put(allocator, "entry_count", .null);
    return .{ .object = obj };
}

/// Implements dependency block name from line workflow logic using caller-owned inputs.
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

/// Appends dependency record data into caller-provided storage, propagating allocation failures.
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

/// Serializes test map fields into an allocator-owned JSON value; allocation failures propagate.
pub fn testMapValue(allocator: std.mem.Allocator, context: app_context.StaticAnalysisContext, limit: usize) ports.PortError!std.json.Value {
    var tests = std.json.Array.init(allocator);
    var files = std.json.Array.init(allocator);
    var commands = std.json.Array.init(allocator);

    var scan = try context.workspace_scanner.scanZigFiles(allocator, .{
        .max_files = null,
        .provenance = "static_analysis.test_map",
    });
    defer scan.deinit(allocator);

    var count: usize = 0;
    var skipped_files: usize = 0;
    for (scan.files) |file| {
        if (count >= limit) break;
        const read = context.workspace_store.read(allocator, .{
            .path = file.path,
            .max_bytes = default_source_read_limit,
            .provenance = "static_analysis.test_map",
        }) catch {
            skipped_files += 1;
            continue;
        };
        defer read.deinit(allocator);

        var file_test_count: usize = 0;
        var lines = std.mem.splitScalar(u8, read.bytes, '\n');
        var line_no: usize = 1;
        while (lines.next()) |line| : (line_no += 1) {
            if (count >= limit) break;
            const trimmed = std.mem.trim(u8, line, " \t");
            if (!std.mem.startsWith(u8, trimmed, "test ")) continue;
            count += 1;
            file_test_count += 1;
            var item = std.json.ObjectMap.empty;
            try item.put(allocator, "file", try ownedString(allocator, file.path));
            try item.put(allocator, "line", .{ .integer = @intCast(line_no) });
            try item.put(allocator, "name", if (testNameFromLine(trimmed)) |name| try ownedString(allocator, name) else .null);
            try item.put(allocator, "declaration", try ownedString(allocator, trimmed));
            try item.put(allocator, "likely_symbols", try likelySymbolsFromTestNameValue(allocator, testNameFromLine(trimmed) orelse trimmed));
            try item.put(allocator, "command", .{ .string = try std.fmt.allocPrint(allocator, "zig test {s}", .{file.path}) });
            try tests.append(.{ .object = item });
        }
        if (file_test_count > 0) {
            try files.append(try ownedString(allocator, file.path));
            try appendUniqueCommand(allocator, &commands, try std.fmt.allocPrint(allocator, "zig test {s}", .{file.path}));
        }
    }
    try appendUniqueCommand(allocator, &commands, "zig build test");

    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zig_test_map" });
    try obj.put(allocator, "tests", .{ .array = tests });
    try obj.put(allocator, "test_files", .{ .array = files });
    try obj.put(allocator, "commands", .{ .array = commands });
    try obj.put(allocator, "count", .{ .integer = @intCast(count) });
    try obj.put(allocator, "skipped_files", .{ .integer = @intCast(skipped_files) });
    try obj.put(allocator, "walk_errors", .{ .integer = 0 });
    return .{ .object = obj };
}

/// Serializes test failure triage fields into an allocator-owned JSON value; allocation failures propagate.
pub fn testFailureTriageValue(allocator: std.mem.Allocator, stderr: []const u8, stdout: []const u8, argv: []const []const u8, ok: bool) !std.json.Value {
    var failures = std.json.Array.init(allocator);
    var panics = std.json.Array.init(allocator);
    var expected_actual = std.json.Array.init(allocator);
    try collectTestFailureLines(allocator, &failures, &panics, &expected_actual, stderr);
    try collectTestFailureLines(allocator, &failures, &panics, &expected_actual, stdout);
    var commands = std.json.Array.init(allocator);
    try commands.append(.{ .string = try commandString(allocator, argv) });
    if (argvContains(argv, "test")) try commands.append(try ownedString(allocator, "rerun with --test-filter <failing test name>"));

    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zig_test_failure_triage" });
    try obj.put(allocator, "ok", .{ .bool = ok });
    try obj.put(allocator, "failures", .{ .array = failures });
    try obj.put(allocator, "panic_clues", .{ .array = panics });
    try obj.put(allocator, "expected_actual", .{ .array = expected_actual });
    try obj.put(allocator, "compile_diagnostics", try compilerErrorIndexValue(allocator, stderr, stdout, argv));
    try obj.put(allocator, "rerun_commands", .{ .array = commands });
    return .{ .object = obj };
}

/// Serializes test failure triage from workspace fields into an allocator-owned JSON value; allocation failures propagate.
pub fn testFailureTriageFromWorkspaceValue(allocator: std.mem.Allocator, context: app_context.StaticAnalysisContext, request: TestFailureTriageRequest) StaticProjectError!std.json.Value {
    if (request.text) |raw_text| {
        return testFailureTriageValue(allocator, raw_text, "", &.{ "zig", "test" }, false);
    }

    const runner = context.command_runner orelse return error.MissingCommandRunner;
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, context.tool_paths.zig);
    var resolved_file: ?ports.WorkspaceResolveResult = null;
    defer if (resolved_file) |resolved| resolved.deinit(allocator);
    if (request.file) |file| {
        resolved_file = try context.workspace_store.resolve(allocator, .{
            .path = file,
            .provenance = "static_analysis.test_failure_triage",
        });
        try argv.append(allocator, "test");
        try argv.append(allocator, resolved_file.?.path);
        if (request.filter) |filter| {
            try argv.append(allocator, "--test-filter");
            try argv.append(allocator, filter);
        }
    } else {
        try argv.append(allocator, "build");
        try argv.append(allocator, "test");
    }
    const extra = try splitArgs(allocator, request.args);
    defer freeStringList(allocator, extra);
    try argv.appendSlice(allocator, extra);
    const run = try runner.run(allocator, .{
        .argv = argv.items,
        .cwd = context.workspace.root,
        .timeout_ms = request.timeout_ms,
        .provenance = "static_analysis.test_failure_triage",
    });
    defer run.deinit(allocator);
    return testFailureTriageValue(allocator, run.stderr, run.stdout, argv.items, !run.effectiveTerm().failed());
}

/// Serializes changed files plan fields into an allocator-owned JSON value; allocation failures propagate.
pub fn changedFilesPlanValue(allocator: std.mem.Allocator, context: app_context.StaticAnalysisContext, timeout_ms: ?u64) StaticProjectError!std.json.Value {
    const runner = context.command_runner orelse return error.MissingCommandRunner;
    const result = try runner.run(allocator, .{
        .argv = &.{ "git", "status", "--porcelain" },
        .cwd = context.workspace.root,
        .timeout_ms = timeout_ms,
        .provenance = "static_analysis.changed_files_plan",
    });
    defer result.deinit(allocator);

    var files = std.json.Array.init(allocator);
    var commands = std.json.Array.init(allocator);
    var saw_zig = false;
    var saw_build = false;
    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    while (lines.next()) |line| {
        if (line.len < 4) continue;
        const path = statusLinePath(line);
        if (path.len == 0 or zig_analysis.skipWorkspacePath(path)) continue;
        var item = std.json.ObjectMap.empty;
        try item.put(allocator, "status", try ownedString(allocator, std.mem.trim(u8, line[0..2], " ")));
        try item.put(allocator, "path", try ownedString(allocator, path));
        try files.append(.{ .object = item });
        if (std.mem.endsWith(u8, path, ".zig") and workspacePathExists(allocator, context, path)) {
            saw_zig = true;
            try appendUniqueCommand(allocator, &commands, try std.fmt.allocPrint(allocator, "zig fmt --check {s}", .{path}));
            try appendUniqueCommand(allocator, &commands, try std.fmt.allocPrint(allocator, "zig ast-check {s}", .{path}));
            try appendUniqueCommand(allocator, &commands, try std.fmt.allocPrint(allocator, "zig test {s}", .{path}));
        }
        if ((std.mem.eql(u8, path, "build.zig") or std.mem.eql(u8, path, "build.zig.zon")) and workspacePathExists(allocator, context, path)) saw_build = true;
    }
    if (saw_build) {
        try appendUniqueCommand(allocator, &commands, "zig build --help");
        try appendUniqueCommand(allocator, &commands, "zig build test");
    } else if (saw_zig) {
        try appendUniqueCommand(allocator, &commands, "zig build test");
    }
    try appendWorkspaceFormatCheckCommand(allocator, context, &commands);

    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zig_changed_files_plan" });
    try obj.put(allocator, "ok", .{ .bool = !result.effectiveTerm().failed() });
    try obj.put(allocator, "files", .{ .array = files });
    try obj.put(allocator, "commands", .{ .array = commands });
    try obj.put(allocator, "raw_status", try ownedString(allocator, result.stdout));
    return .{ .object = obj };
}

/// Serializes target matrix plan fields into an allocator-owned JSON value; allocation failures propagate.
pub fn targetMatrixPlanValue(allocator: std.mem.Allocator, targets_text: []const u8, steps_text: []const u8) !std.json.Value {
    var targets = std.mem.tokenizeAny(u8, targets_text, ", \t\r\n");
    var matrix = std.json.Array.init(allocator);
    while (targets.next()) |target| {
        var commands = std.json.Array.init(allocator);
        var steps = std.mem.tokenizeAny(u8, steps_text, ", \t\r\n");
        while (steps.next()) |step| {
            if (std.mem.eql(u8, target, "native"))
                try commands.append(.{ .string = try std.fmt.allocPrint(allocator, "zig build {s}", .{step}) })
            else
                try commands.append(.{ .string = try std.fmt.allocPrint(allocator, "zig build {s} -Dtarget={s}", .{ step, target }) });
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
    return .{ .object = obj };
}

/// Implements target matrix note workflow logic using caller-owned inputs.
pub fn targetMatrixNote(target: []const u8) []const u8 {
    if (std.mem.eql(u8, target, "native")) return "uses the active host target";
    if (std.mem.indexOf(u8, target, "windows") != null) return "may require avoiding host-only libc/system-library assumptions";
    if (std.mem.indexOf(u8, target, "wasm") != null) return "freestanding/web targets commonly need custom entrypoints and no OS APIs";
    if (std.mem.indexOf(u8, target, "linux") != null) return "Linux cross-target checks catch many libc and target-feature issues";
    if (std.mem.indexOf(u8, target, "macos") != null) return "macOS targets may require SDK availability for linked artifacts";
    return "generic cross-target check";
}

/// Serializes workspace symbol cache fields into an allocator-owned JSON value; allocation failures propagate.
pub fn workspaceSymbolCacheValue(allocator: std.mem.Allocator, context: app_context.StaticAnalysisContext, query: ?[]const u8, limit: usize) StaticProjectError!std.json.Value {
    const index = try workspaceSymbolIndexValue(allocator, context, limit);
    const cache = if (context.analysis_cache) |analysis_cache|
        (analysis_cache.status() catch ports.StaticCacheStatus{})
    else
        ports.StaticCacheStatus{};

    var obj = switch (index) {
        .object => |o| o,
        else => return error.InvalidRequest,
    };
    try obj.put(allocator, "cache", try staticCacheStatusValue(allocator, cache));
    if (query) |text| try obj.put(allocator, "matches", try symbolCacheMatchesValue(allocator, .{ .object = obj }, text));
    return .{ .object = obj };
}

/// Serializes workspace symbol index fields into an allocator-owned JSON value; allocation failures propagate.
pub fn workspaceSymbolIndexValue(allocator: std.mem.Allocator, context: app_context.StaticAnalysisContext, limit: usize) ports.PortError!std.json.Value {
    var files = std.json.Array.init(allocator);
    var total_decls: usize = 0;
    var total_imports: usize = 0;
    var scan = try context.workspace_scanner.scanZigFiles(allocator, .{
        .max_files = limit,
        .provenance = "static_analysis.workspace_symbol_cache",
    });
    defer scan.deinit(allocator);

    var seen: usize = 0;
    var skipped_files: usize = 0;
    for (scan.files) |file| {
        if (seen >= limit) break;
        const read = context.workspace_store.read(allocator, .{
            .path = file.path,
            .max_bytes = default_source_read_limit,
            .provenance = "static_analysis.workspace_symbol_cache",
        }) catch {
            skipped_files += 1;
            continue;
        };
        defer read.deinit(allocator);
        seen += 1;

        var decls = std.json.Array.init(allocator);
        var imports = std.json.Array.init(allocator);
        var lines = std.mem.splitScalar(u8, read.bytes, '\n');
        var line_no: usize = 1;
        while (lines.next()) |line| : (line_no += 1) {
            const trimmed = std.mem.trim(u8, line, " \t");
            if (zig_analysis.declKind(trimmed)) |kind| {
                total_decls += 1;
                var decl = std.json.ObjectMap.empty;
                try decl.put(allocator, "kind", .{ .string = kind });
                try decl.put(allocator, "name", if (declName(trimmed, kind)) |name| try ownedString(allocator, name) else .null);
                try decl.put(allocator, "line", .{ .integer = @intCast(line_no) });
                try decl.put(allocator, "public", .{ .bool = std.mem.startsWith(u8, trimmed, "pub ") });
                try decls.append(.{ .object = decl });
            }
            var pos: usize = 0;
            while (std.mem.indexOfPos(u8, line, pos, "@import(\"")) |hit| {
                const start = hit + "@import(\"".len;
                const end = std.mem.indexOfScalarPos(u8, line, start, '"') orelse break;
                total_imports += 1;
                try imports.append(try ownedString(allocator, line[start..end]));
                pos = end + 1;
            }
        }
        var file_obj = std.json.ObjectMap.empty;
        try file_obj.put(allocator, "file", try ownedString(allocator, file.path));
        try file_obj.put(allocator, "declarations", .{ .array = decls });
        try file_obj.put(allocator, "imports", .{ .array = imports });
        try files.append(.{ .object = file_obj });
    }
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zig_workspace_symbol_cache" });
    try obj.put(allocator, "files", .{ .array = files });
    try obj.put(allocator, "file_count", .{ .integer = @intCast(seen) });
    try obj.put(allocator, "declaration_count", .{ .integer = @intCast(total_decls) });
    try obj.put(allocator, "import_count", .{ .integer = @intCast(total_imports) });
    try obj.put(allocator, "skipped_files", .{ .integer = @intCast(skipped_files) });
    try obj.put(allocator, "walk_errors", .{ .integer = 0 });
    return .{ .object = obj };
}

/// Serializes symbol cache matches fields into an allocator-owned JSON value; allocation failures propagate.
pub fn symbolCacheMatchesValue(allocator: std.mem.Allocator, index: std.json.Value, query: []const u8) !std.json.Value {
    const lower_query = try asciiLowerAllocLocal(allocator, query);
    defer allocator.free(lower_query);
    var matches = std.json.Array.init(allocator);
    const root = switch (index) {
        .object => |o| o,
        else => return .{ .array = matches },
    };
    const files = switch (root.get("files") orelse .null) {
        .array => |a| a,
        else => return .{ .array = matches },
    };
    for (files.items) |file_value| {
        const file_obj = switch (file_value) {
            .object => |o| o,
            else => continue,
        };
        const file = switch (file_obj.get("file") orelse .null) {
            .string => |s| s,
            else => continue,
        };
        const decls = switch (file_obj.get("declarations") orelse .null) {
            .array => |a| a,
            else => continue,
        };
        for (decls.items) |decl_value| {
            const decl_obj = switch (decl_value) {
                .object => |o| o,
                else => continue,
            };
            const name = switch (decl_obj.get("name") orelse .null) {
                .string => |s| s,
                else => continue,
            };
            const lower_name = try asciiLowerAllocLocal(allocator, name);
            defer allocator.free(lower_name);
            if (std.mem.indexOf(u8, lower_name, lower_query) == null) continue;
            var match = std.json.ObjectMap.empty;
            try match.put(allocator, "file", try ownedString(allocator, file));
            try match.put(allocator, "declaration", decl_value);
            try matches.append(.{ .object = match });
        }
    }
    return .{ .array = matches };
}

/// Serializes package cache doctor fields into an allocator-owned JSON value; allocation failures propagate.
pub fn packageCacheDoctorValue(allocator: std.mem.Allocator, context: app_context.StaticAnalysisContext, timeout_ms: ?u64) StaticProjectError!std.json.Value {
    var paths = std.json.Array.init(allocator);
    const names = [_][]const u8{ ".zig-cache", "zig-out", ".zigar-cache", "zig-pkg", "coverage" };
    for (names) |name| try paths.append(try cachePathStatusValue(allocator, context, name));

    var issues = std.json.Array.init(allocator);
    for (names) |name| {
        const tracked = gitTracksPath(allocator, context, name, timeout_ms) catch false;
        if (tracked) try issues.append(.{ .string = try std.fmt.allocPrint(allocator, "generated artifact path `{s}` is tracked by git", .{name}) });
    }
    if (context.workspace_store.read(allocator, .{
        .path = "build.zig.zon",
        .max_bytes = default_build_read_limit,
        .provenance = "static_analysis.package_cache_doctor",
    }) catch null) |read| {
        defer read.deinit(allocator);
        const deps = try dependencyInspectionValue(allocator, context, read.bytes);
        try issues.appendSlice(deps.object.get("issues").?.array.items);
    }
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zig_package_cache_doctor" });
    try obj.put(allocator, "paths", .{ .array = paths });
    try obj.put(allocator, "issues", .{ .array = issues });
    try obj.put(allocator, "resolution", .{ .string = "Cache directories should be workspace-local, ignored by git, and safe to delete/recreate when Zig package state becomes stale." });
    return .{ .object = obj };
}

/// Serializes test select fields into an allocator-owned JSON value; allocation failures propagate.
pub fn testSelectValue(allocator: std.mem.Allocator, context: app_context.StaticAnalysisContext, files_text: ?[]const u8, symbols_text: ?[]const u8, limit: usize) !std.json.Value {
    var files = std.ArrayList([]const u8).empty;
    defer {
        for (files.items) |value| allocator.free(value);
        files.deinit(allocator);
    }
    try appendPathTokens(allocator, &files, files_text);
    var symbols = std.ArrayList([]const u8).empty;
    defer {
        for (symbols.items) |value| allocator.free(value);
        symbols.deinit(allocator);
    }
    try appendPathTokens(allocator, &symbols, symbols_text);

    var commands = std.json.Array.init(allocator);
    var reasons = std.json.Array.init(allocator);
    for (files.items) |file| {
        if (std.mem.endsWith(u8, file, ".zig") and workspacePathExists(allocator, context, file)) {
            try appendUniqueCommand(allocator, &commands, try std.fmt.allocPrint(allocator, "zig test {s}", .{file}));
            try reasons.append(.{ .string = try std.fmt.allocPrint(allocator, "{s}: touched Zig file", .{file}) });
        }
    }

    const map = try testMapValue(allocator, context, limit);
    const tests = map.object.get("tests") orelse .null;
    if (tests == .array) {
        for (tests.array.items) |test_value| {
            const test_obj = switch (test_value) {
                .object => |o| o,
                else => continue,
            };
            const test_file = switch (test_obj.get("file") orelse .null) {
                .string => |s| s,
                else => continue,
            };
            const name = switch (test_obj.get("name") orelse .null) {
                .string => |s| s,
                else => "",
            };
            for (symbols.items) |symbol| {
                if (std.mem.indexOf(u8, name, symbol) != null or std.mem.indexOf(u8, test_file, symbol) != null) {
                    try appendUniqueCommand(allocator, &commands, try std.fmt.allocPrint(allocator, "zig test {s} --test-filter {s}", .{ test_file, symbol }));
                    try reasons.append(.{ .string = try std.fmt.allocPrint(allocator, "{s}: matched test name/file", .{symbol}) });
                }
            }
        }
    }
    try appendUniqueCommand(allocator, &commands, "zig build test");
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zig_test_select" });
    try obj.put(allocator, "commands", .{ .array = commands });
    try obj.put(allocator, "reasons", .{ .array = reasons });
    try obj.put(allocator, "fallback", .{ .string = "zig build test" });
    return .{ .object = obj };
}

/// Serializes public api diff fields into an allocator-owned JSON value; allocation failures propagate.
pub fn publicApiDiffValue(allocator: std.mem.Allocator, file: ?[]const u8, before: []const u8, after: []const u8) !std.json.Value {
    const before_decls = try publicDeclSnapshotValue(allocator, file, before);
    const after_decls = try publicDeclSnapshotValue(allocator, file, after);
    var added = std.json.Array.init(allocator);
    var removed = std.json.Array.init(allocator);
    var changed = std.json.Array.init(allocator);
    try comparePublicDecls(allocator, before_decls.array, after_decls.array, &added, &removed, &changed);

    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zig_public_api_diff" });
    if (file) |path| try obj.put(allocator, "file", try ownedString(allocator, path)) else try obj.put(allocator, "file", .null);
    try obj.put(allocator, "before", before_decls);
    try obj.put(allocator, "after", after_decls);
    try obj.put(allocator, "added", .{ .array = added });
    try obj.put(allocator, "removed", .{ .array = removed });
    try obj.put(allocator, "changed", .{ .array = changed });
    try obj.put(allocator, "breaking_change_risk", .{ .bool = removed.items.len > 0 or changed.items.len > 0 });
    try support.putSamplingUnavailable(allocator, &obj, "MCP sampling is not invoked by this deterministic public API diff; raw added, removed, and changed declarations are returned directly.");
    return .{ .object = obj };
}

/// Serializes public api diff from workspace fields into an allocator-owned JSON value; allocation failures propagate.
pub fn publicApiDiffFromWorkspaceValue(allocator: std.mem.Allocator, context: app_context.StaticAnalysisContext, request: PublicApiDiffRequest) StaticProjectError!std.json.Value {
    const before_text = if (request.before) |text| text else try publicApiBaseline(allocator, context, request.file, request.baseline_ref);
    const after_text = if (request.after) |text| text else try publicApiCurrent(allocator, context, request.file);
    return publicApiDiffValue(allocator, request.file, before_text, after_text);
}

/// Serializes public decl snapshot fields into an allocator-owned JSON value; allocation failures propagate.
pub fn publicDeclSnapshotValue(allocator: std.mem.Allocator, file: ?[]const u8, contents: []const u8) !std.json.Value {
    var decls = std.json.Array.init(allocator);
    var lines = std.mem.splitScalar(u8, contents, '\n');
    var line_no: usize = 1;
    while (lines.next()) |line| : (line_no += 1) {
        const trimmed = std.mem.trim(u8, line, " \t");
        if (!std.mem.startsWith(u8, trimmed, "pub ")) continue;
        const kind = zig_analysis.declKind(trimmed) orelse continue;
        var obj = std.json.ObjectMap.empty;
        if (file) |path| try obj.put(allocator, "file", try ownedString(allocator, path)) else try obj.put(allocator, "file", .null);
        try obj.put(allocator, "line", .{ .integer = @intCast(line_no) });
        try obj.put(allocator, "kind", .{ .string = kind });
        try obj.put(allocator, "name", if (declName(trimmed, kind)) |name| try ownedString(allocator, name) else .null);
        try obj.put(allocator, "signature", try ownedString(allocator, trimmed));
        try decls.append(.{ .object = obj });
    }
    return .{ .array = decls };
}

/// Implements compare public decls workflow logic using caller-owned inputs.
pub fn comparePublicDecls(allocator: std.mem.Allocator, before: std.json.Array, after: std.json.Array, added: *std.json.Array, removed: *std.json.Array, changed: *std.json.Array) !void {
    for (after.items) |after_decl| {
        const key = declKey(after_decl) orelse continue;
        const match = findDeclByKey(before, key);
        if (match) |before_decl| {
            if (!std.mem.eql(u8, declSignature(before_decl) orelse "", declSignature(after_decl) orelse "")) {
                var item = std.json.ObjectMap.empty;
                try item.put(allocator, "before", before_decl);
                try item.put(allocator, "after", after_decl);
                try changed.append(.{ .object = item });
            }
        } else {
            try added.append(after_decl);
        }
    }
    for (before.items) |before_decl| {
        const key = declKey(before_decl) orelse continue;
        if (findDeclByKey(after, key) == null) try removed.append(before_decl);
    }
}

/// Collects test failure lines data into caller-provided output storage without taking ownership of inputs.
pub fn collectTestFailureLines(allocator: std.mem.Allocator, failures: *std.json.Array, panics: *std.json.Array, expected_actual: *std.json.Array, text_value: []const u8) !void {
    var lines = std.mem.splitScalar(u8, text_value, '\n');
    var line_no: usize = 1;
    while (lines.next()) |line| : (line_no += 1) {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len == 0) continue;
        if (std.mem.indexOf(u8, trimmed, "FAIL") != null or std.mem.indexOf(u8, trimmed, "failed") != null) try appendLineRecord(allocator, failures, line_no, trimmed);
        if (std.mem.indexOf(u8, trimmed, "panic") != null or std.mem.indexOf(u8, trimmed, "thread ") != null) try appendLineRecord(allocator, panics, line_no, trimmed);
        if (std.mem.indexOf(u8, trimmed, "expected") != null or std.mem.indexOf(u8, trimmed, "actual") != null) try appendLineRecord(allocator, expected_actual, line_no, trimmed);
    }
}

/// Reports whether the requested workspace path exists.
pub fn workspacePathExists(allocator: std.mem.Allocator, context: app_context.StaticAnalysisContext, path: []const u8) bool {
    const result = context.workspace_store.exists(allocator, .{
        .path = path,
        .provenance = "static_analysis.workspace_path_exists",
    }) catch return false;
    return result.exists;
}

/// Implements ascii lower alloc local workflow logic using caller-owned inputs.
pub fn asciiLowerAllocLocal(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    return std.ascii.allocLowerString(allocator, input);
}

/// Implements test name from line workflow logic using caller-owned inputs.
pub fn testNameFromLine(line: []const u8) ?[]const u8 {
    const rest = std.mem.trim(u8, line["test ".len..], " \t");
    if (rest.len == 0) return null;
    if (rest[0] == '"') return quotedString(rest);
    const end = std.mem.indexOfAny(u8, rest, " {(") orelse rest.len;
    return rest[0..end];
}

/// Serializes likely symbols from test name fields into an allocator-owned JSON value; allocation failures propagate.
pub fn likelySymbolsFromTestNameValue(allocator: std.mem.Allocator, name: []const u8) !std.json.Value {
    var symbols = std.json.Array.init(allocator);
    var tokens = std.mem.tokenizeAny(u8, name, " .:_-/\t\r\n\"");
    while (tokens.next()) |token| {
        if (token.len < 3) continue;
        if (std.ascii.isUpper(token[0])) try symbols.append(try ownedString(allocator, token));
    }
    return .{ .array = symbols };
}

/// Serializes compiler error index fields into an allocator-owned JSON value; allocation failures propagate.
pub fn compilerErrorIndexValue(allocator: std.mem.Allocator, stderr: []const u8, stdout: []const u8, argv: []const []const u8) !std.json.Value {
    const insights = try compilerInsightsValue(allocator, stdout, stderr, argv);
    const insights_obj = switch (insights) {
        .object => |o| o,
        else => return insights,
    };
    var files = std.json.Array.init(allocator);
    const findings = switch (insights_obj.get("findings") orelse .null) {
        .array => |a| a,
        else => std.json.Array.init(allocator),
    };
    for (findings.items) |finding| {
        const finding_obj = switch (finding) {
            .object => |o| o,
            else => continue,
        };
        const path = switch (finding_obj.get("path") orelse .null) {
            .string => |s| s,
            else => "(unlocated)",
        };
        var found_index: ?usize = null;
        for (files.items, 0..) |file_value, index| {
            const file_obj = switch (file_value) {
                .object => |o| o,
                else => continue,
            };
            const existing = switch (file_obj.get("path") orelse .null) {
                .string => |s| s,
                else => continue,
            };
            if (std.mem.eql(u8, existing, path)) {
                found_index = index;
                break;
            }
        }
        if (found_index) |index| {
            var file_obj = files.items[index].object;
            var file_findings = file_obj.get("findings").?.array;
            try file_findings.append(finding);
            try file_obj.put(allocator, "findings", .{ .array = file_findings });
            try file_obj.put(allocator, "count", .{ .integer = @intCast(file_findings.items.len) });
            files.items[index] = .{ .object = file_obj };
        } else {
            var file_findings = std.json.Array.init(allocator);
            try file_findings.append(finding);
            var file_obj = std.json.ObjectMap.empty;
            try file_obj.put(allocator, "path", try ownedString(allocator, path));
            try file_obj.put(allocator, "count", .{ .integer = 1 });
            try file_obj.put(allocator, "findings", .{ .array = file_findings });
            try files.append(.{ .object = file_obj });
        }
    }

    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zig_compile_error_index" });
    try obj.put(allocator, "summary", insights);
    try obj.put(allocator, "files", .{ .array = files });
    try obj.put(allocator, "file_count", .{ .integer = @intCast(files.items.len) });
    return .{ .object = obj };
}

/// Shared compiler line result type used by this workflow module.
pub const CompilerLine = compiler_output.CompilerLine;

/// Serializes compiler insights fields into an allocator-owned JSON value; allocation failures propagate.
pub fn compilerInsightsValue(allocator: std.mem.Allocator, stdout: []const u8, stderr: []const u8, argv: []const []const u8) !std.json.Value {
    var findings = std.json.Array.init(allocator);
    var error_count: i64 = 0;
    var warning_count: i64 = 0;
    var note_count: i64 = 0;
    var primary: ?CompilerLine = null;

    try collectCompilerLines(allocator, &findings, stderr, &primary, &error_count, &warning_count, &note_count);
    try collectCompilerLines(allocator, &findings, stdout, &primary, &error_count, &warning_count, &note_count);

    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "finding_count", .{ .integer = @intCast(findings.items.len) });
    try obj.put(allocator, "error_count", .{ .integer = error_count });
    try obj.put(allocator, "warning_count", .{ .integer = warning_count });
    try obj.put(allocator, "note_count", .{ .integer = note_count });
    try obj.put(allocator, "findings", .{ .array = findings });
    if (primary) |p| {
        try obj.put(allocator, "primary", try compilerLineValue(allocator, p));
        try obj.put(allocator, "category", .{ .string = compiler_output.classifyDiagnosticMessage(p.message) });
        try obj.put(allocator, "next_command", try compilerNextCommand(allocator, p, argv));
        try obj.put(allocator, "next_actions", try compilerNextActions(allocator, p, note_count));
    } else {
        try obj.put(allocator, "primary", .null);
        try obj.put(allocator, "category", .{ .string = "none" });
        try obj.put(allocator, "next_command", .null);
        try obj.put(allocator, "next_actions", .{ .array = std.json.Array.init(allocator) });
    }
    return .{ .object = obj };
}

/// Collects compiler lines data into caller-provided output storage without taking ownership of inputs.
pub fn collectCompilerLines(
    allocator: std.mem.Allocator,
    findings: *std.json.Array,
    text_value: []const u8,
    primary: *?CompilerLine,
    error_count: *i64,
    warning_count: *i64,
    note_count: *i64,
) !void {
    var lines = std.mem.splitScalar(u8, text_value, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, "\r");
        const parsed = compiler_output.parseCompilerLine(line) orelse continue;
        if (std.mem.eql(u8, parsed.severity, "error")) {
            error_count.* += 1;
            if (primary.* == null) primary.* = parsed;
        } else if (std.mem.eql(u8, parsed.severity, "warning")) {
            warning_count.* += 1;
            if (primary.* == null) primary.* = parsed;
        } else if (std.mem.eql(u8, parsed.severity, "note")) {
            note_count.* += 1;
        }
        try findings.append(try compilerLineValue(allocator, parsed));
    }
}

/// Serializes compiler line fields into an allocator-owned JSON value; allocation failures propagate.
pub fn compilerLineValue(allocator: std.mem.Allocator, parsed: CompilerLine) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "severity", .{ .string = parsed.severity });
    try obj.put(allocator, "message", try ownedString(allocator, parsed.message));
    try obj.put(allocator, "raw", try ownedString(allocator, parsed.raw));
    if (parsed.path) |path| {
        try obj.put(allocator, "path", try ownedString(allocator, path));
    } else {
        try obj.put(allocator, "path", .null);
    }
    if (parsed.line) |line_no| {
        try obj.put(allocator, "line", .{ .integer = line_no });
    } else {
        try obj.put(allocator, "line", .null);
    }
    if (parsed.column) |col_no| {
        try obj.put(allocator, "column", .{ .integer = col_no });
    } else {
        try obj.put(allocator, "column", .null);
    }
    return .{ .object = obj };
}

/// Implements compiler next command workflow logic using caller-owned inputs.
pub fn compilerNextCommand(allocator: std.mem.Allocator, primary: CompilerLine, argv: []const []const u8) !std.json.Value {
    const zig = if (argv.len > 0) argv[0] else "zig";
    const path = primary.path orelse return .{ .string = try commandString(allocator, argv) };
    if (path.len > 0 and std.mem.endsWith(u8, path, ".zig")) {
        if (argvContains(argv, "test")) {
            return .{ .string = try std.fmt.allocPrint(allocator, "{s} test {s}", .{ zig, path }) };
        }
        return .{ .string = try std.fmt.allocPrint(allocator, "{s} ast-check {s}", .{ zig, path }) };
    }
    return .{ .string = try commandString(allocator, argv) };
}

/// Implements compiler next actions workflow logic using caller-owned inputs.
pub fn compilerNextActions(allocator: std.mem.Allocator, primary: CompilerLine, note_count: i64) !std.json.Value {
    var actions = std.json.Array.init(allocator);
    if (primary.path) |path| {
        if (primary.line) |line_no| {
            if (primary.column) |col_no| {
                try actions.append(.{ .string = try std.fmt.allocPrint(allocator, "Open {s}:{d}:{d} and address the primary {s}: {s}", .{ path, line_no, col_no, primary.severity, primary.message }) });
            } else {
                try actions.append(.{ .string = try std.fmt.allocPrint(allocator, "Open {s}:{d} and address the primary {s}: {s}", .{ path, line_no, primary.severity, primary.message }) });
            }
        } else {
            try actions.append(.{ .string = try std.fmt.allocPrint(allocator, "Inspect {s} and address the primary {s}: {s}", .{ path, primary.severity, primary.message }) });
        }
    } else {
        try actions.append(.{ .string = try std.fmt.allocPrint(allocator, "Address the primary {s}: {s}", .{ primary.severity, primary.message }) });
    }
    if (note_count > 0) {
        try actions.append(try ownedString(allocator, "Review compiler note entries before editing; Zig often puts the fix-relevant type or declaration context there."));
    }
    if (std.mem.eql(u8, compiler_output.classifyDiagnosticMessage(primary.message), "missing_file_or_import")) {
        try actions.append(try ownedString(allocator, "Run zig_import_resolve for the failing @import name, then check build.zig addImport and build.zig.zon dependency wiring."));
    }
    try actions.append(try ownedString(allocator, "Rerun the next_command after the focused edit."));
    return .{ .array = actions };
}

/// Appends line record data into caller-provided storage, propagating allocation failures.
pub fn appendLineRecord(allocator: std.mem.Allocator, array: *std.json.Array, line_no: usize, text_value: []const u8) !void {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "line", .{ .integer = @intCast(line_no) });
    try obj.put(allocator, "text", try ownedString(allocator, text_value));
    try array.append(.{ .object = obj });
}

/// Appends unique command data into caller-provided storage, propagating allocation failures.
fn appendUniqueCommand(allocator: std.mem.Allocator, commands: *std.json.Array, command_text: []const u8) !void {
    for (commands.items) |item| {
        const existing = switch (item) {
            .string => |s| s,
            else => continue,
        };
        if (std.mem.eql(u8, existing, command_text)) return;
    }
    try commands.append(try ownedString(allocator, command_text));
}

/// Formats argv entries into display command text.
pub fn commandString(allocator: std.mem.Allocator, argv: []const []const u8) ![]u8 {
    if (argv.len == 0) return allocator.dupe(u8, "");
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (argv, 0..) |arg, index| {
        if (index > 0) try out.append(allocator, ' ');
        try out.appendSlice(allocator, arg);
    }
    return out.toOwnedSlice(allocator);
}

/// Reads the argv contains argument from JSON input without taking ownership of borrowed strings.
pub fn argvContains(argv: []const []const u8, needle: []const u8) bool {
    for (argv) |arg| {
        if (std.mem.eql(u8, arg, needle)) return true;
    }
    return false;
}

/// Extracts declaration identity data from Zig source text.
pub fn declKey(value: std.json.Value) ?[]const u8 {
    const obj = switch (value) {
        .object => |o| o,
        else => return null,
    };
    return switch (obj.get("name") orelse .null) {
        .string => |s| s,
        else => null,
    };
}

/// Extracts declaration identity data from Zig source text.
pub fn declSignature(value: std.json.Value) ?[]const u8 {
    const obj = switch (value) {
        .object => |o| o,
        else => return null,
    };
    return switch (obj.get("signature") orelse .null) {
        .string => |s| s,
        else => null,
    };
}

/// Finds decl by key data in the provided collection without taking ownership.
pub fn findDeclByKey(array: std.json.Array, key: []const u8) ?std.json.Value {
    for (array.items) |item| {
        if (declKey(item)) |candidate| {
            if (std.mem.eql(u8, candidate, key)) return item;
        }
    }
    return null;
}

/// Extracts the path portion from a porcelain status line.
pub fn statusLinePath(line: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, if (line.len > 3) line[3..] else "", " \t");
    if (std.mem.indexOf(u8, trimmed, " -> ")) |arrow| return trimmed[arrow + " -> ".len ..];
    return trimmed;
}

/// Appends path tokens data into caller-provided storage, propagating allocation failures.
pub fn appendPathTokens(allocator: std.mem.Allocator, list: *std.ArrayList([]const u8), text: ?[]const u8) !void {
    const raw = text orelse return;
    var tokens = std.mem.tokenizeAny(u8, raw, ", \t\r\n");
    while (tokens.next()) |token| try list.append(allocator, try allocator.dupe(u8, token));
}

/// Appends workspace format check command data into caller-provided storage, propagating allocation failures.
pub fn appendWorkspaceFormatCheckCommand(allocator: std.mem.Allocator, context: app_context.StaticAnalysisContext, commands: *std.json.Array) !void {
    const candidates = [_][]const u8{ "build.zig", "build.zig.zon", "src" };
    var command_text: std.ArrayList(u8) = .empty;
    defer command_text.deinit(allocator);
    try command_text.appendSlice(allocator, "zig fmt --check");
    var appended_path = false;
    for (candidates) |candidate| {
        if (!workspacePathExists(allocator, context, candidate)) continue;
        try command_text.print(allocator, " {s}", .{candidate});
        appended_path = true;
    }
    if (appended_path) try appendUniqueCommand(allocator, commands, command_text.items);
}

/// Implements git tracks path workflow logic using caller-owned inputs.
pub fn gitTracksPath(allocator: std.mem.Allocator, context: app_context.StaticAnalysisContext, path: []const u8, timeout_ms: ?u64) StaticProjectError!bool {
    const runner = context.command_runner orelse return error.MissingCommandRunner;
    const result = runner.run(allocator, .{
        .argv = &.{ "git", "ls-files", "--error-unmatch", path },
        .cwd = context.workspace.root,
        .timeout_ms = timeout_ms,
        .provenance = "static_analysis.git_tracks_path",
    }) catch return false;
    defer result.deinit(allocator);
    return !result.effectiveTerm().failed();
}

/// Serializes static cache status fields into an allocator-owned JSON value; allocation failures propagate.
pub fn staticCacheStatusValue(allocator: std.mem.Allocator, cache: ports.StaticCacheStatus) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "cached", .{ .bool = cache.cached });
    try obj.put(allocator, "hits", .{ .integer = @intCast(cache.hits) });
    try obj.put(allocator, "refreshes", .{ .integer = @intCast(cache.refreshes) });
    try obj.put(allocator, "signature", .{ .integer = @intCast(cache.signature & @as(u64, std.math.maxInt(i64))) });
    try obj.put(allocator, "bytes_len", .{ .integer = @intCast(cache.bytes_len) });
    return .{ .object = obj };
}

/// Implements workspace relative workflow logic using caller-owned inputs.
fn workspaceRelative(root: []const u8, path: []const u8) []const u8 {
    if (std.mem.startsWith(u8, path, root)) {
        var rel = path[root.len..];
        while (std.mem.startsWith(u8, rel, "/")) rel = rel[1..];
        if (rel.len > 0) return rel;
    }
    return path;
}

/// Implements public api baseline workflow logic using caller-owned inputs.
fn publicApiBaseline(allocator: std.mem.Allocator, context: app_context.StaticAnalysisContext, file: ?[]const u8, baseline_ref: []const u8) StaticProjectError![]const u8 {
    const rel = file orelse return "";
    const runner = context.command_runner orelse return "";
    const spec = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ baseline_ref, rel });
    const result = runner.run(allocator, .{
        .argv = &.{ "git", "show", spec },
        .cwd = context.workspace.root,
        .timeout_ms = 5000,
        .provenance = "static_analysis.public_api_diff.baseline",
    }) catch return "";
    defer result.deinit(allocator);
    if (result.effectiveTerm().failed()) return "";
    return allocator.dupe(u8, result.stdout);
}

/// Implements public api current workflow logic using caller-owned inputs.
fn publicApiCurrent(allocator: std.mem.Allocator, context: app_context.StaticAnalysisContext, file: ?[]const u8) StaticProjectError![]const u8 {
    const rel = file orelse return "";
    const read = context.workspace_store.read(allocator, .{
        .path = rel,
        .max_bytes = default_source_read_limit,
        .provenance = "static_analysis.public_api_diff.current",
    }) catch return "";
    defer read.deinit(allocator);
    return allocator.dupe(u8, read.bytes);
}

/// Parses shell-like argument text into allocator-owned argument slices.
pub fn splitArgs(allocator: std.mem.Allocator, text: []const u8) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    var current: std.ArrayList(u8) = .empty;
    errdefer {
        for (list.items) |arg| allocator.free(arg);
        list.deinit(allocator);
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

/// Parses shell-like argument text into allocator-owned argument slices.
fn finishArg(allocator: std.mem.Allocator, list: *std.ArrayList([]const u8), current: *std.ArrayList(u8)) !void {
    try list.ensureUnusedCapacity(allocator, 1);
    const arg = try current.toOwnedSlice(allocator);
    list.appendAssumeCapacity(arg);
}

/// Releases string list allocations; callers must not reuse freed items.
fn freeStringList(allocator: std.mem.Allocator, values: []const []const u8) void {
    for (values) |value| allocator.free(value);
    allocator.free(values);
}

/// Copies the provided string into allocator-owned storage.
fn ownedString(allocator: std.mem.Allocator, value: []const u8) !std.json.Value {
    return .{ .string = try allocator.dupe(u8, value) };
}
