const std = @import("std");
const mcp = @import("mcp");
const zigar = @import("zigar");

const analysis = zigar.analysis;
const analysis_contract = zigar.analysis_contract;
const command = zigar.command;
const evidence = zigar.evidence;
const json_result = zigar.json_result;
const common = @import("common.zig");
const lint_intelligence = @import("lint_intelligence.zig");
const static_tests = @import("static_tests.zig");

const App = common.App;
const structured = common.structured;
const argString = common.argString;
const argBool = common.argBool;
const argInt = common.argInt;
const missingArgumentResult = common.missingArgumentResult;
const workspacePathErrorResult = common.workspacePathErrorResult;
const toolErrorFromError = common.toolErrorFromError;
const scratchApp = common.scratchApp;
const toolTimeout = common.toolTimeout;

const semantic_format_version = 1;

const ParseStats = struct {
    partial_result: bool,
    parse_error_count: i64,
};

fn semanticError(allocator: std.mem.Allocator, tool_name: []const u8, phase: []const u8, err: anyerror) mcp.tools.ToolError!mcp.tools.ToolResult {
    return toolErrorFromError(allocator, .{
        .tool = tool_name,
        .operation = "semantic_index",
        .phase = phase,
        .code = "semantic_index_failed",
        .category = "static_analysis",
        .resolution = "Retry with a smaller limit or refresh=true; inspect unreadable Zig files if the failure repeats.",
    }, err);
}

pub fn zigSemanticIndexBuild(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return semanticIndexResult(a, allocator, args, "zig_semantic_index_build", argBool(args, "refresh", false));
}

pub fn zigSemanticIndexRefresh(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return semanticIndexResult(a, allocator, args, "zig_semantic_index_refresh", true);
}

pub fn zigSemanticIndexStatus(a: *App, allocator: std.mem.Allocator, _: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zig_semantic_index_status" });
    try analysis_contract.putMetadata(allocator, &obj, "zig_semantic_index_status");
    try obj.put(allocator, "format_version", .{ .integer = semantic_format_version });
    try obj.put(allocator, "cached", .{ .bool = a.semantic_index_cache.index_json != null });
    try obj.put(allocator, "signature", .{ .integer = signatureInteger(a.semantic_index_cache.signature) });
    try obj.put(allocator, "hits", .{ .integer = @intCast(a.semantic_index_cache.hits) });
    try obj.put(allocator, "refreshes", .{ .integer = @intCast(a.semantic_index_cache.refreshes) });
    try obj.put(allocator, "evidence_sources", try evidence.sourceArrayValue(allocator, &.{ .parser, .heuristic, .profile }));
    return structured(allocator, .{ .object = obj });
}

fn semanticIndexResult(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value, tool_name: []const u8, force_refresh: bool) mcp.tools.ToolError!mcp.tools.ToolResult {
    ensureSemanticIndexCache(a, allocator, args, tool_name, force_refresh) catch |err| return semanticError(allocator, tool_name, "build_or_read", err);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const parsed = std.json.parseFromSlice(std.json.Value, scratch, a.semantic_index_cache.index_json.?, .{}) catch |err| return semanticError(allocator, tool_name, "parse_cache", err);
    defer parsed.deinit();
    var obj = switch (parsed.value) {
        .object => |o| o,
        else => std.json.ObjectMap.empty,
    };
    try obj.put(scratch, "cache", try semanticCacheStatusValue(scratch, a));
    return structured(allocator, .{ .object = obj });
}

fn ensureSemanticIndexCache(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value, tool_name: []const u8, force_refresh: bool) !void {
    const limit: usize = @intCast(@max(1, argInt(args, "limit", 500)));
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    var scratch_app = scratchApp(a, scratch);
    const signature = try semanticSignature(scratch, &scratch_app, limit);
    if (force_refresh or a.semantic_index_cache.index_json == null or a.semantic_index_cache.signature != signature) {
        const index = try semanticIndexValue(scratch, &scratch_app, limit, tool_name);
        var bytes_list: std.ArrayList(u8) = .empty;
        errdefer bytes_list.deinit(allocator);
        try json_result.serializeValue(allocator, &bytes_list, index);
        const bytes = try bytes_list.toOwnedSlice(allocator);
        defer allocator.free(bytes);
        const cached_bytes = try a.allocator.dupe(u8, bytes);
        if (a.semantic_index_cache.index_json) |old| a.allocator.free(old);
        a.semantic_index_cache.index_json = cached_bytes;
        a.semantic_index_cache.signature = signature;
        a.semantic_index_cache.refreshes += 1;
    } else {
        a.semantic_index_cache.hits += 1;
    }
}

pub fn semanticSignature(allocator: std.mem.Allocator, a: *App, limit: usize) !u64 {
    var hasher = std.hash.Wyhash.init(semantic_format_version);
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
        const bytes = a.workspace.readFileAlloc(a.io, entry.path, 512 * 1024) catch continue;
        defer allocator.free(bytes);
        hasher.update(bytes);
    }
    return hasher.final();
}

