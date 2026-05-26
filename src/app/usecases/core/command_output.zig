const std = @import("std");

pub const SafeText = struct {
    text: []const u8,
    invalid_utf8: bool,
    encoding: []const u8,
    byte_count: usize,
};

pub fn safeTextAlloc(allocator: std.mem.Allocator, bytes: []const u8) !SafeText {
    if (std.unicode.utf8ValidateSlice(bytes)) {
        return .{
            .text = try allocator.dupe(u8, bytes),
            .invalid_utf8 = false,
            .encoding = "utf-8",
            .byte_count = bytes.len,
        };
    }

    var out: std.ArrayList(u8) = .empty;
    var out_owned = true;
    defer if (out_owned) out.deinit(allocator);
    var index: usize = 0;
    while (index < bytes.len) {
        const len = std.unicode.utf8ByteSequenceLength(bytes[index]) catch {
            try appendReplacement(allocator, &out);
            index += 1;
            continue;
        };
        if (index + len <= bytes.len and std.unicode.utf8ValidateSlice(bytes[index .. index + len])) {
            try out.appendSlice(allocator, bytes[index .. index + len]);
            index += len;
        } else {
            try appendReplacement(allocator, &out);
            index += 1;
        }
    }

    const text = try out.toOwnedSlice(allocator);
    out_owned = false;
    return .{
        .text = text,
        .invalid_utf8 = true,
        .encoding = "utf-8-lossy",
        .byte_count = bytes.len,
    };
}

pub fn putStreamFields(allocator: std.mem.Allocator, obj: *std.json.ObjectMap, name: []const u8, safe: SafeText) !void {
    try obj.put(allocator, name, .{ .string = safe.text });
    try obj.put(allocator, try std.fmt.allocPrint(allocator, "{s}_invalid_utf8", .{name}), .{ .bool = safe.invalid_utf8 });
    try obj.put(allocator, try std.fmt.allocPrint(allocator, "{s}_encoding", .{name}), .{ .string = safe.encoding });
    try obj.put(allocator, try std.fmt.allocPrint(allocator, "{s}_byte_count", .{name}), .{ .integer = @intCast(safe.byte_count) });
}

fn appendReplacement(allocator: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
    try out.appendSlice(allocator, &std.unicode.replacement_character_utf8);
}

test "safeTextAlloc preserves valid UTF-8" {
    const safe = try safeTextAlloc(std.testing.allocator, "ok\n");
    defer std.testing.allocator.free(safe.text);

    try std.testing.expectEqualStrings("ok\n", safe.text);
    try std.testing.expect(!safe.invalid_utf8);
    try std.testing.expectEqualStrings("utf-8", safe.encoding);
    try std.testing.expectEqual(@as(usize, 3), safe.byte_count);
}

test "safeTextAlloc replaces invalid UTF-8 bytes" {
    const input = "bad \xff text";
    const safe = try safeTextAlloc(std.testing.allocator, input);
    defer std.testing.allocator.free(safe.text);

    try std.testing.expect(std.unicode.utf8ValidateSlice(safe.text));
    try std.testing.expect(safe.invalid_utf8);
    try std.testing.expectEqualStrings("utf-8-lossy", safe.encoding);
    try std.testing.expectEqual(input.len, safe.byte_count);
    try std.testing.expect(std.mem.indexOf(u8, safe.text, &std.unicode.replacement_character_utf8) != null);

    const truncated = try safeTextAlloc(std.testing.allocator, "\xc3(");
    defer std.testing.allocator.free(truncated.text);
    try std.testing.expect(truncated.invalid_utf8);
}
