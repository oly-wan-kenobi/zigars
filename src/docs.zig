const std = @import("std");
const builtin = @import("builtin");
pub const docs_source = @import("docs/source.zig");
const json_result = @import("json_result.zig");
const langref = @import("docs/langref.zig");

pub const BuiltinDoc = struct {
    name: []const u8,
    signature: []const u8,
    summary: []const u8,
};

pub const LangRefSection = langref.Section;

pub const builtins = [_]BuiltinDoc{
    .{ .name = "@import", .signature = "@import(comptime path: []const u8) type", .summary = "Imports a Zig source file or package module at comptime." },
    .{ .name = "@This", .signature = "@This() type", .summary = "Returns the innermost container type." },
    .{ .name = "@TypeOf", .signature = "@TypeOf(...) type", .summary = "Returns the type of an expression or peer-resolved expressions." },
    .{ .name = "@as", .signature = "@as(comptime T: type, expression) T", .summary = "Performs an explicit type coercion." },
    .{ .name = "@intCast", .signature = "@intCast(integer) anytype", .summary = "Casts an integer to the inferred integer type with safety checks when enabled." },
    .{ .name = "@floatFromInt", .signature = "@floatFromInt(int) anytype", .summary = "Converts an integer to the inferred floating-point type." },
    .{ .name = "@ptrCast", .signature = "@ptrCast(value) anytype", .summary = "Changes pointer type without changing the address." },
    .{ .name = "@alignCast", .signature = "@alignCast(ptr) anytype", .summary = "Asserts or adjusts pointer alignment to the inferred alignment." },
    .{ .name = "@field", .signature = "@field(lhs, comptime field_name: []const u8) anytype", .summary = "Accesses a field by comptime-known name." },
    .{ .name = "@hasDecl", .signature = "@hasDecl(comptime Container: type, comptime name: []const u8) bool", .summary = "Checks whether a container has a declaration." },
    .{ .name = "@hasField", .signature = "@hasField(comptime Container: type, comptime name: []const u8) bool", .summary = "Checks whether a container type has a field." },
    .{ .name = "@compileError", .signature = "@compileError(comptime msg: []const u8) noreturn", .summary = "Emits a compile error during semantic analysis." },
    .{ .name = "@compileLog", .signature = "@compileLog(...) void", .summary = "Prints compile-time debugging information." },
    .{ .name = "@memcpy", .signature = "@memcpy(noalias dest, noalias source) void", .summary = "Copies memory from source to destination." },
    .{ .name = "@memset", .signature = "@memset(dest, elem) void", .summary = "Sets all elements of a destination to a value." },
    .{ .name = "@sizeOf", .signature = "@sizeOf(comptime T: type) comptime_int", .summary = "Returns the ABI size of a type in bytes." },
    .{ .name = "@alignOf", .signature = "@alignOf(comptime T: type) comptime_int", .summary = "Returns the ABI alignment of a type." },
    .{ .name = "@bitSizeOf", .signature = "@bitSizeOf(comptime T: type) comptime_int", .summary = "Returns the bit size of a type." },
    .{ .name = "@errorName", .signature = "@errorName(err: anyerror) [:0]const u8", .summary = "Returns the name of an error value." },
    .{ .name = "@tagName", .signature = "@tagName(value: anytype) [:0]const u8", .summary = "Returns the tag name of an enum value." },
    .{ .name = "@embedFile", .signature = "@embedFile(comptime path: []const u8) *const [N:0]u8", .summary = "Embeds a file in the binary at compile time." },
    .{ .name = "@src", .signature = "@src() std.builtin.SourceLocation", .summary = "Returns source location information." },
    .{ .name = "@panic", .signature = "@panic(message: []const u8) noreturn", .summary = "Terminates execution with a panic message." },
};

pub const langref_sections = langref.sections;

const builtin_list_ranking = "curated builtin declaration order";
const builtin_doc_ranking = "case-insensitive builtin-name substring match in curated order; limit is applied after matching";
const std_search_ranking = "case-insensitive source hit sorted by relative path then line; limit is applied after sorting";
const std_item_ranking = "exact declaration-name match, preferring the path implied by a qualified std name, then relative path and line; limit is applied after sorting";

