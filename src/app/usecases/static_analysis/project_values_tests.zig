const std = @import("std");

const app_context = @import("../../context.zig");
const project_values = @import("project_values.zig");
const command_runner_fake = @import("../../../testing/fakes/command_runner.zig");
const static_cache_fake = @import("../../../testing/fakes/static_cache.zig");
const workspace_store_fake = @import("../../../testing/fakes/workspace_store.zig");
const workspace_scanner_fake = @import("../../../testing/fakes/workspace_scanner.zig");

/// Returns a typed context backed by this fixture or runtime state.
fn testContext(
    store_fake: *workspace_store_fake.FakeWorkspaceStore,
    scanner_fake: *workspace_scanner_fake.FakeWorkspaceScanner,
) app_context.StaticAnalysisContext {
    return .{
        .workspace = .{ .root = "/workspace", .cache_root = "/workspace/.zigars-cache" },
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

test "typed build graph projections cover targets options owners and import resolution" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const build_zig =
        \\const target = b.standardTargetOptions(.{});
        \\const optimize = b.standardOptimizeOption(.{});
        \\const feature = b.option(bool, "feature", "enable feature");
        \\const mod = b.addModule("root", .{ .root_source_file = b.path("src/root.zig") });
        \\const exe = b.addExecutable(.{ .name = "app", .root_source_file = b.path("src/main.zig") });
        \\const tests = b.addTest(.{ .root_source_file = b.path("src/main_test.zig") });
        \\exe.root_module.addImport("root", mod);
        \\const smoke = b.step("smoke", "Run smoke");
        \\
    ;
    const build_zon =
        \\.{
        \\    .dependencies = .{
        \\        .foo = .{ .url = "https://example.invalid/foo.tar.gz", .hash = "abc" },
        \\    },
        \\    .paths = .{
        \\        "src/root.zig",
        \\    },
        \\}
    ;

    var store_fake = workspace_store_fake.FakeWorkspaceStore.init(std.testing.allocator);
    defer store_fake.deinit();
    var scanner_fake = workspace_scanner_fake.FakeWorkspaceScanner.init(std.testing.allocator);
    defer scanner_fake.deinit();

    try expectBuildGraphReads(&store_fake, build_zig, build_zon);
    const targets = try project_values.buildTargetsValue(allocator, testContext(&store_fake, &scanner_fake));
    try std.testing.expect(targets.object.get("modules").?.array.items.len >= 1);
    try std.testing.expect(targets.object.get("artifacts").?.array.items.len >= 1);
    try std.testing.expect(targets.object.get("commands").?.array.items.len >= 3);

    try store_fake.expectRead(.{ .path = "build.zig", .max_bytes = project_values.default_build_read_limit, .provenance = "static_analysis.build_options" }, build_zig);
    const options = try project_values.buildOptionsValue(allocator, testContext(&store_fake, &scanner_fake));
    try std.testing.expectEqualStrings("zig_build_options", options.object.get("kind").?.string);
    try std.testing.expect(options.object.get("options").?.array.items.len >= 3);

    try store_fake.expectResolve(.{ .path = "src/root.zig", .provenance = "static_analysis.file_owner" }, "/workspace/src/root.zig");
    try expectBuildGraphReads(&store_fake, build_zig, build_zon);
    const owner = try project_values.fileOwnerForPathValue(allocator, testContext(&store_fake, &scanner_fake), "src/root.zig");
    try std.testing.expectEqualStrings("high", owner.object.get("owner_match_confidence").?.string);

    try expectBuildGraphReads(&store_fake, build_zig, build_zon);
    const graph = try project_values.buildWorkspaceValue(allocator, testContext(&store_fake, &scanner_fake));
    const std_import = try project_values.importResolveValue(allocator, testContext(&store_fake, &scanner_fake), graph, "std", null);
    try std.testing.expectEqualStrings("stdlib", std_import.object.get("kind").?.string);
    const builtin_import = try project_values.importResolveValue(allocator, testContext(&store_fake, &scanner_fake), graph, "builtin", null);
    try std.testing.expectEqualStrings("compiler_builtin", builtin_import.object.get("kind").?.string);
    const module_import = try project_values.importResolveValue(allocator, testContext(&store_fake, &scanner_fake), graph, "root", null);
    try std.testing.expectEqualStrings("compiler_builtin", module_import.object.get("kind").?.string);
    const dep_import = try project_values.importResolveValue(allocator, testContext(&store_fake, &scanner_fake), graph, "foo", null);
    try std.testing.expectEqualStrings("package_dependency", dep_import.object.get("kind").?.string);
    try store_fake.expectExists(.{ .path = "src/util.zig", .provenance = "static_analysis.import_resolve" }, .{ .exists = true, .kind = .file });
    const file_import = try project_values.importResolveValue(allocator, testContext(&store_fake, &scanner_fake), graph, "util.zig", "src/main.zig");
    try std.testing.expectEqualStrings("workspace_file", file_import.object.get("kind").?.string);
    const unresolved = try project_values.importResolveValue(allocator, testContext(&store_fake, &scanner_fake), graph, "missing_pkg", null);
    try std.testing.expect(!unresolved.object.get("resolved").?.bool);

    try store_fake.verify();
}

test "typed static project values cover fallback branches" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const build_zig =
        \\const lib = b.addModule("lib", .{});
        \\lib.root_source_file = "src/lib.zig";
        \\const exe = b.addExecutable(.{ .name = "app", .root_source_file = b.path("src/main.zig") });
        \\
    ;
    const build_summary = try project_values.buildZigSummaryValue(allocator, build_zig);
    try std.testing.expectEqualStrings("src/lib.zig", build_summary.object.get("source_files").?.array.items[0].object.get("path").?.string);

    var graph_obj = std.json.ObjectMap.empty;
    try graph_obj.put(allocator, "build_zig", build_summary);
    try graph_obj.put(allocator, "build_zig_zon", .null);
    const graph = std.json.Value{ .object = graph_obj };

    const low_owner = try project_values.fileOwnerValue(allocator, graph, "src/unowned.zig");
    try std.testing.expectEqualStrings("low", low_owner.object.get("owner_match_confidence").?.string);

    var store_fake = workspace_store_fake.FakeWorkspaceStore.init(std.testing.allocator);
    defer store_fake.deinit();
    var scanner_fake = workspace_scanner_fake.FakeWorkspaceScanner.init(std.testing.allocator);
    defer scanner_fake.deinit();
    const context = testContext(&store_fake, &scanner_fake);

    const module_import = try project_values.importResolveValue(allocator, context, graph, "lib", null);
    try std.testing.expectEqualStrings("build_module", module_import.object.get("kind").?.string);
    try store_fake.expectExists(.{ .path = "standalone.zig", .provenance = "static_analysis.import_resolve" }, .{ .exists = false });
    const file_import = try project_values.importResolveValue(allocator, context, graph, "standalone.zig", null);
    try std.testing.expectEqualStrings("unresolved", file_import.object.get("kind").?.string);

    try store_fake.expectResolveError(.{ .path = "zig-pkg", .provenance = "static_analysis.cache_path_status" }, error.PathOutsideWorkspace);
    try store_fake.expectResolveError(.{ .path = "zig-pkg", .for_output = true, .provenance = "static_analysis.cache_path_status" }, error.Unavailable);
    const missing_cache = try project_values.cachePathStatusValue(allocator, context, "zig-pkg");
    try std.testing.expect(missing_cache.object.get("abs").? == .null);
    try std.testing.expect(missing_cache.object.get("kind").? == .null);
    try store_fake.verify();
}