pub fn semanticIndexValue(allocator: std.mem.Allocator, a: *App, limit: usize, tool_name: []const u8) !std.json.Value {
    var files = std.json.Array.init(allocator);
    var declarations = std.json.Array.init(allocator);
    var imports = std.json.Array.init(allocator);
    var tests = std.json.Array.init(allocator);
    var skipped = std.json.Array.init(allocator);
    var dir = try std.Io.Dir.openDirAbsolute(a.io, a.workspace.root, .{ .iterate = true });
    defer dir.close(a.io);
    var walker = try dir.walk(allocator);
    defer walker.deinit();
    var seen: usize = 0;
    var walk_errors: usize = 0;
    var partial_result = false;
    var parse_error_count: i64 = 0;
    while (true) {
        const maybe_entry = walker.next(a.io) catch {
            walk_errors += 1;
            break;
        };
        const entry = maybe_entry orelse break;
        if (seen >= limit) break;
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".zig") or analysis.skipWorkspacePath(entry.path)) continue;
        const contents = a.workspace.readFileAlloc(a.io, entry.path, 512 * 1024) catch |err| {
            try skipped.append(try skippedFileValue(allocator, entry.path, err));
            continue;
        };
        defer allocator.free(contents);
        seen += 1;
        const stats = try appendFileIndex(allocator, entry.path, contents, &files, &declarations, &imports, &tests);
        partial_result = partial_result or stats.partial_result;
        parse_error_count += stats.parse_error_count;
    }
    partial_result = partial_result or skipped.items.len > 0 or walk_errors > 0;

    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = tool_name });
    try analysis_contract.putMetadata(allocator, &obj, tool_name);
    try obj.put(allocator, "format", .{ .string = "zigar.semantic_index" });
    try obj.put(allocator, "format_version", .{ .integer = semantic_format_version });
    try obj.put(allocator, "parse_status", .{ .string = if (parse_error_count > 0) "syntax_errors" else if (partial_result) "partial" else "ok" });
    try obj.put(allocator, "partial_result", .{ .bool = partial_result });
    try obj.put(allocator, "result_complete", .{ .bool = !partial_result });
    try obj.put(allocator, "parse_error_count", .{ .integer = parse_error_count });
    try obj.put(allocator, "evidence_sources", try evidence.sourceArrayValue(allocator, &.{ .parser, .heuristic, .profile }));
    try obj.put(allocator, "files", .{ .array = files });
    try obj.put(allocator, "declarations", .{ .array = declarations });
    try obj.put(allocator, "imports", .{ .array = imports });
    try obj.put(allocator, "tests", .{ .array = tests });
    try obj.put(allocator, "build_targets", try buildTargetsValue(allocator));
    try obj.put(allocator, "file_count", .{ .integer = @intCast(seen) });
    try obj.put(allocator, "declaration_count", .{ .integer = @intCast(declarations.items.len) });
    try obj.put(allocator, "import_count", .{ .integer = @intCast(imports.items.len) });
    try obj.put(allocator, "test_count", .{ .integer = @intCast(tests.items.len) });
    try obj.put(allocator, "skipped_files", .{ .array = skipped });
    try obj.put(allocator, "skipped_file_count", .{ .integer = @intCast(skipped.items.len) });
    try obj.put(allocator, "walk_errors", .{ .integer = @intCast(walk_errors) });
    return .{ .object = obj };
}

fn appendFileIndex(allocator: std.mem.Allocator, file: []const u8, contents: []const u8, files: *std.json.Array, declarations: *std.json.Array, imports: *std.json.Array, tests: *std.json.Array) !ParseStats {
    const ast_decls = analysis.astDeclSummaryJson(allocator, file, contents) catch null;
    const ast_imports = analysis.astImportsJson(allocator, file, contents) catch null;
    const ast_tests = analysis.astTestsJson(allocator, file, contents) catch null;
    const stats = parseStatsValue(ast_decls);
    var file_decls = std.json.Array.init(allocator);
    var file_imports = std.json.Array.init(allocator);
    var file_tests = std.json.Array.init(allocator);
    if (ast_decls) |value| {
        if (arrayField(value, "declarations")) |decls| for (decls.items) |decl| {
            const item = try semanticDeclValue(allocator, file, decl, .parser);
            try file_decls.append(item);
            try declarations.append(item);
        };
    } else try appendHeuristicDecls(allocator, file, contents, &file_decls, declarations);
    if (ast_imports) |value| {
        if (arrayField(value, "imports")) |imports_array| for (imports_array.items) |import_value| {
            const item = try semanticImportValue(allocator, file, import_value, .parser);
            try file_imports.append(item);
            try imports.append(item);
        };
    }
    if (ast_tests) |value| {
        if (arrayField(value, "tests")) |tests_array| for (tests_array.items) |test_value| {
            const item = try semanticTestValue(allocator, file, test_value, .parser);
            try file_tests.append(item);
            try tests.append(item);
        };
    }
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "file", try evidence.ownedString(allocator, file));
    try obj.put(allocator, "parse_status", parseStatusValue(ast_decls));
    try obj.put(allocator, "partial_result", .{ .bool = stats.partial_result });
    try obj.put(allocator, "result_complete", .{ .bool = !stats.partial_result });
    try obj.put(allocator, "parse_error_count", .{ .integer = stats.parse_error_count });
    try obj.put(allocator, "source_evidence", try evidence.sourceArrayValue(allocator, if (ast_decls != null) &.{ .parser, .heuristic } else &.{.heuristic}));
    try obj.put(allocator, "declarations", .{ .array = file_decls });
    try obj.put(allocator, "imports", .{ .array = file_imports });
    try obj.put(allocator, "tests", .{ .array = file_tests });
    try files.append(.{ .object = obj });
    return stats;
}

