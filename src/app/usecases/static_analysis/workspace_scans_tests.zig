const std = @import("std");

const app_context = @import("../../context.zig");
const usecase = @import("workspace_scans.zig");
const fakes = @import("../../../testing/fakes/root.zig");

test "import graph scan uses scanner and workspace reads" {
    var fake_scanner = fakes.FakeWorkspaceScanner.init(std.testing.allocator);
    defer fake_scanner.deinit();
    var fake_workspace = fakes.FakeWorkspaceStore.init(std.testing.allocator);
    defer fake_workspace.deinit();

    try fake_scanner.expectScan(.{
        .path_prefix = "",
        .max_files = 3,
        .provenance = "static_analysis.import_graph",
    }, &.{ "src/main.zig", "src/lib.zig", "src/unreadable.zig" });
    try fake_workspace.expectRead(.{
        .path = "src/main.zig",
        .max_bytes = usecase.default_source_read_limit,
        .provenance = "static_analysis.import_graph",
    }, "const a = @import(\"std\");\n");
    try fake_workspace.expectRead(.{
        .path = "src/lib.zig",
        .max_bytes = usecase.default_source_read_limit,
        .provenance = "static_analysis.import_graph",
    }, "pub fn x() void {}\n");
    try fake_workspace.expectReadError(.{
        .path = "src/unreadable.zig",
        .max_bytes = usecase.default_source_read_limit,
        .provenance = "static_analysis.import_graph",
    }, error.AccessDenied);

    const ctx = app_context.StaticAnalysisContext{
        .workspace = .{ .root = "/workspace" },
        .workspace_store = fake_workspace.port(),
        .workspace_scanner = fake_scanner.port(),
    };

    var graph = try usecase.importGraph(std.testing.allocator, ctx, .{ .limit = 3 });
    defer graph.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), graph.files.len);
    try std.testing.expectEqual(@as(usize, 1), graph.files[0].imports.len);
    try std.testing.expectEqualStrings("std", graph.files[0].imports[0].import);
    try std.testing.expectEqual(@as(usize, 1), graph.skipped_files.len);
    const text = try usecase.importGraphText(std.testing.allocator, graph);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "- no string-literal imports found") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Skipped unreadable files: 1") != null);
    try fake_scanner.verify();
    try fake_workspace.verify();
}

test "test discover extracts test declarations and preserves skipped file errors" {
    var fake_scanner = fakes.FakeWorkspaceScanner.init(std.testing.allocator);
    defer fake_scanner.deinit();
    var fake_workspace = fakes.FakeWorkspaceStore.init(std.testing.allocator);
    defer fake_workspace.deinit();

    try fake_scanner.expectScan(.{
        .path_prefix = "",
        .max_files = 10,
        .provenance = "static_analysis.test_discover",
    }, &.{ "src/main.zig", "src/fail.zig" });
    try fake_workspace.expectRead(.{
        .path = "src/main.zig",
        .max_bytes = usecase.default_source_read_limit,
        .provenance = "static_analysis.test_discover",
    }, "test \"ok\" { }\n");
    try fake_workspace.expectReadError(.{
        .path = "src/fail.zig",
        .max_bytes = usecase.default_source_read_limit,
        .provenance = "static_analysis.test_discover",
    }, error.Unavailable);

    const ctx = app_context.StaticAnalysisContext{
        .workspace = .{ .root = "/workspace" },
        .workspace_store = fake_workspace.port(),
        .workspace_scanner = fake_scanner.port(),
    };

    var tests = try usecase.testDiscover(std.testing.allocator, ctx, .{ .limit = 10 });
    defer tests.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), tests.tests.len);
    try std.testing.expectEqualStrings("test \"ok\" { }", tests.tests[0].declaration);
    try std.testing.expectEqual(@as(usize, 1), tests.skipped_files.len);
    try std.testing.expectEqualStrings("Unavailable", tests.skipped_files[0].error_name);
}

test "import graph text output preserves advisory header" {
    var imports = try std.testing.allocator.alloc(usecase.ImportEdge, 1);
    defer std.testing.allocator.free(imports);
    imports[0] = .{ .import = try std.testing.allocator.dupe(u8, "std") };
    defer std.testing.allocator.free(imports[0].import);

    var files = try std.testing.allocator.alloc(usecase.ImportFile, 1);
    defer std.testing.allocator.free(files);
    files[0] = .{
        .file = try std.testing.allocator.dupe(u8, "src/main.zig"),
        .imports = imports,
    };
    defer std.testing.allocator.free(files[0].file);

    const skipped = try std.testing.allocator.alloc(usecase.SkippedFile, 0);
    defer std.testing.allocator.free(skipped);
    const result = usecase.ImportGraphResult{ .files = files, .skipped_files = skipped };
    const text = try usecase.importGraphText(std.testing.allocator, result);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "# Import graph") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "## src/main.zig") != null);
}
