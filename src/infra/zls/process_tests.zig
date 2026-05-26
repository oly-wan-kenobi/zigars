const std = @import("std");
const process_mod = @import("process.zig");

const ZlsProcess = process_mod.ZlsProcess;

/// Builds a bounded in-memory I/O fixture for tests.
fn testIo() std.Io {
    var threaded: std.Io.Threaded = .init(std.heap.smp_allocator, .{});
    return threaded.io();
}

test "ZlsProcess init state" {
    const alloc = std.testing.allocator;
    const io = testIo();
    var proc = ZlsProcess.init(alloc, io, "/workspace", "/usr/bin/zls");
    defer proc.deinit();
    try std.testing.expect(!proc.isAlive());
    try std.testing.expect(proc.getStdin() == null);
    try std.testing.expect(proc.getStdout() == null);
    try std.testing.expect(proc.getStderr() == null);
    try std.testing.expectEqualStrings("/workspace", proc.workspace_path);
    try std.testing.expectEqual(@as(u32, 0), proc.restart_count);
}

test "ZlsProcess detachPipes on null child" {
    const alloc = std.testing.allocator;
    const io = testIo();
    var proc = ZlsProcess.init(alloc, io, "/workspace", "/usr/bin/zls");
    proc.detachPipes(); // should not crash
    try std.testing.expect(!proc.isAlive());
}

test "ZlsProcess kill on null child" {
    const alloc = std.testing.allocator;
    const io = testIo();
    var proc = ZlsProcess.init(alloc, io, "/workspace", "/usr/bin/zls");
    proc.kill(); // should not crash
    try std.testing.expect(!proc.isAlive());
}

test "ZlsProcess max restart count logic" {
    const alloc = std.testing.allocator;
    const io = testIo();
    var proc = ZlsProcess.init(alloc, io, "/workspace", "/nonexistent-zls-binary");
    defer proc.deinit();
    proc.max_restarts = 3;

    // Simulate restart count reaching max (without actually spawning)
    proc.restart_count = 3;

    // Should return false (max exceeded) without attempting spawn
    const can_restart = proc.restart() catch false;
    try std.testing.expect(!can_restart);
    try std.testing.expectEqual(@as(u32, 3), proc.restart_count);
}

test "ZlsProcess restart records failed spawn attempts" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var proc = ZlsProcess.init(alloc, io, ".", "/nonexistent-zls-binary");
    defer proc.deinit();
    proc.max_restarts = 1;

    const can_restart = try proc.restart();
    try std.testing.expect(!can_restart);
    try std.testing.expectEqual(@as(u32, 1), proc.restart_count);
}

test "ZlsProcess restart succeeds for a spawnable process" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;

    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var proc = ZlsProcess.init(alloc, io, ".", "/bin/sh");
    defer proc.deinit();
    proc.max_restarts = 1;

    const can_restart = try proc.restart();
    try std.testing.expect(can_restart);
    try std.testing.expect(proc.isAlive());
    try std.testing.expectEqual(@as(u32, 1), proc.restart_count);
}