fn appendHeuristicDecls(allocator: std.mem.Allocator, file: []const u8, contents: []const u8, file_decls: *std.json.Array, declarations: *std.json.Array) !void {
    var lines = std.mem.splitScalar(u8, contents, '\n');
    var line_no: usize = 1;
    while (lines.next()) |line| : (line_no += 1) {
        const trimmed = std.mem.trim(u8, line, " \t");
        const kind = analysis.declKind(trimmed) orelse continue;
        var raw = std.json.ObjectMap.empty;
        try raw.put(allocator, "line", .{ .integer = @intCast(line_no) });
        try raw.put(allocator, "kind", .{ .string = kind });
        try raw.put(allocator, "name", if (static_tests.declName(trimmed, kind)) |name| try evidence.ownedString(allocator, name) else .null);
        try raw.put(allocator, "public", .{ .bool = std.mem.startsWith(u8, trimmed, "pub ") });
        try raw.put(allocator, "signature", try evidence.ownedString(allocator, trimmed));
        const item = try semanticDeclValue(allocator, file, .{ .object = raw }, .heuristic);
        try file_decls.append(item);
        try declarations.append(item);
    }
}

fn semanticDeclValue(allocator: std.mem.Allocator, file: []const u8, decl: std.json.Value, source: evidence.Source) !std.json.Value {
    const obj = switch (decl) {
        .object => |o| o,
        else => std.json.ObjectMap.empty,
    };
    const line: usize = @intCast(@max(evidence.integerField(obj, "line") orelse 1, 1));
    const kind = evidence.stringField(obj, "kind") orelse "decl";
    const name = evidence.stringField(obj, "name") orelse "";
    const signature = evidence.stringField(obj, "signature") orelse "";
    var out = std.json.ObjectMap.empty;
    errdefer out.deinit(allocator);
    try out.put(allocator, "file", try evidence.ownedString(allocator, file));
    try out.put(allocator, "line", .{ .integer = @intCast(line) });
    try out.put(allocator, "kind", try evidence.ownedString(allocator, kind));
    try out.put(allocator, "name", if (name.len > 0) try evidence.ownedString(allocator, name) else .null);
    try out.put(allocator, "public", obj.get("public") orelse .null);
    try out.put(allocator, "signature", try evidence.ownedString(allocator, signature));
    try out.put(allocator, "location", try evidence.locationValue(allocator, file, line, 1));
    try out.put(allocator, "source", .{ .string = evidence.sourceName(source) });
    try out.put(allocator, "confidence", .{ .string = if (source == .parser) "high" else "medium" });
    try out.put(allocator, "evidence", try evidence.evidenceValue(allocator, source, if (source == .parser) .high else .medium, "Declaration recovered from workspace source.", &.{ "ZLS definition", "zig ast-check" }));
    return .{ .object = out };
}

fn semanticImportValue(allocator: std.mem.Allocator, file: []const u8, import_value: std.json.Value, source: evidence.Source) !std.json.Value {
    const obj = switch (import_value) {
        .object => |o| o,
        else => std.json.ObjectMap.empty,
    };
    const line: usize = @intCast(@max(evidence.integerField(obj, "line") orelse 1, 1));
    var out = std.json.ObjectMap.empty;
    errdefer out.deinit(allocator);
    try out.put(allocator, "file", try evidence.ownedString(allocator, file));
    try out.put(allocator, "line", .{ .integer = @intCast(line) });
    try out.put(allocator, "import", if (evidence.stringField(obj, "import")) |value| try evidence.ownedString(allocator, value) else .null);
    try out.put(allocator, "alias", obj.get("alias") orelse .null);
    try out.put(allocator, "source", .{ .string = evidence.sourceName(source) });
    try out.put(allocator, "confidence", .{ .string = if (source == .parser) "high" else "medium" });
    try out.put(allocator, "evidence", try evidence.evidenceValue(allocator, source, if (source == .parser) .high else .medium, "Import recovered from workspace source.", &.{ "zig_ast_imports", "zig build test" }));
    return .{ .object = out };
}

