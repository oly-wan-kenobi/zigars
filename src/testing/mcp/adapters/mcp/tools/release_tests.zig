const std = @import("std");

const mcp_result = @import("../../../../../adapters/mcp/result.zig");
const release = @import("../../../../../adapters/mcp/tools/release.zig");
const docs_domain = @import("../../../../../domain/release/docs_index.zig");
const app_context = @import("../../../../../app/context.zig");

test "snippet check projection preserves public structured shape" {
    const allocator = std.testing.allocator;
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator,
        \\{"content":"pub fn main() void {\n}\n"}
    , .{});
    defer parsed.deinit();

    const result = try release.zigSnippetCheck(allocator, undefined, parsed.value);
    defer mcp_result.deinitToolResult(allocator, result);

    const obj = result.structuredContent.?.object;
    try std.testing.expectEqualStrings("zig_snippet_check", obj.get("kind").?.string);
    try std.testing.expectEqual(@as(i64, 1), obj.get("schema_version").?.integer);
    const snippet = obj.get("snippet").?.object;
    try std.testing.expectEqualStrings("ok", snippet.get("parse_status").?.string);
    try std.testing.expect(snippet.get("ok").?.bool);
    try std.testing.expectEqual(@as(i64, 0), snippet.get("parse_error_count").?.integer);
}

test "autodoc ingest projection renders hash as JSON-safe hex" {
    const allocator = std.testing.allocator;
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator,
        \\{"content":"{\"name\":\"FixtureSymbol\",\"docs\":\"FixtureSymbol docs\"}","limit":5}
    , .{});
    defer parsed.deinit();

    const result = try release.zigAutodocIngest(allocator, undefined, parsed.value);
    defer mcp_result.deinitToolResult(allocator, result);

    const text = result.content[0].text.text;
    const parsed_text = try std.json.parseFromSlice(std.json.Value, allocator, text, .{});
    defer parsed_text.deinit();
    const raw_reference = parsed_text.value.object.get("raw_reference").?.object;
    try std.testing.expectEqual(@as(usize, 64), raw_reference.get("sha256").?.string.len);
    try std.testing.expectEqualStrings("inline_content", raw_reference.get("source_kind").?.string);
    try std.testing.expectEqual(@as(i64, 1), parsed_text.value.object.get("entry_count").?.integer);
}

