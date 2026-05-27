const std = @import("std");
const cobertura = @import("coverage_cobertura.zig");
const coverage_config = @import("coverage_config.zig");
const json_util = @import("../common/json_util.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const JsonValue = std.json.Value;
const CoverageFileStats = cobertura.CoverageFileStats;
const CoverageStats = cobertura.CoverageStats;

const percent_scale: u32 = 100;

// Owns the stable release-evidence JSON shape emitted by the coverage command.

/// Per-test executable result included in the coverage summary.
pub const TestResult = struct {
    name: []const u8,
    path: []const u8,
    ok: bool,
    exit_code: i64,
    tests: ?i64,
    min_tests: i64,
    tests_ok: bool,
    stdout_bytes: usize,
    stderr_bytes: usize,
};

/// kcov availability, execution, and parsed Cobertura state for summary output.
pub const KcovInput = struct {
    available: bool,
    path: ?[]const u8,
    required: bool,
    ran: bool,
    error_message: ?[]const u8,
    stats: ?CoverageStats,
    min_line_coverage: u32,
    min_src_line_coverage: u32,
    min_tools_line_coverage: u32,
    floors_ok: bool,
};

const CoverageSummaryInput = struct {
    ok: bool,
    zig_version: []const u8,
    total_tests: i64,
    min_total_tests: i64,
    total_tests_ok: bool,
    suite_tests_ok: bool,
    tests: []const TestResult,
    kcov: KcovInput,
};

/// Renders release coverage evidence as deterministic JSON.
pub fn renderCoverageSummary(allocator: Allocator, io: Io, input: CoverageSummaryInput) ![]u8 {
    var aw: Io.Writer.Allocating = .init(allocator);
    var aw_owned = true;
    defer if (aw_owned) aw.deinit();
    try aw.writer.writeAll("{\n");
    try aw.writer.writeAll("  \"kind\": \"test_summary\",\n");
    try aw.writer.print("  \"ok\": {},\n", .{input.ok});
    try aw.writer.print("  \"generated_at_unix_ns\": {d},\n", .{Io.Clock.now(.real, io).nanoseconds});
    try aw.writer.writeAll("  \"root\": ");
    try json_util.writeString(&aw.writer, ".");
    try aw.writer.writeAll(",\n");
    try aw.writer.writeAll("  \"zig_version\": ");
    try json_util.writeString(&aw.writer, input.zig_version);
    try aw.writer.writeAll(",\n");
    try aw.writer.print("  \"total_tests\": {d},\n", .{input.total_tests});
    try aw.writer.print("  \"min_total_tests\": {d},\n", .{input.min_total_tests});
    try aw.writer.print("  \"total_tests_ok\": {},\n", .{input.total_tests_ok});
    try aw.writer.print("  \"suite_tests_ok\": {},\n", .{input.suite_tests_ok});
    try aw.writer.writeAll("  \"tests\": [\n");
    for (input.tests, 0..) |result, i| {
        if (i > 0) try aw.writer.writeAll(",\n");
        try renderTestResult(&aw.writer, result, "    ");
    }
    try aw.writer.writeAll("\n  ],\n");
    try renderCoverageObject(&aw.writer, input.kcov);
    try aw.writer.writeAll("\n}\n");
    const rendered = try aw.toOwnedSlice();
    aw_owned = false;
    return rendered;
}

fn renderCoverageObject(writer: *Io.Writer, input: KcovInput) !void {
    try writer.writeAll("  \"coverage\": {\n");
    try writer.print("    \"measured\": {},\n", .{input.stats != null});
    try writer.print("    \"available\": {},\n", .{input.available});
    if (input.path) |path| {
        try writer.writeAll("    \"path\": ");
        try json_util.writeString(writer, path);
        try writer.writeAll(",\n");
    } else {
        try writer.writeAll("    \"path\": null,\n");
    }
    try writer.print("    \"required\": {},\n", .{input.required});
    try writer.print("    \"ran\": {},\n", .{input.ran});
    try writer.print("    \"floors_ok\": {},\n", .{input.floors_ok});
    try writer.writeAll("    \"min_line_coverage_percent\": ");
    try writePercent(writer, input.min_line_coverage);
    try writer.writeAll(",\n    \"min_src_line_coverage_percent\": ");
    try writePercent(writer, input.min_src_line_coverage);
    try writer.writeAll(",\n    \"min_tools_line_coverage_percent\": ");
    try writePercent(writer, input.min_tools_line_coverage);
    try writer.writeAll(",\n");
    try writer.writeAll("    \"include_path\": ");
    try json_util.writeString(writer, coverage_config.kcov_include_path);
    try writer.writeAll(",\n");
    try writer.writeAll("    \"exclude_path\": ");
    try json_util.writeString(writer, coverage_config.kcov_exclude_path);
    if (input.stats) |stats| {
        try writer.writeAll(",\n    \"covered_lines\": ");
        try writer.print("{d}", .{stats.covered_lines});
        try writer.writeAll(",\n    \"total_lines\": ");
        try writer.print("{d}", .{stats.total_lines});
        try writer.writeAll(",\n    \"line_coverage_percent\": ");
        try writeOptionalPercent(writer, stats.lineRateBasisPoints());
        try writer.writeAll(",\n    \"src_line_coverage_percent\": ");
        try writeOptionalPercent(writer, stats.srcLineRateBasisPoints());
        try writer.writeAll(",\n    \"tools_line_coverage_percent\": ");
        try writeOptionalPercent(writer, stats.toolsLineRateBasisPoints());
        try writer.writeAll(",\n    \"line_coverage_ok\": ");
        try writer.print("{}", .{meetsFloor(stats.lineRateBasisPoints(), input.min_line_coverage)});
        try writer.writeAll(",\n    \"src_line_coverage_ok\": ");
        try writer.print("{}", .{meetsFloor(stats.srcLineRateBasisPoints(), input.min_src_line_coverage)});
        try writer.writeAll(",\n    \"tools_line_coverage_ok\": ");
        try writer.print("{}", .{meetsFloor(stats.toolsLineRateBasisPoints(), input.min_tools_line_coverage)});
        try writer.writeAll(",\n    \"uncovered_line_count\": ");
        try writer.print("{d}", .{stats.uncoveredLineCount()});
        try writer.writeAll(",\n    \"missing_file_count\": ");
        try writer.print("{d}", .{stats.missingFileCount()});
        try writer.writeAll(",\n    \"missing_files\": [");
        for (stats.missing_files, 0..) |path, i| {
            if (i > 0) try writer.writeAll(", ");
            try json_util.writeString(writer, path);
        }
        try writer.writeAll("],\n    \"files\": [\n");
        for (stats.files, 0..) |file, i| {
            if (i > 0) try writer.writeAll(",\n");
            try renderCoverageFile(writer, file);
        }
        try writer.writeAll("\n    ]");
    }
    if (input.error_message) |err| {
        try writer.writeAll(",\n    \"error\": ");
        try json_util.writeString(writer, err);
    }
    try writer.writeAll("\n  }");
}

fn renderCoverageFile(writer: *Io.Writer, file: CoverageFileStats) !void {
    try writer.writeAll("      {\n        \"path\": ");
    try json_util.writeString(writer, file.path);
    try writer.writeAll(",\n        \"scope\": ");
    try json_util.writeString(writer, @tagName(file.scope));
    try writer.writeAll(",\n        \"covered_lines\": ");
    try writer.print("{d}", .{file.covered_lines});
    try writer.writeAll(",\n        \"total_lines\": ");
    try writer.print("{d}", .{file.total_lines});
    try writer.writeAll(",\n        \"line_coverage_percent\": ");
    try writeOptionalPercent(writer, file.lineRateBasisPoints());
    try writer.writeAll(",\n        \"uncovered_lines\": [");
    for (file.uncovered_lines, 0..) |line, i| {
        if (i > 0) try writer.writeAll(", ");
        try writer.print("{d}", .{line});
    }
    try writer.writeAll("]\n      }");
}

fn writePercent(writer: *Io.Writer, value: u32) !void {
    try writer.print("{d}.{d:0>2}", .{ value / percent_scale, value % percent_scale });
}

fn writeOptionalPercent(writer: *Io.Writer, value: ?u32) !void {
    if (value) |bp| {
        try writer.print("{d}.{d:0>2}", .{ bp / percent_scale, bp % percent_scale });
    } else {
        try writer.writeAll("null");
    }
}

fn renderTestResult(writer: *Io.Writer, result: TestResult, indent: []const u8) !void {
    try writer.print("{s}{{\n{s}  \"name\": ", .{ indent, indent });
    try json_util.writeString(writer, result.name);
    try writer.print(",\n{s}  \"path\": ", .{indent});
    try json_util.writeString(writer, result.path);
    try writer.print(",\n{s}  \"ok\": {},\n{s}  \"exit_code\": {d},\n", .{ indent, result.ok, indent, result.exit_code });
    if (result.tests) |count| {
        try writer.print("{s}  \"tests\": {d},\n", .{ indent, count });
    } else {
        try writer.print("{s}  \"tests\": null,\n", .{indent});
    }
    try writer.print(
        \\{s}  "min_tests": {d},
        \\{s}  "tests_ok": {},
        \\{s}  "stdout_bytes": {d},
        \\{s}  "stderr_bytes": {d}
        \\{s}}}
    , .{ indent, result.min_tests, indent, result.tests_ok, indent, result.stdout_bytes, indent, result.stderr_bytes, indent });
}

