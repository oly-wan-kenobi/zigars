//! Pins the docs-index use case to its ports: workspace/std/langref scans and
//! reads go through faked ports, toolchain-version and source drift drive
//! builtin docs, unreadable sources are skipped, and every entrypoint cleans up
//! staged results when allocation fails.
const std = @import("std");

const app_context = @import("../../context.zig");
const docs_index = @import("docs_index.zig");
const docs_domain = @import("../../../domain/release/docs_index.zig");
const fakes = @import("../../../testing/fakes/root.zig");

/// Returns a typed context backed by this fixture or runtime state.
fn testContext(
    workspace: *fakes.FakeWorkspaceStore,
    toolchain: *fakes.FakeToolchainEnv,
    scanner: *fakes.FakeDocsScanner,
) app_context.ReleaseDocsContext {
    // Keep this logic centralized so callers observe one consistent behavior path.
    return .{
        .workspace = .{ .root = "/workspace" },
        .tool_paths = .{},
        .timeouts = .{},
        .workspace_store = workspace.port(),
        .toolchain_env = toolchain.port(),
        .docs_scanner = scanner.port(),
    };
}

test "docs query uses scanner paths and workspace reads through ports" {
    const allocator = std.testing.allocator;
    var workspace = fakes.FakeWorkspaceStore.init(allocator);
    defer workspace.deinit();
    var toolchain = fakes.FakeToolchainEnv.init(allocator);
    defer toolchain.deinit();
    var scanner = fakes.FakeDocsScanner.init(allocator);
    defer scanner.deinit();

    try scanner.expectWorkspaceScan(.{ .max_files = docs_domain.default_path_scan_limit, .provenance = "release_docs.workspace_docs_scan" }, &.{"README.md"});
    try workspace.expectRead(.{ .path = "README.md", .max_bytes = docs_domain.std_source_read_limit, .provenance = "release_docs.workspace_docs_read" }, "# zigars\nFixtureSymbol docs\n");

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

test "builtin docs use toolchain version, source drift, and unavailable fallbacks" {
    const allocator = std.testing.allocator;
    var workspace = fakes.FakeWorkspaceStore.init(allocator);
    defer workspace.deinit();
    var toolchain = fakes.FakeToolchainEnv.init(allocator);
    defer toolchain.deinit();
    var scanner = fakes.FakeDocsScanner.init(allocator);
    defer scanner.deinit();

    try toolchain.expectGet(.{ .key = "version", .provenance = "release_docs.builtin_version" }, "0.16.0");
    try toolchain.expectGet(.{ .key = "std_dir", .provenance = "release_docs.builtin_source" }, "/zig/lib/std");
    try scanner.expectRead(.{
        .path = "/zig/lib/std/zig/BuiltinFn.zig",
        .max_bytes = docs_domain.std_source_read_limit,
        .provenance = "release_docs.builtin_source",
    }, "pub const list = .{ .{ \"@import\", {} }, .{ \"@This\", {} } });");

    const ctx = testContext(&workspace, &toolchain, &scanner);
    var doc = try docs_index.builtinDoc(allocator, ctx, "@import", 0);
    defer doc.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), doc.limit);
    try std.testing.expect(doc.matches.len >= 1);
    try std.testing.expectEqualStrings("0.16.0", doc.input.toolchain_version.?);
    try std.testing.expectEqualStrings("/zig/lib/std/zig/BuiltinFn.zig", doc.input.drift.?.active_source_path.?);
    try std.testing.expectEqualStrings("source_backed", doc.input.drift.?.confidence);

    try toolchain.expectGetError(.{ .key = "version", .provenance = "release_docs.builtin_version" }, error.Unavailable);
    try toolchain.expectGetError(.{ .key = "std_dir", .provenance = "release_docs.builtin_source" }, error.Unavailable);
    const list = try docs_index.builtinList(allocator, ctx);
    defer list.deinit(allocator);
    try std.testing.expectEqual(@as(?[]const u8, null), list.input.toolchain_version);
    try std.testing.expectEqualStrings("toolchain_version_unavailable", list.input.drift.?.status);

    try toolchain.verify();
    try scanner.verify();
}

