//! Workspace path sandbox: every user-supplied path is canonicalized and
//! re-checked against the workspace root before any filesystem access.
//! Symlinks are resolved through realpath; a path whose canonical form escapes
//! the root is rejected with PathOutsideWorkspace at resolution time.
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
    /// root_input may be relative or absolute; it is resolved and then
    /// realpath'd so all subsequent containment checks use the canonical inode
    /// address. cache_input defaults to ".zigars-cache" inside root_input.
    /// Fails with PathOutsideWorkspace if cache_input resolves outside root.
    pub fn init(allocator: std.mem.Allocator, io: std.Io, root_input: []const u8, cache_input: ?[]const u8) !Workspace {
        // Capture all required dependencies up front so later calls can stay predictable.
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
            try resolveOutputInsideRoot(allocator, io, root, ".zigars-cache");

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
    /// Returned slice is allocator-owned; caller must free it.
    /// Symlinks that resolve inside the root are allowed; outside-pointing
    /// symlinks are rejected with PathOutsideWorkspace.
    pub fn resolve(self: Workspace, path: []const u8) ![]const u8 {
        return resolveInsideRoot(self.allocator, self.io, self.root, path);
    }

    /// Resolves an output path whose parent may not exist yet.
    /// The parent chain is canonicalized; a symlinked parent escaping the root
    /// is rejected. The final component need not exist. Returned slice is
    /// allocator-owned; caller must free it.
    pub fn resolveOutput(self: Workspace, path: []const u8) ![]const u8 {
        return resolveOutputInsideRoot(self.allocator, self.io, self.root, path);
    }

    /// Reads a workspace-relative file with a caller-supplied byte limit.
    ///
    /// The final component is opened relative to the canonicalized parent
    /// directory with symlink-following disabled, so a path that resolves
    /// inside the root during `resolve` but is swapped for an
    /// outside-pointing symlink before the open is rejected by the kernel
    /// rather than followed (TOCTOU containment).
    pub fn readFileAlloc(self: Workspace, io: std.Io, path: []const u8, max_bytes: usize) ![]u8 {
        // Keep this logic centralized so callers observe one consistent behavior path.
        const resolved = try self.resolve(path);
        defer self.allocator.free(resolved);

        var contained = try openContainedFinalComponent(io, self.root, resolved, false);
        defer contained.parent.close(io);
        var file = contained.openFileNoFollow(io) catch |err| return err;
        defer file.close(io);

        var file_reader = file.reader(io, &.{});
        return file_reader.interface.allocRemaining(self.allocator, .limited(max_bytes)) catch |err| switch (err) {
            error.ReadFailed => return file_reader.err.?,
            error.OutOfMemory, error.StreamTooLong => |e| return e,
        };
    }

    /// Atomically writes a workspace-relative output file, creating parents as needed.
    ///
    /// The atomic file is created relative to the canonicalized parent
    /// directory and materialized with a rename, which replaces an
    /// outside-pointing final-component symlink instead of writing through
    /// it. Containment is therefore enforced against the canonical parent
    /// inode rather than a re-walked path string.
    pub fn writeFile(self: Workspace, io: std.Io, path: []const u8, bytes: []const u8) !void {
        // Keep this logic centralized so callers observe one consistent behavior path.
        const resolved = try self.resolveOutput(path);
        defer self.allocator.free(resolved);

        var contained = try openContainedFinalComponent(io, self.root, resolved, true);
        defer contained.parent.close(io);

        var atomic = try contained.parent.createFileAtomic(io, contained.name, .{
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

/// Resolves an existing input path inside root; returned slice is allocator-owned.
/// Containment is enforced on the canonical path so symlinks that escape the
/// root are rejected. The caller must free the returned slice.
fn resolveInsideRoot(allocator: std.mem.Allocator, io: std.Io, root: []const u8, path: []const u8) ![]const u8 {
    if (path.len == 0) return WorkspaceError.EmptyPath;
    const resolved = if (std.fs.path.isAbsolute(path))
        try std.fs.path.resolve(allocator, &.{path})
    else
        try std.fs.path.resolve(allocator, &.{ root, path });
    defer allocator.free(resolved);

    if (!isInside(root, resolved)) {
        return WorkspaceError.PathOutsideWorkspace;
    }
    const real = realPathFileAbsoluteOwned(allocator, io, resolved) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        // The full path could not be canonicalized (typically a not-yet-existing
        // final component). Do NOT degrade to the unresolved lexical string:
        // canonicalize the parent and re-check containment so an
        // outside-pointing symlink in the parent chain is still rejected.
        // A genuinely missing file then surfaces as FileNotFound on open,
        // matching prior behavior, but containment is never lexical-only.
        else => {
            const parent = std.fs.path.dirname(resolved) orelse root;
            const real_parent = try canonicalOutputParent(allocator, io, root, parent);
            defer allocator.free(real_parent);
            std.debug.assert(isInside(root, real_parent));
            const name = std.fs.path.basename(resolved);
            const real_input = try std.fs.path.join(allocator, &.{ real_parent, name });
            std.debug.assert(isInside(root, real_input));
            return real_input;
        },
    };
    if (!isInside(root, real)) {
        allocator.free(real);
        return WorkspaceError.PathOutsideWorkspace;
    }
    return real;
}

/// Resolves an output path inside root; the final component need not exist yet.
/// Parent directories are canonicalized recursively so a symlinked ancestor
/// that escapes the root is still rejected. Returned slice is allocator-owned.
fn resolveOutputInsideRoot(allocator: std.mem.Allocator, io: std.Io, root: []const u8, path: []const u8) ![]const u8 {
    // Keep this logic centralized so callers observe one consistent behavior path.
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

/// Canonicalizes the parent directory for an output path by walking up the
/// tree until a real directory is found, then re-checking containment.
/// Returns PathOutsideWorkspace when no ancestor is inside root.
fn canonicalOutputParent(allocator: std.mem.Allocator, io: std.Io, root: []const u8, parent: []const u8) ![]u8 {
    // Keep this logic centralized so callers observe one consistent behavior path.
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

/// Returns an allocator-owned canonical path; fails if the path does not exist.
/// The extra dupe is needed because realPathFileAbsoluteAlloc may return a
/// sentinel-terminated slice that is freed by the defer, so we take ownership.
fn realPathFileAbsoluteOwned(allocator: std.mem.Allocator, io: std.Io, absolute_path: []const u8) ![]u8 {
    const sentinel_path = try std.Io.Dir.realPathFileAbsoluteAlloc(io, absolute_path, allocator);
    defer allocator.free(sentinel_path);
    return try allocator.dupe(u8, sentinel_path[0..sentinel_path.len]);
}

/// A final path component pinned to an opened, contained parent directory.
///
/// `parent` is the already-canonicalized parent directory opened as a handle;
/// the handle pins that inode so subsequent `openat`/atomic-create operations
/// resolve relative to it rather than re-walking a path string. `name`
/// borrows the final component from the caller-owned canonical path.
const ContainedTarget = struct {
    parent: std.Io.Dir,
    name: []const u8,

    /// Opens the final component relative to the pinned parent without
    /// following a final-component symlink, so a swap to an outside-pointing
    /// symlink after canonicalization is rejected at open time.
    fn openFileNoFollow(self: ContainedTarget, io: std.Io) !std.Io.File {
        if (builtin.os.tag == .windows) {
            // Zig 0.16's no-follow open on Windows yields a handle whose
            // async flag the std file readers cannot service: reads panic
            // with `.PENDING => unreachable` in readFilePositionalWindows.
            // Use the default open there. Windows symlink creation requires
            // elevation or developer mode, and containment is still enforced
            // against the canonical pinned parent directory handle.
            return self.parent.openFile(io, self.name, .{});
        }
        return self.parent.openFile(io, self.name, .{
            .follow_symlinks = false,
            // Belt-and-suspenders on operating systems that enforce it
            // (e.g. FreeBSD); ignored elsewhere, where `follow_symlinks`
            // plus the canonical parent provides containment.
            .resolve_beneath = true,
        });
    }
};

/// Opens the canonicalized parent of `resolved` and pins its final component.
///
/// `resolved` must already be a canonical absolute path inside `root` (as
/// produced by `resolve`/`resolveOutput`). The parent directory is opened as a
/// handle and re-verified to live inside `root`, which both pins intermediate
/// components against a TOCTOU swap and rejects a path whose parent escapes the
/// workspace (for example the workspace root itself, whose parent is outside).
///
/// When `create_parents` is set, the canonical (already inside-verified) parent
/// chain is created before opening, preserving `make_path` semantics for writes
/// without ever materializing directories outside the root.
fn openContainedFinalComponent(io: std.Io, root: []const u8, resolved: []const u8, create_parents: bool) !ContainedTarget {
    // Keep this logic centralized so callers observe one consistent behavior path.
    const parent_path = std.fs.path.dirname(resolved) orelse return WorkspaceError.PathOutsideWorkspace;
    if (!isInside(root, parent_path)) return WorkspaceError.PathOutsideWorkspace;
    const name = std.fs.path.basename(resolved);
    if (name.len == 0) return WorkspaceError.EmptyPath;
    if (create_parents) {
        try std.Io.Dir.cwd().createDirPath(io, parent_path);
    }
    const parent = try std.Io.Dir.openDirAbsolute(io, parent_path, .{});
    return .{ .parent = parent, .name = name };
}

/// True when `path` is exactly `root` or a descendant separated by a path separator.
pub fn isInside(root: []const u8, path: []const u8) bool {
    if (std.mem.eql(u8, root, path)) return true;
    if (!std.mem.startsWith(u8, path, root)) return false;
    if (path.len <= root.len) return false;
    return path[root.len] == std.fs.path.sep;
}

test "resolve keeps paths inside workspace" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "root/src");
    try tmp.dir.writeFile(io, .{ .sub_path = "root/src/main.zig", .data = "pub fn main() void {}\n" });

    const rel_base = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    const base_z = try std.Io.Dir.cwd().realPathFileAlloc(io, rel_base, allocator);
    const root = try std.fs.path.join(allocator, &.{ base_z[0..], "root" });

    const child = try resolveInsideRoot(allocator, io, root, "src/main.zig");
    try std.testing.expect(isInside(root, child));
    try std.testing.expectError(WorkspaceError.PathOutsideWorkspace, resolveInsideRoot(allocator, io, root, "../outside.zig"));
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

test "contained open rejects a final component swapped to an outside symlink after resolve" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // A real file inside the root, and an attacker-controlled target outside it.
    try tmp.dir.createDirPath(io, "root/src");
    try tmp.dir.writeFile(io, .{ .sub_path = "root/src/main.zig", .data = "pub const internal = true;\n" });
    try tmp.dir.createDirPath(io, "outside");
    try tmp.dir.writeFile(io, .{ .sub_path = "outside/evil.zig", .data = "pub const escaped = true;\n" });

    const rel_base = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer allocator.free(rel_base);
    const base_z = try std.Io.Dir.cwd().realPathFileAlloc(io, rel_base, allocator);
    defer allocator.free(base_z);
    const base = base_z[0..];
    const root = try std.fs.path.join(allocator, &.{ base, "root" });
    defer allocator.free(root);
    const target_inside = try std.fs.path.join(allocator, &.{ root, "src", "main.zig" });
    defer allocator.free(target_inside);
    const outside_file = try std.fs.path.join(allocator, &.{ base, "outside", "evil.zig" });
    defer allocator.free(outside_file);

    // Time-of-check: canonicalize while the path is still a real inside file.
    const canonical = try resolveInsideRoot(allocator, io, root, "src/main.zig");
    defer allocator.free(canonical);
    try std.testing.expectEqualStrings(target_inside, canonical);

    // Time-of-use swap: the final component is replaced with a symlink that
    // points outside the workspace, simulating a racing attacker winning the
    // TOCTOU window between resolve and open.
    try std.Io.Dir.cwd().deleteFile(io, canonical);
    try std.Io.Dir.symLinkAbsolute(io, outside_file, canonical, .{});

    // Post-fix containment: opening the final component relative to the pinned
    // canonical parent with symlink-following disabled rejects the swap instead
    // of reading the outside file.
    var contained = try openContainedFinalComponent(io, root, canonical, false);
    defer contained.parent.close(io);
    try std.testing.expectError(error.SymLinkLoop, contained.openFileNoFollow(io));

    // Control proving the pre-fix open strategy was exploitable: re-walking the
    // canonical string with symlink-following enabled (the old behavior) follows
    // the swapped symlink straight out of the workspace. If `readFileAlloc` is
    // ever reverted to that strategy this divergence is the regression signal.
    var followed = try std.Io.Dir.cwd().openFile(io, canonical, .{});
    defer followed.close(io);
    var reader = followed.reader(io, &.{});
    const leaked = try reader.interface.allocRemaining(allocator, .limited(4096));
    defer allocator.free(leaked);
    try std.testing.expectEqualStrings("pub const escaped = true;\n", leaked);
}
