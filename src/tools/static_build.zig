const std = @import("std");

const common = @import("common.zig");

const App = common.App;
const ownedString = common.ownedString;

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
