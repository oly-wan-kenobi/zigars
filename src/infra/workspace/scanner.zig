const std = @import("std");

const ports = @import("../../app/ports.zig");
const workspace_mod = @import("workspace.zig");
const zig_analysis = @import("../../domain/zig/analysis.zig");
const filesystem = @import("filesystem.zig");

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

    pub fn port(self: *Self) ports.WorkspaceScanner {
        return .{
            .ptr = self,
            .vtable = &.{
                .scan_zig_files = scanZigFiles,
            },
        };
    }

    fn scanZigFiles(
        ptr: *anyopaque,
        allocator: std.mem.Allocator,
        request: ports.WorkspaceScanRequest,
    ) ports.PortError!ports.WorkspaceScanResult {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const resolved_prefix = if (request.path_prefix.len == 0)
            try self.workspace.resolve(".")
        else
            self.workspace.resolve(request.path_prefix) catch |err| return filesystem.mapPortError(err);
        defer self.workspace.allocator.free(resolved_prefix);

        var dir = std.Io.Dir.openDirAbsolute(self.io, resolved_prefix, .{ .iterate = true }) catch |err| return filesystem.mapPortError(err);
        defer dir.close(self.io);

        var walker = dir.walk(allocator) catch return error.OutOfMemory;
        defer walker.deinit();

        var files: std.ArrayList(ports.WorkspaceScanFile) = .empty;
        errdefer {
            for (files.items) |file| allocator.free(file.path);
            files.deinit(allocator);
        }
        const limit = request.max_files orelse std.math.maxInt(usize);
        while (files.items.len < limit) {
            const maybe_entry = walker.next(self.io) catch |err| return filesystem.mapPortError(err);
            const entry = maybe_entry orelse break;
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.path, ".zig")) continue;
            if (zig_analysis.skipWorkspacePath(entry.path)) continue;
            const rel = try allocator.dupe(u8, entry.path);
            var rel_owned = true;
            defer if (rel_owned) allocator.free(rel);
            try files.append(allocator, .{ .path = rel });
            rel_owned = false;
        }

        return .{
            .files = try files.toOwnedSlice(allocator),
            .owns_memory = true,
        };
    }
};

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