test "typed changed file plans cover zig-only status without build files" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var commands = command_runner_fake.FakeCommandRunner.init(std.testing.allocator);
    defer commands.deinit();
    var store_fake = workspace_store_fake.FakeWorkspaceStore.init(std.testing.allocator);
    defer store_fake.deinit();
    var scanner_fake = workspace_scanner_fake.FakeWorkspaceScanner.init(std.testing.allocator);
    defer scanner_fake.deinit();
    const context = app_context.StaticAnalysisContext{
        .workspace = .{ .root = "/workspace", .cache_root = "/workspace/.zigars-cache" },
        .command_runner = commands.port(),
        .workspace_store = store_fake.port(),
        .workspace_scanner = scanner_fake.port(),
    };

    try commands.expectRun(.{
        .argv = &.{ "git", "status", "--porcelain" },
        .cwd = "/workspace",
        .timeout_ms = 100,
        .provenance = "static_analysis.changed_files_plan",
    }, .{ .stdout = " M src/only.zig\n" });
    try store_fake.expectExists(.{ .path = "src/only.zig", .provenance = "static_analysis.workspace_path_exists" }, .{ .exists = true, .kind = .file });
    try store_fake.expectExists(.{ .path = "build.zig", .provenance = "static_analysis.workspace_path_exists" }, .{ .exists = false });
    try store_fake.expectExists(.{ .path = "build.zig.zon", .provenance = "static_analysis.workspace_path_exists" }, .{ .exists = false });
    try store_fake.expectExists(.{ .path = "src", .provenance = "static_analysis.workspace_path_exists" }, .{ .exists = true, .kind = .directory });

    const plan = try project_values.changedFilesPlanValue(allocator, context, 100);
    try std.testing.expect(plan.object.get("commands").?.array.items.len >= 4);
    try commands.verify();
    try store_fake.verify();
    try scanner_fake.verify();
}