pub fn builtinList(allocator: std.mem.Allocator) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    const source = docs_source.curatedBuiltins();
    const contract: docs_source.Contract = .{
        .result_count = builtins.len,
        .ranking = builtin_list_ranking,
    };
    try docs_source.appendTextHeader(allocator, &out, source);
    try docs_source.appendTextContract(allocator, &out, contract);
    try out.print(allocator, "Known Zig builtins ({d} curated entries):\n\n", .{builtins.len});
    for (builtins) |item| {
        try out.print(allocator, "- `{s}`: {s}\n", .{ item.signature, item.summary });
    }
    return out.toOwnedSlice(allocator);
}

pub fn builtinListValue(allocator: std.mem.Allocator) !std.json.Value {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    return json_result.cloneValue(allocator, try builtinListValueImpl(arena.allocator()));
}

fn builtinListValueImpl(allocator: std.mem.Allocator) !std.json.Value {
    var items = std.json.Array.init(allocator);
    errdefer items.deinit();
    for (builtins) |item| try items.append(try builtinItemValue(allocator, item, null));

    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try docs_source.putContractFields(allocator, &obj, docs_source.curatedBuiltins(), .{
        .result_count = builtins.len,
        .ranking = builtin_list_ranking,
    });
    try obj.put(allocator, "count", .{ .integer = @intCast(builtins.len) });
    try obj.put(allocator, "builtins", .{ .array = items });
    return .{ .object = obj };
}

pub fn builtinDoc(allocator: std.mem.Allocator, query: []const u8, limit: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    const lower_query = try asciiLowerAlloc(allocator, query);
    defer allocator.free(lower_query);
    const normalized_limit = @max(limit, 1);

    const found = countBuiltinMatches(allocator, lower_query, normalized_limit) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
    };
    const contract: docs_source.Contract = .{
        .query = query,
        .limit = normalized_limit,
        .result_count = found,
        .no_result_reason = if (found == 0) "no_builtin_match" else null,
        .ranking = builtin_doc_ranking,
    };
    try docs_source.appendTextHeader(allocator, &out, docs_source.curatedBuiltins());
    try docs_source.appendTextContract(allocator, &out, contract);

    var emitted: usize = 0;
    for (builtins) |item| {
        const lower_name = try asciiLowerAlloc(allocator, item.name);
        defer allocator.free(lower_name);
        if (std.mem.indexOf(u8, lower_name, lower_query) != null or std.mem.indexOf(u8, lower_query, lower_name) != null) {
            if (emitted >= normalized_limit) break;
            emitted += 1;
            try out.print(allocator, "## {s}\n\n```zig\n{s}\n```\n\n{s}\n\n", .{ item.name, item.signature, item.summary });
        }
    }

    if (emitted == 0) {
        try out.print(allocator, "No curated builtin documentation matched `{s}`. Try `zig_builtin_list` for available entries.\n", .{query});
    }
    return out.toOwnedSlice(allocator);
}

pub fn builtinDocValue(allocator: std.mem.Allocator, query: []const u8, limit: usize) !std.json.Value {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    return json_result.cloneValue(allocator, try builtinDocValueImpl(arena.allocator(), query, limit));
}

fn builtinDocValueImpl(allocator: std.mem.Allocator, query: []const u8, limit: usize) !std.json.Value {
    const normalized_limit = @max(limit, 1);
    const lower_query = try asciiLowerAlloc(allocator, query);
    defer allocator.free(lower_query);

    var matches = std.json.Array.init(allocator);
    errdefer matches.deinit();
    var emitted: usize = 0;
    for (builtins) |item| {
        if (emitted >= normalized_limit) break;
        const lower_name = try asciiLowerAlloc(allocator, item.name);
        defer allocator.free(lower_name);
        if (std.mem.indexOf(u8, lower_name, lower_query) == null and std.mem.indexOf(u8, lower_query, lower_name) == null) continue;
        emitted += 1;
        try matches.append(try builtinItemValue(allocator, item, emitted));
    }

    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try docs_source.putContractFields(allocator, &obj, docs_source.curatedBuiltins(), .{
        .query = query,
        .limit = normalized_limit,
        .result_count = emitted,
        .no_result_reason = if (emitted == 0) "no_builtin_match" else null,
        .ranking = builtin_doc_ranking,
    });
    try obj.put(allocator, "matches", .{ .array = matches });
    return .{ .object = obj };
}

