const std = @import("std");
const builtin = @import("builtin");
const docs_source = @import("source.zig");
const json_result = @import("../json_result.zig");

pub const Section = struct {
    title: []const u8,
    anchor: []const u8,
    summary: []const u8,
    body: []const u8,
};

pub const sections = [_]Section{
    .{ .title = "Assignment", .anchor = "Assignment", .summary = "Assignment writes a value to a mutable memory location.", .body = "Use var for mutable local variables and const for immutable bindings. Assignment is not an expression and does not produce a value." },
    .{ .title = "Arrays", .anchor = "Arrays", .summary = "Arrays have a compile-time-known length and element type.", .body = "Array syntax is [N]T. Slices use []T and carry pointer plus length at runtime." },
    .{ .title = "Builtins", .anchor = "Builtin-Functions", .summary = "Builtin functions are compiler-provided operations whose names start with @.", .body = "Examples include @import, @as, @sizeOf, @alignOf, @TypeOf, @compileError, and @panic." },
    .{ .title = "Compile-Time Parameters", .anchor = "comptime", .summary = "comptime marks values and parameters that must be known during semantic analysis.", .body = "comptime enables generic functions, type construction, and compile-time execution. Branches and loops can also execute at comptime when their controlling values are comptime-known." },
    .{ .title = "Defer", .anchor = "defer", .summary = "defer schedules an expression to run when control leaves the current scope.", .body = "Deferred expressions run in reverse order. errdefer runs only when the scope exits with an error and is commonly used for cleanup after partial initialization." },
    .{ .title = "Enums", .anchor = "enum", .summary = "Enums define a set of named values with an optional integer tag type.", .body = "Use @tagName to get the current tag name. Extern and packed enum layout have ABI and storage implications." },
    .{ .title = "Error Sets", .anchor = "Error-Set-Type", .summary = "Error sets describe named error values.", .body = "Error unions combine an error set with a payload type using E!T. Use try, catch, if, and switch to handle or propagate errors." },
    .{ .title = "Functions", .anchor = "Functions", .summary = "Functions declare typed parameters and a return type.", .body = "Function bodies are analyzed when referenced. Parameters can be comptime-known, noalias, or ordinary runtime values." },
    .{ .title = "If", .anchor = "if", .summary = "if selects between branches using a boolean condition.", .body = "if can unwrap optionals and error unions. if expressions require compatible branch result types when used as a value." },
    .{ .title = "Optionals", .anchor = "Optional-Type", .summary = "Optional types represent either null or a payload value.", .body = "Optional syntax is ?T. Use if optional capture, orelse, or.? to handle nullable values explicitly." },
    .{ .title = "Pointers", .anchor = "Pointers", .summary = "Pointers reference memory and carry mutability, alignment, sentinel, and address-space information.", .body = "Single-item pointers use *T, many-item pointers use [*]T, and slices use []T. Pointer casts require explicit builtins and should preserve alignment and const rules." },
    .{ .title = "Slices", .anchor = "Slices", .summary = "Slices are runtime views over contiguous memory.", .body = "A slice stores a pointer and a length. Sentinel-terminated slices carry a known sentinel value after the final element." },
    .{ .title = "Structs", .anchor = "struct", .summary = "Structs group named fields and declarations.", .body = "Struct declarations can contain fields, methods, comptime declarations, and nested types. Layout defaults to Zig-defined unless extern or packed is requested." },
    .{ .title = "Switch", .anchor = "switch", .summary = "switch performs exhaustive selection over values.", .body = "Switch is commonly used with enums, tagged unions, integers, and error sets. Exhaustive handling is required unless an else branch is present." },
    .{ .title = "Tests", .anchor = "Zig-Test", .summary = "test declarations define code executed by zig test.", .body = "Use std.testing helpers for expectations and allocations. Test declarations are discovered by the test runner when their containing file is analyzed." },
    .{ .title = "Undefined", .anchor = "undefined", .summary = "undefined leaves a value uninitialized.", .body = "Reading undefined memory is illegal behavior. It is useful only when every byte will be initialized before the value is observed." },
    .{ .title = "Unions", .anchor = "union", .summary = "Unions store one field at a time, optionally with a tag.", .body = "Tagged unions combine a union payload with an enum tag and work naturally with switch." },
    .{ .title = "While", .anchor = "while", .summary = "while repeats a body while a condition holds.", .body = "while supports continue expressions, optional captures, error-union captures, and else clauses for natural completion." },
};