test "typed compiler diagnostics group repeated paths and next-action fallbacks" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const index = try project_values.compilerErrorIndexValue(
        allocator,
        "src/main.zig:1:1: error: unable to load 'missing.zig'\nsrc/main.zig:2:1: note: imported here\n",
        "",
        &.{ "zig", "build" },
    );
    try std.testing.expectEqual(@as(usize, 1), index.object.get("files").?.array.items.len);
    try std.testing.expectEqual(@as(i64, 2), index.object.get("files").?.array.items[0].object.get("count").?.integer);

    const fallback_command = try project_values.compilerNextCommand(allocator, .{
        .severity = "error",
        .path = "README.md",
        .message = "not a Zig source",
        .raw = "README.md: error: not a Zig source",
    }, &.{ "zig", "build" });
    try std.testing.expectEqualStrings("zig build", fallback_command.string);

    const actions = try project_values.compilerNextActions(allocator, .{
        .severity = "error",
        .message = "unable to load 'missing.zig'",
        .raw = "error: unable to load 'missing.zig'",
    }, 1);
    try std.testing.expect(actions.array.items.len >= 3);
}

test "typed command backed static plans cover status triage symbols and selection" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var commands = command_runner_fake.FakeCommandRunner.init(std.testing.allocator);
    defer commands.deinit();
    var store_fake = workspace_store_fake.FakeWorkspaceStore.init(std.testing.allocator);
    defer store_fake.deinit();
    var scanner_fake = workspace_scanner_fake.FakeWorkspaceScanner.init(std.testing.allocator);
    defer scanner_fake.deinit();
    var cache = static_cache_fake.FakeStaticCache.init(std.testing.allocator);
    defer cache.deinit();
    try cache.seed(42, "cached-index");

    const context = app_context.StaticAnalysisContext{
        .workspace = .{ .root = "/workspace", .cache_root = "/workspace/.zigars-cache" },
        .command_runner = commands.port(),
        .workspace_store = store_fake.port(),
        .workspace_scanner = scanner_fake.port(),
        .analysis_cache = cache.port(),
    };

    try commands.expectRun(.{
        .argv = &.{ "git", "status", "--porcelain" },
        .cwd = "/workspace",
        .timeout_ms = 100,
        .provenance = "static_analysis.changed_files_plan",
    }, .{
        .stdout =
        \\ M src/main.zig
        \\R  old.zig -> src/renamed.zig
        \\ M build.zig
        \\ M README.md
        \\
        ,
    });
    for ([_][]const u8{ "src/main.zig", "src/renamed.zig", "build.zig", "build.zig", "build.zig.zon", "src" }) |path| {
        try store_fake.expectExists(.{ .path = path, .provenance = "static_analysis.workspace_path_exists" }, .{ .exists = true, .kind = if (std.mem.eql(u8, path, "src")) .directory else .file });
    }
    const changed = try project_values.changedFilesPlanValue(allocator, context, 100);
    try std.testing.expectEqualStrings("zig_changed_files_plan", changed.object.get("kind").?.string);
    try std.testing.expect(changed.object.get("commands").?.array.items.len >= 5);

    try store_fake.expectResolve(.{ .path = "src/main.zig", .provenance = "static_analysis.test_failure_triage" }, "/workspace/src/main.zig");
    try commands.expectRun(.{
        .argv = &.{ "zig", "test", "/workspace/src/main.zig", "--test-filter", "Smoke", "--summary", "all" },
        .cwd = "/workspace",
        .timeout_ms = 123,
        .provenance = "static_analysis.test_failure_triage",
    }, .{
        .exit_code = 1,
        .stderr = "src/main.zig:3:4: error: missing import\nthread panic\nexpected 1 actual 2\n",
    });
    const triage = try project_values.testFailureTriageFromWorkspaceValue(allocator, context, .{
        .file = "src/main.zig",
        .filter = "Smoke",
        .args = "--summary all",
        .timeout_ms = 123,
    });
    try std.testing.expectEqualStrings("zig_test_failure_triage", triage.object.get("kind").?.string);
    try std.testing.expect(triage.object.get("panic_clues").?.array.items.len >= 1);

    try scanner_fake.expectScan(.{ .max_files = 5, .provenance = "static_analysis.workspace_symbol_cache" }, &.{ "src/main.zig", "src/skip.zig" });
    try store_fake.expectRead(.{ .path = "src/main.zig", .max_bytes = project_values.default_source_read_limit, .provenance = "static_analysis.workspace_symbol_cache" },
        \\const dep = @import("dep.zig");
        \\pub fn SmokeThing() void {}
        \\const Hidden = struct {};
        \\
    );
    try store_fake.expectReadError(.{ .path = "src/skip.zig", .max_bytes = project_values.default_source_read_limit, .provenance = "static_analysis.workspace_symbol_cache" }, error.FileNotFound);
    const symbols = try project_values.workspaceSymbolCacheValue(allocator, context, "Smoke", 5);
    try std.testing.expectEqual(@as(i64, 1), symbols.object.get("file_count").?.integer);
    try std.testing.expect(symbols.object.get("matches").?.array.items.len >= 1);
    try std.testing.expect(symbols.object.get("cache").?.object.get("cached").?.bool);

    try scanner_fake.expectScan(.{ .max_files = null, .provenance = "static_analysis.test_map" }, &.{"src/main_test.zig"});
    try store_fake.expectRead(.{ .path = "src/main_test.zig", .max_bytes = project_values.default_source_read_limit, .provenance = "static_analysis.test_map" },
        \\test "Smoke Thing" {}
        \\test namedSmoke {}
        \\
    );
    try store_fake.expectExists(.{ .path = "src/main_test.zig", .provenance = "static_analysis.workspace_path_exists" }, .{ .exists = true, .kind = .file });
    const selected = try project_values.testSelectValue(allocator, context, "src/main_test.zig", "Smoke", 10);
    try std.testing.expectEqualStrings("zig_test_select", selected.object.get("kind").?.string);
    try std.testing.expect(selected.object.get("commands").?.array.items.len >= 2);

    const matrix = try project_values.targetMatrixPlanValue(allocator, "native x86_64-windows wasm32-freestanding x86_64-linux aarch64-macos riscv64", "test smoke");
    try std.testing.expectEqual(@as(usize, 6), matrix.object.get("matrix").?.array.items.len);

    try commands.verify();
    try store_fake.verify();
    try scanner_fake.verify();
}

