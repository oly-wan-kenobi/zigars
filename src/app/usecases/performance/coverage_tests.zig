//! Pins the coverage use case: the budget enforces the changed-file floor independently
//! of the overall floor (both in basis points), and diff takes ownership of both parsed
//! sets while reporting the line-rate delta in bp.
const std = @import("std");

const coverage = @import("coverage.zig");

test "coverage budget fails changed-file floor independently of overall floor" {
    var result = try coverage.budget(std.testing.allocator, .{
        .coverage = .{
            .bytes =
            \\SF:src/covered.zig
            \\DA:1,1
            \\DA:2,1
            \\end_of_record
            \\SF:src/changed.zig
            \\DA:1,0
            \\end_of_record
            \\
            ,
            .source_kind = "fixture",
        },
        .changed_files = &.{"src/changed.zig"},
        .min_line_rate_bp = 6000,
        .min_changed_line_rate_bp = 5000,
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 6666), result.line_rate_bp);
    try std.testing.expectEqual(@as(usize, 0), result.changed_line_rate_bp);
    try std.testing.expect(!result.passed());
}

test "coverage diff owns parsed current and baseline evidence" {
    var result = try coverage.diff(std.testing.allocator, .{
        .current = .{
            .bytes = "SF:src/a.zig\nDA:1,1\nDA:2,1\nend_of_record\n",
            .source_kind = "current",
        },
        .baseline = .{
            .bytes = "SF:src/a.zig\nDA:1,1\nDA:2,0\nend_of_record\n",
            .source_kind = "baseline",
        },
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(i64, 5000), result.line_rate_delta_bp);
    try std.testing.expectEqualStrings("current", result.current.source_kind);
    try std.testing.expectEqualStrings("baseline", result.baseline.source_kind);
}
