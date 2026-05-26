const std = @import("std");
const cobertura = @import("coverage_cobertura.zig");
const coverage_config = @import("coverage_config.zig");
const json_util = @import("json_util.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const JsonValue = std.json.Value;
const CoverageFileStats = cobertura.CoverageFileStats;
const CoverageStats = cobertura.CoverageStats;

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
    integration_binary: ?[]const u8 = null,
    min_tests: i64 = coverage_config.min_total_tests,
    no_build: bool = false,
    require_kcov: bool = false,
    allow_kcov_failure: bool = false,
    min_line_coverage: u32 = coverage_config.min_line_coverage_basis_points,
    min_src_line_coverage: u32 = coverage_config.min_src_line_coverage_basis_points,
    min_tools_line_coverage: u32 = coverage_config.min_tools_line_coverage_basis_points,
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

const KcovInput = struct {
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
    var aw_owned = true;
    defer if (aw_owned) aw.deinit();
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

test "renderCoverageSummary includes suite floors and coverage details" {
    const results = [_]TestResult{
        .{
            .name = "zigar-lib-tests",
            .path = "zig-out/test-bin/zigar-lib-tests",
            .ok = true,
            .exit_code = 0,
            .tests = 380,
            .min_tests = 350,
            .tests_ok = true,
            .stdout_bytes = 100,
            .stderr_bytes = 0,
        },
        .{
            .name = "zigar-exe-tests",
            .path = "zig-out/test-bin/zigar-exe-tests",
            .ok = true,
            .exit_code = 0,
            .tests = 121,
            .min_tests = 100,
            .tests_ok = true,
            .stdout_bytes = 20,
            .stderr_bytes = 0,
        },
        .{
            .name = "zigar-tools-tests",
            .path = "zig-out/test-bin/zigar-tools-tests",
            .ok = true,
            .exit_code = 0,
            .tests = 21,
            .min_tests = 18,
            .tests_ok = true,
            .stdout_bytes = 40,
            .stderr_bytes = 0,
        },
        .{
            .name = "zigar-no-count-tests",
            .path = "zig-out/test-bin/zigar-no-count-tests",
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
                        .path = "tools/coverage.zig",
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
