const std = @import("std");

const JsonValue = std.json.Value;

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
