//! Behavioral tests for docs_index: builtin drift detection, stdlib source scan,
//! langref search (bundled and installed HTML), workspace docs querying, autodoc
//! ingest, fenced-snippet parse verification, and allocation-failure cleanup.

const std = @import("std");

const docs_index = @import("docs_index.zig");

test "builtin drift parser compares curated names with offline BuiltinFn source" {
    const allocator = std.testing.allocator;
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(allocator);
    try source.appendSlice(allocator, "pub const list = list: { break :list std.StaticStringMap(BuiltinFn).initComptime([_]struct { []const u8, BuiltinFn }{\n");
    for (docs_index.builtins) |item| try source.print(allocator, ".{{ \"{s}\", .{{ .param_count = 1 }} }},\n", .{item.name});
    try source.appendSlice(allocator, ".{ \"@newBuiltin\", .{ .param_count = 0 } },\n}); };\n");

    const input = try docs_index.buildBuiltinIndexInput(allocator, "0.16.0", "/zig/std/zig/BuiltinFn.zig", source.items);
    const drift = input.drift.?;
    defer docs_index.deinitBuiltinIndexInput(input, allocator);

    try std.testing.expectEqualStrings("curated_subset_matches_active_builtin_source", drift.status);
    try std.testing.expectEqualStrings("source_backed", drift.confidence);
    try std.testing.expectEqual(@as(usize, docs_index.builtins.len + 1), drift.active_count);
    try std.testing.expectEqual(@as(usize, 0), drift.curated_missing_count);
    try std.testing.expectEqual(@as(usize, 1), drift.active_extra_count);
    try std.testing.expectEqualStrings("@newBuiltin", drift.extra_names_sample[0]);
}

test "docs snippet checks report syntax status without execution" {
    const allocator = std.testing.allocator;
    var examples = try docs_index.docExampleCheck(allocator, "inline_content", null,
        \\```zig
        \\pub fn ok() void {}
        \\```
    , 10);
    defer examples.deinit(allocator);
    try std.testing.expect(examples.ok);
    try std.testing.expectEqual(@as(usize, 1), examples.snippets.len);

    const bad = try docs_index.snippetCheck(allocator, "bad", "pub fn bad() void { const x = ; _ = x; }");
    defer bad.deinit(allocator);
    try std.testing.expect(!bad.ok);
    try std.testing.expectEqualStrings("syntax_errors", bad.parse_status);
}

test "docs index source metadata and builtin lookup cover provenance contracts" {
    const allocator = std.testing.allocator;

    try std.testing.expectEqualStrings("partial_curated", docs_index.curatedBuiltinsSource().completeness.text());
    try std.testing.expectEqualStrings("source_scan", docs_index.stdlibSource("/zig/lib/std", "0.16.0").completeness.text());
    try std.testing.expectEqualStrings("installed_complete", docs_index.installedLangrefSource("/zig/doc/langref.html", null).completeness.text());
    try std.testing.expectEqualStrings("bundled_langref_index", docs_index.bundledLangrefSource().id);

    const listed = docs_index.builtinList(.{});
    listed.deinit(allocator);

    var import_doc = try docs_index.builtinDoc(allocator, "IMPORT", 0, .{});
    defer import_doc.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), import_doc.limit);
    try std.testing.expect(import_doc.matches.len >= 1);
    try std.testing.expectEqualStrings("@import", import_doc.matches[0].item.name);

    var no_doc = try docs_index.builtinDoc(allocator, "definitely-not-a-builtin", 3, .{});
    defer no_doc.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), no_doc.matches.len);

    const failed_parse = try docs_index.buildBuiltinIndexInput(allocator, null, "/zig/std/zig/BuiltinFn.zig", "pub const other = .{};");
    defer docs_index.deinitBuiltinIndexInput(failed_parse, allocator);
    try std.testing.expectEqualStrings("active_builtin_source_parse_failed", failed_parse.drift.?.status);
    try std.testing.expectEqualStrings("source_backed", failed_parse.drift.?.confidence);

    const missing_source =
        \\pub const list = list: {
        \\    break :list std.StaticStringMap(BuiltinFn).initComptime([_]struct { []const u8, BuiltinFn }{
        \\        .{ "@import", .{ .param_count = 1 } },
        \\        .{ "@not_curated", .{ .param_count = 0 } },
        \\        .{ "not_builtin", .{ .param_count = 0 } },
        \\        .{ "@bad-name", .{ .param_count = 0 } },
        \\    });
        \\};
    ;
    const missing = try docs_index.buildBuiltinIndexInput(allocator, "0.16.0", null, missing_source);
    defer docs_index.deinitBuiltinIndexInput(missing, allocator);
    try std.testing.expectEqualStrings("curated_entries_missing_from_active_builtin_source", missing.drift.?.status);
    try std.testing.expect(missing.drift.?.curated_missing_count > 0);
    try std.testing.expectEqual(@as(usize, 1), missing.drift.?.active_extra_count);
}

