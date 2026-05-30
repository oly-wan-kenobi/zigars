//! Tests for benchmark_model: parsing (text and JSON), comparison classification,
//! summary evaluation, and allocation-failure cleanup contracts.

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

test "benchmark parser covers nested JSON and timing unit edges" {
    const allocator = std.testing.allocator;
    var json_set = try benchmark_model.parseEvidence(allocator,
        \\{"results":{"baseline":[{"benchmark":"parse","time_ns":42.5},{"name":"emit","mean_ns":7}]}}
    , "json-fixture");
    defer json_set.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), json_set.samples.items.len);
    try std.testing.expectEqualStrings("parse", json_set.samples.items[0].name);
    try std.testing.expectEqual(@as(f64, 42.5), json_set.samples.items[0].ns_per_iter);
    try std.testing.expectEqual(@as(f64, 7), json_set.samples.items[1].ns_per_iter);

    var text_set = try benchmark_model.parseText(allocator,
        \\build 3 ms
        \\e2e 1 s
    );
    defer text_set.deinit(allocator);
    try std.testing.expectEqual(@as(f64, 3_000_000), text_set.samples.items[0].ns_per_iter);
    try std.testing.expectEqual(@as(f64, 1_000_000_000), text_set.samples.items[1].ns_per_iter);
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

test "benchmark comparison skips unmatched and zero baselines" {
    const allocator = std.testing.allocator;
    var current = try benchmark_model.parseEvidence(allocator,
        \\[{"name":"parse","ns_per_iter":100},{"name":"missing","ns_per_iter":100}]
    , "fixture");
    defer current.deinit(allocator);
    var baseline = try benchmark_model.parseEvidence(allocator,
        \\[{"name":"parse","ns_per_iter":0}]
    , "fixture");
    defer baseline.deinit(allocator);
    var comparison = try benchmark_model.compare(allocator, current, baseline, 5);
    defer comparison.deinit(allocator);

    try std.testing.expect(comparison.passed());
    try std.testing.expectEqual(@as(usize, 1), comparison.compared_count);
    try std.testing.expect(benchmark_model.findSample(current, "absent") == null);
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

test "benchmark summary accepts scalar counts and invalid roots" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const summary = try benchmark_model.compareSummaryFromJson(arena.allocator(),
        \\{"regression_count":-2,"worst_regression_pct":4}
    );
    try std.testing.expectEqual(@as(usize, 0), summary.regression_count);
    try std.testing.expectEqual(@as(f64, 4), summary.worst_regression_pct);
    try std.testing.expectError(error.InvalidBenchmarkEvidence, benchmark_model.compareSummaryFromJson(arena.allocator(), "[]"));
}

test "benchmark model allocation failure cleanup is bounded" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, parseTextWithAllocator, .{});
    try std.testing.checkAllAllocationFailures(std.testing.allocator, parseJsonWithAllocator, .{});
    try std.testing.checkAllAllocationFailures(std.testing.allocator, compareBenchmarksWithAllocator, .{});
}

/// Exercises text benchmark parsing under allocation-failure testing.
fn parseTextWithAllocator(allocator: std.mem.Allocator) !void {
    var set = try benchmark_model.parseText(allocator,
        \\parse small: 12.5 ns
        \\encode big 2 us
    );
    defer set.deinit(allocator);
}

/// Exercises JSON benchmark parsing under allocation-failure testing.
fn parseJsonWithAllocator(allocator: std.mem.Allocator) !void {
    var set = try benchmark_model.parseEvidence(allocator,
        \\{"benchmarks":[{"name":"parse","ns_per_iter":112.0},{"name":"emit","ns_per_iter":80.0}]}
    , "fixture");
    defer set.deinit(allocator);
}

/// Exercises benchmark comparison under allocation-failure testing.
fn compareBenchmarksWithAllocator(allocator: std.mem.Allocator) !void {
    var current = try benchmark_model.parseEvidence(allocator,
        \\[{"name":"parse","ns_per_iter":112},{"name":"emit","ns_per_iter":80}]
    , "fixture");
    defer current.deinit(allocator);
    var baseline = try benchmark_model.parseEvidence(allocator,
        \\[{"name":"parse","ns_per_iter":100},{"name":"emit","ns_per_iter":100}]
    , "fixture");
    defer baseline.deinit(allocator);
    var comparison = try benchmark_model.compare(allocator, current, baseline, 5);
    defer comparison.deinit(allocator);
}
