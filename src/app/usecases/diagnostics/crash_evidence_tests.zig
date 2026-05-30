//! Pins crash-evidence extraction: sanitizer fusion yields the right
//! classification, a prefixed crash identity, and frame counts bounded by the
//! limit; panic analysis keeps the "unknown panic" fallback; and crash-repro
//! planning classifies the failure kind.
const std = @import("std");

const crash = @import("../../../domain/diagnostics/crash.zig");
const crash_evidence = @import("crash_evidence.zig");

test "sanitizer fusion returns typed classification identity and bounded frames" {
    var result = try crash_evidence.fuseSanitizer(std.testing.allocator, .{
        .source_kind = "content",
        .bytes =
        \\==1==ERROR: AddressSanitizer: heap-use-after-free
        \\#0 0x1 in parse src/main.zig:10
        \\#1 0x2 in caller src/main.zig:20
        ,
        .limit = 1,
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(crash.Sanitizer.asan, result.sanitizer);
    try std.testing.expectEqual(crash.FailureKind.use_after_free, result.failure_kind);
    try std.testing.expect(std.mem.startsWith(u8, result.crash_identity.value, "asan:"));
    try std.testing.expectEqual(@as(usize, 2), result.frames.count);
    try std.testing.expectEqual(@as(usize, 1), result.frames.frames.len);
}

test "panic trace keeps unknown panic fallback and crash repro classification" {
    var panic_result = try crash_evidence.analyzePanicTrace(std.testing.allocator, .{
        .source_kind = "content",
        .bytes = "#0 0x1 in main src/main.zig:1\n",
        .limit = 10,
    });
    defer panic_result.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("unknown panic", panic_result.panic_message);
    try std.testing.expect(std.mem.startsWith(u8, panic_result.crash_identity.value, "zig_panic:"));

    var repro = try crash_evidence.planCrashRepro(std.testing.allocator, "SIGSEGV at 0x0\n");
    defer repro.deinit(std.testing.allocator);
    try std.testing.expectEqual(crash.FailureKind.segfault, repro.failure_kind);
    try std.testing.expect(std.mem.startsWith(u8, repro.crash_identity.value, "crash:"));
}
