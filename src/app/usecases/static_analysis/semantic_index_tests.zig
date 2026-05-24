const std = @import("std");

const app_context = @import("../../context.zig");
const semantic_index = @import("semantic_index.zig");
const fakes = @import("../../../testing/fakes/root.zig");

fn testContext(
    store_fake: *fakes.FakeWorkspaceStore,
    scanner_fake: *fakes.FakeWorkspaceScanner,
    command_fake: ?*fakes.FakeCommandRunner,
) app_context.StaticAnalysisContext {
    return .{
        .workspace = .{ .root = "/workspace", .cache_root = "/workspace/.zigar-cache" },
        .tool_paths = .{ .zlint = "zlint-bin" },
        .timeouts = .{ .command_ms = 1000 },
        .command_runner = if (command_fake) |fake| fake.port() else null,
        .workspace_store = store_fake.port(),
        .workspace_scanner = scanner_fake.port(),
    };
}

test "semantic index builds declarations imports and tests through static ports" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var store_fake = fakes.FakeWorkspaceStore.init(std.testing.allocator);
    defer store_fake.deinit();
    var scanner_fake = fakes.FakeWorkspaceScanner.init(std.testing.allocator);
    defer scanner_fake.deinit();

    try scanner_fake.expectScan(.{ .max_files = 10, .provenance = "static_analysis.semantic_index" }, &.{"src/main.zig"});
    try store_fake.expectRead(.{ .path = "src/main.zig", .max_bytes = semantic_index.default_source_read_limit, .provenance = "static_analysis.semantic_index" },
        \\const std = @import("std");
        \\pub fn main() void {}
        \\test "main" {}
    );

    const value = try semantic_index.semanticIndexValue(arena.allocator(), testContext(&store_fake, &scanner_fake, null), 10, "zig_semantic_index_build");

    try std.testing.expectEqualStrings("zigar.semantic_index", value.object.get("format").?.string);
    try std.testing.expectEqual(@as(i64, 1), value.object.get("file_count").?.integer);
    try std.testing.expect(value.object.get("declaration_count").?.integer >= 1);
    try std.testing.expectEqual(@as(i64, 1), value.object.get("import_count").?.integer);
    try std.testing.expectEqual(@as(i64, 1), value.object.get("test_count").?.integer);
    try scanner_fake.verify();
    try store_fake.verify();
}

test "semantic references use workspace scan and zlint AST confirmation when available" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var store_fake = fakes.FakeWorkspaceStore.init(std.testing.allocator);
    defer store_fake.deinit();
    var scanner_fake = fakes.FakeWorkspaceScanner.init(std.testing.allocator);
    defer scanner_fake.deinit();
    var command_fake = fakes.FakeCommandRunner.init(std.testing.allocator);
    defer command_fake.deinit();

    try scanner_fake.expectScan(.{ .max_files = null, .provenance = "static_analysis.semantic_refs" }, &.{"src/main.zig"});
    try store_fake.expectRead(.{ .path = "src/main.zig", .max_bytes = semantic_index.default_source_read_limit, .provenance = "static_analysis.semantic_refs" },
        \\fn helper() void {}
        \\pub fn main() void {
        \\    helper();
        \\}
    );
    try store_fake.expectResolve(.{ .path = "src/main.zig", .provenance = "static_analysis.zlint_ast" }, "/workspace/src/main.zig");
    try command_fake.expectRun(.{
        .argv = &.{ "zlint-bin", "--print-ast", "/workspace/src/main.zig" },
        .cwd = "/workspace",
        .timeout_ms = 250,
        .provenance = "static_analysis.zlint_ast",
    }, .{
        .stdout = "{\"symbols\":[{\"name\":\"helper\",\"references\":[{\"flags\":[\"call\"]}]}]}",
    });

    const value = try semantic_index.sourceRefs(arena.allocator(), testContext(&store_fake, &scanner_fake, &command_fake), .{
        .symbol = "helper",
        .calls_only = true,
        .limit = 10,
        .timeout_ms = 250,
    });

    const callers = value.object.get("callers").?.array.items;
    try std.testing.expectEqual(@as(i64, 1), value.object.get("count").?.integer);
    try std.testing.expectEqualStrings("zlint", callers[0].object.get("source").?.string);
    try std.testing.expect(callers[0].object.get("semantic_confirmed").?.bool);
    try std.testing.expectEqual(@as(i64, 1), value.object.get("zlint_ast_files").?.integer);
    try scanner_fake.verify();
    try store_fake.verify();
    try command_fake.verify();
}
