const std = @import("std");

pub const Identity = struct {
    exists: bool,
    bytes: usize,
    sha256: ?[]const u8 = null,

    pub fn deinit(self: *Identity, allocator: std.mem.Allocator) void {
        if (self.sha256) |hash| allocator.free(hash);
        self.* = undefined;
    }

    pub fn clone(self: Identity, allocator: std.mem.Allocator) !Identity {
        return .{
            .exists = self.exists,
            .bytes = self.bytes,
            .sha256 = if (self.sha256) |hash| try allocator.dupe(u8, hash) else null,
        };
    }

    pub fn matches(self: Identity, other: Identity) bool {
        if (self.exists != other.exists) return false;
        if (!self.exists) return true;
        if (self.bytes != other.bytes) return false;
        if (self.sha256 == null and other.sha256 == null) return true;
        if (self.sha256 == null or other.sha256 == null) return false;
        return std.mem.eql(u8, self.sha256.?, other.sha256.?);
    }
};

pub const ExpectedPreimage = struct {
    file: []const u8,
    identity: Identity,
};

pub fn identityFromBytes(allocator: std.mem.Allocator, exists: bool, bytes: []const u8) !Identity {
    if (!exists) return .{ .exists = false, .bytes = 0, .sha256 = null };
    return .{
        .exists = true,
        .bytes = bytes.len,
        .sha256 = try sha256Hex(allocator, bytes),
    };
}

pub fn sha256Hex(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    return allocator.dupe(u8, &hex);
}

pub fn expectedMatches(expected: []const ExpectedPreimage, file: []const u8, actual: Identity) bool {
    for (expected) |item| {
        if (std.mem.eql(u8, item.file, file)) return item.identity.matches(actual);
    }
    return false;
}

pub fn sessionId(allocator: std.mem.Allocator, prefix: []const u8, goal: ?[]const u8, a: ?[]const u8, b: ?[]const u8, c: ?[]const u8) ![]const u8 {
    var seed = std.ArrayList(u8).empty;
    try seed.appendSlice(allocator, prefix);
    if (goal) |value| try seed.appendSlice(allocator, value);
    if (a) |value| try seed.appendSlice(allocator, value);
    if (b) |value| try seed.appendSlice(allocator, value);
    if (c) |value| try seed.appendSlice(allocator, value);
    const hash = try sha256Hex(allocator, seed.items);
    return std.fmt.allocPrint(allocator, "session-{s}", .{hash[0..16]});
}

pub fn preimageArtifactPath(allocator: std.mem.Allocator, session_id: []const u8, index: usize, file: []const u8) ![]const u8 {
    const safe = try sanitizePath(allocator, file);
    defer allocator.free(safe);
    return std.fmt.allocPrint(allocator, ".zigar-cache/patch-sessions/{s}/{d}-{s}.preimage", .{ session_id, index, safe });
}

pub fn sanitizePath(allocator: std.mem.Allocator, file: []const u8) ![]const u8 {
    const out = try allocator.dupe(u8, file);
    for (out) |*ch| {
        if (ch.* == '/' or ch.* == '\\' or ch.* == ':' or ch.* == ' ') ch.* = '_';
    }
    return out;
}

fn collectLines(allocator: std.mem.Allocator, text: []const u8) ![][]const u8 {
    var lines = std.ArrayList([]const u8).empty;
    errdefer lines.deinit(allocator);
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| try lines.append(allocator, line);
    return lines.toOwnedSlice(allocator);
}