const bundled_ranking = "bundled curated sections with title or anchor matches before summary/body matches; limit is applied after ranking";
const installed_ranking = "installed HTML heading order for matching language-reference sections; limit is applied after document-order ranking";

pub fn search(allocator: std.mem.Allocator, io: std.Io, lib_dir: []const u8, query: []const u8, limit: usize) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const result = try searchValue(arena.allocator(), io, lib_dir, query, limit);
    return searchTextFromValue(allocator, result);
}

pub fn searchValue(allocator: std.mem.Allocator, io: std.Io, lib_dir: []const u8, query: []const u8, limit: usize) !std.json.Value {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    return json_result.cloneValue(allocator, try searchValueImpl(arena.allocator(), io, lib_dir, query, limit));
}

fn searchValueImpl(allocator: std.mem.Allocator, io: std.Io, lib_dir: []const u8, query: []const u8, limit: usize) !std.json.Value {
    const normalized_limit = @max(limit, 1);
    const probe = try findHtml(allocator, io, lib_dir);
    if (probe.path) |path| {
        const contents = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(2 * 1024 * 1024)) catch {
            return searchBundledValue(allocator, query, normalized_limit, .{
                .installed_doc_available = true,
                .candidate_count = probe.candidates_checked,
                .skipped_candidate_count = probe.skippedCandidates(),
                .rejected_candidate_count = probe.rejected_candidates,
                .unreadable_candidate_count = probe.unreadable_candidates + 1,
                .parse_failure_count = 1,
                .fallback_reason = "installed_langref_read_failed",
            });
        };
        defer allocator.free(contents);
        return searchHtmlValue(allocator, path, contents, query, normalized_limit, probe);
    }
    return searchBundledValue(allocator, query, normalized_limit, .{
        .candidate_count = probe.candidates_checked,
        .skipped_candidate_count = probe.skippedCandidates(),
        .rejected_candidate_count = probe.rejected_candidates,
        .unreadable_candidate_count = probe.unreadable_candidates,
        .fallback_reason = "installed_langref_not_found",
    });
}

const LangRefHtmlProbe = struct {
    path: ?[]const u8 = null,
    candidates_checked: usize = 0,
    rejected_candidates: usize = 0,
    unreadable_candidates: usize = 0,

    fn skippedCandidates(self: LangRefHtmlProbe) usize {
        return self.rejected_candidates + self.unreadable_candidates;
    }
};

fn findHtml(allocator: std.mem.Allocator, io: std.Io, lib_dir: []const u8) !LangRefHtmlProbe {
    const candidates = [_][]const u8{
        "doc/langref.html",
        "doc/langref.html.in",
        "docs/langref.html",
        "docs/langref.html.in",
        "langref.html",
        "docs/index.html",
    };
    var probe: LangRefHtmlProbe = .{};
    for (candidates) |rel| {
        probe.candidates_checked += 1;
        const path = try std.fs.path.join(allocator, &.{ lib_dir, rel });
        errdefer allocator.free(path);
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(128 * 1024)) catch {
            allocator.free(path);
            probe.unreadable_candidates += 1;
            continue;
        };
        defer allocator.free(bytes);
        if (looksLikeLangRef(rel, bytes)) {
            probe.path = path;
            return probe;
        }
        probe.rejected_candidates += 1;
        allocator.free(path);
    }
    return probe;
}

