const std = @import("std");

const ports = @import("../../app/ports.zig");
const workspace_mod = @import("../workspace/workspace.zig");
const filesystem = @import("../workspace/filesystem.zig");

pub const Scanner = struct {
    workspace: *workspace_mod.Workspace,
    io: std.Io,

    const Self = @This();

    pub fn init(workspace: *workspace_mod.Workspace, io: std.Io) Self {
        return .{
            .workspace = workspace,
            .io = io,
        };
    }

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
    errdefer {
        for (paths.items) |path| allocator.free(path.path);
        paths.deinit(allocator);
    }

    const limit = maybe_limit orelse std.math.maxInt(usize);
    var walk_errors: usize = 0;
    var truncated = false;
    while (true) {
        if (paths.items.len >= limit) {
            truncated = true;
            break;
        }
        const maybe_entry = walker.next(io) catch {
            walk_errors += 1;
            break;
        };
        const entry = maybe_entry orelse break;
        if (entry.kind != .file) continue;
        switch (mode) {
            .zig_only => if (!std.mem.endsWith(u8, entry.path, ".zig")) continue,
            .text_candidates => if (!std.mem.endsWith(u8, entry.path, ".zig") and !std.mem.endsWith(u8, entry.path, ".md")) continue,
        }
        try paths.append(allocator, .{ .path = try allocator.dupe(u8, entry.path) });
    }

    return .{
        .paths = try paths.toOwnedSlice(allocator),
        .walk_errors = walk_errors,
        .truncated = truncated,
        .owns_memory = true,
    };
}
