//! Tests for filesystem.Store: verifies that reads, writes, deletes, and
//! directory scans stay inside the workspace sandbox and that symlink escapes
//! are rejected at the port boundary.
const std = @import("std");
const filesystem = @import("filesystem.zig");
const workspace_mod = @import("workspace.zig");

const Store = filesystem.Store;

/// Scans a directory using an explicit test allocator.
fn scanDirectoryWithAllocator(allocator: std.mem.Allocator) !void {
    // Keep this logic centralized so callers observe one consistent behavior path.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;

    try tmp.dir.createDirPath(io, "root/src");
    try tmp.dir.writeFile(io, .{ .sub_path = "root/src/a.zig", .data = "a" });
    try tmp.dir.writeFile(io, .{ .sub_path = "root/src/b.zig", .data = "b" });
    const base = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..], "root" });
    defer std.testing.allocator.free(base);
    const root = try std.Io.Dir.cwd().realPathFileAlloc(io, base, std.testing.allocator);
    defer std.testing.allocator.free(root);

    var workspace = try workspace_mod.Workspace.init(std.testing.allocator, io, root, null);
    defer workspace.deinit();
    var store = Store.init(&workspace, io, .{});
    const scan = try store.port().scanDirectory(allocator, .{ .path = "src", .suffix = ".zig", .for_output = false });
    defer scan.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), scan.entries.len);
}

test "filesystem workspace store resolves reads writes and deletes inside root" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    try tmp.dir.createDirPath(io, "root/src");
    try tmp.dir.writeFile(io, .{ .sub_path = "root/src/main.zig", .data = "pub const ok = true;\n" });
    const base = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..], "root" });
    defer allocator.free(base);
    const root = try std.Io.Dir.cwd().realPathFileAlloc(io, base, allocator);
    defer allocator.free(root);

    var workspace = try workspace_mod.Workspace.init(allocator, io, root, null);
    defer workspace.deinit();
    var store = Store.init(&workspace, io, .{});

    const resolved = try store.port().resolve(allocator, .{ .path = "src/main.zig" });
    defer resolved.deinit(allocator);
    try std.testing.expect(workspace_mod.isInside(workspace.root, resolved.path));

    const read_result = try store.port().read(allocator, .{ .path = "src/main.zig", .max_bytes = 1024 });
    defer read_result.deinit(allocator);
    try std.testing.expectEqualStrings("pub const ok = true;\n", read_result.bytes);

    const write_result = try store.port().write(.{ .path = "zig-out/report.txt", .bytes = "ok\n" });
    try std.testing.expectEqual(@as(usize, 3), write_result.bytes_written);

    const delete_result = try store.port().delete(.{ .path = "zig-out/report.txt", .missing_ok = false });
    try std.testing.expect(delete_result.deleted);
    const missing_delete = try store.port().delete(.{ .path = "zig-out/report.txt", .missing_ok = true });
    try std.testing.expect(!missing_delete.deleted);
    try std.testing.expectError(error.Unavailable, store.port().delete(.{ .path = "src", .missing_ok = false }));

    try tmp.dir.writeFile(io, .{ .sub_path = "root/src/skip.txt", .data = "skip" });
    const scan = try store.port().scanDirectory(allocator, .{ .path = "src", .suffix = ".zig", .for_output = false });
    defer scan.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), scan.entries.len);
    try std.testing.expectEqualStrings("main.zig", scan.entries[0].path);
}

test "filesystem workspace store preserves output parent symlink sandboxing" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "root");
    try tmp.dir.createDirPath(io, "outside");
    const base_rel = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer allocator.free(base_rel);
    const base = try std.Io.Dir.cwd().realPathFileAlloc(io, base_rel, allocator);
    defer allocator.free(base);
    const root = try std.fs.path.join(allocator, &.{ base[0..], "root" });
    defer allocator.free(root);
    const outside = try std.fs.path.join(allocator, &.{ base[0..], "outside" });
    defer allocator.free(outside);
    const link_dir = try std.fs.path.join(allocator, &.{ root, "outlink" });
    defer allocator.free(link_dir);
    try std.Io.Dir.symLinkAbsolute(io, outside, link_dir, .{ .is_directory = true });

    var workspace = try workspace_mod.Workspace.init(allocator, io, root, null);
    defer workspace.deinit();
    var store = Store.init(&workspace, io, .{ .read_resolution = .output });

    try std.testing.expectError(error.PathOutsideWorkspace, store.port().resolve(allocator, .{
        .path = "outlink/new/generated.zig",
        .for_output = true,
    }));
    try std.testing.expectError(error.PathOutsideWorkspace, store.port().read(allocator, .{
        .path = "outlink/new/generated.zig",
        .max_bytes = 1024,
    }));
    const exists = try store.port().exists(allocator, .{
        .path = "outlink/new/generated.zig",
        .for_output = true,
    });
    try std.testing.expect(!exists.exists);
}

test "filesystem workspace store scan cleans paths on allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, scanDirectoryWithAllocator, .{});
}
