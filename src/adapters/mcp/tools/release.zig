//! Release and documentation MCP adapters over release workflow use cases.
const std = @import("std");
const mcp = @import("mcp");

const app_context = @import("../../../app/context.zig");
const docs_usecases = @import("../../../app/usecases/release/docs_index.zig");
const workflows = @import("../../../app/usecases/release/workflows.zig");
const ci_evidence = @import("../../../app/usecases/release/ci_evidence.zig");
const release_drift = @import("../../../app/usecases/release/drift.zig");
const support = @import("../../../app/usecases/usecase_support.zig");
const docs_domain = @import("../../../domain/release/docs_index.zig");
const mcp_errors = @import("../errors.zig");
const mcp_result = @import("../result.zig");

/// Schema version emitted in structured release and drift contract payloads.
const schema_version = 1;

/// Handles MCP `zig_ci_annotations` requests by delegating to app logic and shaping owned results/errors.
pub fn zigCiAnnotations(allocator: std.mem.Allocator, context: app_context.ReleaseWorkflowContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invokeCi(allocator, context, args, "zig_ci_annotations", ci_evidence.zigCiAnnotations);
}

/// Handles MCP `zig_junit` requests by delegating to app logic and shaping owned results/errors.
pub fn zigJunit(allocator: std.mem.Allocator, context: app_context.ReleaseWorkflowContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invokeCi(allocator, context, args, "zig_junit", ci_evidence.zigJunit);
}

/// Handles MCP `zig_matrix_check` requests by delegating to app logic and shaping owned results/errors.
pub fn zigMatrixCheck(allocator: std.mem.Allocator, context: app_context.ReleaseWorkflowContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invokeCi(allocator, context, args, "zig_matrix_check", ci_evidence.zigMatrixCheck);
}

/// Handles MCP `zig_ci_ingest` requests by delegating to app logic and shaping owned results/errors.
pub fn zigCiIngest(allocator: std.mem.Allocator, context: app_context.ReleaseWorkflowContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invokeWorkflow(allocator, context, args, "zig_ci_ingest", workflows.zigCiIngest);
}

/// Handles MCP `zig_ci_repro_plan` requests by delegating to app logic and shaping owned results/errors.
pub fn zigCiReproPlan(allocator: std.mem.Allocator, context: app_context.ReleaseWorkflowContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invokeWorkflow(allocator, context, args, "zig_ci_repro_plan", workflows.zigCiReproPlan);
}

/// Handles MCP `zig_ci_failure_map` requests by delegating to app logic and shaping owned results/errors.
pub fn zigCiFailureMap(allocator: std.mem.Allocator, context: app_context.ReleaseWorkflowContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invokeWorkflow(allocator, context, args, "zig_ci_failure_map", workflows.zigCiFailureMap);
}

/// Handles MCP `zig_release_plan` requests by delegating to app logic and shaping owned results/errors.
pub fn zigReleasePlan(allocator: std.mem.Allocator, context: app_context.ReleaseWorkflowContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invokeWorkflow(allocator, context, args, "zig_release_plan", workflows.zigReleasePlan);
}

/// Handles MCP `zig_semver_suggest` requests by delegating to app logic and shaping owned results/errors.
pub fn zigSemverSuggest(allocator: std.mem.Allocator, context: app_context.ReleaseWorkflowContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invokeWorkflow(allocator, context, args, "zig_semver_suggest", workflows.zigSemverSuggest);
}

/// Handles MCP `zig_release_notes_draft` requests by delegating to app logic and shaping owned results/errors.
pub fn zigReleaseNotesDraft(allocator: std.mem.Allocator, context: app_context.ReleaseWorkflowContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invokeWorkflow(allocator, context, args, "zig_release_notes_draft", workflows.zigReleaseNotesDraft);
}

/// Handles MCP `zig_release_evidence_pack` requests by delegating to app logic and shaping owned results/errors.
pub fn zigReleaseEvidencePack(allocator: std.mem.Allocator, context: app_context.ReleaseWorkflowContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invokeWorkflow(allocator, context, args, "zig_release_evidence_pack", workflows.zigReleaseEvidencePack);
}

/// Handles MCP `zig_api_baseline_init` requests by delegating to app logic and shaping owned results/errors.
pub fn zigApiBaselineInit(allocator: std.mem.Allocator, context: app_context.ReleaseWorkflowContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invokeWorkflow(allocator, context, args, "zig_api_baseline_init", workflows.zigApiBaselineInit);
}

/// Handles MCP `zig_api_check` requests by delegating to app logic and shaping owned results/errors.
pub fn zigApiCheck(allocator: std.mem.Allocator, context: app_context.ReleaseWorkflowContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invokeWorkflow(allocator, context, args, "zig_api_check", workflows.zigApiCheck);
}

/// Handles MCP `zig_api_diff_baseline` requests by delegating to app logic and shaping owned results/errors.
pub fn zigApiDiffBaseline(allocator: std.mem.Allocator, context: app_context.ReleaseWorkflowContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invokeWorkflow(allocator, context, args, "zig_api_diff_baseline", workflows.zigApiDiffBaseline);
}

/// Handles MCP `zig_api_docs_diff` requests by delegating to app logic and shaping owned results/errors.
pub fn zigApiDocsDiff(allocator: std.mem.Allocator, context: app_context.ReleaseWorkflowContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invokeWorkflow(allocator, context, args, "zig_api_docs_diff", workflows.zigApiDocsDiff);
}

/// Handles MCP `zigars_docs_drift_check` requests by delegating to app logic and shaping owned results/errors.
pub fn zigarsDocsDriftCheck(allocator: std.mem.Allocator, context: app_context.ReleaseWorkflowContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invokeDrift(allocator, context, args, "zigars_docs_drift_check", release_drift.zigarsDocsDriftCheck);
}

/// Handles MCP `zigars_release_claim_check` requests by delegating to app logic and shaping owned results/errors.
pub fn zigarsReleaseClaimCheck(allocator: std.mem.Allocator, context: app_context.ReleaseWorkflowContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invokeDrift(allocator, context, args, "zigars_release_claim_check", release_drift.zigarsReleaseClaimCheck);
}

/// Handles MCP `zigars_tool_index_check` requests by delegating to app logic and shaping owned results/errors.
pub fn zigarsToolIndexCheck(allocator: std.mem.Allocator, context: app_context.ReleaseWorkflowContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invokeDrift(allocator, context, args, "zigars_tool_index_check", release_drift.zigarsToolIndexCheck);
}

/// Handles MCP `zig_builtin_list` requests by delegating to app logic and shaping owned results/errors.
pub fn zigBuiltinList(allocator: std.mem.Allocator, context: app_context.ReleaseDocsContext, _: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const result = docs_usecases.builtinList(scratch, context) catch |err| return docsBackendError(allocator, "zig_builtin_list", "builtin_list", err, "");
    const output = builtinListText(scratch, result) catch return error.OutOfMemory;
    return structuredText(allocator, "zig_builtin_list", output);
}

/// Handles MCP `zig_builtin_list_json` requests by delegating to app logic and shaping owned results/errors.
pub fn zigBuiltinListJson(allocator: std.mem.Allocator, context: app_context.ReleaseDocsContext, _: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const result = docs_usecases.builtinList(scratch, context) catch |err| return docsBackendError(allocator, "zig_builtin_list_json", "builtin_list", err, "");
    const value = builtinListValue(scratch, result) catch return error.OutOfMemory;
    return mcp_result.structured(allocator, value);
}

/// Handles MCP `zig_builtin_doc` requests by delegating to app logic and shaping owned results/errors.
pub fn zigBuiltinDoc(allocator: std.mem.Allocator, context: app_context.ReleaseDocsContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    // Keep this logic centralized so callers observe one consistent behavior path.
    const query = argString(args, "query") orelse return mcp_errors.missingArgument(allocator, "zig_builtin_doc", "query", "string");
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const result = docs_usecases.builtinDoc(scratch, context, query, normalizedLimit(args, "limit", docs_usecases.default_std_limit)) catch |err| return docsBackendError(allocator, "zig_builtin_doc", "builtin_doc", err, query);
    const output = builtinDocText(scratch, result) catch return error.OutOfMemory;
    return structuredText(allocator, "zig_builtin_doc", output);
}

/// Handles MCP `zig_builtin_doc_json` requests by delegating to app logic and shaping owned results/errors.
pub fn zigBuiltinDocJson(allocator: std.mem.Allocator, context: app_context.ReleaseDocsContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    // Keep this logic centralized so callers observe one consistent behavior path.
    const query = argString(args, "query") orelse return mcp_errors.missingArgument(allocator, "zig_builtin_doc_json", "query", "string");
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const result = docs_usecases.builtinDoc(scratch, context, query, normalizedLimit(args, "limit", docs_usecases.default_std_limit)) catch |err| return docsBackendError(allocator, "zig_builtin_doc_json", "builtin_doc", err, query);
    const value = builtinDocValue(scratch, result) catch return error.OutOfMemory;
    return mcp_result.structured(allocator, value);
}

/// Handles MCP `zig_std_search` requests by delegating to app logic and shaping owned results/errors.
pub fn zigStdSearch(allocator: std.mem.Allocator, context: app_context.ReleaseDocsContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    // Keep this logic centralized so callers observe one consistent behavior path.
    const query = argString(args, "query") orelse return mcp_errors.missingArgument(allocator, "zig_std_search", "query", "string");
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const result = docs_usecases.stdSearch(scratch, context, query, normalizedLimit(args, "limit", docs_usecases.default_std_limit)) catch |err| return docsError(allocator, "zig_std_search", "search_std", "scan_std_sources", "search_failed", err, query, "Confirm the Zig standard-library directory is readable, then retry with a narrower query if needed.");
    const value = stdSearchValue(scratch, result) catch return error.OutOfMemory;
    const output = stdSearchTextFromValue(scratch, value) catch return error.OutOfMemory;
    return structuredText(allocator, "zig_std_search", output);
}

