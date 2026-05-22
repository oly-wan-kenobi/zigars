const std = @import("std");

const benchmark_model = @import("benchmark_model.zig");

test "benchmark parser reads simple timing lines" {
    const allocator = std.testing.allocator;
    var set = try benchmark_model.parseText(allocator,
        \\parse small: 12.5 ns
        \\encode big 2 us
        \\
    );
    defer set.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), set.samples.items.len);
    try std.testing.expectEqualStrings("parse small", set.samples.items[0].name);
    try std.testing.expectEqual(@as(f64, 2000), set.samples.items[1].ns_per_iter);
}

test "benchmark comparison classifies regressions and improvements" {
    const allocator = std.testing.allocator;
    var current = try benchmark_model.parseEvidence(allocator,
        \\{"benchmarks":[{"name":"parse","ns_per_iter":112.0},{"name":"emit","ns_per_iter":80.0}]}
    , "fixture");
    defer current.deinit(allocator);
    var baseline = try benchmark_model.parseEvidence(allocator,
        \\{"benchmarks":[{"name":"parse","ns_per_iter":100.0},{"name":"emit","ns_per_iter":100.0}]}
    , "fixture");
    defer baseline.deinit(allocator);
    var comparison = try benchmark_model.compare(allocator, current, baseline, 5);
    defer comparison.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), comparison.compared_count);
    try std.testing.expectEqual(@as(usize, 1), comparison.regressions.items.len);
    try std.testing.expectEqual(@as(usize, 1), comparison.improvements.items.len);
    try std.testing.expect(!comparison.passed());
}

test "benchmark comparison summaries detect regressions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const summary = try benchmark_model.compareSummaryFromJson(arena.allocator(),
        \\{"regressions":[{"name":"parse","delta_pct":12.5}],"worst_regression_pct":12.5}
    );
    try std.testing.expectEqual(@as(usize, 1), summary.regression_count);
    try std.testing.expectEqual(@as(f64, 12.5), summary.worst_regression_pct);
    try std.testing.expect(!benchmark_model.budgetPassed(summary, 5));
}
