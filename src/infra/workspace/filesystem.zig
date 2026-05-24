const std = @import("std");

const ports = @import("../../app/ports.zig");
const command = @import("../process/command.zig");
const workspace_mod = @import("workspace.zig");

pub const ReadResolution = enum {
    input,
    output,
};

pub const Store = struct {
    workspace: *workspace_mod.Workspace,
    io: std.Io,
    default_read_limit: usize = command.output_limit,
    read_resolution: ReadResolution = .input,

    const Self = @This();

    pub fn init(workspace: *workspace_mod.Workspace, io: std.Io, options: Options) Self {
        return .{
            .workspace = workspace,
            .io = io,
            .default_read_limit = options.default_read_limit,
            .read_resolution = options.read_resolution,
        };
    }

    pub const Options = struct {
        default_read_limit: usize = command.output_limit,
        read_resolution: ReadResolution = .input,
    };

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

    pub fn resolveInputPath(self: *Self, path: []const u8) ![]const u8 {
        return self.workspace.resolve(path);
    }

    pub fn resolveOutputPath(self: *Self, path: []const u8) ![]const u8 {
        return self.workspace.resolveOutput(path);
    }

    pub fn freeResolvedPath(self: *Self, path: []const u8) void {
        self.workspace.allocator.free(path);
    }

    fn resolve(ptr: *anyopaque, allocator: std.mem.Allocator, request: ports.WorkspaceResolveRequest) ports.PortError!ports.WorkspaceResolveResult {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const resolved = if (request.for_output)
            self.workspace.resolveOutput(request.path) catch |err| return mapPortError(err)
        else
            self.workspace.resolve(request.path) catch |err| return mapPortError(err);
        defer self.workspace.allocator.free(resolved);
        return .{ .path = allocator.dupe(u8, resolved) catch return error.OutOfMemory, .owns_path = true };
    }

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
            var file = std.Io.Dir.cwd().openFile(self.io, resolved, .{}) catch |err| return mapPortError(err);
            file.close(self.io);
            return .{ .bytes = "" };
        }
        const bytes = std.Io.Dir.cwd().readFileAlloc(self.io, resolved, allocator, .limited(max_bytes)) catch |err| return mapPortError(err);
        return .{ .bytes = bytes, .owns_bytes = true };
    }

    fn write(ptr: *anyopaque, request: ports.WorkspaceWriteRequest) ports.PortError!ports.WorkspaceWriteResult {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.workspace.writeFile(self.io, request.path, request.bytes) catch |err| return mapPortError(err);
        return .{
            .bytes_written = request.bytes.len,
            .replaced_existing = false,
        };
    }

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
            if (std.mem.indexOfScalar(u8, entry.path, std.fs.path.sep) == null) count += 1;
        }
        return .{ .exists = true, .kind = .directory, .entry_count = count };
    }

    fn existsResolveError(err: anyerror) ports.PortError!ports.WorkspaceExistsResult {
        return switch (mapPortError(err)) {
            error.OutOfMemory => error.OutOfMemory,
            else => .{ .exists = false },
        };
    }

    fn ensureDir(ptr: *anyopaque, request: ports.WorkspaceEnsureDirRequest) ports.PortError!ports.WorkspaceEnsureDirResult {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const resolved = self.workspace.resolveOutput(request.path) catch |err| return mapPortError(err);
        defer self.workspace.allocator.free(resolved);
        std.Io.Dir.cwd().createDirPath(self.io, resolved) catch |err| return mapPortError(err);
        return .{};
    }

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
        errdefer {
            for (entries.items) |entry| allocator.free(entry.path);
            entries.deinit(allocator);
        }
        while (walker.next(self.io) catch |err| return mapPortError(err)) |entry| {
            if (request.max_files) |max_files| if (entries.items.len >= max_files) break;
            if (entry.kind != .file) continue;
            if (request.suffix.len > 0 and !std.mem.endsWith(u8, entry.path, request.suffix)) continue;
            try entries.append(allocator, .{ .path = allocator.dupe(u8, entry.path) catch return error.OutOfMemory });
        }
        return .{ .entries = try entries.toOwnedSlice(allocator), .owns_memory = true };
    }
};

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
}