fn semanticTestValue(allocator: std.mem.Allocator, file: []const u8, test_value: std.json.Value, source: evidence.Source) !std.json.Value {
    const obj = switch (test_value) {
        .object => |o| o,
        else => std.json.ObjectMap.empty,
    };
    const line: usize = @intCast(@max(evidence.integerField(obj, "line") orelse 1, 1));
    var out = std.json.ObjectMap.empty;
    errdefer out.deinit(allocator);
    try out.put(allocator, "file", try evidence.ownedString(allocator, file));
    try out.put(allocator, "line", .{ .integer = @intCast(line) });
    try out.put(allocator, "name", obj.get("name") orelse .null);
    try out.put(allocator, "command", if (evidence.stringField(obj, "command")) |value| try evidence.ownedString(allocator, value) else .null);
    try out.put(allocator, "source", .{ .string = evidence.sourceName(source) });
    try out.put(allocator, "confidence", .{ .string = if (source == .parser) "high" else "medium" });
    try out.put(allocator, "evidence", try evidence.evidenceValue(allocator, source, if (source == .parser) .high else .medium, "Test declaration recovered from workspace source.", &.{ "zig_ast_tests", "zig test <file>" }));
    return .{ .object = out };
}

fn parseStatusValue(value: ?std.json.Value) std.json.Value {
    if (value) |v| {
        const obj = switch (v) {
            .object => |o| o,
            else => return .{ .string = "heuristic_fallback" },
        };
        return switch (obj.get("parse_status") orelse .null) {
            .string => |s| .{ .string = s },
            else => .{ .string = "ok" },
        };
    }
    return .{ .string = "heuristic_fallback" };
}

fn parseStatsValue(value: ?std.json.Value) ParseStats {
    const v = value orelse return .{ .partial_result = true, .parse_error_count = 0 };
    const obj = switch (v) {
        .object => |o| o,
        else => return .{ .partial_result = true, .parse_error_count = 0 },
    };
    const partial = switch (obj.get("partial_result") orelse .null) {
        .bool => |b| b,
        else => false,
    };
    return .{
        .partial_result = partial,
        .parse_error_count = evidence.integerField(obj, "parse_error_count") orelse 0,
    };
}

fn arrayField(value: std.json.Value, field: []const u8) ?std.json.Array {
    const obj = switch (value) {
        .object => |o| o,
        else => return null,
    };
    return switch (obj.get(field) orelse .null) {
        .array => |array| array,
        else => null,
    };
}

fn semanticCacheStatusValue(allocator: std.mem.Allocator, a: *App) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "cached", .{ .bool = a.semantic_index_cache.index_json != null });
    try obj.put(allocator, "hits", .{ .integer = @intCast(a.semantic_index_cache.hits) });
    try obj.put(allocator, "refreshes", .{ .integer = @intCast(a.semantic_index_cache.refreshes) });
    try obj.put(allocator, "signature", .{ .integer = signatureInteger(a.semantic_index_cache.signature) });
    return .{ .object = obj };
}

fn signatureInteger(signature: u64) i64 {
    return @intCast(signature & @as(u64, std.math.maxInt(i64)));
}

fn skippedFileValue(allocator: std.mem.Allocator, path: []const u8, err: anyerror) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "path", try evidence.ownedString(allocator, path));
    try obj.put(allocator, "error", try evidence.ownedString(allocator, @errorName(err)));
    return .{ .object = obj };
}

fn buildTargetsValue(allocator: std.mem.Allocator) !std.json.Value {
    var array = std.json.Array.init(allocator);
    try array.append(try evidence.ownedString(allocator, "zig build"));
    try array.append(try evidence.ownedString(allocator, "zig build test"));
    return .{ .array = array };
}

pub fn zigSemanticQuery(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const query = argString(args, "query") orelse return missingArgumentResult(allocator, "zig_semantic_query", "query", "symbol, import, test, or file substring");
    ensureSemanticIndexCache(a, allocator, args, "zig_semantic_query", argBool(args, "refresh", false)) catch |err| return semanticError(allocator, "zig_semantic_query", "query_index", err);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const parsed = std.json.parseFromSlice(std.json.Value, scratch, a.semantic_index_cache.index_json.?, .{}) catch |err| return semanticError(allocator, "zig_semantic_query", "parse_cache", err);
    defer parsed.deinit();
    const matches = semanticMatchesValue(scratch, parsed.value, query, argString(args, "kind"), @intCast(@max(1, argInt(args, "limit", 50)))) catch return error.OutOfMemory;
    var obj = std.json.ObjectMap.empty;
    try obj.put(scratch, "kind", .{ .string = "zig_semantic_query" });
    try analysis_contract.putMetadata(scratch, &obj, "zig_semantic_query");
    try obj.put(scratch, "query", try evidence.ownedString(scratch, query));
    try obj.put(scratch, "matches", matches);
    return structured(allocator, .{ .object = obj });
}

pub fn zigSemanticDecl(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const symbol = argString(args, "symbol") orelse return missingArgumentResult(allocator, "zig_semantic_decl", "symbol", "declaration name");
    ensureSemanticIndexCache(a, allocator, args, "zig_semantic_decl", argBool(args, "refresh", false)) catch |err| return semanticError(allocator, "zig_semantic_decl", "decl_index", err);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const parsed = std.json.parseFromSlice(std.json.Value, scratch, a.semantic_index_cache.index_json.?, .{}) catch |err| return semanticError(allocator, "zig_semantic_decl", "parse_cache", err);
    defer parsed.deinit();
    const matches = semanticMatchesValue(scratch, parsed.value, symbol, "declaration", @intCast(@max(1, argInt(args, "limit", 20)))) catch return error.OutOfMemory;
    var obj = std.json.ObjectMap.empty;
    try obj.put(scratch, "kind", .{ .string = "zig_semantic_decl" });
    try analysis_contract.putMetadata(scratch, &obj, "zig_semantic_decl");
    try obj.put(scratch, "symbol", try evidence.ownedString(scratch, symbol));
    try obj.put(scratch, "declarations", matches);
    return structured(allocator, .{ .object = obj });
}