test "std source search and item lookup parse declarations docs and ranking" {
    const allocator = std.testing.allocator;
    const files = [_]docs_index.TextFile{
        .{
            .path = "mem.zig",
            .source_path = "/zig/lib/std/mem.zig",
            .bytes =
            \\/// Allocator docs
            \\/// second line
            \\pub fn Allocator() void {}
            \\plain alpha text
            \\
            ,
        },
        .{
            .path = "other.zig",
            .bytes =
            \\pub const alpha_value = 1;
            \\pub extern fn Allocator() void;
            \\pub inline fn helper() void {}
            \\
            ,
        },
    };

    var search = try docs_index.stdSearch(allocator, "/zig/lib/std", "alpha", files[0..], .{ .files_scanned = 2, .skipped_files = 1, .walk_errors = 1 }, 1);
    defer search.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), search.total_match_count);
    try std.testing.expectEqual(@as(usize, 1), search.matches.len);
    try std.testing.expectEqualStrings("mem.zig", search.matches[0].path);
    try std.testing.expectEqualStrings("source_line", search.matches[0].match_kind);
    try std.testing.expectEqual(@as(usize, 1), search.metadata.skipped_files);

    var decl_search = try docs_index.stdSearch(allocator, "/zig/lib/std", "alpha_value", files[0..], .{}, 4);
    defer decl_search.deinit(allocator);
    try std.testing.expectEqualStrings("const", decl_search.matches[0].match_kind);
    try std.testing.expectEqualStrings("std.other.alpha_value", decl_search.matches[0].qualified_name.?);

    var item = try docs_index.stdItem(allocator, "/zig/lib/std", "std.mem.Allocator", files[0..], .{}, 1);
    defer item.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), item.total_match_count);
    try std.testing.expectEqualStrings("mem.zig", item.matches[0].path);
    try std.testing.expect(item.matches[0].preferred_path);
    try std.testing.expectEqual(@as(usize, 2), item.matches[0].doc_comment_count);
    try std.testing.expectEqualStrings("std.mem.Allocator", item.matches[0].qualified_name);

    var empty_item = try docs_index.stdItem(allocator, "/zig/lib/std", "   ", files[0..], .{}, 0);
    defer empty_item.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), empty_item.total_match_count);
    try std.testing.expect(empty_item.qualified_path_hint == null);
}

