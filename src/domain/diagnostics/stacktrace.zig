const std = @import("std");

pub const Frame = struct {
    index: usize,
    raw: []const u8,
    symbol: []const u8,
    location: []const u8,
};

pub const ParsedFrames = struct {
    frames: []Frame,
    count: usize,

    pub fn deinit(self: *ParsedFrames, allocator: std.mem.Allocator) void {
        allocator.free(self.frames);
        self.* = undefined;
    }

    pub fn top(self: ParsedFrames) ?Frame {
        if (self.frames.len == 0) return null;
        return self.frames[0];
    }
};

pub fn parseFrames(allocator: std.mem.Allocator, text: []const u8, limit: usize) !ParsedFrames {
    var frames = std.ArrayList(Frame).empty;
    errdefer frames.deinit(allocator);

    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (!looksLikeFrame(line)) continue;
        count += 1;
        if (frames.items.len >= limit) continue;
        try frames.append(allocator, .{
            .index = count - 1,
            .raw = line,
            .symbol = frameSymbol(line),
            .location = frameLocation(line),
        });
    }

    return .{ .frames = try frames.toOwnedSlice(allocator), .count = count };
}

pub fn looksLikeFrame(line: []const u8) bool {
    if (line.len == 0) return false;
    return std.mem.startsWith(u8, line, "#") or
        std.mem.startsWith(u8, line, "frame #") or
        std.mem.indexOf(u8, line, " in ") != null or
        std.mem.indexOf(u8, line, " at ") != null or
        std.mem.indexOf(u8, line, ":0x") != null;
}

pub fn frameSymbol(line: []const u8) []const u8 {
    if (std.mem.indexOf(u8, line, " in ")) |idx| {
        const rest = line[idx + 4 ..];
        const end = std.mem.indexOfAny(u8, rest, " (") orelse rest.len;
        return std.mem.trim(u8, rest[0..end], " \t");
    }
    if (std.mem.indexOf(u8, line, "`")) |tick| {
        const rest = line[tick + 1 ..];
        const end = std.mem.indexOfAny(u8, rest, " +") orelse rest.len;
        return std.mem.trim(u8, rest[0..end], " \t");
    }
    return "unknown";
}

pub fn frameLocation(line: []const u8) []const u8 {
    if (std.mem.indexOf(u8, line, " at ")) |idx| return std.mem.trim(u8, line[idx + 4 ..], " \t");
    if (std.mem.lastIndexOfScalar(u8, line, ':')) |idx| if (idx > 0) return std.mem.trim(u8, line[0..idx], " \t");
    return "";
}
