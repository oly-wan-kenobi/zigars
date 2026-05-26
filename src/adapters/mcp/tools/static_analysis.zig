const std = @import("std");
const mcp = @import("mcp");

const app_context = @import("../../../app/context.zig");
const ports = @import("../../../app/ports.zig");
const backend_contracts = @import("../../../domain/zig/backend_contracts.zig");
const lint_intelligence = @import("../../../app/usecases/static_analysis/lint_intelligence.zig");
const project_values = @import("../../../app/usecases/static_analysis/project_values.zig");
const semantic_index = @import("../../../app/usecases/static_analysis/semantic_index.zig");
const workspace_scans = @import("../../../app/usecases/static_analysis/workspace_scans.zig");
const mcp_errors = @import("../errors.zig");
const mcp_result = @import("../result.zig");

pub fn zigImportGraph(
    allocator: std.mem.Allocator,
    context: app_context.StaticAnalysisContext,
    args: ?std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    var graph = workspace_scans.importGraph(allocator, context, .{ .limit = argInt(args, "limit") orelse workspace_scans.default_scan_limit }) catch |err| return staticToolError(allocator, "zig_import_graph", "scan_import_graph", "scan_workspace", err);
    defer graph.deinit(allocator);
    const output = workspace_scans.importGraphText(allocator, graph) catch return error.OutOfMemory;
    defer allocator.free(output);
    return staticTextResult(allocator, "zig_import_graph", output);
}

pub fn zigImportGraphJson(
    allocator: std.mem.Allocator,
    context: app_context.StaticAnalysisContext,
    args: ?std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    var graph = workspace_scans.importGraph(allocator, context, .{ .limit = argInt(args, "limit") orelse workspace_scans.default_scan_limit }) catch |err| return staticToolError(allocator, "zig_import_graph_json", "scan_import_graph_json", "scan_workspace", err);
    defer graph.deinit(allocator);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    return staticStructuredValue(allocator, arena.allocator(), "zig_import_graph_json", try importGraphJsonValue(arena.allocator(), graph));
}

pub fn zigBuildGraph(
    allocator: std.mem.Allocator,
    context: app_context.StaticAnalysisContext,
    _: ?std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    return staticValueResult(allocator, context, "zig_build_graph", project_values.buildWorkspaceValue(allocator, context));
}

pub fn zigBuildTargets(
    allocator: std.mem.Allocator,
    context: app_context.StaticAnalysisContext,
    _: ?std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    return staticValueResult(allocator, context, "zig_build_targets", project_values.buildTargetsValue(allocator, context));
}

pub fn zigBuildOptions(
    allocator: std.mem.Allocator,
    context: app_context.StaticAnalysisContext,
    _: ?std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    return staticValueResult(allocator, context, "zig_build_options", project_values.buildOptionsValue(allocator, context));
}

pub fn zigFileOwner(
    allocator: std.mem.Allocator,
    context: app_context.StaticAnalysisContext,
    args: ?std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    const file = argString(args, "file") orelse return mcp_errors.missingArgument(allocator, "zig_file_owner", "file", "workspace-relative Zig file path");
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const value = project_values.fileOwnerForPathValue(scratch, context, file) catch |err| return staticPathError(allocator, context, "zig_file_owner", file, err);
    return staticStructuredValue(allocator, scratch, "zig_file_owner", value);
}

pub fn zigImportResolve(
    allocator: std.mem.Allocator,
    context: app_context.StaticAnalysisContext,
    args: ?std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    const import_name = argString(args, "import") orelse return mcp_errors.missingArgument(allocator, "zig_import_resolve", "import", "Zig import name");
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const graph = project_values.buildWorkspaceValue(scratch, context) catch |err| return staticToolError(allocator, "zig_import_resolve", "build_workspace_graph", "workspace_read", err);
    const value = project_values.importResolveValue(scratch, context, graph, import_name, argString(args, "from")) catch return error.OutOfMemory;
    return staticStructuredValue(allocator, scratch, "zig_import_resolve", value);
}

pub fn zigTestDiscover(
    allocator: std.mem.Allocator,
    context: app_context.StaticAnalysisContext,
    args: ?std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    var tests = workspace_scans.testDiscover(allocator, context, .{ .limit = argInt(args, "limit") orelse 500 }) catch |err| return staticToolError(allocator, "zig_test_discover", "scan_test_declarations", "scan_workspace", err);
    defer tests.deinit(allocator);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    return staticStructuredValue(allocator, arena.allocator(), "zig_test_discover", try testDiscoverJsonValue(arena.allocator(), tests));
}

pub fn zigChangedFilesPlan(
    allocator: std.mem.Allocator,
    context: app_context.StaticAnalysisContext,
    args: ?std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    return staticValueResult(allocator, context, "zig_changed_files_plan", project_values.changedFilesPlanValue(allocator, context, timeoutMs(context, args)));
}

pub fn zigDependencyInspect(
    allocator: std.mem.Allocator,
    context: app_context.StaticAnalysisContext,
    _: ?std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const value = project_values.dependencyInspectionFromWorkspaceValue(scratch, context) catch |err| return staticToolError(allocator, "zig_dependency_inspect", "inspect_dependencies", "static_analysis", err);
    return staticStructuredValue(allocator, scratch, "zig_dependency_inspect", value);
}

pub fn zigTargetMatrixPlan(
    allocator: std.mem.Allocator,
    _: app_context.StaticAnalysisContext,
    args: ?std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const value = project_values.targetMatrixPlanValue(scratch, argString(args, "targets") orelse "native x86_64-linux-gnu x86_64-macos-none aarch64-macos-none x86_64-windows-gnu wasm32-freestanding", argString(args, "steps") orelse "build test") catch return error.OutOfMemory;
    return staticStructuredValue(allocator, scratch, "zig_target_matrix_plan", value);
}

pub fn zigTestFailureTriage(
    allocator: std.mem.Allocator,
    context: app_context.StaticAnalysisContext,
    args: ?std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const value = project_values.testFailureTriageFromWorkspaceValue(scratch, context, .{
        .text = argString(args, "text"),
        .file = argString(args, "file"),
        .filter = argString(args, "filter"),
        .args = argString(args, "args") orelse "",
        .timeout_ms = timeoutMs(context, args),
    }) catch |err| switch (err) {
        error.InvalidArguments => return splitToolArgsError(allocator, "zig_test_failure_triage", "args", argString(args, "args") orelse "", err),
        error.PathOutsideWorkspace, error.EmptyPath => return staticPathError(allocator, context, "zig_test_failure_triage", argString(args, "file") orelse "", err),
        else => return staticToolError(allocator, "zig_test_failure_triage", "run_tests", "static_analysis", err),
    };
    return staticStructuredValue(allocator, scratch, "zig_test_failure_triage", value);
}

pub fn zigWorkspaceSymbolCache(
    allocator: std.mem.Allocator,
    context: app_context.StaticAnalysisContext,
    args: ?std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    return staticValueResult(allocator, context, "zig_workspace_symbol_cache", project_values.workspaceSymbolCacheValue(allocator, context, argString(args, "query"), argInt(args, "limit") orelse 500));
}

pub fn zigPackageCacheDoctor(
    allocator: std.mem.Allocator,
    context: app_context.StaticAnalysisContext,
    args: ?std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    return staticValueResult(allocator, context, "zig_package_cache_doctor", project_values.packageCacheDoctorValue(allocator, context, timeoutMs(context, args)));
}

pub fn zigTestMap(
    allocator: std.mem.Allocator,
    context: app_context.StaticAnalysisContext,
    args: ?std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    return staticValueResult(allocator, context, "zig_test_map", project_values.testMapValue(allocator, context, argInt(args, "limit") orelse 500));
}

pub fn zigTestSelect(
    allocator: std.mem.Allocator,
    context: app_context.StaticAnalysisContext,
    args: ?std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    return staticValueResult(allocator, context, "zig_test_select", project_values.testSelectValue(allocator, context, argString(args, "files"), argString(args, "symbols"), argInt(args, "limit") orelse 500));
}

pub fn zigPublicApiDiff(
    allocator: std.mem.Allocator,
    context: app_context.StaticAnalysisContext,
    args: ?std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const file = argString(args, "file");
    const value = project_values.publicApiDiffFromWorkspaceValue(scratch, context, .{
        .file = file,
        .before = argString(args, "before"),
        .after = argString(args, "after"),
        .baseline_ref = argString(args, "baseline_ref") orelse "HEAD",
    }) catch |err| return staticToolError(allocator, "zig_public_api_diff", "public_api_diff", "static_analysis", err);
    return staticStructuredValue(allocator, scratch, "zig_public_api_diff", value);
}

pub fn zigZlint(
    allocator: std.mem.Allocator,
    context: app_context.StaticAnalysisContext,
    args: ?std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    return zlintDiagnosticsResult(allocator, context, args, "zig_zlint", false);
}

pub fn zigZlintSarif(
    allocator: std.mem.Allocator,
    context: app_context.StaticAnalysisContext,
    args: ?std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    return zlintDiagnosticsResult(allocator, context, args, "zig_zlint_sarif", true);
}

pub fn zigZlintRules(
    allocator: std.mem.Allocator,
    context: app_context.StaticAnalysisContext,
    args: ?std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const value = lint_intelligence.runZlintRules(scratch, context, .{
        .timeout_ms = timeoutMs(context, args),
    }) catch |err| return lintToolError(allocator, context, "zig_zlint_rules", ".", "run_zlint_rules", "run_backend", err);
    return structuredLintValue(allocator, scratch, "zig_zlint_rules", value);
}

pub fn zigZlintFix(
    allocator: std.mem.Allocator,
    context: app_context.StaticAnalysisContext,
    args: ?std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    const raw_extra_args = argString(args, "args") orelse "";
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const extra = splitArgs(scratch, raw_extra_args) catch |err| return splitToolArgsError(allocator, "zig_zlint_fix", "args", raw_extra_args, err);
    const path = argString(args, "path") orelse ".";
    const config = argString(args, "config");
    const value = lint_intelligence.runZlintFix(scratch, context, .{
        .path = path,
        .config = config,
        .rules = argString(args, "rules"),
        .extra = extra,
        .dangerous = argBool(args, "dangerous", false),
        .apply = argBool(args, "apply", false),
        .timeout_ms = timeoutMs(context, args),
    }) catch |err| return lintToolError(allocator, context, "zig_zlint_fix", config orelse path, "run_zlint_fix", "run_backend", err);
    return structuredLintValue(allocator, scratch, "zig_zlint_fix", value);
}

pub fn zigLintCompare(
    allocator: std.mem.Allocator,
    _: app_context.StaticAnalysisContext,
    args: ?std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const zlint = lint_intelligence.normalizeFindingsText(scratch, argString(args, "zlint_findings") orelse "[]", .zlint) catch return mcp_errors.missingArgument(allocator, "zig_lint_compare", "zlint_findings", "valid JSON findings");
    const zwanzig = lint_intelligence.normalizeFindingsText(scratch, argString(args, "zwanzig_findings") orelse "[]", .zwanzig) catch return mcp_errors.missingArgument(allocator, "zig_lint_compare", "zwanzig_findings", "valid JSON findings");
    const value = try lint_intelligence.lintCompareValue(scratch, zlint.array, zwanzig.array);
    return structuredLintValue(allocator, scratch, "zig_lint_compare", value);
}

pub fn zigLintProfile(
    allocator: std.mem.Allocator,
    _: app_context.StaticAnalysisContext,
    args: ?std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const value = try lint_intelligence.lintProfileValue(scratch, argString(args, "profile") orelse "standard");
    return structuredLintValue(allocator, scratch, "zig_lint_profile", value);
}

pub fn zigLintGate(
    allocator: std.mem.Allocator,
    _: app_context.StaticAnalysisContext,
    args: ?std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    const text = argString(args, "findings") orelse return mcp_errors.missingArgument(allocator, "zig_lint_gate", "findings", "valid JSON findings");
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const findings = lint_intelligence.normalizeFindingsText(scratch, text, .zlint) catch return mcp_errors.missingArgument(allocator, "zig_lint_gate", "findings", "valid JSON findings");
    const profile = argString(args, "profile") orelse "standard";
    const defaults = lint_intelligence.lintProfileDefaults(profile);
    const allow_warnings = if (argHas(args, "allow_warnings")) argBool(args, "allow_warnings", defaults.allow_warnings) else defaults.allow_warnings;
    const max_warnings = if (argHas(args, "max_warnings")) argInteger(args, "max_warnings") orelse defaults.max_warnings else defaults.max_warnings;
    const value = try lint_intelligence.lintGateValue(scratch, findings.array, profile, allow_warnings, max_warnings);
    return structuredLintValue(allocator, scratch, "zig_lint_gate", value);
}

pub fn zigLintFixPlan(
    allocator: std.mem.Allocator,
    _: app_context.StaticAnalysisContext,
    args: ?std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    const text = argString(args, "findings") orelse return mcp_errors.missingArgument(allocator, "zig_lint_fix_plan", "findings", "valid JSON findings");
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const findings = lint_intelligence.normalizeFindingsText(scratch, text, .zlint) catch return mcp_errors.missingArgument(allocator, "zig_lint_fix_plan", "findings", "valid JSON findings");
    const value = try lint_intelligence.fixPlanValue(scratch, findings.array);
    return structuredLintValue(allocator, scratch, "zig_lint_fix_plan", value);
}

