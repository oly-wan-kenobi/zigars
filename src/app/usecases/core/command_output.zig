const std = @import("std");

/// Carries safe text data across use case and port boundaries.
pub const SafeText = struct {
    text: []const u8,
    invalid_utf8: bool,
    encoding: []const u8,
    byte_count: usize,
};

/// Copies bounded text into allocator-owned storage for result payloads.
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

/// Implements put stream fields workflow logic using caller-owned inputs.
pub fn putStreamFields(allocator: std.mem.Allocator, obj: *std.json.ObjectMap, name: []const u8, safe: SafeText) !void {
    try obj.put(allocator, name, .{ .string = safe.text });
    try obj.put(allocator, try std.fmt.allocPrint(allocator, "{s}_invalid_utf8", .{name}), .{ .bool = safe.invalid_utf8 });
    try obj.put(allocator, try std.fmt.allocPrint(allocator, "{s}_encoding", .{name}), .{ .string = safe.encoding });
    try obj.put(allocator, try std.fmt.allocPrint(allocator, "{s}_byte_count", .{name}), .{ .integer = @intCast(safe.byte_count) });
}

/// Appends replacement data into caller-provided storage, propagating allocation failures.
fn appendReplacement(allocator: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
    try out.appendSlice(allocator, &std.unicode.replacement_character_utf8);
}
