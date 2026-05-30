//! Pins the Scanner port contract: readAbsolute returns file bytes,
//! scanAbsoluteZigPaths filters to .zig only, scanWorkspacePaths includes .md,
//! and max_files truncation sets the truncated flag without returning an error.
const std = @import("std");
const docs_scanner = @import("docs_scanner.zig");
const workspace_mod = @import("../workspace/workspace.zig");

const Scanner = docs_scanner.Scanner;

test "docs scanner reads absolute files and scans zig and docs paths" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "root/src");
    try tmp.dir.writeFile(io, .{ .sub_path = "root/src/main.zig", .data = "pub fn main() void {}\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "root/README.md", .data = "# docs\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "root/notes.txt", .data = "skip\n" });

    const base = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..], "root" });
    defer allocator.free(base);
    const root = try std.Io.Dir.cwd().realPathFileAlloc(io, base, allocator);
    defer allocator.free(root);
    const main_path = try std.fs.path.join(allocator, &.{ root, "src", "main.zig" });
    defer allocator.free(main_path);

    var workspace = try workspace_mod.Workspace.init(allocator, io, root, null);
    defer workspace.deinit();
    var scanner = Scanner.init(&workspace, io);
    const port = scanner.port();

    const read = try port.readAbsolute(allocator, .{ .path = main_path, .max_bytes = 1024 });
    defer read.deinit(allocator);
    try std.testing.expectEqualStrings("pub fn main() void {}\n", read.bytes);

    const zig_paths = try port.scanAbsoluteZigPaths(allocator, .{ .root = root });
    defer zig_paths.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), zig_paths.paths.len);
    try std.testing.expectEqualStrings("src/main.zig", zig_paths.paths[0].path);

    const docs_paths = try port.scanWorkspacePaths(allocator, .{});
    defer docs_paths.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), docs_paths.paths.len);

    const truncated = try port.scanAbsoluteZigPaths(allocator, .{ .root = root, .max_files = 0 });
    defer truncated.deinit(allocator);
    try std.testing.expect(truncated.truncated);
    try std.testing.expectEqual(@as(usize, 0), truncated.paths.len);
}
