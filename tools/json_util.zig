const std = @import("std");

pub fn writeString(writer: *std.Io.Writer, text: []const u8) !void {
    try writer.writeByte('"');
    for (text) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => if (c < 0x20) {
                try writer.print("\\u{x:0>4}", .{c});
            } else {
                try writer.writeByte(c);
            },
        }
    }
    try writer.writeByte('"');
}

test "writeString escapes JSON control characters" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try writeString(&out.writer, "a\"b\\c\n\t\x1b");
    try std.testing.expectEqualStrings("\"a\\\"b\\\\c\\n\\t\\u001b\"", out.written());
}
