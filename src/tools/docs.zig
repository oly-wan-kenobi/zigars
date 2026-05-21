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
const source_read_limit = common.source_read_limit;

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

pub fn zigBuiltinList(a: *App, allocator: std.mem.Allocator, _: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    var context = builtinLookupContext(a, allocator) catch return error.OutOfMemory;
    defer context.deinit(allocator);
    const output = docs.builtinListWithInput(allocator, context.input) catch return error.OutOfMemory;
    defer allocator.free(output);
    return structuredText(allocator, "zig_builtin_list", output);
}

pub fn zigBuiltinListJson(a: *App, allocator: std.mem.Allocator, _: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    var context = builtinLookupContext(a, allocator) catch return error.OutOfMemory;
    defer context.deinit(allocator);
    const value = docs.builtinListValueWithInput(allocator, context.input) catch return error.OutOfMemory;
    return structuredOwned(allocator, value);
}

pub fn zigBuiltinDoc(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const query = argString(args, "query") orelse return missingArgumentResult(allocator, "zig_builtin_doc", "query", "string");
    var context = builtinLookupContext(a, allocator) catch return error.OutOfMemory;
    defer context.deinit(allocator);
    const output = docs.builtinDocWithInput(allocator, query, @intCast(@max(1, argInt(args, "limit", 20))), context.input) catch return error.OutOfMemory;
    defer allocator.free(output);
    return structuredText(allocator, "zig_builtin_doc", output);
}

pub fn zigBuiltinDocJson(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const query = argString(args, "query") orelse return missingArgumentResult(allocator, "zig_builtin_doc_json", "query", "string");
    var context = builtinLookupContext(a, allocator) catch return error.OutOfMemory;
    defer context.deinit(allocator);
    const value = docs.builtinDocValueWithInput(allocator, query, @intCast(@max(1, argInt(args, "limit", 20))), context.input) catch return error.OutOfMemory;
    return structuredOwned(allocator, value);
}

fn builtinToolchainVersionOrNull(a: *App, allocator: std.mem.Allocator) ?[]u8 {
    return zigEnvValue(a, allocator, "version") catch null;
}

const max_drift_name_sample = 16;

const BuiltinLookupContext = struct {
    input: docs.BuiltinIndexInput = .{},
    version: ?[]u8 = null,
    source_path: ?[]u8 = null,
    source: ?[]u8 = null,
    missing_names: ?[]const []const u8 = null,
    extra_names: ?[]const []const u8 = null,

    fn deinit(self: *BuiltinLookupContext, allocator: std.mem.Allocator) void {
        if (self.version) |bytes| allocator.free(bytes);
        if (self.source_path) |bytes| allocator.free(bytes);
        if (self.source) |bytes| allocator.free(bytes);
        if (self.missing_names) |items| allocator.free(items);
        if (self.extra_names) |items| allocator.free(items);
    }
};

fn builtinLookupContext(a: *App, allocator: std.mem.Allocator) !BuiltinLookupContext {
    var context: BuiltinLookupContext = .{ .version = builtinToolchainVersionOrNull(a, allocator) };
    if (zigEnvValue(a, allocator, "std_dir")) |std_dir| {
        defer allocator.free(std_dir);
        context.source_path = try std.fs.path.join(allocator, &.{ std_dir, "zig/BuiltinFn.zig" });
        context.source = std.Io.Dir.cwd().readFileAlloc(a.io, context.source_path.?, allocator, .limited(512 * 1024)) catch null;
    } else |_| {}

    var drift = docs.BuiltinDriftInfo{
        .status = if (context.version == null) "toolchain_version_unavailable" else "toolchain_builtin_source_unavailable",
        .confidence = if (context.version == null) "unavailable" else "version_only",
        .active_source_path = context.source_path,
    };
    if (context.source) |source| try fillBuiltinDrift(allocator, source, &context, &drift);
    context.input = .{ .toolchain_version = context.version, .drift = drift };
    return context;
}