pub fn zigLintBaseline(
    allocator: std.mem.Allocator,
    context: app_context.StaticAnalysisContext,
    args: ?std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    const text = argString(args, "findings") orelse return mcp_errors.missingArgument(allocator, "zig_lint_baseline", "findings", "valid JSON findings");
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const findings = lint_intelligence.normalizeFindingsText(scratch, text, .zlint) catch return mcp_errors.missingArgument(allocator, "zig_lint_baseline", "findings", "valid JSON findings");
    const baseline = lint_intelligence.normalizeFindingsText(scratch, argString(args, "baseline") orelse "[]", .zlint) catch std.json.Value{ .array = std.json.Array.init(scratch) };
    const output = argString(args, "output") orelse ".zigar-cache/lint-baseline.json";
    const value = lint_intelligence.lintBaseline(scratch, context, findings.array, baseline.array, argBool(args, "apply", false), output) catch |err| return lintToolError(allocator, context, "zig_lint_baseline", output, "write_lint_baseline", "workspace_store", err);
    return structuredLintValue(allocator, scratch, "zig_lint_baseline", value);
}

pub fn zigLintSuppressions(
    allocator: std.mem.Allocator,
    _: app_context.StaticAnalysisContext,
    args: ?std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    const text = argString(args, "findings") orelse return mcp_errors.missingArgument(allocator, "zig_lint_suppressions", "findings", "valid JSON findings");
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const findings = lint_intelligence.normalizeFindingsText(scratch, text, .zlint) catch return mcp_errors.missingArgument(allocator, "zig_lint_suppressions", "findings", "valid JSON findings");
    const value = try lint_intelligence.suppressionsValue(scratch, findings.array, argString(args, "suppressions") orelse "[]");
    return structuredLintValue(allocator, scratch, "zig_lint_suppressions", value);
}

pub fn zigLintTrend(
    allocator: std.mem.Allocator,
    _: app_context.StaticAnalysisContext,
    args: ?std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    const before_text = argString(args, "before") orelse return mcp_errors.missingArgument(allocator, "zig_lint_trend", "before", "valid JSON findings");
    const after_text = argString(args, "after") orelse return mcp_errors.missingArgument(allocator, "zig_lint_trend", "after", "valid JSON findings");
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const before = lint_intelligence.normalizeFindingsText(scratch, before_text, .zlint) catch return mcp_errors.missingArgument(allocator, "zig_lint_trend", "before", "valid JSON findings");
    const after = lint_intelligence.normalizeFindingsText(scratch, after_text, .zlint) catch return mcp_errors.missingArgument(allocator, "zig_lint_trend", "after", "valid JSON findings");
    const value = try lint_intelligence.trendValue(scratch, before.array, after.array);
    return structuredLintValue(allocator, scratch, "zig_lint_trend", value);
}

pub fn zigLint(
    allocator: std.mem.Allocator,
    context: app_context.StaticAnalysisContext,
    args: ?std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    return zwanzigLintResult(allocator, context, args, .json, "zig_lint");
}

pub fn zigLintSarif(
    allocator: std.mem.Allocator,
    context: app_context.StaticAnalysisContext,
    args: ?std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    return zwanzigLintResult(allocator, context, args, .sarif, "zig_lint_sarif");
}

pub fn zigLintRules(
    allocator: std.mem.Allocator,
    context: app_context.StaticAnalysisContext,
    args: ?std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const value = lint_intelligence.runZwanzigRules(scratch, context, timeoutMs(context, args)) catch |err| return lintToolError(allocator, context, "zig_lint_rules", ".", "run_zwanzig_rules", "run_backend", err);
    return structuredZwanzigValue(allocator, scratch, "zig_lint_rules", value);
}

pub fn zigAnalysisGraphs(
    allocator: std.mem.Allocator,
    context: app_context.StaticAnalysisContext,
    args: ?std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    const mode_raw = argString(args, "mode") orelse return mcp_errors.missingArgument(allocator, "zig_analysis_graphs", "mode", backend_contracts.supportedZwanzigGraphModesText());
    const mode = backend_contracts.parseZwanzigGraphMode(mode_raw) orelse return mcp_errors.invalidArgument(
        allocator,
        "zig_analysis_graphs",
        "mode",
        backend_contracts.supportedZwanzigGraphModesText(),
        mode_raw,
        "Choose one of the graph modes published in tools/list; raw zwanzig graph flags are not accepted as public zigar API.",
    );
    const path = argString(args, "path") orelse return mcp_errors.missingArgument(allocator, "zig_analysis_graphs", "path", "workspace-relative Zig source path");
    const output = argString(args, "output") orelse return mcp_errors.missingArgument(allocator, "zig_analysis_graphs", "output", "workspace-relative graph output directory");
    const raw_extra_args = argString(args, "args") orelse "";

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const extra = splitArgs(scratch, raw_extra_args) catch |err| return splitToolArgsError(allocator, "zig_analysis_graphs", "args", raw_extra_args, err);
    const outcome = lint_intelligence.runZwanzigGraph(scratch, context, .{
        .mode = mode,
        .path = path,
        .output = output,
        .extra = extra,
        .timeout_ms = timeoutMs(context, args),
    }) catch |err| return lintToolError(allocator, context, "zig_analysis_graphs", output, "generate_analysis_graphs", "run_backend", err);
    return switch (outcome) {
        .value => |value| structuredGraphValue(allocator, scratch, value),
        .error_value => |value| mcp_result.structuredError(allocator, value),
    };
}

pub fn zigSemanticIndexBuild(
    allocator: std.mem.Allocator,
    context: app_context.StaticAnalysisContext,
    args: ?std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    return semanticIndexResult(allocator, context, args, "zig_semantic_index_build", argBool(args, "refresh", false));
}

pub fn zigSemanticIndexRefresh(
    allocator: std.mem.Allocator,
    context: app_context.StaticAnalysisContext,
    args: ?std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    return semanticIndexResult(allocator, context, args, "zig_semantic_index_refresh", true);
}

pub fn zigSemanticIndexStatus(
    allocator: std.mem.Allocator,
    context: app_context.StaticAnalysisContext,
    _: ?std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    const cache = semantic_index.status(context) catch |err| return semanticToolError(allocator, "zig_semantic_index_status", "cache_status", "read_cache_status", err);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    var obj = std.json.ObjectMap.empty;
    try obj.put(scratch, "kind", .{ .string = "zig_semantic_index_status" });
    try putMetadata(scratch, &obj, "zig_semantic_index_status");
    try obj.put(scratch, "format_version", .{ .integer = semantic_index.semantic_format_version });
    try obj.put(scratch, "cached", .{ .bool = cache.cached });
    try obj.put(scratch, "signature", .{ .integer = signatureInteger(cache.signature) });
    try obj.put(scratch, "hits", .{ .integer = @intCast(cache.hits) });
    try obj.put(scratch, "refreshes", .{ .integer = @intCast(cache.refreshes) });
    try obj.put(scratch, "evidence_sources", try stringArrayValue(scratch, &.{ "parser", "heuristic", "profile" }));
    return mcp_result.structured(allocator, .{ .object = obj });
}

pub fn zigSemanticQuery(
    allocator: std.mem.Allocator,
    context: app_context.StaticAnalysisContext,
    args: ?std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    const query = argString(args, "query") orelse return mcp_errors.missingArgument(allocator, "zig_semantic_query", "query", "symbol, import, test, or file substring");
    const limit_arg = argInt(args, "limit");
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const value = semantic_index.query(scratch, context, .{
        .query = query,
        .kind = argString(args, "kind"),
        .index_limit = limit_arg orelse semantic_index.default_limit,
        .match_limit = limit_arg orelse 50,
        .refresh = argBool(args, "refresh", false),
    }) catch |err| return semanticToolError(allocator, "zig_semantic_query", "query_index", "query_index", err);
    return structuredSemanticValue(allocator, scratch, "zig_semantic_query", value);
}

pub fn zigSemanticDecl(
    allocator: std.mem.Allocator,
    context: app_context.StaticAnalysisContext,
    args: ?std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    const symbol = argString(args, "symbol") orelse return mcp_errors.missingArgument(allocator, "zig_semantic_decl", "symbol", "declaration name");
    const limit_arg = argInt(args, "limit");
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const value = semantic_index.decl(scratch, context, .{
        .symbol = symbol,
        .index_limit = limit_arg orelse semantic_index.default_limit,
        .match_limit = limit_arg orelse 20,
        .refresh = argBool(args, "refresh", false),
    }) catch |err| return semanticToolError(allocator, "zig_semantic_decl", "decl_index", "decl_index", err);
    return structuredSemanticValue(allocator, scratch, "zig_semantic_decl", value);
}

pub fn zigSemanticRefs(
    allocator: std.mem.Allocator,
    context: app_context.StaticAnalysisContext,
    args: ?std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    const symbol = argString(args, "symbol") orelse return mcp_errors.missingArgument(allocator, "zig_semantic_refs", "symbol", "symbol name");
    return sourceRefsResult(allocator, context, args, "zig_semantic_refs", symbol, false);
}

pub fn zigSemanticCallers(
    allocator: std.mem.Allocator,
    context: app_context.StaticAnalysisContext,
    args: ?std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    const symbol = argString(args, "symbol") orelse return mcp_errors.missingArgument(allocator, "zig_semantic_callers", "symbol", "function name");
    return sourceRefsResult(allocator, context, args, "zig_semantic_callers", symbol, true);
}

pub fn zigStaticFusion(
    allocator: std.mem.Allocator,
    context: app_context.StaticAnalysisContext,
    args: ?std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    const query_text = argString(args, "query") orelse return mcp_errors.missingArgument(allocator, "zig_static_fusion", "query", "symbol or lint subject");
    if (try validateFindingsArgument(allocator, args, "zlint_findings")) |argument_error| return argument_error;
    if (try validateFindingsArgument(allocator, args, "zwanzig_findings")) |argument_error| return argument_error;

    const limit_arg = argInt(args, "limit");
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const value = semantic_index.staticFusion(scratch, context, .{
        .query = query_text,
        .index_limit = limit_arg orelse semantic_index.default_limit,
        .match_limit = limit_arg orelse 20,
        .zlint_findings = argString(args, "zlint_findings"),
        .zwanzig_findings = argString(args, "zwanzig_findings"),
    }) catch |err| return semanticToolError(allocator, "zig_static_fusion", "fusion_index", "fusion_index", err);
    return structuredSemanticValue(allocator, scratch, "zig_static_fusion", value);
}

pub fn zigCodeIndexExport(
    allocator: std.mem.Allocator,
    context: app_context.StaticAnalysisContext,
    args: ?std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    return exportIndexResult(allocator, context, args, "zig_code_index_export", "zigar.code_index", ".zigar-cache/code-index.json");
}

pub fn zigScipExport(
    allocator: std.mem.Allocator,
    context: app_context.StaticAnalysisContext,
    args: ?std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    return exportIndexResult(allocator, context, args, "zig_scip_export", "scip-like-json", ".zigar-cache/code-index.scip.json");
}

fn semanticIndexResult(
    allocator: std.mem.Allocator,
    context: app_context.StaticAnalysisContext,
    args: ?std.json.Value,
    tool_name: []const u8,
    force_refresh: bool,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const index = semantic_index.buildIndex(scratch, context, .{
        .limit = argInt(args, "limit") orelse semantic_index.default_limit,
        .refresh = force_refresh,
        .tool_name = tool_name,
    }) catch |err| return semanticToolError(allocator, tool_name, "semantic_index", "build_or_read", err);

    var value = index.value;
    switch (value) {
        .object => |*obj| {
            try putMetadata(scratch, obj, tool_name);
            try obj.put(scratch, "cache", try semanticCacheStatusValue(scratch, index.cache));
        },
        else => {},
    }
    return mcp_result.structured(allocator, value);
}

fn staticValueResult(
    allocator: std.mem.Allocator,
    context: app_context.StaticAnalysisContext,
    tool_name: []const u8,
    result: anyerror!std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    _ = context;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const value = result catch |err| return staticToolError(allocator, tool_name, "run_static_analysis", "static_analysis", err);
    return staticStructuredValue(allocator, scratch, tool_name, value);
}

fn staticStructuredValue(
    allocator: std.mem.Allocator,
    scratch: std.mem.Allocator,
    tool_name: []const u8,
    value: std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    var mutable = value;
    switch (mutable) {
        .object => |*obj| try putMetadata(scratch, obj, tool_name),
        else => {},
    }
    return mcp_result.structured(allocator, mutable);
}

fn staticTextResult(allocator: std.mem.Allocator, tool_name: []const u8, body: []const u8) mcp.tools.ToolError!mcp.tools.ToolResult {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    var obj = std.json.ObjectMap.empty;
    try obj.put(scratch, "kind", .{ .string = tool_name });
    try putMetadata(scratch, &obj, tool_name);
    try obj.put(scratch, "text", .{ .string = body });
    return mcp_result.structured(allocator, .{ .object = obj });
}

