const std = @import("std");
const cli_io = @import("../../common/cli_io.zig");
const smoke = @import("../smoke_support.zig");

const Io = std.Io;
const JsonValue = std.json.Value;
const readFileAlloc = cli_io.readFileAlloc;

// Extends the stdio fixture with broad tool-family assertions. The client type
// is supplied by stdio_fixtures so this module stays transport-boundary only.

/// Exercises core, ZLS-unavailable, lint, semantic, and profiling tool paths.
pub fn run(client: anytype, workspace: []const u8) !void {
    const profile_plan = try client.callTool("zig_profile_plan", "{\"binary\":\"zig-out/bin/fixture\",\"platform\":\"linux\"}");
    defer client.allocator.free(profile_plan);
    try client.expectPathString(profile_plan, "kind", "zig_profile_plan");

    const panic_trace = try client.callTool("zig_panic_trace_analyze", "{\"content\":\"thread 1 panic: reached unreachable code\\n#0 0x1 in main src/main.zig:1\\n\"}");
    defer client.allocator.free(panic_trace);
    try client.expectPathString(panic_trace, "kind", "zig_panic_trace_analyze");
    try client.expectPathString(panic_trace, "failure_kind", "panic");

    const binary_size = try client.callTool("zig_binary_size", "{\"path\":\"src/main.zig\"}");
    defer client.allocator.free(binary_size);
    try client.expectPathString(binary_size, "kind", "zig_binary_size");
    try client.expectPathString(binary_size, "format", "unknown");

    try client.expectZlsUnavailable("zig_document_open", "{\"file\":\"src/main.zig\",\"content\":\"pub fn main() void {}\\n\"}");
    const close_doc = try client.callTool("zig_document_close", "{\"file\":\"src/main.zig\"}");
    defer client.allocator.free(close_doc);
    try client.expectPathJson(close_doc, "open", .{ .bool = false });
    const document_status = try client.callTool("zig_document_status", "{\"file\":\"src/main.zig\"}");
    defer client.allocator.free(document_status);
    try client.expectPathString(document_status, "file", "src/main.zig");
    try client.expectZlsUnavailable("zig_hover", "{\"file\":\"src/main.zig\",\"line\":0,\"character\":0}");
    try client.expectZlsUnavailable("zig_definition", "{\"file\":\"src/main.zig\",\"line\":0,\"character\":0}");
    try client.expectZlsUnavailable("zig_references", "{\"file\":\"src/main.zig\",\"line\":0,\"character\":0}");
    try client.expectZlsUnavailable("zig_completion", "{\"file\":\"src/main.zig\",\"line\":0,\"character\":0}");
    try client.expectZlsUnavailable("zig_signature_help", "{\"file\":\"src/main.zig\",\"line\":0,\"character\":0}");
    try client.expectZlsUnavailable("zig_workspace_symbols", "{\"query\":\"main\"}");
    try client.expectZlsUnavailable("zig_code_actions", "{\"file\":\"src/main.zig\",\"line\":0,\"character\":0}");
    try client.expectZlsUnavailable("zig_code_action_apply", "{\"file\":\"src/main.zig\",\"line\":0,\"character\":0}");
    try client.expectZlsUnavailable("zig_rename", "{\"file\":\"src/main.zig\",\"line\":0,\"character\":0,\"new_name\":\"renamed\"}");
    try client.expectZlsUnavailable("zig_diagnostics_all", "{\"file\":\"src/main.zig\"}");
    const diagnostics_workspace = try client.callTool("zig_diagnostics_workspace", "{}");
    defer client.allocator.free(diagnostics_workspace);
    try client.expectPathString(diagnostics_workspace, "kind", "zig_diagnostics_workspace");

    const compile_index = try client.callTool("zig_compile_error_index", "{\"text\":\"src/main.zig:1:2: error: fixture failure\\n\"}");
    defer client.allocator.free(compile_index);
    try client.expectPathJson(compile_index, "summary.error_count", .{ .integer = 1 });

    const langref = try client.callTool("zig_lang_ref_search", "{\"query\":\"defer\",\"limit\":1}");
    defer client.allocator.free(langref);
    try client.expectPathString(langref, "kind", "zig_lang_ref_search");
    if (std.mem.indexOf(u8, langref, "Language reference search source:") == null) return error.AssertionFailed;
    if (std.mem.indexOf(u8, langref, "wasm/main.zig") != null) return error.AssertionFailed;

    const next_action = try client.callTool("zigar_next_action", "{\"goal\":\"fix compile error\",\"changed_files\":\"src/main.zig\"}");
    defer client.allocator.free(next_action);
    try client.expectPathString(next_action, "recommended_steps.0.tool", "zig_compile_error_index");
    try client.expectPathString(next_action, "workflow_contract.confidence", "medium");

    const guard = try client.callTool("zigar_patch_guard", "{\"files\":\"src/main.zig zig-out/generated.zig\"}");
    defer client.allocator.free(guard);
    try client.expectPathJson(guard, "safe", .{ .bool = false });

    const api_diff = try client.callTool("zig_public_api_diff", "{\"before\":\"pub fn oldName() void {}\\n\",\"after\":\"pub fn newName() void {}\\n\"}");
    defer client.allocator.free(api_diff);
    try client.expectPathJson(api_diff, "breaking_change_risk", .{ .bool = true });
    try client.expectPathString(api_diff, "capability_tier", "advisory_orientation");

    const ast_decls = try client.callTool("zig_ast_decl_summary", "{\"file\":\"src/tests.zig\"}");
    defer client.allocator.free(ast_decls);
    try client.expectPathString(ast_decls, "capability_tier", "parser_backed");
    if (std.mem.indexOf(u8, ast_decls, "Fixture") == null) return error.AssertionFailed;

    const annotations = try client.callTool("zig_ci_annotations", "{\"file\":\"src/bad.zig\"}");
    defer client.allocator.free(annotations);
    try client.expectPathString(annotations, "artifact_kind", "ci_annotations");
    try client.expectPathString(annotations, "parser_confidence", "high");

    const lint = try client.callTool("zig_lint", "{\"path\":\"src\",\"config\":\"src/main.zig\",\"rules_do\":\"fake-rule\",\"rules_skip\":\"style\",\"args\":\"--verbose\"}");
    defer client.allocator.free(lint);
    try client.expectPathJson(lint, "ok", .{ .bool = true });
    try client.expectPathString(lint, "capability_tier", "zwanzig_backed");
    if (std.mem.indexOf(u8, lint, "diagnostics") == null) return error.AssertionFailed;

    const sarif = try client.callTool("zig_lint_sarif", "{\"path\":\"src\",\"rules_do\":\"fake-rule\"}");
    defer client.allocator.free(sarif);
    try client.expectPathJson(sarif, "ok", .{ .bool = true });
    if (std.mem.indexOf(u8, sarif, "fake-zwanzig") == null or std.mem.indexOf(u8, sarif, "--format") == null) return error.AssertionFailed;

    const rules = try client.callTool("zig_lint_rules", "{}");
    defer client.allocator.free(rules);
    if (std.mem.indexOf(u8, rules, "--dump-cfg") == null) return error.AssertionFailed;

    const zlint = try client.callTool("zig_zlint", "{\"path\":\"src\",\"rules\":\"fake-rule\"}");
    defer client.allocator.free(zlint);
    try client.expectPathString(zlint, "capability_tier", "zlint_backed");
    try client.expectPathString(zlint, "findings.0.rule", "fake.zlint.rule");

    const zlint_sarif = try client.callTool("zig_zlint_sarif", "{\"path\":\"src\"}");
    defer client.allocator.free(zlint_sarif);
    try client.expectPathString(zlint_sarif, "sarif.version", "2.1.0");

    const zlint_rules = try client.callTool("zig_zlint_rules", "{}");
    defer client.allocator.free(zlint_rules);
    try client.expectPathString(zlint_rules, "rules.0.id", "fake.zlint.rule");

    const zlint_fix_preview = try client.callTool("zig_zlint_fix", "{\"path\":\"src\",\"apply\":false}");
    defer client.allocator.free(zlint_fix_preview);
    try client.expectPathJson(zlint_fix_preview, "requires_apply", .{ .bool = true });
    try client.expectPathString(zlint_fix_preview, "argv.3", "--fix");

    const zlint_fix_apply = try client.callTool("zig_zlint_fix", "{\"path\":\"src\",\"apply\":true}");
    defer client.allocator.free(zlint_fix_apply);
    try client.expectPathJson(zlint_fix_apply, "applied", .{ .bool = true });
    try client.expectPathJson(zlint_fix_apply, "summary.error_count", .{ .integer = 0 });

    const semantic_refs = try client.callTool("zig_semantic_refs", "{\"symbol\":\"main\",\"limit\":5}");
    defer client.allocator.free(semantic_refs);
    try client.expectPathString(semantic_refs, "references.0.source", "zlint");
    try client.expectPathJson(semantic_refs, "zlint_ast_files", .{ .integer = 1 });

    const graph = try client.callTool("zig_analysis_graphs", "{\"mode\":\"cfg\",\"path\":\"src/main.zig\",\"output\":\"graphs/cfg\"}");
    defer client.allocator.free(graph);
    try client.expectPathString(graph, "kind", "zig_analysis_graphs");
    try client.expectPathString(graph, "mode", "cfg");
    try expectFileStartsWith(client.allocator, client.io, workspace, "graphs/cfg/fake-cfg.dot", "digraph");

    const flame = try client.callTool("zig_flamegraph", "{\"format\":\"recursive\",\"input\":\"stacks.folded\",\"output\":\"profile.svg\",\"title\":\"fixture\"}");
    defer client.allocator.free(flame);
    try client.expectPathString(flame, "kind", "zig_flamegraph");
    try expectFileStartsWith(client.allocator, client.io, workspace, "profile.svg", "<svg");

    const diff = try client.callTool("zig_flamegraph_diff", "{\"before\":\"before.folded\",\"after\":\"after.folded\",\"output\":\"diff.svg\",\"title\":\"diff fixture\"}");
    defer client.allocator.free(diff);
    try client.expectPathString(diff, "kind", "zig_flamegraph_diff");
    try expectFileStartsWith(client.allocator, client.io, workspace, "diff.svg", "<svg");
}

fn joinedRead(allocator: std.mem.Allocator, io: Io, workspace: []const u8, rel: []const u8) ![]u8 {
    const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ workspace, rel });
    defer allocator.free(path);
    return readFileAlloc(allocator, io, path, 1024 * 1024);
}

fn expectFileStartsWith(allocator: std.mem.Allocator, io: Io, workspace: []const u8, rel: []const u8, prefix: []const u8) !void {
    const bytes = try joinedRead(allocator, io, workspace, rel);
    defer allocator.free(bytes);
    if (!std.mem.startsWith(u8, bytes, prefix)) return error.AssertionFailed;
}

test "stdio core fixtures expose run helper" {
    try std.testing.expect(@hasDecl(@This(), "run"));
}