fn looksLikeLangRef(rel_path: []const u8, bytes: []const u8) bool {
    if (std.mem.eql(u8, rel_path, "docs/index.html")) return false;
    if (std.mem.indexOf(u8, bytes, "Language Reference") != null or
        std.mem.indexOf(u8, bytes, "Zig Language Reference") != null)
    {
        return true;
    }
    if (std.mem.indexOf(u8, rel_path, "langref") == null) return false;
    return std.mem.indexOf(u8, bytes, "Zig") != null or std.mem.indexOf(u8, bytes, "zig") != null;
}

const BundledFallbackMetadata = struct {
    installed_doc_available: bool = false,
    candidate_count: usize = 0,
    skipped_candidate_count: usize = 0,
    rejected_candidate_count: usize = 0,
    unreadable_candidate_count: usize = 0,
    parse_failure_count: usize = 0,
    fallback_reason: []const u8 = "installed_langref_not_found",
};

fn searchBundledValue(allocator: std.mem.Allocator, query: []const u8, limit: usize, fallback: BundledFallbackMetadata) !std.json.Value {
    const lower_query = try asciiLowerAlloc(allocator, query);
    defer allocator.free(lower_query);

    var matches = std.json.Array.init(allocator);
    errdefer matches.deinit();
    var count = try appendBundledMatches(allocator, &matches, lower_query, limit, .title);
    if (count < limit) {
        count += try appendBundledMatches(allocator, &matches, lower_query, limit - count, .body);
    }

    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try docs_source.putContractFields(allocator, &obj, docs_source.bundledLangref(), .{
        .query = query,
        .limit = limit,
        .result_count = count,
        .no_result_reason = if (count == 0) "no_langref_match" else null,
        .ranking = bundled_ranking,
    });
    try obj.put(allocator, "index_metadata", try indexMetadataValue(allocator, .{
        .strategy = "bundled_curated_langref_index",
        .indexed_sections = sections.len,
        .installed_doc_available = fallback.installed_doc_available,
        .candidate_count = fallback.candidate_count,
        .skipped_candidate_count = fallback.skipped_candidate_count,
        .rejected_candidate_count = fallback.rejected_candidate_count,
        .unreadable_candidate_count = fallback.unreadable_candidate_count,
        .parse_failure_count = fallback.parse_failure_count,
        .fallback_reason = fallback.fallback_reason,
    }));
    try obj.put(allocator, "matches", .{ .array = matches });
    return .{ .object = obj };
}

const MatchPass = enum { title, body };

fn appendBundledMatches(allocator: std.mem.Allocator, matches: *std.json.Array, lower_query: []const u8, limit: usize, pass: MatchPass) !usize {
    var count: usize = 0;
    for (sections) |section| {
        if (count >= limit) break;
        if (!sectionMatches(section, lower_query, pass)) continue;
        count += 1;
        var obj = std.json.ObjectMap.empty;
        errdefer obj.deinit(allocator);
        try obj.put(allocator, "rank", .{ .integer = @intCast(matches.items.len + 1) });
        try obj.put(allocator, "title", .{ .string = section.title });
        try obj.put(allocator, "anchor", .{ .string = section.anchor });
        try obj.put(allocator, "summary", .{ .string = section.summary });
        try obj.put(allocator, "body", .{ .string = section.body });
        try obj.put(allocator, "match_pass", .{ .string = @tagName(pass) });
        try obj.put(allocator, "source_path", .null);
        try matches.append(.{ .object = obj });
    }
    return count;
}

fn sectionMatches(section: Section, lower_query: []const u8, pass: MatchPass) bool {
    const title_hit = containsLowered(section.title, lower_query) or containsLowered(section.anchor, lower_query);
    return switch (pass) {
        .title => title_hit,
        .body => !title_hit and (containsLowered(section.summary, lower_query) or containsLowered(section.body, lower_query)),
    };
}

fn containsLowered(haystack: []const u8, lower_query: []const u8) bool {
    if (lower_query.len == 0) return true;
    if (lower_query.len > haystack.len) return false;
    var start: usize = 0;
    while (start + lower_query.len <= haystack.len) : (start += 1) {
        for (lower_query, 0..) |query_char, offset| {
            if (std.ascii.toLower(haystack[start + offset]) != query_char) break;
        } else return true;
    }
    return false;
}

