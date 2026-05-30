//! Tests for Logger level filtering and correlation-prefix formatting.

const std = @import("std");
const logging = @import("logging.zig");

const Logger = logging.Logger;

test "disabled logger accepts messages without an IO sink" {
    const logger = Logger.disabled();
    logger.info("test", "ignored {s}", .{"message"});
}

test "correlation prefix includes request and optional tool fields" {
    var buffer: [128]u8 = undefined;
    const request = logging.formatCorrelationPrefix(&buffer, .{
        .trace_id = "00000001",
        .request_id = "42",
        .method = "tools/call",
        .tool_name = "zig_check",
    });
    try std.testing.expectEqualStrings("trace=00000001 req=42 method=tools/call tool=zig_check", request);

    const notification = logging.formatCorrelationPrefix(&buffer, .{
        .trace_id = "00000002",
        .request_id = "null",
        .method = "notifications/initialized",
    });
    try std.testing.expectEqualStrings("trace=00000002 req=null method=notifications/initialized", notification);
}