test "typed public api diffs and argument splitting cover edge cases" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const diff = try project_values.publicApiDiffValue(
        allocator,
        "src/api.zig",
        "pub fn kept() void {}\npub fn removed() void {}\npub const Changed = u8;\n",
        "pub fn kept() void {}\npub fn added() void {}\npub const Changed = u16;\n",
    );
    try std.testing.expect(diff.object.get("breaking_change_risk").?.bool);
    try std.testing.expectEqual(@as(usize, 1), diff.object.get("added").?.array.items.len);
    try std.testing.expectEqual(@as(usize, 1), diff.object.get("removed").?.array.items.len);
    try std.testing.expectEqual(@as(usize, 1), diff.object.get("changed").?.array.items.len);

    var commands = command_runner_fake.FakeCommandRunner.init(std.testing.allocator);
    defer commands.deinit();
    var store_fake = workspace_store_fake.FakeWorkspaceStore.init(std.testing.allocator);
    defer store_fake.deinit();
    var scanner_fake = workspace_scanner_fake.FakeWorkspaceScanner.init(std.testing.allocator);
    defer scanner_fake.deinit();
    const context = app_context.StaticAnalysisContext{
        .workspace = .{ .root = "/workspace" },
        .command_runner = commands.port(),
        .workspace_store = store_fake.port(),
        .workspace_scanner = scanner_fake.port(),
    };

    // The baseline path is resolved through the workspace sandbox before it is
    // embedded in the `git show <ref>:<path>` token, matching the sandboxed
    // current-source sibling.
    try store_fake.expectResolve(.{ .path = "src/api.zig", .provenance = "static_analysis.public_api_diff.baseline" }, "/workspace/src/api.zig");
    try commands.expectRun(.{
        .argv = &.{ "git", "show", "HEAD~1:src/api.zig" },
        .cwd = "/workspace",
        .timeout_ms = 5000,
        .provenance = "static_analysis.public_api_diff.baseline",
    }, .{ .stdout = "pub fn oldName() void {}\n" });
    try store_fake.expectRead(.{ .path = "src/api.zig", .max_bytes = project_values.default_source_read_limit, .provenance = "static_analysis.public_api_diff.current" }, "pub fn newName() void {}\n");
    const workspace_diff = try project_values.publicApiDiffFromWorkspaceValue(allocator, context, .{ .file = "src/api.zig", .baseline_ref = "HEAD~1" });
    try std.testing.expect(workspace_diff.object.get("breaking_change_risk").?.bool);

    const split = try project_values.splitArgs(allocator, " --flag 'two words' escaped\\ value \"dq\" ");
    defer {
        for (split) |arg| allocator.free(arg);
        allocator.free(split);
    }
    try std.testing.expectEqual(@as(usize, 4), split.len);
    try std.testing.expectEqualStrings("two words", split[1]);
    try std.testing.expectError(error.InvalidArguments, project_values.splitArgs(allocator, "\"unterminated"));

    try commands.verify();
    try store_fake.verify();
    try scanner_fake.verify();
}