pub fn searchStd(
    allocator: std.mem.Allocator,
    io: std.Io,
    std_dir: []const u8,
    query: []const u8,
    limit: usize,
) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const result = try stdSearchValue(arena.allocator(), io, std_dir, query, limit);
    return stdSearchTextFromValue(allocator, result);
}

pub fn langRefSearch(allocator: std.mem.Allocator, io: std.Io, lib_dir: []const u8, query: []const u8, limit: usize) ![]u8 {
    return langref.search(allocator, io, lib_dir, query, limit);
}

pub fn langRefSearchValue(allocator: std.mem.Allocator, io: std.Io, lib_dir: []const u8, query: []const u8, limit: usize) !std.json.Value {
    return langref.searchValue(allocator, io, lib_dir, query, limit);
}

pub fn stdSearchValue(
    allocator: std.mem.Allocator,
    io: std.Io,
    std_dir: []const u8,
    query: []const u8,
    limit: usize,
) !std.json.Value {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    return json_result.cloneValue(allocator, try stdSearchValueImpl(arena.allocator(), io, std_dir, query, limit));
}

fn stdSearchValueImpl(
    allocator: std.mem.Allocator,
    io: std.Io,
    std_dir: []const u8,
    query: []const u8,
    limit: usize,
) !std.json.Value {
    const normalized_limit = @max(limit, 1);
    const lower_query = try asciiLowerAlloc(allocator, query);
    defer allocator.free(lower_query);

    var dir = try std.Io.Dir.openDirAbsolute(io, std_dir, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(allocator);
    defer walker.deinit();

    var collected: std.ArrayList(StdSourceMatch) = .empty;
    defer collected.deinit(allocator);
    var skipped_files: usize = 0;
    var walk_errors: usize = 0;
    while (true) {
        const maybe_entry = walker.next(io) catch {
            walk_errors += 1;
            break;
        };
        const entry = maybe_entry orelse break;
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".zig")) continue;

        const abs = try std.fs.path.join(allocator, &.{ std_dir, entry.path });
        defer allocator.free(abs);
        const contents = std.Io.Dir.cwd().readFileAlloc(io, abs, allocator, .limited(512 * 1024)) catch {
            skipped_files += 1;
            continue;
        };
        defer allocator.free(contents);

        const lower_contents = try asciiLowerAlloc(allocator, contents);
        defer allocator.free(lower_contents);
        const hit = std.mem.indexOf(u8, lower_contents, lower_query) orelse continue;

        try collected.append(allocator, .{
            .path = try allocator.dupe(u8, entry.path),
            .line = lineNumber(contents, hit),
            .snippet = try allocator.dupe(u8, lineAt(contents, hit)),
        });
    }
    std.mem.sort(StdSourceMatch, collected.items, {}, stdSourceMatchLessThan);

    const result_count = @min(collected.items.len, normalized_limit);
    var matches = std.json.Array.init(allocator);
    errdefer matches.deinit();
    for (collected.items[0..result_count], 0..) |match, index| {
        var obj = std.json.ObjectMap.empty;
        errdefer obj.deinit(allocator);
        const source_path = try std.fs.path.join(allocator, &.{ std_dir, match.path });
        try obj.put(allocator, "rank", .{ .integer = @intCast(index + 1) });
        try obj.put(allocator, "root", .{ .string = "std" });
        try obj.put(allocator, "path", .{ .string = match.path });
        try obj.put(allocator, "source_path", .{ .string = source_path });
        try obj.put(allocator, "line", .{ .integer = @intCast(match.line) });
        try obj.put(allocator, "snippet", .{ .string = match.snippet });
        try matches.append(.{ .object = obj });
    }

    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try docs_source.putContractFields(allocator, &obj, docs_source.stdlibSource(std_dir, null), .{
        .query = query,
        .limit = normalized_limit,
        .result_count = result_count,
        .no_result_reason = if (collected.items.len == 0) "no_std_source_match" else null,
        .ranking = std_search_ranking,
    });
    try obj.put(allocator, "total_match_count", .{ .integer = @intCast(collected.items.len) });
    try obj.put(allocator, "skipped_files", .{ .integer = @intCast(skipped_files) });
    try obj.put(allocator, "walk_errors", .{ .integer = @intCast(walk_errors) });
    try obj.put(allocator, "matches", .{ .array = matches });
    return .{ .object = obj };
}

