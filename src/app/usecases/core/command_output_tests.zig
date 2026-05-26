const std = @import("std");

const command_output = @import("command_output.zig");

test "safeTextAlloc preserves valid UTF-8" {
    const safe = try command_output.safeTextAlloc(std.testing.allocator, "ok\n");
    defer std.testing.allocator.free(safe.text);

    try std.testing.expectEqualStrings("ok\n", safe.text);
    try std.testing.expect(!safe.invalid_utf8);
    try std.testing.expectEqualStrings("utf-8", safe.encoding);
    try std.testing.expectEqual(@as(usize, 3), safe.byte_count);
}

test "safeTextAlloc replaces invalid UTF-8 bytes" {
    const input = "bad \xff text";
    const safe = try command_output.safeTextAlloc(std.testing.allocator, input);
    defer std.testing.allocator.free(safe.text);

    try std.testing.expect(std.unicode.utf8ValidateSlice(safe.text));
    try std.testing.expect(safe.invalid_utf8);
    try std.testing.expectEqualStrings("utf-8-lossy", safe.encoding);
    try std.testing.expectEqual(input.len, safe.byte_count);
    try std.testing.expect(std.mem.indexOf(u8, safe.text, &std.unicode.replacement_character_utf8) != null);

    const truncated = try command_output.safeTextAlloc(std.testing.allocator, "\xc3(");
    defer std.testing.allocator.free(truncated.text);
    try std.testing.expect(truncated.invalid_utf8);
}