fn importGraphJsonValue(allocator: std.mem.Allocator, graph: workspace_scans.ImportGraphResult) !std.json.Value {
    var files = std.json.Array.init(allocator);
    for (graph.files) |file| {
        var imports = std.json.Array.init(allocator);
        for (file.imports) |import_item| {
            try imports.append(try ownedString(allocator, import_item.import));
        }
        var file_obj = std.json.ObjectMap.empty;
        try file_obj.put(allocator, "file", try ownedString(allocator, file.file));
        try file_obj.put(allocator, "imports", .{ .array = imports });
        try files.append(.{ .object = file_obj });
    }
    var skipped_files = std.json.Array.init(allocator);
    for (graph.skipped_files) |item| {
        var skipped_obj = std.json.ObjectMap.empty;
        try skipped_obj.put(allocator, "path", try ownedString(allocator, item.path));
        try skipped_obj.put(allocator, "error", try ownedString(allocator, item.error_name));
        try skipped_files.append(.{ .object = skipped_obj });
    }

    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "files", .{ .array = files });
    try obj.put(allocator, "file_count", .{ .integer = @intCast(graph.files.len) });
    try obj.put(allocator, "skipped_files", .{ .array = skipped_files });
    try obj.put(allocator, "skipped_file_count", .{ .integer = @intCast(graph.skipped_files.len) });
    return .{ .object = obj };
}

fn testDiscoverJsonValue(allocator: std.mem.Allocator, result: workspace_scans.TestDiscoverResult) !std.json.Value {
    var tests = std.json.Array.init(allocator);
    for (result.tests) |test_item| {
        var item = std.json.ObjectMap.empty;
        try item.put(allocator, "file", try ownedString(allocator, test_item.file));
        try item.put(allocator, "line", .{ .integer = @intCast(test_item.line) });
        try item.put(allocator, "declaration", try ownedString(allocator, test_item.declaration));
        try item.put(allocator, "command", try ownedString(allocator, test_item.command));
        try tests.append(.{ .object = item });
    }
    var skipped_files = std.json.Array.init(allocator);
    for (result.skipped_files) |item| {
        var skipped_obj = std.json.ObjectMap.empty;
        try skipped_obj.put(allocator, "path", try ownedString(allocator, item.path));
        try skipped_obj.put(allocator, "error", try ownedString(allocator, item.error_name));
        try skipped_files.append(.{ .object = skipped_obj });
    }

    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "tests", .{ .array = tests });
    try obj.put(allocator, "count", .{ .integer = @intCast(result.tests.len) });
    try obj.put(allocator, "skipped_files", .{ .array = skipped_files });
    try obj.put(allocator, "skipped_file_count", .{ .integer = @intCast(result.skipped_files.len) });
    return .{ .object = obj };
}

fn staticToolError(
    allocator: std.mem.Allocator,
    tool_name: []const u8,
    operation: []const u8,
    phase: []const u8,
    err: anyerror,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    if (err == error.OutOfMemory) return error.OutOfMemory;
    return mcp_errors.fromError(allocator, .{
        .tool = tool_name,
        .operation = operation,
        .phase = phase,
        .code = staticErrorCode(err),
        .category = staticErrorCategory(err),
        .retryable = staticErrorRetryable(err),
        .resolution = staticErrorResolution(err),
    }, err);
}

fn staticPathError(
    allocator: std.mem.Allocator,
    context: app_context.StaticAnalysisContext,
    tool_name: []const u8,
    path: []const u8,
    err: anyerror,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    return switch (err) {
        error.PathOutsideWorkspace, error.EmptyPath => mcp_errors.workspacePath(allocator, tool_name, path, context.workspace.root, err),
        else => staticToolError(allocator, tool_name, "resolve_workspace_path", "workspace_path", err),
    };
}

fn staticErrorCode(err: anyerror) []const u8 {
    return switch (err) {
        error.MissingCommandRunner => "missing_command_runner",
        error.PathOutsideWorkspace, error.EmptyPath => "workspace_path",
        error.FileNotFound, error.NotFound => "file_not_found",
        error.Timeout, error.RequestTimeout => "timeout",
        error.OutputLimitExceeded, error.StreamTooLong => "output_limit",
        else => "static_analysis_failed",
    };
}

fn staticErrorCategory(err: anyerror) []const u8 {
    return switch (err) {
        error.MissingCommandRunner => "configuration",
        error.PathOutsideWorkspace, error.EmptyPath => "workspace_path",
        error.FileNotFound, error.NotFound => "filesystem",
        error.Timeout, error.RequestTimeout => "timeout",
        error.OutputLimitExceeded, error.StreamTooLong => "output_limit",
        else => "static_analysis",
    };
}

fn staticErrorRetryable(err: anyerror) bool {
    return switch (err) {
        error.Timeout, error.RequestTimeout => true,
        else => false,
    };
}

fn staticErrorResolution(err: anyerror) []const u8 {
    return switch (err) {
        error.MissingCommandRunner => "Run this tool through a runtime that supplies the command runner port.",
        error.PathOutsideWorkspace, error.EmptyPath => "Retry with a non-empty workspace-relative path inside the configured workspace.",
        error.FileNotFound, error.NotFound => "Create the expected build or source file, or call a nullable project summary tool first.",
        error.Timeout, error.RequestTimeout => "Retry with a smaller scope or a larger timeout_ms value.",
        else => "Retry with a smaller limit or inspect unreadable workspace files.",
    };
}

fn sourceRefsResult(
    allocator: std.mem.Allocator,
    context: app_context.StaticAnalysisContext,
    args: ?std.json.Value,
    tool_name: []const u8,
    symbol: []const u8,
    calls_only: bool,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const value = semantic_index.sourceRefs(scratch, context, .{
        .symbol = symbol,
        .calls_only = calls_only,
        .limit = argInt(args, "limit") orelse 100,
        .timeout_ms = timeoutMs(context, args),
    }) catch |err| return semanticToolError(allocator, tool_name, "scan_sources", "scan_sources", err);
    return structuredSemanticValue(allocator, scratch, tool_name, value);
}

fn exportIndexResult(
    allocator: std.mem.Allocator,
    context: app_context.StaticAnalysisContext,
    args: ?std.json.Value,
    tool_name: []const u8,
    format: []const u8,
    default_output: []const u8,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    const output = argString(args, "output") orelse default_output;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    var value = semantic_index.exportIndex(scratch, context, .{
        .tool_name = tool_name,
        .format = format,
        .output = output,
        .limit = argInt(args, "limit") orelse semantic_index.default_limit,
        .apply = argBool(args, "apply", false),
        .refresh = argBool(args, "refresh", false),
    }) catch |err| return exportError(allocator, context, tool_name, output, err);
    try addExportMetadata(scratch, &value, tool_name);
    return mcp_result.structured(allocator, value);
}

fn addExportMetadata(allocator: std.mem.Allocator, value: *std.json.Value, tool_name: []const u8) !void {
    switch (value.*) {
        .object => |*obj| {
            try putMetadata(allocator, obj, tool_name);
            if (obj.getPtr("artifact_preview")) |preview| switch (preview.*) {
                .object => |*preview_obj| {
                    try putMetadata(allocator, preview_obj, tool_name);
                    if (preview_obj.getPtr("index")) |index| switch (index.*) {
                        .object => |*index_obj| try putMetadata(allocator, index_obj, tool_name),
                        else => {},
                    };
                },
                else => {},
            };
        },
        else => {},
    }
}

fn structuredSemanticValue(
    allocator: std.mem.Allocator,
    scratch: std.mem.Allocator,
    tool_name: []const u8,
    value: std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    var mutable = value;
    switch (mutable) {
        .object => |*obj| try putMetadata(scratch, obj, tool_name),
        else => {},
    }
    return mcp_result.structured(allocator, mutable);
}

fn structuredLintValue(
    allocator: std.mem.Allocator,
    scratch: std.mem.Allocator,
    tool_name: []const u8,
    value: std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    var mutable = value;
    switch (mutable) {
        .object => |*obj| {
            if (objectString(obj.*, "kind")) |kind| {
                if (std.mem.eql(u8, kind, tool_name)) try putMetadata(scratch, obj, tool_name);
            }
        },
        else => {},
    }
    return mcp_result.structured(allocator, mutable);
}

fn structuredZwanzigValue(
    allocator: std.mem.Allocator,
    scratch: std.mem.Allocator,
    tool_name: []const u8,
    value: std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    var mutable = value;
    switch (mutable) {
        .object => |*obj| {
            if (obj.get("tool") == null) try obj.put(scratch, "tool", .{ .string = tool_name });
            if (obj.get("backend") == null) try obj.put(scratch, "backend", .{ .string = "zwanzig" });
            if (obj.get("optional_backend") == null) try obj.put(scratch, "optional_backend", .{ .bool = true });
            try putMetadata(scratch, obj, tool_name);
        },
        else => {},
    }
    return mcp_result.structured(allocator, mutable);
}

fn structuredGraphValue(
    allocator: std.mem.Allocator,
    scratch: std.mem.Allocator,
    value: std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    var mutable = value;
    switch (mutable) {
        .object => |*obj| {
            if (objectString(obj.*, "kind")) |kind| {
                if (std.mem.eql(u8, kind, "zig_analysis_graphs")) try putMetadata(scratch, obj, "zig_analysis_graphs");
            }
        },
        else => {},
    }
    return mcp_result.structured(allocator, mutable);
}

fn zlintDiagnosticsResult(
    allocator: std.mem.Allocator,
    context: app_context.StaticAnalysisContext,
    args: ?std.json.Value,
    tool_name: []const u8,
    sarif: bool,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    const raw_extra_args = argString(args, "args") orelse "";
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const extra = splitArgs(scratch, raw_extra_args) catch |err| return splitToolArgsError(allocator, tool_name, "args", raw_extra_args, err);
    const path = argString(args, "path") orelse ".";
    const config = argString(args, "config");
    const value = lint_intelligence.runZlintDiagnostics(scratch, context, .{
        .tool_name = tool_name,
        .path = path,
        .config = config,
        .rules = argString(args, "rules"),
        .extra = extra,
        .timeout_ms = timeoutMs(context, args),
        .sarif = sarif,
    }) catch |err| return lintToolError(allocator, context, tool_name, config orelse path, "run_zlint_diagnostics", "run_backend", err);
    return structuredLintValue(allocator, scratch, tool_name, value);
}

fn zwanzigLintResult(
    allocator: std.mem.Allocator,
    context: app_context.StaticAnalysisContext,
    args: ?std.json.Value,
    format: backend_contracts.ZwanzigLintFormat,
    tool_name: []const u8,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    const raw_extra_args = argString(args, "args") orelse "";
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const extra = splitArgs(scratch, raw_extra_args) catch |err| return splitToolArgsError(allocator, tool_name, "args", raw_extra_args, err);
    const path = argString(args, "path") orelse ".";
    const config = argString(args, "config");
    const value = lint_intelligence.runZwanzigLint(scratch, context, .{
        .tool_name = tool_name,
        .format = format,
        .path = path,
        .config = config,
        .rules_do = argString(args, "rules_do"),
        .rules_skip = argString(args, "rules_skip"),
        .extra = extra,
        .timeout_ms = timeoutMs(context, args),
    }) catch |err| return lintToolError(allocator, context, tool_name, config orelse path, "run_zwanzig_lint", "run_backend", err);
    return structuredZwanzigValue(allocator, scratch, tool_name, value);
}

fn semanticToolError(
    allocator: std.mem.Allocator,
    tool_name: []const u8,
    operation: []const u8,
    phase: []const u8,
    err: anyerror,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    if (err == error.OutOfMemory) return error.OutOfMemory;
    return mcp_errors.fromError(allocator, .{
        .tool = tool_name,
        .operation = operation,
        .phase = phase,
        .code = semanticErrorCode(err),
        .category = semanticErrorCategory(err),
        .retryable = semanticErrorRetryable(err),
        .resolution = semanticErrorResolution(err),
    }, err);
}

fn lintToolError(
    allocator: std.mem.Allocator,
    context: app_context.StaticAnalysisContext,
    tool_name: []const u8,
    path: []const u8,
    operation: []const u8,
    phase: []const u8,
    err: anyerror,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    if (err == error.OutOfMemory) return error.OutOfMemory;
    return switch (err) {
        error.PathOutsideWorkspace, error.EmptyPath => mcp_errors.workspacePath(allocator, tool_name, path, context.workspace.root, err),
        error.InvalidRequest => mcp_errors.invalidArgument(
            allocator,
            tool_name,
            "path",
            "workspace-relative path inside the configured workspace",
            path,
            "Retry with a workspace-relative path that can be resolved by the active zigar workspace.",
        ),
        else => mcp_errors.fromError(allocator, .{
            .tool = tool_name,
            .operation = operation,
            .phase = phase,
            .code = lintErrorCode(err),
            .category = lintErrorCategory(err),
            .retryable = lintErrorRetryable(err),
            .resolution = lintErrorResolution(err),
        }, err),
    };
}

fn splitToolArgsError(
    allocator: std.mem.Allocator,
    tool_name: []const u8,
    field: []const u8,
    actual: []const u8,
    err: anyerror,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    return switch (err) {
        error.InvalidArguments => mcp_errors.invalidArgument(
            allocator,
            tool_name,
            field,
            "shell-style argument string",
            actual,
            "Quote arguments the same way you would in a shell command, or omit the field when no extra arguments are needed.",
        ),
        error.OutOfMemory => error.OutOfMemory,
        else => mcp_errors.fromError(allocator, .{
            .tool = tool_name,
            .operation = "parse_arguments",
            .phase = "split_extra_arguments",
            .code = "argument_parse_failed",
            .category = "argument",
            .resolution = "Inspect the extra argument string and retry with valid shell-style quoting.",
            .details = &.{
                .{ .key = "field", .value = .{ .string = field } },
                .{ .key = "actual", .value = .{ .string = actual } },
            },
        }, err),
    };
}

