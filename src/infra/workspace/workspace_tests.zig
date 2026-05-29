const std = @import("std");
const builtin = @import("builtin");
const workspace_mod = @import("workspace.zig");

const Workspace = workspace_mod.Workspace;
const WorkspaceError = workspace_mod.WorkspaceError;
const isInside = workspace_mod.isInside;

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
        .cache_root = "/tmp/project/.zigars-cache",
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
    const cache_link = try std.fs.path.join(allocator, &.{ root, ".zigars-cache" });
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

test "workspace readFileAlloc follows an inside symlink but rejects an outside one" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

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
    const inside_target = try std.fs.path.join(allocator, &.{ root, "src", "main.zig" });
    defer allocator.free(inside_target);
    const outside_target = try std.fs.path.join(allocator, &.{ base, "outside", "evil.zig" });
    defer allocator.free(outside_target);
    const inside_link = try std.fs.path.join(allocator, &.{ root, "inside-link.zig" });
    defer allocator.free(inside_link);
    const outside_link = try std.fs.path.join(allocator, &.{ root, "outside-link.zig" });
    defer allocator.free(outside_link);

    try std.Io.Dir.symLinkAbsolute(io, inside_target, inside_link, .{});
    try std.Io.Dir.symLinkAbsolute(io, outside_target, outside_link, .{});

    var ws = try Workspace.init(allocator, io, root, null);
    defer ws.deinit();

    // Currently-correct behavior preserved: a symlink resolving inside the root
    // is read through to its canonical target.
    const inside_bytes = try ws.readFileAlloc(io, "inside-link.zig", 4096);
    defer allocator.free(inside_bytes);
    try std.testing.expectEqualStrings("pub const internal = true;\n", inside_bytes);

    // An outside-pointing symlink must never yield the outside file's contents.
    try std.testing.expectError(WorkspaceError.PathOutsideWorkspace, ws.readFileAlloc(io, "outside-link.zig", 4096));
}

test "workspace writeFile does not clobber through an outside symlink" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "root");
    try tmp.dir.createDirPath(io, "outside");
    try tmp.dir.writeFile(io, .{ .sub_path = "outside/secret.txt", .data = "original\n" });

    const rel_base = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer allocator.free(rel_base);
    const base_z = try std.Io.Dir.cwd().realPathFileAlloc(io, rel_base, allocator);
    defer allocator.free(base_z);
    const base = base_z[0..];
    const root = try std.fs.path.join(allocator, &.{ base, "root" });
    defer allocator.free(root);
    const outside_target = try std.fs.path.join(allocator, &.{ base, "outside", "secret.txt" });
    defer allocator.free(outside_target);
    const link_file = try std.fs.path.join(allocator, &.{ root, "report.txt" });
    defer allocator.free(link_file);

    // A pre-existing final-component symlink inside the root that points out.
    try std.Io.Dir.symLinkAbsolute(io, outside_target, link_file, .{});

    var ws = try Workspace.init(allocator, io, root, null);
    defer ws.deinit();

    // The resolved output canonicalizes the symlink and rejects it; the write
    // must not reach the outside file.
    try std.testing.expectError(WorkspaceError.PathOutsideWorkspace, ws.writeFile(io, "report.txt", "overwritten\n"));

    // The outside file is untouched.
    const after = try std.Io.Dir.cwd().readFileAlloc(io, outside_target, allocator, .limited(4096));
    defer allocator.free(after);
    try std.testing.expectEqualStrings("original\n", after);
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
