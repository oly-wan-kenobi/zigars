//! Tests for Scanner: pins that .zig-cache paths are excluded, that partial
//! results are cleaned up on allocation failure, and that the result count
//! matches only non-skipped .zig source files.
const std = @import("std");
const scanner_mod = @import("scanner.zig");
const workspace_mod = @import("workspace.zig");

const Scanner = scanner_mod.Scanner;

test "workspace scanner enumerates zig files and skips cache paths" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    try tmp.dir.createDirPath(io, "root/src");
    try tmp.dir.createDirPath(io, "root/.zig-cache");
    try tmp.dir.writeFile(io, .{ .sub_path = "root/src/main.zig", .data = "pub fn main() void {}\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "root/src/lib.zig", .data = "pub const x = 1;\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "root/.zig-cache/generated.zig", .data = "pub const ignored = true;\n" });

    const base = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..], "root" });
    defer allocator.free(base);
    const root = try std.Io.Dir.cwd().realPathFileAlloc(io, base, allocator);
    defer allocator.free(root);

    var workspace = try workspace_mod.Workspace.init(allocator, io, root, null);
    defer workspace.deinit();
    var scanner = Scanner.init(&workspace, io);

    const result = try scanner.port().scanZigFiles(allocator, .{});
    defer result.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), result.files.len);
}

test "workspace scanner cleans partial results on allocation failure" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    try tmp.dir.createDirPath(io, "root/src");
    try tmp.dir.writeFile(io, .{ .sub_path = "root/src/main.zig", .data = "pub fn main() void {}\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "root/src/lib.zig", .data = "pub const x = 1;\n" });

    const base = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..], "root" });
    defer allocator.free(base);
    const root = try std.Io.Dir.cwd().realPathFileAlloc(io, base, allocator);
    defer allocator.free(root);

    var workspace = try workspace_mod.Workspace.init(allocator, io, root, null);
    defer workspace.deinit();
    var scanner = Scanner.init(&workspace, io);

    var saw_oom = false;
    for (0..32) |fail_index| {
        var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = fail_index });
        const result = scanner.port().scanZigFiles(failing.allocator(), .{}) catch |err| {
            if (err == error.OutOfMemory) saw_oom = true;
            continue;
        };
        result.deinit(failing.allocator());
    }
    try std.testing.expect(saw_oom);
}