fn lintErrorCode(err: anyerror) []const u8 {
    return switch (err) {
        error.MissingCommandRunner => "missing_command_runner",
        error.PathOutsideWorkspace, error.EmptyPath => "workspace_path",
        error.InvalidRequest => "invalid_request",
        error.FileNotFound, error.NotFound => "file_not_found",
        error.Timeout, error.RequestTimeout => "timeout",
        error.OutputLimitExceeded, error.StreamTooLong => "output_limit",
        else => "static_lint_failed",
    };
}

fn lintErrorCategory(err: anyerror) []const u8 {
    return switch (err) {
        error.MissingCommandRunner => "configuration",
        error.PathOutsideWorkspace, error.EmptyPath => "workspace_path",
        error.InvalidRequest => "argument",
        error.FileNotFound, error.NotFound => "filesystem",
        error.Timeout, error.RequestTimeout => "timeout",
        error.OutputLimitExceeded, error.StreamTooLong => "output_limit",
        else => "static_analysis",
    };
}

fn lintErrorRetryable(err: anyerror) bool {
    return switch (err) {
        error.Timeout, error.RequestTimeout => true,
        else => false,
    };
}

fn lintErrorResolution(err: anyerror) []const u8 {
    return switch (err) {
        error.MissingCommandRunner => "Run this tool through a runtime that supplies the command runner port.",
        error.PathOutsideWorkspace, error.EmptyPath => "Retry with a non-empty workspace-relative path inside the configured workspace.",
        error.InvalidRequest => "Inspect the tools/list inputSchema and retry with valid arguments.",
        error.Timeout, error.RequestTimeout => "Retry with a smaller scope or a larger timeout_ms value.",
        error.OutputLimitExceeded, error.StreamTooLong => "Retry with narrower lint output, a smaller path scope, or backend flags that reduce output.",
        else => "Inspect the configured optional backend, workspace path, and tool arguments, then retry.",
    };
}

fn exportError(
    allocator: std.mem.Allocator,
    context: app_context.StaticAnalysisContext,
    tool_name: []const u8,
    output: []const u8,
    err: anyerror,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    if (err == error.OutOfMemory) return error.OutOfMemory;
    return switch (err) {
        error.PathOutsideWorkspace, error.EmptyPath => mcp_errors.workspacePath(allocator, tool_name, output, context.workspace.root, err),
        else => semanticToolError(allocator, tool_name, "export_index", "export_index", err),
    };
}

fn validateFindingsArgument(allocator: std.mem.Allocator, args: ?std.json.Value, field: []const u8) mcp.tools.ToolError!?mcp.tools.ToolResult {
    const text = argString(args, field) orelse return null;
    if (std.mem.trim(u8, text, " \t\r\n").len == 0) return null;
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, text, .{}) catch {
        return try mcp_errors.missingArgument(allocator, "zig_static_fusion", field, "valid JSON findings");
    };
    defer parsed.deinit();
    return null;
}

fn semanticErrorCode(err: anyerror) []const u8 {
    return switch (err) {
        error.MissingCachePort => "missing_cache_port",
        error.MissingCommandRunner => "missing_command_runner",
        error.InvalidCache => "invalid_semantic_cache",
        error.PathOutsideWorkspace, error.EmptyPath => "workspace_path",
        error.FileNotFound, error.NotFound => "file_not_found",
        error.Timeout, error.RequestTimeout => "timeout",
        error.OutputLimitExceeded, error.StreamTooLong => "output_limit",
        else => "semantic_index_failed",
    };
}

fn semanticErrorCategory(err: anyerror) []const u8 {
    return switch (err) {
        error.MissingCachePort, error.MissingCommandRunner => "configuration",
        error.InvalidCache => "cache",
        error.PathOutsideWorkspace, error.EmptyPath => "workspace_path",
        error.FileNotFound, error.NotFound => "filesystem",
        error.Timeout, error.RequestTimeout => "timeout",
        error.OutputLimitExceeded, error.StreamTooLong => "output_limit",
        else => "static_analysis",
    };
}

fn semanticErrorRetryable(err: anyerror) bool {
    return switch (err) {
        error.Timeout, error.RequestTimeout, error.InvalidCache => true,
        else => false,
    };
}

fn semanticErrorResolution(err: anyerror) []const u8 {
    return switch (err) {
        error.MissingCachePort => "Run this tool through a runtime that supplies the semantic-index StaticCache port.",
        error.MissingCommandRunner => "Run this tool through a runtime that supplies the command runner port, or retry without ZLint-backed reference confirmation.",
        error.InvalidCache => "Retry with refresh=true to rebuild the semantic index from workspace sources.",
        error.PathOutsideWorkspace, error.EmptyPath => "Retry with a non-empty workspace-relative path inside the configured workspace.",
        error.Timeout, error.RequestTimeout => "Retry with a smaller limit or a larger timeout_ms value.",
        error.OutputLimitExceeded, error.StreamTooLong => "Retry with a smaller limit or narrower query.",
        else => "Retry with a smaller limit or refresh=true; inspect unreadable Zig files if the failure repeats.",
    };
}

fn semanticCacheStatusValue(allocator: std.mem.Allocator, cache: ports.StaticCacheStatus) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "cached", .{ .bool = cache.cached });
    try obj.put(allocator, "hits", .{ .integer = @intCast(cache.hits) });
    try obj.put(allocator, "refreshes", .{ .integer = @intCast(cache.refreshes) });
    try obj.put(allocator, "signature", .{ .integer = signatureInteger(cache.signature) });
    return .{ .object = obj };
}

fn signatureInteger(signature: u64) i64 {
    return @intCast(signature & @as(u64, std.math.maxInt(i64)));
}

fn argString(args: ?std.json.Value, name: []const u8) ?[]const u8 {
    return mcp.tools.getString(args, name);
}

fn argBool(args: ?std.json.Value, name: []const u8, default: bool) bool {
    return mcp.tools.getBoolean(args, name) orelse default;
}

fn argInt(args: ?std.json.Value, name: []const u8) ?usize {
    const value = mcp.tools.getInteger(args, name) orelse return null;
    return @intCast(@max(value, 1));
}

fn argInteger(args: ?std.json.Value, name: []const u8) ?i64 {
    return mcp.tools.getInteger(args, name);
}

fn argHas(args: ?std.json.Value, name: []const u8) bool {
    const value = args orelse return false;
    return switch (value) {
        .object => |obj| obj.get(name) != null,
        else => false,
    };
}

fn timeoutMs(context: app_context.StaticAnalysisContext, args: ?std.json.Value) ?u64 {
    const raw = mcp.tools.getInteger(args, "timeout_ms") orelse context.timeouts.command_ms;
    return @intCast(@max(1, @min(raw, 60 * 60 * 1000)));
}

fn objectString(obj: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const value = obj.get(name) orelse return null;
    return switch (value) {
        .string => |text| text,
        else => null,
    };
}

fn ownedString(allocator: std.mem.Allocator, value: []const u8) !std.json.Value {
    return .{ .string = try allocator.dupe(u8, value) };
}

fn splitArgs(allocator: std.mem.Allocator, text: []const u8) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    var current: std.ArrayList(u8) = .empty;
    errdefer {
        for (list.items) |arg| allocator.free(arg);
        list.deinit(allocator);
        current.deinit(allocator);
    }

    var quote: ?u8 = null;
    var escaping = false;
    var in_token = false;
    for (text) |c| {
        if (escaping) {
            try current.append(allocator, c);
            in_token = true;
            escaping = false;
            continue;
        }
        if (c == '\\') {
            escaping = true;
            in_token = true;
            continue;
        }
        if (quote) |q| {
            if (c == q) {
                quote = null;
            } else {
                try current.append(allocator, c);
            }
            in_token = true;
            continue;
        }
        switch (c) {
            '\'', '"' => {
                quote = c;
                in_token = true;
            },
            ' ', '\t', '\r', '\n' => {
                if (in_token) {
                    try finishArg(allocator, &list, &current);
                    in_token = false;
                }
            },
            else => {
                try current.append(allocator, c);
                in_token = true;
            },
        }
    }
    if (escaping or quote != null) return error.InvalidArguments;
    if (in_token) try finishArg(allocator, &list, &current);
    return list.toOwnedSlice(allocator);
}

fn finishArg(allocator: std.mem.Allocator, list: *std.ArrayList([]const u8), current: *std.ArrayList(u8)) !void {
    const arg = try current.toOwnedSlice(allocator);
    errdefer allocator.free(arg);
    try list.append(allocator, arg);
}

const Contract = struct {
    tool: []const u8,
    analysis_kind: []const u8,
    capability_tier: []const u8,
    confidence: []const u8,
    confidence_class: []const u8,
    source_coverage: []const u8,
    limitations: []const []const u8,
    verify_with: []const []const u8,
};

const semantic_index_coverage = "Readable workspace Zig files up to the requested limit; declarations/imports/tests are parser-backed where std.zig.Ast can parse the file, with parse_status, partial_result, and parse_error_count carried from parser-backed evidence when available.";
const semantic_refs_coverage = "Readable workspace Zig files up to the requested limit; matching lines are confirmed with optional ZLint --print-ast symbol references when the configured backend supports it, with source-scan fallback.";
const lint_fusion_coverage = "Semantic index and optional normalized linter evidence supplied by the caller.";
const lint_evidence_coverage = "Caller-supplied normalized lint JSON or optional lint backend output, depending on the tool and arguments.";
const zlint_output_coverage = "Optional ZLint backend output for the requested workspace path, normalized into zigar lint findings.";
const zlint_fix_coverage = "Optional ZLint --fix or --fix-dangerously over a workspace-local path, previewed unless apply=true.";
const zwanzig_output_coverage = "Optional zwanzig backend output for the requested workspace path or graph mode.";

const semantic_index_limits = &.{
    "Parser-backed syntax view plus source-scan evidence; it does not resolve comptime execution, aliases, or conditional imports.",
    "Parse errors are reported through parser metadata when available and can make file-level evidence partial.",
    "Workspace walks are bounded by the requested limit and skip generated/cache paths.",
};
const semantic_refs_limits = &.{
    "ZLint symbol-reference evidence is used when the configured backend exposes --print-ast; otherwise results fall back to source scans.",
    "Locations are still reported from matching source lines and can include textual matches that require review.",
    "Does not execute comptime code or prove cross-module alias resolution.",
};
const lint_intelligence_limits = &.{
    "Compares normalized lint evidence by stable rule/path/line fingerprints and cannot prove semantic correctness by itself.",
    "Gate and trend outputs are policy decisions over observed findings, not compiler or runtime proof.",
};
const zlint_limits = &.{
    "Requires an optional configured ZLint executable; zigar does not bundle or require the backend.",
    "Rule coverage, false positives, and output shape depend on the installed ZLint version and configuration.",
};
const zlint_fix_limits = &.{
    "Requires an optional configured ZLint executable with --fix support; zigar does not implement the edits itself.",
    "Runs only when apply=true and the selected path resolves inside the workspace.",
    "dangerous=true delegates to ZLint --fix-dangerously and should be followed by git diff review and tests.",
};
const zwanzig_limits = &.{
    "Requires an optional configured zwanzig executable; zigar does not bundle or require the backend.",
    "Rule coverage, false positives, and graph support depend on the installed zwanzig version and configuration.",
};