/// Handles MCP `zig_std_search_json` requests by delegating to app logic and shaping owned results/errors.
pub fn zigStdSearchJson(allocator: std.mem.Allocator, context: app_context.ReleaseDocsContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    // Keep this logic centralized so callers observe one consistent behavior path.
    const query = argString(args, "query") orelse return mcp_errors.missingArgument(allocator, "zig_std_search_json", "query", "string");
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const result = docs_usecases.stdSearch(scratch, context, query, normalizedLimit(args, "limit", docs_usecases.default_std_limit)) catch |err| return docsError(allocator, "zig_std_search_json", "search_std_json", "scan_std_sources", "search_failed", err, query, "Confirm the Zig standard-library directory exists and is readable.");
    const value = stdSearchValue(scratch, result) catch return error.OutOfMemory;
    return mcp_result.structured(allocator, value);
}

/// Handles MCP `zig_std_item` requests by delegating to app logic and shaping owned results/errors.
pub fn zigStdItem(allocator: std.mem.Allocator, context: app_context.ReleaseDocsContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    // Keep this logic centralized so callers observe one consistent behavior path.
    const name = argString(args, "name") orelse return mcp_errors.missingArgument(allocator, "zig_std_item", "name", "string");
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const result = docs_usecases.stdItem(scratch, context, name, normalizedLimit(args, "limit", docs_usecases.default_std_limit)) catch |err| return docsError(allocator, "zig_std_item", "std_item", "scan_std_sources", "search_failed", err, name, "Confirm the Zig standard-library directory is readable, then retry with a fully qualified std item.");
    const value = stdItemValue(scratch, result) catch return error.OutOfMemory;
    const output = stdItemTextFromValue(scratch, value) catch return error.OutOfMemory;
    return structuredText(allocator, "zig_std_item", output);
}

/// Handles MCP `zig_std_item_json` requests by delegating to app logic and shaping owned results/errors.
pub fn zigStdItemJson(allocator: std.mem.Allocator, context: app_context.ReleaseDocsContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    // Keep this logic centralized so callers observe one consistent behavior path.
    const name = argString(args, "name") orelse return mcp_errors.missingArgument(allocator, "zig_std_item_json", "name", "string");
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const result = docs_usecases.stdItem(scratch, context, name, normalizedLimit(args, "limit", docs_usecases.default_std_limit)) catch |err| return docsError(allocator, "zig_std_item_json", "std_item_json", "scan_std_sources", "search_failed", err, name, "Confirm the Zig standard-library directory is readable, then retry with a fully qualified std item.");
    const value = stdItemValue(scratch, result) catch return error.OutOfMemory;
    return mcp_result.structured(allocator, value);
}

/// Handles MCP `zig_lang_ref_search` requests by delegating to app logic and shaping owned results/errors.
pub fn zigLangRefSearch(allocator: std.mem.Allocator, context: app_context.ReleaseDocsContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    // Keep this logic centralized so callers observe one consistent behavior path.
    const query = argString(args, "query") orelse return mcp_errors.missingArgument(allocator, "zig_lang_ref_search", "query", "string");
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const result = docs_usecases.langrefSearch(scratch, context, query, normalizedLimit(args, "limit", docs_usecases.default_std_limit)) catch |err| return docsError(allocator, "zig_lang_ref_search", "search_langref", "scan_langref", "search_failed", err, query, "Confirm the Zig language reference is readable, then retry with a narrower query if needed.");
    const value = langrefValue(scratch, result) catch return error.OutOfMemory;
    const output = langrefTextFromValue(scratch, value) catch return error.OutOfMemory;
    return structuredText(allocator, "zig_lang_ref_search", output);
}

/// Handles MCP `zig_lang_ref_search_json` requests by delegating to app logic and shaping owned results/errors.
pub fn zigLangRefSearchJson(allocator: std.mem.Allocator, context: app_context.ReleaseDocsContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    // Keep this logic centralized so callers observe one consistent behavior path.
    const query = argString(args, "query") orelse return mcp_errors.missingArgument(allocator, "zig_lang_ref_search_json", "query", "string");
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const result = docs_usecases.langrefSearch(scratch, context, query, normalizedLimit(args, "limit", docs_usecases.default_std_limit)) catch |err| return docsError(allocator, "zig_lang_ref_search_json", "search_langref_json", "scan_langref", "search_failed", err, query, "Confirm the Zig language reference is readable, then retry with a narrower query if needed.");
    const value = langrefValue(scratch, result) catch return error.OutOfMemory;
    return mcp_result.structured(allocator, value);
}

/// Handles MCP `zig_docs_index_build` requests by delegating to app logic and shaping owned results/errors.
pub fn zigDocsIndexBuild(allocator: std.mem.Allocator, context: app_context.ReleaseDocsContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const result = docs_usecases.docsIndexBuild(scratch, context, argString(args, "scope") orelse "workspace", normalizedLimit(args, "limit", docs_usecases.default_docs_index_limit)) catch |err| return docsToolError(allocator, "zig_docs_index_build", "build_index", err);
    const value = docsIndexBuildValue(scratch, result) catch return error.OutOfMemory;
    return mcp_result.structured(allocator, value);
}

/// Handles MCP `zig_docs_query` requests by delegating to app logic and shaping owned results/errors.
pub fn zigDocsQuery(allocator: std.mem.Allocator, context: app_context.ReleaseDocsContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const query = argString(args, "query") orelse return mcp_errors.missingArgument(allocator, "zig_docs_query", "query", "search query");
    return docsQueryTool(allocator, context, args, "zig_docs_query", query);
}

/// Handles MCP `zig_project_docs_query` requests by delegating to app logic and shaping owned results/errors.
pub fn zigProjectDocsQuery(allocator: std.mem.Allocator, context: app_context.ReleaseDocsContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const query = argString(args, "query") orelse return mcp_errors.missingArgument(allocator, "zig_project_docs_query", "query", "project docs query");
    return docsQueryTool(allocator, context, args, "zig_project_docs_query", query);
}

/// Handles MCP `zig_std_signature` requests by delegating to app logic and shaping owned results/errors.
pub fn zigStdSignature(allocator: std.mem.Allocator, context: app_context.ReleaseDocsContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    // Keep this logic centralized so callers observe one consistent behavior path.
    const name = argString(args, "name") orelse return mcp_errors.missingArgument(allocator, "zig_std_signature", "name", "stdlib item name");
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const result = docs_usecases.stdItem(scratch, context, name, normalizedLimit(args, "limit", docs_usecases.default_std_limit)) catch |err| return docsBackendError(allocator, "zig_std_signature", "std_item", err, name);
    const source = stdItemValue(scratch, result) catch return error.OutOfMemory;
    var obj = std.json.ObjectMap.empty;
    try putBase(scratch, &obj, "zig_std_signature", "Local Zig stdlib source declaration scan", "medium", &.{
        "Signatures come from source scanning, not rendered autodoc or semantic type resolution.",
    });
    try obj.put(scratch, "name", .{ .string = name });
    try obj.put(scratch, "signature", .{ .string = if (result.matches.len > 0) result.matches[0].snippet else "" });
    try obj.put(scratch, "source", source);
    return mcp_result.structured(allocator, .{ .object = obj });
}

/// Handles MCP `zig_langref_item` requests by delegating to app logic and shaping owned results/errors.
pub fn zigLangrefItem(allocator: std.mem.Allocator, context: app_context.ReleaseDocsContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    // Keep this logic centralized so callers observe one consistent behavior path.
    const query = argString(args, "query") orelse return mcp_errors.missingArgument(allocator, "zig_langref_item", "query", "language reference item query");
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const result = docs_usecases.langrefSearch(scratch, context, query, normalizedLimit(args, "limit", docs_usecases.default_langref_item_limit)) catch |err| return docsBackendError(allocator, "zig_langref_item", "langref_item", err, query);
    const item = langrefValue(scratch, result) catch return error.OutOfMemory;
    var obj = std.json.ObjectMap.empty;
    try putBase(scratch, &obj, "zig_langref_item", "Installed langref or bundled fallback search", "medium", &.{
        "Result quality depends on installed langref availability; fallback data is intentionally partial.",
    });
    try obj.put(scratch, "query", .{ .string = query });
    try obj.put(scratch, "item", item);
    return mcp_result.structured(allocator, .{ .object = obj });
}

/// Handles MCP `zig_autodoc_ingest` requests by delegating to app logic and shaping owned results/errors.
pub fn zigAutodocIngest(allocator: std.mem.Allocator, context: app_context.ReleaseDocsContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const result = docs_usecases.autodocIngest(scratch, context, evidenceRequest(args, "zig_autodoc_ingest", true, null), normalizedLimit(args, "limit", docs_usecases.default_autodoc_limit)) catch |err| return evidenceInputError(allocator, context, "zig_autodoc_ingest", args, err);
    const value = autodocIngestValue(scratch, result) catch return error.OutOfMemory;
    return mcp_result.structured(allocator, value);
}

/// Handles MCP `zig_doc_example_check` requests by delegating to app logic and shaping owned results/errors.
pub fn zigDocExampleCheck(allocator: std.mem.Allocator, context: app_context.ReleaseDocsContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const result = docs_usecases.docExampleCheck(scratch, context, evidenceRequest(args, "zig_doc_example_check", true, null), normalizedLimit(args, "limit", docs_usecases.default_doc_example_limit)) catch |err| return evidenceInputError(allocator, context, "zig_doc_example_check", args, err);
    const value = docExampleCheckValue(scratch, result) catch return error.OutOfMemory;
    return mcp_result.structured(allocator, value);
}