test "std docs search and item skip unreadable source files" {
    const allocator = std.testing.allocator;
    var workspace = fakes.FakeWorkspaceStore.init(allocator);
    defer workspace.deinit();
    var toolchain = fakes.FakeToolchainEnv.init(allocator);
    defer toolchain.deinit();
    var scanner = fakes.FakeDocsScanner.init(allocator);
    defer scanner.deinit();

    try toolchain.expectGet(.{ .key = "std_dir", .provenance = "release_docs.std_search" }, "/zig/lib/std");
    try scanner.expectAbsoluteScan(.{
        .root = "/zig/lib/std",
        .max_files = docs_domain.default_path_scan_limit,
        .provenance = "release_docs.std_scan",
    }, &.{ "mem.zig", "unreadable.zig" });
    try scanner.expectRead(.{
        .path = "/zig/lib/std/mem.zig",
        .max_bytes = docs_domain.std_source_read_limit,
        .provenance = "release_docs.std_read",
    }, "/// Memory allocator docs\npub const Allocator = struct {};\n");
    try scanner.expectReadError(.{
        .path = "/zig/lib/std/unreadable.zig",
        .max_bytes = docs_domain.std_source_read_limit,
        .provenance = "release_docs.std_read",
    }, error.FileNotFound);

    const ctx = testContext(&workspace, &toolchain, &scanner);
    var search = try docs_index.stdSearch(allocator, ctx, "Allocator", 0);
    defer search.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), search.limit);
    try std.testing.expectEqual(@as(usize, 1), search.metadata.skipped_files);
    try std.testing.expectEqual(@as(usize, 1), search.matches.len);
    try std.testing.expectEqualStrings("/zig/lib/std/mem.zig", search.matches[0].source_path);

    try toolchain.expectGet(.{ .key = "std_dir", .provenance = "release_docs.std_item" }, "/zig/lib/std");
    try scanner.expectAbsoluteScan(.{
        .root = "/zig/lib/std",
        .max_files = docs_domain.default_path_scan_limit,
        .provenance = "release_docs.std_scan",
    }, &.{"mem.zig"});
    try scanner.expectRead(.{
        .path = "/zig/lib/std/mem.zig",
        .max_bytes = docs_domain.std_source_read_limit,
        .provenance = "release_docs.std_read",
    }, "/// Memory allocator docs\npub const Allocator = struct {};\n");

    var item = try docs_index.stdItem(allocator, ctx, "std.mem.Allocator", 0);
    defer item.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), item.limit);
    try std.testing.expectEqualStrings("Allocator", item.decl_name);
    try std.testing.expectEqual(@as(usize, 1), item.matches.len);
    try std.testing.expect(item.matches[0].preferred_path);

    try toolchain.verify();
    try scanner.verify();
}

test "langref search falls back for installed read failure and missing candidates" {
    const allocator = std.testing.allocator;
    var workspace = fakes.FakeWorkspaceStore.init(allocator);
    defer workspace.deinit();
    var toolchain = fakes.FakeToolchainEnv.init(allocator);
    defer toolchain.deinit();
    var scanner = fakes.FakeDocsScanner.init(allocator);
    defer scanner.deinit();

    try toolchain.expectGet(.{ .key = "lib_dir", .provenance = "release_docs.langref" }, "/zig/lib");
    try scanner.expectRead(.{
        .path = "/zig/lib/doc/langref.html",
        .max_bytes = docs_domain.langref_probe_read_limit,
        .provenance = "release_docs.langref_probe",
    }, "<html><title>Zig Language Reference</title></html>");
    try scanner.expectReadError(.{
        .path = "/zig/lib/doc/langref.html",
        .max_bytes = docs_domain.langref_html_read_limit,
        .provenance = "release_docs.langref_read",
    }, error.FileNotFound);

    const ctx = testContext(&workspace, &toolchain, &scanner);
    var read_failed = try docs_index.langrefSearch(allocator, ctx, "if", 0);
    defer read_failed.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), read_failed.limit);
    try std.testing.expect(read_failed.metadata.installed_doc_available);
    try std.testing.expectEqual(@as(usize, 1), read_failed.metadata.unreadable_candidate_count);
    try std.testing.expectEqual(@as(usize, 1), read_failed.metadata.parse_failure_count);
    try std.testing.expectEqualStrings("installed_langref_read_failed", read_failed.metadata.fallback_reason.?);

    try toolchain.expectGet(.{ .key = "lib_dir", .provenance = "release_docs.langref" }, "/zig/lib");
    for (docs_domain.langref_candidates) |rel| {
        const path = try std.fs.path.join(allocator, &.{ "/zig/lib", rel });
        defer allocator.free(path);
        try scanner.expectReadError(.{
            .path = path,
            .max_bytes = docs_domain.langref_probe_read_limit,
            .provenance = "release_docs.langref_probe",
        }, error.FileNotFound);
    }

    var missing = try docs_index.langrefSearch(allocator, ctx, "while", 0);
    defer missing.deinit(allocator);
    try std.testing.expectEqual(@as(usize, docs_domain.langref_candidates.len), missing.metadata.candidate_count);
    try std.testing.expectEqual(@as(usize, docs_domain.langref_candidates.len), missing.metadata.unreadable_candidate_count);
    try std.testing.expectEqualStrings("installed_langref_not_found", missing.metadata.fallback_reason.?);

    try toolchain.verify();
    try scanner.verify();
}