fn fillBuiltinDrift(allocator: std.mem.Allocator, source: []const u8, context: *BuiltinLookupContext, drift: *docs.BuiltinDriftInfo) !void {
    const active_names = try parseActiveBuiltinNames(allocator, source);
    defer allocator.free(active_names);
    drift.active_count = active_names.len;
    drift.confidence = "source_backed";
    if (active_names.len == 0) {
        drift.status = "active_builtin_source_parse_failed";
        return;
    }
    var missing: std.ArrayList([]const u8) = .empty;
    var extra: std.ArrayList([]const u8) = .empty;
    defer missing.deinit(allocator);
    defer extra.deinit(allocator);
    for (docs.builtins) |item| {
        if (!nameIn(active_names, item.name)) {
            drift.curated_missing_count += 1;
            if (missing.items.len < max_drift_name_sample) try missing.append(allocator, item.name);
        }
    }
    for (active_names) |name| {
        if (!curatedBuiltinName(name)) {
            drift.active_extra_count += 1;
            if (extra.items.len < max_drift_name_sample) try extra.append(allocator, name);
        }
    }
    context.missing_names = try missing.toOwnedSlice(allocator);
    context.extra_names = try extra.toOwnedSlice(allocator);
    drift.missing_names = context.missing_names.?;
    drift.extra_names_sample = context.extra_names.?;
    drift.status = if (drift.curated_missing_count == 0) "curated_subset_matches_active_builtin_source" else "curated_entries_missing_from_active_builtin_source";
}

fn parseActiveBuiltinNames(allocator: std.mem.Allocator, source: []const u8) ![]const []const u8 {
    const list_start = std.mem.indexOf(u8, source, "pub const list") orelse return allocator.alloc([]const u8, 0);
    const list_end = std.mem.indexOfPos(u8, source, list_start, "});") orelse source.len;
    const list_source = source[list_start..list_end];
    var names: std.ArrayList([]const u8) = .empty;
    errdefer names.deinit(allocator);
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, list_source, pos, "\"@")) |hit| {
        const start = hit + 1;
        const end = std.mem.indexOfScalarPos(u8, list_source, start, '"') orelse break;
        const name = list_source[start..end];
        if (looksLikeBuiltinName(name) and !nameIn(names.items, name)) try names.append(allocator, name);
        pos = end + 1;
    }
    return names.toOwnedSlice(allocator);
}

fn looksLikeBuiltinName(name: []const u8) bool {
    if (name.len < 2 or name[0] != '@') return false;
    for (name[1..]) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
    }
    return true;
}

fn curatedBuiltinName(name: []const u8) bool {
    for (docs.builtins) |item| if (std.mem.eql(u8, item.name, name)) return true;
    return false;
}

fn nameIn(names: []const []const u8, needle: []const u8) bool {
    for (names) |name| if (std.mem.eql(u8, name, needle)) return true;
    return false;
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
    const bytes = try a.workspace.readFileAlloc(a.io, file, source_read_limit);
    return .{ .name = file, .bytes = bytes };
}

test "builtin drift parser compares curated names with offline BuiltinFn source" {
    const allocator = std.testing.allocator;
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(allocator);
    try source.appendSlice(allocator, "pub const list = list: { break :list std.StaticStringMap(BuiltinFn).initComptime([_]struct { []const u8, BuiltinFn }{\n");
    for (docs.builtins) |item| try source.print(allocator, ".{{ \"{s}\", .{{ .param_count = 1 }} }},\n", .{item.name});
    try source.appendSlice(allocator, ".{ \"@newBuiltin\", .{ .param_count = 0 } },\n}); };\n");

    var context: BuiltinLookupContext = .{};
    defer context.deinit(allocator);
    var drift = docs.BuiltinDriftInfo{ .status = "unchecked", .confidence = "none" };
    try fillBuiltinDrift(allocator, source.items, &context, &drift);

    try std.testing.expectEqualStrings("curated_subset_matches_active_builtin_source", drift.status);
    try std.testing.expectEqualStrings("source_backed", drift.confidence);
    try std.testing.expectEqual(@as(usize, docs.builtins.len + 1), drift.active_count);
    try std.testing.expectEqual(@as(usize, 0), drift.curated_missing_count);
    try std.testing.expectEqual(@as(usize, 1), drift.active_extra_count);
    try std.testing.expectEqualStrings("@newBuiltin", drift.extra_names_sample[0]);
}