/// Handles MCP `zig_snippet_check` requests by delegating to app logic and shaping owned results/errors.
pub fn zigSnippetCheck(allocator: std.mem.Allocator, _: app_context.ReleaseDocsContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    // Keep this logic centralized so callers observe one consistent behavior path.
    const content = argString(args, "content") orelse return mcp_errors.missingArgument(allocator, "zig_snippet_check", "content", "Zig source snippet");
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const result = docs_usecases.snippetCheck(scratch, content) catch |err| return docsToolError(allocator, "zig_snippet_check", "parse_snippet", err);
    var obj = std.json.ObjectMap.empty;
    try putBase(scratch, &obj, "zig_snippet_check", "std.zig.Ast syntax parse of caller-provided snippet", "high", &.{
        "Syntax parsing does not run semantic analysis, imports, tests, or examples.",
    });
    try obj.put(scratch, "snippet", try snippetCheckValue(scratch, result));
    return mcp_result.structured(allocator, .{ .object = obj });
}

/// Handles MCP `zig_readme_command_check` requests by delegating to app logic and shaping owned results/errors.
pub fn zigReadmeCommandCheck(allocator: std.mem.Allocator, context: app_context.ReleaseDocsContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const result = docs_usecases.readmeCommandCheck(scratch, context, evidenceRequest(args, "zig_readme_command_check", true, "README.md"), normalizedLimit(args, "limit", docs_usecases.default_readme_command_limit)) catch |err| return evidenceInputError(allocator, context, "zig_readme_command_check", args, err);
    const value = readmeCommandCheckValue(scratch, result) catch return error.OutOfMemory;
    return mcp_result.structured(allocator, value);
}

/// Invokes a release workflow and maps the result to MCP output.
fn invokeWorkflow(
    allocator: std.mem.Allocator,
    context: app_context.ReleaseWorkflowContext,
    args: ?std.json.Value,
    comptime tool_name: []const u8,
    comptime func: anytype,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    // Route through a single workflow path so policy checks run in a consistent order.
    var app = workflows.App.init(context, allocator);
    const result = func(&app, allocator, args) catch |err| return workflowUsecaseError(allocator, tool_name, "release_workflow", err);
    return finishWorkflowResult(allocator, result);
}

/// Invokes a CI evidence workflow and maps the result to MCP output.
fn invokeCi(
    allocator: std.mem.Allocator,
    context: app_context.ReleaseWorkflowContext,
    args: ?std.json.Value,
    comptime tool_name: []const u8,
    comptime func: anytype,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    // Keep this logic centralized so callers observe one consistent behavior path.
    var app = ci_evidence.App.init(context, allocator);
    const result = func(&app, allocator, args) catch |err| return workflowUsecaseError(allocator, tool_name, "ci_evidence", err);
    return finishWorkflowResult(allocator, result);
}

/// Invokes a release drift workflow and maps the result to MCP output.
fn invokeDrift(
    allocator: std.mem.Allocator,
    context: app_context.ReleaseWorkflowContext,
    args: ?std.json.Value,
    comptime tool_name: []const u8,
    comptime func: anytype,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    // Keep this logic centralized so callers observe one consistent behavior path.
    var app = release_drift.App.init(context, allocator);
    const result = func(&app, allocator, args) catch |err| return workflowUsecaseError(allocator, tool_name, "release_drift", err);
    return finishWorkflowResult(allocator, result);
}

/// Wraps a workflow result, which owns its JSON value on `allocator`. On the
/// error path the value is copied into a structured error and then freed here
/// (the error envelope does not take ownership); on the success path ownership
/// of the value transfers into the returned result.
fn finishWorkflowResult(allocator: std.mem.Allocator, result: workflows.Result) mcp.tools.ToolError!mcp.tools.ToolResult {
    if (result.is_error) {
        defer mcp_result.deinitOwnedValue(allocator, result.value);
        return mcp_result.structuredError(allocator, result.value);
    }
    return mcp_result.structuredOwned(allocator, result.value);
}

/// Maps workflow usecase error failures to structured MCP errors.
fn workflowUsecaseError(allocator: std.mem.Allocator, tool_name: []const u8, operation: []const u8, err: anyerror) mcp.tools.ToolError!mcp.tools.ToolResult {
    // Preserve a single error-shaping path so callers receive consistent metadata.
    if (err == error.OutOfMemory) return error.OutOfMemory;
    return mcp_errors.fromError(allocator, .{
        .tool = tool_name,
        .operation = operation,
        .phase = "run_usecase",
        .code = "release_usecase_failed",
        .category = "release",
        .resolution = "Retry after confirming workspace paths, release evidence inputs, and optional dependency scanner evidence.",
    }, err);
}

/// Routes documentation query arguments to the requested docs workflow.
fn docsQueryTool(allocator: std.mem.Allocator, context: app_context.ReleaseDocsContext, args: ?std.json.Value, tool_name: []const u8, query: []const u8) mcp.tools.ToolError!mcp.tools.ToolResult {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const result = docs_usecases.docsQuery(scratch, context, query, argString(args, "scope") orelse "workspace", argString(args, "autodoc"), normalizedLimit(args, "limit", docs_usecases.default_docs_query_limit)) catch |err| return docsToolError(allocator, tool_name, "query_docs", err);
    const value = docsQueryValue(scratch, tool_name, result) catch return error.OutOfMemory;
    return mcp_result.structured(allocator, value);
}

/// Returns an allocator-owned JSON value for source.
fn sourceValue(allocator: std.mem.Allocator, source: docs_domain.Source) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "id", .{ .string = source.id });
    try obj.put(allocator, "label", .{ .string = source.label });
    try obj.put(allocator, "provenance", .{ .string = source.provenance });
    try obj.put(allocator, "completeness", .{ .string = source.completeness.text() });
    if (source.version) |version| {
        try obj.put(allocator, "version", .{ .string = version });
        try obj.put(allocator, "version_status", .{ .string = if (std.mem.eql(u8, version, "zigars-bundled")) "bundled" else "available" });
    } else {
        try obj.put(allocator, "version", .{ .string = "unavailable" });
        try obj.put(allocator, "version_status", .{ .string = "unavailable" });
    }
    if (source.path) |path| {
        try obj.put(allocator, "path", .{ .string = path });
        try obj.put(allocator, "source_path", .{ .string = path });
    } else {
        try obj.put(allocator, "path", .null);
        try obj.put(allocator, "source_path", .null);
    }
    return .{ .object = obj };
}

/// Adds contract fields to an allocator-owned JSON object.
fn putContractFields(allocator: std.mem.Allocator, obj: *std.json.ObjectMap, source: docs_domain.Source, contract: docs_domain.Contract) !void {
    // Keep this logic centralized so callers observe one consistent behavior path.
    try obj.put(allocator, "source", try sourceValue(allocator, source));
    try obj.put(allocator, "completeness_level", .{ .string = source.completeness.text() });
    try obj.put(allocator, "query", if (contract.query) |query| .{ .string = query } else .null);
    try obj.put(allocator, "limit", if (contract.limit) |limit| .{ .integer = @intCast(limit) } else .null);
    try obj.put(allocator, "result_count", .{ .integer = @intCast(contract.result_count) });
    try obj.put(allocator, "no_result_reason", if (contract.no_result_reason) |reason| .{ .string = reason } else .null);
    try obj.put(allocator, "ranking", .{ .string = contract.ranking });
}

/// Returns an allocator-owned JSON value for builtin list.
fn builtinListValue(allocator: std.mem.Allocator, result: docs_domain.BuiltinListResult) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
    var items = std.json.Array.init(allocator);
    for (docs_domain.builtins) |item| try items.append(try builtinItemValue(allocator, item, null));
    var obj = std.json.ObjectMap.empty;
    try putContractFields(allocator, &obj, docs_domain.curatedBuiltinsSource(), .{
        .result_count = docs_domain.builtins.len,
        .ranking = "curated builtin declaration order",
    });
    try obj.put(allocator, "index_metadata", try builtinIndexMetadataValue(allocator, result.input));
    try obj.put(allocator, "count", .{ .integer = @intCast(docs_domain.builtins.len) });
    try obj.put(allocator, "builtins", .{ .array = items });
    return .{ .object = obj };
}

/// Returns an allocator-owned JSON value for builtin doc.
fn builtinDocValue(allocator: std.mem.Allocator, result: docs_domain.BuiltinDocResult) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
    var matches = std.json.Array.init(allocator);
    for (result.matches) |match| try matches.append(try builtinItemValue(allocator, match.item, match.rank));
    var obj = std.json.ObjectMap.empty;
    try putContractFields(allocator, &obj, docs_domain.curatedBuiltinsSource(), .{
        .query = result.query,
        .limit = result.limit,
        .result_count = result.matches.len,
        .no_result_reason = if (result.matches.len == 0) "no_builtin_match" else null,
        .ranking = "case-insensitive builtin-name substring match in curated order; limit is applied after matching",
    });
    try obj.put(allocator, "index_metadata", try builtinIndexMetadataValue(allocator, result.input));
    try obj.put(allocator, "matches", .{ .array = matches });
    return .{ .object = obj };
}

/// Returns an allocator-owned JSON value for builtin item.
fn builtinItemValue(allocator: std.mem.Allocator, item: docs_domain.BuiltinDoc, rank: ?usize) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    if (rank) |value_rank| try obj.put(allocator, "rank", .{ .integer = @intCast(value_rank) });
    try obj.put(allocator, "name", .{ .string = item.name });
    try obj.put(allocator, "signature", .{ .string = item.signature });
    try obj.put(allocator, "summary", .{ .string = item.summary });
    return .{ .object = obj };
}

