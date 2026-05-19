const std = @import("std");
const mcp = @import("mcp");
const zigar = @import("zigar");

const analysis = zigar.analysis;
const analysis_contract = zigar.analysis_contract;
const command = zigar.command;
const json_result = zigar.json_result;
const common = @import("common.zig");
const core = @import("core.zig");
const static_core = @import("static_core.zig");

const App = common.App;
const structured = common.structured;
const argString = common.argString;
const argBool = common.argBool;
const argInt = common.argInt;
const workspacePathErrorResult = common.workspacePathErrorResult;
const toolTimeout = common.toolTimeout;
const backendErrorResult = common.backendErrorResult;
const splitToolArgs = common.splitToolArgs;
const splitToolArgsErrorResult = common.splitToolArgsErrorResult;
const toolErrorFromError = common.toolErrorFromError;
const toolErrorResult = common.toolErrorResult;
const commandString = common.commandString;
const argvContains = common.argvContains;
const ownedString = common.ownedString;
const appendPathTokens = common.appendPathTokens;
const appendUniqueString = common.appendUniqueString;
const freeStringList = common.freeStringList;
const analysisCacheStatusValue = common.analysisCacheStatusValue;
const appendUniqueCommand = common.appendUniqueCommand;
const freeArgList = common.freeArgList;
const compilerErrorIndexValue = core.compilerErrorIndexValue;

const asciiLowerAllocLocal = static_core.asciiLowerAllocLocal;
const quotedString = static_core.quotedString;
const appendLineRecord = static_core.appendLineRecord;
const workspacePathExists = static_core.workspacePathExists;
const dependencyInspectionValue = static_core.dependencyInspectionValue;
const cachePathStatusValue = static_core.cachePathStatusValue;
const countTopLevelEntries = static_core.countTopLevelEntries;

fn symbolCacheError(allocator: std.mem.Allocator, phase: []const u8, err: anyerror) mcp.tools.ToolError!mcp.tools.ToolResult {
    return toolErrorFromError(allocator, .{
        .tool = "zig_workspace_symbol_cache",
        .operation = "maintain_symbol_cache",
        .phase = phase,
        .code = "symbol_cache_failed",
        .category = "analysis_cache",
        .resolution = "Retry with refresh=true and a smaller limit; if it repeats, inspect the workspace for unreadable Zig files.",
    }, err);
}

pub fn zigTestFailureTriage(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    if (argString(args, "text")) |raw_text| {
        return structured(allocator, testFailureTriageValue(allocator, raw_text, "", &.{ "zig", "test" }, false) catch return error.OutOfMemory);
    }
    var list: std.ArrayList([]const u8) = .empty;
    defer list.deinit(allocator);
    var resolved_file: ?[]const u8 = null;
    defer if (resolved_file) |path| allocator.free(path);
    try list.append(allocator, a.config.zig_path);
    if (argString(args, "file")) |file| {
        resolved_file = a.workspace.resolve(file) catch |err| return workspacePathErrorResult(a, allocator, "zig_test_failure_triage", file, err);
        try list.append(allocator, "test");
        try list.append(allocator, resolved_file.?);
        if (argString(args, "filter")) |filter| {
            try list.append(allocator, "--test-filter");
            try list.append(allocator, filter);
        }
    } else {
        try list.append(allocator, "build");
        try list.append(allocator, "test");
    }
    const raw_extra_args = argString(args, "args") orelse "";
    const extra = splitToolArgs(allocator, raw_extra_args) catch |err| return splitToolArgsErrorResult(allocator, "zig_test_failure_triage", "args", raw_extra_args, err);
    defer freeArgList(allocator, extra);
    try list.appendSlice(allocator, extra);
    a.command_calls += 1;
    const run = command.run(allocator, a.io, a.workspace.root, list.items, toolTimeout(a, args)) catch |err| return backendErrorResult(allocator, "zig", "test_failure_triage", err, "pass captured test output as text or confirm --zig-path is executable");
    defer run.deinit(allocator);
    return structured(allocator, testFailureTriageValue(allocator, run.stderr, run.stdout, list.items, run.succeeded()) catch return error.OutOfMemory);
}

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
    try analysis_contract.putMetadata(allocator, &obj, "zig_test_failure_triage");
    try obj.put(allocator, "ok", .{ .bool = ok });
    try obj.put(allocator, "failures", .{ .array = failures });
    try obj.put(allocator, "panic_clues", .{ .array = panics });
    try obj.put(allocator, "expected_actual", .{ .array = expected_actual });
    try obj.put(allocator, "compile_diagnostics", try compilerErrorIndexValue(allocator, stderr, stdout, argv));
    try obj.put(allocator, "rerun_commands", .{ .array = commands });
    return .{ .object = obj };
}

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

