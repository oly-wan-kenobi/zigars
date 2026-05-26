const std = @import("std");
const cobertura = @import("coverage_cobertura.zig");
const coverage_config = @import("coverage_config.zig");
const coverage_summary = @import("coverage_summary.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const CoverageStats = cobertura.CoverageStats;
const KcovInput = coverage_summary.KcovInput;
const TestResult = coverage_summary.TestResult;
const renderCoverageSummary = coverage_summary.renderCoverageSummary;

const percent_scale: u32 = 100;

// Runs release coverage evidence generation. Cobertura parsing and summary
// rendering live in sibling modules to keep this file focused on orchestration.

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
    integration_binary: ?[]const u8 = null,
    min_tests: i64 = coverage_config.min_total_tests,
    no_build: bool = false,
    require_kcov: bool = false,
    allow_kcov_failure: bool = false,
    min_line_coverage: u32 = coverage_config.min_line_coverage_basis_points,
    min_src_line_coverage: u32 = coverage_config.min_src_line_coverage_basis_points,
    min_tools_line_coverage: u32 = coverage_config.min_tools_line_coverage_basis_points,
};

const KcovCommand = struct {
    name: []const u8,
    argv: []const []const u8,

    fn init(allocator: Allocator, name: []const u8, argv: []const []const u8) !KcovCommand {
        var owned_argv = try allocator.alloc([]const u8, argv.len);
        errdefer allocator.free(owned_argv);
        var initialized: usize = 0;
        errdefer {
            for (owned_argv[0..initialized]) |arg| allocator.free(arg);
        }
        for (argv) |arg| {
            owned_argv[initialized] = try allocator.dupe(u8, arg);
            initialized += 1;
        }
        return .{
            .name = try allocator.dupe(u8, name),
            .argv = owned_argv,
        };
    }

    fn deinit(self: KcovCommand, allocator: Allocator) void {
        allocator.free(self.name);
        for (self.argv) |arg| allocator.free(arg);
        allocator.free(self.argv);
    }
};