test "docs index domain cleans partial allocations on builder failures" {
    const builtin_source =
        \\pub const list = list: {
        \\    break :list std.StaticStringMap(BuiltinFn).initComptime([_]struct { []const u8, BuiltinFn }{
        \\        .{ "@import", .{ .param_count = 1 } },
        \\        .{ "@not_curated", .{ .param_count = 0 } },
        \\    });
        \\};
    ;
    const std_files = [_]docs_index.TextFile{
        .{
            .path = "mem.zig",
            .bytes =
            \\/// Allocator docs
            \\pub fn Allocator() void {}
            \\pub const needle = 1;
            ,
        },
        .{ .path = "other.zig", .bytes = "pub const needle = 2;\n" },
    };
    const docs_files = [_]docs_index.TextFile{
        .{ .path = "README.md", .bytes = "# Title\nneedle\n" },
        .{ .path = "src/lib.zig", .bytes = "pub fn needle() void {}\n" },
    };
    const html =
        \\<h2 id="Needle">Needle</h2>
        \\<p>Needle docs &amp; details.</p>
    ;
    const fenced =
        \\```zig
        \\pub fn ok() void {}
        \\```
    ;
    const shell =
        \\```sh
        \\zig build test
        \\```
    ;

    var fail_index: usize = 0;
    while (fail_index < 128) : (fail_index += 1) {
        {
            var backing = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer backing.deinit();
            var failing = std.testing.FailingAllocator.init(backing.allocator(), .{ .fail_index = fail_index });
            const allocator = failing.allocator();
            if (docs_index.builtinDoc(allocator, "import", 2, .{})) |result| {
                var owned = result;
                owned.deinit(allocator);
            } else |err| {
                try std.testing.expectEqual(error.OutOfMemory, err);
            }
        }
        {
            var backing = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer backing.deinit();
            var failing = std.testing.FailingAllocator.init(backing.allocator(), .{ .fail_index = fail_index });
            const allocator = failing.allocator();
            if (docs_index.buildBuiltinIndexInput(allocator, "0.16.0", "/zig/std/zig/BuiltinFn.zig", builtin_source)) |input| {
                docs_index.deinitBuiltinIndexInput(input, allocator);
            } else |err| {
                try std.testing.expectEqual(error.OutOfMemory, err);
            }
        }
        {
            var backing = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer backing.deinit();
            var failing = std.testing.FailingAllocator.init(backing.allocator(), .{ .fail_index = fail_index });
            const allocator = failing.allocator();
            if (docs_index.stdSearch(allocator, "/zig/lib/std", "needle", std_files[0..], .{}, 2)) |result| {
                var owned = result;
                owned.deinit(allocator);
            } else |err| {
                try std.testing.expectEqual(error.OutOfMemory, err);
            }
        }
        {
            var backing = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer backing.deinit();
            var failing = std.testing.FailingAllocator.init(backing.allocator(), .{ .fail_index = fail_index });
            const allocator = failing.allocator();
            if (docs_index.stdItem(allocator, "/zig/lib/std", "std.mem.Allocator", std_files[0..], .{}, 2)) |result| {
                var owned = result;
                owned.deinit(allocator);
            } else |err| {
                try std.testing.expectEqual(error.OutOfMemory, err);
            }
        }
        {
            var backing = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer backing.deinit();
            var failing = std.testing.FailingAllocator.init(backing.allocator(), .{ .fail_index = fail_index });
            const allocator = failing.allocator();
            if (docs_index.langrefBundled(allocator, "pointer", 2, .{})) |result| {
                var owned = result;
                owned.deinit(allocator);
            } else |err| {
                try std.testing.expectEqual(error.OutOfMemory, err);
            }
        }
        {
            var backing = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer backing.deinit();
            var failing = std.testing.FailingAllocator.init(backing.allocator(), .{ .fail_index = fail_index });
            const allocator = failing.allocator();
            if (docs_index.langrefInstalled(allocator, "/zig/doc/langref.html", html, "needle", 2, .{})) |result| {
                var owned = result;
                owned.deinit(allocator);
            } else |err| {
                try std.testing.expectEqual(error.OutOfMemory, err);
            }
        }
        {
            var backing = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer backing.deinit();
            var failing = std.testing.FailingAllocator.init(backing.allocator(), .{ .fail_index = fail_index });
            const allocator = failing.allocator();
            if (docs_index.docsIndex(allocator, "all", docs_files[0..], 0, 2)) |result| {
                var owned = result;
                owned.deinit(allocator);
            } else |err| {
                try std.testing.expectEqual(error.OutOfMemory, err);
            }
        }
        {
            var backing = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer backing.deinit();
            var failing = std.testing.FailingAllocator.init(backing.allocator(), .{ .fail_index = fail_index });
            const allocator = failing.allocator();
            if (docs_index.docsQuery(allocator, "needle", "all", docs_files[0..], "needle autodoc", 0, 3)) |result| {
                var owned = result;
                owned.deinit(allocator);
            } else |err| {
                try std.testing.expectEqual(error.OutOfMemory, err);
            }
        }
        {
            var backing = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer backing.deinit();
            var failing = std.testing.FailingAllocator.init(backing.allocator(), .{ .fail_index = fail_index });
            const allocator = failing.allocator();
            if (docs_index.autodocIngest(allocator, "autodoc_json", "autodoc.json", "{\"name\":\"Needle\",\"docs\":\"Docs\"}", 2)) |result| {
                var owned = result;
                owned.deinit(allocator);
            } else |err| {
                try std.testing.expectEqual(error.OutOfMemory, err);
            }
        }
        {
            var backing = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer backing.deinit();
            var failing = std.testing.FailingAllocator.init(backing.allocator(), .{ .fail_index = fail_index });
            const allocator = failing.allocator();
            if (docs_index.docExampleCheck(allocator, "readme", "README.md", fenced, 2)) |result| {
                var owned = result;
                owned.deinit(allocator);
            } else |err| {
                try std.testing.expectEqual(error.OutOfMemory, err);
            }
        }
        {
            var backing = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer backing.deinit();
            var failing = std.testing.FailingAllocator.init(backing.allocator(), .{ .fail_index = fail_index });
            const allocator = failing.allocator();
            if (docs_index.readmeCommandCheck(allocator, "readme", "README.md", shell, 2)) |result| {
                var owned = result;
                owned.deinit(allocator);
            } else |err| {
                try std.testing.expectEqual(error.OutOfMemory, err);
            }
        }
    }
}
