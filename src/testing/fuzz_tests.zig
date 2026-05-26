const std = @import("std");

const coverage_model = @import("coverage_model");
const path_policy = @import("path_policy");
const stacktrace = @import("stacktrace");
const crash = @import("crash");
const command = @import("command");

/// Weighted ASCII corpus keeps fuzzing near CLI-ish inputs while still allowing
/// control bytes that stress parsers.
const ascii_weights = &.{
    std.testing.Smith.Weight.rangeAtMost(u8, 0x20, 0x7e, 8),
    std.testing.Smith.Weight.value(u8, '\n', 2),
    std.testing.Smith.Weight.value(u8, '\t', 1),
    std.testing.Smith.Weight.value(u8, 0, 1),
};

test "fuzz parsers and classifiers stay bounded" {
    try std.testing.fuzz({}, fuzzTextParsers, .{
        .corpus = &.{
            "SF:src/main.zig\nDA:1,1\nDA:2,0\nend_of_record\n",
            "{\"files\":[{\"path\":\"src/main.zig\",\"total_lines\":2,\"covered_lines\":1}]}",
            "#0 0x1 in main src/main.zig:1:1\nthread 1 panic: reached unreachable code\n",
            "zig build test --summary all",
            ".zig-cache/o/hash/file.zig",
        },
    });
}

test "fuzz coverage seed exercises successful coverage parsing" {
    var set = try coverage_model.parse(std.testing.allocator, "SF:src/main.zig\nDA:1,1\nDA:2,0\nend_of_record\n", "seed", "");
    defer set.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 5000), coverage_model.rateBp(set.covered, set.total));
    const changed = coverage_model.changedCoverage(set, &.{ "src/main.zig", "tools/coverage.zig" });
    try std.testing.expectEqual(@as(usize, 1), changed.count);
}

/// Feeds arbitrary bytes through text parsers that accept untrusted input.
fn fuzzTextParsers(_: void, smith: *std.testing.Smith) !void {
    @disableInstrumentation();
    var buffer: [512]u8 = undefined;
    const len = smith.sliceWeightedBytes(buffer[0..], ascii_weights);
    const text = buffer[0..len];

    // If random text does not parse as LCOV, fall back to a valid seed so the
    // rest of the pipeline still gets exercised on every iteration.
    var set = coverage_model.parse(std.testing.allocator, text, "fuzz", "") catch
        try coverage_model.parse(std.testing.allocator, "SF:src/main.zig\nDA:1,1\nend_of_record\n", "seed", "");
    defer set.deinit(std.testing.allocator);
    _ = coverage_model.rateBp(set.covered, set.total);
    _ = coverage_model.changedCoverage(set, &.{ "src/main.zig", "tools/coverage.zig" });

    var frames = try stacktrace.parseFrames(std.testing.allocator, text, 8);
    defer frames.deinit(std.testing.allocator);
    _ = frames.top();
    _ = stacktrace.looksLikeFrame(text);
    _ = stacktrace.frameSymbol(text);
    _ = stacktrace.frameLocation(text);
    _ = crash.classifySanitizer(text);
    _ = crash.classifyFailure(text);
    _ = crash.panicMessage(text);
    _ = path_policy.classify(text);

    if (command.splitArgs(std.testing.allocator, text)) |args| {
        defer {
            for (args) |arg| std.testing.allocator.free(arg);
            std.testing.allocator.free(args);
        }
        const joined = try command.joinArgv(std.testing.allocator, &.{"zig"}, args);
        defer std.testing.allocator.free(joined);
    } else |_| {}
}