fn semanticMatchesValue(allocator: std.mem.Allocator, index: std.json.Value, query: []const u8, kind_filter: ?[]const u8, limit: usize) !std.json.Value {
    const lower_query = try std.ascii.allocLowerString(allocator, query);
    var matches = std.json.Array.init(allocator);
    const root = switch (index) {
        .object => |o| o,
        else => return .{ .array = matches },
    };
    try appendMatchesFromArray(allocator, &matches, root.get("declarations") orelse .null, lower_query, "declaration", kind_filter, limit);
    try appendMatchesFromArray(allocator, &matches, root.get("imports") orelse .null, lower_query, "import", kind_filter, limit);
    try appendMatchesFromArray(allocator, &matches, root.get("tests") orelse .null, lower_query, "test", kind_filter, limit);
    return .{ .array = matches };
}

fn appendMatchesFromArray(allocator: std.mem.Allocator, matches: *std.json.Array, value: std.json.Value, lower_query: []const u8, match_kind: []const u8, kind_filter: ?[]const u8, limit: usize) !void {
    if (matches.items.len >= limit) return;
    if (kind_filter) |filter| if (!std.mem.eql(u8, filter, match_kind) and !std.mem.eql(u8, filter, "any")) return;
    const array = switch (value) {
        .array => |a| a,
        else => return,
    };
    for (array.items) |item| {
        if (matches.items.len >= limit) break;
        const text = try searchableText(allocator, item);
        const lower_text = try std.ascii.allocLowerString(allocator, text);
        if (std.mem.indexOf(u8, lower_text, lower_query) == null) continue;
        var obj = std.json.ObjectMap.empty;
        try obj.put(allocator, "match_kind", try evidence.ownedString(allocator, match_kind));
        try obj.put(allocator, "item", item);
        try matches.append(.{ .object = obj });
    }
}

fn searchableText(allocator: std.mem.Allocator, value: std.json.Value) ![]const u8 {
    const obj = switch (value) {
        .object => |o| o,
        else => return "",
    };
    return std.fmt.allocPrint(allocator, "{s} {s} {s} {s}", .{
        evidence.stringField(obj, "file") orelse "",
        evidence.stringField(obj, "name") orelse "",
        evidence.stringField(obj, "import") orelse "",
        evidence.stringField(obj, "signature") orelse "",
    });
}

pub fn zigSemanticRefs(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const symbol = argString(args, "symbol") orelse return missingArgumentResult(allocator, "zig_semantic_refs", "symbol", "symbol name");
    return sourceScanResult(a, allocator, args, "zig_semantic_refs", symbol, false);
}

pub fn zigSemanticCallers(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const symbol = argString(args, "symbol") orelse return missingArgumentResult(allocator, "zig_semantic_callers", "symbol", "function name");
    return sourceScanResult(a, allocator, args, "zig_semantic_callers", symbol, true);
}

fn sourceScanResult(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value, tool_name: []const u8, symbol: []const u8, calls_only: bool) mcp.tools.ToolError!mcp.tools.ToolResult {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var scratch_app = scratchApp(a, arena.allocator());
    const refs = sourceScanValue(arena.allocator(), &scratch_app, args, tool_name, symbol, calls_only, @intCast(@max(1, argInt(args, "limit", 100)))) catch |err| return semanticError(allocator, tool_name, "scan_sources", err);
    return structured(allocator, refs);
}