pub fn stdItem(allocator: std.mem.Allocator, io: std.Io, std_dir: []const u8, name: []const u8, limit: usize) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const result = try stdItemValue(arena.allocator(), io, std_dir, name, limit);
    return stdItemTextFromValue(allocator, result);
}

pub fn stdItemValue(
    allocator: std.mem.Allocator,
    io: std.Io,
    std_dir: []const u8,
    name: []const u8,
    limit: usize,
) !std.json.Value {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    return json_result.cloneValue(allocator, try stdItemValueImpl(arena.allocator(), io, std_dir, name, limit));
}

fn stdItemValueImpl(
    allocator: std.mem.Allocator,
    io: std.Io,
    std_dir: []const u8,
    name: []const u8,
    limit: usize,
) !std.json.Value {
    const normalized_limit = @max(limit, 1);
    const item_name = lastNameSegment(name);
    const path_hint = try qualifiedStdPathHint(allocator, name);
    const has_item_name = item_name.len > 0;

    var dir = try std.Io.Dir.openDirAbsolute(io, std_dir, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(allocator);
    defer walker.deinit();

    var collected: std.ArrayList(StdItemMatch) = .empty;
    defer collected.deinit(allocator);
    var skipped_files: usize = 0;
    var walk_errors: usize = 0;
    while (has_item_name) {
        const maybe_entry = walker.next(io) catch {
            walk_errors += 1;
            break;
        };
        const entry = maybe_entry orelse break;
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".zig")) continue;

        const abs = try std.fs.path.join(allocator, &.{ std_dir, entry.path });
        defer allocator.free(abs);
        const contents = std.Io.Dir.cwd().readFileAlloc(io, abs, allocator, .limited(512 * 1024)) catch {
            skipped_files += 1;
            continue;
        };
        defer allocator.free(contents);

        var line_no: usize = 1;
        var lines = std.mem.splitScalar(u8, contents, '\n');
        while (lines.next()) |line| : (line_no += 1) {
            const kind = declarationKind(line, item_name) orelse continue;
            try collected.append(allocator, .{
                .path = try allocator.dupe(u8, entry.path),
                .line = line_no,
                .snippet = try allocator.dupe(u8, std.mem.trim(u8, line, " \t\r\n")),
                .kind = kind,
                .preferred_path = if (path_hint) |hint| pathMatchesHint(entry.path, hint) else false,
            });
        }
    }
    std.mem.sort(StdItemMatch, collected.items, {}, stdItemMatchLessThan);

    const result_count = @min(collected.items.len, normalized_limit);
    var matches = std.json.Array.init(allocator);
    errdefer matches.deinit();
    for (collected.items[0..result_count], 0..) |match, index| {
        var obj = std.json.ObjectMap.empty;
        errdefer obj.deinit(allocator);
        const source_path = try std.fs.path.join(allocator, &.{ std_dir, match.path });
        try obj.put(allocator, "rank", .{ .integer = @intCast(index + 1) });
        try obj.put(allocator, "name", .{ .string = name });
        try obj.put(allocator, "decl_name", .{ .string = item_name });
        try obj.put(allocator, "match_kind", .{ .string = match.kind });
        try obj.put(allocator, "path", .{ .string = match.path });
        try obj.put(allocator, "source_path", .{ .string = source_path });
        try obj.put(allocator, "line", .{ .integer = @intCast(match.line) });
        try obj.put(allocator, "snippet", .{ .string = match.snippet });
        try obj.put(allocator, "preferred_path", .{ .bool = match.preferred_path });
        try matches.append(.{ .object = obj });
    }

    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try docs_source.putContractFields(allocator, &obj, docs_source.stdlibSource(std_dir, null), .{
        .query = name,
        .limit = normalized_limit,
        .result_count = result_count,
        .no_result_reason = if (collected.items.len == 0) "no_std_item_declaration_match" else null,
        .ranking = std_item_ranking,
    });
    try obj.put(allocator, "name", .{ .string = name });
    try obj.put(allocator, "decl_name", .{ .string = item_name });
    if (path_hint) |hint| {
        try obj.put(allocator, "qualified_path_hint", .{ .string = hint });
    } else {
        try obj.put(allocator, "qualified_path_hint", .null);
    }
    try obj.put(allocator, "total_match_count", .{ .integer = @intCast(collected.items.len) });
    try obj.put(allocator, "skipped_files", .{ .integer = @intCast(skipped_files) });
    try obj.put(allocator, "walk_errors", .{ .integer = @intCast(walk_errors) });
    try obj.put(allocator, "matches", .{ .array = matches });
    return .{ .object = obj };
}