const contracts = [_]Contract{
    .{ .tool = "zig_import_graph", .analysis_kind = "heuristic_import_graph", .capability_tier = "advisory_orientation", .confidence = "medium", .confidence_class = "orientation_only", .source_coverage = "Readable workspace Zig files up to the requested limit.", .limitations = &.{"String-literal import scan; it does not resolve conditional imports, aliases, or comptime logic."}, .verify_with = &.{ "zig ast-check", "ZLS references" } },
    .{ .tool = "zig_import_graph_json", .analysis_kind = "heuristic_import_graph_json", .capability_tier = "advisory_orientation", .confidence = "medium", .confidence_class = "orientation_only", .source_coverage = "Readable workspace Zig files up to the requested limit.", .limitations = &.{"String-literal import scan; it does not resolve conditional imports, aliases, or comptime logic."}, .verify_with = &.{ "zig ast-check", "ZLS references" } },
    .{ .tool = "zig_build_graph", .analysis_kind = "heuristic_build_graph", .capability_tier = "advisory_orientation", .confidence = "medium", .confidence_class = "orientation_only", .source_coverage = "build.zig and build.zig.zon when present in the workspace root.", .limitations = &.{"Heuristic source scan of build files; it does not execute build.zig."}, .verify_with = &.{"zig build --help"} },
    .{ .tool = "zig_build_targets", .analysis_kind = "heuristic_build_targets", .capability_tier = "advisory_orientation", .confidence = "medium", .confidence_class = "orientation_only", .source_coverage = "build.zig target, artifact, test, step, and command suggestions from the workspace root.", .limitations = &.{"Heuristic source scan of build.zig; it does not execute build.zig."}, .verify_with = &.{"zig build --help"} },
    .{ .tool = "zig_build_options", .analysis_kind = "heuristic_build_option_scan", .capability_tier = "advisory_orientation", .confidence = "medium", .confidence_class = "orientation_only", .source_coverage = "build.zig option declarations in the workspace root.", .limitations = &.{"Only detects common std.Build option syntax; dynamic options may be missed."}, .verify_with = &.{"zig build --help"} },
    .{ .tool = "zig_file_owner", .analysis_kind = "heuristic_file_owner", .capability_tier = "advisory_orientation", .confidence = "medium", .confidence_class = "orientation_only", .source_coverage = "build.zig root_source_file references and the requested workspace file.", .limitations = &.{"Only exact root_source_file matches are high confidence."}, .verify_with = &.{ "zig ast-check", "zig build test" } },
    .{ .tool = "zig_import_resolve", .analysis_kind = "heuristic_import_resolve", .capability_tier = "advisory_orientation", .confidence = "medium", .confidence_class = "orientation_only", .source_coverage = "build.zig, build.zig.zon, and workspace-relative import candidates.", .limitations = &.{"Does not execute build.zig or compiler import resolution."}, .verify_with = &.{ "zig ast-check", "zig build test" } },
    .{ .tool = "zig_test_discover", .analysis_kind = "heuristic_test_discovery", .capability_tier = "advisory_orientation", .confidence = "medium", .confidence_class = "orientation_only", .source_coverage = "Readable workspace Zig files up to the requested limit.", .limitations = &.{"Scans textual test declarations; it does not run tests."}, .verify_with = &.{"zig build test"} },
    .{ .tool = "zig_changed_files_plan", .analysis_kind = "git_changed_files_plan", .capability_tier = "advisory_orientation", .confidence = "medium", .confidence_class = "advisory", .source_coverage = "Current git porcelain status for the workspace.", .limitations = &.{"Requires git status; command suggestions are conservative defaults."}, .verify_with = &.{"git status --porcelain"} },
    .{ .tool = "zig_dependency_inspect", .analysis_kind = "heuristic_dependency_inspect", .capability_tier = "advisory_orientation", .confidence = "medium", .confidence_class = "orientation_only", .source_coverage = "build.zig.zon dependencies in the workspace root.", .limitations = &.{"Heuristic build.zig.zon source scan; it does not fetch dependencies."}, .verify_with = &.{"zig build --fetch"} },
    .{ .tool = "zig_target_matrix_plan", .analysis_kind = "target_matrix_planning", .capability_tier = "advisory_orientation", .confidence = "medium", .confidence_class = "orientation_only", .source_coverage = "Caller-supplied target and step lists.", .limitations = &.{"Plans commands only; it does not validate target availability."}, .verify_with = &.{"zig targets"} },
    .{ .tool = "zig_test_failure_triage", .analysis_kind = "test_failure_triage", .capability_tier = "advisory_orientation", .confidence = "medium", .confidence_class = "advisory", .source_coverage = "Caller-supplied test output or command output from the configured Zig backend.", .limitations = &.{"Line classification is heuristic; rerun the suggested command for proof."}, .verify_with = &.{"zig build test"} },
    .{ .tool = "zig_workspace_symbol_cache", .analysis_kind = "cached_heuristic_symbol_import_scan", .capability_tier = "advisory_orientation", .confidence = "medium", .confidence_class = "orientation_only", .source_coverage = "Readable workspace Zig files up to the requested limit.", .limitations = &.{"Textual declaration and import scan; it does not resolve aliases or comptime code."}, .verify_with = &.{ "zig ast-check", "ZLS workspace symbols" } },
    .{ .tool = "zig_package_cache_doctor", .analysis_kind = "package_cache_doctor", .capability_tier = "advisory_orientation", .confidence = "medium", .confidence_class = "advisory", .source_coverage = "Workspace cache paths, git tracking state, and build.zig.zon dependency hints.", .limitations = &.{"Reports cache hygiene signals; it does not delete files."}, .verify_with = &.{ "git status", "zig build test" } },
    .{ .tool = "zig_test_map", .analysis_kind = "heuristic_test_declaration_scan", .capability_tier = "advisory_orientation", .confidence = "medium", .confidence_class = "orientation_only", .source_coverage = "Readable workspace Zig files up to the requested limit.", .limitations = &.{"Scans textual test declarations; it does not run tests."}, .verify_with = &.{"zig build test"} },
    .{ .tool = "zig_test_select", .analysis_kind = "heuristic_test_selection", .capability_tier = "advisory_orientation", .confidence = "medium", .confidence_class = "advisory", .source_coverage = "Caller-supplied changed files/symbols and heuristic workspace test map.", .limitations = &.{"Command recommendations are conservative and may over-select."}, .verify_with = &.{"zig build test"} },
    .{ .tool = "zig_public_api_diff", .analysis_kind = "heuristic_public_api_diff", .capability_tier = "advisory_orientation", .confidence = "medium", .confidence_class = "advisory", .source_coverage = "Caller-supplied before/after source text or git baseline plus workspace file.", .limitations = &.{"Public declaration scan is textual and does not prove ABI compatibility."}, .verify_with = &.{ "zig build test", "code review" } },
    .{ .tool = "zig_semantic_index_build", .analysis_kind = "parser_backed_semantic_workspace_index", .capability_tier = "parser_backed", .confidence = "high", .confidence_class = "advisory", .source_coverage = semantic_index_coverage, .limitations = semantic_index_limits, .verify_with = &.{ "zig ast-check", "ZLS workspace symbols", "zig build test" } },
    .{ .tool = "zig_semantic_index_status", .analysis_kind = "semantic_index_cache_status", .capability_tier = "advisory_orientation", .confidence = "medium", .confidence_class = "orientation_only", .source_coverage = "In-memory semantic index cache metadata for the current zigar process.", .limitations = &.{"Status reports cache state only; it does not refresh or validate source semantics."}, .verify_with = &.{"zig_semantic_index_refresh"} },
    .{ .tool = "zig_semantic_index_refresh", .analysis_kind = "parser_backed_semantic_workspace_index", .capability_tier = "parser_backed", .confidence = "high", .confidence_class = "advisory", .source_coverage = semantic_index_coverage, .limitations = semantic_index_limits, .verify_with = &.{ "zig ast-check", "ZLS workspace symbols", "zig build test" } },
    .{ .tool = "zig_semantic_query", .analysis_kind = "parser_backed_semantic_index_query", .capability_tier = "parser_backed", .confidence = "high", .confidence_class = "advisory", .source_coverage = semantic_index_coverage, .limitations = semantic_index_limits, .verify_with = &.{ "zig ast-check", "ZLS definition/references", "workspace search" } },
    .{ .tool = "zig_semantic_refs", .analysis_kind = "zlint_confirmed_reference_scan", .capability_tier = "advisory_orientation", .confidence = "medium", .confidence_class = "orientation_only", .source_coverage = semantic_refs_coverage, .limitations = semantic_refs_limits, .verify_with = &.{ "ZLS references", "zig build test" } },
    .{ .tool = "zig_semantic_decl", .analysis_kind = "parser_backed_declaration_lookup", .capability_tier = "parser_backed", .confidence = "high", .confidence_class = "advisory", .source_coverage = semantic_index_coverage, .limitations = semantic_index_limits, .verify_with = &.{ "zig ast-check", "ZLS definition" } },
    .{ .tool = "zig_semantic_callers", .analysis_kind = "zlint_confirmed_call_site_scan", .capability_tier = "advisory_orientation", .confidence = "medium", .confidence_class = "orientation_only", .source_coverage = semantic_refs_coverage, .limitations = semantic_refs_limits, .verify_with = &.{ "ZLS references", "code review" } },
    .{ .tool = "zig_static_fusion", .analysis_kind = "multi_source_static_confidence_fusion", .capability_tier = "advisory_orientation", .confidence = "medium", .confidence_class = "advisory", .source_coverage = lint_fusion_coverage, .limitations = lint_intelligence_limits, .verify_with = &.{ "zig build test", "ZLS", "configured linters" } },
    .{ .tool = "zig_code_index_export", .analysis_kind = "parser_backed_code_index_export", .capability_tier = "parser_backed", .confidence = "high", .confidence_class = "advisory", .source_coverage = semantic_index_coverage, .limitations = semantic_index_limits, .verify_with = &.{ "zig ast-check", "zig_semantic_index_build", "consumer schema validation" } },
    .{ .tool = "zig_scip_export", .analysis_kind = "parser_backed_scip_like_export", .capability_tier = "parser_backed", .confidence = "high", .confidence_class = "advisory", .source_coverage = semantic_index_coverage, .limitations = semantic_index_limits, .verify_with = &.{ "zig ast-check", "zig_semantic_index_build", "SCIP consumer validation" } },
    .{ .tool = "zig_zlint", .analysis_kind = "optional_zlint_diagnostics", .capability_tier = "zlint_backed", .confidence = "high", .confidence_class = "release_gating_candidate", .source_coverage = zlint_output_coverage, .limitations = zlint_limits, .verify_with = &.{"configured ZLint --help"} },
    .{ .tool = "zig_zlint_sarif", .analysis_kind = "optional_zlint_sarif_export", .capability_tier = "zlint_backed", .confidence = "high", .confidence_class = "release_gating_candidate", .source_coverage = zlint_output_coverage, .limitations = zlint_limits, .verify_with = &.{"configured ZLint --help"} },
    .{ .tool = "zig_zlint_rules", .analysis_kind = "optional_zlint_rule_catalog", .capability_tier = "zlint_backed", .confidence = "medium", .confidence_class = "advisory", .source_coverage = zlint_output_coverage, .limitations = zlint_limits, .verify_with = &.{"configured ZLint --help"} },
    .{ .tool = "zig_zlint_fix", .analysis_kind = "optional_zlint_apply_gated_fix", .capability_tier = "zlint_backed", .confidence = "medium", .confidence_class = "advisory", .source_coverage = zlint_fix_coverage, .limitations = zlint_fix_limits, .verify_with = &.{ "configured ZLint --help", "git diff", "zig build test" } },
    .{ .tool = "zig_lint_compare", .analysis_kind = "dual_linter_consensus_comparison", .capability_tier = "advisory_orientation", .confidence = "medium", .confidence_class = "advisory", .source_coverage = lint_evidence_coverage, .limitations = lint_intelligence_limits, .verify_with = &.{ "zig_zlint", "zig_lint" } },
    .{ .tool = "zig_lint_profile", .analysis_kind = "lint_gate_profile_policy", .capability_tier = "advisory_orientation", .confidence = "medium", .confidence_class = "orientation_only", .source_coverage = "Built-in lint gate profile policy table.", .limitations = &.{"Profiles are policy presets; they do not inspect source or run linters."}, .verify_with = &.{"zig_lint_gate"} },
    .{ .tool = "zig_lint_gate", .analysis_kind = "lint_findings_policy_gate", .capability_tier = "advisory_orientation", .confidence = "medium", .confidence_class = "advisory", .source_coverage = lint_evidence_coverage, .limitations = lint_intelligence_limits, .verify_with = &.{ "configured linters", "project CI" } },
    .{ .tool = "zig_lint_fix_plan", .analysis_kind = "lint_fix_planning", .capability_tier = "advisory_orientation", .confidence = "low", .confidence_class = "orientation_only", .source_coverage = lint_evidence_coverage, .limitations = &.{"Produces planning buckets over observed findings; source edits are delegated to apply-gated fix tools such as zig_zlint_fix."}, .verify_with = &.{ "code review", "zig build test" } },
    .{ .tool = "zig_lint_baseline", .analysis_kind = "lint_baseline_comparison", .capability_tier = "advisory_orientation", .confidence = "medium", .confidence_class = "advisory", .source_coverage = lint_evidence_coverage, .limitations = lint_intelligence_limits, .verify_with = &.{ "zig_lint_gate", "configured linters" } },
    .{ .tool = "zig_lint_suppressions", .analysis_kind = "lint_suppression_filter", .capability_tier = "advisory_orientation", .confidence = "medium", .confidence_class = "advisory", .source_coverage = lint_evidence_coverage, .limitations = lint_intelligence_limits, .verify_with = &.{ "code review", "configured linters" } },
    .{ .tool = "zig_lint_trend", .analysis_kind = "lint_trend_comparison", .capability_tier = "advisory_orientation", .confidence = "medium", .confidence_class = "advisory", .source_coverage = lint_evidence_coverage, .limitations = lint_intelligence_limits, .verify_with = &.{ "configured linters", "project CI" } },
    .{ .tool = "zig_lint", .analysis_kind = "optional_zwanzig_lint_json", .capability_tier = "zwanzig_backed", .confidence = "high", .confidence_class = "release_gating_candidate", .source_coverage = zwanzig_output_coverage, .limitations = zwanzig_limits, .verify_with = &.{"configured zwanzig --help"} },
    .{ .tool = "zig_lint_sarif", .analysis_kind = "optional_zwanzig_lint_sarif", .capability_tier = "zwanzig_backed", .confidence = "high", .confidence_class = "release_gating_candidate", .source_coverage = zwanzig_output_coverage, .limitations = zwanzig_limits, .verify_with = &.{"configured zwanzig --help"} },
    .{ .tool = "zig_lint_rules", .analysis_kind = "optional_zwanzig_rule_catalog", .capability_tier = "zwanzig_backed", .confidence = "medium", .confidence_class = "advisory", .source_coverage = zwanzig_output_coverage, .limitations = zwanzig_limits, .verify_with = &.{"configured zwanzig --help"} },
    .{ .tool = "zig_analysis_graphs", .analysis_kind = "optional_zwanzig_analysis_graph", .capability_tier = "zwanzig_backed", .confidence = "high", .confidence_class = "advisory", .source_coverage = zwanzig_output_coverage, .limitations = zwanzig_limits, .verify_with = &.{"configured zwanzig graph mode"} },
};

