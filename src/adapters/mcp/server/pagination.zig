//! Cursor/limit parsing and response cursor projection for list-style MCP endpoints.
const std = @import("std");

/// Parsed pagination params with cursor start, clamped limit, and opt-in flag.
pub const Pagination = struct {
    start: usize = 0,
    limit: usize = std.math.maxInt(usize),
    requested: bool = false,
};

pub const ParseError = error{
    InvalidCursor,
};

pub const invalid_cursor_message = "Pagination cursor must be a non-negative decimal offset";

/// Parses optional params.cursor and params.limit values from JSON-RPC params.
pub fn fromParams(params: ?std.json.Value) ParseError!Pagination {
    var page: Pagination = .{};
    const obj = switch (params orelse .null) {
        .object => |o| o,
        else => return page,
    };
    if (obj.get("cursor")) |cursor| switch (cursor) {
        .string => |s| {
            page.start = std.fmt.parseUnsigned(usize, s, 10) catch return error.InvalidCursor;
            page.requested = true;
        },
        .integer => |i| {
            if (i < 0) return error.InvalidCursor;
            page.start = @intCast(i);
            page.requested = true;
        },
        else => return error.InvalidCursor,
    };
    if (obj.get("limit")) |limit| switch (limit) {
        .integer => |i| {
            page.limit = @intCast(@max(1, @min(i, 500)));
            page.requested = true;
        },
        else => {},
    };
    return page;
}

/// Returns whether a zero-based item index belongs to the requested page.
pub fn shouldIncludeIndex(page: Pagination, index: usize) bool {
    if (index < page.start) return false;
    return index - page.start < page.limit;
}

/// Adds nextCursor only when pagination was requested and more items remain.
pub fn maybePutNextCursor(allocator: std.mem.Allocator, result: *std.json.ObjectMap, page: Pagination, total: usize) !void {
    if (!page.requested) return;
    const next = page.start + @min(page.limit, total -| page.start);
    if (next < total) try result.put(allocator, "nextCursor", .{ .string = try std.fmt.allocPrint(allocator, "{d}", .{next}) });
}
