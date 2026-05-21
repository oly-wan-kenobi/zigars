const std = @import("std");
const builtin = @import("builtin");
const docs_source = @import("source.zig");
const json_result = @import("../json_result.zig");

const std_search_ranking = "case-insensitive declaration/source hit sorted by relative path then line; limit is applied after sorting";
const std_item_ranking = "exact declaration-name match, preferring the path implied by a qualified std name, then relative path and line; limit is applied after sorting";
const std_scan_limitations = "Source scan only: no semantic import resolution, no rendered autodoc, and declaration docs are adjacent triple-slash comments only.";

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
    var files_scanned: usize = 0;
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
        files_scanned += 1;

        const lower_contents = try asciiLowerAlloc(allocator, contents);
        defer allocator.free(lower_contents);
        const hit = std.mem.indexOf(u8, lower_contents, lower_query) orelse continue;

        const hit_line = lineAt(contents, hit);
        const parsed_decl = parseDeclaration(hit_line);
        const qualified_name = if (parsed_decl) |decl| try qualifiedNameForDecl(allocator, entry.path, decl.name) else null;
        const doc_comments = if (parsed_decl != null) try docCommentsBefore(allocator, contents, hit) else try allocator.dupe(u8, "");

        try collected.append(allocator, .{
            .path = try allocator.dupe(u8, entry.path),
            .line = lineNumber(contents, hit),
            .snippet = try allocator.dupe(u8, hit_line),
            .match_kind = if (parsed_decl) |decl| decl.kind else "source_line",
            .decl_name = if (parsed_decl) |decl| try allocator.dupe(u8, decl.name) else null,
            .qualified_name = qualified_name,
            .import_hint = if (qualified_name) |name| try allocator.dupe(u8, name) else null,
            .doc_comments = doc_comments,
            .doc_comment_count = countDocCommentLines(doc_comments),
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
        try obj.put(allocator, "match_kind", .{ .string = match.match_kind });
        try putOptionalString(allocator, &obj, "decl_name", match.decl_name);
        try putOptionalString(allocator, &obj, "qualified_name", match.qualified_name);
        try putOptionalString(allocator, &obj, "import_hint", match.import_hint);
        try obj.put(allocator, "doc_comments", .{ .string = match.doc_comments });
        try obj.put(allocator, "doc_comment_count", .{ .integer = @intCast(match.doc_comment_count) });
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
    try obj.put(allocator, "index_metadata", try stdIndexMetadataValue(allocator, std_dir, files_scanned, skipped_files, walk_errors));
    try obj.put(allocator, "total_match_count", .{ .integer = @intCast(collected.items.len) });
    try obj.put(allocator, "files_scanned", .{ .integer = @intCast(files_scanned) });
    try obj.put(allocator, "skipped_files", .{ .integer = @intCast(skipped_files) });
    try obj.put(allocator, "walk_errors", .{ .integer = @intCast(walk_errors) });
    try obj.put(allocator, "source_scan_limitations", .{ .string = std_scan_limitations });
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
    var files_scanned: usize = 0;
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
        files_scanned += 1;

        var line_no: usize = 1;
        var pending_doc_comments: std.ArrayList(u8) = .empty;
        var pending_doc_comment_count: usize = 0;
        defer pending_doc_comments.deinit(allocator);
        var lines = std.mem.splitScalar(u8, contents, '\n');
        while (lines.next()) |line| : (line_no += 1) {
            const trimmed = std.mem.trim(u8, line, " \t\r\n");
            if (docCommentText(trimmed)) |comment| {
                if (pending_doc_comments.items.len > 0) try pending_doc_comments.append(allocator, '\n');
                try pending_doc_comments.appendSlice(allocator, comment);
                pending_doc_comment_count += 1;
                continue;
            }
            const kind = declarationKind(line, item_name) orelse {
                if (trimmed.len != 0) {
                    pending_doc_comments.clearRetainingCapacity();
                    pending_doc_comment_count = 0;
                }
                continue;
            };
            try collected.append(allocator, .{
                .path = try allocator.dupe(u8, entry.path),
                .line = line_no,
                .snippet = try allocator.dupe(u8, std.mem.trim(u8, line, " \t\r\n")),
                .kind = kind,
                .preferred_path = if (path_hint) |hint| pathMatchesHint(entry.path, hint) else false,
                .doc_comments = try allocator.dupe(u8, pending_doc_comments.items),
                .doc_comment_count = pending_doc_comment_count,
                .qualified_name = try qualifiedNameForDecl(allocator, entry.path, item_name),
            });
            pending_doc_comments.clearRetainingCapacity();
            pending_doc_comment_count = 0;
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
        try obj.put(allocator, "doc_comments", .{ .string = match.doc_comments });
        try obj.put(allocator, "doc_comment_count", .{ .integer = @intCast(match.doc_comment_count) });
        try obj.put(allocator, "preferred_path", .{ .bool = match.preferred_path });
        try obj.put(allocator, "qualified_name", .{ .string = match.qualified_name });
        try obj.put(allocator, "import_hint", .{ .string = match.qualified_name });
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
    try obj.put(allocator, "index_metadata", try stdIndexMetadataValue(allocator, std_dir, files_scanned, skipped_files, walk_errors));
    try obj.put(allocator, "name", .{ .string = name });
    try obj.put(allocator, "decl_name", .{ .string = item_name });
    if (path_hint) |hint| {
        try obj.put(allocator, "qualified_path_hint", .{ .string = hint });
    } else {
        try obj.put(allocator, "qualified_path_hint", .null);
    }
    try obj.put(allocator, "total_match_count", .{ .integer = @intCast(collected.items.len) });
    try obj.put(allocator, "files_scanned", .{ .integer = @intCast(files_scanned) });
    try obj.put(allocator, "skipped_files", .{ .integer = @intCast(skipped_files) });
    try obj.put(allocator, "walk_errors", .{ .integer = @intCast(walk_errors) });
    try obj.put(allocator, "source_scan_limitations", .{ .string = std_scan_limitations });
    try obj.put(allocator, "matches", .{ .array = matches });
    return .{ .object = obj };
}
const StdSourceMatch = struct {
    path: []const u8,
    line: usize,
    snippet: []const u8,
    match_kind: []const u8,
    decl_name: ?[]const u8,
    qualified_name: ?[]const u8,
    import_hint: ?[]const u8,
    doc_comments: []const u8,
    doc_comment_count: usize,
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
    doc_comments: []const u8,
    doc_comment_count: usize,
    qualified_name: []const u8,
};

fn stdItemMatchLessThan(_: void, lhs: StdItemMatch, rhs: StdItemMatch) bool {
    if (lhs.preferred_path != rhs.preferred_path) return lhs.preferred_path;
    const path_order = std.mem.order(u8, lhs.path, rhs.path);
    if (path_order != .eq) return path_order == .lt;
    return lhs.line < rhs.line;
}

fn stdIndexMetadataValue(
    allocator: std.mem.Allocator,
    std_dir: []const u8,
    files_scanned: usize,
    skipped_files: usize,
    walk_errors: usize,
) !std.json.Value {
    var roots = std.json.Array.init(allocator);
    errdefer roots.deinit();
    try roots.append(.{ .string = std_dir });

    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "index_strategy", .{ .string = "in_memory_stdlib_source_scan" });
    try obj.put(allocator, "completeness_mode", .{ .string = "source_scan" });
    try obj.put(allocator, "generated_unix", .null);
    try obj.put(allocator, "generated_at", .{ .string = "per_call_in_memory_index" });
    try obj.put(allocator, "source_roots", .{ .array = roots });
    try obj.put(allocator, "max_file_bytes", .{ .integer = 512 * 1024 });
    try obj.put(allocator, "files_scanned", .{ .integer = @intCast(files_scanned) });
    try obj.put(allocator, "skipped_files", .{ .integer = @intCast(skipped_files) });
    try obj.put(allocator, "walk_errors", .{ .integer = @intCast(walk_errors) });
    try obj.put(allocator, "doc_comment_extraction", .{ .string = "adjacent_triple_slash_comments_for_std_item_matches" });
    try obj.put(allocator, "source_scan_limitations", .{ .string = std_scan_limitations });
    return .{ .object = obj };
}

fn docCommentText(trimmed_line: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, trimmed_line, "///")) return null;
    if (std.mem.startsWith(u8, trimmed_line, "////")) return null;
    return std.mem.trim(u8, trimmed_line[3..], " \t\r\n");
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
        const qualified_name = match.get("qualified_name").?;
        if (qualified_name == .string) try out.print(allocator, "Qualified name: {s}\nImport hint: {s}\n\n", .{ qualified_name.string, match.get("import_hint").?.string });
        const doc_comments = match.get("doc_comments").?.string;
        if (doc_comments.len > 0) try out.print(allocator, "Doc comments:\n{s}\n\n", .{doc_comments});
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
        try out.print(allocator, "Qualified name: {s}\nImport hint: {s}\n\n", .{ match.get("qualified_name").?.string, match.get("import_hint").?.string });
        const doc_comments = match.get("doc_comments").?.string;
        if (doc_comments.len > 0) {
            try out.print(allocator, "Doc comments:\n{s}\n\n", .{doc_comments});
        }
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

