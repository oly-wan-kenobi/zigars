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