fn searchHtmlValue(allocator: std.mem.Allocator, path: []const u8, html: []const u8, query: []const u8, limit: usize, probe: LangRefHtmlProbe) !std.json.Value {
    const lower_query = try asciiLowerAlloc(allocator, query);
    defer allocator.free(lower_query);

    var matches = std.json.Array.init(allocator);
    errdefer matches.deinit();
    var count: usize = 0;
    var heading_count: usize = 0;
    var skipped_heading_count: usize = 0;
    var pos: usize = 0;
    while (true) {
        const heading = nextHeading(html, pos) orelse break;
        heading_count += 1;
        pos = heading.end;
        const next = nextHeading(html, pos);
        const section_end = if (next) |n| n.start else html.len;
        const section_html = html[heading.start..section_end];
        const text = try stripHtmlAlloc(allocator, section_html);
        defer allocator.free(text);
        const title = std.mem.trim(u8, try stripHtmlAlloc(allocator, heading.title_html), " \t\r\n");
        if (title.len == 0 or heading.anchor.len == 0) {
            skipped_heading_count += 1;
            continue;
        }
        const lower_text = try asciiLowerAlloc(allocator, text);
        defer allocator.free(lower_text);
        if (std.mem.indexOf(u8, lower_text, lower_query) == null) continue;
        if (count >= limit) continue;

        count += 1;
        const snippet = snippetForQuery(text, lower_text, lower_query);
        const summary = boundedSummary(text);
        var obj = std.json.ObjectMap.empty;
        errdefer obj.deinit(allocator);
        try obj.put(allocator, "rank", .{ .integer = @intCast(count) });
        try obj.put(allocator, "title", .{ .string = title });
        try obj.put(allocator, "anchor", .{ .string = try allocator.dupe(u8, heading.anchor) });
        try obj.put(allocator, "summary", .{ .string = try allocator.dupe(u8, summary) });
        try obj.put(allocator, "snippet", .{ .string = try allocator.dupe(u8, std.mem.trim(u8, snippet, " \t\r\n")) });
        try obj.put(allocator, "match_pass", .{ .string = "html_section" });
        try obj.put(allocator, "source_path", .{ .string = path });
        try matches.append(.{ .object = obj });
    }

    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try docs_source.putContractFields(allocator, &obj, docs_source.installedLangref(path, null), .{
        .query = query,
        .limit = limit,
        .result_count = count,
        .no_result_reason = if (count == 0) "no_langref_match" else null,
        .ranking = installed_ranking,
    });
    const indexed_sections = heading_count - skipped_heading_count;
    try obj.put(allocator, "index_metadata", try indexMetadataValue(allocator, .{
        .strategy = "installed_html_heading_scan",
        .source_path = path,
        .indexed_sections = indexed_sections,
        .heading_count = heading_count,
        .skipped_heading_count = skipped_heading_count,
        .installed_doc_available = true,
        .candidate_count = probe.candidates_checked,
        .skipped_candidate_count = probe.skippedCandidates(),
        .rejected_candidate_count = probe.rejected_candidates,
        .unreadable_candidate_count = probe.unreadable_candidates,
    }));
    try obj.put(allocator, "matches", .{ .array = matches });
    return .{ .object = obj };
}