pub fn zigWorkspaceSymbolCache(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const limit: usize = @intCast(@max(1, argInt(args, "limit", 500)));
    const signature = workspaceSymbolSignature(allocator, a, limit) catch |err| return symbolCacheError(allocator, "build_signature", err);
    const refresh = argBool(args, "refresh", false) or a.analysis_cache.index_json == null or a.analysis_cache.signature != signature;
    if (refresh) {
        const index = workspaceSymbolIndexValue(allocator, a, limit) catch |err| return symbolCacheError(allocator, "build_index", err);
        var bytes_list: std.ArrayList(u8) = .empty;
        json_result.serializeValue(allocator, &bytes_list, index) catch return error.OutOfMemory;
        const bytes = bytes_list.toOwnedSlice(allocator) catch return error.OutOfMemory;
        if (a.analysis_cache.index_json) |old| allocator.free(old);
        a.analysis_cache.index_json = bytes;
        a.analysis_cache.signature = signature;
        a.analysis_cache.refreshes += 1;
    } else {
        a.analysis_cache.hits += 1;
    }

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, a.analysis_cache.index_json.?, .{}) catch |err| return symbolCacheError(allocator, "parse_cache", err);
    defer parsed.deinit();
    const cached_obj = switch (parsed.value) {
        .object => |o| o,
        else => return toolErrorResult(allocator, .{
            .tool = "zig_workspace_symbol_cache",
            .operation = "read_symbol_cache",
            .phase = "decode_cache",
            .code = "unexpected_cache_shape",
            .category = "internal_contract",
            .resolution = "Refresh the cache with refresh=true; if it repeats, report the workspace_symbol_cache response with the zigar version.",
        }),
    };
    var obj = std.json.ObjectMap.empty;
    defer obj.deinit(allocator);
    var it = cached_obj.iterator();
    while (it.next()) |entry| {
        try obj.put(allocator, entry.key_ptr.*, entry.value_ptr.*);
    }
    try obj.put(allocator, "cache", try analysisCacheStatusValue(allocator, a));
    if (argString(args, "query")) |query| {
        try obj.put(allocator, "matches", try symbolCacheMatchesValue(allocator, parsed.value, query));
    }
    return structured(allocator, .{ .object = obj });
}

pub fn workspaceSymbolSignature(allocator: std.mem.Allocator, a: *App, limit: usize) !u64 {
    var hasher = std.hash.Wyhash.init(0);
    var dir = try std.Io.Dir.openDirAbsolute(a.io, a.workspace.root, .{ .iterate = true });
    defer dir.close(a.io);
    var walker = try dir.walk(allocator);
    defer walker.deinit();
    var seen: usize = 0;
    while ((walker.next(a.io) catch null)) |entry| {
        if (seen >= limit) break;
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".zig") or analysis.skipWorkspacePath(entry.path)) continue;
        seen += 1;
        hasher.update(entry.path);
        const bytes = a.workspace.readFileAlloc(a.io, entry.path, 256 * 1024) catch continue;
        defer allocator.free(bytes);
        hasher.update(bytes);
    }
    return hasher.final();
}

