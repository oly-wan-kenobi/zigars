const std = @import("std");
const coverage_config = @import("coverage_config.zig");
const json_util = @import("json_util.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const JsonValue = std.json.Value;

fn stdoutWrite(io: Io, bytes: []const u8) !void {
    try Io.File.stdout().writeStreamingAll(io, bytes);
}

fn writeFile(io: Io, path: []const u8, bytes: []const u8) !void {
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes });
}

fn nowNs(io: Io) i96 {
    return Io.Clock.now(.real, io).nanoseconds;
}

const CoverageOptions = struct {
    out_dir: []const u8 = "coverage",
    zig: []const u8 = "zig",
    min_tests: i64 = coverage_config.min_total_tests,
    no_build: bool = false,
    require_kcov: bool = false,
    allow_kcov_failure: bool = false,
};

const TestResult = struct {
    name: []const u8,
    path: []const u8,
    ok: bool,
    exit_code: i64,
    tests: ?i64,
    stdout_bytes: usize,
    stderr_bytes: usize,
};

pub fn run(allocator: Allocator, io: Io, args: []const []const u8) !void {
    var options: CoverageOptions = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--out-dir")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            options.out_dir = args[i];
        } else if (std.mem.eql(u8, args[i], "--zig")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            options.zig = args[i];
        } else if (std.mem.eql(u8, args[i], "--min-tests")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            options.min_tests = try std.fmt.parseInt(i64, args[i], 10);
            if (options.min_tests < 0) return error.InvalidArguments;
        } else if (std.mem.eql(u8, args[i], "--no-build")) {
            options.no_build = true;
        } else if (std.mem.eql(u8, args[i], "--require-kcov")) {
            options.require_kcov = true;
        } else if (std.mem.eql(u8, args[i], "--allow-kcov-failure")) {
            options.allow_kcov_failure = true;
        } else {
            return error.InvalidArguments;
        }
    }

    try Io.Dir.cwd().createDirPath(io, options.out_dir);
    if (!options.no_build) {
        const build = try std.process.run(allocator, io, .{ .argv = &.{ options.zig, "build", "install-test-bins" } });
        defer allocator.free(build.stdout);
        defer allocator.free(build.stderr);
        if (!termOk(build.term)) return error.BuildFailed;
    }

    var test_results: std.ArrayList(TestResult) = .empty;
    defer {
        for (test_results.items) |result| freeTestResult(allocator, result);
        test_results.deinit(allocator);
    }
    var test_paths: std.ArrayList([]const u8) = .empty;
    defer test_paths.deinit(allocator);
    for (coverage_config.test_binaries) |binary| {
        const path = binary.path();
        try test_results.append(allocator, try runTestBinary(allocator, io, path, binary.name));
        try test_paths.append(allocator, path);
    }

    const version_result = try std.process.run(allocator, io, .{ .argv = &.{ options.zig, "version" } });
    defer allocator.free(version_result.stdout);
    defer allocator.free(version_result.stderr);
    const zig_version = std.mem.trim(u8, version_result.stdout, " \t\r\n");

    const kcov_path = findExecutable(allocator, io, "kcov") catch null;
    defer if (kcov_path) |p| allocator.free(p);

    var ok = true;
    var total_tests: i64 = 0;
    for (test_results.items) |result| {
        ok = ok and result.ok;
        total_tests += result.tests orelse 0;
    }
    const total_tests_ok = total_tests >= options.min_tests;
    ok = ok and total_tests_ok;
    var kcov_ran = false;
    var kcov_error: ?[]const u8 = null;
    if (kcov_path) |kcov| {
        kcov_ran = true;
        const ran_ok = runKcov(allocator, io, kcov, options.out_dir, test_paths.items) catch |err| blk: {
            kcov_error = try std.fmt.allocPrint(allocator, "kcov exited with {s}", .{@errorName(err)});
            break :blk false;
        };
        if (!ran_ok) {
            if (kcov_error == null) kcov_error = try allocator.dupe(u8, "kcov exited unsuccessfully");
            if (!options.allow_kcov_failure) ok = false;
        }
    } else if (options.require_kcov) {
        kcov_error = try allocator.dupe(u8, "kcov was required but is not available on PATH");
        ok = false;
    }
    defer if (kcov_error) |e| allocator.free(e);

    const summary_path = try std.fmt.allocPrint(allocator, "{s}/summary.json", .{options.out_dir});
    defer allocator.free(summary_path);
    const summary = try renderCoverageSummary(allocator, io, .{
        .ok = ok,
        .zig_version = zig_version,
        .total_tests = total_tests,
        .min_total_tests = options.min_tests,
        .total_tests_ok = total_tests_ok,
        .tests = test_results.items,
        .kcov_available = kcov_path != null,
        .kcov_path = kcov_path,
        .kcov_required = options.require_kcov,
        .kcov_ran = kcov_ran,
        .kcov_error = kcov_error,
    });
    defer allocator.free(summary);
    try writeFile(io, summary_path, summary);
    const message = try std.fmt.allocPrint(allocator, "coverage summary written to {s}\n", .{summary_path});
    defer allocator.free(message);
    try stdoutWrite(io, message);
    if (!ok) return error.CoverageFailed;
}

