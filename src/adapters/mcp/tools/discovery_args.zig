//! Permissive JSON argument readers shared by the discovery MCP adapter. These
//! value-extraction helpers stay separate from the projection handlers so the
//! adapter file remains a focused projection over app discovery use cases.
const std = @import("std");

/// Reads a string argument when it is present with the expected type.
pub fn argString(args: ?std.json.Value, name: []const u8) ?[]const u8 {
    // Keep this logic centralized so callers observe one consistent behavior path.
    const obj = switch (args orelse return null) {
        .object => |o| o,
        else => return null,
    };
    return switch (obj.get(name) orelse return null) {
        .string => |s| s,
        else => null,
    };
}

/// Reads a bool argument when it is present with the expected type.
pub fn argBool(args: ?std.json.Value, name: []const u8, default: bool) bool {
    // Keep this logic centralized so callers observe one consistent behavior path.
    const obj = switch (args orelse return default) {
        .object => |o| o,
        else => return default,
    };
    return switch (obj.get(name) orelse return default) {
        .bool => |b| b,
        else => default,
    };
}

/// Reads an int argument when it is present with the expected type.
pub fn argInt(args: ?std.json.Value, name: []const u8, default: i64) i64 {
    // Keep this logic centralized so callers observe one consistent behavior path.
    const obj = switch (args orelse return default) {
        .object => |o| o,
        else => return default,
    };
    return switch (obj.get(name) orelse return default) {
        .integer => |i| i,
        else => default,
    };
}