pub fn workspaceSymbolIndexValue(allocator: std.mem.Allocator, a: *App, limit: usize) !std.json.Value {
    var files = std.json.Array.init(allocator);
    var total_decls: usize = 0;
    var total_imports: usize = 0;
    var dir = try std.Io.Dir.openDirAbsolute(a.io, a.workspace.root, .{ .iterate = true });
    defer dir.close(a.io);
    var walker = try dir.walk(allocator);
    defer walker.deinit();
    var seen: usize = 0;
    var skipped_files: usize = 0;
    var walk_errors: usize = 0;
    while (true) {
        const maybe_entry = walker.next(a.io) catch {
            walk_errors += 1;
            break;
        };
        const entry = maybe_entry orelse break;
        if (seen >= limit) break;
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".zig") or analysis.skipWorkspacePath(entry.path)) continue;
        const contents = a.workspace.readFileAlloc(a.io, entry.path, 512 * 1024) catch {
            skipped_files += 1;
            continue;
        };
        defer allocator.free(contents);
        seen += 1;
        var decls = std.json.Array.init(allocator);
        var imports = std.json.Array.init(allocator);
        var lines = std.mem.splitScalar(u8, contents, '\n');
        var line_no: usize = 1;
        while (lines.next()) |line| : (line_no += 1) {
            const trimmed = std.mem.trim(u8, line, " \t");
            if (analysis.declKind(trimmed)) |kind| {
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
        try file_obj.put(allocator, "file", try ownedString(allocator, entry.path));
        try file_obj.put(allocator, "declarations", .{ .array = decls });
        try file_obj.put(allocator, "imports", .{ .array = imports });
        try files.append(.{ .object = file_obj });
    }
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zig_workspace_symbol_cache" });
    try analysis_contract.putMetadata(allocator, &obj, "zig_workspace_symbol_cache");
    try obj.put(allocator, "files", .{ .array = files });
    try obj.put(allocator, "file_count", .{ .integer = @intCast(seen) });
    try obj.put(allocator, "declaration_count", .{ .integer = @intCast(total_decls) });
    try obj.put(allocator, "import_count", .{ .integer = @intCast(total_imports) });
    try obj.put(allocator, "skipped_files", .{ .integer = @intCast(skipped_files) });
    try obj.put(allocator, "walk_errors", .{ .integer = @intCast(walk_errors) });
    return .{ .object = obj };
}

pub fn declName(line: []const u8, kind: []const u8) ?[]const u8 {
    const rest = if (std.mem.startsWith(u8, line, "pub ")) line["pub ".len..] else line;
    const prefix_len = kind.len + 1;
    if (rest.len <= prefix_len) return null;
    var name = std.mem.trim(u8, rest[prefix_len..], " \t");
    const end = std.mem.indexOfAny(u8, name, " (:=,{") orelse name.len;
    name = name[0..end];
    return if (name.len == 0) null else name;
}

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

pub fn zigPackageCacheDoctor(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    var paths = std.json.Array.init(allocator);
    const names = [_][]const u8{ ".zig-cache", "zig-out", ".zigar-cache", "zig-pkg", "coverage" };
    for (names) |name| try paths.append(try cachePathStatusValue(allocator, a, name));
    var issues = std.json.Array.init(allocator);
    for (names) |name| {
        const tracked = gitTracksPath(allocator, a, name, toolTimeout(a, args)) catch false;
        if (tracked) try issues.append(.{ .string = try std.fmt.allocPrint(allocator, "generated artifact path `{s}` is tracked by git", .{name}) });
    }
    if (a.workspace.readFileAlloc(a.io, "build.zig.zon", 1024 * 1024) catch null) |bytes| {
        defer allocator.free(bytes);
        const deps = dependencyInspectionValue(allocator, a, bytes) catch return error.OutOfMemory;
        try issues.appendSlice(deps.object.get("issues").?.array.items);
    }
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zig_package_cache_doctor" });
    try analysis_contract.putMetadata(allocator, &obj, "zig_package_cache_doctor");
    try obj.put(allocator, "paths", .{ .array = paths });
    try obj.put(allocator, "issues", .{ .array = issues });
    try obj.put(allocator, "resolution", .{ .string = "Cache directories should be workspace-local, ignored by git, and safe to delete/recreate when Zig package state becomes stale." });
    return structured(allocator, .{ .object = obj });
}

pub fn zigTestMap(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return structured(allocator, testMapValue(allocator, a, @intCast(@max(1, argInt(args, "limit", 500)))) catch return error.OutOfMemory);
}

pub fn zigTestSelect(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return structured(allocator, testSelectValue(allocator, a, argString(args, "files"), argString(args, "symbols"), @intCast(@max(1, argInt(args, "limit", 500)))) catch return error.OutOfMemory);
}