fn searchTextFromValue(allocator: std.mem.Allocator, value: std.json.Value) ![]u8 {
    const obj = value.object;
    const source_obj = obj.get("source").?.object;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.print(allocator, "Language reference search source: {s}\n", .{source_obj.get("id").?.string});
    try appendSourceObjectText(allocator, &out, source_obj);
    try appendContractObjectText(allocator, &out, obj);

    const matches = obj.get("matches").?.array.items;
    for (matches) |match_value| {
        const match = match_value.object;
        try out.print(allocator, "### {s} (#{s})\n\n", .{ match.get("title").?.string, match.get("anchor").?.string });
        const source_path = match.get("source_path").?;
        if (source_path == .string) {
            try out.print(allocator, "Source: {s}\n\n", .{source_path.string});
            try out.print(allocator, "{s}\n\n", .{match.get("summary").?.string});
        } else {
            try out.appendSlice(allocator, "Source: bundled Zig language reference index\n\n");
            try out.print(allocator, "{s}\n\n{s}\n\n", .{ match.get("summary").?.string, match.get("body").?.string });
        }
    }

    if (matches.len == 0) {
        const source_path = source_obj.get("path").?;
        if (source_path == .string) {
            try out.print(allocator, "No language reference matches for `{s}` in {s}.\n", .{ obj.get("query").?.string, source_path.string });
        } else {
            try out.print(allocator, "No language reference matches for `{s}` in the bundled index.\n", .{obj.get("query").?.string});
        }
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

const HtmlHeading = struct {
    start: usize,
    end: usize,
    anchor: []const u8,
    title_html: []const u8,
};

const LangrefIndexMetadata = struct {
    strategy: []const u8,
    source_path: ?[]const u8 = null,
    indexed_sections: usize,
    heading_count: usize = 0,
    skipped_heading_count: usize = 0,
    installed_doc_available: bool,
    candidate_count: usize = 0,
    skipped_candidate_count: usize = 0,
    rejected_candidate_count: usize = 0,
    unreadable_candidate_count: usize = 0,
    parse_failure_count: usize = 0,
    fallback_reason: ?[]const u8 = null,
};

fn indexMetadataValue(allocator: std.mem.Allocator, metadata: LangrefIndexMetadata) !std.json.Value {
    var roots = std.json.Array.init(allocator);
    errdefer roots.deinit();
    if (metadata.source_path) |path| try roots.append(.{ .string = path });

    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "index_strategy", .{ .string = metadata.strategy });
    try obj.put(allocator, "generated_unix", .null);
    try obj.put(allocator, "generated_at", .{ .string = "per_call_in_memory_index" });
    try obj.put(allocator, "indexed_section_count", .{ .integer = @intCast(metadata.indexed_sections) });
    try obj.put(allocator, "heading_count", .{ .integer = @intCast(metadata.heading_count) });
    try obj.put(allocator, "skipped_heading_count", .{ .integer = @intCast(metadata.skipped_heading_count) });
    try obj.put(allocator, "installed_doc_available", .{ .bool = metadata.installed_doc_available });
    try obj.put(allocator, "candidate_count", .{ .integer = @intCast(metadata.candidate_count) });
    try obj.put(allocator, "skipped_candidate_count", .{ .integer = @intCast(metadata.skipped_candidate_count) });
    try obj.put(allocator, "rejected_candidate_count", .{ .integer = @intCast(metadata.rejected_candidate_count) });
    try obj.put(allocator, "unreadable_candidate_count", .{ .integer = @intCast(metadata.unreadable_candidate_count) });
    try obj.put(allocator, "parse_failure_count", .{ .integer = @intCast(metadata.parse_failure_count) });
    if (metadata.fallback_reason) |reason| try obj.put(allocator, "fallback_reason", .{ .string = reason }) else try obj.put(allocator, "fallback_reason", .null);
    try obj.put(allocator, "source_roots", .{ .array = roots });
    try obj.put(allocator, "section_summary", .{ .string = "HTML headings and anchors indexed with bounded section summaries, source path, and fallback counters" });
    return .{ .object = obj };
}

fn nextHeading(html: []const u8, start_pos: usize) ?HtmlHeading {
    var pos = start_pos;
    while (std.mem.indexOfPos(u8, html, pos, "<h")) |start| {
        if (start + 2 >= html.len or !std.ascii.isDigit(html[start + 2])) {
            pos = start + 2;
            continue;
        }
        const open_end = std.mem.indexOfScalarPos(u8, html, start, '>') orelse return null;
        const close = std.mem.indexOfPos(u8, html, open_end, "</h") orelse return null;
        const close_end = std.mem.indexOfScalarPos(u8, html, close, '>') orelse return null;
        const open_tag = html[start .. open_end + 1];
        const title_html = html[open_end + 1 .. close];
        const anchor = headingAnchor(open_tag, title_html) orelse "";
        return .{
            .start = start,
            .end = close_end + 1,
            .anchor = anchor,
            .title_html = title_html,
        };
    }
    return null;
}

fn headingAnchor(open_tag: []const u8, title_html: []const u8) ?[]const u8 {
    return attrValue(open_tag, "id") orelse
        attrValue(open_tag, "name") orelse
        attrValue(title_html, "id") orelse
        attrValue(title_html, "name") orelse
        anchorHrefFragment(title_html);
}

fn attrValue(text: []const u8, name: []const u8) ?[]const u8 {
    const start = std.mem.indexOf(u8, text, name) orelse return null;
    var pos = start + name.len;
    while (pos < text.len and std.ascii.isWhitespace(text[pos])) pos += 1;
    if (pos >= text.len or text[pos] != '=') return null;
    pos += 1;
    while (pos < text.len and std.ascii.isWhitespace(text[pos])) pos += 1;
    if (pos >= text.len or (text[pos] != '"' and text[pos] != '\'')) return null;
    const quote = text[pos];
    const value_start = pos + 1;
    const value_end = std.mem.indexOfScalarPos(u8, text, value_start, quote) orelse return null;
    return text[value_start..value_end];
}

fn anchorHrefFragment(text: []const u8) ?[]const u8 {
    const href = attrValue(text, "href") orelse return null;
    if (href.len < 2 or href[0] != '#') return null;
    return href[1..];
}

fn stripHtmlAlloc(allocator: std.mem.Allocator, html: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var in_tag = false;
    var i: usize = 0;
    while (i < html.len) : (i += 1) {
        const c = html[i];
        if (c == '<') {
            in_tag = true;
            if (out.items.len > 0 and out.items[out.items.len - 1] != ' ') try out.append(allocator, ' ');
            continue;
        }
        if (c == '>') {
            in_tag = false;
            continue;
        }
        if (in_tag) continue;
        if (c == '&') {
            if (consumeEntity(html[i..])) |entity| {
                try out.append(allocator, entity.char);
                i += entity.len - 1;
                continue;
            }
        }
        try out.append(allocator, if (std.ascii.isWhitespace(c)) ' ' else c);
    }
    return out.toOwnedSlice(allocator);
}

const Entity = struct { char: u8, len: usize };

fn consumeEntity(text: []const u8) ?Entity {
    const entities = [_]struct { name: []const u8, char: u8 }{
        .{ .name = "&lt;", .char = '<' },
        .{ .name = "&gt;", .char = '>' },
        .{ .name = "&amp;", .char = '&' },
        .{ .name = "&quot;", .char = '"' },
        .{ .name = "&#39;", .char = '\'' },
    };
    for (entities) |entity| {
        if (std.mem.startsWith(u8, text, entity.name)) return .{ .char = entity.char, .len = entity.name.len };
    }
    return null;
}

fn snippetForQuery(text: []const u8, lower_text: []const u8, lower_query: []const u8) []const u8 {
    const hit = std.mem.indexOf(u8, lower_text, lower_query) orelse return text[0..@min(text.len, 240)];
    var start = hit;
    while (start > 0 and text[start - 1] != '.' and text[start - 1] != '\n') start -= 1;
    var end = hit + lower_query.len;
    while (end < text.len and text[end] != '.' and text[end] != '\n') end += 1;
    if (end < text.len) end += 1;
    if (end - start > 320) end = @min(text.len, start + 320);
    return text[start..end];
}

fn boundedSummary(text: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    return trimmed[0..@min(trimmed.len, 360)];
}

fn asciiLowerAlloc(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    const out = try allocator.alloc(u8, input.len);
    for (input, 0..) |c, i| out[i] = std.ascii.toLower(c);
    return out;
}

test "uses bundled index when installed langref is absent" {
    const text = try search(std.testing.allocator, std.testing.io, "/definitely/missing/zig/lib", "defer", 3);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "bundled_langref_index") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Completeness: partial_curated") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Result count: 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "### Defer (#defer)") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "errdefer") != null);
}

