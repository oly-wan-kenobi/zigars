const std = @import("std");
const mcp = @import("mcp");
const zigar = @import("zigar");

const docs = zigar.docs;
const common = @import("common.zig");

const App = common.App;
const argString = common.argString;
const argInt = common.argInt;
const structuredOwned = common.structuredOwned;
const structuredText = common.structuredText;
const toolErrorFromError = common.toolErrorFromError;
const missingArgumentResult = common.missingArgumentResult;
const zigEnvValue = common.zigEnvValue;

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
    const value = docs.builtinListValue(allocator) catch return error.OutOfMemory;
    return structuredOwned(allocator, value);
}

pub fn zigBuiltinDoc(_: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const query = argString(args, "query") orelse return missingArgumentResult(allocator, "zig_builtin_doc", "query", "string");
    const output = docs.builtinDoc(allocator, query, @intCast(@max(1, argInt(args, "limit", 20)))) catch return error.OutOfMemory;
    defer allocator.free(output);
    return structuredText(allocator, "zig_builtin_doc", output);
}

pub fn zigBuiltinDocJson(_: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const query = argString(args, "query") orelse return missingArgumentResult(allocator, "zig_builtin_doc_json", "query", "string");
    const value = docs.builtinDocValue(allocator, query, @intCast(@max(1, argInt(args, "limit", 20)))) catch return error.OutOfMemory;
    return structuredOwned(allocator, value);
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
    const value = docs.stdSearchValue(allocator, a.io, std_dir, query, @intCast(@max(1, argInt(args, "limit", 20)))) catch |err| return docsError(allocator, "zig_std_search_json", "search_std_json", "scan_std_sources", "search_failed", err, query, "Confirm the Zig standard-library directory exists and is readable.");
    return structuredOwned(allocator, value);
}

pub fn zigStdItem(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const name = argString(args, "name") orelse return missingArgumentResult(allocator, "zig_std_item", "name", "string");
    const std_dir = zigEnvValue(a, allocator, "std_dir") catch |err| return docsError(allocator, "zig_std_item", "zig env", "resolve_std_dir", "zig_env_failed", err, name, "Confirm --zig-path points to a Zig executable that can report std_dir.");
    defer allocator.free(std_dir);
    const output = docs.stdItem(allocator, a.io, std_dir, name, @intCast(@max(1, argInt(args, "limit", 20)))) catch |err| return docsError(allocator, "zig_std_item", "std_item", "scan_std_sources", "search_failed", err, name, "Confirm the Zig standard-library directory is readable, then retry with a fully qualified std item.");
    defer allocator.free(output);
    return structuredText(allocator, "zig_std_item", output);
}

pub fn zigStdItemJson(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const name = argString(args, "name") orelse return missingArgumentResult(allocator, "zig_std_item_json", "name", "string");
    const std_dir = zigEnvValue(a, allocator, "std_dir") catch |err| return docsError(allocator, "zig_std_item_json", "zig env", "resolve_std_dir", "zig_env_failed", err, name, "Confirm --zig-path points to a Zig executable that can report std_dir.");
    defer allocator.free(std_dir);
    const value = docs.stdItemValue(allocator, a.io, std_dir, name, @intCast(@max(1, argInt(args, "limit", 20)))) catch |err| return docsError(allocator, "zig_std_item_json", "std_item_json", "scan_std_sources", "search_failed", err, name, "Confirm the Zig standard-library directory is readable, then retry with a fully qualified std item.");
    return structuredOwned(allocator, value);
}

pub fn zigLangRefSearch(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const query = argString(args, "query") orelse return missingArgumentResult(allocator, "zig_lang_ref_search", "query", "string");
    const lib_dir = zigEnvValue(a, allocator, "lib_dir") catch |err| return docsError(allocator, "zig_lang_ref_search", "zig env", "resolve_lib_dir", "zig_env_failed", err, query, "Confirm --zig-path points to a Zig executable that can report lib_dir.");
    defer allocator.free(lib_dir);
    const output = docs.langRefSearch(allocator, a.io, lib_dir, query, @intCast(@max(1, argInt(args, "limit", 20)))) catch |err| return docsError(allocator, "zig_lang_ref_search", "search_langref", "scan_langref", "search_failed", err, query, "Confirm the Zig language reference is readable, then retry with a narrower query if needed.");
    defer allocator.free(output);
    return structuredText(allocator, "zig_lang_ref_search", output);
}

pub fn zigLangRefSearchJson(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const query = argString(args, "query") orelse return missingArgumentResult(allocator, "zig_lang_ref_search_json", "query", "string");
    const lib_dir = zigEnvValue(a, allocator, "lib_dir") catch |err| return docsError(allocator, "zig_lang_ref_search_json", "zig env", "resolve_lib_dir", "zig_env_failed", err, query, "Confirm --zig-path points to a Zig executable that can report lib_dir.");
    defer allocator.free(lib_dir);
    const value = docs.langRefSearchValue(allocator, a.io, lib_dir, query, @intCast(@max(1, argInt(args, "limit", 20)))) catch |err| return docsError(allocator, "zig_lang_ref_search_json", "search_langref_json", "scan_langref", "search_failed", err, query, "Confirm the Zig language reference is readable, then retry with a narrower query if needed.");
    return structuredOwned(allocator, value);
}

pub fn readSourceArg(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) !struct { name: []const u8, bytes: []u8 } {
    _ = allocator;
    const file = argString(args, "file") orelse return error.MissingFile;
    const bytes = try a.workspace.readFileAlloc(a.io, file, 4 * 1024 * 1024);
    return .{ .name = file, .bytes = bytes };
}