test "public api baseline resolves through the workspace sandbox before git show" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Case 1: a workspace-escaping `file` is rejected by resolve, so no
    // `git show` runs and the baseline falls back to empty content. On pre-fix
    // code the raw `../../../../etc/passwd` reached `git show HEAD:...`,
    // disclosing out-of-workspace blobs; here it must never reach the runner.
    {
        var commands = command_runner_fake.FakeCommandRunner.init(std.testing.allocator);
        defer commands.deinit();
        var store_fake = workspace_store_fake.FakeWorkspaceStore.init(std.testing.allocator);
        defer store_fake.deinit();
        var scanner_fake = workspace_scanner_fake.FakeWorkspaceScanner.init(std.testing.allocator);
        defer scanner_fake.deinit();
        const context = app_context.StaticAnalysisContext{
            .workspace = .{ .root = "/workspace" },
            .command_runner = commands.port(),
            .workspace_store = store_fake.port(),
            .workspace_scanner = scanner_fake.port(),
        };

        try store_fake.expectResolveError(.{ .path = "../../../../etc/passwd", .provenance = "static_analysis.public_api_diff.baseline" }, error.PathOutsideWorkspace);
        try store_fake.expectRead(.{ .path = "../../../../etc/passwd", .max_bytes = project_values.default_source_read_limit, .provenance = "static_analysis.public_api_diff.current" }, "");
        const diff = try project_values.publicApiDiffFromWorkspaceValue(allocator, context, .{ .file = "../../../../etc/passwd", .baseline_ref = "HEAD" });
        // No subprocess argv was constructed from the escaping path.
        try std.testing.expectEqual(@as(usize, 0), commands.calls().len);
        try std.testing.expectEqual(@as(usize, 0), diff.object.get("before").?.array.items.len);
        try commands.verify();
        try store_fake.verify();
    }

    // Case 2: a valid `file` is resolved, and the `git show <ref>:<path>` token
    // carries the *resolved* workspace-relative path, not the raw caller input.
    {
        var commands = command_runner_fake.FakeCommandRunner.init(std.testing.allocator);
        defer commands.deinit();
        var store_fake = workspace_store_fake.FakeWorkspaceStore.init(std.testing.allocator);
        defer store_fake.deinit();
        var scanner_fake = workspace_scanner_fake.FakeWorkspaceScanner.init(std.testing.allocator);
        defer scanner_fake.deinit();
        const context = app_context.StaticAnalysisContext{
            .workspace = .{ .root = "/workspace" },
            .command_runner = commands.port(),
            .workspace_store = store_fake.port(),
            .workspace_scanner = scanner_fake.port(),
        };

        // The fake maps the requested path to a normalized absolute path under
        // root; the use case must reduce it back to `src/api.zig` for the token.
        try store_fake.expectResolve(.{ .path = "src/./api.zig", .provenance = "static_analysis.public_api_diff.baseline" }, "/workspace/src/api.zig");
        try commands.expectRun(.{
            .argv = &.{ "git", "show", "HEAD:src/api.zig" },
            .cwd = "/workspace",
            .timeout_ms = 5000,
            .provenance = "static_analysis.public_api_diff.baseline",
        }, .{ .stdout = "pub fn kept() void {}\n" });
        try store_fake.expectRead(.{ .path = "src/./api.zig", .max_bytes = project_values.default_source_read_limit, .provenance = "static_analysis.public_api_diff.current" }, "pub fn kept() void {}\n");
        _ = try project_values.publicApiDiffFromWorkspaceValue(allocator, context, .{ .file = "src/./api.zig", .baseline_ref = "HEAD" });
        try std.testing.expectEqualStrings("git", commands.calls()[0].argv[0]);
        try std.testing.expectEqualStrings("show", commands.calls()[0].argv[1]);
        try std.testing.expectEqualStrings("HEAD:src/api.zig", commands.calls()[0].argv[2]);
        try commands.verify();
        try store_fake.verify();
    }

    // Case 3: an invalid baseline_ref (smuggling a second `:` path component) is
    // rejected before any resolve or subprocess call.
    {
        var commands = command_runner_fake.FakeCommandRunner.init(std.testing.allocator);
        defer commands.deinit();
        var store_fake = workspace_store_fake.FakeWorkspaceStore.init(std.testing.allocator);
        defer store_fake.deinit();
        var scanner_fake = workspace_scanner_fake.FakeWorkspaceScanner.init(std.testing.allocator);
        defer scanner_fake.deinit();
        const context = app_context.StaticAnalysisContext{
            .workspace = .{ .root = "/workspace" },
            .command_runner = commands.port(),
            .workspace_store = store_fake.port(),
            .workspace_scanner = scanner_fake.port(),
        };

        try store_fake.expectRead(.{ .path = "src/api.zig", .max_bytes = project_values.default_source_read_limit, .provenance = "static_analysis.public_api_diff.current" }, "");
        _ = try project_values.publicApiDiffFromWorkspaceValue(allocator, context, .{ .file = "src/api.zig", .baseline_ref = "HEAD:../../etc/passwd" });
        try std.testing.expectEqual(@as(usize, 0), commands.calls().len);
        try std.testing.expectEqual(@as(usize, 0), store_fake.resolveCalls().len);
        try commands.verify();
        try store_fake.verify();
    }
}

