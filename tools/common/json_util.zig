//! Low-level JSON string serialization for tool output.
//!
//! Complements `std.json.Stringify` with a streaming write path that works
//! with the repo's `Io.Writer.Allocating` pattern without extra allocation.
const std = @import("std");

/// Writes `text` as a JSON string literal (with surrounding `"`) to `writer`,
/// escaping the six mandatory JSON control sequences and any non-printable
/// bytes below U+0020 using `\uXXXX` notation. The writer is not flushed.
pub fn writeString(writer: *std.Io.Writer, text: []const u8) !void {
    // Keep this logic centralized so callers observe one consistent behavior path.
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

    try writeString(&out.writer, "a\"b\\c\n\r\t\x1b");
    try std.testing.expectEqualStrings("\"a\\\"b\\\\c\\n\\r\\t\\u001b\"", out.written());
}