/// Returns an allocator-owned JSON value for builtin index metadata.
fn builtinIndexMetadataValue(allocator: std.mem.Allocator, input: docs_domain.BuiltinIndexInput) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "index_strategy", .{ .string = "curated_builtin_index" });
    try obj.put(allocator, "completeness_mode", .{ .string = "partial_curated" });
    try obj.put(allocator, "curated_count", .{ .integer = @intCast(docs_domain.builtins.len) });
    try obj.put(allocator, "toolchain_version", if (input.toolchain_version) |version| .{ .string = version } else .null);
    const drift = input.drift orelse docs_domain.BuiltinDriftInfo{
        .status = if (input.toolchain_version == null) "toolchain_version_unavailable" else "toolchain_version_recorded_builtin_set_not_extracted",
        .confidence = "version_only",
    };
    try obj.put(allocator, "drift_check_status", .{ .string = drift.status });
    try obj.put(allocator, "drift_check_confidence", .{ .string = drift.confidence });
    try obj.put(allocator, "active_builtin_source_path", if (drift.active_source_path) |path| .{ .string = path } else .null);
    try obj.put(allocator, "active_builtin_count", .{ .integer = @intCast(drift.active_count) });
    try obj.put(allocator, "curated_missing_count", .{ .integer = @intCast(drift.curated_missing_count) });
    try obj.put(allocator, "active_extra_count", .{ .integer = @intCast(drift.active_extra_count) });
    try obj.put(allocator, "missing_curated_builtins", try stringArrayValue(allocator, drift.missing_names));
    try obj.put(allocator, "extra_active_builtins_sample", try stringArrayValue(allocator, drift.extra_names_sample));
    try obj.put(allocator, "drift_check_note", .{ .string = "When std/zig/BuiltinFn.zig is readable from the active Zig installation, zigars compares curated builtin entries against that offline source and reports missing curated names plus extra active names." });
    return .{ .object = obj };
}

/// Returns an allocator-owned JSON value for std search.
fn stdSearchValue(allocator: std.mem.Allocator, result: docs_domain.StdSearchResult) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
    var matches = std.json.Array.init(allocator);
    for (result.matches) |match| try matches.append(try stdSourceMatchValue(allocator, match));
    var obj = std.json.ObjectMap.empty;
    try putContractFields(allocator, &obj, docs_domain.stdlibSource(result.std_dir, null), .{
        .query = result.query,
        .limit = result.limit,
        .result_count = result.matches.len,
        .no_result_reason = if (result.total_match_count == 0) "no_std_source_match" else null,
        .ranking = "case-insensitive declaration/source hit sorted by relative path then line; limit is applied after sorting",
    });
    try obj.put(allocator, "index_metadata", try stdIndexMetadataValue(allocator, result.std_dir, result.metadata));
    try obj.put(allocator, "total_match_count", .{ .integer = @intCast(result.total_match_count) });
    try obj.put(allocator, "files_scanned", .{ .integer = @intCast(result.metadata.files_scanned) });
    try obj.put(allocator, "skipped_files", .{ .integer = @intCast(result.metadata.skipped_files) });
    try obj.put(allocator, "walk_errors", .{ .integer = @intCast(result.metadata.walk_errors) });
    try obj.put(allocator, "source_scan_limitations", .{ .string = docs_domain.std_scan_limitations });
    try obj.put(allocator, "matches", .{ .array = matches });
    return .{ .object = obj };
}

/// Returns an allocator-owned JSON value for std source match.
fn stdSourceMatchValue(allocator: std.mem.Allocator, match: docs_domain.StdSourceMatch) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "rank", .{ .integer = @intCast(match.rank) });
    try obj.put(allocator, "root", .{ .string = "std" });
    try obj.put(allocator, "path", .{ .string = match.path });
    try obj.put(allocator, "source_path", .{ .string = match.source_path });
    try obj.put(allocator, "line", .{ .integer = @intCast(match.line) });
    try obj.put(allocator, "snippet", .{ .string = match.snippet });
    try obj.put(allocator, "match_kind", .{ .string = match.match_kind });
    try obj.put(allocator, "decl_name", if (match.decl_name) |value| .{ .string = value } else .null);
    try obj.put(allocator, "qualified_name", if (match.qualified_name) |value| .{ .string = value } else .null);
    try obj.put(allocator, "import_hint", if (match.import_hint) |value| .{ .string = value } else .null);
    try obj.put(allocator, "doc_comments", .{ .string = match.doc_comments });
    try obj.put(allocator, "doc_comment_count", .{ .integer = @intCast(match.doc_comment_count) });
    return .{ .object = obj };
}

/// Returns an allocator-owned JSON value for std item.
fn stdItemValue(allocator: std.mem.Allocator, result: docs_domain.StdItemResult) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
    var matches = std.json.Array.init(allocator);
    for (result.matches) |match| try matches.append(try stdItemMatchValue(allocator, match));
    var obj = std.json.ObjectMap.empty;
    try putContractFields(allocator, &obj, docs_domain.stdlibSource(result.std_dir, null), .{
        .query = result.name,
        .limit = result.limit,
        .result_count = result.matches.len,
        .no_result_reason = if (result.total_match_count == 0) "no_std_item_declaration_match" else null,
        .ranking = "exact declaration-name match, preferring the path implied by a qualified std name, then relative path and line; limit is applied after sorting",
    });
    try obj.put(allocator, "index_metadata", try stdIndexMetadataValue(allocator, result.std_dir, result.metadata));
    try obj.put(allocator, "name", .{ .string = result.name });
    try obj.put(allocator, "decl_name", .{ .string = result.decl_name });
    try obj.put(allocator, "qualified_path_hint", if (result.qualified_path_hint) |hint| .{ .string = hint } else .null);
    try obj.put(allocator, "total_match_count", .{ .integer = @intCast(result.total_match_count) });
    try obj.put(allocator, "files_scanned", .{ .integer = @intCast(result.metadata.files_scanned) });
    try obj.put(allocator, "skipped_files", .{ .integer = @intCast(result.metadata.skipped_files) });
    try obj.put(allocator, "walk_errors", .{ .integer = @intCast(result.metadata.walk_errors) });
    try obj.put(allocator, "source_scan_limitations", .{ .string = docs_domain.std_scan_limitations });
    try obj.put(allocator, "matches", .{ .array = matches });
    return .{ .object = obj };
}

/// Returns an allocator-owned JSON value for std item match.
fn stdItemMatchValue(allocator: std.mem.Allocator, match: docs_domain.StdItemMatch) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "rank", .{ .integer = @intCast(match.rank) });
    try obj.put(allocator, "name", .{ .string = match.name });
    try obj.put(allocator, "decl_name", .{ .string = match.decl_name });
    try obj.put(allocator, "match_kind", .{ .string = match.match_kind });
    try obj.put(allocator, "path", .{ .string = match.path });
    try obj.put(allocator, "source_path", .{ .string = match.source_path });
    try obj.put(allocator, "line", .{ .integer = @intCast(match.line) });
    try obj.put(allocator, "snippet", .{ .string = match.snippet });
    try obj.put(allocator, "doc_comments", .{ .string = match.doc_comments });
    try obj.put(allocator, "doc_comment_count", .{ .integer = @intCast(match.doc_comment_count) });
    try obj.put(allocator, "preferred_path", .{ .bool = match.preferred_path });
    try obj.put(allocator, "qualified_name", .{ .string = match.qualified_name });
    // For a resolved std item the qualified name is the import hint, so both
    // fields intentionally carry the same value (no separate import_hint field).
    try obj.put(allocator, "import_hint", .{ .string = match.qualified_name });
    return .{ .object = obj };
}

/// Returns an allocator-owned JSON value for std index metadata.
fn stdIndexMetadataValue(allocator: std.mem.Allocator, std_dir: []const u8, metadata: docs_domain.StdIndexMetadata) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
    var roots = std.json.Array.init(allocator);
    try roots.append(.{ .string = std_dir });
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "index_strategy", .{ .string = "in_memory_stdlib_source_scan" });
    try obj.put(allocator, "completeness_mode", .{ .string = "source_scan" });
    try obj.put(allocator, "generated_unix", .null);
    try obj.put(allocator, "generated_at", .{ .string = "per_call_in_memory_index" });
    try obj.put(allocator, "source_roots", .{ .array = roots });
    try obj.put(allocator, "max_file_bytes", .{ .integer = docs_domain.std_source_read_limit });
    try obj.put(allocator, "files_scanned", .{ .integer = @intCast(metadata.files_scanned) });
    try obj.put(allocator, "skipped_files", .{ .integer = @intCast(metadata.skipped_files) });
    try obj.put(allocator, "walk_errors", .{ .integer = @intCast(metadata.walk_errors) });
    try obj.put(allocator, "doc_comment_extraction", .{ .string = "adjacent_triple_slash_comments_for_std_item_matches" });
    try obj.put(allocator, "source_scan_limitations", .{ .string = docs_domain.std_scan_limitations });
    return .{ .object = obj };
}

/// Returns an allocator-owned JSON value for langref.
fn langrefValue(allocator: std.mem.Allocator, result: docs_domain.LangrefSearchResult) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
    var matches = std.json.Array.init(allocator);
    for (result.matches) |match| try matches.append(try langrefMatchValue(allocator, match));
    const bundled = std.mem.eql(u8, result.source.id, "bundled_langref_index");
    var obj = std.json.ObjectMap.empty;
    try putContractFields(allocator, &obj, result.source, .{
        .query = result.query,
        .limit = result.limit,
        .result_count = result.matches.len,
        .no_result_reason = if (result.matches.len == 0) "no_langref_match" else null,
        .ranking = if (bundled) "bundled curated sections with title or anchor matches before summary/body matches; limit is applied after ranking" else "installed HTML heading order for matching language-reference sections; limit is applied after document-order ranking",
    });
    try obj.put(allocator, "index_metadata", try langrefIndexMetadataValue(allocator, result.metadata));
    try obj.put(allocator, "matches", .{ .array = matches });
    return .{ .object = obj };
}

/// Returns an allocator-owned JSON value for langref match.
fn langrefMatchValue(allocator: std.mem.Allocator, match: docs_domain.LangrefMatch) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "rank", .{ .integer = @intCast(match.rank) });
    try obj.put(allocator, "title", .{ .string = match.title });
    try obj.put(allocator, "anchor", .{ .string = match.anchor });
    try obj.put(allocator, "summary", .{ .string = match.summary });
    if (match.body) |body| try obj.put(allocator, "body", .{ .string = body });
    if (match.snippet) |snippet| try obj.put(allocator, "snippet", .{ .string = snippet });
    try obj.put(allocator, "match_pass", .{ .string = match.match_pass });
    try obj.put(allocator, "source_path", if (match.source_path) |path| .{ .string = path } else .null);
    return .{ .object = obj };
}

