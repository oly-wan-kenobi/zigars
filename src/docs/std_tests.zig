const std = @import("std");
const builtin = @import("builtin");

const std_docs = @import("std.zig");

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
    const text = try std_docs.searchStd(allocator, io, std_dir, "docs_only_token", 10);
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
    const value = try std_docs.stdSearchValue(arena.allocator(), io, std_dir, "token", 1);
    const obj = value.object;
    try std.testing.expectEqualStrings("local_stdlib_zig_source", obj.get("source").?.object.get("id").?.string);
    try std.testing.expectEqualStrings("source_scan", obj.get("source").?.object.get("completeness").?.string);
    try std.testing.expectEqual(@as(i64, 1), obj.get("limit").?.integer);
    try std.testing.expectEqual(@as(i64, 1), obj.get("result_count").?.integer);
    try std.testing.expectEqual(@as(i64, 2), obj.get("total_match_count").?.integer);
    try std.testing.expectEqualStrings("a_first.zig", obj.get("matches").?.array.items[0].object.get("path").?.string);
    try std.testing.expect(std.mem.endsWith(u8, obj.get("matches").?.array.items[0].object.get("source_path").?.string, "std/a_first.zig"));
    try std.testing.expectEqualStrings("const", obj.get("matches").?.array.items[0].object.get("match_kind").?.string);
    try std.testing.expectEqualStrings("std.a_first.token", obj.get("matches").?.array.items[0].object.get("qualified_name").?.string);
    try std.testing.expect(std.mem.indexOf(u8, obj.get("source_scan_limitations").?.string, "Source scan only") != null);
    try std.testing.expect(obj.get("no_result_reason").? == .null);
}

test "std item JSON uses exact declaration lookup and no-match contract" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "std/fs");
    try tmp.dir.writeFile(io, .{
        .sub_path = "std/fs/path.zig",
        .data =
        \\/// Join path segments.
        \\/// Returns an owned path buffer.
        \\pub fn join() void {}
        \\
        ,
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "std/other.zig", .data = "pub fn join() void {}\n" });

    const std_dir = try tmpAbs(allocator, io, tmp.sub_path[0..], "std");
    defer allocator.free(std_dir);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const hit = try std_docs.stdItemValue(arena.allocator(), io, std_dir, "std.fs.path.join", 1);
    const hit_obj = hit.object;
    const first = hit_obj.get("matches").?.array.items[0].object;
    try std.testing.expectEqualStrings("local_stdlib_zig_source", hit_obj.get("source").?.object.get("id").?.string);
    try std.testing.expectEqualStrings("source_scan", hit_obj.get("source").?.object.get("completeness").?.string);
    try std.testing.expectEqualStrings("fs/path.zig", hit_obj.get("qualified_path_hint").?.string);
    try std.testing.expectEqualStrings("fs/path.zig", first.get("path").?.string);
    try std.testing.expect(std.mem.endsWith(u8, first.get("source_path").?.string, "std/fs/path.zig"));
    try std.testing.expect(first.get("preferred_path").?.bool);
    try std.testing.expectEqualStrings("fn", first.get("match_kind").?.string);
    try std.testing.expectEqualStrings("std.fs.path.join", first.get("qualified_name").?.string);
    try std.testing.expectEqualStrings("std.fs.path.join", first.get("import_hint").?.string);
    try std.testing.expectEqual(@as(i64, 2), first.get("doc_comment_count").?.integer);
    try std.testing.expect(std.mem.indexOf(u8, first.get("doc_comments").?.string, "Join path segments.") != null);
    try std.testing.expectEqualStrings("in_memory_stdlib_source_scan", hit_obj.get("index_metadata").?.object.get("index_strategy").?.string);

    const miss = try std_docs.stdItemValue(arena.allocator(), io, std_dir, "std.fs.path.missing", 3);
    const miss_obj = miss.object;
    try std.testing.expectEqual(@as(i64, 0), miss_obj.get("result_count").?.integer);
    try std.testing.expectEqualStrings("no_std_item_declaration_match", miss_obj.get("no_result_reason").?.string);
}

fn tmpAbs(allocator: std.mem.Allocator, io: std.Io, tmp_sub_path: []const u8, child: []const u8) ![]u8 {
    const rel_base = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", tmp_sub_path });
    defer allocator.free(rel_base);
    const base_z = try std.Io.Dir.cwd().realPathFileAlloc(io, rel_base, allocator);
    defer allocator.free(base_z);
    return std.fs.path.join(allocator, &.{ base_z[0..], child });
}