test "docs index and evidence readers cover skips, defaults, optional empty input, and missing evidence" {
    const allocator = std.testing.allocator;
    var workspace = fakes.FakeWorkspaceStore.init(allocator);
    defer workspace.deinit();
    var toolchain = fakes.FakeToolchainEnv.init(allocator);
    defer toolchain.deinit();
    var scanner = fakes.FakeDocsScanner.init(allocator);
    defer scanner.deinit();

    try scanner.expectWorkspaceScan(.{
        .max_files = docs_domain.default_path_scan_limit,
        .provenance = "release_docs.workspace_docs_scan",
    }, &.{ "README.md", "docs/guide.md", "src/main.zig" });
    try workspace.expectRead(.{
        .path = "README.md",
        .max_bytes = docs_domain.std_source_read_limit,
        .provenance = "release_docs.workspace_docs_read",
    }, "# Project\nNeedle docs\n");
    try workspace.expectReadError(.{
        .path = "docs/guide.md",
        .max_bytes = docs_domain.std_source_read_limit,
        .provenance = "release_docs.workspace_docs_read",
    }, error.FileNotFound);

    const ctx = testContext(&workspace, &toolchain, &scanner);
    var index = try docs_index.docsIndexBuild(allocator, ctx, "docs", 0);
    defer index.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), index.files_scanned);
    try std.testing.expectEqual(@as(usize, 1), index.skipped_files);
    try std.testing.expectEqual(@as(usize, 1), index.entries.len);
    try std.testing.expectEqualStrings("# Project", index.entries[0].first_heading.?);

    var autodoc = try docs_index.autodocIngest(allocator, ctx, .{
        .content = "{\"name\":\"Needle\",\"docs\":\"Generated docs\"}",
        .provenance = "release_docs.autodoc_inline",
    }, 0);
    defer autodoc.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), autodoc.entries.len);
    try std.testing.expectEqualStrings("inline_content", autodoc.raw_reference.source_kind);

    try workspace.expectRead(.{
        .path = "docs/examples.md",
        .max_bytes = docs_domain.evidence_read_limit,
        .provenance = "release_docs.examples",
    }, "```zig\nconst x = ;\n```\n");
    var examples = try docs_index.docExampleCheck(allocator, ctx, .{
        .default_path = "docs/examples.md",
        .provenance = "release_docs.examples",
    }, 0);
    defer examples.deinit(allocator);
    try std.testing.expect(!examples.ok);
    try std.testing.expectEqualStrings("workspace_path", examples.raw_reference.source_kind);
    try std.testing.expectEqualStrings("docs/examples.md", examples.raw_reference.path.?);

    var optional_empty = try docs_index.readmeCommandCheck(allocator, ctx, .{
        .require = false,
        .provenance = "release_docs.readme_optional",
    }, 0);
    defer optional_empty.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), optional_empty.commands.len);
    try std.testing.expectEqualStrings("empty", optional_empty.raw_reference.source_kind);

    try std.testing.expectError(error.MissingEvidence, docs_index.autodocIngest(allocator, ctx, .{
        .provenance = "release_docs.required_missing",
    }, 1));

    try workspace.verify();
    try scanner.verify();
}

