const std = @import("std");
const static_cache = @import("static_cache.zig");

const State = static_cache.State;
const Cache = static_cache.Cache;

test "static cache stores bytes and records hits" {
    var state = State{};
    defer state.deinit(std.testing.allocator);

    var cache = Cache.init(std.testing.allocator, &state);
    const stored = try cache.port().store(std.testing.allocator, .{ .signature = 7, .bytes = "{}" });
    try std.testing.expect(stored.cached);
    try std.testing.expectEqual(@as(u64, 7), stored.signature);
    try std.testing.expectEqual(@as(usize, 1), stored.refreshes);

    const hit = try cache.port().recordHit();
    try std.testing.expectEqual(@as(usize, 1), hit.hits);
    const loaded = try cache.port().load(std.testing.allocator);
    try std.testing.expectEqualStrings("{}", loaded.bytes.?);
}
