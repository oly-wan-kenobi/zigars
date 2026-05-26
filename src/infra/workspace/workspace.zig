const std = @import("std");
const builtin = @import("builtin");

pub const WorkspaceError = error{
    PathOutsideWorkspace,
    EmptyPath,
};

pub const Workspace = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    cache_root: []const u8,

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

    pub fn deinit(self: *Workspace) void {
        self.allocator.free(self.root);
        self.allocator.free(self.cache_root);
    }

    pub fn resolve(self: Workspace, path: []const u8) ![]const u8 {
        return resolveInsideRoot(self.allocator, self.io, self.root, path);
    }

    pub fn resolveOutput(self: Workspace, path: []const u8) ![]const u8 {
        return resolveOutputInsideRoot(self.allocator, self.io, self.root, path);
    }

    pub fn readFileAlloc(self: Workspace, io: std.Io, path: []const u8, max_bytes: usize) ![]u8 {
        const resolved = try self.resolve(path);
        defer self.allocator.free(resolved);
        return std.Io.Dir.cwd().readFileAlloc(io, resolved, self.allocator, .limited(max_bytes));
    }

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

    pub fn relative(self: Workspace, abs_path: []const u8) []const u8 {
        if (std.mem.eql(u8, abs_path, self.root)) return ".";
        if (std.mem.startsWith(u8, abs_path, self.root) and abs_path.len > self.root.len and abs_path[self.root.len] == std.fs.path.sep) {
            return abs_path[self.root.len + 1 ..];
        }
        return abs_path;
    }
};

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

fn realPathFileAbsoluteOwned(allocator: std.mem.Allocator, io: std.Io, absolute_path: []const u8) ![]u8 {
    const sentinel_path = try std.Io.Dir.realPathFileAbsoluteAlloc(io, absolute_path, allocator);
    defer allocator.free(sentinel_path);
    return try allocator.dupe(u8, sentinel_path[0..sentinel_path.len]);
}

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

test "workspace init canonicalizes relative root" {
    var ws = try Workspace.init(std.testing.allocator, std.testing.io, ".", null);
    defer ws.deinit();
    try std.testing.expect(std.fs.path.isAbsolute(ws.root));
}

test "workspace init accepts explicit cache output inside root" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "root");
    const rel_base = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer allocator.free(rel_base);
    const base_z = try std.Io.Dir.cwd().realPathFileAlloc(io, rel_base, allocator);
    defer allocator.free(base_z);
    const root = try std.fs.path.join(allocator, &.{ base_z[0..], "root" });
    defer allocator.free(root);
    const expected_cache = try std.fs.path.join(allocator, &.{ root, "cache" });
    defer allocator.free(expected_cache);

    var ws = try Workspace.init(allocator, io, root, "cache");
    defer ws.deinit();
    try std.testing.expectEqualStrings(expected_cache, ws.cache_root);
}

test "workspace resolves absolute output paths only when inside root" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "root/out");
    const rel_base = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer allocator.free(rel_base);
    const base_z = try std.Io.Dir.cwd().realPathFileAlloc(io, rel_base, allocator);
    defer allocator.free(base_z);
    const root = try std.fs.path.join(allocator, &.{ base_z[0..], "root" });
    defer allocator.free(root);
    const inside = try std.fs.path.join(allocator, &.{ root, "out", "generated.zig" });
    defer allocator.free(inside);
    const outside = try std.fs.path.join(allocator, &.{ base_z[0..], "outside.zig" });
    defer allocator.free(outside);

    var ws = try Workspace.init(allocator, io, root, null);
    defer ws.deinit();
    const resolved = try ws.resolveOutput(inside);
    defer allocator.free(resolved);
    try std.testing.expectEqualStrings(inside, resolved);
    try std.testing.expectError(WorkspaceError.PathOutsideWorkspace, ws.resolveOutput(outside));
}

test "workspace relative only trims root at path boundary" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const ws = Workspace{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .root = "/tmp/project",
        .cache_root = "/tmp/project/.zigar-cache",
    };

    try std.testing.expectEqualStrings(".", ws.relative("/tmp/project"));
    try std.testing.expectEqualStrings("src/main.zig", ws.relative("/tmp/project/src/main.zig"));
    try std.testing.expectEqualStrings("/tmp/projectile/src/main.zig", ws.relative("/tmp/projectile/src/main.zig"));
}

