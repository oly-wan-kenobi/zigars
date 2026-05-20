const std = @import("std");
const builtin = @import("builtin");
const json_result = @import("json_result.zig");

pub const docs_source = @import("docs/source.zig");

const builtin_docs = @import("docs/builtins.zig");
const langref = @import("docs/langref.zig");
const std_docs = @import("docs/std.zig");

pub const BuiltinDoc = builtin_docs.BuiltinDoc;
pub const LangRefSection = langref.Section;

pub const builtins = builtin_docs.builtins;
pub const langref_sections = langref.sections;

pub const builtinList = builtin_docs.builtinList;
pub const builtinListValue = builtin_docs.builtinListValue;
pub const builtinDoc = builtin_docs.builtinDoc;
pub const builtinDocValue = builtin_docs.builtinDocValue;
pub const searchStd = std_docs.searchStd;
pub const stdSearchValue = std_docs.stdSearchValue;
pub const stdItem = std_docs.stdItem;
pub const stdItemValue = std_docs.stdItemValue;
pub const langRefSearch = langref.search;
pub const langRefSearchValue = langref.searchValue;

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
        const value = try builtinListValue(allocator, null);
        const result = try json_result.structuredOwned(allocator, value);
        defer json_result.deinitToolResult(allocator, result);
        try std.testing.expectEqualStrings("curated_zigar_builtins", result.structuredContent.?.object.get("source").?.object.get("id").?.string);
    }
    {
        const value = try builtinDocValue(allocator, "import", 1, null);
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
    _ = builtin_docs;
    _ = langref;
    _ = std_docs;
}

fn tmpAbs(allocator: std.mem.Allocator, io: std.Io, tmp_sub_path: []const u8, child: []const u8) ![]u8 {
    const rel_base = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", tmp_sub_path });
    defer allocator.free(rel_base);
    const base_z = try std.Io.Dir.cwd().realPathFileAlloc(io, rel_base, allocator);
    defer allocator.free(base_z);
    return std.fs.path.join(allocator, &.{ base_z[0..], child });
}
