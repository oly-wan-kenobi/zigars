const std = @import("std");
const coverage_config = @import("coverage_config.zig");
const json_util = @import("json_util.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const JsonValue = std.json.Value;

const percent_scale: u32 = 100;

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
    min_tests: i64,
    tests_ok: bool,
    stdout_bytes: usize,
    stderr_bytes: usize,
};

const CoverageStats = struct {
    covered_lines: u64 = 0,
    total_lines: u64 = 0,
    src_covered_lines: u64 = 0,
    src_total_lines: u64 = 0,
    tools_covered_lines: u64 = 0,
    tools_total_lines: u64 = 0,

    fn lineRateBasisPoints(self: CoverageStats) ?u32 {
        return rateBasisPoints(self.covered_lines, self.total_lines);
    }

    fn srcLineRateBasisPoints(self: CoverageStats) ?u32 {
        return rateBasisPoints(self.src_covered_lines, self.src_total_lines);
    }

    fn toolsLineRateBasisPoints(self: CoverageStats) ?u32 {
        return rateBasisPoints(self.tools_covered_lines, self.tools_total_lines);
    }
};

const KcovInput = struct {
    available: bool,
    path: ?[]const u8,
    required: bool,
    ran: bool,
    error_message: ?[]const u8,
    stats: ?CoverageStats,
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
        try test_results.append(allocator, try runTestBinary(allocator, io, path, binary));
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
    var suite_tests_ok = true;
    for (test_results.items) |result| {
        ok = ok and result.ok;
        suite_tests_ok = suite_tests_ok and result.tests_ok;
        total_tests += result.tests orelse 0;
    }
    ok = ok and suite_tests_ok;
    const total_tests_ok = total_tests >= options.min_tests;
    ok = ok and total_tests_ok;

    var kcov_ran = false;
    var kcov_error: ?[]const u8 = null;
    var coverage_stats: ?CoverageStats = null;
    if (kcov_path) |kcov| {
        kcov_ran = true;
        coverage_stats = runKcov(allocator, io, kcov, options.out_dir, test_paths.items, &kcov_error) catch |err| blk: {
            if (kcov_error == null) kcov_error = try std.fmt.allocPrint(allocator, "kcov exited with {s}", .{@errorName(err)});
            break :blk null;
        };
        if (coverage_stats == null and !options.allow_kcov_failure) {
            if (kcov_error == null) kcov_error = try allocator.dupe(u8, "kcov exited unsuccessfully");
            ok = false;
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
        .suite_tests_ok = suite_tests_ok,
        .tests = test_results.items,
        .kcov = .{
            .available = kcov_path != null,
            .path = kcov_path,
            .required = options.require_kcov,
            .ran = kcov_ran,
            .error_message = kcov_error,
            .stats = coverage_stats,
        },
    });
    defer allocator.free(summary);
    try writeFile(io, summary_path, summary);
    const message = try std.fmt.allocPrint(allocator, "test and coverage summary written to {s}\n", .{summary_path});
    defer allocator.free(message);
    try stdoutWrite(io, message);
    if (!ok) return error.CoverageFailed;
}