/// Returns an allocator-owned JSON value for langref index metadata.
fn langrefIndexMetadataValue(allocator: std.mem.Allocator, metadata: docs_domain.LangrefIndexMetadata) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
    var roots = std.json.Array.init(allocator);
    if (metadata.source_path) |path| try roots.append(.{ .string = path });
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "index_strategy", .{ .string = metadata.strategy });
    try obj.put(allocator, "generated_unix", .null);
    try obj.put(allocator, "generated_at", .{ .string = "per_call_in_memory_index" });
    try obj.put(allocator, "indexed_section_count", .{ .integer = @intCast(metadata.indexed_sections) });
    try obj.put(allocator, "heading_count", .{ .integer = @intCast(metadata.heading_count) });
    try obj.put(allocator, "skipped_heading_count", .{ .integer = @intCast(metadata.skipped_heading_count) });
    try obj.put(allocator, "installed_doc_available", .{ .bool = metadata.installed_doc_available });
    try obj.put(allocator, "candidate_count", .{ .integer = @intCast(metadata.candidate_count) });
    try obj.put(allocator, "skipped_candidate_count", .{ .integer = @intCast(metadata.skipped_candidate_count) });
    try obj.put(allocator, "rejected_candidate_count", .{ .integer = @intCast(metadata.rejected_candidate_count) });
    try obj.put(allocator, "unreadable_candidate_count", .{ .integer = @intCast(metadata.unreadable_candidate_count) });
    try obj.put(allocator, "parse_failure_count", .{ .integer = @intCast(metadata.parse_failure_count) });
    try obj.put(allocator, "fallback_reason", if (metadata.fallback_reason) |reason| .{ .string = reason } else .null);
    try obj.put(allocator, "source_roots", .{ .array = roots });
    try obj.put(allocator, "section_summary", .{ .string = "HTML headings and anchors indexed with bounded section summaries, source path, and fallback counters" });
    return .{ .object = obj };
}

/// Returns an allocator-owned JSON value for docs index build.
fn docsIndexBuildValue(allocator: std.mem.Allocator, result: docs_domain.DocsIndexResult) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
    var entries = std.json.Array.init(allocator);
    for (result.entries) |entry| try entries.append(try docsEntryValue(allocator, entry));
    var sources = std.json.Array.init(allocator);
    try sources.append(.{ .string = "workspace_readme_docs" });
    try sources.append(.{ .string = "workspace_source_comments" });
    try sources.append(.{ .string = "installed_zig_docs_when_queried" });
    var obj = std.json.ObjectMap.empty;
    try putBase(allocator, &obj, "zig_docs_index_build", "Workspace docs/source-comment index with versioned source family labels", "medium", &.{
        "Index is in-memory for this response; persistent docs artifacts must be regenerated by project documentation tooling.",
        "Source comments are text evidence, not rendered autodoc.",
    });
    try obj.put(allocator, "scope", .{ .string = result.scope });
    try obj.put(allocator, "entries", .{ .array = entries });
    try obj.put(allocator, "entry_count", .{ .integer = @intCast(result.entries.len) });
    try obj.put(allocator, "files_scanned", .{ .integer = @intCast(result.files_scanned) });
    try obj.put(allocator, "skipped_files", .{ .integer = @intCast(result.skipped_files) });
    try obj.put(allocator, "sources", .{ .array = sources });
    try obj.put(allocator, "index_version", .{ .string = "zigars.docs_index.v1" });
    return .{ .object = obj };
}

/// Returns an allocator-owned JSON value for docs entry.
fn docsEntryValue(allocator: std.mem.Allocator, entry: docs_domain.DocsEntry) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "path", .{ .string = entry.path });
    try obj.put(allocator, "source_family", .{ .string = entry.source_family });
    try obj.put(allocator, "bytes", .{ .integer = @intCast(entry.bytes) });
    try obj.put(allocator, "first_heading", if (entry.first_heading) |heading| .{ .string = heading } else .null);
    return .{ .object = obj };
}

/// Returns an allocator-owned JSON value for docs query.
fn docsQueryValue(allocator: std.mem.Allocator, kind: []const u8, result: docs_domain.DocsQueryResult) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
    var matches = std.json.Array.init(allocator);
    for (result.matches) |match| try matches.append(try docsMatchValue(allocator, match));
    var obj = std.json.ObjectMap.empty;
    try putBase(allocator, &obj, kind, "Local docs/source text query", "medium", &.{
        "Search is textual and local; semantic API correctness still needs compiler and docs review.",
    });
    try obj.put(allocator, "query", .{ .string = result.query });
    try obj.put(allocator, "scope", .{ .string = result.scope });
    try obj.put(allocator, "matches", .{ .array = matches });
    try obj.put(allocator, "result_count", .{ .integer = @intCast(result.matches.len) });
    try obj.put(allocator, "files_scanned", .{ .integer = @intCast(result.files_scanned) });
    try obj.put(allocator, "skipped_files", .{ .integer = @intCast(result.skipped_files) });
    try obj.put(allocator, "no_result_reason", if (result.matches.len == 0) .{ .string = "no_local_docs_match" } else .null);
    return .{ .object = obj };
}

/// Returns an allocator-owned JSON value for docs match.
fn docsMatchValue(allocator: std.mem.Allocator, match: docs_domain.DocsMatch) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "path", .{ .string = match.path });
    try obj.put(allocator, "source_family", .{ .string = match.source_family });
    try obj.put(allocator, "line", .{ .integer = @intCast(match.line) });
    try obj.put(allocator, "snippet", .{ .string = match.snippet });
    try obj.put(allocator, "confidence", .{ .string = match.confidence });
    return .{ .object = obj };
}

/// Returns an allocator-owned JSON value for autodoc ingest.
fn autodocIngestValue(allocator: std.mem.Allocator, result: docs_domain.AutodocIngestResult) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
    var entries = std.json.Array.init(allocator);
    for (result.entries) |entry| try entries.append(try autodocEntryValue(allocator, entry));
    var obj = std.json.ObjectMap.empty;
    try putBase(allocator, &obj, "zig_autodoc_ingest", "Autodoc JSON/text ingestion into response-local docs evidence", "medium", &.{
        "Ingestion is response-local and does not persist a docs database.",
        "Autodoc schema variants are normalized best-effort by common name/path/doc fields.",
    });
    try obj.put(allocator, "raw_reference", try rawReferenceValue(allocator, result.raw_reference));
    try obj.put(allocator, "entries", .{ .array = entries });
    try obj.put(allocator, "entry_count", .{ .integer = @intCast(result.entries.len) });
    return .{ .object = obj };
}

/// Returns an allocator-owned JSON value for autodoc entry.
fn autodocEntryValue(allocator: std.mem.Allocator, entry: docs_domain.AutodocEntry) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
    var obj = std.json.ObjectMap.empty;
    if (std.mem.eql(u8, entry.source_family, "autodoc_json")) {
        try obj.put(allocator, "name", if (entry.name) |value| .{ .string = value } else .null);
        try obj.put(allocator, "path", if (entry.path) |value| .{ .string = value } else .null);
        try obj.put(allocator, "docs", if (entry.docs) |value| .{ .string = value } else .null);
        try obj.put(allocator, "source_family", .{ .string = entry.source_family });
    } else {
        if (entry.line) |line| try obj.put(allocator, "line", .{ .integer = @intCast(line) });
        try obj.put(allocator, "docs", if (entry.docs) |value| .{ .string = value } else .null);
        try obj.put(allocator, "source_family", .{ .string = entry.source_family });
    }
    return .{ .object = obj };
}

/// Returns an allocator-owned JSON value for doc example check.
fn docExampleCheckValue(allocator: std.mem.Allocator, result: docs_domain.DocExampleCheckResult) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
    var snippets = std.json.Array.init(allocator);
    for (result.snippets) |snippet| try snippets.append(try snippetCheckValue(allocator, snippet));
    var obj = std.json.ObjectMap.empty;
    try putBase(allocator, &obj, "zig_doc_example_check", "Fenced Zig snippet syntax parse from docs text", "high", &.{
        "Checks syntax only; examples are not compiled, linked, or executed.",
        "Snippets requiring surrounding declarations can report syntax errors until wrapped by docs tooling.",
    });
    try obj.put(allocator, "raw_reference", try rawReferenceValue(allocator, result.raw_reference));
    try obj.put(allocator, "snippets", .{ .array = snippets });
    try obj.put(allocator, "snippet_count", .{ .integer = @intCast(result.snippets.len) });
    try obj.put(allocator, "ok", .{ .bool = result.ok });
    try obj.put(allocator, "verify_with", try stringArrayValue(allocator, &.{ "zig_snippet_check", "project example tests", "zig build test" }));
    return .{ .object = obj };
}

/// Returns an allocator-owned JSON value for snippet check.
fn snippetCheckValue(allocator: std.mem.Allocator, result: docs_domain.SnippetCheck) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "label", .{ .string = result.label });
    try obj.put(allocator, "parse_status", .{ .string = result.parse_status });
    try obj.put(allocator, "ok", .{ .bool = result.ok });
    try obj.put(allocator, "parse_error_count", .{ .integer = @intCast(result.parse_error_count) });
    try obj.put(allocator, "confidence", .{ .string = result.confidence });
    try obj.put(allocator, "source_bytes", .{ .integer = @intCast(result.source_bytes) });
    return .{ .object = obj };
}

/// Returns an allocator-owned JSON value for readme command check.
fn readmeCommandCheckValue(allocator: std.mem.Allocator, result: docs_domain.ReadmeCommandCheckResult) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
    var commands = std.json.Array.init(allocator);
    for (result.commands) |command| try commands.append(try readmeCommandValue(allocator, command));
    var obj = std.json.ObjectMap.empty;
    try putBase(allocator, &obj, "zig_readme_command_check", "README command extraction without execution", "medium", &.{
        "Commands are classified text; zigars does not run shell snippets or infer setup side effects.",
    });
    try obj.put(allocator, "raw_reference", try rawReferenceValue(allocator, result.raw_reference));
    try obj.put(allocator, "commands", .{ .array = commands });
    try obj.put(allocator, "command_count", .{ .integer = @intCast(result.commands.len) });
    return .{ .object = obj };
}