pub fn unifiedDiff(allocator: std.mem.Allocator, path: []const u8, before: []const u8, after: []const u8) ![]u8 {
    if (std.mem.eql(u8, before, after)) return allocator.dupe(u8, "");

    const before_lines = try collectLines(allocator, before);
    defer allocator.free(before_lines);
    const after_lines = try collectLines(allocator, after);
    defer allocator.free(after_lines);

    var prefix: usize = 0;
    while (prefix < before_lines.len and prefix < after_lines.len and std.mem.eql(u8, before_lines[prefix], after_lines[prefix])) : (prefix += 1) {}

    var suffix: usize = 0;
    while (suffix < before_lines.len - prefix and suffix < after_lines.len - prefix) : (suffix += 1) {
        const old_idx = before_lines.len - suffix - 1;
        const new_idx = after_lines.len - suffix - 1;
        if (!std.mem.eql(u8, before_lines[old_idx], after_lines[new_idx])) break;
    }

    const old_change_end = before_lines.len - suffix;
    const new_change_end = after_lines.len - suffix;
    const context_before = @min(prefix, 3);
    const context_after = @min(suffix, 3);
    const old_hunk_start = prefix - context_before;
    const new_hunk_start = prefix - context_before;
    const old_hunk_end = @min(before_lines.len, old_change_end + context_after);
    const new_hunk_end = @min(after_lines.len, new_change_end + context_after);
    const old_count = old_hunk_end - old_hunk_start;
    const new_count = new_hunk_end - new_hunk_start;

    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try out.writer.print("--- a/{s}\n+++ b/{s}\n@@ -{d},{d} +{d},{d} @@\n", .{
        path,
        path,
        old_hunk_start + 1,
        old_count,
        new_hunk_start + 1,
        new_count,
    });
    var i: usize = old_hunk_start;
    while (i < prefix) : (i += 1) {
        try out.writer.print(" {s}\n", .{before_lines[i]});
    }
    i = prefix;
    while (i < old_change_end) : (i += 1) {
        try out.writer.print("-{s}\n", .{before_lines[i]});
    }
    i = prefix;
    while (i < new_change_end) : (i += 1) {
        try out.writer.print("+{s}\n", .{after_lines[i]});
    }
    i = old_change_end;
    while (i < old_hunk_end) : (i += 1) {
        try out.writer.print(" {s}\n", .{before_lines[i]});
    }
    return try out.toOwnedSlice();
}

test "file identity hashes existing bytes and matches expected preimages" {
    var identity = try identityFromBytes(std.testing.allocator, true, "abc");
    defer identity.deinit(std.testing.allocator);
    try std.testing.expect(identity.exists);
    try std.testing.expectEqual(@as(usize, 3), identity.bytes);
    try std.testing.expect(identity.sha256 != null);

    const expected = [_]ExpectedPreimage{.{ .file = "src/main.zig", .identity = identity }};
    try std.testing.expect(expectedMatches(&expected, "src/main.zig", identity));
    try std.testing.expect(!expectedMatches(&expected, "src/other.zig", identity));
}

test "missing identity only matches missing expected identity" {
    const missing = try identityFromBytes(std.testing.allocator, false, "");
    var existing = try identityFromBytes(std.testing.allocator, true, "");
    defer existing.deinit(std.testing.allocator);

    const expected = [_]ExpectedPreimage{.{ .file = "new.zig", .identity = missing }};
    try std.testing.expect(expectedMatches(&expected, "new.zig", missing));
    try std.testing.expect(!expectedMatches(&expected, "new.zig", existing));
}

test "session artifact paths are stable and sanitized" {
    const path = try preimageArtifactPath(std.testing.allocator, "session-1234", 1, "src/main file.zig");
    defer std.testing.allocator.free(path);
    try std.testing.expectEqualStrings(".zigar-cache/patch-sessions/session-1234/1-src_main_file.zig.preimage", path);
}

test "unified diff preserves existing public line markers" {
    const diff = try unifiedDiff(std.testing.allocator, "src/main.zig", "const a = 1;\n", "const a = 2;\n");
    defer std.testing.allocator.free(diff);
    try std.testing.expect(std.mem.indexOf(u8, diff, "-const a = 1;") != null);
    try std.testing.expect(std.mem.indexOf(u8, diff, "+const a = 2;") != null);
}
