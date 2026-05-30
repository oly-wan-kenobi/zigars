//! Tests for coverage_model: LCOV and JSON parsing, merge semantics, changed-file
//! filtering, overflow safety for huge counts, and integer-field coercion.

const std = @import("std");

const coverage_model = @import("coverage_model.zig");

test "coverage parser normalizes LCOV and merge totals" {
    const allocator = std.testing.allocator;
    var left = try coverage_model.parse(allocator,
        \\SF:src/a.zig
        \\DA:1,1
        \\DA:2,0
        \\end_of_record
        \\
    , "fixture", "auto");
    defer left.deinit(allocator);
    var right = try coverage_model.parse(allocator,
        \\SF:src/b.zig
        \\DA:1,3
        \\end_of_record
        \\
    , "fixture", "auto");
    defer right.deinit(allocator);
    var merged = try coverage_model.merge(allocator, left, right);
    defer merged.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 3), merged.total);
    try std.testing.expectEqual(@as(usize, 2), merged.covered);
    try std.testing.expectEqual(@as(usize, 6666), coverage_model.rateBp(merged.covered, merged.total));
}

test "coverage parser accepts zigars coverage JSON" {
    const allocator = std.testing.allocator;
    var set = try coverage_model.parse(allocator,
        \\{"coverage":{"total_lines":2},"files":[{"path":"src/main.zig","total_lines":2,"covered_lines":1}]}
    , "fixture", "auto");
    defer set.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), set.total);
    try std.testing.expectEqual(@as(usize, 1), set.covered);
    try std.testing.expectEqualStrings("src/main.zig", set.files.items[0].path);
}

test "changed coverage only counts named files present in evidence" {
    const allocator = std.testing.allocator;
    var set = try coverage_model.parse(allocator,
        \\SF:src/a.zig
        \\DA:1,1
        \\DA:2,0
        \\end_of_record
        \\SF:src/b.zig
        \\DA:1,0
        \\end_of_record
        \\
    , "fixture", "auto");
    defer set.deinit(allocator);

    const changed = coverage_model.changedCoverage(set, &.{ "src/a.zig", "src/missing.zig" });
    try std.testing.expectEqual(@as(usize, 1), changed.count);
    try std.testing.expectEqual(@as(usize, 2), changed.total);
    try std.testing.expectEqual(@as(usize, 1), changed.covered);
}

test "coverage model parses nested and array JSON evidence shapes" {
    const allocator = std.testing.allocator;
    var nested = try coverage_model.parse(allocator,
        \\{"baseline":{"coverage":{"files":[{"path":"src/nested.zig","total_lines":4,"covered_lines":2}]}}}
    , "fixture", "json");
    defer nested.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 4), nested.total);
    try std.testing.expectEqual(@as(usize, 2), nested.covered);
    try std.testing.expectEqualStrings("src/nested.zig", nested.files.items[0].path);

    var array = try coverage_model.parse(allocator,
        \\[{"file":"src/array.zig","total":3,"covered":5},{"path":"","total":1,"covered":1},{"path":"src/defaults.zig"}]
    , "fixture", "json");
    defer array.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 3), array.total);
    try std.testing.expectEqual(@as(usize, 3), array.covered);
    try std.testing.expectEqualStrings("src/array.zig", array.files.items[0].path);

    var fallback_nested = try coverage_model.parse(allocator,
        \\{"files":[],"coverage":{"files":[{"path":"src/fallback.zig","total":2,"covered":1}]}}
    , "fixture", "json");
    defer fallback_nested.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), fallback_nested.total);
    try std.testing.expectEqualStrings("src/fallback.zig", fallback_nested.files.items[0].path);

    try std.testing.expectError(error.InvalidCoverageEvidence, coverage_model.parse(allocator, "{\"coverage\":true}", "fixture", "json"));
}
