const std = @import("std");
const analysis_contract = @import("analysis_contract.zig");

pub fn declSummary(allocator: std.mem.Allocator, file: []const u8, contents: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.print(allocator, "# Declaration summary for {s}\n\n", .{file});
    try out.appendSlice(allocator, "Confidence: medium heuristic text scan (orientation_only). Verify with ZLS or `zig ast-check` before making destructive edits.\n\n");
    var lines = std.mem.splitScalar(u8, contents, '\n');
    var line_no: usize = 1;
    var count: usize = 0;
    while (lines.next()) |line| : (line_no += 1) {
        const trimmed = std.mem.trim(u8, line, " \t");
        if (isDeclarationLine(trimmed)) {
            count += 1;
            try out.print(allocator, "- {d}: `{s}`\n", .{ line_no, trimmed });
        }
    }
    if (count == 0) try out.appendSlice(allocator, "No top-level-looking declarations found.\n");
    return out.toOwnedSlice(allocator);
}

pub fn allocationSummary(allocator: std.mem.Allocator, file: []const u8, contents: []const u8) ![]u8 {
    return keywordSummary(allocator, file, contents, "allocation-related sites", &.{
        ".alloc(",
        ".create(",
        ".dupe(",
        "ArrayList",
        "ArenaAllocator",
        "GeneralPurposeAllocator",
    }, "Confidence: low heuristic keyword scan (orientation_only). Review matches before acting.\n\n");
}

pub fn errorSetSummary(allocator: std.mem.Allocator, file: []const u8, contents: []const u8) ![]u8 {
    return keywordSummary(allocator, file, contents, "error-related sites", &.{
        "error{",
        "anyerror",
        "catch",
        "try ",
        "!",
    }, "Confidence: low heuristic keyword scan (orientation_only). Review matches before acting.\n\n");
}

pub fn publicApiSummary(allocator: std.mem.Allocator, file: []const u8, contents: []const u8) ![]u8 {
    return keywordSummary(allocator, file, contents, "public API declarations", &.{
        "pub const ",
        "pub var ",
        "pub fn ",
        "pub extern ",
        "pub export ",
    }, "Confidence: medium heuristic keyword scan (advisory). Verify public API changes with ZLS, compiler checks, and release review.\n\n");
}

pub fn deadDeclCandidates(allocator: std.mem.Allocator, file: []const u8, contents: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.print(allocator, "# Dead declaration candidates for {s}\n\n", .{file});
    try out.appendSlice(allocator, "Confidence: low heuristic (orientation_only). Private declarations listed here still need reference checks before deletion.\n\n");

    var lines = std.mem.splitScalar(u8, contents, '\n');
    var line_no: usize = 1;
    var count: usize = 0;
    while (lines.next()) |line| : (line_no += 1) {
        const trimmed = std.mem.trim(u8, line, " \t");
        if (std.mem.startsWith(u8, trimmed, "const ") or std.mem.startsWith(u8, trimmed, "fn ")) {
            count += 1;
            try out.print(allocator, "- {d}: `{s}`\n", .{ line_no, trimmed });
        }
    }
    if (count == 0) try out.appendSlice(allocator, "No obvious private top-level declarations found.\n");
    return out.toOwnedSlice(allocator);
}

pub fn importGraph(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    limit: usize,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "# Import graph\n\n");
    try out.appendSlice(allocator, "Confidence: medium heuristic string-literal @import scan (orientation_only).\n\n");

    var dir = try std.Io.Dir.openDirAbsolute(io, root, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(allocator);
    defer walker.deinit();

    var files: usize = 0;
    var skipped: usize = 0;
    while (try walker.next(io)) |entry| {
        if (files >= limit) break;
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".zig")) continue;
        if (skipWorkspacePath(entry.path)) continue;

        const abs = try std.fs.path.join(allocator, &.{ root, entry.path });
        defer allocator.free(abs);
        const contents = std.Io.Dir.cwd().readFileAlloc(io, abs, allocator, .limited(512 * 1024)) catch |err| {
            skipped += 1;
            try out.print(allocator, "## {s}\n- skipped: {s}\n\n", .{ entry.path, @errorName(err) });
            continue;
        };
        defer allocator.free(contents);

        files += 1;
        try out.print(allocator, "## {s}\n", .{entry.path});
        var pos: usize = 0;
        var found = false;
        while (std.mem.indexOfPos(u8, contents, pos, "@import(\"")) |hit| {
            const start = hit + "@import(\"".len;
            const end = std.mem.indexOfScalarPos(u8, contents, start, '"') orelse break;
            try out.print(allocator, "- {s}\n", .{contents[start..end]});
            pos = end + 1;
            found = true;
        }
        if (!found) try out.appendSlice(allocator, "- no string-literal imports found\n");
        try out.append(allocator, '\n');
    }
    if (skipped > 0) try out.print(allocator, "\nSkipped unreadable files: {d}\n", .{skipped});
    return out.toOwnedSlice(allocator);
}

