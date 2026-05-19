const std = @import("std");
const mcp = @import("mcp");
const zigar = @import("zigar");

const docs = zigar.docs;
const common = @import("common.zig");

const App = common.App;
const structured = common.structured;
const argString = common.argString;
const argInt = common.argInt;
const structuredText = common.structuredText;
const toolErrorFromError = common.toolErrorFromError;
const missingArgumentResult = common.missingArgumentResult;
const ownedString = common.ownedString;
const zigEnvValue = common.zigEnvValue;
const makeArgs2 = common.makeArgs2;
const asciiLowerAllocLocal = common.asciiLowerAllocLocal;
const lineNumberLocal = common.lineNumberLocal;
const lineAtLocal = common.lineAtLocal;

fn docsError(
    allocator: std.mem.Allocator,
    tool: []const u8,
    operation: []const u8,
    phase: []const u8,
    code: []const u8,
    err: anyerror,
    query: []const u8,
    resolution: []const u8,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    return toolErrorFromError(allocator, .{
        .tool = tool,
        .operation = operation,
        .phase = phase,
        .code = code,
        .category = "docs",
        .resolution = resolution,
        .details = &.{.{ .key = "query", .value = .{ .string = query } }},
    }, err);
}

pub fn zigBuiltinList(_: *App, allocator: std.mem.Allocator, _: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const output = docs.builtinList(allocator) catch return error.OutOfMemory;
    defer allocator.free(output);
    return structuredText(allocator, "zig_builtin_list", output);
}

pub fn zigBuiltinListJson(_: *App, allocator: std.mem.Allocator, _: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    var items = std.json.Array.init(allocator);
    for (docs.builtins) |item| {
        var obj = std.json.ObjectMap.empty;
        obj.put(allocator, "name", .{ .string = item.name }) catch return error.OutOfMemory;
        obj.put(allocator, "signature", .{ .string = item.signature }) catch return error.OutOfMemory;
        obj.put(allocator, "summary", .{ .string = item.summary }) catch return error.OutOfMemory;
        items.append(.{ .object = obj }) catch return error.OutOfMemory;
    }
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    obj.put(allocator, "source", docs.docs_source.value(allocator, docs.docs_source.curatedBuiltins()) catch return error.OutOfMemory) catch return error.OutOfMemory;
    obj.put(allocator, "count", .{ .integer = @intCast(docs.builtins.len) }) catch return error.OutOfMemory;
    obj.put(allocator, "builtins", .{ .array = items }) catch return error.OutOfMemory;
    return structured(allocator, .{ .object = obj });
}

pub fn zigBuiltinDoc(_: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const query = argString(args, "query") orelse return missingArgumentResult(allocator, "zig_builtin_doc", "query", "string");
    const output = docs.builtinDoc(allocator, query) catch return error.OutOfMemory;
    defer allocator.free(output);
    return structuredText(allocator, "zig_builtin_doc", output);
}

pub fn zigStdSearch(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const query = argString(args, "query") orelse return missingArgumentResult(allocator, "zig_std_search", "query", "string");
    const std_dir = zigEnvValue(a, allocator, "std_dir") catch |err| return docsError(allocator, "zig_std_search", "zig env", "resolve_std_dir", "zig_env_failed", err, query, "Confirm --zig-path points to a Zig executable that can report std_dir.");
    defer allocator.free(std_dir);
    const output = docs.searchStd(allocator, a.io, std_dir, query, @intCast(@max(1, argInt(args, "limit", 20)))) catch |err| return docsError(allocator, "zig_std_search", "search_std", "scan_std_sources", "search_failed", err, query, "Confirm the Zig standard-library directory is readable, then retry with a narrower query if needed.");
    defer allocator.free(output);
    return structuredText(allocator, "zig_std_search", output);
}

pub fn zigStdSearchJson(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const query = argString(args, "query") orelse return missingArgumentResult(allocator, "zig_std_search_json", "query", "string");
    const std_dir = zigEnvValue(a, allocator, "std_dir") catch |err| return docsError(allocator, "zig_std_search_json", "zig env", "resolve_std_dir", "zig_env_failed", err, query, "Confirm --zig-path points to a Zig executable that can report std_dir.");
    defer allocator.free(std_dir);
    return searchZigFilesJson(allocator, a.io, std_dir, "std", query, @intCast(@max(1, argInt(args, "limit", 20))));
}

