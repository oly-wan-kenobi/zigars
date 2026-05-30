//! Crash-triage helpers: classify sanitizer family and failure kind from raw
//! crash transcript text, and extract the first panic message when present.
//! All functions are pure text scanners; they do not allocate.

const std = @import("std");

/// Sanitizer family detected from crash or test output.
pub const Sanitizer = enum {
    asan,
    ubsan,
    tsan,
    msan,
    unknown,

    /// Returns the serialized sanitizer token.
    pub fn name(self: Sanitizer) []const u8 {
        return @tagName(self);
    }
};

/// Broad failure class used for crash triage.
pub const FailureKind = enum {
    use_after_free,
    bounds,
    data_race,
    panic,
    leak,
    segfault,
    unknown,

    /// Returns the serialized failure-kind token.
    pub fn name(self: FailureKind) []const u8 {
        return @tagName(self);
    }
};

/// Classifies sanitizer output by recognizable tool markers.
pub fn classifySanitizer(text: []const u8) Sanitizer {
    if (containsAny(text, &.{ "AddressSanitizer", "heap-use-after-free", "stack-buffer-overflow" })) return .asan;
    if (containsAny(text, &.{ "UndefinedBehaviorSanitizer", "runtime error:" })) return .ubsan;
    if (containsAny(text, &.{ "ThreadSanitizer", "data race" })) return .tsan;
    if (containsAny(text, &.{ "MemorySanitizer", "use-of-uninitialized-value" })) return .msan;
    return .unknown;
}

/// Classifies a crash transcript into the highest-priority known failure kind.
/// Priority order is fixed: use_after_free > bounds > data_race > panic > leak > segfault.
/// Returns .unknown when no recognized marker is found.
pub fn classifyFailure(text: []const u8) FailureKind {
    if (containsAny(text, &.{ "heap-use-after-free", "use after free" })) return .use_after_free;
    if (containsAny(text, &.{ "stack-buffer-overflow", "heap-buffer-overflow", "index out of bounds" })) return .bounds;
    if (containsAny(text, &.{ "data race", "ThreadSanitizer" })) return .data_race;
    if (containsAny(text, &.{ "panic:", "thread panic", "reached unreachable" })) return .panic;
    if (containsAny(text, &.{ "leak", "definitely lost" })) return .leak;
    if (containsAny(text, &.{ "SIGSEGV", "segmentation fault", "access violation" })) return .segfault;
    return .unknown;
}

/// Extracts a panic message line from Zig-style crash text when present.
/// Returns a borrowed slice into `text`; the caller must not free it.
/// Returns null when no "panic:" or "thread ... panic" line is found.
pub fn panicMessage(text: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (std.mem.indexOf(u8, line, "panic:")) |idx| return std.mem.trim(u8, line[idx + "panic:".len ..], " \t");
        if (std.mem.indexOf(u8, line, "thread") != null and std.mem.indexOf(u8, line, "panic") != null) return line;
    }
    return null;
}

/// Returns whether any marker appears in the supplied text.
pub fn containsAny(haystack: []const u8, needles: []const []const u8) bool {
    for (needles) |needle| if (std.mem.indexOf(u8, haystack, needle) != null) return true;
    return false;
}
