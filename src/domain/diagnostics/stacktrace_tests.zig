const std = @import("std");

const stacktrace = @import("stacktrace.zig");

test "frame parser extracts bounded frames and total count" {
    var frames = try stacktrace.parseFrames(std.testing.allocator,
        \\noise
        \\#0 0x1 in parse src/main.zig:10
        \\frame #1: app`main + 4
        \\#2 0x2 in done src/main.zig:20
    , 2);
    defer frames.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 3), frames.count);
    try std.testing.expectEqual(@as(usize, 2), frames.frames.len);
    try std.testing.expectEqual(@as(usize, 0), frames.frames[0].index);
    try std.testing.expectEqualStrings("parse", frames.frames[0].symbol);
    try std.testing.expectEqualStrings("#0 0x1 in parse src/main.zig", frames.frames[0].location);
    try std.testing.expectEqualStrings("main", frames.frames[1].symbol);
}

test "frame parser classifies common debugger line shapes" {
    try std.testing.expect(stacktrace.looksLikeFrame("#0 0x1 in main src/main.zig:1"));
    try std.testing.expect(stacktrace.looksLikeFrame("frame #0: 0x1 app`main"));
    try std.testing.expect(stacktrace.looksLikeFrame("main at src/main.zig:1"));
    try std.testing.expect(stacktrace.looksLikeFrame("pc:0x1234"));
    try std.testing.expect(!stacktrace.looksLikeFrame("ordinary log line"));
}