pub fn importGraphJson(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    limit: usize,
) !std.json.Value {
    var files = std.json.Array.init(allocator);
    var skipped_files = std.json.Array.init(allocator);
    var dir = try std.Io.Dir.openDirAbsolute(io, root, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(allocator);
    defer walker.deinit();
    var seen: usize = 0;
    while (try walker.next(io)) |entry| {
        if (seen >= limit) break;
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".zig")) continue;
        if (skipWorkspacePath(entry.path)) continue;
        const abs = try std.fs.path.join(allocator, &.{ root, entry.path });
        defer allocator.free(abs);
        const contents = std.Io.Dir.cwd().readFileAlloc(io, abs, allocator, .limited(512 * 1024)) catch |err| {
            try skipped_files.append(try skippedFileValue(allocator, entry.path, err));
            continue;
        };
        defer allocator.free(contents);
        seen += 1;
        var imports = std.json.Array.init(allocator);
        var pos: usize = 0;
        while (std.mem.indexOfPos(u8, contents, pos, "@import(\"")) |hit| {
            const start = hit + "@import(\"".len;
            const end = std.mem.indexOfScalarPos(u8, contents, start, '"') orelse break;
            try imports.append(try ownedString(allocator, contents[start..end]));
            pos = end + 1;
        }
        var file_obj = std.json.ObjectMap.empty;
        try file_obj.put(allocator, "file", try ownedString(allocator, entry.path));
        try file_obj.put(allocator, "imports", .{ .array = imports });
        try files.append(.{ .object = file_obj });
    }
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try analysis_contract.putMetadata(allocator, &obj, "zig_import_graph_json");
    try obj.put(allocator, "files", .{ .array = files });
    try obj.put(allocator, "file_count", .{ .integer = @intCast(seen) });
    try obj.put(allocator, "skipped_files", .{ .array = skipped_files });
    try obj.put(allocator, "skipped_file_count", .{ .integer = @intCast(skipped_files.items.len) });
    return .{ .object = obj };
}

pub fn declSummaryJson(allocator: std.mem.Allocator, file: []const u8, contents: []const u8) !std.json.Value {
    var decls = std.json.Array.init(allocator);
    var lines = std.mem.splitScalar(u8, contents, '\n');
    var line_no: usize = 1;
    while (lines.next()) |line| : (line_no += 1) {
        const trimmed = std.mem.trim(u8, line, " \t");
        const kind = declKind(trimmed) orelse continue;
        var item = std.json.ObjectMap.empty;
        try item.put(allocator, "line", .{ .integer = @intCast(line_no) });
        try item.put(allocator, "kind", .{ .string = kind });
        try item.put(allocator, "public", .{ .bool = std.mem.startsWith(u8, trimmed, "pub ") });
        try item.put(allocator, "text", try ownedString(allocator, trimmed));
        try decls.append(.{ .object = item });
    }
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "file", try ownedString(allocator, file));
    try analysis_contract.putMetadata(allocator, &obj, "zig_decl_summary_json");
    try obj.put(allocator, "declarations", .{ .array = decls });
    return .{ .object = obj };
}

pub fn testDiscoverJson(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    limit: usize,
) !std.json.Value {
    var tests = std.json.Array.init(allocator);
    var skipped_files = std.json.Array.init(allocator);
    var dir = try std.Io.Dir.openDirAbsolute(io, root, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(allocator);
    defer walker.deinit();
    var count: usize = 0;
    while (try walker.next(io)) |entry| {
        if (count >= limit) break;
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".zig") or skipWorkspacePath(entry.path)) continue;
        const abs = try std.fs.path.join(allocator, &.{ root, entry.path });
        defer allocator.free(abs);
        const contents = std.Io.Dir.cwd().readFileAlloc(io, abs, allocator, .limited(512 * 1024)) catch |err| {
            try skipped_files.append(try skippedFileValue(allocator, entry.path, err));
            continue;
        };
        defer allocator.free(contents);
        var lines = std.mem.splitScalar(u8, contents, '\n');
        var line_no: usize = 1;
        while (lines.next()) |line| : (line_no += 1) {
            if (count >= limit) break;
            const trimmed = std.mem.trim(u8, line, " \t");
            if (!std.mem.startsWith(u8, trimmed, "test ")) continue;
            count += 1;
            var obj = std.json.ObjectMap.empty;
            try obj.put(allocator, "file", try ownedString(allocator, entry.path));
            try obj.put(allocator, "line", .{ .integer = @intCast(line_no) });
            try obj.put(allocator, "declaration", try ownedString(allocator, trimmed));
            try obj.put(allocator, "command", .{ .string = try std.fmt.allocPrint(allocator, "zig test {s}", .{entry.path}) });
            try tests.append(.{ .object = obj });
        }
    }
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try analysis_contract.putMetadata(allocator, &obj, "zig_test_discover");
    try obj.put(allocator, "tests", .{ .array = tests });
    try obj.put(allocator, "count", .{ .integer = @intCast(count) });
    try obj.put(allocator, "skipped_files", .{ .array = skipped_files });
    try obj.put(allocator, "skipped_file_count", .{ .integer = @intCast(skipped_files.items.len) });
    return .{ .object = obj };
}