fn meetsFloor(actual: ?u32, minimum: u32) bool {
    return if (actual) |value| value >= minimum else false;
}

fn valueAt(value: JsonValue, path: []const u8) ?JsonValue {
    var current = value;
    var parts = std.mem.splitScalar(u8, path, '.');
    while (parts.next()) |part| {
        if (part.len == 0) return null;
        if (isDigits(part)) {
            if (current != .array) return null;
            const index = std.fmt.parseInt(usize, part, 10) catch return null;
            if (index >= current.array.items.len) return null;
            current = current.array.items[index];
        } else {
            if (current != .object) return null;
            current = current.object.get(part) orelse return null;
        }
    }
    return current;
}

fn isDigits(text: []const u8) bool {
    if (text.len == 0) return false;
    for (text) |c| if (c < '0' or c > '9') return false;
    return true;
}

test "renderCoverageSummary includes suite floors and coverage details" {
    const results = [_]TestResult{
        .{
            .name = "zigars-lib-tests",
            .path = "zig-out/test-bin/zigars-lib-tests",
            .ok = true,
            .exit_code = 0,
            .tests = 380,
            .min_tests = 350,
            .tests_ok = true,
            .stdout_bytes = 100,
            .stderr_bytes = 0,
        },
        .{
            .name = "zigars-exe-tests",
            .path = "zig-out/test-bin/zigars-exe-tests",
            .ok = true,
            .exit_code = 0,
            .tests = 121,
            .min_tests = 100,
            .tests_ok = true,
            .stdout_bytes = 20,
            .stderr_bytes = 0,
        },
        .{
            .name = "zigars-tools-tests",
            .path = "zig-out/test-bin/zigars-tools-tests",
            .ok = true,
            .exit_code = 0,
            .tests = 21,
            .min_tests = 18,
            .tests_ok = true,
            .stdout_bytes = 40,
            .stderr_bytes = 0,
        },
        .{
            .name = "zigars-no-count-tests",
            .path = "zig-out/test-bin/zigars-no-count-tests",
            .ok = true,
            .exit_code = 0,
            .tests = null,
            .min_tests = 0,
            .tests_ok = true,
            .stdout_bytes = 0,
            .stderr_bytes = 0,
        },
    };
    const summary = try renderCoverageSummary(std.testing.allocator, std.testing.io, .{
        .ok = true,
        .zig_version = "0.16.0",
        .total_tests = 522,
        .min_total_tests = 480,
        .total_tests_ok = true,
        .suite_tests_ok = true,
        .tests = &results,
        .kcov = .{
            .available = true,
            .path = "kcov",
            .required = true,
            .ran = true,
            .error_message = null,
            .stats = .{
                .covered_lines = 8,
                .total_lines = 10,
                .src_covered_lines = 5,
                .src_total_lines = 7,
                .tools_covered_lines = 3,
                .tools_total_lines = 3,
                .files = @constCast(&[_]CoverageFileStats{
                    .{
                        .path = "src/root.zig",
                        .scope = .src,
                        .covered_lines = 5,
                        .total_lines = 7,
                        .uncovered_lines = @constCast(&[_]u32{ 3, 5 }),
                    },
                    .{
                        .path = "tools/coverage/coverage.zig",
                        .scope = .tools,
                        .covered_lines = 3,
                        .total_lines = 3,
                    },
                }),
                .missing_files = @constCast(&[_][]const u8{"src/missing.zig"}),
            },
            .min_line_coverage = 7000,
            .min_src_line_coverage = 7000,
            .min_tools_line_coverage = 9000,
            .floors_ok = true,
        },
    });
    defer std.testing.allocator.free(summary);

    const parsed = try std.json.parseFromSlice(JsonValue, std.testing.allocator, summary, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("test_summary", valueAt(parsed.value, "kind").?.string);
    try std.testing.expectEqual(@as(usize, 4), valueAt(parsed.value, "tests").?.array.items.len);
    try std.testing.expectEqual(@as(i64, 480), valueAt(parsed.value, "min_total_tests").?.integer);
    try std.testing.expect(valueAt(parsed.value, "suite_tests_ok").?.bool);
    try std.testing.expectEqual(@as(i64, 350), valueAt(parsed.value, "tests.0.min_tests").?.integer);
    try std.testing.expectEqual(@as(i64, 100), valueAt(parsed.value, "tests.1.min_tests").?.integer);
    try std.testing.expect(valueAt(parsed.value, "tests.2.tests_ok").?.bool);
    try std.testing.expect(valueAt(parsed.value, "tests.3.tests").? == .null);
    try std.testing.expect(valueAt(parsed.value, "coverage.measured").?.bool);
    try std.testing.expect(valueAt(parsed.value, "coverage.floors_ok").?.bool);
    try std.testing.expect(valueAt(parsed.value, "coverage.line_coverage_ok").?.bool);
    try std.testing.expect(valueAt(parsed.value, "coverage.src_line_coverage_ok").?.bool);
    try std.testing.expect(valueAt(parsed.value, "coverage.tools_line_coverage_ok").?.bool);
    try std.testing.expectEqual(@as(i64, 8), valueAt(parsed.value, "coverage.covered_lines").?.integer);
    try std.testing.expectEqual(@as(i64, 2), valueAt(parsed.value, "coverage.uncovered_line_count").?.integer);
    try std.testing.expectEqual(@as(i64, 1), valueAt(parsed.value, "coverage.missing_file_count").?.integer);
    try std.testing.expectEqualStrings("src/missing.zig", valueAt(parsed.value, "coverage.missing_files.0").?.string);
    try std.testing.expectEqualStrings("src/root.zig", valueAt(parsed.value, "coverage.files.0.path").?.string);
    try std.testing.expectEqual(@as(i64, 3), valueAt(parsed.value, "coverage.files.0.uncovered_lines.0").?.integer);
}

test "renderCoverageSummary renders absent kcov path and error details" {
    const summary = try renderCoverageSummary(std.testing.allocator, std.testing.io, .{
        .ok = false,
        .zig_version = "0.16.0",
        .total_tests = 0,
        .min_total_tests = 0,
        .total_tests_ok = true,
        .suite_tests_ok = true,
        .tests = &.{},
        .kcov = .{
            .available = false,
            .path = null,
            .required = true,
            .ran = false,
            .error_message = "kcov failed",
            .stats = null,
            .min_line_coverage = 10000,
            .min_src_line_coverage = 10000,
            .min_tools_line_coverage = 10000,
            .floors_ok = false,
        },
    });
    defer std.testing.allocator.free(summary);

    const parsed = try std.json.parseFromSlice(JsonValue, std.testing.allocator, summary, .{});
    defer parsed.deinit();
    try std.testing.expect(valueAt(parsed.value, "coverage.path").? == .null);
    try std.testing.expectEqualStrings("kcov failed", valueAt(parsed.value, "coverage.error").?.string);
}