fn runTestBinary(allocator: Allocator, io: Io, path: []const u8, binary: coverage_config.TestBinary) !TestResult {
    const result = try std.process.run(allocator, io, .{ .argv = &.{path} });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    const combined = try std.mem.concat(allocator, u8, &.{ result.stdout, result.stderr });
    defer allocator.free(combined);
    const tests = parseTestCount(combined);
    return .{
        .name = try allocator.dupe(u8, binary.name),
        .path = try allocator.dupe(u8, path),
        .ok = termOk(result.term),
        .exit_code = termExitCode(result.term),
        .tests = tests,
        .min_tests = binary.min_tests,
        .tests_ok = if (tests) |count| count >= binary.min_tests else false,
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

fn runKcov(allocator: Allocator, io: Io, kcov: []const u8, out_dir: []const u8, tests: []const []const u8, error_message: *?[]const u8) !CoverageStats {
    const kcov_root = try std.fmt.allocPrint(allocator, "{s}/kcov", .{out_dir});
    defer allocator.free(kcov_root);
    try Io.Dir.cwd().createDirPath(io, kcov_root);

    var result_dirs: std.ArrayList([]const u8) = .empty;
    defer {
        for (result_dirs.items) |dir| allocator.free(dir);
        result_dirs.deinit(allocator);
    }

    for (tests) |test_path| {
        const stem = std.fs.path.stem(test_path);
        const target_dir = try std.fmt.allocPrint(allocator, "{s}/kcov/{s}", .{ out_dir, stem });
        errdefer allocator.free(target_dir);
        const include_arg = "--include-path=" ++ coverage_config.kcov_include_path;
        const exclude_arg = "--exclude-path=" ++ coverage_config.kcov_exclude_path;
        const result = try std.process.run(allocator, io, .{
            .argv = &.{ kcov, "--clean", include_arg, exclude_arg, target_dir, test_path },
        });
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
        if (!termOk(result.term)) {
            try recordCommandFailure(allocator, error_message, "kcov", result.stdout, result.stderr);
            return error.KcovFailed;
        }
        try result_dirs.append(allocator, target_dir);
    }

    const report_dir = if (result_dirs.items.len == 1) result_dirs.items[0] else blk: {
        const merged_dir = try std.fmt.allocPrint(allocator, "{s}/kcov/merged", .{out_dir});
        errdefer allocator.free(merged_dir);
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(allocator);
        try argv.appendSlice(allocator, &.{ kcov, "--merge", merged_dir });
        try argv.appendSlice(allocator, result_dirs.items);
        const result = try std.process.run(allocator, io, .{ .argv = argv.items });
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
        if (!termOk(result.term)) {
            try recordCommandFailure(allocator, error_message, "kcov merge", result.stdout, result.stderr);
            return error.KcovMergeFailed;
        }
        try result_dirs.append(allocator, merged_dir);
        break :blk merged_dir;
    };

    const xml = try readCoberturaXml(allocator, io, report_dir);
    defer allocator.free(xml);
    const stats = try parseCobertura(xml);
    if (stats.total_lines == 0) return error.EmptyCoverageReport;
    return stats;
}

fn readCoberturaXml(allocator: Allocator, io: Io, report_dir: []const u8) ![]u8 {
    const direct = try std.fmt.allocPrint(allocator, "{s}/cobertura.xml", .{report_dir});
    defer allocator.free(direct);
    if (Io.Dir.cwd().readFileAlloc(io, direct, allocator, .limited(32 * 1024 * 1024))) |xml| {
        return xml;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }

    var dir = try Io.Dir.cwd().openDir(io, report_dir, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(allocator);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.eql(u8, std.fs.path.basename(entry.path), "cobertura.xml")) continue;
        const report_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ report_dir, entry.path });
        defer allocator.free(report_path);
        return try Io.Dir.cwd().readFileAlloc(io, report_path, allocator, .limited(32 * 1024 * 1024));
    }
    return error.FileNotFound;
}

fn recordCommandFailure(allocator: Allocator, error_message: *?[]const u8, phase: []const u8, stdout: []const u8, stderr: []const u8) !void {
    if (error_message.* != null) return;
    const stderr_text = std.mem.trim(u8, stderr, " \t\r\n");
    const stdout_text = std.mem.trim(u8, stdout, " \t\r\n");
    const detail = if (stderr_text.len > 0) stderr_text else stdout_text;
    if (detail.len == 0) {
        error_message.* = try std.fmt.allocPrint(allocator, "{s} exited unsuccessfully without output", .{phase});
        return;
    }
    const limit = @min(detail.len, 2048);
    error_message.* = try std.fmt.allocPrint(allocator, "{s} exited unsuccessfully: {s}", .{ phase, detail[0..limit] });
}

fn rateBasisPoints(covered: u64, total: u64) ?u32 {
    if (total == 0) return null;
    return @intCast((covered * 100 * percent_scale) / total);
}