fn builtinItemValue(allocator: std.mem.Allocator, item: BuiltinDoc, rank: ?usize) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    if (rank) |value_rank| try obj.put(allocator, "rank", .{ .integer = @intCast(value_rank) });
    try obj.put(allocator, "name", .{ .string = item.name });
    try obj.put(allocator, "signature", .{ .string = item.signature });
    try obj.put(allocator, "summary", .{ .string = item.summary });
    return .{ .object = obj };
}

fn countBuiltinMatches(allocator: std.mem.Allocator, lower_query: []const u8, limit: usize) !usize {
    var found: usize = 0;
    for (builtins) |item| {
        if (found >= limit) break;
        const lower_name = try asciiLowerAlloc(allocator, item.name);
        defer allocator.free(lower_name);
        if (std.mem.indexOf(u8, lower_name, lower_query) != null or std.mem.indexOf(u8, lower_query, lower_name) != null) found += 1;
    }
    return found;
}

const StdSourceMatch = struct {
    path: []const u8,
    line: usize,
    snippet: []const u8,
};

fn stdSourceMatchLessThan(_: void, lhs: StdSourceMatch, rhs: StdSourceMatch) bool {
    const path_order = std.mem.order(u8, lhs.path, rhs.path);
    if (path_order != .eq) return path_order == .lt;
    return lhs.line < rhs.line;
}

const StdItemMatch = struct {
    path: []const u8,
    line: usize,
    snippet: []const u8,
    kind: []const u8,
    preferred_path: bool,
};

fn stdItemMatchLessThan(_: void, lhs: StdItemMatch, rhs: StdItemMatch) bool {
    if (lhs.preferred_path != rhs.preferred_path) return lhs.preferred_path;
    const path_order = std.mem.order(u8, lhs.path, rhs.path);
    if (path_order != .eq) return path_order == .lt;
    return lhs.line < rhs.line;
}

fn stdSearchTextFromValue(allocator: std.mem.Allocator, value: std.json.Value) ![]u8 {
    const obj = value.object;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    const source_obj = obj.get("source").?.object;
    try appendSourceObjectText(allocator, &out, source_obj);
    try appendContractObjectText(allocator, &out, obj);
    const matches = obj.get("matches").?.array.items;
    for (matches) |match_value| {
        const match = match_value.object;
        try out.print(allocator, "### std/{s}:{d}\n\n```zig\n{s}\n```\n\n", .{
            match.get("path").?.string,
            match.get("line").?.integer,
            match.get("snippet").?.string,
        });
    }
    if (matches.len == 0) {
        try out.print(allocator, "No stdlib matches for `{s}` under {s}.\n", .{
            obj.get("query").?.string,
            source_obj.get("path").?.string,
        });
    }
    if (obj.get("skipped_files").?.integer > 0) {
        try out.print(allocator, "\nSkipped {d} unreadable or oversized Zig files while scanning.\n", .{obj.get("skipped_files").?.integer});
    }
    return out.toOwnedSlice(allocator);
}