fn sourceScanValue(allocator: std.mem.Allocator, a: *App, args: ?std.json.Value, tool_name: []const u8, symbol: []const u8, calls_only: bool, limit: usize) !std.json.Value {
    var matches = std.json.Array.init(allocator);
    var dir = try std.Io.Dir.openDirAbsolute(a.io, a.workspace.root, .{ .iterate = true });
    defer dir.close(a.io);
    var walker = try dir.walk(allocator);
    defer walker.deinit();
    var zlint_ast_files: usize = 0;
    var zlint_ast_failures: usize = 0;
    var zlint_disabled = false;
    while (try walker.next(a.io)) |entry| {
        if (matches.items.len >= limit) break;
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".zig") or analysis.skipWorkspacePath(entry.path)) continue;
        const contents = a.workspace.readFileAlloc(a.io, entry.path, 512 * 1024) catch continue;
        defer allocator.free(contents);
        var zlint_confirmed = false;
        if (!zlint_disabled and std.mem.indexOf(u8, contents, symbol) != null) {
            zlint_confirmed = zlintAstSymbolHasReferenceForFile(allocator, a, args, entry.path, symbol, calls_only) catch blk: {
                zlint_ast_failures += 1;
                zlint_disabled = true;
                break :blk false;
            };
            if (!zlint_disabled) zlint_ast_files += 1;
        }
        var lines = std.mem.splitScalar(u8, contents, '\n');
        var line_no: usize = 1;
        while (lines.next()) |line| : (line_no += 1) {
            if (matches.items.len >= limit) break;
            if (std.mem.indexOf(u8, line, symbol) == null) continue;
            if (calls_only and std.mem.indexOf(u8, line, "(") == null) continue;
            if (calls_only and analysis.declKind(std.mem.trim(u8, line, " \t")) != null) continue;
            var item = std.json.ObjectMap.empty;
            try item.put(allocator, "file", try evidence.ownedString(allocator, entry.path));
            try item.put(allocator, "line", .{ .integer = @intCast(line_no) });
            try item.put(allocator, "text", try evidence.ownedString(allocator, std.mem.trim(u8, line, " \t")));
            try item.put(allocator, "location", try evidence.locationValue(allocator, entry.path, line_no, 1));
            try item.put(allocator, "source", .{ .string = if (zlint_confirmed) "zlint" else "heuristic" });
            try item.put(allocator, "confidence", .{ .string = if (zlint_confirmed) "high" else "medium" });
            try item.put(allocator, "semantic_confirmed", .{ .bool = zlint_confirmed });
            if (zlint_confirmed) try item.put(allocator, "semantic_backend", .{ .string = "zlint --print-ast" });
            try matches.append(.{ .object = item });
        }
    }
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = tool_name });
    try analysis_contract.putMetadata(allocator, &obj, tool_name);
    try obj.put(allocator, "symbol", try evidence.ownedString(allocator, symbol));
    try obj.put(allocator, if (calls_only) "callers" else "references", .{ .array = matches });
    try obj.put(allocator, "count", .{ .integer = @intCast(matches.items.len) });
    try obj.put(allocator, "zlint_ast_files", .{ .integer = @intCast(zlint_ast_files) });
    try obj.put(allocator, "zlint_ast_failures", .{ .integer = @intCast(zlint_ast_failures) });
    try obj.put(allocator, "evidence_sources", try evidence.sourceArrayValue(allocator, if (zlint_ast_files > 0) &.{ .zlint, .heuristic } else &.{.heuristic}));
    return .{ .object = obj };
}

fn zlintAstSymbolHasReferenceForFile(allocator: std.mem.Allocator, a: *App, args: ?std.json.Value, file: []const u8, symbol: []const u8, calls_only: bool) !bool {
    const resolved = try a.workspace.resolve(file);
    defer allocator.free(resolved);
    const argv = [_][]const u8{ a.config.zlint_path, "--print-ast", resolved };
    a.command_calls += 1;
    const result = try command.run(allocator, a.io, a.workspace.root, argv[0..], toolTimeout(a, args));
    if (!result.succeeded()) return false;
    return zlintAstSymbolHasReference(allocator, result.stdout, symbol, calls_only);
}

pub fn zlintAstSymbolHasReference(allocator: std.mem.Allocator, text: []const u8, symbol: []const u8, calls_only: bool) !bool {
    const start = std.mem.indexOfScalar(u8, text, '{') orelse return false;
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, text[start..], .{});
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |o| o,
        else => return false,
    };
    const symbols = switch (root.get("symbols") orelse .null) {
        .array => |array| array,
        else => return false,
    };
    for (symbols.items) |item| {
        const obj = switch (item) {
            .object => |o| o,
            else => continue,
        };
        if (!std.mem.eql(u8, evidence.stringField(obj, "name") orelse "", symbol)) continue;
        const refs = switch (obj.get("references") orelse .null) {
            .array => |array| array,
            else => return false,
        };
        if (!calls_only) return refs.items.len > 0;
        for (refs.items) |ref| if (zlintReferenceHasFlag(ref, "call")) return true;
        return false;
    }
    return false;
}

fn zlintReferenceHasFlag(value: std.json.Value, flag: []const u8) bool {
    const obj = switch (value) {
        .object => |o| o,
        else => return false,
    };
    const flags = switch (obj.get("flags") orelse .null) {
        .array => |array| array,
        else => return false,
    };
    for (flags.items) |item| switch (item) {
        .string => |s| if (std.mem.eql(u8, s, flag)) return true,
        else => {},
    };
    return false;
}