fn runTestBinary(allocator: Allocator, io: Io, path: []const u8, name: []const u8) !TestResult {
    const result = try std.process.run(allocator, io, .{ .argv = &.{path} });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    const combined = try std.mem.concat(allocator, u8, &.{ result.stdout, result.stderr });
    defer allocator.free(combined);
    return .{
        .name = try allocator.dupe(u8, name),
        .path = try allocator.dupe(u8, path),
        .ok = termOk(result.term),
        .exit_code = termExitCode(result.term),
        .tests = parseTestCount(combined),
        .stdout_bytes = result.stdout.len,
        .stderr_bytes = result.stderr.len,
    };
}

fn freeTestResult(allocator: Allocator, result: TestResult) void {
    allocator.free(result.name);
    allocator.free(result.path);
}

fn parseTestCount(text: []const u8) ?i64 {
    const prefix = "All ";
    var start: usize = 0;
    while (std.mem.indexOfPos(u8, text, start, prefix)) |idx| {
        const n_start = idx + prefix.len;
        const n_end_rel = std.mem.indexOfScalar(u8, text[n_start..], ' ') orelse return null;
        const n_end = n_start + n_end_rel;
        if (std.mem.startsWith(u8, text[n_end..], " tests passed.")) {
            return std.fmt.parseInt(i64, text[n_start..n_end], 10) catch null;
        }
        start = n_start;
    }
    return null;
}

fn termOk(term: std.process.Child.Term) bool {
    return switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
}

fn termExitCode(term: std.process.Child.Term) i64 {
    return switch (term) {
        .exited => |code| @intCast(code),
        .signal => -1,
        .stopped => -2,
        .unknown => -3,
    };
}

fn findExecutable(allocator: Allocator, io: Io, name: []const u8) !?[]u8 {
    const result = std.process.run(allocator, io, .{ .argv = &.{ name, "--version" } }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (!termOk(result.term)) return null;
    return try allocator.dupe(u8, name);
}

fn runKcov(allocator: Allocator, io: Io, kcov: []const u8, out_dir: []const u8, tests: []const []const u8) !bool {
    for (tests) |test_path| {
        const stem = std.fs.path.stem(test_path);
        const target_dir = try std.fmt.allocPrint(allocator, "{s}/kcov/{s}", .{ out_dir, stem });
        defer allocator.free(target_dir);
        const result = try std.process.run(allocator, io, .{
            .argv = &.{ kcov, "--include-path=src", target_dir, test_path },
        });
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
        if (!termOk(result.term)) return false;
    }
    return true;
}

const CoverageSummaryInput = struct {
    ok: bool,
    zig_version: []const u8,
    total_tests: i64,
    min_total_tests: i64,
    total_tests_ok: bool,
    tests: []const TestResult,
    kcov_available: bool,
    kcov_path: ?[]const u8,
    kcov_required: bool,
    kcov_ran: bool,
    kcov_error: ?[]const u8,
};

fn renderCoverageSummary(allocator: Allocator, io: Io, input: CoverageSummaryInput) ![]u8 {
    var aw: Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    try aw.writer.writeAll("{\n");
    try aw.writer.print("  \"ok\": {},\n", .{input.ok});
    try aw.writer.print("  \"generated_at_unix_ns\": {d},\n", .{nowNs(io)});
    try aw.writer.writeAll("  \"root\": ");
    try json_util.writeString(&aw.writer, ".");
    try aw.writer.writeAll(",\n");
    try aw.writer.writeAll("  \"zig_version\": ");
    try json_util.writeString(&aw.writer, input.zig_version);
    try aw.writer.writeAll(",\n");
    try aw.writer.print("  \"total_tests\": {d},\n", .{input.total_tests});
    try aw.writer.print("  \"min_total_tests\": {d},\n", .{input.min_total_tests});
    try aw.writer.print("  \"total_tests_ok\": {},\n", .{input.total_tests_ok});
    try aw.writer.writeAll("  \"tests\": [\n");
    for (input.tests, 0..) |result, i| {
        if (i > 0) try aw.writer.writeAll(",\n");
        try renderTestResult(&aw.writer, result, "    ");
    }
    try aw.writer.writeAll("\n  ],\n");
    try aw.writer.writeAll("  \"kcov\": {\n");
    try aw.writer.print("    \"available\": {},\n", .{input.kcov_available});
    if (input.kcov_path) |path| {
        try aw.writer.writeAll("    \"path\": ");
        try json_util.writeString(&aw.writer, path);
        try aw.writer.writeAll(",\n");
    } else {
        try aw.writer.writeAll("    \"path\": null,\n");
    }
    try aw.writer.print("    \"required\": {},\n", .{input.kcov_required});
    try aw.writer.print("    \"ran\": {}", .{input.kcov_ran});
    if (input.kcov_error) |err| {
        try aw.writer.writeAll(",\n    \"error\": ");
        try json_util.writeString(&aw.writer, err);
        try aw.writer.writeAll("\n");
    } else {
        try aw.writer.writeAll("\n");
    }
    try aw.writer.writeAll("  }\n}\n");
    return try aw.toOwnedSlice();
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
        \\{s}  "stdout_bytes": {d},
        \\{s}  "stderr_bytes": {d}
        \\{s}}}
    , .{ indent, result.stdout_bytes, indent, result.stderr_bytes, indent });
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

