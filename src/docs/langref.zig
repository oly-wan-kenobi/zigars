const std = @import("std");
const builtin = @import("builtin");

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

pub fn search(allocator: std.mem.Allocator, io: std.Io, lib_dir: []const u8, query: []const u8, limit: usize) ![]u8 {
    const normalized_limit = @max(limit, 1);
    if (try findHtml(allocator, io, lib_dir)) |path| {
        defer allocator.free(path);
        const contents = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(2 * 1024 * 1024));
        defer allocator.free(contents);
        return searchHtml(allocator, path, contents, query, normalized_limit);
    }
    return searchBundled(allocator, query, normalized_limit);
}

fn findHtml(allocator: std.mem.Allocator, io: std.Io, lib_dir: []const u8) !?[]u8 {
    const candidates = [_][]const u8{
        "doc/langref.html",
        "doc/langref.html.in",
        "docs/langref.html",
        "docs/langref.html.in",
        "langref.html",
        "docs/index.html",
    };
    for (candidates) |rel| {
        const path = try std.fs.path.join(allocator, &.{ lib_dir, rel });
        errdefer allocator.free(path);
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(128 * 1024)) catch {
            allocator.free(path);
            continue;
        };
        defer allocator.free(bytes);
        if (looksLikeLangRef(rel, bytes)) return path;
        allocator.free(path);
    }
    return null;
}

fn looksLikeLangRef(rel_path: []const u8, bytes: []const u8) bool {
    if (std.mem.indexOf(u8, bytes, "Language Reference") != null or
        std.mem.indexOf(u8, bytes, "Zig Language Reference") != null)
    {
        return true;
    }
    if (std.mem.indexOf(u8, rel_path, "langref") == null) return false;
    return std.mem.indexOf(u8, bytes, "Zig") != null or std.mem.indexOf(u8, bytes, "zig") != null;
}

fn searchBundled(allocator: std.mem.Allocator, query: []const u8, limit: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    const lower_query = try asciiLowerAlloc(allocator, query);
    defer allocator.free(lower_query);

    try out.print(allocator, "Language reference search source: bundled_langref_index\nQuery: `{s}`\n\n", .{query});
    var count = try appendBundledMatches(allocator, &out, lower_query, limit, .title);
    if (count < limit) {
        count += try appendBundledMatches(allocator, &out, lower_query, limit - count, .body);
    }

    if (count == 0) {
        try out.print(allocator, "No language reference matches for `{s}` in the bundled index.\n", .{query});
    }
    return out.toOwnedSlice(allocator);
}

const MatchPass = enum { title, body };

fn appendBundledMatches(allocator: std.mem.Allocator, out: *std.ArrayList(u8), lower_query: []const u8, limit: usize, pass: MatchPass) !usize {
    var count: usize = 0;
    for (sections) |section| {
        if (count >= limit) break;
        if (!sectionMatches(section, lower_query, pass)) continue;
        count += 1;
        try out.print(
            allocator,
            "### {s} (#{s})\n\nSource: bundled Zig language reference index\n\n{s}\n\n{s}\n\n",
            .{ section.title, section.anchor, section.summary, section.body },
        );
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

fn searchHtml(allocator: std.mem.Allocator, path: []const u8, html: []const u8, query: []const u8, limit: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    const lower_query = try asciiLowerAlloc(allocator, query);
    defer allocator.free(lower_query);

    try out.print(allocator, "Language reference search source: installed_langref_html\nPath: {s}\nQuery: `{s}`\n\n", .{ path, query });
    var count: usize = 0;
    var pos: usize = 0;
    while (count < limit) {
        const heading = nextHeading(html, pos) orelse break;
        pos = heading.end;
        const next = nextHeading(html, pos);
        const section_end = if (next) |n| n.start else html.len;
        const section_html = html[heading.start..section_end];
        const text = try stripHtmlAlloc(allocator, section_html);
        defer allocator.free(text);
        const lower_text = try asciiLowerAlloc(allocator, text);
        defer allocator.free(lower_text);
        if (std.mem.indexOf(u8, lower_text, lower_query) == null) continue;

        count += 1;
        const title = try stripHtmlAlloc(allocator, heading.title_html);
        defer allocator.free(title);
        const snippet = snippetForQuery(text, lower_text, lower_query);
        try out.print(
            allocator,
            "### {s} (#{s})\n\nSource: {s}\n\n{s}\n\n",
            .{ std.mem.trim(u8, title, " \t\r\n"), heading.anchor, path, std.mem.trim(u8, snippet, " \t\r\n") },
        );
    }

    if (count == 0) {
        try out.print(allocator, "No language reference matches for `{s}` in {s}.\n", .{ query, path });
    }
    return out.toOwnedSlice(allocator);
}

const HtmlHeading = struct {
    start: usize,
    end: usize,
    anchor: []const u8,
    title_html: []const u8,
};

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
        const anchor = headingAnchor(open_tag) orelse "";
        return .{
            .start = start,
            .end = close_end + 1,
            .anchor = anchor,
            .title_html = html[open_end + 1 .. close],
        };
    }
    return null;
}

fn headingAnchor(open_tag: []const u8) ?[]const u8 {
    const id_pos = std.mem.indexOf(u8, open_tag, "id=\"") orelse return null;
    const start = id_pos + 4;
    const end = std.mem.indexOfScalarPos(u8, open_tag, start, '"') orelse return null;
    return open_tag[start..end];
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

fn asciiLowerAlloc(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    const out = try allocator.alloc(u8, input.len);
    for (input, 0..) |c, i| out[i] = std.ascii.toLower(c);
    return out;
}

test "uses bundled index when installed langref is absent" {
    const text = try search(std.testing.allocator, std.testing.io, "/definitely/missing/zig/lib", "defer", 3);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "bundled_langref_index") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "### Defer (#defer)") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "errdefer") != null);
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
        \\<p>Autodoc search result shell, not the language reference.</p>
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
    try std.testing.expect(std.mem.indexOf(u8, text, "### defer (#defer)") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "bundled_langref_index") == null);
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
