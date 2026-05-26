const std = @import("std");

const ports = @import("../../app/ports.zig");
const workspace_mod = @import("../workspace/workspace.zig");
const filesystem = @import("../workspace/filesystem.zig");

/// DocsScanner port for bounded release documentation reads and path scans.
pub const Scanner = struct {
    workspace: *workspace_mod.Workspace,
    io: std.Io,

    const Self = @This();

    /// Stores borrowed workspace and I/O references used by scan operations.
    pub fn init(workspace: *workspace_mod.Workspace, io: std.Io) Self {
        return .{
            .workspace = workspace,
            .io = io,
        };
    }

    /// Exposes this scanner through the DocsScanner vtable.
    pub fn port(self: *Self) ports.DocsScanner {
        return .{
            .ptr = self,
            .vtable = &.{
                .read_absolute = readAbsolute,
                .scan_absolute_zig_paths = scanAbsoluteZigPaths,
                .scan_workspace_paths = scanWorkspacePaths,
            },
        };
    }

    fn readAbsolute(ptr: *anyopaque, allocator: std.mem.Allocator, request: ports.DocsReadAbsoluteRequest) ports.PortError!ports.DocsReadResult {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const bytes = std.Io.Dir.cwd().readFileAlloc(self.io, request.path, allocator, .limited(request.max_bytes)) catch |err| return filesystem.mapPortError(err);
        return .{ .bytes = bytes, .owns_bytes = true };
    }

    fn scanAbsoluteZigPaths(
        ptr: *anyopaque,
        allocator: std.mem.Allocator,
        request: ports.DocsScanAbsoluteZigPathsRequest,
    ) ports.PortError!ports.DocsPathScanResult {
        const self: *Self = @ptrCast(@alignCast(ptr));
        var dir = std.Io.Dir.openDirAbsolute(self.io, request.root, .{ .iterate = true }) catch |err| return filesystem.mapPortError(err);
        defer dir.close(self.io);
        return scanPaths(self.io, allocator, &dir, .zig_only, request.max_files);
    }

    fn scanWorkspacePaths(
        ptr: *anyopaque,
        allocator: std.mem.Allocator,
        request: ports.DocsScanWorkspacePathsRequest,
    ) ports.PortError!ports.DocsPathScanResult {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const root = self.workspace.resolve(".") catch |err| return filesystem.mapPortError(err);
        defer self.workspace.allocator.free(root);
        var dir = std.Io.Dir.openDirAbsolute(self.io, root, .{ .iterate = true }) catch |err| return filesystem.mapPortError(err);
        defer dir.close(self.io);
        return scanPaths(self.io, allocator, &dir, .text_candidates, request.max_files);
    }
};

/// Selects which path extensions a docs scan includes.
const PathMode = enum { zig_only, text_candidates };

fn scanPaths(
    io: std.Io,
    allocator: std.mem.Allocator,
    dir: *std.Io.Dir,
    mode: PathMode,
    maybe_limit: ?usize,
) ports.PortError!ports.DocsPathScanResult {
    var walker = dir.walk(allocator) catch return error.OutOfMemory;
    defer walker.deinit();

    var paths: std.ArrayList(ports.DocsPath) = .empty;
    var paths_owned = true;
    defer if (paths_owned) {
        for (paths.items) |path| allocator.free(path.path);
        paths.deinit(allocator);
    };

    const limit = maybe_limit orelse std.math.maxInt(usize);
    var walk_errors: usize = 0;
    var truncated = false;
    while (true) {
        if (paths.items.len >= limit) {
            truncated = true;
            break;
        }
        const maybe_entry = walker.next(io) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                walk_errors += 1;
                break;
            },
        };
        const entry = maybe_entry orelse break;
        if (entry.kind != .file) continue;
        switch (mode) {
            .zig_only => if (!std.mem.endsWith(u8, entry.path, ".zig")) continue,
            .text_candidates => if (!std.mem.endsWith(u8, entry.path, ".zig") and !std.mem.endsWith(u8, entry.path, ".md")) continue,
        }
        const path = try allocator.dupe(u8, entry.path);
        var path_owned = true;
        defer if (path_owned) allocator.free(path);
        try paths.append(allocator, .{ .path = path });
        path_owned = false;
    }

    const owned_paths = try paths.toOwnedSlice(allocator);
    paths_owned = false;
    return .{
        .paths = owned_paths,
        .walk_errors = walk_errors,
        .truncated = truncated,
        .owns_memory = true,
    };
}

test "docs scanner cleans scanned paths on allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, scanDocsWithAllocator, .{});
}

fn scanDocsWithAllocator(allocator: std.mem.Allocator) !void {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "root/src");
    try tmp.dir.writeFile(io, .{ .sub_path = "root/src/a.zig", .data = "a" });
    try tmp.dir.writeFile(io, .{ .sub_path = "root/src/b.zig", .data = "b" });
    const base = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..], "root" });
    defer std.testing.allocator.free(base);
    const root = try std.Io.Dir.cwd().realPathFileAlloc(io, base, std.testing.allocator);
    defer std.testing.allocator.free(root);

    var dir = try std.Io.Dir.openDirAbsolute(io, root, .{ .iterate = true });
    defer dir.close(io);
    const paths = try scanPaths(io, allocator, &dir, .zig_only, null);
    defer paths.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), paths.paths.len);
}

test "docs scanner reports walker errors and stops scanning" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "root/blocked");
    try tmp.dir.writeFile(io, .{ .sub_path = "root/blocked/hidden.zig", .data = "hidden" });
    try tmp.dir.setFilePermissions(io, "root/blocked", @enumFromInt(0), .{});
    defer tmp.dir.setFilePermissions(io, "root/blocked", .default_dir, .{}) catch {};

    const base = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..], "root" });
    defer allocator.free(base);
    const root = try std.Io.Dir.cwd().realPathFileAlloc(io, base, allocator);
    defer allocator.free(root);

    var dir = try std.Io.Dir.openDirAbsolute(io, root, .{ .iterate = true });
    defer dir.close(io);
    const paths = try scanPaths(io, allocator, &dir, .zig_only, null);
    defer paths.deinit(allocator);
    try std.testing.expect(paths.walk_errors > 0);
}
