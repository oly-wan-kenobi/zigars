const std = @import("std");
const builtin = @import("builtin");

/// Errors raised when workspace-relative paths cannot be made safe.
pub const WorkspaceError = error{
    PathOutsideWorkspace,
    EmptyPath,
};

/// Owns canonical workspace roots and resolves all file access through them.
pub const Workspace = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    cache_root: []const u8,

    /// Canonicalizes the workspace and cache roots; caller must call deinit.
    pub fn init(allocator: std.mem.Allocator, io: std.Io, root_input: []const u8, cache_input: ?[]const u8) !Workspace {
        var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
        const cwd_len = try std.process.currentPath(io, &cwd_buf);
        const cwd = cwd_buf[0..cwd_len];
        const lexical_root = if (std.fs.path.isAbsolute(root_input))
            try std.fs.path.resolve(allocator, &.{root_input})
        else
            try std.fs.path.resolve(allocator, &.{ cwd, root_input });
        defer allocator.free(lexical_root);
        const root = try realPathFileAbsoluteOwned(allocator, io, lexical_root);
        errdefer allocator.free(root);

        const cache_root = if (cache_input) |cache|
            try resolveOutputInsideRoot(allocator, io, root, cache)
        else
            try resolveOutputInsideRoot(allocator, io, root, ".zigar-cache");

        return .{
            .allocator = allocator,
            .io = io,
            .root = root,
            .cache_root = cache_root,
        };
    }

    /// Releases root strings owned by the workspace.
    pub fn deinit(self: *Workspace) void {
        self.allocator.free(self.root);
        self.allocator.free(self.cache_root);
    }

    /// Resolves an existing input path and rejects paths outside the workspace.
    pub fn resolve(self: Workspace, path: []const u8) ![]const u8 {
        return resolveInsideRoot(self.allocator, self.io, self.root, path);
    }

    /// Resolves an output path whose parent may not exist yet.
    pub fn resolveOutput(self: Workspace, path: []const u8) ![]const u8 {
        return resolveOutputInsideRoot(self.allocator, self.io, self.root, path);
    }

    /// Reads a workspace-relative file with a caller-supplied byte limit.
    pub fn readFileAlloc(self: Workspace, io: std.Io, path: []const u8, max_bytes: usize) ![]u8 {
        const resolved = try self.resolve(path);
        defer self.allocator.free(resolved);
        return std.Io.Dir.cwd().readFileAlloc(io, resolved, self.allocator, .limited(max_bytes));
    }

    /// Atomically writes a workspace-relative output file, creating parents as needed.
    pub fn writeFile(self: Workspace, io: std.Io, path: []const u8, bytes: []const u8) !void {
        const resolved = try self.resolveOutput(path);
        defer self.allocator.free(resolved);
        var atomic = try std.Io.Dir.cwd().createFileAtomic(io, resolved, .{
            .make_path = true,
            .replace = true,
        });
        defer atomic.deinit(io);
        var buffer: [1024]u8 = undefined;
        var writer = atomic.file.writer(io, &buffer);
        try writer.interface.writeAll(bytes);
        try writer.flush();
        try atomic.replace(io);
    }

    /// Returns a workspace-relative view when `abs_path` is below the root.
    pub fn relative(self: Workspace, abs_path: []const u8) []const u8 {
        if (std.mem.eql(u8, abs_path, self.root)) return ".";
        if (std.mem.startsWith(u8, abs_path, self.root) and abs_path.len > self.root.len and abs_path[self.root.len] == std.fs.path.sep) {
            return abs_path[self.root.len + 1 ..];
        }
        return abs_path;
    }
};

/// Resolves inside root and returns borrowed or owned data according to the result contract.
fn resolveInsideRoot(allocator: std.mem.Allocator, io: std.Io, root: []const u8, path: []const u8) ![]const u8 {
    if (path.len == 0) return WorkspaceError.EmptyPath;
    const resolved = if (std.fs.path.isAbsolute(path))
        try std.fs.path.resolve(allocator, &.{path})
    else
        try std.fs.path.resolve(allocator, &.{ root, path });
    var resolved_owned = true;
    defer if (resolved_owned) allocator.free(resolved);

    if (!isInside(root, resolved)) {
        return WorkspaceError.PathOutsideWorkspace;
    }
    const real = realPathFileAbsoluteOwned(allocator, io, resolved) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            resolved_owned = false;
            return resolved;
        },
    };
    if (!isInside(root, real)) {
        allocator.free(real);
        return WorkspaceError.PathOutsideWorkspace;
    }
    return real;
}