const ParsedDecl = struct { name: []const u8, kind: []const u8 };

fn declarationKind(line: []const u8, name: []const u8) ?[]const u8 {
    const decl = parseDeclaration(line) orelse return null;
    return if (std.mem.eql(u8, decl.name, name)) decl.kind else null;
}

fn parseDeclaration(line: []const u8) ?ParsedDecl {
    var rest = std.mem.trim(u8, line, " \t");
    if (std.mem.startsWith(u8, rest, "pub ")) rest = rest[4..];
    while (true) {
        if (std.mem.startsWith(u8, rest, "inline ")) rest = rest[7..] else if (std.mem.startsWith(u8, rest, "extern ")) rest = rest[7..] else break;
    }
    const kinds = [_]struct { prefix: []const u8, kind: []const u8 }{
        .{ .prefix = "const ", .kind = "const" },
        .{ .prefix = "fn ", .kind = "fn" },
        .{ .prefix = "var ", .kind = "var" },
    };
    for (kinds) |entry| {
        if (!std.mem.startsWith(u8, rest, entry.prefix)) continue;
        const name_start = entry.prefix.len;
        var name_end = name_start;
        while (name_end < rest.len and isIdentChar(rest[name_end])) name_end += 1;
        if (name_end > name_start) return .{ .name = rest[name_start..name_end], .kind = entry.kind };
    }
    return null;
}