test "parseTestCount extracts Zig test runner totals" {
    try std.testing.expectEqual(@as(?i64, 42), parseTestCount("All 42 tests passed.\n"));
    try std.testing.expectEqual(@as(?i64, 7), parseTestCount("noise\nAll 7 tests passed.\n"));
    try std.testing.expectEqual(@as(?i64, null), parseTestCount("1/1 test.foo...OK\n"));
    try std.testing.expectEqual(@as(?i64, null), parseTestCount("All tests passed.\n"));
}

test "renderCoverageSummary includes every configured test binary" {
    const results = [_]TestResult{
        .{
            .name = "zigar-lib-tests",
            .path = "zig-out/test-bin/zigar-lib-tests",
            .ok = true,
            .exit_code = 0,
            .tests = 10,
            .stdout_bytes = 100,
            .stderr_bytes = 0,
        },
        .{
            .name = "zigar-exe-tests",
            .path = "zig-out/test-bin/zigar-exe-tests",
            .ok = true,
            .exit_code = 0,
            .tests = 11,
            .stdout_bytes = 110,
            .stderr_bytes = 0,
        },
        .{
            .name = "zigar-tools-tests",
            .path = "zig-out/test-bin/zigar-tools-tests",
            .ok = true,
            .exit_code = 0,
            .tests = 4,
            .stdout_bytes = 40,
            .stderr_bytes = 0,
        },
    };
    const summary = try renderCoverageSummary(std.testing.allocator, std.testing.io, .{
        .ok = true,
        .zig_version = "0.16.0",
        .total_tests = 25,
        .min_total_tests = 20,
        .total_tests_ok = true,
        .tests = &results,
        .kcov_available = true,
        .kcov_path = "kcov",
        .kcov_required = false,
        .kcov_ran = true,
        .kcov_error = "kcov exited unsuccessfully",
    });
    defer std.testing.allocator.free(summary);

    const parsed = try std.json.parseFromSlice(JsonValue, std.testing.allocator, summary, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 3), valueAt(parsed.value, "tests").?.array.items.len);
    try std.testing.expectEqual(@as(i64, 25), valueAt(parsed.value, "total_tests").?.integer);
    try std.testing.expectEqual(@as(i64, 20), valueAt(parsed.value, "min_total_tests").?.integer);
    try std.testing.expect(valueAt(parsed.value, "total_tests_ok").?.bool);
    try std.testing.expectEqualStrings("zigar-tools-tests", valueAt(parsed.value, "tests.2.name").?.string);
    try std.testing.expectEqualStrings("kcov", valueAt(parsed.value, "kcov.path").?.string);
    try std.testing.expectEqualStrings("kcov exited unsuccessfully", valueAt(parsed.value, "kcov.error").?.string);
}
