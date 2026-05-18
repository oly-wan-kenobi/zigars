const std = @import("std");

const Io = std.Io;
const Allocator = std.mem.Allocator;

pub fn artifactHygiene(allocator: Allocator, io: Io, args: []const []const u8) !void {
    if (args.len != 0) return error.InvalidArguments;
    const generated = [_][]const u8{ "zig-out", ".zig-cache", "zig-pkg", ".zigar-cache", "coverage", "dist" };
    var ok = true;
    for (generated) |path| {
        if (isGitTracked(allocator, io, path)) {
            try stderrPrint(io, "generated artifact path is tracked: {s}\n", .{path});
            ok = false;
        }
        if (pathExists(io, path) and !isGitIgnored(allocator, io, path)) {
            try stderrPrint(io, "generated artifact path exists but is not ignored: {s}\n", .{path});
            ok = false;
        }
    }
    ok = (try checkLineBudgets(allocator, io)) and ok;
    ok = (try checkForbiddenTokens(allocator, io)) and ok;
    ok = (try checkPureZigTrees(allocator, io)) and ok;
    if (!ok) return error.ArtifactHygieneFailed;
}

pub fn fakeZwanzig(io: Io, args: []const []const u8) !void {
    if (args.len > 0 and std.mem.eql(u8, args[0], "--help")) {
        try stdoutWrite(io, "fake zwanzig help\n");
        return;
    }
    var format: []const u8 = "json";
    var i: usize = 0;
    while (i + 1 < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--format")) {
            format = args[i + 1];
            break;
        }
    }
    if (std.mem.eql(u8, format, "sarif")) {
        try stdoutWrite(io, "{\"version\":\"2.1.0\",\"runs\":[{\"tool\":{\"driver\":{\"name\":\"fake-zwanzig\"}}}]}\n");
    } else {
        try stdoutWrite(io, "{\"diagnostics\":[]}\n");
    }
}

pub fn fakeZflame(io: Io) !void {
    try stdoutWrite(io, "<svg xmlns=\"http://www.w3.org/2000/svg\"><title>fake flamegraph</title></svg>\n");
}

pub fn fakeDiffFolded(io: Io) !void {
    try stdoutWrite(io, "main;delta 2\n");
}

