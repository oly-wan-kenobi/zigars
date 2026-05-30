//! Sanitizes captured subprocess output for MCP result payloads. Zig tool
//! stdout/stderr is arbitrary bytes, but MCP JSON strings must be valid UTF-8,
//! so invalid sequences are replaced with U+FFFD and flagged rather than
//! emitted raw. The byte count records the original (pre-replacement) length.
const std = @import("std");

/// Carries safe text data across use case and port boundaries.
pub const SafeText = struct {
    text: []const u8,
    invalid_utf8: bool,
    encoding: []const u8,
    byte_count: usize,
};

/// Returns an allocator-owned UTF-8-safe copy of `bytes`. Valid input is duped
/// verbatim (`encoding = "utf-8"`); otherwise invalid sequences become U+FFFD,
/// `invalid_utf8` is set, and `encoding` is "utf-8-lossy". `byte_count` is
/// always the original byte length. Caller owns and frees `.text`.
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

/// Writes a sanitized output stream into `obj` as `<name>` plus the sidecar
/// fields `<name>_invalid_utf8`, `<name>_encoding`, and `<name>_byte_count`, so
/// consumers can tell whether the text was lossily re-encoded. Keys and the
/// stored text are allocated into `allocator`.
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