fn putMetadata(allocator: std.mem.Allocator, obj: *std.json.ObjectMap, tool_name: []const u8) !void {
    const contract = contractFor(tool_name) orelse unreachable;
    try obj.put(allocator, "analysis_kind", .{ .string = contract.analysis_kind });
    try obj.put(allocator, "capability_tier", .{ .string = contract.capability_tier });
    try obj.put(allocator, "confidence", .{ .string = contract.confidence });
    try obj.put(allocator, "confidence_class", .{ .string = contract.confidence_class });
    try obj.put(allocator, "source_coverage", .{ .string = contract.source_coverage });
    try obj.put(allocator, "limitations", try stringArrayValue(allocator, contract.limitations));
    try obj.put(allocator, "verify_with", try stringArrayValue(allocator, contract.verify_with));
    try obj.put(allocator, "evidence_basis", try evidenceBasisValue(allocator, contract));
    try obj.put(allocator, "cross_check", try crossCheckValue(allocator, contract));
    if (contract.verify_with.len > 0) try obj.put(allocator, "recommended_cross_check", .{ .string = contract.verify_with[0] });
}

fn contractFor(tool_name: []const u8) ?Contract {
    for (contracts) |contract| if (std.mem.eql(u8, contract.tool, tool_name)) return contract;
    return null;
}

fn evidenceBasisValue(allocator: std.mem.Allocator, contract: Contract) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "analysis_kind", .{ .string = contract.analysis_kind });
    try obj.put(allocator, "capability_tier", .{ .string = contract.capability_tier });
    try obj.put(allocator, "confidence", .{ .string = contract.confidence });
    try obj.put(allocator, "confidence_class", .{ .string = contract.confidence_class });
    try obj.put(allocator, "source_coverage", .{ .string = contract.source_coverage });
    try obj.put(allocator, "limitations", try stringArrayValue(allocator, contract.limitations));
    return .{ .object = obj };
}

fn crossCheckValue(allocator: std.mem.Allocator, contract: Contract) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "required_for_release_gate", .{ .bool = false });
    if (contract.verify_with.len > 0) {
        try obj.put(allocator, "primary", .{ .string = contract.verify_with[0] });
    } else {
        try obj.put(allocator, "primary", .null);
    }
    try obj.put(allocator, "verify_with", try stringArrayValue(allocator, contract.verify_with));
    return .{ .object = obj };
}

fn stringArrayValue(allocator: std.mem.Allocator, values: []const []const u8) !std.json.Value {
    var array = std.json.Array.init(allocator);
    for (values) |value| try array.append(.{ .string = value });
    return .{ .array = array };
}

const command_runner_fake = @import("../../../testing/fakes/command_runner.zig");
const static_cache_fake = @import("../../../testing/fakes/static_cache.zig");
const workspace_store_fake = @import("../../../testing/fakes/workspace_store.zig");
const workspace_scanner_fake = @import("../../../testing/fakes/workspace_scanner.zig");

test "semantic adapter metadata preserves public contract fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var obj = std.json.ObjectMap.empty;
    try putMetadata(arena.allocator(), &obj, "zig_semantic_query");
    try std.testing.expectEqualStrings("parser_backed_semantic_index_query", obj.get("analysis_kind").?.string);
    try std.testing.expectEqualStrings("parser_backed", obj.get("capability_tier").?.string);
    try std.testing.expectEqualStrings("zig ast-check", obj.get("recommended_cross_check").?.string);

    var zlint_obj = std.json.ObjectMap.empty;
    try putMetadata(arena.allocator(), &zlint_obj, "zig_zlint");
    try std.testing.expectEqualStrings("optional_zlint_diagnostics", zlint_obj.get("analysis_kind").?.string);
    try std.testing.expectEqualStrings("zlint_backed", zlint_obj.get("capability_tier").?.string);

    var zwanzig_obj = std.json.ObjectMap.empty;
    try putMetadata(arena.allocator(), &zwanzig_obj, "zig_analysis_graphs");
    try std.testing.expectEqualStrings("optional_zwanzig_analysis_graph", zwanzig_obj.get("analysis_kind").?.string);
    try std.testing.expectEqualStrings("zwanzig_backed", zwanzig_obj.get("capability_tier").?.string);
}

