const std = @import("std");

const benchmark = @import("benchmark.zig");

test "benchmark compare returns typed regression and improvement buckets" {
    var result = try benchmark.compare(std.testing.allocator, .{
        .current = .{ .bytes = "parse: 120 ns\nemit: 75 ns\n", .source_kind = "current" },
        .baseline = .{ .bytes = "parse: 100 ns\nemit: 100 ns\n", .source_kind = "baseline" },
        .threshold_pct = 5,
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), result.compared_count);
    try std.testing.expectEqual(@as(usize, 1), result.regressions.items.len);
    try std.testing.expectEqual(@as(usize, 1), result.improvements.items.len);
    try std.testing.expect(!result.passed());
}

test "performance budget classifies worst regression against supplied threshold" {
    const result = try benchmark.budget(std.testing.allocator, .{
        .comparison =
        \\{"regression_count":1,"worst_regression_pct":6.25}
        ,
        .max_regression_pct = 5,
    });

    try std.testing.expectEqual(@as(usize, 1), result.summary.regression_count);
    try std.testing.expect(!result.passed());
}

test "profile regression plan selects backend-aware recommendation set" {
    const tracy = try benchmark.planProfileRegression(std.testing.allocator, .{
        .comparison =
        \\{"regressions":[{"name":"parse","delta_pct":9.0}]}
        ,
        .backend = "tracy",
    });
    try std.testing.expect(tracy.needsProfile());
    try std.testing.expectEqualStrings("zig_tracy_plan", tracy.recommendedTools()[0]);

    const samply = try benchmark.planProfileRegression(std.testing.allocator, .{
        .comparison =
        \\{"regression_count":0,"worst_regression_pct":0}
        ,
        .backend = "samply",
    });
    try std.testing.expect(!samply.needsProfile());
    try std.testing.expectEqualStrings("zig_samply_record", samply.recommendedTools()[0]);
}
