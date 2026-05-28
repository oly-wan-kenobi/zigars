const std = @import("std");

const evidence = @import("evidence.zig");

test "finding summary counts severities" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var findings = std.json.Array.init(allocator);
    try findings.append(try evidence.findingValue(allocator, .zlint, "rule", "error", "src/main.zig", 3, 1, "bad", .high));
    try findings.append(try evidence.findingValue(allocator, .zwanzig, "style", "warning", "src/main.zig", 4, 1, "warn", .high));
    const summary = try evidence.summaryValue(allocator, findings);
    try std.testing.expectEqual(@as(i64, 2), summary.object.get("finding_count").?.integer);
    try std.testing.expectEqual(@as(i64, 1), summary.object.get("error_count").?.integer);
    try std.testing.expectEqual(@as(i64, 1), summary.object.get("warning_count").?.integer);
}

test "evidence JSON builders clean up allocation failures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, evidenceValuesWithAllocator, .{});
}

/// Exercises nested evidence JSON construction under allocation-failure testing.
fn evidenceValuesWithAllocator(allocator: std.mem.Allocator) !void {
    const sources = try evidence.sourceArrayValue(allocator, &.{ .parser, .zls });
    defer evidence.deinitOwnedValue(allocator, sources);

    const details = try evidence.evidenceValue(allocator, .parser, .high, "parser-backed", &.{ "zig ast-check", "zig build test" });
    defer evidence.deinitOwnedValue(allocator, details);

    const finding = try evidence.findingValue(allocator, .zlint, "rule", "error", "src/main.zig", 3, 1, "bad", .high);
    defer evidence.deinitOwnedValue(allocator, finding);

    const fingerprint = try evidence.fingerprintValue(allocator, finding);
    defer evidence.deinitOwnedValue(allocator, fingerprint);

    var findings = std.json.Array.init(allocator);
    defer evidence.deinitOwnedValue(allocator, .{ .array = findings });
    try appendEvidenceValue(allocator, &findings, try evidence.findingValue(allocator, .zwanzig, "style", "warning", "src/main.zig", 4, 1, "warn", .medium));

    const summary = try evidence.summaryValue(allocator, findings);
    defer evidence.deinitOwnedValue(allocator, summary);
}

/// Appends a JSON value in test setup without masking leaks when append allocation fails.
fn appendEvidenceValue(allocator: std.mem.Allocator, array: *std.json.Array, value: std.json.Value) !void {
    errdefer evidence.deinitOwnedValue(allocator, value);
    try array.append(value);
}