test "release docs adapters exercise public wrappers through ports" {
    const allocator = std.testing.allocator;
    const fakes = @import("../../../../fakes/root.zig");

    var workspace = fakes.FakeWorkspaceStore.init(allocator);
    defer workspace.deinit();
    var toolchain = fakes.FakeToolchainEnv.init(allocator);
    defer toolchain.deinit();
    var scanner = fakes.FakeDocsScanner.init(allocator);
    defer scanner.deinit();

    const context = app_context.ReleaseDocsContext{
        .workspace = .{ .root = "/workspace" },
        .tool_paths = .{},
        .timeouts = .{},
        .workspace_store = workspace.port(),
        .toolchain_env = toolchain.port(),
        .docs_scanner = scanner.port(),
    };

    try expectNoBuiltinEnv(&toolchain);
    const builtin_list = try release.zigBuiltinList(allocator, context, null);
    defer mcp_result.deinitToolResult(allocator, builtin_list);
    try expectStructuredKind(builtin_list, "zig_builtin_list");
    try std.testing.expect(std.mem.indexOf(u8, builtin_list.structuredContent.?.object.get("text").?.string, "@import") != null);

    try expectNoBuiltinEnv(&toolchain);
    const builtin_list_json = try release.zigBuiltinListJson(allocator, context, null);
    defer mcp_result.deinitToolResult(allocator, builtin_list_json);
    try std.testing.expect(builtin_list_json.structuredContent.?.object.get("builtins").?.array.items.len > 0);

    var builtin_args = std.json.ObjectMap.empty;
    defer builtin_args.deinit(allocator);
    try builtin_args.put(allocator, "query", .{ .string = "@import" });
    try builtin_args.put(allocator, "limit", .{ .integer = 2 });
    try expectNoBuiltinEnv(&toolchain);
    const builtin_doc = try release.zigBuiltinDoc(allocator, context, .{ .object = builtin_args });
    defer mcp_result.deinitToolResult(allocator, builtin_doc);
    try expectStructuredKind(builtin_doc, "zig_builtin_doc");

    var builtin_json_args = std.json.ObjectMap.empty;
    defer builtin_json_args.deinit(allocator);
    try builtin_json_args.put(allocator, "query", .{ .string = "missing_builtin" });
    try expectNoBuiltinEnv(&toolchain);
    const builtin_doc_json = try release.zigBuiltinDocJson(allocator, context, .{ .object = builtin_json_args });
    defer mcp_result.deinitToolResult(allocator, builtin_doc_json);
    try std.testing.expectEqualStrings("no_builtin_match", builtin_doc_json.structuredContent.?.object.get("no_result_reason").?.string);

    const std_source =
        \\/// Allocator docs
        \\pub fn Allocator() void {}
        \\pub const alpha_value = 1;
        \\
    ;
    var std_search_args = std.json.ObjectMap.empty;
    defer std_search_args.deinit(allocator);
    try std_search_args.put(allocator, "query", .{ .string = "Allocator" });
    try std_search_args.put(allocator, "limit", .{ .integer = 3 });
    try expectStdScan(&toolchain, &scanner, "release_docs.std_search", std_source);
    const std_search = try release.zigStdSearch(allocator, context, .{ .object = std_search_args });
    defer mcp_result.deinitToolResult(allocator, std_search);
    try expectStructuredKind(std_search, "zig_std_search");
    try std.testing.expect(std.mem.indexOf(u8, std_search.structuredContent.?.object.get("text").?.string, "Allocator") != null);

    var std_search_json_args = std.json.ObjectMap.empty;
    defer std_search_json_args.deinit(allocator);
    try std_search_json_args.put(allocator, "query", .{ .string = "nope" });
    try expectStdScan(&toolchain, &scanner, "release_docs.std_search", std_source);
    const std_search_json = try release.zigStdSearchJson(allocator, context, .{ .object = std_search_json_args });
    defer mcp_result.deinitToolResult(allocator, std_search_json);
    try std.testing.expectEqualStrings("no_std_source_match", std_search_json.structuredContent.?.object.get("no_result_reason").?.string);

    var std_item_args = std.json.ObjectMap.empty;
    defer std_item_args.deinit(allocator);
    try std_item_args.put(allocator, "name", .{ .string = "std.mem.Allocator" });
    try expectStdScan(&toolchain, &scanner, "release_docs.std_item", std_source);
    const std_item = try release.zigStdItem(allocator, context, .{ .object = std_item_args });
    defer mcp_result.deinitToolResult(allocator, std_item);
    try expectStructuredKind(std_item, "zig_std_item");

    var std_item_json_args = std.json.ObjectMap.empty;
    defer std_item_json_args.deinit(allocator);
    try std_item_json_args.put(allocator, "name", .{ .string = "std.mem.Allocator" });
    try expectStdScan(&toolchain, &scanner, "release_docs.std_item", std_source);
    const std_item_json = try release.zigStdItemJson(allocator, context, .{ .object = std_item_json_args });
    defer mcp_result.deinitToolResult(allocator, std_item_json);
    try std.testing.expectEqualStrings("Allocator", std_item_json.structuredContent.?.object.get("decl_name").?.string);

    var signature_args = std.json.ObjectMap.empty;
    defer signature_args.deinit(allocator);
    try signature_args.put(allocator, "name", .{ .string = "std.mem.Allocator" });
    try expectStdScan(&toolchain, &scanner, "release_docs.std_item", std_source);
    const signature = try release.zigStdSignature(allocator, context, .{ .object = signature_args });
    defer mcp_result.deinitToolResult(allocator, signature);
    try expectStructuredKind(signature, "zig_std_signature");

    const langref_probe = "Zig Language Reference";
    const langref_html =
        \\<html><body><h2 id="Pointers">Pointers</h2><p>Pointer docs are local.</p></body></html>
    ;
    var langref_args = std.json.ObjectMap.empty;
    defer langref_args.deinit(allocator);
    try langref_args.put(allocator, "query", .{ .string = "Pointer" });
    try expectLangref(&toolchain, &scanner, langref_probe, langref_html);
    const langref = try release.zigLangRefSearch(allocator, context, .{ .object = langref_args });
    defer mcp_result.deinitToolResult(allocator, langref);
    try expectStructuredKind(langref, "zig_lang_ref_search");

    var langref_json_args = std.json.ObjectMap.empty;
    defer langref_json_args.deinit(allocator);
    try langref_json_args.put(allocator, "query", .{ .string = "Pointer" });
    try expectLangref(&toolchain, &scanner, langref_probe, langref_html);
    const langref_json = try release.zigLangRefSearchJson(allocator, context, .{ .object = langref_json_args });
    defer mcp_result.deinitToolResult(allocator, langref_json);
    try std.testing.expectEqualStrings("installed_html_heading_scan", langref_json.structuredContent.?.object.get("index_metadata").?.object.get("index_strategy").?.string);

    var langref_item_args = std.json.ObjectMap.empty;
    defer langref_item_args.deinit(allocator);
    try langref_item_args.put(allocator, "query", .{ .string = "Pointer" });
    try expectLangref(&toolchain, &scanner, langref_probe, langref_html);
    const langref_item = try release.zigLangrefItem(allocator, context, .{ .object = langref_item_args });
    defer mcp_result.deinitToolResult(allocator, langref_item);
    try expectStructuredKind(langref_item, "zig_langref_item");

    var index_args = std.json.ObjectMap.empty;
    defer index_args.deinit(allocator);
    try index_args.put(allocator, "scope", .{ .string = "docs" });
    try scanner.expectWorkspaceScan(.{ .max_files = docs_domain.default_path_scan_limit, .provenance = "release_docs.workspace_docs_scan" }, &.{ "README.md", "docs/guide.md" });
    try workspace.expectRead(.{ .path = "README.md", .max_bytes = docs_domain.std_source_read_limit, .provenance = "release_docs.workspace_docs_read" }, "# Title\nNeedle\n");
    try workspace.expectRead(.{ .path = "docs/guide.md", .max_bytes = docs_domain.std_source_read_limit, .provenance = "release_docs.workspace_docs_read" }, "Guide body\n");
    const docs_index = try release.zigDocsIndexBuild(allocator, context, .{ .object = index_args });
    defer mcp_result.deinitToolResult(allocator, docs_index);
    try expectStructuredKind(docs_index, "zig_docs_index_build");

    var docs_query_args = std.json.ObjectMap.empty;
    defer docs_query_args.deinit(allocator);
    try docs_query_args.put(allocator, "query", .{ .string = "Needle" });
    try docs_query_args.put(allocator, "scope", .{ .string = "docs" });
    try scanner.expectWorkspaceScan(.{ .max_files = docs_domain.default_path_scan_limit, .provenance = "release_docs.workspace_docs_scan" }, &.{"README.md"});
    try workspace.expectRead(.{ .path = "README.md", .max_bytes = docs_domain.std_source_read_limit, .provenance = "release_docs.workspace_docs_read" }, "Needle docs\n");
    const docs_query = try release.zigDocsQuery(allocator, context, .{ .object = docs_query_args });
    defer mcp_result.deinitToolResult(allocator, docs_query);
    try expectStructuredKind(docs_query, "zig_docs_query");

    var project_query_args = std.json.ObjectMap.empty;
    defer project_query_args.deinit(allocator);
    try project_query_args.put(allocator, "query", .{ .string = "Autodoc" });
    try project_query_args.put(allocator, "scope", .{ .string = "docs" });
    try project_query_args.put(allocator, "autodoc", .{ .string = "Autodoc match" });
    try scanner.expectWorkspaceScan(.{ .max_files = docs_domain.default_path_scan_limit, .provenance = "release_docs.workspace_docs_scan" }, &.{"README.md"});
    try workspace.expectRead(.{ .path = "README.md", .max_bytes = docs_domain.std_source_read_limit, .provenance = "release_docs.workspace_docs_read" }, "No match\n");
    const project_query = try release.zigProjectDocsQuery(allocator, context, .{ .object = project_query_args });
    defer mcp_result.deinitToolResult(allocator, project_query);
    try expectStructuredKind(project_query, "zig_project_docs_query");

    var autodoc_args = std.json.ObjectMap.empty;
    defer autodoc_args.deinit(allocator);
    try autodoc_args.put(allocator, "content", .{ .string = "{\"name\":\"Thing\",\"doc\":\"Docs\"}" });
    const autodoc = try release.zigAutodocIngest(allocator, context, .{ .object = autodoc_args });
    defer mcp_result.deinitToolResult(allocator, autodoc);
    try expectStructuredKind(autodoc, "zig_autodoc_ingest");

    var example_args = std.json.ObjectMap.empty;
    defer example_args.deinit(allocator);
    try example_args.put(allocator, "content", .{ .string = "```zig\npub fn ok() void {}\n```\n" });
    const examples = try release.zigDocExampleCheck(allocator, context, .{ .object = example_args });
    defer mcp_result.deinitToolResult(allocator, examples);
    try expectStructuredKind(examples, "zig_doc_example_check");

    var readme_args = std.json.ObjectMap.empty;
    defer readme_args.deinit(allocator);
    try readme_args.put(allocator, "content", .{ .string = "zig build test\n" });
    const readme = try release.zigReadmeCommandCheck(allocator, context, .{ .object = readme_args });
    defer mcp_result.deinitToolResult(allocator, readme);
    try expectStructuredKind(readme, "zig_readme_command_check");

    const missing_builtin = try release.zigBuiltinDoc(allocator, context, null);
    defer mcp_result.deinitToolResult(allocator, missing_builtin);
    try std.testing.expect(missing_builtin.is_error);

    try workspace.verify();
    try toolchain.verify();
    try scanner.verify();
}