fn skippedFileValue(allocator: std.mem.Allocator, path: []const u8, err: anyerror) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "path", try ownedString(allocator, path));
    try obj.put(allocator, "error", try ownedString(allocator, @errorName(err)));
    return .{ .object = obj };
}

fn keywordSummary(
    allocator: std.mem.Allocator,
    file: []const u8,
    contents: []const u8,
    title: []const u8,
    keywords: []const []const u8,
    confidence_line: []const u8,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.print(allocator, "# {s} for {s}\n\n", .{ title, file });
    try out.appendSlice(allocator, confidence_line);

    var lines = std.mem.splitScalar(u8, contents, '\n');
    var line_no: usize = 1;
    var count: usize = 0;
    while (lines.next()) |line| : (line_no += 1) {
        for (keywords) |keyword| {
            if (std.mem.indexOf(u8, line, keyword) != null) {
                count += 1;
                try out.print(allocator, "- {d}: `{s}`\n", .{ line_no, std.mem.trim(u8, line, " \t") });
                break;
            }
        }
    }
    if (count == 0) try out.appendSlice(allocator, "No matches found.\n");
    return out.toOwnedSlice(allocator);
}

fn ownedString(allocator: std.mem.Allocator, value: []const u8) !std.json.Value {
    return .{ .string = try allocator.dupe(u8, value) };
}

fn isDeclarationLine(line: []const u8) bool {
    return std.mem.startsWith(u8, line, "pub const ") or
        std.mem.startsWith(u8, line, "pub var ") or
        std.mem.startsWith(u8, line, "pub fn ") or
        std.mem.startsWith(u8, line, "const ") or
        std.mem.startsWith(u8, line, "var ") or
        std.mem.startsWith(u8, line, "fn ");
}

pub fn declKind(line: []const u8) ?[]const u8 {
    const rest = if (std.mem.startsWith(u8, line, "pub ")) line["pub ".len..] else line;
    if (std.mem.startsWith(u8, rest, "const ")) return "const";
    if (std.mem.startsWith(u8, rest, "var ")) return "var";
    if (std.mem.startsWith(u8, rest, "fn ")) return "fn";
    if (std.mem.startsWith(u8, rest, "extern ")) return "extern";
    if (std.mem.startsWith(u8, rest, "export ")) return "export";
    return null;
}

pub fn skipWorkspacePath(path: []const u8) bool {
    return std.mem.startsWith(u8, path, ".zig-cache") or
        std.mem.startsWith(u8, path, ".zigar-cache") or
        std.mem.startsWith(u8, path, "zig-out") or
        std.mem.startsWith(u8, path, "zig-pkg") or
        std.mem.indexOf(u8, path, "/.zig-cache/") != null or
        std.mem.indexOf(u8, path, "/.zigar-cache/") != null or
        std.mem.indexOf(u8, path, "/zig-out/") != null or
        std.mem.indexOf(u8, path, "/zig-pkg/") != null;
}

test "declaration summary finds pub fn" {
    const text = try declSummary(std.testing.allocator, "x.zig", "pub fn main() void {}\nconst A = u8;\n");
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "pub fn main") != null);
}

test "declaration summary json classifies declarations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const value = try declSummaryJson(arena.allocator(), "x.zig", "pub fn main() void {}\nconst A = u8;\n");
    const decls = value.object.get("declarations").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), decls.len);
    try std.testing.expectEqualStrings("fn", decls[0].object.get("kind").?.string);
    try std.testing.expect(decls[0].object.get("public").?.bool);
}

test "import graph skips cache and vendored package paths" {
    try std.testing.expect(skipWorkspacePath(".zig-cache/o/file.zig"));
    try std.testing.expect(skipWorkspacePath(".zigar-cache/profile/out.zig"));
    try std.testing.expect(skipWorkspacePath("zig-out/bin/main.zig"));
    try std.testing.expect(skipWorkspacePath("zig-pkg/mcp/src/server.zig"));
    try std.testing.expect(!skipWorkspacePath("src/main.zig"));
}

test "heuristic JSON scans report skipped file count" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const rel_base = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    const root_z = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, rel_base, allocator);
    const root = root_z[0..];

    const imports = try importGraphJson(allocator, std.testing.io, root, 10);
    try std.testing.expectEqualStrings("heuristic_import_scan", imports.object.get("analysis_kind").?.string);
    try std.testing.expectEqualStrings("orientation_only", imports.object.get("confidence_class").?.string);
    try std.testing.expect(imports.object.get("limitations").?.array.items.len > 0);
    try std.testing.expectEqual(@as(i64, 0), imports.object.get("skipped_file_count").?.integer);

    const tests = try testDiscoverJson(allocator, std.testing.io, root, 10);
    try std.testing.expectEqualStrings("heuristic_test_scan", tests.object.get("analysis_kind").?.string);
    try std.testing.expectEqualStrings("orientation_only", tests.object.get("confidence_class").?.string);
    try std.testing.expect(tests.object.get("verify_with").?.array.items.len > 0);
    try std.testing.expectEqual(@as(i64, 0), tests.object.get("skipped_file_count").?.integer);
}