fn isGitTracked(allocator: Allocator, io: Io, path: []const u8) bool {
    _ = allocator;
    var child = std.process.spawn(io, .{
        .argv = &.{ "git", "ls-files", "--error-unmatch", path },
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return false;
    const term = child.wait(io) catch return false;
    return switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
}

fn isGitIgnored(allocator: Allocator, io: Io, path: []const u8) bool {
    _ = allocator;
    var child = std.process.spawn(io, .{
        .argv = &.{ "git", "check-ignore", "-q", "--", path },
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return false;
    const term = child.wait(io) catch return false;
    return switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
}

fn pathExists(io: Io, path: []const u8) bool {
    var dir = Io.Dir.cwd().openDir(io, path, .{}) catch return false;
    dir.close(io);
    return true;
}

const LineBudget = struct {
    path: []const u8,
    max_lines: usize,
    reason: []const u8,
};

const ForbiddenToken = struct {
    path: []const u8,
    token: []const u8,
    reason: []const u8,
};

const line_budgets = [_]LineBudget{
    .{
        .path = "src/main.zig",
        .max_lines = 150,
        .reason = "main must stay a small startup/lifecycle entrypoint",
    },
    .{
        .path = "tools/zigar_tools.zig",
        .max_lines = 800,
        .reason = "tool dispatcher must delegate large release-check helpers to focused modules",
    },
};

const forbidden_tokens = [_]ForbiddenToken{
    .{
        .path = "src/main.zig",
        .token = "active_app",
        .reason = "MCP handlers must receive runtime through user_data, not globals",
    },
    .{
        .path = "src/main.zig",
        .token = "fn app(",
        .reason = "MCP handlers must receive runtime through user_data, not globals",
    },
    .{
        .path = "src/server.zig",
        .token = "active_app",
        .reason = "server handlers must not reintroduce global runtime state",
    },
};

const pure_zig_roots = [_][]const u8{
    ".github",
    "docs",
    "examples",
    "scripts",
    "src",
    "tests",
    "tools",
};

fn checkLineBudgets(allocator: Allocator, io: Io) !bool {
    var ok = true;
    for (line_budgets) |budget| {
        const bytes = readFileAlloc(allocator, io, budget.path, 4 * 1024 * 1024) catch |err| {
            try stderrPrint(io, "line-budget check could not read {s}: {s}\n", .{ budget.path, @errorName(err) });
            ok = false;
            continue;
        };
        defer allocator.free(bytes);
        const lines = lineCount(bytes);
        if (lines > budget.max_lines) {
            try stderrPrint(io, "line budget exceeded: {s} has {d} lines, max {d} ({s})\n", .{ budget.path, lines, budget.max_lines, budget.reason });
            ok = false;
        }
    }
    return ok;
}

fn checkForbiddenTokens(allocator: Allocator, io: Io) !bool {
    var ok = true;
    for (forbidden_tokens) |rule| {
        const bytes = readFileAlloc(allocator, io, rule.path, 8 * 1024 * 1024) catch |err| {
            try stderrPrint(io, "forbidden-token check could not read {s}: {s}\n", .{ rule.path, @errorName(err) });
            ok = false;
            continue;
        };
        defer allocator.free(bytes);
        if (std.mem.indexOf(u8, bytes, rule.token) != null) {
            try stderrPrint(io, "forbidden token in {s}: `{s}` ({s})\n", .{ rule.path, rule.token, rule.reason });
            ok = false;
        }
    }
    return ok;
}

fn checkPureZigTrees(allocator: Allocator, io: Io) !bool {
    var ok = true;
    for (pure_zig_roots) |root| {
        ok = (try checkNoExtensionInTree(allocator, io, root, ".py")) and ok;
    }
    return ok;
}

fn checkNoExtensionInTree(allocator: Allocator, io: Io, root: []const u8, extension: []const u8) !bool {
    var dir = Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return true,
        else => return err,
    };
    defer dir.close(io);
    var walker = try dir.walk(allocator);
    defer walker.deinit();

    var ok = true;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, extension)) continue;
        try stderrPrint(io, "pure Zig hygiene rejected {s}/{s}: Python files do not belong in project-owned source, tools, tests, scripts, examples, docs, or CI\n", .{ root, entry.path });
        ok = false;
    }
    return ok;
}

fn readFileAlloc(allocator: Allocator, io: Io, path: []const u8, limit: usize) ![]u8 {
    return Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(limit));
}

fn lineCount(bytes: []const u8) usize {
    if (bytes.len == 0) return 0;
    var count: usize = 0;
    for (bytes) |byte| {
        if (byte == '\n') count += 1;
    }
    if (bytes[bytes.len - 1] != '\n') count += 1;
    return count;
}

fn stdoutWrite(io: Io, bytes: []const u8) !void {
    try Io.File.stdout().writeStreamingAll(io, bytes);
}

fn stderrPrint(io: Io, comptime fmt: []const u8, args: anytype) !void {
    var buffer: [4096]u8 = undefined;
    var writer = Io.File.stderr().writer(io, &buffer);
    try writer.interface.print(fmt, args);
    try writer.interface.flush();
}

test "lineCount handles empty trailing and unterminated text" {
    try std.testing.expectEqual(@as(usize, 0), lineCount(""));
    try std.testing.expectEqual(@as(usize, 1), lineCount("one"));
    try std.testing.expectEqual(@as(usize, 1), lineCount("one\n"));
    try std.testing.expectEqual(@as(usize, 2), lineCount("one\ntwo"));
    try std.testing.expectEqual(@as(usize, 2), lineCount("one\ntwo\n"));
}