test "workspace allows symlinked input inside root" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "root/src");
    try tmp.dir.writeFile(io, .{ .sub_path = "root/src/main.zig", .data = "pub const internal = true;\n" });

    const rel_base = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer allocator.free(rel_base);
    const base_z = try std.Io.Dir.cwd().realPathFileAlloc(io, rel_base, allocator);
    defer allocator.free(base_z);
    const base = base_z[0..];
    const root = try std.fs.path.join(allocator, &.{ base, "root" });
    defer allocator.free(root);
    const target_file = try std.fs.path.join(allocator, &.{ root, "src", "main.zig" });
    defer allocator.free(target_file);
    const link_file = try std.fs.path.join(allocator, &.{ root, "link.zig" });
    defer allocator.free(link_file);

    try std.Io.Dir.symLinkAbsolute(io, target_file, link_file, .{});

    var ws = try Workspace.init(allocator, io, root, null);
    defer ws.deinit();
    const resolved = try ws.resolve("link.zig");
    defer allocator.free(resolved);
    try std.testing.expectEqualStrings(target_file, resolved);
}

test "workspace rejects symlinked input outside root" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "root");
    try tmp.dir.createDirPath(io, "outside");
    try tmp.dir.writeFile(io, .{ .sub_path = "outside/outside.zig", .data = "pub const escaped = true;\n" });

    const rel_base = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer allocator.free(rel_base);
    const base_z = try std.Io.Dir.cwd().realPathFileAlloc(io, rel_base, allocator);
    defer allocator.free(base_z);
    const base = base_z[0..];
    const root = try std.fs.path.join(allocator, &.{ base, "root" });
    defer allocator.free(root);
    const outside_file = try std.fs.path.join(allocator, &.{ base, "outside", "outside.zig" });
    defer allocator.free(outside_file);
    const link_file = try std.fs.path.join(allocator, &.{ root, "link.zig" });
    defer allocator.free(link_file);

    try std.Io.Dir.symLinkAbsolute(io, outside_file, link_file, .{});

    var ws = try Workspace.init(allocator, io, root, null);
    defer ws.deinit();
    try std.testing.expectError(WorkspaceError.PathOutsideWorkspace, ws.resolve("link.zig"));
}

test "workspace rejects default cache symlink outside root" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "root");
    try tmp.dir.createDirPath(io, "outside-cache");

    const rel_base = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer allocator.free(rel_base);
    const base_z = try std.Io.Dir.cwd().realPathFileAlloc(io, rel_base, allocator);
    defer allocator.free(base_z);
    const base = base_z[0..];
    const root = try std.fs.path.join(allocator, &.{ base, "root" });
    defer allocator.free(root);
    const outside_cache = try std.fs.path.join(allocator, &.{ base, "outside-cache" });
    defer allocator.free(outside_cache);
    const cache_link = try std.fs.path.join(allocator, &.{ root, ".zigar-cache" });
    defer allocator.free(cache_link);

    try std.Io.Dir.symLinkAbsolute(io, outside_cache, cache_link, .{ .is_directory = true });

    try std.testing.expectError(WorkspaceError.PathOutsideWorkspace, Workspace.init(allocator, io, root, null));
}

test "workspace rejects output through symlinked parent" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "root");
    try tmp.dir.createDirPath(io, "outside");

    const rel_base = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer allocator.free(rel_base);
    const base_z = try std.Io.Dir.cwd().realPathFileAlloc(io, rel_base, allocator);
    defer allocator.free(base_z);
    const base = base_z[0..];
    const root = try std.fs.path.join(allocator, &.{ base, "root" });
    defer allocator.free(root);
    const outside_dir = try std.fs.path.join(allocator, &.{ base, "outside" });
    defer allocator.free(outside_dir);
    const link_dir = try std.fs.path.join(allocator, &.{ root, "outlink" });
    defer allocator.free(link_dir);

    try std.Io.Dir.symLinkAbsolute(io, outside_dir, link_dir, .{ .is_directory = true });

    var ws = try Workspace.init(allocator, io, root, null);
    defer ws.deinit();
    try std.testing.expectError(WorkspaceError.PathOutsideWorkspace, ws.resolveOutput("outlink/generated.zig"));
}

