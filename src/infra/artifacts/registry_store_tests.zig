const std = @import("std");
const registry_store = @import("registry_store.zig");
const artifacts = @import("registry.zig");
const workspace_mod = @import("../workspace/workspace.zig");

const Store = registry_store.Store;

/// Replays an artifact store operation until the failing allocator stops injecting errors.
fn exerciseAllocationFailures(comptime operation: fn (std.mem.Allocator) anyerror!void) !void {
    var saw_out_of_memory = false;
    for (0..64) |fail_index| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        operation(failing.allocator()) catch |err| {
            std.debug.assert(err == error.OutOfMemory or err == error.Unavailable);
            if (err == error.OutOfMemory) saw_out_of_memory = true;
            continue;
        };
    }
    try std.testing.expect(saw_out_of_memory);
}

/// Writes an artifact using the supplied test allocator.
fn putArtifactWithAllocator(operation_allocator: std.mem.Allocator) !void {
    const setup_allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "root");
    const base = try std.fs.path.join(setup_allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..], "root" });
    defer setup_allocator.free(base);
    const root = try std.Io.Dir.cwd().realPathFileAlloc(io, base, setup_allocator);
    defer setup_allocator.free(root);

    var workspace = try workspace_mod.Workspace.init(setup_allocator, io, root, null);
    defer workspace.deinit();
    var store = Store.init(&workspace, io, .{ .zig_path = "zig" });

    const ref = try store.port().put(operation_allocator, .{
        .namespace = "reports",
        .name = "summary.json",
        .kind = "json_report",
        .bytes = "{\"ok\":true}\n",
        .provenance = "allocation-test",
    });
    defer ref.deinit(operation_allocator);
}

/// Records a workspace artifact using the supplied test allocator.
fn recordWorkspaceWithAllocator(operation_allocator: std.mem.Allocator) !void {
    const setup_allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "root/zig-out");
    try tmp.dir.writeFile(io, .{ .sub_path = "root/zig-out/report.txt", .data = "existing artifact\n" });
    const base = try std.fs.path.join(setup_allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..], "root" });
    defer setup_allocator.free(base);
    const root = try std.Io.Dir.cwd().realPathFileAlloc(io, base, setup_allocator);
    defer setup_allocator.free(root);

    var workspace = try workspace_mod.Workspace.init(setup_allocator, io, root, null);
    defer workspace.deinit();
    var store = Store.init(&workspace, io, .{ .zig_path = "zig" });

    const ref = try store.port().recordWorkspace(operation_allocator, .{
        .path = "zig-out/report.txt",
        .producer = "allocation-test",
        .artifact_kind = "text",
        .toolchain = .{ .zig_path = "zig" },
    });
    defer ref.deinit(operation_allocator);
}

test "artifact registry store writes reads and records provenance" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "root");
    const base = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..], "root" });
    defer allocator.free(base);
    const root = try std.Io.Dir.cwd().realPathFileAlloc(io, base, allocator);
    defer allocator.free(root);

    var workspace = try workspace_mod.Workspace.init(allocator, io, root, null);
    defer workspace.deinit();
    var store = Store.init(&workspace, io, .{ .zig_path = "zig", .zls_path = "zls", .zflame_path = "zflame", .diff_folded_path = "diff-folded" });

    const ref = try store.port().put(allocator, .{
        .namespace = "reports",
        .name = "summary.json",
        .kind = "json_report",
        .bytes = "{\"ok\":true}\n",
        .provenance = "artifact_test",
    });
    defer ref.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 12), ref.bytes_written);
    try std.testing.expectEqualStrings(".zigars-cache/artifacts/reports/summary.json", ref.id);

    const read_result = try store.port().read(allocator, .{ .id = ref.id });
    defer read_result.deinit(allocator);
    try std.testing.expectEqualStrings("{\"ok\":true}\n", read_result.bytes);

    const registry_abs = try workspace.resolveOutput(artifacts.default_registry_path);
    defer workspace.allocator.free(registry_abs);
    var registry = try artifacts.loadRegistry(allocator, io, registry_abs);
    defer registry.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), registry.entries.items.len);
    try std.testing.expectEqualStrings(ref.id, registry.entries.items[0].path);
    try std.testing.expectEqualStrings("artifact_test", registry.entries.items[0].producer);
    try std.testing.expectEqualStrings("json_report", registry.entries.items[0].artifact_kind);
    try std.testing.expectEqualStrings(ref.checksum.?, registry.entries.items[0].sha256);
}

test "artifact registry store rejects path traversal names" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "root");
    const base = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..], "root" });
    defer allocator.free(base);
    const root = try std.Io.Dir.cwd().realPathFileAlloc(io, base, allocator);
    defer allocator.free(root);

    var workspace = try workspace_mod.Workspace.init(allocator, io, root, null);
    defer workspace.deinit();
    var store = Store.init(&workspace, io, .{ .zig_path = "zig" });

    try std.testing.expectError(error.InvalidRequest, store.port().put(allocator, .{
        .namespace = "reports",
        .name = "../escape.json",
        .kind = "json_report",
        .bytes = "{}",
    }));
}

test "artifact registry store read is scoped to artifact ids" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "root/src");
    try tmp.dir.writeFile(io, .{ .sub_path = "root/src/main.zig", .data = "pub const not_artifact = true;\n" });
    const base = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..], "root" });
    defer allocator.free(base);
    const root = try std.Io.Dir.cwd().realPathFileAlloc(io, base, allocator);
    defer allocator.free(root);

    var workspace = try workspace_mod.Workspace.init(allocator, io, root, null);
    defer workspace.deinit();
    var store = Store.init(&workspace, io, .{ .zig_path = "zig" });

    const ref = try store.port().put(allocator, .{
        .namespace = "reports",
        .name = "scoped.txt",
        .kind = "text",
        .bytes = "artifact bytes",
        .provenance = "artifact_read_scope_test",
    });
    defer ref.deinit(allocator);
    const read_result = try store.port().read(allocator, .{ .id = ref.id });
    defer read_result.deinit(allocator);
    try std.testing.expectEqualStrings("artifact bytes", read_result.bytes);

    try std.testing.expectError(error.InvalidRequest, store.port().read(allocator, .{ .id = "src/main.zig" }));
    try std.testing.expectError(error.InvalidRequest, store.port().read(allocator, .{ .id = ".zigars-cache/artifacts/reports/../escape.txt" }));
    try std.testing.expectError(error.InvalidRequest, store.port().read(allocator, .{ .id = "/tmp/escape.txt" }));
}

test "artifact registry store maps upsert allocation failures" {
    try exerciseAllocationFailures(putArtifactWithAllocator);
    try exerciseAllocationFailures(recordWorkspaceWithAllocator);
}