test "release docs use cases propagate allocation failures without leaking staged results" {
    var fail_index: usize = 0;
    while (fail_index < 192) : (fail_index += 1) {
        {
            var backing = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer backing.deinit();
            var failing = std.testing.FailingAllocator.init(backing.allocator(), .{ .fail_index = fail_index });
            const allocator = failing.allocator();
            var workspace = fakes.FakeWorkspaceStore.init(std.testing.allocator);
            defer workspace.deinit();
            var toolchain = fakes.FakeToolchainEnv.init(std.testing.allocator);
            defer toolchain.deinit();
            var scanner = fakes.FakeDocsScanner.init(std.testing.allocator);
            defer scanner.deinit();

            try toolchain.expectGet(.{ .key = "version", .provenance = "release_docs.builtin_version" }, "0.16.0");
            try toolchain.expectGet(.{ .key = "std_dir", .provenance = "release_docs.builtin_source" }, "/zig/lib/std");
            try scanner.expectRead(.{
                .path = "/zig/lib/std/zig/BuiltinFn.zig",
                .max_bytes = docs_domain.std_source_read_limit,
                .provenance = "release_docs.builtin_source",
            }, "pub const list = .{ .{ \"@import\", {} }, .{ \"@extra\", {} } });");

            if (docs_index.builtinDoc(allocator, testContext(&workspace, &toolchain, &scanner), "import", 2)) |result| {
                var owned = result;
                owned.deinit(allocator);
            } else |err| try std.testing.expectEqual(error.OutOfMemory, err);
        }
        {
            var backing = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer backing.deinit();
            var failing = std.testing.FailingAllocator.init(backing.allocator(), .{ .fail_index = fail_index });
            const allocator = failing.allocator();
            var workspace = fakes.FakeWorkspaceStore.init(std.testing.allocator);
            defer workspace.deinit();
            var toolchain = fakes.FakeToolchainEnv.init(std.testing.allocator);
            defer toolchain.deinit();
            var scanner = fakes.FakeDocsScanner.init(std.testing.allocator);
            defer scanner.deinit();

            try toolchain.expectGet(.{ .key = "version", .provenance = "release_docs.builtin_version" }, "0.16.0");
            try toolchain.expectGetError(.{ .key = "std_dir", .provenance = "release_docs.builtin_source" }, error.Unavailable);

            if (docs_index.builtinList(allocator, testContext(&workspace, &toolchain, &scanner))) |result| {
                result.deinit(allocator);
            } else |err| try std.testing.expectEqual(error.OutOfMemory, err);
        }
        {
            var backing = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer backing.deinit();
            var failing = std.testing.FailingAllocator.init(backing.allocator(), .{ .fail_index = fail_index });
            const allocator = failing.allocator();
            var workspace = fakes.FakeWorkspaceStore.init(std.testing.allocator);
            defer workspace.deinit();
            var toolchain = fakes.FakeToolchainEnv.init(std.testing.allocator);
            defer toolchain.deinit();
            var scanner = fakes.FakeDocsScanner.init(std.testing.allocator);
            defer scanner.deinit();

            try toolchain.expectGet(.{ .key = "std_dir", .provenance = "release_docs.std_search" }, "/zig/lib/std");
            try scanner.expectAbsoluteScan(.{
                .root = "/zig/lib/std",
                .max_files = docs_domain.default_path_scan_limit,
                .provenance = "release_docs.std_scan",
            }, &.{ "mem.zig", "heap.zig" });
            try scanner.expectRead(.{
                .path = "/zig/lib/std/mem.zig",
                .max_bytes = docs_domain.std_source_read_limit,
                .provenance = "release_docs.std_read",
            }, "/// Allocator docs\npub const Allocator = struct {};\n");
            try scanner.expectRead(.{
                .path = "/zig/lib/std/heap.zig",
                .max_bytes = docs_domain.std_source_read_limit,
                .provenance = "release_docs.std_read",
            }, "pub const allocator_needle = 1;\n");

            if (docs_index.stdSearch(allocator, testContext(&workspace, &toolchain, &scanner), "Allocator", 2)) |result| {
                var owned = result;
                owned.deinit(allocator);
            } else |err| try std.testing.expectEqual(error.OutOfMemory, err);
        }
        {
            var backing = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer backing.deinit();
            var failing = std.testing.FailingAllocator.init(backing.allocator(), .{ .fail_index = fail_index });
            const allocator = failing.allocator();
            var workspace = fakes.FakeWorkspaceStore.init(std.testing.allocator);
            defer workspace.deinit();
            var toolchain = fakes.FakeToolchainEnv.init(std.testing.allocator);
            defer toolchain.deinit();
            var scanner = fakes.FakeDocsScanner.init(std.testing.allocator);
            defer scanner.deinit();

            try toolchain.expectGet(.{ .key = "std_dir", .provenance = "release_docs.std_item" }, "/zig/lib/std");
            try scanner.expectAbsoluteScan(.{
                .root = "/zig/lib/std",
                .max_files = docs_domain.default_path_scan_limit,
                .provenance = "release_docs.std_scan",
            }, &.{ "mem.zig", "heap.zig" });
            try scanner.expectRead(.{
                .path = "/zig/lib/std/mem.zig",
                .max_bytes = docs_domain.std_source_read_limit,
                .provenance = "release_docs.std_read",
            }, "/// Allocator docs\npub const Allocator = struct {};\n");
            try scanner.expectRead(.{
                .path = "/zig/lib/std/heap.zig",
                .max_bytes = docs_domain.std_source_read_limit,
                .provenance = "release_docs.std_read",
            }, "pub const Allocator = struct {};\n");

            if (docs_index.stdItem(allocator, testContext(&workspace, &toolchain, &scanner), "std.mem.Allocator", 2)) |result| {
                var owned = result;
                owned.deinit(allocator);
            } else |err| try std.testing.expectEqual(error.OutOfMemory, err);
        }
        {
            var backing = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer backing.deinit();
            var failing = std.testing.FailingAllocator.init(backing.allocator(), .{ .fail_index = fail_index });
            const allocator = failing.allocator();
            var workspace = fakes.FakeWorkspaceStore.init(std.testing.allocator);
            defer workspace.deinit();
            var toolchain = fakes.FakeToolchainEnv.init(std.testing.allocator);
            defer toolchain.deinit();
            var scanner = fakes.FakeDocsScanner.init(std.testing.allocator);
            defer scanner.deinit();

            try toolchain.expectGet(.{ .key = "lib_dir", .provenance = "release_docs.langref" }, "/zig/lib");
            try scanner.expectRead(.{
                .path = "/zig/lib/doc/langref.html",
                .max_bytes = docs_domain.langref_probe_read_limit,
                .provenance = "release_docs.langref_probe",
            }, "Zig Language Reference");
            try scanner.expectReadError(.{
                .path = "/zig/lib/doc/langref.html",
                .max_bytes = docs_domain.langref_html_read_limit,
                .provenance = "release_docs.langref_read",
            }, error.FileNotFound);

            if (docs_index.langrefSearch(allocator, testContext(&workspace, &toolchain, &scanner), "pointer", 2)) |result| {
                var owned = result;
                owned.deinit(allocator);
            } else |err| try std.testing.expectEqual(error.OutOfMemory, err);
        }
        {
            var backing = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer backing.deinit();
            var failing = std.testing.FailingAllocator.init(backing.allocator(), .{ .fail_index = fail_index });
            const allocator = failing.allocator();
            var workspace = fakes.FakeWorkspaceStore.init(std.testing.allocator);
            defer workspace.deinit();
            var toolchain = fakes.FakeToolchainEnv.init(std.testing.allocator);
            defer toolchain.deinit();
            var scanner = fakes.FakeDocsScanner.init(std.testing.allocator);
            defer scanner.deinit();

            try toolchain.expectGet(.{ .key = "lib_dir", .provenance = "release_docs.langref" }, "/zig/lib");
            for (docs_domain.langref_candidates) |rel| {
                const path = try std.fs.path.join(std.testing.allocator, &.{ "/zig/lib", rel });
                defer std.testing.allocator.free(path);
                try scanner.expectReadError(.{
                    .path = path,
                    .max_bytes = docs_domain.langref_probe_read_limit,
                    .provenance = "release_docs.langref_probe",
                }, error.FileNotFound);
            }

            if (docs_index.langrefSearch(allocator, testContext(&workspace, &toolchain, &scanner), "pointer", 2)) |result| {
                var owned = result;
                owned.deinit(allocator);
            } else |err| try std.testing.expectEqual(error.OutOfMemory, err);
        }
        {
            var backing = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer backing.deinit();
            var failing = std.testing.FailingAllocator.init(backing.allocator(), .{ .fail_index = fail_index });
            const allocator = failing.allocator();
            var workspace = fakes.FakeWorkspaceStore.init(std.testing.allocator);
            defer workspace.deinit();
            var toolchain = fakes.FakeToolchainEnv.init(std.testing.allocator);
            defer toolchain.deinit();
            var scanner = fakes.FakeDocsScanner.init(std.testing.allocator);
            defer scanner.deinit();

            try scanner.expectWorkspaceScan(.{
                .max_files = docs_domain.default_path_scan_limit,
                .provenance = "release_docs.workspace_docs_scan",
            }, &.{ "README.md", "docs/guide.md" });
            try workspace.expectRead(.{
                .path = "README.md",
                .max_bytes = docs_domain.std_source_read_limit,
                .provenance = "release_docs.workspace_docs_read",
            }, "# Readme\nNeedle docs\n");
            try workspace.expectRead(.{
                .path = "docs/guide.md",
                .max_bytes = docs_domain.std_source_read_limit,
                .provenance = "release_docs.workspace_docs_read",
            }, "# Guide\nNeedle docs\n");

            if (docs_index.docsIndexBuild(allocator, testContext(&workspace, &toolchain, &scanner), "docs", 2)) |result| {
                var owned = result;
                owned.deinit(allocator);
            } else |err| try std.testing.expectEqual(error.OutOfMemory, err);
        }
    }
}