test "workspace rejects output below missing directory under symlinked parent" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "root");
    try tmp.dir.createDirPath(io, "outside");

    const rel_base = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer allocator.free(rel_base);
    const base_z = try std.Io.Dir.cwd().realPathFileAlloc(io, rel_base, allocator);
    defer allocator.free(base_z);
    const base = base_z[0..];
    const root = try std.fs.path.join(allocator, &.{ base, "root" });
    defer allocator.free(root);
    const outside_dir = try std.fs.path.join(allocator, &.{ base, "outside" });
    defer allocator.free(outside_dir);
    const link_dir = try std.fs.path.join(allocator, &.{ root, "outlink" });
    defer allocator.free(link_dir);

    try std.Io.Dir.symLinkAbsolute(io, outside_dir, link_dir, .{ .is_directory = true });

    var ws = try Workspace.init(allocator, io, root, null);
    defer ws.deinit();
    try std.testing.expectError(WorkspaceError.PathOutsideWorkspace, ws.resolveOutput("outlink/new/generated.zig"));
}

test "workspace rejects existing output symlink outside root" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "root");
    try tmp.dir.createDirPath(io, "outside");
    try tmp.dir.writeFile(io, .{ .sub_path = "outside/generated.zig", .data = "pub const escaped = true;\n" });

    const rel_base = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer allocator.free(rel_base);
    const base_z = try std.Io.Dir.cwd().realPathFileAlloc(io, rel_base, allocator);
    defer allocator.free(base_z);
    const base = base_z[0..];
    const root = try std.fs.path.join(allocator, &.{ base, "root" });
    defer allocator.free(root);
    const outside_file = try std.fs.path.join(allocator, &.{ base, "outside", "generated.zig" });
    defer allocator.free(outside_file);
    const link_file = try std.fs.path.join(allocator, &.{ root, "generated.zig" });
    defer allocator.free(link_file);

    try std.Io.Dir.symLinkAbsolute(io, outside_file, link_file, .{});

    var ws = try Workspace.init(allocator, io, root, null);
    defer ws.deinit();
    try std.testing.expectError(WorkspaceError.PathOutsideWorkspace, ws.resolveOutput("generated.zig"));
}

test "workspace allows output below symlinked parent inside root" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "root/real");

    const rel_base = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer allocator.free(rel_base);
    const base_z = try std.Io.Dir.cwd().realPathFileAlloc(io, rel_base, allocator);
    defer allocator.free(base_z);
    const base = base_z[0..];
    const root = try std.fs.path.join(allocator, &.{ base, "root" });
    defer allocator.free(root);
    const real_dir = try std.fs.path.join(allocator, &.{ root, "real" });
    defer allocator.free(real_dir);
    const link_dir = try std.fs.path.join(allocator, &.{ root, "link" });
    defer allocator.free(link_dir);

    try std.Io.Dir.symLinkAbsolute(io, real_dir, link_dir, .{ .is_directory = true });

    var ws = try Workspace.init(allocator, io, root, null);
    defer ws.deinit();
    const output = try ws.resolveOutput("link/new/generated.zig");
    defer allocator.free(output);
    const expected = try std.fs.path.join(allocator, &.{ real_dir, "new", "generated.zig" });
    defer allocator.free(expected);
    try std.testing.expectEqualStrings(expected, output);
}

test "workspace allows existing output symlink inside root" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "root/real");
    try tmp.dir.writeFile(io, .{ .sub_path = "root/real/generated.zig", .data = "pub const internal = true;\n" });

    const rel_base = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer allocator.free(rel_base);
    const base_z = try std.Io.Dir.cwd().realPathFileAlloc(io, rel_base, allocator);
    defer allocator.free(base_z);
    const base = base_z[0..];
    const root = try std.fs.path.join(allocator, &.{ base, "root" });
    defer allocator.free(root);
    const target_file = try std.fs.path.join(allocator, &.{ root, "real", "generated.zig" });
    defer allocator.free(target_file);
    const link_file = try std.fs.path.join(allocator, &.{ root, "generated.zig" });
    defer allocator.free(link_file);

    try std.Io.Dir.symLinkAbsolute(io, target_file, link_file, .{});

    var ws = try Workspace.init(allocator, io, root, null);
    defer ws.deinit();
    const output = try ws.resolveOutput("generated.zig");
    defer allocator.free(output);
    try std.testing.expectEqualStrings(target_file, output);
}

test "workspace allows output below missing directory under real parent" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "root/safe");

    const rel_base = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer allocator.free(rel_base);
    const base_z = try std.Io.Dir.cwd().realPathFileAlloc(io, rel_base, allocator);
    defer allocator.free(base_z);
    const root = try std.fs.path.join(allocator, &.{ base_z[0..], "root" });
    defer allocator.free(root);

    var ws = try Workspace.init(allocator, io, root, null);
    defer ws.deinit();
    const output = try ws.resolveOutput("safe/new/generated.zig");
    defer allocator.free(output);
    try std.testing.expect(isInside(ws.root, output));
}
