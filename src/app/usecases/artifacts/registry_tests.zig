const std = @import("std");

const app_context = @import("../../context.zig");
const fakes = @import("../../../testing/fakes/root.zig");
const registry = @import("registry.zig");

test "artifact read uses input workspace reads and returns identity" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var fake = fakes.workspace_store.FakeWorkspaceStore.init(std.testing.allocator);
    defer fake.deinit();

    try fake.expectResolve(.{
        .path = "zig-out/report.txt",
        .for_output = false,
        .provenance = "artifacts.read.resolve",
    }, "/workspace/zig-out/report.txt");
    try fake.expectRead(.{
        .path = "zig-out/report.txt",
        .max_bytes = 1024,
        .for_output = false,
        .provenance = "artifacts.read.content",
    }, "report\n");

    const context = app_context.ArtifactContext{
        .workspace = .{ .root = "/workspace" },
        .workspace_store = fake.port(),
    };
    const result = try registry.readArtifact(allocator, context, "zig-out/report.txt", 1024);
    try std.testing.expectEqualStrings("zig-out/report.txt", result.path);
    try std.testing.expectEqualStrings("/workspace/zig-out/report.txt", result.abs_path);
    try std.testing.expectEqual(@as(usize, 7), result.bytes);
    try std.testing.expectEqualStrings("report\n", result.content);
    try fake.verify();
}

test "artifact prune previews stale records through workspace ports" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var fake = fakes.workspace_store.FakeWorkspaceStore.init(std.testing.allocator);
    defer fake.deinit();

    const kept_hash = try registry.sha256Hex(allocator, "kept");
    const missing_hash = try registry.sha256Hex(allocator, "missing");
    const registry_bytes = try std.fmt.allocPrint(allocator,
        \\{{"path":"zig-out/kept.txt","abs_path":"/workspace/zig-out/kept.txt","bytes":4,"sha256":"{s}","indexed_at_unix_ms":1,"provenance":{{"producer":"fixture","artifact_kind":"text","toolchain":{{"zig_path":"zig"}}}}}}
        \\{{"path":"zig-out/missing.txt","abs_path":"/workspace/zig-out/missing.txt","bytes":7,"sha256":"{s}","indexed_at_unix_ms":1,"provenance":{{"producer":"fixture","artifact_kind":"text","toolchain":{{"zig_path":"zig"}}}}}}
        \\
    , .{ kept_hash, missing_hash });
    try fake.expectRead(.{
        .path = registry.default_registry_path,
        .max_bytes = registry.max_registry_bytes,
        .for_output = true,
        .provenance = "artifacts.registry.load",
    }, registry_bytes);
    try fake.expectRead(.{
        .path = "zig-out/kept.txt",
        .max_bytes = 5,
        .for_output = false,
        .provenance = "artifacts.prune.verify",
    }, "kept");
    try fake.expectReadError(.{
        .path = "zig-out/missing.txt",
        .max_bytes = 8,
        .for_output = false,
        .provenance = "artifacts.prune.verify",
    }, error.FileNotFound);

    const context = app_context.ArtifactContext{
        .workspace = .{ .root = "/workspace" },
        .workspace_store = fake.port(),
    };
    const loaded = try registry.readRegistrySnapshot(allocator, context);
    const result = try registry.pruneStale(allocator, context, loaded);
    try std.testing.expectEqual(@as(usize, 1), result.summary.kept);
    try std.testing.expectEqual(@as(usize, 1), result.summary.missing);
    try std.testing.expectEqual(@as(usize, 1), result.summary.pruned);
    try std.testing.expectEqual(@as(usize, 1), result.entries.len);
    try std.testing.expectEqualStrings("zig-out/kept.txt", result.entries[0].path);
    try fake.verify();
}