fn stdItemTextFromValue(allocator: std.mem.Allocator, value: std.json.Value) ![]u8 {
    const obj = value.object;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try appendSourceObjectText(allocator, &out, obj.get("source").?.object);
    try appendContractObjectText(allocator, &out, obj);
    const matches = obj.get("matches").?.array.items;
    for (matches) |match_value| {
        const match = match_value.object;
        try out.print(allocator, "### std/{s}:{d} ({s})\n\n```zig\n{s}\n```\n\n", .{
            match.get("path").?.string,
            match.get("line").?.integer,
            match.get("match_kind").?.string,
            match.get("snippet").?.string,
        });
    }
    if (matches.len == 0) {
        try out.print(allocator, "No stdlib declaration matched `{s}`. Try `zig_std_search` for broader source scanning.\n", .{obj.get("name").?.string});
    }
    return out.toOwnedSlice(allocator);
}

fn appendSourceObjectText(allocator: std.mem.Allocator, out: *std.ArrayList(u8), source_obj: std.json.ObjectMap) !void {
    try out.print(allocator,
        \\Docs source: {s}
        \\Source label: {s}
        \\Provenance: {s}
        \\Completeness: {s}
        \\Version: {s}
        \\
    , .{
        source_obj.get("id").?.string,
        source_obj.get("label").?.string,
        source_obj.get("provenance").?.string,
        source_obj.get("completeness").?.string,
        source_obj.get("version").?.string,
    });
    const path = source_obj.get("path").?;
    if (path == .string) try out.print(allocator, "Path: {s}\n", .{path.string});
    try out.append(allocator, '\n');
}

fn appendContractObjectText(allocator: std.mem.Allocator, out: *std.ArrayList(u8), obj: std.json.ObjectMap) !void {
    const query = obj.get("query").?;
    if (query == .string) {
        try out.print(allocator, "Query: `{s}`\n", .{query.string});
    } else {
        try out.appendSlice(allocator, "Query: none\n");
    }
    const limit = obj.get("limit").?;
    if (limit == .integer) {
        try out.print(allocator, "Limit: {d}\n", .{limit.integer});
    } else {
        try out.appendSlice(allocator, "Limit: none\n");
    }
    try out.print(allocator, "Result count: {d}\n", .{obj.get("result_count").?.integer});
    const no_result = obj.get("no_result_reason").?;
    if (no_result == .string) {
        try out.print(allocator, "No result reason: {s}\n", .{no_result.string});
    } else {
        try out.appendSlice(allocator, "No result reason: none\n");
    }
    try out.print(allocator, "Ranking: {s}\n\n", .{obj.get("ranking").?.string});
}

fn lastNameSegment(name: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, name, " \t\r\n");
    if (std.mem.lastIndexOfScalar(u8, trimmed, '.')) |dot| return std.mem.trim(u8, trimmed[dot + 1 ..], " \t\r\n");
    return trimmed;
}

fn qualifiedStdPathHint(allocator: std.mem.Allocator, name: []const u8) !?[]const u8 {
    const trimmed = std.mem.trim(u8, name, " \t\r\n");
    if (!std.mem.startsWith(u8, trimmed, "std.")) return null;
    const last_dot = std.mem.lastIndexOfScalar(u8, trimmed, '.') orelse return null;
    if (last_dot <= "std.".len) return null;
    const qualifier = trimmed["std.".len..last_dot];
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (qualifier) |c| {
        try out.append(allocator, if (c == '.') '/' else c);
    }
    try out.appendSlice(allocator, ".zig");
    const owned = try out.toOwnedSlice(allocator);
    return @as([]const u8, owned);
}

fn pathMatchesHint(path: []const u8, hint: []const u8) bool {
    return std.mem.eql(u8, path, hint) or std.mem.endsWith(u8, path, hint);
}

fn declarationKind(line: []const u8, name: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, line, " \t");
    if (hasDeclarationName(trimmed, "pub const ", name) or hasDeclarationName(trimmed, "const ", name)) return "const";
    if (hasDeclarationName(trimmed, "pub fn ", name) or hasDeclarationName(trimmed, "fn ", name)) return "fn";
    if (hasDeclarationName(trimmed, "pub var ", name) or hasDeclarationName(trimmed, "var ", name)) return "var";
    return null;
}