test "bundled langref JSON labels partial curated fallback and no-match reason" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const hit = try searchValue(allocator, std.testing.io, "/definitely/missing/zig/lib", "defer", 1);
    const hit_obj = hit.object;
    try std.testing.expectEqualStrings("bundled_langref_index", hit_obj.get("source").?.object.get("id").?.string);
    try std.testing.expectEqualStrings("partial_curated", hit_obj.get("source").?.object.get("completeness").?.string);
    try std.testing.expectEqual(@as(i64, 1), hit_obj.get("limit").?.integer);
    try std.testing.expectEqual(@as(i64, 1), hit_obj.get("result_count").?.integer);
    try std.testing.expectEqualStrings("bundled_curated_langref_index", hit_obj.get("index_metadata").?.object.get("index_strategy").?.string);
    try std.testing.expectEqual(false, hit_obj.get("index_metadata").?.object.get("installed_doc_available").?.bool);
    try std.testing.expectEqualStrings("installed_langref_not_found", hit_obj.get("index_metadata").?.object.get("fallback_reason").?.string);
    try std.testing.expectEqualStrings("Defer", hit_obj.get("matches").?.array.items[0].object.get("title").?.string);
    try std.testing.expect(hit_obj.get("no_result_reason").? == .null);

    const miss = try searchValue(allocator, std.testing.io, "/definitely/missing/zig/lib", "not-a-langref-token", 2);
    const miss_obj = miss.object;
    try std.testing.expectEqual(@as(i64, 0), miss_obj.get("result_count").?.integer);
    try std.testing.expectEqualStrings("no_langref_match", miss_obj.get("no_result_reason").?.string);
}

