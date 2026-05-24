const std = @import("std");

const app_context = @import("../../context.zig");
const project_values = @import("project_values.zig");
const workspace_store_fake = @import("../../../testing/fakes/workspace_store.zig");
const workspace_scanner_fake = @import("../../../testing/fakes/workspace_scanner.zig");

fn testContext(
    store_fake: *workspace_store_fake.FakeWorkspaceStore,
    scanner_fake: *workspace_scanner_fake.FakeWorkspaceScanner,
) app_context.StaticAnalysisContext {
    return .{
        .workspace = .{ .root = "/workspace", .cache_root = "/workspace/.zigar-cache" },
        .workspace_store = store_fake.port(),
        .workspace_scanner = scanner_fake.port(),
    };
}

test "typed build workspace value reads build files through workspace port" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var store_fake = workspace_store_fake.FakeWorkspaceStore.init(std.testing.allocator);
    defer store_fake.deinit();
    var scanner_fake = workspace_scanner_fake.FakeWorkspaceScanner.init(std.testing.allocator);
    defer scanner_fake.deinit();

    try store_fake.expectRead(.{ .path = "build.zig", .max_bytes = project_values.default_build_read_limit, .provenance = "static_analysis.build_graph" },
        \\const mod = b.addModule("root", .{ .root_source_file = b.path("src/main.zig") });
    );
    try store_fake.expectRead(.{ .path = "build.zig.zon", .max_bytes = project_values.default_build_read_limit, .provenance = "static_analysis.build_graph" },
        \\.{
        \\    .dependencies = .{
        \\        .foo = .{ .url = "https://example.invalid/foo.tar.gz", .hash = "abc" },
        \\    },
        \\}
    );

    const value = try project_values.buildWorkspaceValue(arena.allocator(), testContext(&store_fake, &scanner_fake));
    try std.testing.expect(value.object.get("build_zig").? == .object);
    try std.testing.expect(value.object.get("build_zig_zon").? == .object);
    try store_fake.verify();
}

test "typed test map scans and reads through static ports" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var store_fake = workspace_store_fake.FakeWorkspaceStore.init(std.testing.allocator);
    defer store_fake.deinit();
    var scanner_fake = workspace_scanner_fake.FakeWorkspaceScanner.init(std.testing.allocator);
    defer scanner_fake.deinit();

    try scanner_fake.expectScan(.{ .max_files = null, .provenance = "static_analysis.test_map" }, &.{"src/main.zig"});
    try store_fake.expectRead(.{ .path = "src/main.zig", .max_bytes = project_values.default_source_read_limit, .provenance = "static_analysis.test_map" },
        \\test "Build Graph" {}
    );

    const value = try project_values.testMapValue(arena.allocator(), testContext(&store_fake, &scanner_fake), 10);
    try std.testing.expectEqual(@as(i64, 1), value.object.get("count").?.integer);
    try scanner_fake.verify();
    try store_fake.verify();
}

test "typed dependency inspection checks cache path through workspace exists port" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var store_fake = workspace_store_fake.FakeWorkspaceStore.init(std.testing.allocator);
    defer store_fake.deinit();
    var scanner_fake = workspace_scanner_fake.FakeWorkspaceScanner.init(std.testing.allocator);
    defer scanner_fake.deinit();

    try store_fake.expectResolveError(.{ .path = "zig-pkg", .provenance = "static_analysis.cache_path_status" }, error.PathOutsideWorkspace);
    try store_fake.expectResolve(.{ .path = "zig-pkg", .for_output = true, .provenance = "static_analysis.cache_path_status" }, "/workspace/zig-pkg");
    try store_fake.expectExists(.{ .path = "zig-pkg", .for_output = true, .provenance = "static_analysis.cache_path_status" }, .{ .exists = true, .kind = .directory, .entry_count = 2 });

    const value = try project_values.dependencyInspectionValue(arena.allocator(), testContext(&store_fake, &scanner_fake),
        \\.{
        \\    .dependencies = .{
        \\        .foo = .{
        \\            .url = "https://example.invalid/foo.tar.gz",
        \\        },
        \\    },
        \\}
    );
    try std.testing.expectEqual(@as(i64, 1), value.object.get("dependency_count").?.integer);
    try std.testing.expectEqual(@as(usize, 1), value.object.get("issues").?.array.items.len);
    try store_fake.verify();
}

test "typed test failure triage preserves compiler and test clues" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const value = try project_values.testFailureTriageValue(
        arena.allocator(),
        "src/main.zig:1:1: error: expected type\nFAIL expected 1 actual 2\n",
        "",
        &.{ "zig", "test" },
        false,
    );

    try std.testing.expectEqual(@as(usize, 1), value.object.get("failures").?.array.items.len);
    try std.testing.expectEqual(@as(usize, 2), value.object.get("expected_actual").?.array.items.len);
    try std.testing.expect(value.object.get("compile_diagnostics").? == .object);
}

test "typed helper names and lowercase preserve stable parsing behavior" {
    try std.testing.expectEqualStrings("main", project_values.declName("pub fn main() void {}", "fn").?);
    try std.testing.expectEqualStrings("Thing", project_values.declName("const Thing = struct {}", "const").?);

    const lower = try project_values.asciiLowerAllocLocal(std.testing.allocator, "Build-Test");
    defer std.testing.allocator.free(lower);
    try std.testing.expectEqualStrings("build-test", lower);
}

test "typed workspace path exists uses workspace exists port" {
    var store_fake = workspace_store_fake.FakeWorkspaceStore.init(std.testing.allocator);
    defer store_fake.deinit();
    var scanner_fake = workspace_scanner_fake.FakeWorkspaceScanner.init(std.testing.allocator);
    defer scanner_fake.deinit();

    try store_fake.expectExists(.{ .path = "build.zig", .provenance = "static_analysis.workspace_path_exists" }, .{ .exists = true, .kind = .file });

    try std.testing.expect(project_values.workspacePathExists(std.testing.allocator, testContext(&store_fake, &scanner_fake), "build.zig"));
    try store_fake.verify();
}