pub fn zigPublicApiDiff(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const file = argString(args, "file");
    var before_owned: ?[]u8 = null;
    defer if (before_owned) |bytes| allocator.free(bytes);
    var after_owned: ?[]u8 = null;
    defer if (after_owned) |bytes| allocator.free(bytes);

    const before_text = argString(args, "before") orelse blk: {
        const rel = file orelse break :blk "";
        const baseline_ref = argString(args, "baseline_ref") orelse "HEAD";
        const spec = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ baseline_ref, rel });
        defer allocator.free(spec);
        const result = command.run(allocator, a.io, a.workspace.root, &.{ "git", "show", spec }, @min(toolTimeout(a, args), 5000)) catch null;
        if (result) |r| {
            defer r.deinit(allocator);
            if (r.succeeded()) {
                before_owned = try allocator.dupe(u8, r.stdout);
                break :blk before_owned.?;
            }
        }
        break :blk "";
    };
    const after_text = argString(args, "after") orelse blk: {
        const rel = file orelse break :blk "";
        after_owned = a.workspace.readFileAlloc(a.io, rel, 4 * 1024 * 1024) catch break :blk "";
        break :blk after_owned.?;
    };
    return structured(allocator, publicApiDiffValue(allocator, file, before_text, after_text) catch return error.OutOfMemory);
}

pub fn testMapValue(allocator: std.mem.Allocator, a: *App, limit: usize) !std.json.Value {
    var tests = std.json.Array.init(allocator);
    var files = std.json.Array.init(allocator);
    var commands = std.json.Array.init(allocator);
    var seen_files = std.ArrayList([]const u8).empty;
    defer seen_files.deinit(allocator);
    defer freeStringList(allocator, seen_files.items);

    var dir = try std.Io.Dir.openDirAbsolute(a.io, a.workspace.root, .{ .iterate = true });
    defer dir.close(a.io);
    var walker = try dir.walk(allocator);
    defer walker.deinit();
    var count: usize = 0;
    var skipped_files: usize = 0;
    var walk_errors: usize = 0;
    while (true) {
        const maybe_entry = walker.next(a.io) catch {
            walk_errors += 1;
            break;
        };
        const entry = maybe_entry orelse break;
        if (count >= limit) break;
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".zig") or analysis.skipWorkspacePath(entry.path)) continue;
        const contents = a.workspace.readFileAlloc(a.io, entry.path, 512 * 1024) catch {
            skipped_files += 1;
            continue;
        };
        defer allocator.free(contents);
        var file_test_count: usize = 0;
        var lines = std.mem.splitScalar(u8, contents, '\n');
        var line_no: usize = 1;
        while (lines.next()) |line| : (line_no += 1) {
            if (count >= limit) break;
            const trimmed = std.mem.trim(u8, line, " \t");
            if (!std.mem.startsWith(u8, trimmed, "test ")) continue;
            count += 1;
            file_test_count += 1;
            var item = std.json.ObjectMap.empty;
            try item.put(allocator, "file", try ownedString(allocator, entry.path));
            try item.put(allocator, "line", .{ .integer = @intCast(line_no) });
            try item.put(allocator, "name", if (testNameFromLine(trimmed)) |name| try ownedString(allocator, name) else .null);
            try item.put(allocator, "declaration", try ownedString(allocator, trimmed));
            try item.put(allocator, "likely_symbols", try likelySymbolsFromTestNameValue(allocator, testNameFromLine(trimmed) orelse trimmed));
            try item.put(allocator, "command", .{ .string = try std.fmt.allocPrint(allocator, "zig test {s}", .{entry.path}) });
            try tests.append(.{ .object = item });
        }
        if (file_test_count > 0) {
            try appendUniqueString(allocator, &seen_files, entry.path);
            try files.append(try ownedString(allocator, entry.path));
            try appendUniqueCommand(allocator, &commands, try std.fmt.allocPrint(allocator, "zig test {s}", .{entry.path}));
        }
    }
    try appendUniqueCommand(allocator, &commands, "zig build test");
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zig_test_map" });
    try analysis_contract.putMetadata(allocator, &obj, "zig_test_map");
    try obj.put(allocator, "tests", .{ .array = tests });
    try obj.put(allocator, "test_files", .{ .array = files });
    try obj.put(allocator, "commands", .{ .array = commands });
    try obj.put(allocator, "count", .{ .integer = @intCast(count) });
    try obj.put(allocator, "skipped_files", .{ .integer = @intCast(skipped_files) });
    try obj.put(allocator, "walk_errors", .{ .integer = @intCast(walk_errors) });
    return .{ .object = obj };
}