test "langref JSON value is fully owned and compatible with structuredOwned" {
    const allocator = std.testing.allocator;
    const value = try searchValue(allocator, std.testing.io, "/definitely/missing/zig/lib", "defer", 1);
    const result = try json_result.structuredOwned(allocator, value);
    defer json_result.deinitToolResult(allocator, result);

    const obj = result.structuredContent.?.object;
    try std.testing.expectEqualStrings("bundled_langref_index", obj.get("source").?.object.get("id").?.string);
    try std.testing.expectEqual(@as(i64, 1), obj.get("result_count").?.integer);
    try std.testing.expectEqualStrings("Defer", obj.get("matches").?.array.items[0].object.get("title").?.string);
}

test "does not scan docs implementation zig files" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "lib/docs/wasm");
    try tmp.dir.writeFile(io, .{
        .sub_path = "lib/docs/wasm/main.zig",
        .data = "const docs_app_only_token = true;\n",
    });

    const lib_dir = try tmpAbs(allocator, io, tmp.sub_path[0..], "lib");
    defer allocator.free(lib_dir);
    const text = try search(allocator, io, lib_dir, "docs_app_only_token", 5);
    defer allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "wasm/main.zig") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "docs_app_only_token") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "No language reference matches") != null);
}

test "does not treat installed autodoc index as language reference" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "lib/docs");
    try tmp.dir.writeFile(io, .{
        .sub_path = "lib/docs/index.html",
        .data =
        \\<!doctype html>
        \\<html><head><title>Zig Documentation</title></head><body>
        \\<h1 id="hdrName">defer</h1>
        \\<p>Autodoc search result shell, not the Zig Language Reference.</p>
        \\</body></html>
        ,
    });

    const lib_dir = try tmpAbs(allocator, io, tmp.sub_path[0..], "lib");
    defer allocator.free(lib_dir);
    const text = try search(allocator, io, lib_dir, "defer", 1);
    defer allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "bundled_langref_index") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "installed_langref_html") == null);
}

test "unreadable langref candidate falls back to bundled partial data" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "lib/doc/langref.html");

    const lib_dir = try tmpAbs(allocator, io, tmp.sub_path[0..], "lib");
    defer allocator.free(lib_dir);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const value = try searchValue(arena.allocator(), io, lib_dir, "defer", 1);
    const obj = value.object;

    try std.testing.expectEqualStrings("bundled_langref_index", obj.get("source").?.object.get("id").?.string);
    try std.testing.expectEqualStrings("partial_curated", obj.get("source").?.object.get("completeness").?.string);
}