test "static analysis adapters exercise scanner and project value wrappers" {
    const backing_allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(backing_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var commands = command_runner_fake.FakeCommandRunner.init(backing_allocator);
    defer commands.deinit();
    var store = workspace_store_fake.FakeWorkspaceStore.init(backing_allocator);
    defer store.deinit();
    var scanner = workspace_scanner_fake.FakeWorkspaceScanner.init(backing_allocator);
    defer scanner.deinit();
    var cache = static_cache_fake.FakeStaticCache.init(backing_allocator);
    defer cache.deinit();
    const context = testStaticAdapterContext(&commands, &store, &scanner, &cache);

    try scanner.expectScan(.{ .max_files = 2, .provenance = "static_analysis.import_graph" }, &.{"src/main.zig"});
    try store.expectRead(.{ .path = "src/main.zig", .max_bytes = workspace_scans.default_source_read_limit, .provenance = "static_analysis.import_graph" },
        \\const std = @import("std");
        \\const dep = @import("dep.zig");
    );
    const graph_text = try zigImportGraph(allocator, context, try testArgs(arena.allocator(), "{\"limit\":2}"));
    defer mcp_result.deinitToolResult(allocator, graph_text);
    try expectResultObjectKind(graph_text, "zig_import_graph");

    try scanner.expectScan(.{ .max_files = 1, .provenance = "static_analysis.import_graph" }, &.{"src/lib.zig"});
    try store.expectRead(.{ .path = "src/lib.zig", .max_bytes = workspace_scans.default_source_read_limit, .provenance = "static_analysis.import_graph" },
        \\const std = @import("std");
    );
    const graph_json = try zigImportGraphJson(allocator, context, try testArgs(arena.allocator(), "{\"limit\":1}"));
    defer mcp_result.deinitToolResult(allocator, graph_json);
    try expectResultHasMetadata(graph_json);

    try scanner.expectScan(.{ .max_files = 3, .provenance = "static_analysis.test_discover" }, &.{"src/main.zig"});
    try store.expectRead(.{ .path = "src/main.zig", .max_bytes = workspace_scans.default_source_read_limit, .provenance = "static_analysis.test_discover" },
        \\test "alpha" {}
        \\pub fn main() void {}
    );
    const tests = try zigTestDiscover(allocator, context, try testArgs(arena.allocator(), "{\"limit\":3}"));
    defer mcp_result.deinitToolResult(allocator, tests);
    try expectResultHasMetadata(tests);

    try expectBuildGraphReads(&store);
    const build_graph = try zigBuildGraph(allocator, context, null);
    defer mcp_result.deinitToolResult(allocator, build_graph);
    try expectResultHasMetadata(build_graph);

    try expectBuildGraphReads(&store);
    const build_targets = try zigBuildTargets(allocator, context, null);
    defer mcp_result.deinitToolResult(allocator, build_targets);
    try expectResultHasMetadata(build_targets);

    try expectBuildOptionsRead(&store);
    const build_options = try zigBuildOptions(allocator, context, null);
    defer mcp_result.deinitToolResult(allocator, build_options);
    try expectResultHasMetadata(build_options);

    try store.expectResolve(.{ .path = "src/main.zig", .provenance = "static_analysis.file_owner" }, "/workspace/src/main.zig");
    try expectBuildGraphReads(&store);
    const owner = try zigFileOwner(allocator, context, try testArgs(arena.allocator(), "{\"file\":\"src/main.zig\"}"));
    defer mcp_result.deinitToolResult(allocator, owner);
    try expectResultHasMetadata(owner);

    try expectBuildGraphReads(&store);
    const resolved = try zigImportResolve(allocator, context, try testArgs(arena.allocator(), "{\"import\":\"dep\",\"from\":\"src/main.zig\"}"));
    defer mcp_result.deinitToolResult(allocator, resolved);
    try expectResultHasMetadata(resolved);

    try expectDependencyInspect(&store);
    const deps = try zigDependencyInspect(allocator, context, null);
    defer mcp_result.deinitToolResult(allocator, deps);
    try expectResultHasMetadata(deps);

    const matrix = try zigTargetMatrixPlan(allocator, context, try testArgs(arena.allocator(), "{\"targets\":\"native wasm32-freestanding\",\"steps\":\"build test\"}"));
    defer mcp_result.deinitToolResult(allocator, matrix);
    try expectResultObjectKind(matrix, "zig_target_matrix_plan");

    const triage = try zigTestFailureTriage(allocator, context, try testArgs(arena.allocator(), "{\"text\":\"src/main.zig:1:1: error: bad\",\"args\":\"--summary all\"}"));
    defer mcp_result.deinitToolResult(allocator, triage);
    try expectResultObjectKind(triage, "zig_test_failure_triage");

    const semantic_status = try zigSemanticIndexStatus(allocator, context, null);
    defer mcp_result.deinitToolResult(allocator, semantic_status);
    try expectResultObjectKind(semantic_status, "zig_semantic_index_status");

    try commands.verify();
    try store.verify();
    try scanner.verify();
}

test "static lint adapters exercise argument parsing metadata and backend errors" {
    const backing_allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(backing_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var commands = command_runner_fake.FakeCommandRunner.init(backing_allocator);
    defer commands.deinit();
    var store = workspace_store_fake.FakeWorkspaceStore.init(backing_allocator);
    defer store.deinit();
    var scanner = workspace_scanner_fake.FakeWorkspaceScanner.init(backing_allocator);
    defer scanner.deinit();
    var cache = static_cache_fake.FakeStaticCache.init(backing_allocator);
    defer cache.deinit();
    const context = testStaticAdapterContext(&commands, &store, &scanner, &cache);

    try store.expectResolve(.{ .path = "src", .provenance = "static_analysis.zlint_path" }, "/workspace/src");
    try commands.expectRun(.{
        .argv = &.{ "zlint-test", "--format", "json", "--rules", "style", "/workspace/src", "--trace" },
        .cwd = "/workspace",
        .timeout_ms = 12,
        .provenance = "static_analysis.zlint",
    }, .{ .stdout = "[{\"rule\":\"style\",\"severity\":\"warning\",\"path\":\"src/main.zig\",\"line\":1,\"message\":\"warn\"}]" });
    const zlint = try zigZlintSarif(allocator, context, try testArgs(arena.allocator(), "{\"path\":\"src\",\"rules\":\"style\",\"args\":\"--trace\",\"timeout_ms\":12}"));
    defer mcp_result.deinitToolResult(allocator, zlint);
    try expectResultObjectKind(zlint, "zig_zlint_sarif");

    try commands.expectRun(.{
        .argv = &.{ "zlint-test", "--help" },
        .cwd = "/workspace",
        .timeout_ms = 42,
        .provenance = "static_analysis.zlint_rules_help",
    }, .{ .stdout = "--rules\n--format\n" });
    try commands.expectRun(.{
        .argv = &.{ "zlint-test", "--rules", "--format", "json" },
        .cwd = "/workspace",
        .timeout_ms = 42,
        .provenance = "static_analysis.zlint_rules",
    }, .{ .stdout = "{\"rules\":[{\"id\":\"style\",\"severity\":\"warning\"}]}" });
    const rules = try zigZlintRules(allocator, context, null);
    defer mcp_result.deinitToolResult(allocator, rules);
    try expectResultObjectKind(rules, "zig_zlint_rules");

    try store.expectResolve(.{ .path = "src/main.zig", .provenance = "static_analysis.zlint_fix_path" }, "/workspace/src/main.zig");
    const fix = try zigZlintFix(allocator, context, try testArgs(arena.allocator(), "{\"path\":\"src/main.zig\",\"rules\":\"style\",\"dangerous\":true,\"args\":\"--dry\"}"));
    defer mcp_result.deinitToolResult(allocator, fix);
    try expectResultObjectKind(fix, "zig_zlint_fix");

    const compare = try zigLintCompare(allocator, context, try testArgs(arena.allocator(),
        \\{"zlint_findings":"[{\"rule\":\"r\",\"severity\":\"warning\",\"path\":\"a.zig\",\"line\":1}]","zwanzig_findings":"[]"}
    ));
    defer mcp_result.deinitToolResult(allocator, compare);
    try expectResultObjectKind(compare, "zig_lint_compare");

    const profile = try zigLintProfile(allocator, context, try testArgs(arena.allocator(), "{\"profile\":\"strict\"}"));
    defer mcp_result.deinitToolResult(allocator, profile);
    try expectResultObjectKind(profile, "zig_lint_profile");

    const gate = try zigLintGate(allocator, context, try testArgs(arena.allocator(),
        \\{"findings":"[{\"rule\":\"r\",\"severity\":\"warning\",\"path\":\"a.zig\",\"line\":1}]","profile":"strict","max_warnings":0}
    ));
    defer mcp_result.deinitToolResult(allocator, gate);
    try expectResultObjectKind(gate, "zig_lint_gate");

    const plan = try zigLintFixPlan(allocator, context, try testArgs(arena.allocator(),
        \\{"findings":"[{\"rule\":\"fmt\",\"severity\":\"warning\",\"path\":\"a.zig\",\"line\":1,\"message\":\"format\"}]"}
    ));
    defer mcp_result.deinitToolResult(allocator, plan);
    try expectResultObjectKind(plan, "zig_lint_fix_plan");

    const baseline = try zigLintBaseline(allocator, context, try testArgs(arena.allocator(),
        \\{"findings":"[{\"rule\":\"r\",\"severity\":\"warning\",\"path\":\"a.zig\",\"line\":1}]","baseline":"[]"}
    ));
    defer mcp_result.deinitToolResult(allocator, baseline);
    try expectResultObjectKind(baseline, "zig_lint_baseline");

    const suppressions = try zigLintSuppressions(allocator, context, try testArgs(arena.allocator(),
        \\{"findings":"[{\"rule\":\"r\",\"severity\":\"warning\",\"path\":\"a.zig\",\"line\":1}]","suppressions":"[]"}
    ));
    defer mcp_result.deinitToolResult(allocator, suppressions);
    try expectResultObjectKind(suppressions, "zig_lint_suppressions");

    const trend = try zigLintTrend(allocator, context, try testArgs(arena.allocator(),
        \\{"before":"[]","after":"[{\"rule\":\"r\",\"severity\":\"warning\",\"path\":\"a.zig\",\"line\":1}]"}
    ));
    defer mcp_result.deinitToolResult(allocator, trend);
    try expectResultObjectKind(trend, "zig_lint_trend");

    try store.expectResolve(.{ .path = "src", .provenance = "static_analysis.zwanzig_path" }, "/workspace/src");
    try commands.expectRun(.{
        .argv = &.{ "zwanzig-test", "--format", "json", "--do", "safety", "/workspace/src", "--trace" },
        .cwd = "/workspace",
        .timeout_ms = 42,
        .provenance = "static_analysis.zwanzig",
    }, .{ .stdout = "ok\n" });
    const lint = try zigLint(allocator, context, try testArgs(arena.allocator(), "{\"path\":\"src\",\"rules_do\":\"safety\",\"args\":\"--trace\"}"));
    defer mcp_result.deinitToolResult(allocator, lint);
    try expectResultObjectKind(lint, "command");
    try std.testing.expectEqualStrings("zig_lint", lint.structuredContent.?.object.get("tool").?.string);

    try commands.expectRunError(.{
        .argv = &.{ "zwanzig-test", "--help" },
        .cwd = "/workspace",
        .timeout_ms = 42,
        .provenance = "static_analysis.zwanzig",
    }, error.RequestTimeout);
    const lint_rules = try zigLintRules(allocator, context, null);
    defer mcp_result.deinitToolResult(allocator, lint_rules);
    try expectResultObjectKind(lint_rules, "command_error");
    try std.testing.expectEqualStrings("zig_lint_rules", lint_rules.structuredContent.?.object.get("tool").?.string);

    const split_error = try zigZlintFix(allocator, context, try testArgs(arena.allocator(), "{\"args\":\"\\\"unterminated\"}"));
    defer mcp_result.deinitToolResult(allocator, split_error);
    try std.testing.expect(split_error.is_error);

    try commands.verify();
    try store.verify();
    try scanner.verify();
}

test "static adapter private error classifiers cover public categories" {
    try std.testing.expectEqualStrings("missing_command_runner", staticErrorCode(error.MissingCommandRunner));
    try std.testing.expectEqualStrings("workspace_path", staticErrorCode(error.PathOutsideWorkspace));
    try std.testing.expectEqualStrings("file_not_found", staticErrorCode(error.FileNotFound));
    try std.testing.expectEqualStrings("timeout", staticErrorCode(error.RequestTimeout));
    try std.testing.expectEqualStrings("output_limit", staticErrorCode(error.OutputLimitExceeded));
    try std.testing.expectEqualStrings("static_analysis_failed", staticErrorCode(error.UnexpectedCall));
    try std.testing.expect(staticErrorRetryable(error.Timeout));
    try std.testing.expect(!staticErrorRetryable(error.FileNotFound));
    try std.testing.expectEqualStrings("configuration", staticErrorCategory(error.MissingCommandRunner));
    try std.testing.expectEqualStrings("Retry with a smaller scope or a larger timeout_ms value.", staticErrorResolution(error.Timeout));

    try std.testing.expectEqualStrings("invalid_request", lintErrorCode(error.InvalidRequest));
    try std.testing.expectEqualStrings("argument", lintErrorCategory(error.InvalidRequest));
    try std.testing.expect(lintErrorRetryable(error.RequestTimeout));
    try std.testing.expect(!lintErrorRetryable(error.InvalidRequest));
    try std.testing.expectEqualStrings("Retry with narrower lint output, a smaller path scope, or backend flags that reduce output.", lintErrorResolution(error.OutputLimitExceeded));

    try std.testing.expectEqualStrings("missing_cache_port", semanticErrorCode(error.MissingCachePort));
    try std.testing.expectEqualStrings("cache", semanticErrorCategory(error.InvalidCache));
    try std.testing.expect(semanticErrorRetryable(error.Timeout));
    try std.testing.expect(semanticErrorRetryable(error.InvalidCache));
    try std.testing.expectEqualStrings("Retry with refresh=true to rebuild the semantic index from workspace sources.", semanticErrorResolution(error.InvalidCache));

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const non_object = try structuredLintValue(std.testing.allocator, allocator, "zig_lint_profile", .{ .string = "plain" });
    defer mcp_result.deinitToolResult(std.testing.allocator, non_object);
    const zwanzig = try structuredZwanzigValue(std.testing.allocator, allocator, "zig_lint_rules", .{ .object = std.json.ObjectMap.empty });
    defer mcp_result.deinitToolResult(std.testing.allocator, zwanzig);
    const graph = try structuredGraphValue(std.testing.allocator, allocator, .{ .object = std.json.ObjectMap.empty });
    defer mcp_result.deinitToolResult(std.testing.allocator, graph);
}

test "static adapter error result helpers cover tool path lint semantic and export failures" {
    const backing_allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(backing_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var commands = command_runner_fake.FakeCommandRunner.init(backing_allocator);
    defer commands.deinit();
    var store = workspace_store_fake.FakeWorkspaceStore.init(backing_allocator);
    defer store.deinit();
    var scanner = workspace_scanner_fake.FakeWorkspaceScanner.init(backing_allocator);
    defer scanner.deinit();
    var cache = static_cache_fake.FakeStaticCache.init(backing_allocator);
    defer cache.deinit();
    const context = testStaticAdapterContext(&commands, &store, &scanner, &cache);

    try std.testing.expectError(error.OutOfMemory, staticToolError(allocator, "zig_build_graph", "op", "phase", error.OutOfMemory));
    const static_error = try staticToolError(backing_allocator, "zig_build_graph", "op", "phase", error.FileNotFound);
    defer mcp_result.deinitToolResult(backing_allocator, static_error);
    try std.testing.expect(static_error.is_error);
    try std.testing.expectEqualStrings("file_not_found", static_error.structuredContent.?.object.get("code").?.string);

    const path_error = try staticPathError(backing_allocator, context, "zig_file_owner", "../out.zig", error.PathOutsideWorkspace);
    defer mcp_result.deinitToolResult(backing_allocator, path_error);
    try std.testing.expectEqualStrings("workspace_path_error", path_error.structuredContent.?.object.get("kind").?.string);
    const generic_path = try staticPathError(backing_allocator, context, "zig_file_owner", "src/main.zig", error.UnexpectedCall);
    defer mcp_result.deinitToolResult(backing_allocator, generic_path);
    try std.testing.expectEqualStrings("static_analysis_failed", generic_path.structuredContent.?.object.get("code").?.string);

    try std.testing.expectError(error.OutOfMemory, semanticToolError(allocator, "zig_semantic_query", "op", "phase", error.OutOfMemory));
    const semantic_error = try semanticToolError(backing_allocator, "zig_semantic_query", "op", "phase", error.InvalidCache);
    defer mcp_result.deinitToolResult(backing_allocator, semantic_error);
    try std.testing.expectEqualStrings("invalid_semantic_cache", semantic_error.structuredContent.?.object.get("code").?.string);

    try std.testing.expectError(error.OutOfMemory, lintToolError(allocator, context, "zig_lint", ".", "op", "phase", error.OutOfMemory));
    const lint_path = try lintToolError(backing_allocator, context, "zig_lint", "../out", "op", "phase", error.PathOutsideWorkspace);
    defer mcp_result.deinitToolResult(backing_allocator, lint_path);
    try std.testing.expectEqualStrings("workspace_path_error", lint_path.structuredContent.?.object.get("kind").?.string);
    const lint_invalid = try lintToolError(backing_allocator, context, "zig_lint", "src", "op", "phase", error.InvalidRequest);
    defer mcp_result.deinitToolResult(backing_allocator, lint_invalid);
    try std.testing.expectEqualStrings("argument_error", lint_invalid.structuredContent.?.object.get("kind").?.string);
    const lint_generic = try lintToolError(backing_allocator, context, "zig_lint", "src", "op", "phase", error.StreamTooLong);
    defer mcp_result.deinitToolResult(backing_allocator, lint_generic);
    try std.testing.expectEqualStrings("output_limit", lint_generic.structuredContent.?.object.get("code").?.string);

    try std.testing.expectError(error.OutOfMemory, splitToolArgsError(allocator, "zig_zlint_fix", "args", "--x", error.OutOfMemory));
    const split_generic = try splitToolArgsError(backing_allocator, "zig_zlint_fix", "args", "--x", error.UnexpectedCall);
    defer mcp_result.deinitToolResult(backing_allocator, split_generic);
    try std.testing.expectEqualStrings("argument_parse_failed", split_generic.structuredContent.?.object.get("code").?.string);

    try std.testing.expectError(error.OutOfMemory, exportError(allocator, context, "zig_code_index_export", "out.json", error.OutOfMemory));
    const export_path = try exportError(backing_allocator, context, "zig_code_index_export", "../out.json", error.PathOutsideWorkspace);
    defer mcp_result.deinitToolResult(backing_allocator, export_path);
    try std.testing.expectEqualStrings("workspace_path_error", export_path.structuredContent.?.object.get("kind").?.string);
    const export_generic = try exportError(backing_allocator, context, "zig_code_index_export", "out.json", error.MissingCachePort);
    defer mcp_result.deinitToolResult(backing_allocator, export_generic);
    try std.testing.expectEqualStrings("missing_cache_port", export_generic.structuredContent.?.object.get("code").?.string);
}

test "static adapter JSON value helpers include skipped files and metadata fallbacks" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var graph_imports = [_]workspace_scans.ImportEdge{.{ .import = "std" }};
    var graph_files = [_]workspace_scans.ImportFile{.{
        .file = "src/main.zig",
        .imports = graph_imports[0..],
    }};
    var graph_skipped = [_]workspace_scans.SkippedFile{.{ .path = "src/bad.zig", .error_name = "AccessDenied" }};
    const graph = workspace_scans.ImportGraphResult{
        .files = graph_files[0..],
        .skipped_files = graph_skipped[0..],
    };
    const graph_value = try importGraphJsonValue(allocator, graph);
    try std.testing.expectEqual(@as(usize, 1), graph_value.object.get("skipped_files").?.array.items.len);
    try std.testing.expectEqual(@as(i64, 1), graph_value.object.get("skipped_file_count").?.integer);

    var test_decls = [_]workspace_scans.TestDecl{.{
        .file = "src/main.zig",
        .line = 9,
        .declaration = "test \"unit\"",
        .command = "zig test src/main.zig --test-filter unit",
    }};
    var test_skipped = [_]workspace_scans.SkippedFile{.{ .path = "src/unreadable.zig", .error_name = "FileNotFound" }};
    const discovered = workspace_scans.TestDiscoverResult{
        .tests = test_decls[0..],
        .skipped_files = test_skipped[0..],
    };
    const discover_value = try testDiscoverJsonValue(allocator, discovered);
    try std.testing.expectEqual(@as(usize, 1), discover_value.object.get("skipped_files").?.array.items.len);
    try std.testing.expectEqual(@as(i64, 1), discover_value.object.get("skipped_file_count").?.integer);

    const unknown_contract = contractFor("zig_unknown_tool");
    try std.testing.expect(unknown_contract == null);
    const custom_contract = Contract{
        .tool = "custom",
        .analysis_kind = "kind",
        .capability_tier = "tier",
        .confidence = "low",
        .confidence_class = "class",
        .source_coverage = "coverage",
        .limitations = &.{},
        .verify_with = &.{},
    };
    const cross_check = try crossCheckValue(allocator, custom_contract);
    try std.testing.expect(cross_check.object.get("primary").? == .null);
}

test "static adapter argument and findings validators cover edge cases" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const parsed = try splitArgs(allocator, " --one \"two words\" 'three four' escaped\\ value ");
    try std.testing.expectEqual(@as(usize, 4), parsed.len);
    try std.testing.expectEqualStrings("--one", parsed[0]);
    try std.testing.expectEqualStrings("two words", parsed[1]);
    try std.testing.expectEqualStrings("three four", parsed[2]);
    try std.testing.expectEqualStrings("escaped value", parsed[3]);
    try std.testing.expectError(error.InvalidArguments, splitArgs(allocator, "unterminated\\"));

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 1000 });
    const copied = try splitArgs(failing.allocator(), "a b");
    defer freeArgList(failing.allocator(), copied);
    try std.testing.expectEqual(@as(usize, 2), copied.len);
    try std.testing.expectEqualStrings("a", copied[0]);

    var fail_index: usize = 0;
    while (fail_index < 8) : (fail_index += 1) {
        var fail_list_append = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        if (splitArgs(fail_list_append.allocator(), "a b")) |args| {
            freeArgList(fail_list_append.allocator(), args);
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
        }
    }

    try std.testing.expect((try validateFindingsArgument(allocator, null, "zlint_findings")) == null);
    try std.testing.expect((try validateFindingsArgument(allocator, try testArgs(allocator, "{\"zlint_findings\":\"   \\n \"}"), "zlint_findings")) == null);
    try std.testing.expect((try validateFindingsArgument(allocator, try testArgs(allocator, "{\"zlint_findings\":\"[]\"}"), "zlint_findings")) == null);
    const invalid = try validateFindingsArgument(std.testing.allocator, try testArgs(allocator, "{\"zlint_findings\":\"not json\"}"), "zlint_findings");
    defer if (invalid) |result| mcp_result.deinitToolResult(std.testing.allocator, result);
    try std.testing.expect(invalid != null);
    try std.testing.expect(invalid.?.is_error);
}