pub fn testSelectValue(allocator: std.mem.Allocator, a: *App, files_text: ?[]const u8, symbols_text: ?[]const u8, limit: usize) !std.json.Value {
    var files = std.ArrayList([]const u8).empty;
    defer files.deinit(allocator);
    defer freeStringList(allocator, files.items);
    try appendPathTokens(allocator, &files, files_text);
    var symbols = std.ArrayList([]const u8).empty;
    defer symbols.deinit(allocator);
    defer freeStringList(allocator, symbols.items);
    try appendPathTokens(allocator, &symbols, symbols_text);

    var commands = std.json.Array.init(allocator);
    var reasons = std.json.Array.init(allocator);
    for (files.items) |file| {
        if (std.mem.endsWith(u8, file, ".zig") and workspacePathExists(allocator, a, file)) {
            try appendUniqueCommand(allocator, &commands, try std.fmt.allocPrint(allocator, "zig test {s}", .{file}));
            try reasons.append(.{ .string = try std.fmt.allocPrint(allocator, "{s}: touched Zig file", .{file}) });
        }
    }

    const map = try testMapValue(allocator, a, limit);
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
    try analysis_contract.putMetadata(allocator, &obj, "zig_test_select");
    try obj.put(allocator, "commands", .{ .array = commands });
    try obj.put(allocator, "reasons", .{ .array = reasons });
    try obj.put(allocator, "fallback", .{ .string = "zig build test" });
    return .{ .object = obj };
}

pub fn testNameFromLine(line: []const u8) ?[]const u8 {
    const rest = std.mem.trim(u8, line["test ".len..], " \t");
    if (rest.len == 0) return null;
    if (rest[0] == '"') return quotedString(rest);
    const end = std.mem.indexOfAny(u8, rest, " {(") orelse rest.len;
    return rest[0..end];
}

pub fn likelySymbolsFromTestNameValue(allocator: std.mem.Allocator, name: []const u8) !std.json.Value {
    var symbols = std.json.Array.init(allocator);
    var tokens = std.mem.tokenizeAny(u8, name, " .:_-/\t\r\n\"");
    while (tokens.next()) |token| {
        if (token.len < 3) continue;
        if (std.ascii.isUpper(token[0])) try symbols.append(try ownedString(allocator, token));
    }
    return .{ .array = symbols };
}

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
    try analysis_contract.putMetadata(allocator, &obj, "zig_public_api_diff");
    if (file) |path| try obj.put(allocator, "file", try ownedString(allocator, path)) else try obj.put(allocator, "file", .null);
    try obj.put(allocator, "before", before_decls);
    try obj.put(allocator, "after", after_decls);
    try obj.put(allocator, "added", .{ .array = added });
    try obj.put(allocator, "removed", .{ .array = removed });
    try obj.put(allocator, "changed", .{ .array = changed });
    try obj.put(allocator, "breaking_change_risk", .{ .bool = removed.items.len > 0 or changed.items.len > 0 });
    return .{ .object = obj };
}

pub fn publicDeclSnapshotValue(allocator: std.mem.Allocator, file: ?[]const u8, contents: []const u8) !std.json.Value {
    var decls = std.json.Array.init(allocator);
    var lines = std.mem.splitScalar(u8, contents, '\n');
    var line_no: usize = 1;
    while (lines.next()) |line| : (line_no += 1) {
        const trimmed = std.mem.trim(u8, line, " \t");
        if (!std.mem.startsWith(u8, trimmed, "pub ")) continue;
        const kind = analysis.declKind(trimmed) orelse continue;
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

pub fn findDeclByKey(array: std.json.Array, key: []const u8) ?std.json.Value {
    for (array.items) |item| {
        if (declKey(item)) |candidate| {
            if (std.mem.eql(u8, candidate, key)) return item;
        }
    }
    return null;
}

pub fn gitTracksPath(allocator: std.mem.Allocator, a: *App, path: []const u8, timeout_ms: i64) !bool {
    const result = command.run(allocator, a.io, a.workspace.root, &.{ "git", "ls-files", "--error-unmatch", path }, @min(timeout_ms, 3000)) catch return false;
    defer result.deinit(allocator);
    return result.succeeded();
}