fn hasDeclarationName(line: []const u8, prefix: []const u8, name: []const u8) bool {
    if (!std.mem.startsWith(u8, line, prefix)) return false;
    const rest = line[prefix.len..];
    if (!std.mem.startsWith(u8, rest, name)) return false;
    return rest.len == name.len or !isIdentChar(rest[name.len]);
}

fn isIdentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn asciiLowerAlloc(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    const out = try allocator.alloc(u8, input.len);
    for (input, 0..) |c, i| out[i] = std.ascii.toLower(c);
    return out;
}

fn lineNumber(text: []const u8, index: usize) usize {
    var line: usize = 1;
    for (text[0..@min(index, text.len)]) |c| {
        if (c == '\n') line += 1;
    }
    return line;
}

fn lineAt(text: []const u8, index: usize) []const u8 {
    var start = index;
    while (start > 0 and text[start - 1] != '\n') start -= 1;
    var end = index;
    while (end < text.len and text[end] != '\n') end += 1;
    return text[start..end];
}

test "builtin docs find import" {
    const text = try builtinDoc(std.testing.allocator, "import", 20);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "@import") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Docs source: curated_zigar_builtins") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Completeness: partial_curated") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Result count: 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Ranking: case-insensitive builtin-name substring match") != null);
}

test "builtin doc JSON exposes docs contract and no-match reason" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const hit = try builtinDocValue(allocator, "import", 1);
    const hit_obj = hit.object;
    try std.testing.expectEqualStrings("curated_zigar_builtins", hit_obj.get("source").?.object.get("id").?.string);
    try std.testing.expectEqualStrings("partial_curated", hit_obj.get("source").?.object.get("completeness").?.string);
    try std.testing.expectEqual(@as(i64, 1), hit_obj.get("limit").?.integer);
    try std.testing.expectEqual(@as(i64, 1), hit_obj.get("result_count").?.integer);
    try std.testing.expect(hit_obj.get("no_result_reason").? == .null);
    try std.testing.expectEqualStrings("@import", hit_obj.get("matches").?.array.items[0].object.get("name").?.string);

    const miss = try builtinDocValue(allocator, "definitely_not_a_builtin", 5);
    const miss_obj = miss.object;
    try std.testing.expectEqual(@as(i64, 0), miss_obj.get("result_count").?.integer);
    try std.testing.expectEqualStrings("no_builtin_match", miss_obj.get("no_result_reason").?.string);
}

test {
    _ = langref;
}

test "std search ignores non-zig documentation files" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "std");
    try tmp.dir.writeFile(io, .{ .sub_path = "std/readme.md", .data = "docs_only_token\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "std/main.zig", .data = "pub const x = 1;\n" });

    const std_dir = try tmpAbs(allocator, io, tmp.sub_path[0..], "std");
    defer allocator.free(std_dir);
    const text = try searchStd(allocator, io, std_dir, "docs_only_token", 10);
    defer allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "No stdlib matches") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "readme.md") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Docs source: local_stdlib_zig_source") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Completeness: source_scan") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "No result reason: no_std_source_match") != null);
}