fn parseCobertura(xml: []const u8) !CoverageStats {
    var stats: CoverageStats = .{};
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, xml, pos, "<class")) |class_start| {
        const tag_end = std.mem.indexOfScalarPos(u8, xml, class_start, '>') orelse return error.InvalidCoverageReport;
        const tag = xml[class_start .. tag_end + 1];
        const filename = attributeValue(tag, "filename") orelse {
            pos = tag_end + 1;
            continue;
        };
        const body_start = tag_end + 1;
        const class_end = std.mem.indexOfPos(u8, xml, body_start, "</class>") orelse body_start;
        const body = xml[body_start..class_end];
        const scope = coverageScope(filename);
        if (scope == .ignored) {
            pos = class_end + "</class>".len;
            continue;
        }

        var line_pos: usize = 0;
        while (std.mem.indexOfPos(u8, body, line_pos, "<line")) |line_start| {
            const line_tag_end = std.mem.indexOfScalarPos(u8, body, line_start, '>') orelse return error.InvalidCoverageReport;
            const line_tag = body[line_start .. line_tag_end + 1];
            const hits_text = attributeValue(line_tag, "hits") orelse {
                line_pos = line_tag_end + 1;
                continue;
            };
            const covered = (std.fmt.parseInt(u64, hits_text, 10) catch 0) > 0;
            stats.total_lines += 1;
            if (covered) stats.covered_lines += 1;
            switch (scope) {
                .src => {
                    stats.src_total_lines += 1;
                    if (covered) stats.src_covered_lines += 1;
                },
                .tools => {
                    stats.tools_total_lines += 1;
                    if (covered) stats.tools_covered_lines += 1;
                },
                .ignored => {},
            }
            line_pos = line_tag_end + 1;
        }
        pos = if (class_end == body_start) body_start else class_end + "</class>".len;
    }
    return stats;
}

const CoverageScope = enum { src, tools, ignored };

fn coverageScope(filename: []const u8) CoverageScope {
    if (isScopePath(filename, "src")) return .src;
    if (isScopePath(filename, "tools")) return .tools;
    return .ignored;
}

fn isScopePath(filename: []const u8, scope: []const u8) bool {
    if (std.mem.eql(u8, filename, scope)) return true;
    if (std.mem.startsWith(u8, filename, scope) and filename.len > scope.len and isPathSep(filename[scope.len])) return true;
    const needle = if (std.mem.eql(u8, scope, "src")) "/src/" else "/tools/";
    return std.mem.indexOf(u8, filename, needle) != null;
}

fn isPathSep(byte: u8) bool {
    return byte == '/' or byte == '\\';
}

fn attributeValue(tag: []const u8, name: []const u8) ?[]const u8 {
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, tag, pos, name)) |idx| {
        const before_ok = idx == 0 or std.ascii.isWhitespace(tag[idx - 1]) or tag[idx - 1] == '<';
        const after = idx + name.len;
        if (before_ok and after < tag.len and tag[after] == '=') {
            if (after + 1 >= tag.len) return null;
            const quote = tag[after + 1];
            if (quote != '"' and quote != '\'') return null;
            const value_start = after + 2;
            const value_end = std.mem.indexOfScalarPos(u8, tag, value_start, quote) orelse return null;
            return tag[value_start..value_end];
        }
        pos = after;
    }
    return null;
}

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

fn renderCoverageSummary(allocator: Allocator, io: Io, input: CoverageSummaryInput) ![]u8 {
    var aw: Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    try aw.writer.writeAll("{\n");
    try aw.writer.writeAll("  \"kind\": \"test_summary\",\n");
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
    try aw.writer.print("  \"suite_tests_ok\": {},\n", .{input.suite_tests_ok});
    try aw.writer.writeAll("  \"tests\": [\n");
    for (input.tests, 0..) |result, i| {
        if (i > 0) try aw.writer.writeAll(",\n");
        try renderTestResult(&aw.writer, result, "    ");
    }
    try aw.writer.writeAll("\n  ],\n");
    try renderCoverageObject(&aw.writer, input.kcov);
    try aw.writer.writeAll("\n}\n");
    return try aw.toOwnedSlice();
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
    }
    if (input.error_message) |err| {
        try writer.writeAll(",\n    \"error\": ");
        try json_util.writeString(writer, err);
    }
    try writer.writeAll("\n  }");
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

