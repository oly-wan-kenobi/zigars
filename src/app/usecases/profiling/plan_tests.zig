const std = @import("std");

const flamegraph_model = @import("../../../domain/profiling/flamegraph.zig");
const plan = @import("plan.zig");

test "profile plan returns structured external capture plans" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const value = try plan.profilePlanValue(arena.allocator(), .{
        .binary = "zig-out/bin/demo",
        .detected_platform = "linux",
        .platform = "linux",
        .output_prefix = ".zigar-cache/profile/demo",
    });
    const root = value.object;
    try std.testing.expectEqualStrings("zig_profile_plan", root.get("kind").?.string);
    try std.testing.expectEqualStrings("linux", root.get("selected_platform").?.string);
    try std.testing.expectEqual(@as(usize, 6), root.get("plans").?.array.items.len);
    try std.testing.expectEqual(@as(usize, flamegraph_model.zflame_format_names.len), root.get("supported_zflame_formats").?.array.items.len);
    try std.testing.expectEqualStrings("linux_perf", root.get("recommended_plan_ids").?.array.items[0].string);
    try std.testing.expectEqualStrings("diff-folded", root.get("diff_workflow").?.object.get("canonical_diff_backend").?.string);
}

test "profile plan recommends platform-specific fallback plan ids" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const cases = [_]struct {
        platform: []const u8,
        expected_first: []const u8,
        expected_len: usize,
    }{
        .{ .platform = "freebsd", .expected_first = "dtrace", .expected_len = 2 },
        .{ .platform = "illumos", .expected_first = "dtrace", .expected_len = 2 },
        .{ .platform = "windows", .expected_first = "vtune", .expected_len = 2 },
        .{ .platform = "unknown", .expected_first = "already_folded_recursive", .expected_len = 1 },
    };

    for (cases) |case| {
        const value = try plan.profilePlanValue(arena.allocator(), .{
            .detected_platform = "linux",
            .platform = case.platform,
        });
        const ids = value.object.get("recommended_plan_ids").?.array.items;
        try std.testing.expectEqual(case.expected_len, ids.len);
        try std.testing.expectEqualStrings(case.expected_first, ids[0].string);
    }
}
