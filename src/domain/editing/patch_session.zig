const std = @import("std");

/// File identity snapshot used to verify preimage and post-apply integrity.
pub const Identity = struct {
    exists: bool,
    bytes: usize,
    sha256: ?[]const u8 = null,

    /// Frees owned hash memory and invalidates the snapshot.
    pub fn deinit(self: *Identity, allocator: std.mem.Allocator) void {
        if (self.sha256) |hash| allocator.free(hash);
        self.* = undefined;
    }

    /// Deep-copies optional hash data so caller ownership is independent.
    pub fn clone(self: Identity, allocator: std.mem.Allocator) !Identity {
        return .{
            .exists = self.exists,
            .bytes = self.bytes,
            .sha256 = if (self.sha256) |hash| try allocator.dupe(u8, hash) else null,
        };
    }

    /// Compares semantic identity, treating non-existent files as equal by absence.
    pub fn matches(self: Identity, other: Identity) bool {
        if (self.exists != other.exists) return false;
        if (!self.exists) return true;
        if (self.bytes != other.bytes) return false;
        if (self.sha256 == null and other.sha256 == null) return true;
        if (self.sha256 == null or other.sha256 == null) return false;
        return std.mem.eql(u8, self.sha256.?, other.sha256.?);
    }
};

/// Expected preimage for one file in a patch session.
pub const ExpectedPreimage = struct {
    file: []const u8,
    identity: Identity,
};

/// Builds a file identity from existence state and bytes; allocates the digest when present.
pub fn identityFromBytes(allocator: std.mem.Allocator, exists: bool, bytes: []const u8) !Identity {
    if (!exists) return .{ .exists = false, .bytes = 0, .sha256 = null };
    return .{
        .exists = true,
        .bytes = bytes.len,
        .sha256 = try sha256Hex(allocator, bytes),
    };
}

/// Returns a lowercase hex-encoded SHA-256 digest owned by the allocator.
pub fn sha256Hex(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    return allocator.dupe(u8, &hex);
}

/// Returns whether a file identity matches the expected preimage set.
pub fn expectedMatches(expected: []const ExpectedPreimage, file: []const u8, actual: Identity) bool {
    for (expected) |item| {
        if (std.mem.eql(u8, item.file, file)) return item.identity.matches(actual);
    }
    return false;
}

/// Builds a stable session id from goal and path seed inputs.
pub fn sessionId(allocator: std.mem.Allocator, prefix: []const u8, goal: ?[]const u8, a: ?[]const u8, b: ?[]const u8, c: ?[]const u8) ![]const u8 {
    var seed = std.ArrayList(u8).empty;
    defer seed.deinit(allocator);
    try seed.appendSlice(allocator, prefix);
    if (goal) |value| try seed.appendSlice(allocator, value);
    if (a) |value| try seed.appendSlice(allocator, value);
    if (b) |value| try seed.appendSlice(allocator, value);
    if (c) |value| try seed.appendSlice(allocator, value);
    const hash = try sha256Hex(allocator, seed.items);
    defer allocator.free(hash);
    return std.fmt.allocPrint(allocator, "session-{s}", .{hash[0..16]});
}

/// Produces a cache artifact path for persisted file preimages.
pub fn preimageArtifactPath(allocator: std.mem.Allocator, session_id: []const u8, index: usize, file: []const u8) ![]const u8 {
    const safe = try sanitizePath(allocator, file);
    defer allocator.free(safe);
    return std.fmt.allocPrint(allocator, ".zigars-cache/patch-sessions/{s}/{d}-{s}.preimage", .{ session_id, index, safe });
}

/// Replaces path separators and shell-hostile characters for cache filenames.
pub fn sanitizePath(allocator: std.mem.Allocator, file: []const u8) ![]const u8 {
    const out = try allocator.dupe(u8, file);
    for (out) |*ch| {
        if (ch.* == '/' or ch.* == '\\' or ch.* == ':' or ch.* == ' ') ch.* = '_';
    }
    return out;
}

/// Splits by newline without retaining separator bytes.
fn collectLines(allocator: std.mem.Allocator, text: []const u8) ![][]const u8 {
    var lines = std.ArrayList([]const u8).empty;
    errdefer lines.deinit(allocator);
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| try lines.append(allocator, line);
    return lines.toOwnedSlice(allocator);
}

/// Emits a single-hunk unified diff focused on the changed span plus small context.
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