/// Returns an allocator-owned JSON value for readme command.
fn readmeCommandValue(allocator: std.mem.Allocator, command: docs_domain.ReadmeCommand) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "line", .{ .integer = @intCast(command.line) });
    try obj.put(allocator, "command", .{ .string = command.command });
    try obj.put(allocator, "safe_to_execute_automatically", .{ .bool = false });
    try obj.put(allocator, "classification", .{ .string = command.classification });
    try obj.put(allocator, "verification", .{ .string = "Review command and run explicitly in the intended workspace; this tool does not execute README commands." });
    return .{ .object = obj };
}

/// Returns an allocator-owned JSON value for raw reference.
fn rawReferenceValue(allocator: std.mem.Allocator, reference: docs_domain.RawReference) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "source_kind", .{ .string = reference.source_kind });
    try obj.put(allocator, "path", if (reference.path) |path| .{ .string = path } else .null);
    try obj.put(allocator, "bytes", .{ .integer = @intCast(reference.bytes) });
    try obj.put(allocator, "sha256", .{ .string = try allocator.dupe(u8, reference.sha256[0..]) });
    return .{ .object = obj };
}

/// Serializes builtin index results for text-only docs responses.
fn builtinListText(allocator: std.mem.Allocator, result: docs_domain.BuiltinListResult) ![]u8 {
    // Keep this logic centralized so callers observe one consistent behavior path.
    var out: std.ArrayList(u8) = .empty;
    try appendSourceText(allocator, &out, docs_domain.curatedBuiltinsSource());
    try appendContractText(allocator, &out, .{ .result_count = docs_domain.builtins.len, .ranking = "curated builtin declaration order" });
    try appendBuiltinIndexMetadataText(allocator, &out, result.input);
    try out.print(allocator, "Known Zig builtins ({d} curated entries):\n\n", .{docs_domain.builtins.len});
    for (docs_domain.builtins) |item| try out.print(allocator, "- `{s}`: {s}\n", .{ item.signature, item.summary });
    return out.toOwnedSlice(allocator);
}

/// Serializes builtin documentation results for text-only docs responses.
fn builtinDocText(allocator: std.mem.Allocator, result: docs_domain.BuiltinDocResult) ![]u8 {
    // Keep this logic centralized so callers observe one consistent behavior path.
    var out: std.ArrayList(u8) = .empty;
    try appendSourceText(allocator, &out, docs_domain.curatedBuiltinsSource());
    try appendContractText(allocator, &out, .{
        .query = result.query,
        .limit = result.limit,
        .result_count = result.matches.len,
        .no_result_reason = if (result.matches.len == 0) "no_builtin_match" else null,
        .ranking = "case-insensitive builtin-name substring match in curated order; limit is applied after matching",
    });
    try appendBuiltinIndexMetadataText(allocator, &out, result.input);
    for (result.matches) |match| {
        try out.print(allocator, "## {s}\n\n```zig\n{s}\n```\n\n{s}\n\n", .{ match.item.name, match.item.signature, match.item.summary });
    }
    if (result.matches.len == 0) try out.print(allocator, "No curated builtin documentation matched `{s}`. Try `zig_builtin_list` for available entries.\n", .{result.query});
    return out.toOwnedSlice(allocator);
}

/// Appends builtin index metadata text to the caller-provided output list.
fn appendBuiltinIndexMetadataText(allocator: std.mem.Allocator, out: *std.ArrayList(u8), input: docs_domain.BuiltinIndexInput) !void {
    // Append in deterministic order so completion and snapshot output remain stable.
    try out.print(allocator, "Index strategy: curated_builtin_index\nCurated entries: {d}\n", .{docs_domain.builtins.len});
    const drift = input.drift orelse docs_domain.BuiltinDriftInfo{ .status = if (input.toolchain_version == null) "toolchain_version_unavailable" else "toolchain_version_recorded_builtin_set_not_extracted", .confidence = "version_only" };
    if (input.toolchain_version) |version| {
        try out.print(allocator, "Toolchain version: {s}\n", .{version});
    } else {
        try out.appendSlice(allocator, "Toolchain version: unavailable\n");
    }
    if (drift.active_source_path) |path| try out.print(allocator, "Active builtin source: {s}\n", .{path});
    try out.print(allocator, "Drift check: {s}\nDrift confidence: {s}\nActive builtins: {d}\nCurated missing: {d}\nActive extras: {d}\n\n", .{ drift.status, drift.confidence, drift.active_count, drift.curated_missing_count, drift.active_extra_count });
}

/// Returns an allocator-owned JSON value for std search text from.
fn stdSearchTextFromValue(allocator: std.mem.Allocator, value: std.json.Value) ![]u8 {
    // Keep this logic centralized so callers observe one consistent behavior path.
    const obj = value.object;
    var out: std.ArrayList(u8) = .empty;
    const source_obj = obj.get("source").?.object;
    try appendSourceObjectText(allocator, &out, source_obj);
    try appendContractObjectText(allocator, &out, obj);
    const matches = obj.get("matches").?.array.items;
    for (matches) |match_value| {
        const match = match_value.object;
        try out.print(allocator, "### std/{s}:{d}\n\n```zig\n{s}\n```\n\n", .{ match.get("path").?.string, match.get("line").?.integer, match.get("snippet").?.string });
        const qualified_name = match.get("qualified_name").?;
        if (qualified_name == .string) try out.print(allocator, "Qualified name: {s}\nImport hint: {s}\n\n", .{ qualified_name.string, match.get("import_hint").?.string });
        const doc_comments = match.get("doc_comments").?.string;
        if (doc_comments.len > 0) try out.print(allocator, "Doc comments:\n{s}\n\n", .{doc_comments});
    }
    if (matches.len == 0) try out.print(allocator, "No stdlib matches for `{s}` under {s}.\n", .{ obj.get("query").?.string, source_obj.get("path").?.string });
    if (obj.get("skipped_files").?.integer > 0) try out.print(allocator, "\nSkipped {d} unreadable or oversized Zig files while scanning.\n", .{obj.get("skipped_files").?.integer});
    return out.toOwnedSlice(allocator);
}

/// Returns an allocator-owned JSON value for std item text from.
fn stdItemTextFromValue(allocator: std.mem.Allocator, value: std.json.Value) ![]u8 {
    // Keep this logic centralized so callers observe one consistent behavior path.
    const obj = value.object;
    var out: std.ArrayList(u8) = .empty;
    try appendSourceObjectText(allocator, &out, obj.get("source").?.object);
    try appendContractObjectText(allocator, &out, obj);
    const matches = obj.get("matches").?.array.items;
    for (matches) |match_value| {
        const match = match_value.object;
        try out.print(allocator, "### std/{s}:{d} ({s})\n\n```zig\n{s}\n```\n\n", .{ match.get("path").?.string, match.get("line").?.integer, match.get("match_kind").?.string, match.get("snippet").?.string });
        try out.print(allocator, "Qualified name: {s}\nImport hint: {s}\n\n", .{ match.get("qualified_name").?.string, match.get("import_hint").?.string });
        const doc_comments = match.get("doc_comments").?.string;
        if (doc_comments.len > 0) try out.print(allocator, "Doc comments:\n{s}\n\n", .{doc_comments});
    }
    if (matches.len == 0) try out.print(allocator, "No stdlib declaration matched `{s}`. Try `zig_std_search` for broader source scanning.\n", .{obj.get("name").?.string});
    return out.toOwnedSlice(allocator);
}

/// Returns an allocator-owned JSON value for langref text from.
fn langrefTextFromValue(allocator: std.mem.Allocator, value: std.json.Value) ![]u8 {
    // Keep this logic centralized so callers observe one consistent behavior path.
    const obj = value.object;
    const source_obj = obj.get("source").?.object;
    var out: std.ArrayList(u8) = .empty;
    try out.print(allocator, "Language reference search source: {s}\n", .{source_obj.get("id").?.string});
    try appendSourceObjectText(allocator, &out, source_obj);
    try appendContractObjectText(allocator, &out, obj);
    const matches = obj.get("matches").?.array.items;
    for (matches) |match_value| {
        const match = match_value.object;
        try out.print(allocator, "### {s} (#{s})\n\n", .{ match.get("title").?.string, match.get("anchor").?.string });
        const source_path = match.get("source_path").?;
        if (source_path == .string) {
            try out.print(allocator, "Source: {s}\n\n{s}\n\n", .{ source_path.string, match.get("summary").?.string });
        } else {
            try out.print(allocator, "Source: bundled Zig language reference index\n\n{s}\n\n{s}\n\n", .{ match.get("summary").?.string, match.get("body").?.string });
        }
    }
    if (matches.len == 0) {
        const source_path = source_obj.get("path").?;
        if (source_path == .string) {
            try out.print(allocator, "No language reference matches for `{s}` in {s}.\n", .{ obj.get("query").?.string, source_path.string });
        } else {
            try out.print(allocator, "No language reference matches for `{s}` in the bundled index.\n", .{obj.get("query").?.string});
        }
    }
    return out.toOwnedSlice(allocator);
}

/// Appends source text to the caller-provided output list.
fn appendSourceText(allocator: std.mem.Allocator, out: *std.ArrayList(u8), source: docs_domain.Source) !void {
    // Append in deterministic order so completion and snapshot output remain stable.
    try out.print(allocator,
        \\Docs source: {s}
        \\Source label: {s}
        \\Provenance: {s}
        \\Completeness: {s}
        \\
    , .{ source.id, source.label, source.provenance, source.completeness.text() });
    if (source.version) |version| {
        try out.print(allocator, "Version: {s}\n", .{version});
    } else {
        try out.appendSlice(allocator, "Version: unavailable\n");
    }
    if (source.path) |path| try out.print(allocator, "Path: {s}\n", .{path});
    try out.append(allocator, '\n');
}

