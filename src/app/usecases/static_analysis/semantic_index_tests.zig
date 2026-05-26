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

test "semantic index records skipped reads and heuristic declarations for partial parses" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var store_fake = fakes.FakeWorkspaceStore.init(std.testing.allocator);
    defer store_fake.deinit();
    var scanner_fake = fakes.FakeWorkspaceScanner.init(std.testing.allocator);
    defer scanner_fake.deinit();

    try scanner_fake.expectScan(.{ .max_files = 5, .provenance = "static_analysis.semantic_index" }, &.{ "src/missing.zig", "src/broken.zig" });
    try store_fake.expectReadError(.{ .path = "src/missing.zig", .max_bytes = semantic_index.default_source_read_limit, .provenance = "static_analysis.semantic_index" }, error.FileNotFound);
    try store_fake.expectRead(.{ .path = "src/broken.zig", .max_bytes = semantic_index.default_source_read_limit, .provenance = "static_analysis.semantic_index" },
        \\pub fn fallback() void {
    );

    const value = try semantic_index.semanticIndexValue(arena.allocator(), testContext(&store_fake, &scanner_fake, null), 5, "zig_semantic_index_build");

    try std.testing.expect(value.object.get("partial_result").?.bool);
    try std.testing.expectEqual(@as(i64, 1), value.object.get("skipped_file_count").?.integer);
    try std.testing.expectEqual(@as(i64, 1), value.object.get("file_count").?.integer);
    const decl = value.object.get("declarations").?.array.items[0].object;
    try std.testing.expectEqualStrings("fallback", decl.get("name").?.string);
    try std.testing.expectEqualStrings("heuristic", decl.get("source").?.string);
    const skipped = value.object.get("skipped_files").?.array.items[0].object;
    try std.testing.expectEqualStrings("FileNotFound", skipped.get("error").?.string);
    try scanner_fake.verify();
    try store_fake.verify();
}

test "semantic export applies a cache-hit index write through the workspace port" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var store_fake = fakes.FakeWorkspaceStore.init(std.testing.allocator);
    defer store_fake.deinit();
    var scanner_fake = fakes.FakeWorkspaceScanner.init(std.testing.allocator);
    defer scanner_fake.deinit();
    var cache_fake = fakes.FakeStaticCache.init(std.testing.allocator);
    defer cache_fake.deinit();

    const source = "pub fn main() void {}\n";
    var hasher = std.hash.Wyhash.init(semantic_index.semantic_format_version);
    hasher.update("src/main.zig");
    hasher.update(source);
    try cache_fake.seed(hasher.final(), "null");

    try scanner_fake.expectScan(.{ .max_files = 1, .provenance = "static_analysis.semantic_signature" }, &.{"src/main.zig"});
    try store_fake.expectRead(.{ .path = "src/main.zig", .max_bytes = semantic_index.default_source_read_limit, .provenance = "static_analysis.semantic_signature" }, source);
    const expected =
        \\{"kind":"zig_semantic_export","format":"json","format_version":1,"index":null}
    ;
    try store_fake.expectWrite(.{
        .path = ".zigar-cache/semantic.json",
        .bytes = expected,
        .provenance = "static_analysis.semantic_export",
    }, .{ .bytes_written = expected.len });

    var context = testContext(&store_fake, &scanner_fake, null);
    context.semantic_index_cache = cache_fake.port();
    const value = try semantic_index.exportIndex(arena.allocator(), context, .{
        .tool_name = "zig_semantic_export",
        .format = "json",
        .output = ".zigar-cache/semantic.json",
        .limit = 1,
        .apply = true,
    });

    try std.testing.expect(value.object.get("wrote").?.bool);
    try std.testing.expectEqual(@as(usize, 1), cache_fake.load_calls);
    try std.testing.expectEqual(@as(usize, 1), cache_fake.hits);
    try scanner_fake.verify();
    try store_fake.verify();
}

test "semantic fusion combines cached parser matches with lint evidence" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var store_fake = fakes.FakeWorkspaceStore.init(std.testing.allocator);
    defer store_fake.deinit();
    var scanner_fake = fakes.FakeWorkspaceScanner.init(std.testing.allocator);
    defer scanner_fake.deinit();
    var cache_fake = fakes.FakeStaticCache.init(std.testing.allocator);
    defer cache_fake.deinit();

    const source = "pub const Widget = struct {};\n";
    var hasher = std.hash.Wyhash.init(semantic_index.semantic_format_version);
    hasher.update("src/widget.zig");
    hasher.update(source);
    try cache_fake.seed(hasher.final(),
        \\{"declarations":[{"file":"src/widget.zig","name":"Widget","signature":"pub const Widget = struct {};"}],"imports":[],"tests":[]}
    );
    try scanner_fake.expectScan(.{ .max_files = 3, .provenance = "static_analysis.semantic_signature" }, &.{"src/widget.zig"});
    try store_fake.expectRead(.{ .path = "src/widget.zig", .max_bytes = semantic_index.default_source_read_limit, .provenance = "static_analysis.semantic_signature" }, source);

    var context = testContext(&store_fake, &scanner_fake, null);
    context.semantic_index_cache = cache_fake.port();
    const value = try semantic_index.staticFusion(arena.allocator(), context, .{
        .query = "Widget",
        .index_limit = 3,
        .match_limit = 5,
        .zlint_findings =
        \\[{"rule":"zlint.widget","severity":"warning","path":"src/widget.zig","line":1,"message":"Widget warning"}]
        ,
        .zwanzig_findings =
        \\{"results":[{"code":"zwanzig.widget","level":"error","location":{"path":"src/widget.zig","line":"1","column":"1"},"detail":"Widget error"}]}
        ,
    });

    try std.testing.expect(value.object.get("consensus").?.bool);
    try std.testing.expectEqualStrings("high", value.object.get("confidence").?.string);
    const evidence = value.object.get("lint_evidence").?.object;
    try std.testing.expectEqual(@as(i64, 1), evidence.get("zlint_related_count").?.integer);
    try std.testing.expectEqual(@as(i64, 1), evidence.get("zwanzig_related_count").?.integer);
    try scanner_fake.verify();
    try store_fake.verify();
}
