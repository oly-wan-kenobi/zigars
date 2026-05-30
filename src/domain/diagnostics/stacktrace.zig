//! Stacktrace parser: extracts structured frame data from raw crash transcripts.
//! Frame text slices borrow from the original transcript; only the frames slice itself
//! is owned — call ParsedFrames.deinit to release it.

const std = @import("std");

/// Borrowed stack frame slices extracted from a crash transcript line.
pub const Frame = struct {
    index: usize,
    raw: []const u8,
    symbol: []const u8,
    location: []const u8,
};

/// Owned frame list; frame text slices borrow from the original transcript.
pub const ParsedFrames = struct {
    frames: []Frame,
    count: usize,

    /// Frees only the frame slice; individual frame fields are borrowed.
    pub fn deinit(self: *ParsedFrames, allocator: std.mem.Allocator) void {
        allocator.free(self.frames);
        self.* = undefined;
    }

    /// Returns the first retained frame, if any.
    pub fn top(self: ParsedFrames) ?Frame {
        if (self.frames.len == 0) return null;
        return self.frames[0];
    }
};

/// Parses up to `limit` frames from `text` and returns a ParsedFrames whose
/// `frames` slice is caller-owned (free via deinit) and whose `count` reflects
/// all frame-like lines seen, even those beyond the limit.
/// Symbol and location slices borrow from `text` and must outlive the result.
pub fn parseFrames(allocator: std.mem.Allocator, text: []const u8, limit: usize) !ParsedFrames {
    var frames = std.ArrayList(Frame).empty;
    // frames_owned guards the deferred cleanup: flipped to false once ownership
    // is transferred via toOwnedSlice so the defer becomes a no-op.
    var frames_owned = true;
    defer if (frames_owned) frames.deinit(allocator);

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

    const owned_frames = try frames.toOwnedSlice(allocator);
    frames_owned = false;
    return .{ .frames = owned_frames, .count = count };
}

/// Heuristically detects common Zig, LLDB, and symbolized frame lines.
/// Matches: GDB-style `#N`, LLDB `frame #N`, ` in ` / ` at ` presence, and `:0x` addresses.
/// This is a best-effort heuristic; false positives are possible on unusual output.
pub fn looksLikeFrame(line: []const u8) bool {
    if (line.len == 0) return false;
    return std.mem.startsWith(u8, line, "#") or
        std.mem.startsWith(u8, line, "frame #") or
        std.mem.indexOf(u8, line, " in ") != null or
        std.mem.indexOf(u8, line, " at ") != null or
        std.mem.indexOf(u8, line, ":0x") != null;
}

/// Extracts the best-effort symbol name from a frame line.
/// Returns a borrowed slice of `line`; returns "unknown" when no known pattern matches.
/// Prefers ` in <name>` (GDB/sanitizer output) over backtick-quoted LLDB symbols.
pub fn frameSymbol(line: []const u8) []const u8 {
    // Keep this logic centralized so callers observe one consistent behavior path.
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

/// Extracts the best-effort source or binary location from a frame line.
/// Returns the text after ` at ` when present, or the segment before the last
/// colon as a binary-address fallback. Returns "" when neither pattern matches.
/// Result is a borrowed slice of `line`.
pub fn frameLocation(line: []const u8) []const u8 {
    if (std.mem.indexOf(u8, line, " at ")) |idx| return std.mem.trim(u8, line[idx + 4 ..], " \t");
    if (std.mem.lastIndexOfScalar(u8, line, ':')) |idx| if (idx > 0) return std.mem.trim(u8, line[0..idx], " \t");
    return "";
}