pub fn zigStaticFusion(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const query = argString(args, "query") orelse return missingArgumentResult(allocator, "zig_static_fusion", "query", "symbol or lint subject");
    ensureSemanticIndexCache(a, allocator, args, "zig_static_fusion", false) catch |err| return semanticError(allocator, "zig_static_fusion", "fusion_index", err);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const parsed = std.json.parseFromSlice(std.json.Value, scratch, a.semantic_index_cache.index_json.?, .{}) catch |err| return semanticError(allocator, "zig_static_fusion", "parse_cache", err);
    defer parsed.deinit();
    const matches = semanticMatchesValue(scratch, parsed.value, query, null, @intCast(@max(1, argInt(args, "limit", 20)))) catch return error.OutOfMemory;
    const zlint_findings = if (argString(args, "zlint_findings")) |text|
        lint_intelligence.normalizeFindingsText(scratch, text, .zlint) catch return missingArgumentResult(allocator, "zig_static_fusion", "zlint_findings", "valid JSON findings")
    else
        std.json.Value{ .array = std.json.Array.init(scratch) };
    const zwanzig_findings = if (argString(args, "zwanzig_findings")) |text|
        lint_intelligence.normalizeFindingsText(scratch, text, .zwanzig) catch return missingArgumentResult(allocator, "zig_static_fusion", "zwanzig_findings", "valid JSON findings")
    else
        std.json.Value{ .array = std.json.Array.init(scratch) };
    const zlint_related = try findingsMatchingQuery(scratch, zlint_findings.array, query);
    const zwanzig_related = try findingsMatchingQuery(scratch, zwanzig_findings.array, query);
    var sources = std.json.Array.init(scratch);
    if (matches.array.items.len > 0) try sources.append(.{ .string = "parser" });
    if (zlint_related.array.items.len > 0) try sources.append(.{ .string = "zlint" });
    if (zwanzig_related.array.items.len > 0) try sources.append(.{ .string = "zwanzig" });
    const consensus = sources.items.len >= 2;
    var obj = std.json.ObjectMap.empty;
    try obj.put(scratch, "kind", .{ .string = "zig_static_fusion" });
    try analysis_contract.putMetadata(scratch, &obj, "zig_static_fusion");
    try obj.put(scratch, "query", try evidence.ownedString(scratch, query));
    try obj.put(scratch, "matches", matches);
    try obj.put(scratch, "lint_evidence", try lintEvidenceValue(scratch, zlint_findings.array, zlint_related.array, zwanzig_findings.array, zwanzig_related.array));
    try obj.put(scratch, "evidence_sources", .{ .array = sources });
    try obj.put(scratch, "consensus", .{ .bool = consensus });
    try obj.put(scratch, "fusion_source", .{ .string = if (consensus) "consensus" else "disagreement_or_single_source" });
    try obj.put(scratch, "confidence", .{ .string = if (consensus) "high" else if (matches.array.items.len > 0) "medium" else "low" });
    try obj.put(scratch, "recommended_cross_check", try evidence.stringArrayValue(scratch, &.{ "zig build test", "ZLS references", "zig_lint_compare" }));
    return structured(allocator, .{ .object = obj });
}

fn findingsMatchingQuery(allocator: std.mem.Allocator, findings: std.json.Array, query: []const u8) !std.json.Value {
    var matches = std.json.Array.init(allocator);
    const lower_query = try std.ascii.allocLowerString(allocator, query);
    for (findings.items) |finding| {
        const text = try lintSearchableText(allocator, finding);
        const lower_text = try std.ascii.allocLowerString(allocator, text);
        if (std.mem.indexOf(u8, lower_text, lower_query) != null) try matches.append(finding);
    }
    return .{ .array = matches };
}

fn lintSearchableText(allocator: std.mem.Allocator, finding: std.json.Value) ![]const u8 {
    const obj = switch (finding) {
        .object => |o| o,
        else => return "",
    };
    const loc = switch (obj.get("location") orelse .null) {
        .object => |o| o,
        else => std.json.ObjectMap.empty,
    };
    return std.fmt.allocPrint(allocator, "{s} {s} {s} {s}", .{
        evidence.stringField(obj, "rule") orelse "",
        evidence.stringField(obj, "message") orelse "",
        evidence.stringField(obj, "severity") orelse "",
        evidence.stringField(loc, "file") orelse "",
    });
}

fn lintEvidenceValue(allocator: std.mem.Allocator, zlint_all: std.json.Array, zlint_related: std.json.Array, zwanzig_all: std.json.Array, zwanzig_related: std.json.Array) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "zlint_total_count", .{ .integer = @intCast(zlint_all.items.len) });
    try obj.put(allocator, "zlint_related_count", .{ .integer = @intCast(zlint_related.items.len) });
    try obj.put(allocator, "zlint_related", .{ .array = zlint_related });
    try obj.put(allocator, "zwanzig_total_count", .{ .integer = @intCast(zwanzig_all.items.len) });
    try obj.put(allocator, "zwanzig_related_count", .{ .integer = @intCast(zwanzig_related.items.len) });
    try obj.put(allocator, "zwanzig_related", .{ .array = zwanzig_related });
    return .{ .object = obj };
}

pub fn zigCodeIndexExport(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return exportIndex(a, allocator, args, "zig_code_index_export", "zigar.code_index");
}

pub fn zigScipExport(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return exportIndex(a, allocator, args, "zig_scip_export", "scip-like-json");
}