fn expectStructuredKind(result: anytype, kind: []const u8) !void {
    try std.testing.expect(result.structuredContent != null);
    try std.testing.expectEqualStrings(kind, result.structuredContent.?.object.get("kind").?.string);
}

fn expectNoBuiltinEnv(toolchain: anytype) !void {
    try toolchain.expectGetError(.{ .key = "version", .provenance = "release_docs.builtin_version" }, error.FileNotFound);
    try toolchain.expectGetError(.{ .key = "std_dir", .provenance = "release_docs.builtin_source" }, error.FileNotFound);
}

fn expectStdScan(toolchain: anytype, scanner: anytype, provenance: []const u8, source: []const u8) !void {
    try toolchain.expectGet(.{ .key = "std_dir", .provenance = provenance }, "/zig/lib/std");
    try scanner.expectAbsoluteScan(.{ .root = "/zig/lib/std", .max_files = docs_domain.default_path_scan_limit, .provenance = "release_docs.std_scan" }, &.{"mem.zig"});
    try scanner.expectRead(.{ .path = "/zig/lib/std/mem.zig", .max_bytes = docs_domain.std_source_read_limit, .provenance = "release_docs.std_read" }, source);
}

fn expectLangref(toolchain: anytype, scanner: anytype, probe: []const u8, html: []const u8) !void {
    try toolchain.expectGet(.{ .key = "lib_dir", .provenance = "release_docs.langref" }, "/zig/lib");
    try scanner.expectRead(.{ .path = "/zig/lib/doc/langref.html", .max_bytes = docs_domain.langref_probe_read_limit, .provenance = "release_docs.langref_probe" }, probe);
    try scanner.expectRead(.{ .path = "/zig/lib/doc/langref.html", .max_bytes = docs_domain.langref_html_read_limit, .provenance = "release_docs.langref_read" }, html);
}
