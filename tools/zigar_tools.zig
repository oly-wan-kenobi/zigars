const std = @import("std");
const cli_io = @import("cli_io.zig");
const coverage = @import("coverage.zig");
const dist = @import("dist.zig");
const http_smoke = @import("http_smoke.zig");
const http_diagnostics_smoke = @import("http_diagnostics_smoke.zig");
const json_query = @import("json_query.zig");
const json_util = @import("json_util.zig");
const release_checks = @import("release_checks.zig");
const release_targets = @import("release_targets.zig");
const stdio_fixtures = @import("stdio_fixtures.zig");
const tool_index = @import("tool_index.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const executableName = cli_io.executableName;
const failUsage = cli_io.failUsage;
const parseJsonFile = cli_io.parseJsonFile;
const reportInvalidArguments = cli_io.reportInvalidArguments;
const stderrPrint = cli_io.stderrPrint;

test {
    _ = coverage;
    _ = cli_io;
    _ = dist;
    _ = http_smoke;
    _ = http_diagnostics_smoke;
    _ = json_query;
    _ = json_util;
    _ = release_checks;
    _ = release_targets;
    _ = stdio_fixtures;
    _ = tool_index;
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    var args_arena_state = std.heap.ArenaAllocator.init(allocator);
    defer args_arena_state.deinit();
    const args_arena = args_arena_state.allocator();
    const args = try init.minimal.args.toSlice(args_arena);

    if (args.len > 0) {
        const invoked = executableName(args[0]);
        if (std.mem.startsWith(u8, invoked, "fake-zwanzig")) return release_checks.fakeZwanzig(io, args[1..]);
        if (std.mem.startsWith(u8, invoked, "fake-zlint")) return release_checks.fakeZlint(io, args[1..]);
        if (std.mem.startsWith(u8, invoked, "fake-zflame")) return release_checks.fakeZflame(io, args[1..]);
        if (std.mem.startsWith(u8, invoked, "fake-diff-folded")) return release_checks.fakeDiffFolded(io, args[1..]);
    }
    if (args.len > 1) {
        if (std.mem.eql(u8, args[1], "fake-zwanzig")) return release_checks.fakeZwanzig(io, args[2..]);
        if (std.mem.eql(u8, args[1], "fake-zlint")) return release_checks.fakeZlint(io, args[2..]);
        if (std.mem.eql(u8, args[1], "fake-zflame")) return release_checks.fakeZflame(io, args[2..]);
        if (std.mem.eql(u8, args[1], "fake-diff-folded")) return release_checks.fakeDiffFolded(io, args[2..]);
    }

    if (args.len < 2) {
        try usage(io);
        return failUsage(io, "zigar-tools", "", "missing command", .{});
    }

    const cmd = args[1];
    if (std.mem.eql(u8, cmd, "version")) {
        try dist.printVersion(io);
    } else if (std.mem.eql(u8, cmd, "generate-tool-index")) {
        tool_index.generate(allocator, io, args[2..]) catch |err| {
            return reportInvalidArguments(io, cmd, "generate-tool-index [--check]", err);
        };
    } else if (std.mem.eql(u8, cmd, "check-json")) {
        try checkJson(allocator, io, args[2..]);
    } else if (std.mem.eql(u8, cmd, "http-smoke")) {
        try http_smoke.run(allocator, io, args[2..]);
    } else if (std.mem.eql(u8, cmd, "stdio-fixtures")) {
        try stdio_fixtures.run(allocator, io, args[0], args[2..]);
    } else if (std.mem.eql(u8, cmd, "coverage")) {
        coverage.run(allocator, io, args[2..]) catch |err| {
            return reportInvalidArguments(io, cmd, "coverage [--out-dir <path>] [--zig <path>] [--min-tests <count>] [--no-build] [--require-kcov] [--allow-kcov-failure]", err);
        };
    } else if (std.mem.eql(u8, cmd, "dist")) {
        dist.buildArchives(allocator, io, args[2..]) catch |err| {
            return reportInvalidArguments(io, cmd, "dist --package <name> --exe <name> --binary <path>...", err);
        };
    } else if (std.mem.eql(u8, cmd, "dist-smoke")) {
        dist.smoke(allocator, io, args[2..]) catch |err| {
            return reportInvalidArguments(io, cmd, "dist-smoke [--assets-dir <path>] [--version <version>]", err);
        };
    } else if (std.mem.eql(u8, cmd, "artifact-hygiene")) {
        release_checks.artifactHygiene(allocator, io, args[2..]) catch |err| {
            return reportInvalidArguments(io, cmd, "artifact-hygiene", err);
        };
    } else {
        try usage(io);
        return failUsage(io, "zigar-tools", "", "unknown command `{s}`", .{cmd});
    }
}

fn usage(io: Io) !void {
    try stderrPrint(io,
        \\usage: zigar-tools <command> [options]
        \\
        \\commands:
        \\  version
        \\  generate-tool-index [--check]
        \\  check-json <path>...
        \\  http-smoke [--binary <path>] [--workspace <path>] [--expect <path>]
        \\  stdio-fixtures [--binary <path>] [--zig-path <path>]
        \\  coverage [--out-dir <path>] [--zig <path>] [--min-tests <count>] [--no-build] [--require-kcov] [--allow-kcov-failure]
        \\  dist --package <name> --exe <name> --binary <path>...
        \\  dist-smoke [--assets-dir <path>] [--version <version>]
        \\  artifact-hygiene
        \\
    , .{});
}

fn checkJson(allocator: Allocator, io: Io, args: []const []const u8) !void {
    if (args.len == 0) return failUsage(io, "check-json", "check-json <path>...", "expected at least one JSON path", .{});
    for (args) |path| {
        const parsed = try parseJsonFile(allocator, io, path);
        parsed.deinit();
    }
}

test "json util escapes JSON control characters" {
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try json_util.writeString(&out.writer, "a\"b\\c\n\t\x1b");
    try std.testing.expectEqualStrings("\"a\\\"b\\\\c\\n\\t\\u001b\"", out.written());
}
