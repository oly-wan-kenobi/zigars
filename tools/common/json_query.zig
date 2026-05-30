//! Dot-path traversal helpers for `std.json.Value` trees.
//!
//! Provides a small query DSL for inspecting JSON results in test assertions
//! and release checks without pulling in a full JSONPath library.
const std = @import("std");

const JsonValue = std.json.Value;

/// Traverses a JSON value using a dot-separated `path` (e.g. `"result.tools.1.name"`).
/// Numeric segments index into arrays; non-numeric segments key into objects.
/// Returns `null` for any missing key, out-of-bounds index, or type mismatch.
/// An empty segment (consecutive dots) also yields `null`.
pub fn valueAt(value: JsonValue, path: []const u8) ?JsonValue {
    var current = value;
    var parts = std.mem.splitScalar(u8, path, '.');
    while (parts.next()) |part| {
        if (part.len == 0) return null;
        if (isDigits(part)) {
            if (current != .array) return null;
            const index = std.fmt.parseInt(usize, part, 10) catch return null;
            if (index >= current.array.items.len) return null;
            current = current.array.items[index];
        } else {
            if (current != .object) return null;
            current = current.object.get(part) orelse return null;
        }
    }
    return current;
}

/// Returns true only when every byte is an ASCII digit, so array indices and
/// object keys can be distinguished during dot-path traversal.
fn isDigits(text: []const u8) bool {
    if (text.len == 0) return false;
    for (text) |c| if (c < '0' or c > '9') return false;
    return true;
}

test "valueAt traverses object and array paths" {
    const parsed = try std.json.parseFromSlice(JsonValue, std.testing.allocator,
        \\{"result":{"tools":[{"name":"zig_format"},{"name":"zig_test"}],"ok":true}}
    , .{});
    defer parsed.deinit();

    try std.testing.expectEqualStrings("zig_test", valueAt(parsed.value, "result.tools.1.name").?.string);
    try std.testing.expect(valueAt(parsed.value, "result.ok").?.bool);
    try std.testing.expect(valueAt(parsed.value, "result.tools.2.name") == null);
    try std.testing.expect(valueAt(parsed.value, "result..ok") == null);
}