fn isIdentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn qualifiedNameForDecl(allocator: std.mem.Allocator, path: []const u8, decl_name: []const u8) ![]const u8 {
    const stem = if (std.mem.endsWith(u8, path, ".zig")) path[0 .. path.len - 4] else path;
    var module: std.ArrayList(u8) = .empty;
    defer module.deinit(allocator);
    try module.appendSlice(allocator, "std");
    if (!std.mem.eql(u8, stem, "std")) {
        try module.append(allocator, '.');
        for (stem) |c| try module.append(allocator, if (c == '/') '.' else c);
    }
    return std.fmt.allocPrint(allocator, "{s}.{s}", .{ module.items, decl_name });
}

fn docCommentsBefore(allocator: std.mem.Allocator, text: []const u8, index: usize) ![]const u8 {
    const start = lineStart(text, index);
    var first = start;
    while (first > 0) {
        const prev_end = first - 1;
        const prev_start = lineStart(text, prev_end);
        const trimmed = std.mem.trim(u8, text[prev_start..prev_end], " \t\r\n");
        if (docCommentText(trimmed) == null) break;
        first = prev_start;
    }
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    while (first < start) {
        const end = std.mem.indexOfScalarPos(u8, text, first, '\n') orelse start;
        if (docCommentText(std.mem.trim(u8, text[first..end], " \t\r\n"))) |comment| {
            if (out.items.len > 0) try out.append(allocator, '\n');
            try out.appendSlice(allocator, comment);
        }
        first = @min(end + 1, start);
    }
    return out.toOwnedSlice(allocator);
}

fn countDocCommentLines(comments: []const u8) usize {
    if (comments.len == 0) return 0;
    var count: usize = 1;
    for (comments) |c| {
        if (c == '\n') count += 1;
    }
    return count;
}

fn lineStart(text: []const u8, index: usize) usize {
    var start = @min(index, text.len);
    while (start > 0 and text[start - 1] != '\n') start -= 1;
    return start;
}

fn putOptionalString(allocator: std.mem.Allocator, obj: *std.json.ObjectMap, key: []const u8, value: ?[]const u8) !void {
    if (value) |string| try obj.put(allocator, key, .{ .string = string }) else try obj.put(allocator, key, .null);
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