/// Appends contract text to the caller-provided output list.
fn appendContractText(allocator: std.mem.Allocator, out: *std.ArrayList(u8), contract: docs_domain.Contract) !void {
    // Append in deterministic order so completion and snapshot output remain stable.
    if (contract.query) |query| {
        try out.print(allocator, "Query: `{s}`\n", .{query});
    } else {
        try out.appendSlice(allocator, "Query: none\n");
    }
    if (contract.limit) |limit| {
        try out.print(allocator, "Limit: {d}\n", .{limit});
    } else {
        try out.appendSlice(allocator, "Limit: none\n");
    }
    try out.print(allocator, "Result count: {d}\n", .{contract.result_count});
    if (contract.no_result_reason) |reason| {
        try out.print(allocator, "No result reason: {s}\n", .{reason});
    } else {
        try out.appendSlice(allocator, "No result reason: none\n");
    }
    try out.print(allocator, "Ranking: {s}\n\n", .{contract.ranking});
}

/// Appends source object text to the caller-provided output list.
fn appendSourceObjectText(allocator: std.mem.Allocator, out: *std.ArrayList(u8), source_obj: std.json.ObjectMap) !void {
    // Append in deterministic order so completion and snapshot output remain stable.
    try out.print(allocator,
        \\Docs source: {s}
        \\Source label: {s}
        \\Provenance: {s}
        \\Completeness: {s}
        \\Version: {s}
        \\
    , .{
        source_obj.get("id").?.string,
        source_obj.get("label").?.string,
        source_obj.get("provenance").?.string,
        source_obj.get("completeness").?.string,
        source_obj.get("version").?.string,
    });
    const path = source_obj.get("path").?;
    if (path == .string) try out.print(allocator, "Path: {s}\n", .{path.string});
    try out.append(allocator, '\n');
}

/// Appends contract object text to the caller-provided output list.
fn appendContractObjectText(allocator: std.mem.Allocator, out: *std.ArrayList(u8), obj: std.json.ObjectMap) !void {
    // Append in deterministic order so completion and snapshot output remain stable.
    const query = obj.get("query").?;
    if (query == .string) {
        try out.print(allocator, "Query: `{s}`\n", .{query.string});
    } else {
        try out.appendSlice(allocator, "Query: none\n");
    }
    const limit = obj.get("limit").?;
    if (limit == .integer) {
        try out.print(allocator, "Limit: {d}\n", .{limit.integer});
    } else {
        try out.appendSlice(allocator, "Limit: none\n");
    }
    try out.print(allocator, "Result count: {d}\n", .{obj.get("result_count").?.integer});
    const no_result = obj.get("no_result_reason").?;
    if (no_result == .string) {
        try out.print(allocator, "No result reason: {s}\n", .{no_result.string});
    } else {
        try out.appendSlice(allocator, "No result reason: none\n");
    }
    try out.print(allocator, "Ranking: {s}\n\n", .{obj.get("ranking").?.string});
}

/// Adds base fields to allocator-owned JSON objects.
fn putBase(allocator: std.mem.Allocator, obj: *std.json.ObjectMap, kind: []const u8, evidence_basis: []const u8, confidence: []const u8, limitations: []const []const u8) !void {
    try obj.put(allocator, "kind", .{ .string = kind });
    try obj.put(allocator, "schema_version", .{ .integer = schema_version });
    try obj.put(allocator, "evidence_basis", .{ .string = evidence_basis });
    try obj.put(allocator, "confidence", .{ .string = confidence });
    try obj.put(allocator, "limitations", try stringArrayValue(allocator, limitations));
}

/// Copies a string slice into an allocator-owned JSON array.
fn stringArrayValue(allocator: std.mem.Allocator, values: []const []const u8) !std.json.Value {
    var array = std.json.Array.init(allocator);
    for (values) |value| try array.append(.{ .string = value });
    return .{ .array = array };
}

/// Wraps plain text output with a `kind` discriminator for structured tools.
fn structuredText(allocator: std.mem.Allocator, kind: []const u8, body: []const u8) mcp.tools.ToolError!mcp.tools.ToolResult {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "kind", .{ .string = kind });
    try obj.put(allocator, "text", .{ .string = body });
    defer obj.deinit(allocator);
    return mcp_result.structured(allocator, .{ .object = obj });
}

/// Builds an evidence request from `content` (inline) or `path` (workspace
/// file), falling back to `default_path` when neither is given. The use case
/// resolves any path under the workspace sandbox; `require` makes absent evidence
/// an error instead of an empty result.
fn evidenceRequest(args: ?std.json.Value, provenance: []const u8, require: bool, default_path: ?[]const u8) docs_usecases.EvidenceRequest {
    // Keep this logic centralized so callers observe one consistent behavior path.
    return .{
        .content = argString(args, "content"),
        .path = argString(args, "path"),
        .default_path = default_path,
        .require = require,
        .provenance = provenance,
    };
}

/// Reads a string argument when it is present with the expected type.
fn argString(args: ?std.json.Value, name: []const u8) ?[]const u8 {
    return mcp.tools.getString(args, name);
}

/// Reads an int argument when it is present with the expected type.
fn argInt(args: ?std.json.Value, name: []const u8, default: i64) i64 {
    return mcp.tools.getInteger(args, name) orelse default;
}

/// Reads a result limit, applying the per-tool default and flooring at 1 so a
/// zero or negative request never yields an empty or panicking scan.
fn normalizedLimit(args: ?std.json.Value, name: []const u8, default: usize) usize {
    return @intCast(@max(1, argInt(args, name, @intCast(default))));
}

/// Maps docs error failures to structured MCP errors.
fn docsError(
    allocator: std.mem.Allocator,
    tool: []const u8,
    operation: []const u8,
    phase: []const u8,
    code: []const u8,
    err: anyerror,
    query: []const u8,
    resolution: []const u8,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    // Preserve a single error-shaping path so callers receive consistent metadata.
    if (err == error.OutOfMemory) return error.OutOfMemory;
    return mcp_errors.fromError(allocator, .{
        .tool = tool,
        .operation = operation,
        .phase = phase,
        .code = code,
        .category = "docs",
        .resolution = resolution,
        .details = &.{.{ .key = "query", .value = .{ .string = query } }},
    }, err);
}

/// Maps docs tool error failures to structured MCP errors.
fn docsToolError(allocator: std.mem.Allocator, tool_name: []const u8, operation: []const u8, err: anyerror) mcp.tools.ToolError!mcp.tools.ToolResult {
    // Preserve a single error-shaping path so callers receive consistent metadata.
    if (err == error.OutOfMemory) return error.OutOfMemory;
    return mcp_errors.fromError(allocator, .{
        .tool = tool_name,
        .operation = operation,
        .phase = "docs",
        .code = "docs_query_failed",
        .category = "docs",
        .resolution = "Retry with a smaller limit, a narrower query, or a readable workspace docs path.",
    }, err);
}

/// Maps docs backend error failures to structured MCP errors.
fn docsBackendError(allocator: std.mem.Allocator, tool_name: []const u8, operation: []const u8, err: anyerror, query: []const u8) mcp.tools.ToolError!mcp.tools.ToolResult {
    // Preserve a single error-shaping path so callers receive consistent metadata.
    if (err == error.OutOfMemory) return error.OutOfMemory;
    return mcp_errors.fromError(allocator, .{
        .tool = tool_name,
        .operation = operation,
        .phase = "docs",
        .code = "docs_backend_failed",
        .category = "docs",
        .resolution = "Confirm --zig-path points to a Zig executable with local documentation paths, then retry.",
        .details = &.{.{ .key = "query", .value = .{ .string = query } }},
    }, err);
}

/// Maps evidence-read failures to client-facing errors: missing evidence and
/// empty/out-of-sandbox paths become argument or workspace-path errors (the
/// latter reports the offending `path` against the workspace root), and any
/// other read failure becomes a structured filesystem error.
fn evidenceInputError(allocator: std.mem.Allocator, context: app_context.ReleaseDocsContext, tool_name: []const u8, args: ?std.json.Value, err: anyerror) mcp.tools.ToolError!mcp.tools.ToolResult {
    // Preserve a single error-shaping path so callers receive consistent metadata.
    return switch (err) {
        error.MissingEvidence => mcp_errors.missingArgument(allocator, tool_name, "content", "inline content or workspace path"),
        error.PathOutsideWorkspace, error.EmptyPath => if (argString(args, "path")) |path| mcp_errors.workspacePath(allocator, tool_name, path, context.workspace.root, err) else mcp_errors.missingArgument(allocator, tool_name, "path", "workspace-relative path"),
        error.OutOfMemory => error.OutOfMemory,
        else => mcp_errors.fromError(allocator, .{
            .tool = tool_name,
            .operation = "read_evidence",
            .phase = "workspace_read",
            .code = "evidence_read_failed",
            .category = "filesystem",
            .resolution = "Pass inline content or a readable workspace-relative path, then retry.",
        }, err),
    };
}