/// Runs test binaries, optional kcov collection, and writes coverage summary JSON.
pub fn run(allocator: Allocator, io: Io, self_path: []const u8, args: []const []const u8) !void {
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
        } else if (std.mem.eql(u8, args[i], "--integration-binary")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            options.integration_binary = args[i];
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
    var kcov_commands: std.ArrayList(KcovCommand) = .empty;
    defer {
        for (kcov_commands.items) |command| command.deinit(allocator);
        kcov_commands.deinit(allocator);
    }
    for (coverage_config.test_binaries) |binary| {
        const path = binary.path();
        try test_results.append(allocator, try runTestBinary(allocator, io, path, binary));
        try kcov_commands.append(allocator, try KcovCommand.init(allocator, binary.name, &.{path}));
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
    defer if (coverage_stats) |*stats| stats.deinit(allocator);
    if (kcov_path) |kcov| {
        kcov_ran = true;
        coverage_stats = runKcov(allocator, io, kcov, options.out_dir, kcov_commands.items, self_path, options.integration_binary, &kcov_error) catch |err| blk: {
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
    const coverage_ok = coverageMeetsFloors(coverage_stats, options);
    if (!coverage_ok) {
        ok = false;
        if (kcov_error == null) kcov_error = try coverageFailureMessage(allocator, coverage_stats, options);
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
            .min_line_coverage = options.min_line_coverage,
            .min_src_line_coverage = options.min_src_line_coverage,
            .min_tools_line_coverage = options.min_tools_line_coverage,
            .floors_ok = coverage_ok,
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

fn runKcov(
    allocator: Allocator,
    io: Io,
    kcov: []const u8,
    out_dir: []const u8,
    commands: []const KcovCommand,
    self_path: []const u8,
    integration_binary: ?[]const u8,
    error_message: *?[]const u8,
) !CoverageStats {
    const kcov_root = try std.fmt.allocPrint(allocator, "{s}/kcov", .{out_dir});
    defer allocator.free(kcov_root);
    if (dirExists(io, kcov_root)) try Io.Dir.cwd().deleteTree(io, kcov_root);
    try Io.Dir.cwd().createDirPath(io, kcov_root);

    var result_dirs: std.ArrayList([]const u8) = .empty;
    defer {
        for (result_dirs.items) |dir| allocator.free(dir);
        result_dirs.deinit(allocator);
    }

    for (commands) |command| {
        const target_dir = try std.fmt.allocPrint(allocator, "{s}/kcov/{s}", .{ out_dir, command.name });
        errdefer allocator.free(target_dir);
        const include_arg = "--include-path=" ++ coverage_config.kcov_include_path;
        const exclude_arg = "--exclude-path=" ++ coverage_config.kcov_exclude_path;
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(allocator);
        try argv.appendSlice(allocator, &.{ kcov, "--clean", include_arg, exclude_arg, coverage_config.kcov_exclude_line_arg, coverage_config.kcov_exclude_region_arg, target_dir });
        try argv.appendSlice(allocator, command.argv);
        const result = try std.process.run(allocator, io, .{
            .argv = argv.items,
        });
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
        if (!termOk(result.term)) {
            try recordCommandFailure(allocator, error_message, command.name, result.stdout, result.stderr);
            return error.KcovFailed;
        }
        try result_dirs.append(allocator, target_dir);
    }
    if (integration_binary) |binary| {
        try runIntegrationKcov(allocator, io, kcov, out_dir, self_path, binary, &result_dirs, error_message);
    }

    const report_dir = if (result_dirs.items.len == 1) result_dirs.items[0] else blk: {
        const merged_dir = try std.fmt.allocPrint(allocator, "{s}/kcov/merged", .{out_dir});
        errdefer allocator.free(merged_dir);
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(allocator);
        try argv.appendSlice(allocator, &.{ kcov, "--merge", coverage_config.kcov_exclude_line_arg, coverage_config.kcov_exclude_region_arg, merged_dir });
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
    var stats = try cobertura.parseCobertura(allocator, xml);
    errdefer stats.deinit(allocator);
    try cobertura.addMissingTrackedFiles(allocator, io, &stats);
    if (stats.total_lines == 0) return error.EmptyCoverageReport;
    return stats;
}

fn runIntegrationKcov(
    allocator: Allocator,
    io: Io,
    kcov: []const u8,
    out_dir: []const u8,
    self_path: []const u8,
    binary: []const u8,
    result_dirs: *std.ArrayList([]const u8),
    error_message: *?[]const u8,
) !void {
    const http_dir = try std.fmt.allocPrint(allocator, "{s}/kcov/http-server", .{out_dir});
    errdefer allocator.free(http_dir);
    const http = try std.process.run(allocator, io, .{ .argv = &.{
        self_path,
        "http-smoke",
        "--binary",
        binary,
        "--workspace",
        ".",
        "--server-kcov-path",
        kcov,
        "--server-kcov-dir",
        http_dir,
    } });
    defer allocator.free(http.stdout);
    defer allocator.free(http.stderr);
    if (!termOk(http.term)) {
        try recordCommandFailure(allocator, error_message, "http-smoke server coverage", http.stdout, http.stderr);
        return error.KcovFailed;
    }
    try result_dirs.append(allocator, http_dir);

    const stdio_dir = try std.fmt.allocPrint(allocator, "{s}/kcov/stdio-server", .{out_dir});
    errdefer allocator.free(stdio_dir);
    const stdio = try std.process.run(allocator, io, .{ .argv = &.{
        self_path,
        "stdio-fixtures",
        "--binary",
        binary,
        "--server-kcov-path",
        kcov,
        "--server-kcov-dir",
        stdio_dir,
    } });
    defer allocator.free(stdio.stdout);
    defer allocator.free(stdio.stderr);
    if (!termOk(stdio.term)) {
        try recordCommandFailure(allocator, error_message, "stdio-fixtures server coverage", stdio.stdout, stdio.stderr);
        return error.KcovFailed;
    }
    try result_dirs.append(allocator, stdio_dir);
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

fn coverageMeetsFloors(stats: ?CoverageStats, options: CoverageOptions) bool {
    const measured = stats orelse return !options.require_kcov;
    return meetsFloor(measured.lineRateBasisPoints(), options.min_line_coverage) and
        meetsFloor(measured.srcLineRateBasisPoints(), options.min_src_line_coverage) and
        meetsFloor(measured.toolsLineRateBasisPoints(), options.min_tools_line_coverage) and
        measured.uncoveredLineCount() == 0 and
        measured.missingFileCount() == 0;
}

fn meetsFloor(actual: ?u32, minimum: u32) bool {
    return if (actual) |value| value >= minimum else false;
}

fn coverageFailureMessage(allocator: Allocator, stats: ?CoverageStats, options: CoverageOptions) ![]u8 {
    const measured = stats orelse return coverageFloorMessage(allocator, options);
    return std.fmt.allocPrint(
        allocator,
        "line coverage did not meet configured floors: total >= {d}.{d:0>2}%, src >= {d}.{d:0>2}%, tools >= {d}.{d:0>2}%; uncovered_lines={d}, missing_files={d}",
        .{
            options.min_line_coverage / percent_scale,
            options.min_line_coverage % percent_scale,
            options.min_src_line_coverage / percent_scale,
            options.min_src_line_coverage % percent_scale,
            options.min_tools_line_coverage / percent_scale,
            options.min_tools_line_coverage % percent_scale,
            measured.uncoveredLineCount(),
            measured.missingFileCount(),
        },
    );
}

fn coverageFloorMessage(allocator: Allocator, options: CoverageOptions) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "line coverage did not meet configured floors: total >= {d}.{d:0>2}%, src >= {d}.{d:0>2}%, tools >= {d}.{d:0>2}%",
        .{
            options.min_line_coverage / percent_scale,
            options.min_line_coverage % percent_scale,
            options.min_src_line_coverage / percent_scale,
            options.min_src_line_coverage % percent_scale,
            options.min_tools_line_coverage / percent_scale,
            options.min_tools_line_coverage % percent_scale,
        },
    );
}

fn dirExists(io: Io, path: []const u8) bool {
    var dir = Io.Dir.cwd().openDir(io, path, .{}) catch return false;
    dir.close(io);
    return true;
}

test "parseTestCount extracts Zig test runner totals" {
    try std.testing.expectEqual(@as(?i64, 42), parseTestCount("All 42 tests passed.\n"));
    try std.testing.expectEqual(@as(?i64, 7), parseTestCount("noise\nAll 7 tests passed.\n"));
    try std.testing.expectEqual(@as(?i64, null), parseTestCount("1/1 test.foo...OK\n"));
    try std.testing.expectEqual(@as(?i64, null), parseTestCount("All tests passed.\n"));
}

test "coverage floors require measured kcov data when configured" {
    try std.testing.expect(!coverageMeetsFloors(null, .{ .require_kcov = true }));
    try std.testing.expect(coverageMeetsFloors(null, .{}));
    try std.testing.expect(!coverageMeetsFloors(.{
        .covered_lines = 8,
        .total_lines = 10,
        .src_covered_lines = 8,
        .src_total_lines = 10,
        .tools_covered_lines = 8,
        .tools_total_lines = 10,
    }, .{}));
    try std.testing.expect(!coverageMeetsFloors(.{
        .covered_lines = 10,
        .total_lines = 10,
        .src_covered_lines = 5,
        .src_total_lines = 5,
        .tools_covered_lines = 5,
        .tools_total_lines = 5,
        .missing_files = @constCast(&[_][]const u8{"src/missing.zig"}),
    }, .{}));
}