fn exportIndex(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value, tool_name: []const u8, format: []const u8) mcp.tools.ToolError!mcp.tools.ToolResult {
    const apply = argBool(args, "apply", false);
    const output = argString(args, "output") orelse if (std.mem.eql(u8, tool_name, "zig_scip_export")) ".zigar-cache/code-index.scip.json" else ".zigar-cache/code-index.json";
    ensureSemanticIndexCache(a, allocator, args, tool_name, argBool(args, "refresh", false)) catch |err| return semanticError(allocator, tool_name, "export_index", err);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const parsed = std.json.parseFromSlice(std.json.Value, scratch, a.semantic_index_cache.index_json.?, .{}) catch |err| return semanticError(allocator, tool_name, "parse_cache", err);
    defer parsed.deinit();
    var export_obj = std.json.ObjectMap.empty;
    try export_obj.put(scratch, "kind", .{ .string = tool_name });
    try analysis_contract.putMetadata(scratch, &export_obj, tool_name);
    try export_obj.put(scratch, "format", try evidence.ownedString(scratch, format));
    try export_obj.put(scratch, "format_version", .{ .integer = semantic_format_version });
    try export_obj.put(scratch, "index", parsed.value);
    const export_value: std.json.Value = .{ .object = export_obj };
    var bytes = std.ArrayList(u8).empty;
    try json_result.serializeValue(scratch, &bytes, export_value);
    if (apply) {
        a.workspace.writeFile(a.io, output, bytes.items) catch |err| return workspacePathErrorResult(a, allocator, tool_name, output, err);
    }
    var obj = std.json.ObjectMap.empty;
    try obj.put(scratch, "kind", .{ .string = tool_name });
    try analysis_contract.putMetadata(scratch, &obj, tool_name);
    try obj.put(scratch, "apply", .{ .bool = apply });
    try obj.put(scratch, "output", try evidence.ownedString(scratch, output));
    try obj.put(scratch, "wrote", .{ .bool = apply });
    try obj.put(scratch, "preview_bytes", .{ .integer = @intCast(bytes.items.len) });
    if (!apply) try obj.put(scratch, "artifact_preview", export_value);
    return structured(allocator, .{ .object = obj });
}

test "semantic index records parser evidence" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.writeFile(io, .{ .sub_path = "main.zig", .data = "const std = @import(\"std\");\npub fn main() void {}\ntest \"main\" {}\n" });
    const rel_base = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    const root_z = try std.Io.Dir.cwd().realPathFileAlloc(io, rel_base, allocator);
    const root = root_z[0..];
    const ws = zigar.workspace.Workspace{ .allocator = allocator, .io = io, .root = root, .cache_root = root };
    var cfg = try zigar.config.parse(allocator, io, &.{"zigar"});
    defer cfg.deinit(allocator);
    var app = App{ .allocator = allocator, .io = io, .config = cfg, .workspace = ws };
    const value = try semanticIndexValue(allocator, &app, 10, "zig_semantic_index_build");
    try std.testing.expectEqualStrings("zigar.semantic_index", value.object.get("format").?.string);
    try std.testing.expectEqualStrings("ok", value.object.get("parse_status").?.string);
    try std.testing.expect(!value.object.get("partial_result").?.bool);
    try std.testing.expectEqual(@as(i64, 0), value.object.get("parse_error_count").?.integer);
    const file = value.object.get("files").?.array.items[0].object;
    try std.testing.expectEqualStrings("ok", file.get("parse_status").?.string);
    try std.testing.expect(!file.get("partial_result").?.bool);
    try std.testing.expectEqual(@as(i64, 0), file.get("parse_error_count").?.integer);
    try std.testing.expect(value.object.get("declarations").?.array.items.len > 0);
    try std.testing.expect(value.object.get("imports").?.array.items.len > 0);
    try std.testing.expect(value.object.get("tests").?.array.items.len > 0);
}

test "static fusion only counts related lint evidence" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const empty_matches = std.json.Array.init(allocator);
    const related = try lint_intelligence.normalizeFindingsText(allocator, "{\"findings\":[{\"rule\":\"r\",\"severity\":\"warning\",\"path\":\"src/main.zig\",\"line\":1,\"message\":\"main warning\"}]}", .zlint);
    const unrelated = try lint_intelligence.normalizeFindingsText(allocator, "{\"findings\":[{\"rule\":\"r\",\"severity\":\"warning\",\"path\":\"src/other.zig\",\"line\":1,\"message\":\"other warning\"}]}", .zwanzig);
    const zlint_related = try findingsMatchingQuery(allocator, related.array, "main");
    const zwanzig_related = try findingsMatchingQuery(allocator, unrelated.array, "main");
    try std.testing.expectEqual(@as(usize, 1), zlint_related.array.items.len);
    try std.testing.expectEqual(@as(usize, 0), zwanzig_related.array.items.len);
    try std.testing.expectEqual(@as(usize, 0), empty_matches.items.len);
}

test "zlint ast confirms call references from prefixed output" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const ast =
        \\Printing AST for main.zig
        \\{"symbols":[{"name":"helper","references":[{"flags":["call"]}]},{"name":"other","references":[]}]}
    ;
    try std.testing.expect(try zlintAstSymbolHasReference(arena.allocator(), ast, "helper", false));
    try std.testing.expect(try zlintAstSymbolHasReference(arena.allocator(), ast, "helper", true));
    try std.testing.expect(!try zlintAstSymbolHasReference(arena.allocator(), ast, "other", false));
}
