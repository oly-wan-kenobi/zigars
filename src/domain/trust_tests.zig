//! Behavioral tests for trust.zig: risk-level classification, clean-tree gate
//! parsing with generated-path evidence, and allocation-failure cleanup.

const std = @import("std");

const trust = @import("trust.zig");

test "risk metadata classifies execution and mutation levels" {
    try std.testing.expectEqualStrings("high", trust.riskLevel(.{ .writes_source = true }));
    try std.testing.expectEqualStrings("medium", trust.riskLevel(.{ .writes_artifacts = true }));
    try std.testing.expectEqualStrings("low", trust.riskLevel(.{ .executes_backend = true }));
    try std.testing.expectEqualStrings("none", trust.riskLevel(.{}));
}

test "clean tree gate parses porcelain status with generated path evidence" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const value = try trust.cleanTreeGateFromStatus(arena.allocator(), "/tmp/work", " M src/main.zig\n?? zig-out/bin/app\n", true, "fixture");
    const obj = value.object;
    try std.testing.expectEqualStrings("zigars_clean_tree_gate", obj.get("kind").?.string);
    try std.testing.expect(!obj.get("clean").?.bool);
    try std.testing.expectEqual(@as(i64, 2), obj.get("changed_count").?.integer);
    try std.testing.expectEqual(@as(i64, 1), obj.get("untracked_count").?.integer);
    try std.testing.expectEqual(@as(i64, 1), obj.get("generated_or_vendored_count").?.integer);
}

test "trust JSON builders clean up allocation failures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, trustValuesWithAllocator, .{});
}

/// Exercises trust JSON construction under allocation-failure testing.
fn trustValuesWithAllocator(allocator: std.mem.Allocator) !void {
    // Keep this logic centralized so callers observe one consistent behavior path.
    const gate = try trust.cleanTreeGateFromStatus(allocator, "/tmp/work", " M src/main.zig\n?? zig-out/bin/app\n", true, "fixture");
    defer trust.deinitOwnedValue(allocator, gate);

    const evidence_value = try trust.evidenceValue(allocator, "git", "git status --porcelain stdout", "high");
    defer trust.deinitOwnedValue(allocator, evidence_value);

    const array = try trust.stringArray(allocator, &.{ "zig build test", "zig build docs-check" });
    defer trust.deinitOwnedValue(allocator, array);
}
