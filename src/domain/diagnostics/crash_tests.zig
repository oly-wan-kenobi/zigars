const std = @import("std");

const crash = @import("crash.zig");

test "sanitizer classifier covers common runtime variants" {
    try std.testing.expectEqual(crash.Sanitizer.asan, crash.classifySanitizer("AddressSanitizer: heap-use-after-free"));
    try std.testing.expectEqual(crash.Sanitizer.ubsan, crash.classifySanitizer("UndefinedBehaviorSanitizer runtime error:"));
    try std.testing.expectEqual(crash.Sanitizer.tsan, crash.classifySanitizer("ThreadSanitizer data race"));
    try std.testing.expectEqual(crash.Sanitizer.msan, crash.classifySanitizer("MemorySanitizer use-of-uninitialized-value"));
    try std.testing.expectEqual(crash.Sanitizer.unknown, crash.classifySanitizer("ordinary output"));
}

test "failure classifier and panic message preserve historic labels" {
    try std.testing.expectEqual(crash.FailureKind.use_after_free, crash.classifyFailure("heap-use-after-free"));
    try std.testing.expectEqual(crash.FailureKind.bounds, crash.classifyFailure("index out of bounds"));
    try std.testing.expectEqual(crash.FailureKind.data_race, crash.classifyFailure("data race"));
    try std.testing.expectEqual(crash.FailureKind.panic, crash.classifyFailure("thread 1 panic: reached unreachable code"));
    try std.testing.expectEqual(crash.FailureKind.leak, crash.classifyFailure("definitely lost"));
    try std.testing.expectEqual(crash.FailureKind.segfault, crash.classifyFailure("SIGSEGV"));
    try std.testing.expectEqual(crash.FailureKind.unknown, crash.classifyFailure("ordinary output"));
    try std.testing.expectEqualStrings("reached unreachable code", crash.panicMessage("thread 123 panic: reached unreachable code\n").?);
    try std.testing.expect(crash.panicMessage("ordinary output") == null);
    try std.testing.expect(crash.containsAny("hello sanitizer", &.{ "none", "sanitizer" }));
    try std.testing.expect(!crash.containsAny("hello", &.{ "asan", "ubsan" }));
}