test "uses installed language reference html when present" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "lib/doc");
    try tmp.dir.writeFile(io, .{
        .sub_path = "lib/doc/langref.html",
        .data =
        \\<!doctype html>
        \\<html><head><title>Zig Language Reference</title></head><body>
        \\<h1 id="defer">defer</h1>
        \\<p>Runs cleanup at scope exit sentinel phrase.</p>
        \\<h1 id="while">while</h1>
        \\<p>Repeats while a condition is true.</p>
        \\</body></html>
        ,
    });

    const lib_dir = try tmpAbs(allocator, io, tmp.sub_path[0..], "lib");
    defer allocator.free(lib_dir);
    const text = try search(allocator, io, lib_dir, "scope exit sentinel", 5);
    defer allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "installed_langref_html") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Completeness: installed_complete") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "### defer (#defer)") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "bundled_langref_index") == null);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const value = try searchValue(arena.allocator(), io, lib_dir, "scope exit sentinel", 5);
    const obj = value.object;
    try std.testing.expectEqualStrings("installed_langref_html", obj.get("source").?.object.get("id").?.string);
    try std.testing.expectEqualStrings("installed_complete", obj.get("source").?.object.get("completeness").?.string);
    try std.testing.expectEqualStrings("installed_html_heading_scan", obj.get("index_metadata").?.object.get("index_strategy").?.string);
    try std.testing.expectEqual(@as(i64, 2), obj.get("index_metadata").?.object.get("indexed_section_count").?.integer);
    try std.testing.expectEqual(true, obj.get("index_metadata").?.object.get("installed_doc_available").?.bool);
    try std.testing.expectEqual(@as(i64, 0), obj.get("index_metadata").?.object.get("parse_failure_count").?.integer);
    try std.testing.expect(std.mem.indexOf(u8, obj.get("source").?.object.get("path").?.string, "langref.html") != null);
    try std.testing.expectEqualStrings("defer", obj.get("matches").?.array.items[0].object.get("anchor").?.string);
    try std.testing.expect(std.mem.indexOf(u8, obj.get("matches").?.array.items[0].object.get("summary").?.string, "scope exit sentinel") != null);
}

test "respects limit for installed html" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "lib/doc");
    try tmp.dir.writeFile(io, .{
        .sub_path = "lib/doc/langref.html",
        .data =
        \\<!doctype html>
        \\<html><head><title>Zig Language Reference</title></head><body>
        \\<h1 id="one">one</h1><p>shared limit token.</p>
        \\<h1 id="two">two</h1><p>shared limit token.</p>
        \\</body></html>
        ,
    });

    const lib_dir = try tmpAbs(allocator, io, tmp.sub_path[0..], "lib");
    defer allocator.free(lib_dir);
    const text = try search(allocator, io, lib_dir, "shared limit token", 1);
    defer allocator.free(text);

    try std.testing.expectEqual(@as(usize, 1), countOccurrences(text, "### "));
}

test "ranks title matches before body matches" {
    const text = try search(std.testing.allocator, std.testing.io, "/definitely/missing/zig/lib", "error", 1);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "### Error Sets (#Error-Set-Type)") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "### Defer (#defer)") == null);
}

fn tmpAbs(allocator: std.mem.Allocator, io: std.Io, tmp_sub_path: []const u8, child: []const u8) ![]u8 {
    const rel_base = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", tmp_sub_path });
    defer allocator.free(rel_base);
    const base_z = try std.Io.Dir.cwd().realPathFileAlloc(io, rel_base, allocator);
    defer allocator.free(base_z);
    return std.fs.path.join(allocator, &.{ base_z[0..], child });
}

fn countOccurrences(text: []const u8, needle: []const u8) usize {
    var count: usize = 0;
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, text, pos, needle)) |hit| {
        count += 1;
        pos = hit + needle.len;
    }
    return count;
}
