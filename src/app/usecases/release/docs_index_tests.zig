const std = @import("std");

const app_context = @import("../../context.zig");
const docs_index = @import("docs_index.zig");
const docs_domain = @import("../../../domain/release/docs_index.zig");
const fakes = @import("../../../testing/fakes/root.zig");

test "docs query uses scanner paths and workspace reads through ports" {
    const allocator = std.testing.allocator;
    var workspace = fakes.FakeWorkspaceStore.init(allocator);
    defer workspace.deinit();
    var toolchain = fakes.FakeToolchainEnv.init(allocator);
    defer toolchain.deinit();
    var scanner = fakes.FakeDocsScanner.init(allocator);
    defer scanner.deinit();

    try scanner.expectWorkspaceScan(.{ .max_files = docs_domain.default_path_scan_limit, .provenance = "release_docs.workspace_docs_scan" }, &.{"README.md"});
    try workspace.expectRead(.{ .path = "README.md", .max_bytes = docs_domain.std_source_read_limit, .provenance = "release_docs.workspace_docs_read" }, "# zigar\nFixtureSymbol docs\n");

    const ctx = app_context.ReleaseDocsContext{
        .workspace = .{ .root = "/workspace" },
        .tool_paths = .{},
        .timeouts = .{},
        .workspace_store = workspace.port(),
        .toolchain_env = toolchain.port(),
        .docs_scanner = scanner.port(),
    };
    var result = try docs_index.docsQuery(allocator, ctx, "FixtureSymbol", "workspace", null, 20);
    defer result.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), result.matches.len);
    try std.testing.expectEqualStrings("README.md", result.matches[0].path);
    try workspace.verify();
    try scanner.verify();
}
