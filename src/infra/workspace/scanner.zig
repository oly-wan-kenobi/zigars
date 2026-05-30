//! WorkspaceScanner port implementation: walks workspace directories and
//! collects .zig source files, skipping cache and build-output paths as
//! classified by the domain analysis policy.
const std = @import("std");

const ports = @import("../../app/ports.zig");
const workspace_mod = @import("workspace.zig");
const zig_analysis = @import("../../domain/zig/analysis.zig");
const filesystem = @import("filesystem.zig");

/// WorkspaceScanner port that walks workspace directories and returns Zig files.
pub const Scanner = struct {
    workspace: *workspace_mod.Workspace,
    io: std.Io,

    const Self = @This();

    /// Stores borrowed workspace pointer and I/O handle for later scans.
    pub fn init(workspace: *workspace_mod.Workspace, io: std.Io) Self {
        return .{
            .workspace = workspace,
            .io = io,
        };
    }

    /// Exposes this scanner through the WorkspaceScanner vtable.
    pub fn port(self: *Self) ports.WorkspaceScanner {
        return .{
            .ptr = self,
            .vtable = &.{
                .scan_zig_files = scanZigFiles,
            },
        };
    }

    /// Scans Zig source files under the workspace (or a prefix sub-path) and
    /// returns an allocator-owned result; call result.deinit(allocator) to free.
    /// Files listed under paths excluded by zig_analysis.skipWorkspacePath are
    /// silently omitted (e.g. .zig-cache, zig-out).
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
