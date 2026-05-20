const std = @import("std");

const Io = std.Io;
const Allocator = std.mem.Allocator;

pub fn checkPublicReleaseBlockers(allocator: Allocator, io: Io) !bool {
    return checkTasks(allocator, io, .public_release_blockers);
}

pub fn checkReadyTaskScope(allocator: Allocator, io: Io) !bool {
    return checkTasks(allocator, io, .ready_task_scope);
}

const TaskCheck = enum { public_release_blockers, ready_task_scope };

fn checkTasks(allocator: Allocator, io: Io, check: TaskCheck) !bool {
    var dir = Io.Dir.cwd().openDir(io, "tasks", .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return true,
        else => return err,
    };
    defer dir.close(io);

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    var ok = true;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".md")) continue;
        const path = try std.fmt.allocPrint(allocator, "tasks/{s}", .{entry.path});
        defer allocator.free(path);
        const bytes = Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024 * 1024)) catch |err| {
            try stderrPrint(io, "task-status check could not read {s}: {s}\n", .{ path, @errorName(err) });
            ok = false;
            continue;
        };
        defer allocator.free(bytes);
        const status = frontmatterValue(bytes, "status") orelse {
            try stderrPrint(io, "task-status check missing status in task frontmatter: {s}\n", .{path});
            ok = false;
            continue;
        };
        switch (check) {
            .public_release_blockers => {
                if (!isReleaseBlocker(bytes)) continue;
                if (!isClosedStatus(status)) {
                    try stderrPrint(io, "task-status check found open public-release blocker: {s} has status `{s}`\n", .{ path, status });
                    ok = false;
                }
            },
            .ready_task_scope => {
                if (!std.mem.eql(u8, status, "ready")) continue;
                if (!isExplicitFutureReadyTask(bytes)) {
                    try stderrPrint(io, "task-status check found ambiguous ready task: {s} must declare `blocks_public_release: false` or `public_release_scope: future`\n", .{path});
                    ok = false;
                }
            },
        }
    }
    return ok;
}

fn isReleaseBlocker(bytes: []const u8) bool {
    const value = frontmatterValue(bytes, "blocks_public_release") orelse return false;
    return std.mem.eql(u8, value, "true");
}

fn isClosedStatus(status: []const u8) bool {
    return std.mem.eql(u8, status, "done") or
        std.mem.eql(u8, status, "superseded") or
        std.mem.eql(u8, status, "deferred");
}

fn isExplicitFutureReadyTask(bytes: []const u8) bool {
    if (frontmatterValue(bytes, "blocks_public_release")) |value| {
        if (std.mem.eql(u8, value, "false")) return true;
    }
    if (frontmatterValue(bytes, "public_release_scope")) |value| {
        if (std.mem.eql(u8, value, "future")) return true;
    }
    return false;
}

fn frontmatterValue(bytes: []const u8, key: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, bytes, "---\n")) return null;
    const body = bytes[4..];
    const end = std.mem.indexOf(u8, body, "\n---") orelse return null;
    var lines = std.mem.splitScalar(u8, body[0..end], '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len <= key.len + 1) continue;
        if (!std.mem.startsWith(u8, trimmed, key)) continue;
        if (trimmed[key.len] != ':') continue;
        return std.mem.trim(u8, trimmed[key.len + 1 ..], " \t\r");
    }
    return null;
}

fn stderrPrint(io: Io, comptime fmt: []const u8, args: anytype) !void {
    var buffer: [4096]u8 = undefined;
    var writer = Io.File.stderr().writer(io, &buffer);
    try writer.interface.print(fmt, args);
    try writer.interface.flush();
}

test "frontmatterValue reads simple keys" {
    const bytes =
        \\---
        \\status: done
        \\blocks_public_release: true
        \\---
        \\
        \\# Task
    ;
    try std.testing.expectEqualStrings("done", frontmatterValue(bytes, "status").?);
    try std.testing.expect(isReleaseBlocker(bytes));
    try std.testing.expect(isClosedStatus("superseded"));
    try std.testing.expect(!isClosedStatus("ready"));
    try std.testing.expect(!isExplicitFutureReadyTask(bytes));
    const future = "---\nstatus: ready\nblocks_public_release: false\n---\n";
    try std.testing.expect(isExplicitFutureReadyTask(future));
}