/// Resolves output inside root and returns borrowed or owned data according to the result contract.
fn resolveOutputInsideRoot(allocator: std.mem.Allocator, io: std.Io, root: []const u8, path: []const u8) ![]const u8 {
    if (path.len == 0) return WorkspaceError.EmptyPath;
    const resolved = if (std.fs.path.isAbsolute(path))
        try std.fs.path.resolve(allocator, &.{path})
    else
        try std.fs.path.resolve(allocator, &.{ root, path });
    defer allocator.free(resolved);

    if (!isInside(root, resolved)) {
        return WorkspaceError.PathOutsideWorkspace;
    }
    const existing_output = realPathFileAbsoluteOwned(allocator, io, resolved) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => null,
    };
    if (existing_output) |real| {
        if (!isInside(root, real)) {
            allocator.free(real);
            return WorkspaceError.PathOutsideWorkspace;
        }
        return real;
    }

    const parent = std.fs.path.dirname(resolved) orelse root;
    const real_parent = try canonicalOutputParent(allocator, io, root, parent);
    defer allocator.free(real_parent);
    std.debug.assert(isInside(root, real_parent));

    const name = std.fs.path.basename(resolved);
    const real_output = try std.fs.path.join(allocator, &.{ real_parent, name });
    std.debug.assert(isInside(root, real_output));
    return real_output;
}

/// Canonicalizes the parent directory for an output path.
fn canonicalOutputParent(allocator: std.mem.Allocator, io: std.Io, root: []const u8, parent: []const u8) ![]u8 {
    const real = realPathFileAbsoluteOwned(allocator, io, parent) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => null,
    };
    if (real) |resolved_parent| {
        if (!isInside(root, resolved_parent)) {
            allocator.free(resolved_parent);
            return WorkspaceError.PathOutsideWorkspace;
        }
        return resolved_parent;
    }

    if (std.mem.eql(u8, parent, root)) return WorkspaceError.PathOutsideWorkspace;
    const grandparent = std.fs.path.dirname(parent) orelse return WorkspaceError.PathOutsideWorkspace;
    const basename = std.fs.path.basename(parent);
    const real_grandparent = try canonicalOutputParent(allocator, io, root, grandparent);
    defer allocator.free(real_grandparent);
    const joined = try std.fs.path.join(allocator, &.{ real_grandparent, basename });
    var joined_owned = true;
    defer if (joined_owned) allocator.free(joined);
    if (!isInside(root, joined)) return WorkspaceError.PathOutsideWorkspace;
    joined_owned = false;
    return joined;
}

/// Returns an allocator-owned absolute real path for a file.
fn realPathFileAbsoluteOwned(allocator: std.mem.Allocator, io: std.Io, absolute_path: []const u8) ![]u8 {
    const sentinel_path = try std.Io.Dir.realPathFileAbsoluteAlloc(io, absolute_path, allocator);
    defer allocator.free(sentinel_path);
    return try allocator.dupe(u8, sentinel_path[0..sentinel_path.len]);
}

/// True when `path` is exactly `root` or a descendant separated by a path separator.
pub fn isInside(root: []const u8, path: []const u8) bool {
    if (std.mem.eql(u8, root, path)) return true;
    if (!std.mem.startsWith(u8, path, root)) return false;
    if (path.len <= root.len) return false;
    return path[root.len] == std.fs.path.sep;
}

test "resolve keeps paths inside workspace" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const root = try std.fs.path.resolve(arena.allocator(), &.{"/tmp/zigar-root"});
    const child = try resolveInsideRoot(arena.allocator(), std.testing.io, root, "src/main.zig");
    try std.testing.expect(isInside(root, child));
    try std.testing.expectError(WorkspaceError.PathOutsideWorkspace, resolveInsideRoot(arena.allocator(), std.testing.io, root, "../outside.zig"));
}

test "resolve propagates allocation failure while canonicalizing existing files" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "root/src");
    try tmp.dir.writeFile(io, .{ .sub_path = "root/src/main.zig", .data = "pub fn main() void {}\n" });

    const rel_base = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer allocator.free(rel_base);
    const base_z = try std.Io.Dir.cwd().realPathFileAlloc(io, rel_base, allocator);
    defer allocator.free(base_z);
    const root = try std.fs.path.join(allocator, &.{ base_z[0..], "root" });
    defer allocator.free(root);

    var saw_success = false;
    var saw_oom = false;
    for (0..32) |fail_index| {
        var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = fail_index });
        const result = resolveInsideRoot(failing.allocator(), io, root, "src/main.zig");
        if (result) |resolved| {
            failing.allocator().free(resolved);
            saw_success = true;
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            saw_oom = true;
        }
    }
    try std.testing.expect(saw_success);
    try std.testing.expect(saw_oom);
}