test "typed static project value builders release partial objects on allocation failure" {
    var fail_index: usize = 0;
    while (fail_index < 256) : (fail_index += 1) {
        {
            var backing = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer backing.deinit();
            var failing = std.testing.FailingAllocator.init(backing.allocator(), .{ .fail_index = fail_index });
            const allocator = failing.allocator();
            var store_fake = workspace_store_fake.FakeWorkspaceStore.init(std.testing.allocator);
            defer store_fake.deinit();
            var scanner_fake = workspace_scanner_fake.FakeWorkspaceScanner.init(std.testing.allocator);
            defer scanner_fake.deinit();
            try expectBuildGraphReads(&store_fake,
                \\const mod = b.addModule("mod", .{});
                \\mod.root_source_file = "src/mod.zig";
            ,
                \\.{ .dependencies = .{} }
            );
            if (project_values.buildTargetsValue(allocator, testContext(&store_fake, &scanner_fake))) |_| {} else |err| try std.testing.expect(err == error.OutOfMemory);
        }

        {
            var backing = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer backing.deinit();
            var failing = std.testing.FailingAllocator.init(backing.allocator(), .{ .fail_index = fail_index });
            const allocator = failing.allocator();
            var store_fake = workspace_store_fake.FakeWorkspaceStore.init(std.testing.allocator);
            defer store_fake.deinit();
            var scanner_fake = workspace_scanner_fake.FakeWorkspaceScanner.init(std.testing.allocator);
            defer scanner_fake.deinit();
            try store_fake.expectRead(.{ .path = "build.zig", .max_bytes = project_values.default_build_read_limit, .provenance = "static_analysis.build_options" },
                \\const target = b.standardTargetOptions(.{});
                \\const feature = b.option(bool, "feature", "enable");
            );
            if (project_values.buildOptionsValue(allocator, testContext(&store_fake, &scanner_fake))) |_| {} else |err| try std.testing.expect(err == error.OutOfMemory);
        }

        {
            var backing = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer backing.deinit();
            var failing = std.testing.FailingAllocator.init(backing.allocator(), .{ .fail_index = fail_index });
            const allocator = failing.allocator();
            const graph = try project_values.buildZigSummaryValue(backing.allocator(),
                \\const mod = b.addModule("mod", .{});
                \\mod.root_source_file = "src/mod.zig";
            );
            if (project_values.fileOwnerValue(allocator, graph, "src/mod.zig")) |_| {} else |err| try std.testing.expect(err == error.OutOfMemory);
        }

        {
            var backing = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer backing.deinit();
            var failing = std.testing.FailingAllocator.init(backing.allocator(), .{ .fail_index = fail_index });
            const allocator = failing.allocator();
            var store_fake = workspace_store_fake.FakeWorkspaceStore.init(std.testing.allocator);
            defer store_fake.deinit();
            var scanner_fake = workspace_scanner_fake.FakeWorkspaceScanner.init(std.testing.allocator);
            defer scanner_fake.deinit();
            const graph = try project_values.buildZigSummaryValue(backing.allocator(),
                \\const mod = b.addModule("mod", .{});
            );
            if (project_values.importResolveValue(allocator, testContext(&store_fake, &scanner_fake), graph, "std", null)) |_| {} else |err| try std.testing.expect(err == error.OutOfMemory);
        }

        {
            var backing = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer backing.deinit();
            var failing = std.testing.FailingAllocator.init(backing.allocator(), .{ .fail_index = fail_index });
            const allocator = failing.allocator();
            var commands = command_runner_fake.FakeCommandRunner.init(std.testing.allocator);
            defer commands.deinit();
            var store_fake = workspace_store_fake.FakeWorkspaceStore.init(std.testing.allocator);
            defer store_fake.deinit();
            var scanner_fake = workspace_scanner_fake.FakeWorkspaceScanner.init(std.testing.allocator);
            defer scanner_fake.deinit();
            const context = app_context.StaticAnalysisContext{
                .workspace = .{ .root = "/workspace", .cache_root = "/workspace/.zigars-cache" },
                .command_runner = commands.port(),
                .workspace_store = store_fake.port(),
                .workspace_scanner = scanner_fake.port(),
            };
            try commands.expectRun(.{
                .argv = &.{ "git", "status", "--porcelain" },
                .cwd = "/workspace",
                .timeout_ms = 10,
                .provenance = "static_analysis.changed_files_plan",
            }, .{ .stdout = " M src/main.zig\n" });
            try store_fake.expectExists(.{ .path = "src/main.zig", .provenance = "static_analysis.workspace_path_exists" }, .{ .exists = true, .kind = .file });
            try store_fake.expectExists(.{ .path = "build.zig", .provenance = "static_analysis.workspace_path_exists" }, .{ .exists = false });
            try store_fake.expectExists(.{ .path = "build.zig.zon", .provenance = "static_analysis.workspace_path_exists" }, .{ .exists = false });
            try store_fake.expectExists(.{ .path = "src", .provenance = "static_analysis.workspace_path_exists" }, .{ .exists = true, .kind = .directory });
            if (project_values.changedFilesPlanValue(allocator, context, 10)) |_| {} else |err| try std.testing.expect(err == error.OutOfMemory);
        }

        {
            var backing = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer backing.deinit();
            var failing = std.testing.FailingAllocator.init(backing.allocator(), .{ .fail_index = fail_index });
            const allocator = failing.allocator();
            if (project_values.targetMatrixPlanValue(allocator, "native x86_64-linux", "test")) |_| {} else |err| try std.testing.expect(err == error.OutOfMemory);
        }

        {
            var backing = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer backing.deinit();
            var failing = std.testing.FailingAllocator.init(backing.allocator(), .{ .fail_index = fail_index });
            const allocator = failing.allocator();
            var store_fake = workspace_store_fake.FakeWorkspaceStore.init(std.testing.allocator);
            defer store_fake.deinit();
            var scanner_fake = workspace_scanner_fake.FakeWorkspaceScanner.init(std.testing.allocator);
            defer scanner_fake.deinit();
            try scanner_fake.expectScan(.{ .max_files = 2, .provenance = "static_analysis.workspace_symbol_cache" }, &.{"src/main.zig"});
            try store_fake.expectRead(.{ .path = "src/main.zig", .max_bytes = project_values.default_source_read_limit, .provenance = "static_analysis.workspace_symbol_cache" },
                \\pub fn main() void {}
            );
            if (project_values.workspaceSymbolIndexValue(allocator, testContext(&store_fake, &scanner_fake), 2)) |_| {} else |err| try std.testing.expect(err == error.OutOfMemory);
        }

        {
            var backing = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer backing.deinit();
            var failing = std.testing.FailingAllocator.init(backing.allocator(), .{ .fail_index = fail_index });
            const allocator = failing.allocator();
            var commands = command_runner_fake.FakeCommandRunner.init(std.testing.allocator);
            defer commands.deinit();
            var store_fake = workspace_store_fake.FakeWorkspaceStore.init(std.testing.allocator);
            defer store_fake.deinit();
            var scanner_fake = workspace_scanner_fake.FakeWorkspaceScanner.init(std.testing.allocator);
            defer scanner_fake.deinit();
            const context = app_context.StaticAnalysisContext{
                .workspace = .{ .root = "/workspace", .cache_root = "/workspace/.zigars-cache" },
                .command_runner = commands.port(),
                .workspace_store = store_fake.port(),
                .workspace_scanner = scanner_fake.port(),
            };
            inline for (.{ ".zig-cache", "zig-out", ".zigars-cache", "zig-pkg", "coverage" }) |name| {
                try store_fake.expectResolveError(.{ .path = name, .provenance = "static_analysis.cache_path_status" }, error.FileNotFound);
                try store_fake.expectResolveError(.{ .path = name, .for_output = true, .provenance = "static_analysis.cache_path_status" }, error.FileNotFound);
                try commands.expectRun(.{
                    .argv = &.{ "git", "ls-files", "--error-unmatch", name },
                    .cwd = "/workspace",
                    .timeout_ms = 10,
                    .provenance = "static_analysis.git_tracks_path",
                }, .{ .exit_code = 1 });
            }
            try store_fake.expectReadError(.{ .path = "build.zig.zon", .max_bytes = project_values.default_build_read_limit, .provenance = "static_analysis.package_cache_doctor" }, error.FileNotFound);
            if (project_values.packageCacheDoctorValue(allocator, context, 10)) |_| {} else |err| try std.testing.expect(err == error.OutOfMemory);
        }

        {
            var backing = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer backing.deinit();
            var failing = std.testing.FailingAllocator.init(backing.allocator(), .{ .fail_index = fail_index });
            const allocator = failing.allocator();
            var store_fake = workspace_store_fake.FakeWorkspaceStore.init(std.testing.allocator);
            defer store_fake.deinit();
            var scanner_fake = workspace_scanner_fake.FakeWorkspaceScanner.init(std.testing.allocator);
            defer scanner_fake.deinit();
            try scanner_fake.expectScan(.{ .max_files = null, .provenance = "static_analysis.test_map" }, &.{"src/main_test.zig"});
            try store_fake.expectRead(.{ .path = "src/main_test.zig", .max_bytes = project_values.default_source_read_limit, .provenance = "static_analysis.test_map" },
                \\test "main smoke" {}
            );
            if (project_values.testSelectValue(allocator, testContext(&store_fake, &scanner_fake), "src/main_test.zig", "smoke", 2)) |_| {} else |err| try std.testing.expect(err == error.OutOfMemory);
        }

        {
            var backing = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer backing.deinit();
            var failing = std.testing.FailingAllocator.init(backing.allocator(), .{ .fail_index = fail_index });
            const allocator = failing.allocator();
            if (project_values.publicApiDiffValue(allocator, "src/api.zig", "pub fn before() void {}\n", "pub fn after() void {}\n")) |_| {} else |err| try std.testing.expect(err == error.OutOfMemory);
        }
    }
}

/// Implements expect build graph reads workflow logic using caller-owned inputs.
fn expectBuildGraphReads(store_fake: *workspace_store_fake.FakeWorkspaceStore, build_zig: []const u8, build_zon: []const u8) !void {
    try store_fake.expectRead(.{ .path = "build.zig", .max_bytes = project_values.default_build_read_limit, .provenance = "static_analysis.build_graph" }, build_zig);
    try store_fake.expectRead(.{ .path = "build.zig.zon", .max_bytes = project_values.default_build_read_limit, .provenance = "static_analysis.build_graph" }, build_zon);
}
