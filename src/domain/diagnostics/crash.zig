const std = @import("std");

pub const Sanitizer = enum {
    asan,
    ubsan,
    tsan,
    msan,
    unknown,

    pub fn name(self: Sanitizer) []const u8 {
        return @tagName(self);
    }
};

pub const FailureKind = enum {
    use_after_free,
    bounds,
    data_race,
    panic,
    leak,
    segfault,
    unknown,

    pub fn name(self: FailureKind) []const u8 {
        return @tagName(self);
    }
};

pub fn classifySanitizer(text: []const u8) Sanitizer {
    if (containsAny(text, &.{ "AddressSanitizer", "heap-use-after-free", "stack-buffer-overflow" })) return .asan;
    if (containsAny(text, &.{ "UndefinedBehaviorSanitizer", "runtime error:" })) return .ubsan;
    if (containsAny(text, &.{ "ThreadSanitizer", "data race" })) return .tsan;
    if (containsAny(text, &.{ "MemorySanitizer", "use-of-uninitialized-value" })) return .msan;
    return .unknown;
}

pub fn classifyFailure(text: []const u8) FailureKind {
    if (containsAny(text, &.{ "heap-use-after-free", "use after free" })) return .use_after_free;
    if (containsAny(text, &.{ "stack-buffer-overflow", "heap-buffer-overflow", "index out of bounds" })) return .bounds;
    if (containsAny(text, &.{ "data race", "ThreadSanitizer" })) return .data_race;
    if (containsAny(text, &.{ "panic:", "thread panic", "reached unreachable" })) return .panic;
    if (containsAny(text, &.{ "leak", "definitely lost" })) return .leak;
    if (containsAny(text, &.{ "SIGSEGV", "segmentation fault", "access violation" })) return .segfault;
    return .unknown;
}

pub fn panicMessage(text: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (std.mem.indexOf(u8, line, "panic:")) |idx| return std.mem.trim(u8, line[idx + "panic:".len ..], " \t");
        if (std.mem.indexOf(u8, line, "thread") != null and std.mem.indexOf(u8, line, "panic") != null) return line;
    }
    return null;
}

pub fn containsAny(haystack: []const u8, needles: []const []const u8) bool {
    for (needles) |needle| if (std.mem.indexOf(u8, haystack, needle) != null) return true;
    return false;
}
