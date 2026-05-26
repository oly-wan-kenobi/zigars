const std = @import("std");
const clock_mod = @import("clock_and_ids.zig");

const RuntimeClockAndIds = clock_mod.RuntimeClockAndIds;

test "runtime clock and ids use process clock and monotonic counter" {
    var counter = std.atomic.Value(u64).init(7);
    var clock = RuntimeClockAndIds.init(std.testing.io, &counter);

    const instant = try clock.port().now();
    try std.testing.expect(instant.unix_ms > 0);
    try std.testing.expectEqual(@as(u64, 0), instant.monotonic_ms);

    const id = try clock.port().nextId(std.testing.allocator, .{ .prefix = "tmp-" });
    defer std.testing.allocator.free(id);
    try std.testing.expectEqualStrings("tmp-7", id);
    try std.testing.expectEqual(@as(u64, 8), counter.load(.monotonic));
}