test "std search JSON applies deterministic sorted limit and source contract" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "std");
    try tmp.dir.writeFile(io, .{ .sub_path = "std/z_last.zig", .data = "pub const token = 1;\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "std/a_first.zig", .data = "pub const token = 2;\n" });

    const std_dir = try tmpAbs(allocator, io, tmp.sub_path[0..], "std");
    defer allocator.free(std_dir);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const value = try stdSearchValue(arena.allocator(), io, std_dir, "token", 1);
    const obj = value.object;
    try std.testing.expectEqualStrings("local_stdlib_zig_source", obj.get("source").?.object.get("id").?.string);
    try std.testing.expectEqualStrings("source_scan", obj.get("source").?.object.get("completeness").?.string);
    try std.testing.expectEqual(@as(i64, 1), obj.get("limit").?.integer);
    try std.testing.expectEqual(@as(i64, 1), obj.get("result_count").?.integer);
    try std.testing.expectEqual(@as(i64, 2), obj.get("total_match_count").?.integer);
    try std.testing.expectEqualStrings("a_first.zig", obj.get("matches").?.array.items[0].object.get("path").?.string);
    try std.testing.expect(std.mem.endsWith(u8, obj.get("matches").?.array.items[0].object.get("source_path").?.string, "std/a_first.zig"));
    try std.testing.expect(obj.get("no_result_reason").? == .null);
}

test "std item JSON uses exact declaration lookup and no-match contract" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "std/fs");
    try tmp.dir.writeFile(io, .{ .sub_path = "std/fs/path.zig", .data = "pub fn join() void {}\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "std/other.zig", .data = "pub fn join() void {}\n" });

    const std_dir = try tmpAbs(allocator, io, tmp.sub_path[0..], "std");
    defer allocator.free(std_dir);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const hit = try stdItemValue(arena.allocator(), io, std_dir, "std.fs.path.join", 1);
    const hit_obj = hit.object;
    const first = hit_obj.get("matches").?.array.items[0].object;
    try std.testing.expectEqualStrings("local_stdlib_zig_source", hit_obj.get("source").?.object.get("id").?.string);
    try std.testing.expectEqualStrings("source_scan", hit_obj.get("source").?.object.get("completeness").?.string);
    try std.testing.expectEqualStrings("fs/path.zig", hit_obj.get("qualified_path_hint").?.string);
    try std.testing.expectEqualStrings("fs/path.zig", first.get("path").?.string);
    try std.testing.expect(std.mem.endsWith(u8, first.get("source_path").?.string, "std/fs/path.zig"));
    try std.testing.expect(first.get("preferred_path").?.bool);
    try std.testing.expectEqualStrings("fn", first.get("match_kind").?.string);

    const miss = try stdItemValue(arena.allocator(), io, std_dir, "std.fs.path.missing", 3);
    const miss_obj = miss.object;
    try std.testing.expectEqual(@as(i64, 0), miss_obj.get("result_count").?.integer);
    try std.testing.expectEqualStrings("no_std_item_declaration_match", miss_obj.get("no_result_reason").?.string);
}

test "docs JSON values are fully owned and compatible with structuredOwned" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "std/fs");
    try tmp.dir.writeFile(io, .{ .sub_path = "std/fs/path.zig", .data = "pub fn join() void {}\npub const token = 1;\n" });

    const std_dir = try tmpAbs(allocator, io, tmp.sub_path[0..], "std");
    defer allocator.free(std_dir);

    {
        const value = try builtinListValue(allocator);
        const result = try json_result.structuredOwned(allocator, value);
        defer json_result.deinitToolResult(allocator, result);
        try std.testing.expectEqualStrings("curated_zigar_builtins", result.structuredContent.?.object.get("source").?.object.get("id").?.string);
    }
    {
        const value = try builtinDocValue(allocator, "import", 1);
        const result = try json_result.structuredOwned(allocator, value);
        defer json_result.deinitToolResult(allocator, result);
        try std.testing.expectEqual(@as(i64, 1), result.structuredContent.?.object.get("result_count").?.integer);
    }
    {
        const value = try stdSearchValue(allocator, io, std_dir, "token", 1);
        const result = try json_result.structuredOwned(allocator, value);
        defer json_result.deinitToolResult(allocator, result);
        try std.testing.expectEqualStrings("source_scan", result.structuredContent.?.object.get("source").?.object.get("completeness").?.string);
    }
    {
        const value = try stdItemValue(allocator, io, std_dir, "std.fs.path.join", 1);
        const result = try json_result.structuredOwned(allocator, value);
        defer json_result.deinitToolResult(allocator, result);
        try std.testing.expectEqualStrings("join", result.structuredContent.?.object.get("decl_name").?.string);
    }
}

test {
    _ = docs_source;
}

fn tmpAbs(allocator: std.mem.Allocator, io: std.Io, tmp_sub_path: []const u8, child: []const u8) ![]u8 {
    const rel_base = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", tmp_sub_path });
    defer allocator.free(rel_base);
    const base_z = try std.Io.Dir.cwd().realPathFileAlloc(io, rel_base, allocator);
    defer allocator.free(base_z);
    return std.fs.path.join(allocator, &.{ base_z[0..], child });
}