test "release workflow adapters and error helpers cover fallback branches" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const fakes = @import("../../../testing/fakes/root.zig");

    var command_fake = fakes.FakeCommandRunner.init(std.testing.allocator);
    defer command_fake.deinit();
    var workspace_fake = fakes.FakeWorkspaceStore.init(std.testing.allocator);
    defer workspace_fake.deinit();

    const workflow_context = app_context.ReleaseWorkflowContext{
        .workspace = .{ .root = "/repo", .cache_root = "/repo/.zigars-cache", .transport = "test" },
        .tool_paths = .{ .zig = "zig" },
        .timeouts = .{ .command_ms = 1000, .zls_ms = 1000 },
        .command_runner = command_fake.port(),
        .workspace_store = workspace_fake.port(),
        .workspace_scanner = undefined,
        .tool_manifest = undefined,
    };

    try command_fake.expectRun(.{
        .argv = &.{ "zig", "build", "test" },
        .cwd = "/repo",
        .timeout_ms = 1000,
        .max_stdout_bytes = support.command_output_limit,
        .max_stderr_bytes = support.command_output_limit,
        .provenance = "arch110-workflow-command",
    }, .{
        .exit_code = 0,
        .stdout = "ok\n",
        .duration_ms = 5,
    });
    const junit = try zigJunit(allocator, workflow_context, null);
    defer mcp_result.deinitToolResult(allocator, junit);
    try expectStructuredKind(junit, "zig_junit");

    var matrix_args = std.json.ObjectMap.empty;
    defer matrix_args.deinit(allocator);
    try matrix_args.put(allocator, "zig_paths", .{ .string = "zig-nightly" });
    try command_fake.expectRun(.{
        .argv = &.{ "zig-nightly", "build", "test" },
        .cwd = "/repo",
        .timeout_ms = 1000,
        .max_stdout_bytes = support.command_output_limit,
        .max_stderr_bytes = support.command_output_limit,
        .provenance = "arch110-workflow-command",
    }, .{
        .exit_code = 0,
        .stdout = "nightly ok\n",
        .duration_ms = 6,
    });
    const matrix = try zigMatrixCheck(allocator, workflow_context, .{ .object = matrix_args });
    defer mcp_result.deinitToolResult(allocator, matrix);
    try expectStructuredKind(matrix, "zig_matrix_check");

    var bad_claim_args = std.json.ObjectMap.empty;
    defer bad_claim_args.deinit(allocator);
    try bad_claim_args.put(allocator, "mode", .{ .string = "wide" });
    const claim = try zigarsReleaseClaimCheck(allocator, workflow_context, .{ .object = bad_claim_args });
    defer mcp_result.deinitToolResult(allocator, claim);
    try std.testing.expect(claim.is_error);

    var bad_index_args = std.json.ObjectMap.empty;
    defer bad_index_args.deinit(allocator);
    try bad_index_args.put(allocator, "mode", .{ .string = "wide" });
    const index = try zigarsToolIndexCheck(allocator, workflow_context, .{ .object = bad_index_args });
    defer mcp_result.deinitToolResult(allocator, index);
    try std.testing.expect(index.is_error);

    const usecase_error = try workflowUsecaseError(allocator, "tool", "operation", error.FileNotFound);
    defer mcp_result.deinitToolResult(allocator, usecase_error);
    try std.testing.expect(usecase_error.is_error);
    try std.testing.expectError(error.OutOfMemory, workflowUsecaseError(allocator, "tool", "operation", error.OutOfMemory));

    const doc_error = try docsError(allocator, "tool", "operation", "phase", "code", error.FileNotFound, "query", "resolution");
    defer mcp_result.deinitToolResult(allocator, doc_error);
    try std.testing.expect(doc_error.is_error);
    try std.testing.expectError(error.OutOfMemory, docsError(allocator, "tool", "operation", "phase", "code", error.OutOfMemory, "query", "resolution"));

    const tool_error = try docsToolError(allocator, "tool", "operation", error.InvalidData);
    defer mcp_result.deinitToolResult(allocator, tool_error);
    try std.testing.expect(tool_error.is_error);
    try std.testing.expectError(error.OutOfMemory, docsToolError(allocator, "tool", "operation", error.OutOfMemory));

    const backend_error = try docsBackendError(allocator, "tool", "operation", error.FileNotFound, "query");
    defer mcp_result.deinitToolResult(allocator, backend_error);
    try std.testing.expect(backend_error.is_error);
    try std.testing.expectError(error.OutOfMemory, docsBackendError(allocator, "tool", "operation", error.OutOfMemory, "query"));

    var path_args = std.json.ObjectMap.empty;
    defer path_args.deinit(allocator);
    try path_args.put(allocator, "path", .{ .string = "../escape.md" });
    const docs_context = app_context.ReleaseDocsContext{
        .workspace = .{ .root = "/repo" },
        .tool_paths = .{},
        .timeouts = .{},
        .workspace_store = workspace_fake.port(),
        .toolchain_env = undefined,
        .docs_scanner = undefined,
    };
    const missing_evidence = try evidenceInputError(allocator, docs_context, "tool", null, error.MissingEvidence);
    defer mcp_result.deinitToolResult(allocator, missing_evidence);
    try std.testing.expect(missing_evidence.is_error);
    const path_error = try evidenceInputError(allocator, docs_context, "tool", .{ .object = path_args }, error.PathOutsideWorkspace);
    defer mcp_result.deinitToolResult(allocator, path_error);
    try std.testing.expect(path_error.is_error);
    const empty_path = try evidenceInputError(allocator, docs_context, "tool", null, error.EmptyPath);
    defer mcp_result.deinitToolResult(allocator, empty_path);
    try std.testing.expect(empty_path.is_error);
    try std.testing.expectError(error.OutOfMemory, evidenceInputError(allocator, docs_context, "tool", null, error.OutOfMemory));
    const read_error = try evidenceInputError(allocator, docs_context, "tool", null, error.FileNotFound);
    defer mcp_result.deinitToolResult(allocator, read_error);
    try std.testing.expect(read_error.is_error);

    try command_fake.verify();
    try workspace_fake.verify();
}

test "release docs text projections cover text-only and null metadata branches" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const autodoc_entry = try autodocEntryValue(allocator, .{
        .line = 7,
        .docs = "line docs",
        .source_family = "autodoc_text",
    });
    try std.testing.expectEqual(@as(i64, 7), autodoc_entry.object.get("line").?.integer);

    var builtin_metadata: std.ArrayList(u8) = .empty;
    defer builtin_metadata.deinit(allocator);
    try appendBuiltinIndexMetadataText(allocator, &builtin_metadata, .{
        .toolchain_version = "0.16.0",
        .drift = .{ .status = "recorded", .confidence = "high" },
    });
    try std.testing.expect(std.mem.indexOf(u8, builtin_metadata.items, "Toolchain version: 0.16.0") != null);

    const langref_value = try langrefValue(allocator, .{
        .query = "missing",
        .limit = 1,
        .source = .{
            .id = "installed_langref_html",
            .label = "Installed Langref",
            .provenance = "test",
            .completeness = .installed_complete,
            .path = "/zig/lib/doc/langref.html",
            .version = "0.16.0",
        },
        .matches = &.{},
        .metadata = .{
            .strategy = "installed_html_heading_scan",
            .indexed_sections = 0,
            .installed_doc_available = true,
        },
    });
    const langref_text = try langrefTextFromValue(allocator, langref_value);
    try std.testing.expect(std.mem.indexOf(u8, langref_text, "/zig/lib/doc/langref.html") != null);

    var source_text: std.ArrayList(u8) = .empty;
    defer source_text.deinit(allocator);
    try appendSourceText(allocator, &source_text, .{
        .id = "project_docs",
        .label = "Project docs",
        .provenance = "test",
        .completeness = .partial_curated,
    });
    try std.testing.expect(std.mem.indexOf(u8, source_text.items, "Version: unavailable") != null);

    var contract_text: std.ArrayList(u8) = .empty;
    defer contract_text.deinit(allocator);
    try appendContractText(allocator, &contract_text, .{
        .result_count = 0,
        .no_result_reason = "no evidence",
        .ranking = "none",
    });
    try std.testing.expect(std.mem.indexOf(u8, contract_text.items, "No result reason: no evidence") != null);

    var object = std.json.ObjectMap.empty;
    defer object.deinit(allocator);
    try object.put(allocator, "query", .null);
    try object.put(allocator, "limit", .null);
    try object.put(allocator, "result_count", .{ .integer = 0 });
    try object.put(allocator, "no_result_reason", .{ .string = "not found" });
    try object.put(allocator, "ranking", .{ .string = "none" });
    var object_text: std.ArrayList(u8) = .empty;
    defer object_text.deinit(allocator);
    try appendContractObjectText(allocator, &object_text, object);
    try std.testing.expect(std.mem.indexOf(u8, object_text.items, "Query: none") != null);
    try std.testing.expect(std.mem.indexOf(u8, object_text.items, "Limit: none") != null);
    try std.testing.expect(std.mem.indexOf(u8, object_text.items, "No result reason: not found") != null);
}

/// Asserts structured kind in adapter tests.
fn expectStructuredKind(result: mcp.tools.ToolResult, kind: []const u8) !void {
    try std.testing.expect(result.structuredContent != null);
    try std.testing.expectEqualStrings(kind, result.structuredContent.?.object.get("kind").?.string);
}

/// Asserts no builtin env in adapter tests.
fn expectNoBuiltinEnv(toolchain: anytype) !void {
    try toolchain.expectGetError(.{ .key = "version", .provenance = "release_docs.builtin_version" }, error.FileNotFound);
    try toolchain.expectGetError(.{ .key = "std_dir", .provenance = "release_docs.builtin_source" }, error.FileNotFound);
}

/// Asserts std scan in adapter tests.
fn expectStdScan(toolchain: anytype, scanner: anytype, provenance: []const u8, source: []const u8) !void {
    try toolchain.expectGet(.{ .key = "std_dir", .provenance = provenance }, "/zig/lib/std");
    try scanner.expectAbsoluteScan(.{ .root = "/zig/lib/std", .max_files = docs_domain.default_path_scan_limit, .provenance = "release_docs.std_scan" }, &.{"mem.zig"});
    try scanner.expectRead(.{ .path = "/zig/lib/std/mem.zig", .max_bytes = docs_domain.std_source_read_limit, .provenance = "release_docs.std_read" }, source);
}

/// Asserts langref in adapter tests.
fn expectLangref(toolchain: anytype, scanner: anytype, probe: []const u8, html: []const u8) !void {
    try toolchain.expectGet(.{ .key = "lib_dir", .provenance = "release_docs.langref" }, "/zig/lib");
    try scanner.expectRead(.{ .path = "/zig/lib/doc/langref.html", .max_bytes = docs_domain.langref_probe_read_limit, .provenance = "release_docs.langref_probe" }, probe);
    try scanner.expectRead(.{ .path = "/zig/lib/doc/langref.html", .max_bytes = docs_domain.langref_html_read_limit, .provenance = "release_docs.langref_read" }, html);
}