test "parseCobertura counts src and tools lines" {
    const xml =
        \\<?xml version="1.0" ?>
        \\<coverage>
        \\  <packages>
        \\    <class filename="src/root.zig">
        \\      <lines>
        \\        <line number="1" hits="1"/>
        \\        <line number="2" hits="0"/>
        \\      </lines>
        \\    </class>
        \\    <class filename="/repo/tools/coverage.zig">
        \\      <lines>
        \\        <line number="1" hits="3"/>
        \\      </lines>
        \\    </class>
        \\    <class filename="zig-pkg/mcp.zig">
        \\      <lines>
        \\        <line number="1" hits="1"/>
        \\      </lines>
        \\    </class>
        \\  </packages>
        \\</coverage>
    ;
    const stats = try parseCobertura(xml);
    try std.testing.expectEqual(@as(u64, 2), stats.covered_lines);
    try std.testing.expectEqual(@as(u64, 3), stats.total_lines);
    try std.testing.expectEqual(@as(u64, 1), stats.src_covered_lines);
    try std.testing.expectEqual(@as(u64, 2), stats.src_total_lines);
    try std.testing.expectEqual(@as(u32, 6666), stats.lineRateBasisPoints().?);
    try std.testing.expectEqual(@as(u32, 5000), stats.srcLineRateBasisPoints().?);
    try std.testing.expectEqual(@as(u32, 10000), stats.toolsLineRateBasisPoints().?);
}

test "renderCoverageSummary includes suite floors and coverage details" {
    const results = [_]TestResult{
        .{
            .name = "zigar-lib-tests",
            .path = "zig-out/test-bin/zigar-lib-tests",
            .ok = true,
            .exit_code = 0,
            .tests = 122,
            .min_tests = 115,
            .tests_ok = true,
            .stdout_bytes = 100,
            .stderr_bytes = 0,
        },
        .{
            .name = "zigar-exe-tests",
            .path = "zig-out/test-bin/zigar-exe-tests",
            .ok = true,
            .exit_code = 0,
            .tests = 3,
            .min_tests = 3,
            .tests_ok = true,
            .stdout_bytes = 20,
            .stderr_bytes = 0,
        },
        .{
            .name = "zigar-tools-tests",
            .path = "zig-out/test-bin/zigar-tools-tests",
            .ok = true,
            .exit_code = 0,
            .tests = 14,
            .min_tests = 10,
            .tests_ok = true,
            .stdout_bytes = 40,
            .stderr_bytes = 0,
        },
    };
    const summary = try renderCoverageSummary(std.testing.allocator, std.testing.io, .{
        .ok = true,
        .zig_version = "0.16.0",
        .total_tests = 139,
        .min_total_tests = 135,
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
            },
        },
    });
    defer std.testing.allocator.free(summary);

    const parsed = try std.json.parseFromSlice(JsonValue, std.testing.allocator, summary, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("test_summary", valueAt(parsed.value, "kind").?.string);
    try std.testing.expectEqual(@as(usize, 3), valueAt(parsed.value, "tests").?.array.items.len);
    try std.testing.expectEqual(@as(i64, 135), valueAt(parsed.value, "min_total_tests").?.integer);
    try std.testing.expect(valueAt(parsed.value, "suite_tests_ok").?.bool);
    try std.testing.expectEqual(@as(i64, 115), valueAt(parsed.value, "tests.0.min_tests").?.integer);
    try std.testing.expectEqual(@as(i64, 3), valueAt(parsed.value, "tests.1.min_tests").?.integer);
    try std.testing.expect(valueAt(parsed.value, "tests.2.tests_ok").?.bool);
    try std.testing.expect(valueAt(parsed.value, "coverage.measured").?.bool);
    try std.testing.expectEqual(@as(i64, 8), valueAt(parsed.value, "coverage.covered_lines").?.integer);
}
