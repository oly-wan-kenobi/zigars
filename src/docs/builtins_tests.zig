const std = @import("std");

const builtin_docs = @import("builtins.zig");

test "builtin docs find import" {
    const text = try builtin_docs.builtinDoc(std.testing.allocator, "import", 20, "0.16.0");
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

    const hit = try builtin_docs.builtinDocValue(allocator, "import", 1, "0.16.0");
    const hit_obj = hit.object;
    try std.testing.expectEqualStrings("curated_zigar_builtins", hit_obj.get("source").?.object.get("id").?.string);
    try std.testing.expectEqualStrings("partial_curated", hit_obj.get("source").?.object.get("completeness").?.string);
    try std.testing.expectEqualStrings("0.16.0", hit_obj.get("index_metadata").?.object.get("toolchain_version").?.string);
    try std.testing.expectEqual(@as(i64, 1), hit_obj.get("limit").?.integer);
    try std.testing.expectEqual(@as(i64, 1), hit_obj.get("result_count").?.integer);
    try std.testing.expect(hit_obj.get("no_result_reason").? == .null);
    try std.testing.expectEqualStrings("@import", hit_obj.get("matches").?.array.items[0].object.get("name").?.string);

    const miss = try builtin_docs.builtinDocValue(allocator, "definitely_not_a_builtin", 5, null);
    const miss_obj = miss.object;
    try std.testing.expectEqual(@as(i64, 0), miss_obj.get("result_count").?.integer);
    try std.testing.expectEqualStrings("no_builtin_match", miss_obj.get("no_result_reason").?.string);
}