pub fn searchZigFilesJson(allocator: std.mem.Allocator, io: std.Io, root: []const u8, label: []const u8, query: []const u8, limit: usize) mcp.tools.ToolError!mcp.tools.ToolResult {
    const lower_query = asciiLowerAllocLocal(allocator, query) catch return error.OutOfMemory;
    defer allocator.free(lower_query);
    var matches = std.json.Array.init(allocator);
    var dir = std.Io.Dir.openDirAbsolute(io, root, .{ .iterate = true }) catch |err| return docsError(allocator, "zig_std_search_json", "search_std_json", "open_root", "docs_root_open_failed", err, query, "Confirm the Zig standard-library directory exists and is readable.");
    defer dir.close(io);
    var walker = dir.walk(allocator) catch |err| return docsError(allocator, "zig_std_search_json", "search_std_json", "walk_root", "docs_root_walk_failed", err, query, "Confirm the Zig standard-library directory can be traversed.");
    defer walker.deinit();
    var count: usize = 0;
    var skipped_files: usize = 0;
    var walk_errors: usize = 0;
    while (true) {
        const maybe_entry = walker.next(io) catch {
            walk_errors += 1;
            break;
        };
        const entry = maybe_entry orelse break;
        if (count >= limit) break;
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".zig")) continue;
        const abs = std.fs.path.join(allocator, &.{ root, entry.path }) catch return error.OutOfMemory;
        defer allocator.free(abs);
        const contents = std.Io.Dir.cwd().readFileAlloc(io, abs, allocator, .limited(512 * 1024)) catch {
            skipped_files += 1;
            continue;
        };
        defer allocator.free(contents);
        const lower = asciiLowerAllocLocal(allocator, contents) catch return error.OutOfMemory;
        defer allocator.free(lower);
        const hit = std.mem.indexOf(u8, lower, lower_query) orelse continue;
        count += 1;
        var obj = std.json.ObjectMap.empty;
        obj.put(allocator, "root", .{ .string = label }) catch return error.OutOfMemory;
        obj.put(allocator, "path", ownedString(allocator, entry.path) catch return error.OutOfMemory) catch return error.OutOfMemory;
        obj.put(allocator, "line", .{ .integer = @intCast(lineNumberLocal(contents, hit)) }) catch return error.OutOfMemory;
        obj.put(allocator, "snippet", ownedString(allocator, lineAtLocal(contents, hit)) catch return error.OutOfMemory) catch return error.OutOfMemory;
        matches.append(.{ .object = obj }) catch return error.OutOfMemory;
    }
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    obj.put(allocator, "source", docs.docs_source.value(allocator, docs.docs_source.stdlibSource(root, null)) catch return error.OutOfMemory) catch return error.OutOfMemory;
    obj.put(allocator, "query", .{ .string = query }) catch return error.OutOfMemory;
    obj.put(allocator, "limit", .{ .integer = @intCast(limit) }) catch return error.OutOfMemory;
    obj.put(allocator, "skipped_files", .{ .integer = @intCast(skipped_files) }) catch return error.OutOfMemory;
    obj.put(allocator, "walk_errors", .{ .integer = @intCast(walk_errors) }) catch return error.OutOfMemory;
    obj.put(allocator, "matches", .{ .array = matches }) catch return error.OutOfMemory;
    return structured(allocator, .{ .object = obj });
}

pub fn zigStdItem(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const name = argString(args, "name") orelse return missingArgumentResult(allocator, "zig_std_item", "name", "string");
    return zigStdSearch(a, allocator, makeArgs2(allocator, "query", name, "limit", argInt(args, "limit", 20)) catch return error.OutOfMemory);
}

pub fn zigLangRefSearch(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const query = argString(args, "query") orelse return missingArgumentResult(allocator, "zig_lang_ref_search", "query", "string");
    const lib_dir = zigEnvValue(a, allocator, "lib_dir") catch |err| return docsError(allocator, "zig_lang_ref_search", "zig env", "resolve_lib_dir", "zig_env_failed", err, query, "Confirm --zig-path points to a Zig executable that can report lib_dir.");
    defer allocator.free(lib_dir);
    const output = docs.langRefSearch(allocator, a.io, lib_dir, query, @intCast(@max(1, argInt(args, "limit", 20)))) catch |err| return docsError(allocator, "zig_lang_ref_search", "search_langref", "scan_langref", "search_failed", err, query, "Confirm the Zig language reference is readable, then retry with a narrower query if needed.");
    defer allocator.free(output);
    return structuredText(allocator, "zig_lang_ref_search", output);
}

pub fn readSourceArg(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) !struct { name: []const u8, bytes: []u8 } {
    _ = allocator;
    const file = argString(args, "file") orelse return error.MissingFile;
    const bytes = try a.workspace.readFileAlloc(a.io, file, 4 * 1024 * 1024);
    return .{ .name = file, .bytes = bytes };
}