test "static adapter public error branches preserve structured failures" {
    const backing_allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(backing_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var commands = command_runner_fake.FakeCommandRunner.init(backing_allocator);
    defer commands.deinit();
    var store = workspace_store_fake.FakeWorkspaceStore.init(backing_allocator);
    defer store.deinit();
    var scanner = workspace_scanner_fake.FakeWorkspaceScanner.init(backing_allocator);
    defer scanner.deinit();
    var cache = static_cache_fake.FakeStaticCache.init(backing_allocator);
    defer cache.deinit();
    const context = testStaticAdapterContext(&commands, &store, &scanner, &cache);

    const triage_args_error = try zigTestFailureTriage(backing_allocator, context, try testArgs(allocator, "{\"args\":\"\\\"unterminated\"}"));
    defer mcp_result.deinitToolResult(backing_allocator, triage_args_error);
    try std.testing.expectEqualStrings("argument_error", triage_args_error.structuredContent.?.object.get("kind").?.string);

    try store.expectResolveError(.{ .path = "../bad.zig", .provenance = "static_analysis.test_failure_triage" }, error.PathOutsideWorkspace);
    const triage_path_error = try zigTestFailureTriage(backing_allocator, context, try testArgs(allocator, "{\"file\":\"../bad.zig\"}"));
    defer mcp_result.deinitToolResult(backing_allocator, triage_path_error);
    try std.testing.expectEqualStrings("workspace_path_error", triage_path_error.structuredContent.?.object.get("kind").?.string);

    var no_runner_context = context;
    no_runner_context.command_runner = null;
    const triage_backend_error = try zigTestFailureTriage(backing_allocator, no_runner_context, try testArgs(allocator, "{\"filter\":\"unit\"}"));
    defer mcp_result.deinitToolResult(backing_allocator, triage_backend_error);
    try std.testing.expectEqualStrings("missing_command_runner", triage_backend_error.structuredContent.?.object.get("code").?.string);

    var failing = std.testing.FailingAllocator.init(backing_allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, zigPublicApiDiff(failing.allocator(), context, try testArgs(allocator,
        \\{"before":"pub fn old() void {}","after":"pub fn new() void {}"}
    )));

    const analysis_mode_error = try zigAnalysisGraphs(backing_allocator, context, try testArgs(allocator, "{\"mode\":\"raw-flag\",\"path\":\"src/main.zig\",\"output\":\"graphs\"}"));
    defer mcp_result.deinitToolResult(backing_allocator, analysis_mode_error);
    try std.testing.expectEqualStrings("argument_error", analysis_mode_error.structuredContent.?.object.get("kind").?.string);

    try store.expectResolveError(.{ .path = "src/main.zig", .provenance = "static_analysis.zwanzig_graph_path" }, error.FileNotFound);
    const analysis_resolve_error = try zigAnalysisGraphs(backing_allocator, context, try testArgs(allocator, "{\"mode\":\"cfg\",\"path\":\"src/main.zig\",\"output\":\"graphs\"}"));
    defer mcp_result.deinitToolResult(backing_allocator, analysis_resolve_error);
    try std.testing.expectEqualStrings("file_not_found", analysis_resolve_error.structuredContent.?.object.get("code").?.string);

    try store.expectResolve(.{ .path = "src/main.zig", .provenance = "static_analysis.zwanzig_graph_path" }, "/workspace/src/main.zig");
    try store.expectResolve(.{ .path = "graphs", .for_output = true, .provenance = "static_analysis.zwanzig_graph_output" }, "/workspace/graphs");
    try store.expectEnsureDir(.{ .path = "graphs", .provenance = "static_analysis.zwanzig_graph_output" }, .{ .created_or_existing = true });
    try commands.expectRun(.{
        .argv = &.{ "zwanzig-test", "--dump-cfg", "/workspace/graphs", "/workspace/src/main.zig" },
        .cwd = "/workspace",
        .timeout_ms = 42,
        .provenance = "static_analysis.zwanzig_graph",
    }, .{ .exit_code = 1, .stderr = "graph failed\n" });
    const analysis_backend_error = try zigAnalysisGraphs(backing_allocator, context, try testArgs(allocator, "{\"mode\":\"cfg\",\"path\":\"src/main.zig\",\"output\":\"graphs\"}"));
    defer mcp_result.deinitToolResult(backing_allocator, analysis_backend_error);
    try std.testing.expect(analysis_backend_error.is_error);
    try std.testing.expectEqualStrings("zwanzig_graph_command_failed", analysis_backend_error.structuredContent.?.object.get("code").?.string);

    const semantic_query_error = try zigSemanticQuery(backing_allocator, no_runnerContextWithCache(context), try testArgs(allocator, "{\"query\":\"main\"}"));
    defer mcp_result.deinitToolResult(backing_allocator, semantic_query_error);
    try std.testing.expectEqualStrings("missing_cache_port", semantic_query_error.structuredContent.?.object.get("code").?.string);

    const semantic_decl_error = try zigSemanticDecl(backing_allocator, no_runnerContextWithCache(context), try testArgs(allocator, "{\"symbol\":\"main\"}"));
    defer mcp_result.deinitToolResult(backing_allocator, semantic_decl_error);
    try std.testing.expectEqualStrings("missing_cache_port", semantic_decl_error.structuredContent.?.object.get("code").?.string);

    try scanner.expectScanError(.{ .max_files = null, .provenance = "static_analysis.semantic_refs" }, error.RequestTimeout);
    const refs_error = try zigSemanticRefs(backing_allocator, context, try testArgs(allocator, "{\"symbol\":\"main\"}"));
    defer mcp_result.deinitToolResult(backing_allocator, refs_error);
    try std.testing.expectEqualStrings("timeout", refs_error.structuredContent.?.object.get("code").?.string);

    const fusion_error = try zigStaticFusion(backing_allocator, no_runnerContextWithCache(context), try testArgs(allocator, "{\"query\":\"main\"}"));
    defer mcp_result.deinitToolResult(backing_allocator, fusion_error);
    try std.testing.expectEqualStrings("missing_cache_port", fusion_error.structuredContent.?.object.get("code").?.string);

    try store.expectResolveError(.{ .path = "src", .provenance = "static_analysis.zlint_path" }, error.PathOutsideWorkspace);
    const zlint_error = try zigZlint(backing_allocator, context, try testArgs(allocator, "{\"path\":\"src\"}"));
    defer mcp_result.deinitToolResult(backing_allocator, zlint_error);
    try std.testing.expectEqualStrings("workspace_path_error", zlint_error.structuredContent.?.object.get("kind").?.string);

    try commands.expectRunError(.{
        .argv = &.{ "zlint-test", "--help" },
        .cwd = "/workspace",
        .timeout_ms = 42,
        .provenance = "static_analysis.zlint_rules_help",
    }, error.StreamTooLong);
    const zlint_rules_error = try zigZlintRules(backing_allocator, context, null);
    defer mcp_result.deinitToolResult(backing_allocator, zlint_rules_error);
    try expectResultObjectKind(zlint_rules_error, "backend_error");

    const zlint_rules_missing_runner = try zigZlintRules(backing_allocator, no_runner_context, null);
    defer mcp_result.deinitToolResult(backing_allocator, zlint_rules_missing_runner);
    try std.testing.expectEqualStrings("missing_command_runner", zlint_rules_missing_runner.structuredContent.?.object.get("code").?.string);

    try store.expectResolveError(.{ .path = "src/main.zig", .provenance = "static_analysis.zlint_fix_path" }, error.InvalidRequest);
    const zlint_fix_error = try zigZlintFix(backing_allocator, context, try testArgs(allocator, "{\"path\":\"src/main.zig\"}"));
    defer mcp_result.deinitToolResult(backing_allocator, zlint_fix_error);
    try std.testing.expectEqualStrings("argument_error", zlint_fix_error.structuredContent.?.object.get("kind").?.string);

    try store.expectResolveError(.{ .path = "src", .provenance = "static_analysis.zwanzig_path" }, error.FileNotFound);
    const zwanzig_error = try zigLint(backing_allocator, context, try testArgs(allocator, "{\"path\":\"src\"}"));
    defer mcp_result.deinitToolResult(backing_allocator, zwanzig_error);
    try std.testing.expectEqualStrings("file_not_found", zwanzig_error.structuredContent.?.object.get("code").?.string);

    try store.verify();
    try scanner.verify();
    try commands.verify();
}

fn testStaticAdapterContext(
    commands: *command_runner_fake.FakeCommandRunner,
    store: *workspace_store_fake.FakeWorkspaceStore,
    scanner: *workspace_scanner_fake.FakeWorkspaceScanner,
    cache: *static_cache_fake.FakeStaticCache,
) app_context.StaticAnalysisContext {
    return .{
        .workspace = .{ .root = "/workspace", .cache_root = "/workspace/.zigar-cache" },
        .tool_paths = .{ .zig = "zig-test", .zlint = "zlint-test", .zwanzig = "zwanzig-test" },
        .timeouts = .{ .command_ms = 42 },
        .command_runner = commands.port(),
        .workspace_store = store.port(),
        .workspace_scanner = scanner.port(),
        .semantic_index_cache = cache.port(),
    };
}

fn no_runnerContextWithCache(context: app_context.StaticAnalysisContext) app_context.StaticAnalysisContext {
    var copy = context;
    copy.semantic_index_cache = null;
    return copy;
}

fn testArgs(allocator: std.mem.Allocator, text: []const u8) !std.json.Value {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, text, .{});
    return parsed.value;
}

fn freeArgList(allocator: std.mem.Allocator, args: []const []const u8) void {
    for (args) |arg| allocator.free(arg);
    allocator.free(args);
}

fn expectResultObjectKind(result: mcp.tools.ToolResult, expected_kind: []const u8) !void {
    const structured = result.structuredContent orelse return error.MissingStructuredContent;
    try std.testing.expect(structured == .object);
    const kind = structured.object.get("kind") orelse return error.MissingKind;
    try std.testing.expect(kind == .string);
    try std.testing.expectEqualStrings(expected_kind, kind.string);
}

fn expectResultHasMetadata(result: mcp.tools.ToolResult) !void {
    const structured = result.structuredContent orelse return error.MissingStructuredContent;
    try std.testing.expect(structured == .object);
    try std.testing.expect(structured.object.get("analysis_kind") != null);
    try std.testing.expect(structured.object.get("capability_tier") != null);
    try std.testing.expect(structured.object.get("confidence") != null);
}

fn expectBuildGraphReads(store: *workspace_store_fake.FakeWorkspaceStore) !void {
    try store.expectRead(.{ .path = "build.zig", .max_bytes = project_values.default_build_read_limit, .provenance = "static_analysis.build_graph" },
        \\const exe = b.addExecutable(.{ .name = "demo", .root_source_file = b.path("src/main.zig") });
        \\const mod = b.addModule("core", .{ .root_source_file = b.path("src/lib.zig") });
        \\exe.root_module.addImport("dep", mod);
        \\const tests = b.addTest(.{ .root_source_file = b.path("src/main_test.zig") });
        \\const step = b.step("check", "Run checks");
    );
    try store.expectRead(.{ .path = "build.zig.zon", .max_bytes = project_values.default_build_read_limit, .provenance = "static_analysis.build_graph" },
        \\.{
        \\    .dependencies = .{
        \\        .dep = .{ .url = "https://example.invalid/dep.tar.gz", .hash = "abc" },
        \\    },
        \\    .paths = .{ "build.zig", "src" },
        \\}
    );
}

fn expectBuildOptionsRead(store: *workspace_store_fake.FakeWorkspaceStore) !void {
    try store.expectRead(.{ .path = "build.zig", .max_bytes = project_values.default_build_read_limit, .provenance = "static_analysis.build_options" },
        \\const target = b.standardTargetOptions(.{});
        \\const optimize = b.standardOptimizeOption(.{});
        \\const feature = b.option(bool, "feature", "Enable feature") orelse false;
        \\_ = target;
        \\_ = optimize;
        \\_ = feature;
    );
}

fn expectDependencyInspect(store: *workspace_store_fake.FakeWorkspaceStore) !void {
    try store.expectRead(.{ .path = "build.zig.zon", .max_bytes = project_values.default_build_read_limit, .provenance = "static_analysis.dependency_inspect" },
        \\.{
        \\    .dependencies = .{
        \\        .dep = .{ .url = "https://example.invalid/dep.tar.gz", .hash = "abc" },
        \\    },
        \\}
    );
    try store.expectResolve(.{ .path = "zig-pkg", .provenance = "static_analysis.cache_path_status" }, "/workspace/zig-pkg");
    try store.expectExists(.{ .path = "zig-pkg", .provenance = "static_analysis.cache_path_status" }, .{ .exists = true, .kind = .directory });
}
