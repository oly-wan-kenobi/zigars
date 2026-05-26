//! Adapts workspace-relative file operations to the WorkspaceStore port.
const std = @import("std");

const ports = @import("../../app/ports.zig");
const command = @import("../process/command.zig");
const workspace_mod = @import("workspace.zig");

/// Selects whether reads resolve against existing input paths or output paths.
pub const ReadResolution = enum {
    input,
    output,
};

/// WorkspaceStore port backed by real filesystem calls under a Workspace root.
pub const Store = struct {
    workspace: *workspace_mod.Workspace,
    io: std.Io,
    default_read_limit: usize = command.output_limit,
    read_resolution: ReadResolution = .input,

    const Self = @This();

    /// Stores borrowed workspace pointer and default read options.
    pub fn init(workspace: *workspace_mod.Workspace, io: std.Io, options: Options) Self {
        return .{
            .workspace = workspace,
            .io = io,
            .default_read_limit = options.default_read_limit,
            .read_resolution = options.read_resolution,
        };
    }

    /// Configuration for filesystem-backed workspace reads.
    pub const Options = struct {
        default_read_limit: usize = command.output_limit,
        read_resolution: ReadResolution = .input,
    };

    /// Exposes this store through the WorkspaceStore vtable.
    pub fn port(self: *Self) ports.WorkspaceStore {
        return .{
            .ptr = self,
            .vtable = &.{
                .resolve = resolve,
                .read = read,
                .write = write,
                .delete = delete,
                .exists = exists,
                .ensure_dir = ensureDir,
                .scan_directory = scanDirectory,
            },
        };
    }

    /// Resolves an input path; returned memory belongs to the workspace allocator.
    pub fn resolveInputPath(self: *Self, path: []const u8) ![]const u8 {
        return self.workspace.resolve(path);
    }

    /// Resolves an output path; returned memory belongs to the workspace allocator.
    pub fn resolveOutputPath(self: *Self, path: []const u8) ![]const u8 {
        return self.workspace.resolveOutput(path);
    }

    /// Frees a path returned by resolveInputPath or resolveOutputPath.
    pub fn freeResolvedPath(self: *Self, path: []const u8) void {
        self.workspace.allocator.free(path);
    }

    /// Resolves resolve and returns borrowed or owned data according to the result contract.
    fn resolve(ptr: *anyopaque, allocator: std.mem.Allocator, request: ports.WorkspaceResolveRequest) ports.PortError!ports.WorkspaceResolveResult {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const resolved = if (request.for_output)
            self.workspace.resolveOutput(request.path) catch |err| return mapPortError(err)
        else
            self.workspace.resolve(request.path) catch |err| return mapPortError(err);
        defer self.workspace.allocator.free(resolved);
        return .{ .path = allocator.dupe(u8, resolved) catch return error.OutOfMemory, .owns_path = true };
    }

    /// Reads stored data through this port implementation.
    fn read(ptr: *anyopaque, allocator: std.mem.Allocator, request: ports.WorkspaceReadRequest) ports.PortError!ports.WorkspaceReadResult {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const use_output = request.for_output orelse (self.read_resolution == .output);
        const resolved = if (use_output)
            self.workspace.resolveOutput(request.path) catch |err| return mapPortError(err)
        else
            self.workspace.resolve(request.path) catch |err| return mapPortError(err);
        defer self.workspace.allocator.free(resolved);
        const max_bytes = request.max_bytes orelse self.default_read_limit;
        if (max_bytes == 0) {
            // Probe openability without allocating file contents.
            var file = std.Io.Dir.cwd().openFile(self.io, resolved, .{}) catch |err| return mapPortError(err);
            file.close(self.io);
            return .{ .bytes = "" };
        }
        const bytes = std.Io.Dir.cwd().readFileAlloc(self.io, resolved, allocator, .limited(max_bytes)) catch |err| return mapPortError(err);
        return .{ .bytes = bytes, .owns_bytes = true };
    }

    /// Writes bytes through this port implementation.
    fn write(ptr: *anyopaque, request: ports.WorkspaceWriteRequest) ports.PortError!ports.WorkspaceWriteResult {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.workspace.writeFile(self.io, request.path, request.bytes) catch |err| return mapPortError(err);
        return .{
            .bytes_written = request.bytes.len,
            .replaced_existing = false,
        };
    }

    /// Deletes a path through this port implementation.
    fn delete(ptr: *anyopaque, request: ports.WorkspaceDeleteRequest) ports.PortError!ports.WorkspaceDeleteResult {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const resolved = self.workspace.resolve(request.path) catch |err| return mapPortError(err);
        defer self.workspace.allocator.free(resolved);
        std.Io.Dir.cwd().deleteFile(self.io, resolved) catch |err| switch (err) {
            error.FileNotFound => {
                if (!request.missing_ok) return error.FileNotFound;
                return .{ .deleted = false };
            },
            else => return mapPortError(err),
        };
        return .{ .deleted = true };
    }

    /// Checks path existence through this port implementation.
    fn exists(ptr: *anyopaque, allocator: std.mem.Allocator, request: ports.WorkspaceExistsRequest) ports.PortError!ports.WorkspaceExistsResult {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const resolved = if (request.for_output)
            self.workspace.resolveOutput(request.path) catch |err| return existsResolveError(err)
        else
            self.workspace.resolve(request.path) catch |err| return existsResolveError(err);
        defer self.workspace.allocator.free(resolved);

        var dir = std.Io.Dir.openDirAbsolute(self.io, resolved, .{ .iterate = true }) catch {
            var file = std.Io.Dir.cwd().openFile(self.io, resolved, .{}) catch return .{ .exists = false };
            file.close(self.io);
            return .{ .exists = true, .kind = .file };
        };
        defer dir.close(self.io);

        var walker = dir.walk(allocator) catch return .{ .exists = true, .kind = .directory, .entry_count = null };
        defer walker.deinit();
        var count: usize = 0;
        while ((walker.next(self.io) catch null)) |entry| {
            // Only direct-child paths contribute to entry_count; nested entries are ignored.
            if (std.mem.indexOfScalar(u8, entry.path, std.fs.path.sep) == null) count += 1;
        }
        return .{ .exists = true, .kind = .directory, .entry_count = count };
    }

    /// Maps path-resolution failure into an existence-check result.
    fn existsResolveError(err: anyerror) ports.PortError!ports.WorkspaceExistsResult {
        // For existence probes, path/safety resolution failures map to "missing".
        return switch (mapPortError(err)) {
            error.OutOfMemory => error.OutOfMemory,
            else => .{ .exists = false },
        };
    }

    /// Ensures a directory exists through this port implementation.
    fn ensureDir(ptr: *anyopaque, request: ports.WorkspaceEnsureDirRequest) ports.PortError!ports.WorkspaceEnsureDirResult {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const resolved = self.workspace.resolveOutput(request.path) catch |err| return mapPortError(err);
        defer self.workspace.allocator.free(resolved);
        std.Io.Dir.cwd().createDirPath(self.io, resolved) catch |err| return mapPortError(err);
        return .{};
    }

    /// Scans a directory through this port implementation.
    fn scanDirectory(ptr: *anyopaque, allocator: std.mem.Allocator, request: ports.WorkspaceDirectoryScanRequest) ports.PortError!ports.WorkspaceDirectoryScanResult {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const resolved = if (request.for_output)
            self.workspace.resolveOutput(request.path) catch |err| return mapPortError(err)
        else
            self.workspace.resolve(request.path) catch |err| return mapPortError(err);
        defer self.workspace.allocator.free(resolved);
        var dir = std.Io.Dir.openDirAbsolute(self.io, resolved, .{ .iterate = true }) catch |err| return mapPortError(err);
        defer dir.close(self.io);
        var walker = dir.walk(allocator) catch |err| return mapPortError(err);
        defer walker.deinit();
        var entries: std.ArrayList(ports.WorkspaceDirectoryEntry) = .empty;
        var entries_owned = true;
        defer if (entries_owned) {
            for (entries.items) |entry| allocator.free(entry.path);
            entries.deinit(allocator);
        };
        while (walker.next(self.io) catch |err| return mapPortError(err)) |entry| {
            if (request.max_files) |max_files| if (entries.items.len >= max_files) break;
            if (entry.kind != .file) continue;
            if (request.suffix.len > 0 and !std.mem.endsWith(u8, entry.path, request.suffix)) continue;
            const path = allocator.dupe(u8, entry.path) catch return error.OutOfMemory;
            var path_owned = true;
            defer if (path_owned) allocator.free(path);
            try entries.append(allocator, .{ .path = path });
            path_owned = false;
        }
        const owned_entries = try entries.toOwnedSlice(allocator);
        entries_owned = false;
        return .{ .entries = owned_entries, .owns_memory = true };
    }
};

/// Maps filesystem and workspace safety failures to WorkspaceStore port errors.
pub fn mapPortError(err: anyerror) ports.PortError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.FileNotFound => error.FileNotFound,
        error.AccessDenied => error.AccessDenied,
        error.PermissionDenied => error.PermissionDenied,
        error.Timeout => error.Timeout,
        error.RequestTimeout => error.RequestTimeout,
        error.EndOfStream => error.EndOfStream,
        error.BrokenPipe => error.BrokenPipe,
        error.PathOutsideWorkspace => error.PathOutsideWorkspace,
        error.EmptyPath => error.EmptyPath,
        error.StreamTooLong => error.StreamTooLong,
        error.InvalidArguments => error.InvalidRequest,
        else => error.Unavailable,
    };
}

test "filesystem workspace store existence treats non-oom resolve errors as missing" {
    try std.testing.expectError(error.OutOfMemory, Store.existsResolveError(error.OutOfMemory));
    const missing = try Store.existsResolveError(error.PathOutsideWorkspace);
    try std.testing.expect(!missing.exists);
}
