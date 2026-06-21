//! Static-analysis MCP adapters that parse args, invoke app use cases, and
//! project graph/lint/semantic evidence into protocol-stable JSON.
const std = @import("std");
const mcp = @import("mcp");

const app_context = @import("../../../app/context.zig");
const ports = @import("../../../app/ports.zig");
const backend_contracts = @import("../../../domain/zig/backend_contracts.zig");
const agent_ergonomics = @import("../../../app/usecases/static_analysis/agent_ergonomics.zig");
const developer_pain = @import("../../../app/usecases/static_analysis/developer_pain.zig");
const lint_intelligence = @import("../../../app/usecases/static_analysis/lint_intelligence.zig");
const project_values = @import("../../../app/usecases/static_analysis/project_values.zig");
const semantic_index = @import("../../../app/usecases/static_analysis/semantic_index.zig");
const workspace_scans = @import("../../../app/usecases/static_analysis/workspace_scans.zig");
const mcp_errors = @import("../errors.zig");
const mcp_result = @import("../result.zig");

// Adapter support helpers extracted to static_analysis_support.zig.
const sa_support = @import("static_analysis_support.zig");
const Contract = sa_support.Contract;
const argBool = sa_support.argBool;
const argHas = sa_support.argHas;
const argInt = sa_support.argInt;
const argInteger = sa_support.argInteger;
const argString = sa_support.argString;
const contractFor = sa_support.contractFor;
const crossCheckValue = sa_support.crossCheckValue;
const evidenceBasisValue = sa_support.evidenceBasisValue;
const finishArg = sa_support.finishArg;
const objectString = sa_support.objectString;
const ownedString = sa_support.ownedString;
const putMetadata = sa_support.putMetadata;
const semanticCacheStatusValue = sa_support.semanticCacheStatusValue;
const semanticErrorCategory = sa_support.semanticErrorCategory;
const semanticErrorCode = sa_support.semanticErrorCode;
const semanticErrorResolution = sa_support.semanticErrorResolution;
const semanticErrorRetryable = sa_support.semanticErrorRetryable;
const signatureInteger = sa_support.signatureInteger;
const splitArgs = sa_support.splitArgs;
const stringArrayValue = sa_support.stringArrayValue;
const timeoutMs = sa_support.timeoutMs;
const validateFindingsArgument = sa_support.validateFindingsArgument;
const wantsJson = sa_support.wantsJson;

/// Handles MCP `zig_import_graph` requests by delegating to app logic and shaping owned results/errors.
pub fn zigImportGraph(
    allocator: std.mem.Allocator,
    context: app_context.StaticAnalysisContext,
    args: ?std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    // Keep this logic centralized so callers observe one consistent behavior path.
    var graph = workspace_scans.importGraph(allocator, context, .{ .limit = argInt(args, "limit") orelse workspace_scans.default_scan_limit }) catch |err| return staticToolError(allocator, "zig_import_graph", "scan_import_graph", "scan_workspace", err);
    defer graph.deinit(allocator);
    if (wantsJson(args)) {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        return staticStructuredValue(allocator, arena.allocator(), "zig_import_graph", try importGraphJsonValue(arena.allocator(), graph));
    }
    const output = workspace_scans.importGraphText(allocator, graph) catch return error.OutOfMemory;
    defer allocator.free(output);
    return staticTextResult(allocator, "zig_import_graph", output);
}

/// Handles MCP `zig_import_cycles` requests by post-processing the import graph into SCCs.
pub fn zigImportCycles(
    allocator: std.mem.Allocator,
    context: app_context.StaticAnalysisContext,
    args: ?std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    // Keep this logic centralized so callers observe one consistent behavior path.
    return staticValueResult(allocator, context, "zig_import_cycles", agent_ergonomics.importCyclesValue(allocator, context, .{
        .limit = argInt(args, "limit") orelse agent_ergonomics.default_limit,
    }));
}

/// Handles MCP `zig_build_graph` requests by delegating to app logic and shaping owned results/errors.
pub fn zigBuildGraph(
    allocator: std.mem.Allocator,
    context: app_context.StaticAnalysisContext,
    _: ?std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    return staticValueResult(allocator, context, "zig_build_graph", project_values.buildWorkspaceValue(allocator, context));
}

/// Handles MCP `zig_build_targets` requests by delegating to app logic and shaping owned results/errors.
pub fn zigBuildTargets(
    allocator: std.mem.Allocator,
    context: app_context.StaticAnalysisContext,
    _: ?std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    return staticValueResult(allocator, context, "zig_build_targets", project_values.buildTargetsValue(allocator, context));
}

/// Handles MCP `zig_build_options` requests by delegating to app logic and shaping owned results/errors.
pub fn zigBuildOptions(
    allocator: std.mem.Allocator,
    context: app_context.StaticAnalysisContext,
    _: ?std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    return staticValueResult(allocator, context, "zig_build_options", project_values.buildOptionsValue(allocator, context));
}

/// Handles MCP `zig_file_owner` requests by delegating to app logic and shaping owned results/errors.
pub fn zigFileOwner(
    allocator: std.mem.Allocator,
    context: app_context.StaticAnalysisContext,
    args: ?std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    // Keep this logic centralized so callers observe one consistent behavior path.
    const file = argString(args, "file") orelse return mcp_errors.missingArgument(allocator, "zig_file_owner", "file", "workspace-relative Zig file path");
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const value = project_values.fileOwnerForPathValue(scratch, context, file) catch |err| return staticPathError(allocator, context, "zig_file_owner", file, err);
    return staticStructuredValue(allocator, scratch, "zig_file_owner", value);
}

/// Handles MCP `zig_import_resolve` requests by delegating to app logic and shaping owned results/errors.
pub fn zigImportResolve(
    allocator: std.mem.Allocator,
    context: app_context.StaticAnalysisContext,
    args: ?std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    // Keep this logic centralized so callers observe one consistent behavior path.
    const import_name = argString(args, "import") orelse return mcp_errors.missingArgument(allocator, "zig_import_resolve", "import", "Zig import name");
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const graph = project_values.buildWorkspaceValue(scratch, context) catch |err| return staticToolError(allocator, "zig_import_resolve", "build_workspace_graph", "workspace_read", err);
    const value = project_values.importResolveValue(scratch, context, graph, import_name, argString(args, "from")) catch return error.OutOfMemory;
    return staticStructuredValue(allocator, scratch, "zig_import_resolve", value);
}

/// Handles MCP `zig_test_discover` requests by delegating to app logic and shaping owned results/errors.
pub fn zigTestDiscover(
    allocator: std.mem.Allocator,
    context: app_context.StaticAnalysisContext,
    args: ?std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    // Keep this logic centralized so callers observe one consistent behavior path.
    var tests = workspace_scans.testDiscover(allocator, context, .{ .limit = argInt(args, "limit") orelse 500 }) catch |err| return staticToolError(allocator, "zig_test_discover", "scan_test_declarations", "scan_workspace", err);
    defer tests.deinit(allocator);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    return staticStructuredValue(allocator, arena.allocator(), "zig_test_discover", try testDiscoverJsonValue(arena.allocator(), tests));
}

/// Handles MCP `zig_test_name_resolve` requests by resolving filters to actual test declarations.
pub fn zigTestNameResolve(
    allocator: std.mem.Allocator,
    context: app_context.StaticAnalysisContext,
    args: ?std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    // Keep this logic centralized so callers observe one consistent behavior path.
    return staticValueResult(allocator, context, "zig_test_name_resolve", agent_ergonomics.testNameResolveValue(allocator, context, .{
        .filters = argString(args, "filters") orelse argString(args, "filter"),
        .limit = argInt(args, "limit") orelse 500,
    }));
}

/// Handles MCP `zig_test_fixture_inventory` requests.
pub fn zigTestFixtureInventory(
    allocator: std.mem.Allocator,
    context: app_context.StaticAnalysisContext,
    args: ?std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    // Keep this logic centralized so callers observe one consistent behavior path.
    return staticValueResult(allocator, context, "zig_test_fixture_inventory", agent_ergonomics.testFixtureInventoryValue(allocator, context, .{
        .path = argString(args, "path"),
        .limit = argInt(args, "limit") orelse agent_ergonomics.default_limit,
    }));
}

/// Handles MCP `zig_safety_site_catalog` requests.
pub fn zigSafetySiteCatalog(
    allocator: std.mem.Allocator,
    context: app_context.StaticAnalysisContext,
    args: ?std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    // Keep this logic centralized so callers observe one consistent behavior path.
    return staticValueResult(allocator, context, "zig_safety_site_catalog", agent_ergonomics.safetySiteCatalogValue(allocator, context, .{
        .path = argString(args, "path"),
        .limit = argInt(args, "limit") orelse agent_ergonomics.default_limit,
    }));
}

/// Handles MCP `zig_test_for_symbol` requests.
pub fn zigTestForSymbol(
    allocator: std.mem.Allocator,
    context: app_context.StaticAnalysisContext,
    args: ?std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    // Keep this logic centralized so callers observe one consistent behavior path.
    const symbol = argString(args, "symbol") orelse return mcp_errors.missingArgument(allocator, "zig_test_for_symbol", "symbol", "symbol name");
    return staticValueResult(allocator, context, "zig_test_for_symbol", agent_ergonomics.testForSymbolValue(allocator, context, .{
        .symbol = symbol,
        .limit = argInt(args, "limit") orelse agent_ergonomics.default_limit,
    }));
}

/// Handles MCP `zig_module_surface` requests.
pub fn zigModuleSurface(
    allocator: std.mem.Allocator,
    context: app_context.StaticAnalysisContext,
    args: ?std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    // Keep this logic centralized so callers observe one consistent behavior path.
    return staticValueResult(allocator, context, "zig_module_surface", agent_ergonomics.moduleSurfaceValue(allocator, context, .{
        .path = argString(args, "path"),
        .limit = argInt(args, "limit") orelse agent_ergonomics.default_limit,
    }));
}

/// Handles MCP `zig_symbol_dossier` requests.
pub fn zigSymbolDossier(
    allocator: std.mem.Allocator,
    context: app_context.StaticAnalysisContext,
    args: ?std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    // Keep this logic centralized so callers observe one consistent behavior path.
    const symbol = argString(args, "symbol") orelse return mcp_errors.missingArgument(allocator, "zig_symbol_dossier", "symbol", "symbol name");
    return staticValueResult(allocator, context, "zig_symbol_dossier", agent_ergonomics.symbolDossierValue(allocator, context, .{
        .symbol = symbol,
        .limit = argInt(args, "limit") orelse agent_ergonomics.default_limit,
    }));
}

/// Handles MCP `zig_change_risk_audit` requests.
pub fn zigChangeRiskAudit(
    allocator: std.mem.Allocator,
    context: app_context.StaticAnalysisContext,
    args: ?std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    // Keep this logic centralized so callers observe one consistent behavior path.
    return staticValueResult(allocator, context, "zig_change_risk_audit", agent_ergonomics.changeRiskAuditValue(allocator, context, .{
        .files = argString(args, "files"),
        .symbols = argString(args, "symbols"),
        .diff = argString(args, "diff"),
        .limit = argInt(args, "limit") orelse agent_ergonomics.default_limit,
    }));
}

/// Handles MCP `zig_insertion_sites` requests.
pub fn zigInsertionSites(
    allocator: std.mem.Allocator,
    context: app_context.StaticAnalysisContext,
    args: ?std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    // Keep this logic centralized so callers observe one consistent behavior path.
    const topic = argString(args, "topic") orelse argString(args, "query") orelse return mcp_errors.missingArgument(allocator, "zig_insertion_sites", "topic", "topic or feature name");
    return staticValueResult(allocator, context, "zig_insertion_sites", agent_ergonomics.insertionSitesValue(allocator, context, .{
        .topic = topic,
        .path = argString(args, "path"),
        .limit = argInt(args, "limit") orelse 20,
    }));
}

/// Handles MCP `zig_io_migration_scan` requests.
pub fn zigIoMigrationScan(
    allocator: std.mem.Allocator,
    context: app_context.StaticAnalysisContext,
    args: ?std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    // Keep this logic centralized so callers observe one consistent behavior path.
    return staticValueResult(allocator, context, "zig_io_migration_scan", developer_pain.ioMigrationScanValue(allocator, context, .{
        .path = argString(args, "path"),
        .limit = argInt(args, "limit") orelse developer_pain.default_limit,
    }));
}

/// Handles MCP `zig_leak_triage` requests.
pub fn zigLeakTriage(
    allocator: std.mem.Allocator,
    context: app_context.StaticAnalysisContext,
    args: ?std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    // Keep this logic centralized so callers observe one consistent behavior path.
    return staticValueResult(allocator, context, "zig_leak_triage", developer_pain.leakTriageValue(allocator, context, .{
        .text = argString(args, "text"),
        .path = argString(args, "path"),
        .limit = argInt(args, "limit") orelse developer_pain.default_limit,
    }));
}

/// Handles MCP `zig_comptime_diagnose` requests.
pub fn zigComptimeDiagnose(
    allocator: std.mem.Allocator,
    context: app_context.StaticAnalysisContext,
    args: ?std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    // Keep this logic centralized so callers observe one consistent behavior path.
    return staticValueResult(allocator, context, "zig_comptime_diagnose", developer_pain.comptimeDiagnoseValue(allocator, context, .{
        .text = argString(args, "text"),
        .path = argString(args, "path"),
        .diagnostic = argString(args, "diagnostic"),
        .limit = argInt(args, "limit") orelse developer_pain.default_limit,
    }));
}

/// Handles MCP `zig_memory_layout` requests.
pub fn zigMemoryLayout(
    allocator: std.mem.Allocator,
    context: app_context.StaticAnalysisContext,
    args: ?std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    // Keep this logic centralized so callers observe one consistent behavior path.
    return staticValueResult(allocator, context, "zig_memory_layout", developer_pain.memoryLayoutValue(allocator, context, .{
        .path = argString(args, "path"),
        .limit = argInt(args, "limit") orelse developer_pain.default_limit,
        .measure = argBool(args, "measure", false),
        .targets = argString(args, "targets"),
        .allow_project_comptime = argBool(args, "allow_project_comptime", false),
        .timeout_ms = timeoutMs(context, args),
    }));
}

/// Handles MCP `zig_unsafe_operations_audit` requests.
pub fn zigUnsafeOperationsAudit(
    allocator: std.mem.Allocator,
    context: app_context.StaticAnalysisContext,
    args: ?std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    // Keep this logic centralized so callers observe one consistent behavior path.
    return staticValueResult(allocator, context, "zig_unsafe_operations_audit", developer_pain.unsafeOperationsAuditValue(allocator, context, .{
        .path = argString(args, "path"),
        .limit = argInt(args, "limit") orelse developer_pain.default_limit,
    }));
}

/// Handles MCP `zig_abi_layout_diff` requests.
pub fn zigAbiLayoutDiff(
    allocator: std.mem.Allocator,
    context: app_context.StaticAnalysisContext,
    args: ?std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    // Keep this logic centralized so callers observe one consistent behavior path.
    return staticValueResult(allocator, context, "zig_abi_layout_diff", developer_pain.abiLayoutDiffValue(allocator, context, .{
        .path = argString(args, "path"),
        .limit = argInt(args, "limit") orelse developer_pain.default_limit,
        .measure = argBool(args, "measure", false),
        .targets = argString(args, "targets"),
        .allow_project_comptime = argBool(args, "allow_project_comptime", false),
        .timeout_ms = timeoutMs(context, args),
    }));
}

/// Handles MCP `zig_changed_files_plan` requests by delegating to app logic and shaping owned results/errors.
pub fn zigChangedFilesPlan(
    allocator: std.mem.Allocator,
    context: app_context.StaticAnalysisContext,
    args: ?std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    return staticValueResult(allocator, context, "zig_changed_files_plan", project_values.changedFilesPlanValue(allocator, context, timeoutMs(context, args)));
}

/// Handles MCP `zig_dependency_inspect` requests by delegating to app logic and shaping owned results/errors.
pub fn zigDependencyInspect(
    allocator: std.mem.Allocator,
    context: app_context.StaticAnalysisContext,
    _: ?std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    // Keep this logic centralized so callers observe one consistent behavior path.
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const value = project_values.dependencyInspectionFromWorkspaceValue(scratch, context) catch |err| return staticToolError(allocator, "zig_dependency_inspect", "inspect_dependencies", "static_analysis", err);
    return staticStructuredValue(allocator, scratch, "zig_dependency_inspect", value);
}

/// Handles MCP `zig_target_matrix_plan` requests by delegating to app logic and shaping owned results/errors.
pub fn zigTargetMatrixPlan(
    allocator: std.mem.Allocator,
    _: app_context.StaticAnalysisContext,
    args: ?std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    // Keep this logic centralized so callers observe one consistent behavior path.
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const value = project_values.targetMatrixPlanValue(scratch, argString(args, "targets") orelse "native x86_64-linux-gnu x86_64-macos-none aarch64-macos-none x86_64-windows-gnu wasm32-freestanding", argString(args, "steps") orelse "build test") catch return error.OutOfMemory;
    return staticStructuredValue(allocator, scratch, "zig_target_matrix_plan", value);
}

/// Handles MCP `zig_test_failure_triage` requests by delegating to app logic and shaping owned results/errors.
pub fn zigTestFailureTriage(
    allocator: std.mem.Allocator,
    context: app_context.StaticAnalysisContext,
    args: ?std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    // Keep this logic centralized so callers observe one consistent behavior path.
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

/// Handles MCP `zig_workspace_symbol_cache` requests by delegating to app logic and shaping owned results/errors.
pub fn zigWorkspaceSymbolCache(
    allocator: std.mem.Allocator,
    context: app_context.StaticAnalysisContext,
    args: ?std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    return staticValueResult(allocator, context, "zig_workspace_symbol_cache", project_values.workspaceSymbolCacheValue(allocator, context, argString(args, "query"), argInt(args, "limit") orelse 500));
}

/// Handles MCP `zig_package_cache_doctor` requests by delegating to app logic and shaping owned results/errors.
pub fn zigPackageCacheDoctor(
    allocator: std.mem.Allocator,
    context: app_context.StaticAnalysisContext,
    args: ?std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    return staticValueResult(allocator, context, "zig_package_cache_doctor", project_values.packageCacheDoctorValue(allocator, context, timeoutMs(context, args)));
}

/// Handles MCP `zig_test_map` requests by delegating to app logic and shaping owned results/errors.
pub fn zigTestMap(
    allocator: std.mem.Allocator,
    context: app_context.StaticAnalysisContext,
    args: ?std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    return staticValueResult(allocator, context, "zig_test_map", project_values.testMapValue(allocator, context, argInt(args, "limit") orelse 500));
}

/// Handles MCP `zig_test_select` requests by delegating to app logic and shaping owned results/errors.
pub fn zigTestSelect(
    allocator: std.mem.Allocator,
    context: app_context.StaticAnalysisContext,
    args: ?std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    return staticValueResult(allocator, context, "zig_test_select", project_values.testSelectValue(allocator, context, argString(args, "files"), argString(args, "symbols"), argInt(args, "limit") orelse 500));
}

/// Handles MCP `zig_public_api_diff` requests by delegating to app logic and shaping owned results/errors.
pub fn zigPublicApiDiff(
    allocator: std.mem.Allocator,
    context: app_context.StaticAnalysisContext,
    args: ?std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    // Keep this logic centralized so callers observe one consistent behavior path.
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

/// Handles MCP `zig_zlint` requests by delegating to app logic and shaping owned results/errors.
pub fn zigZlint(
    allocator: std.mem.Allocator,
    context: app_context.StaticAnalysisContext,
    args: ?std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    return zlintDiagnosticsResult(allocator, context, args, "zig_zlint", false);
}

/// Handles MCP `zig_zlint_sarif` requests by delegating to app logic and shaping owned results/errors.
pub fn zigZlintSarif(
    allocator: std.mem.Allocator,
    context: app_context.StaticAnalysisContext,
    args: ?std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    return zlintDiagnosticsResult(allocator, context, args, "zig_zlint_sarif", true);
}

/// Handles MCP `zig_zlint_rules` requests by delegating to app logic and shaping owned results/errors.
pub fn zigZlintRules(
    allocator: std.mem.Allocator,
    context: app_context.StaticAnalysisContext,
    args: ?std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    // Keep this logic centralized so callers observe one consistent behavior path.
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const value = lint_intelligence.runZlintRules(scratch, context, .{
        .timeout_ms = timeoutMs(context, args),
    }) catch |err| return lintToolError(allocator, context, "zig_zlint_rules", ".", "run_zlint_rules", "run_backend", err);
    return structuredLintValue(allocator, scratch, "zig_zlint_rules", value);
}

/// Handles MCP `zig_zlint_fix` requests by delegating to app logic and shaping owned results/errors.
pub fn zigZlintFix(
    allocator: std.mem.Allocator,
    context: app_context.StaticAnalysisContext,
    args: ?std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    // Keep this logic centralized so callers observe one consistent behavior path.
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

/// Handles MCP `zig_lint_compare` requests by delegating to app logic and shaping owned results/errors.
pub fn zigLintCompare(
    allocator: std.mem.Allocator,
    _: app_context.StaticAnalysisContext,
    args: ?std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    // Keep this logic centralized so callers observe one consistent behavior path.
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const zlint = lint_intelligence.normalizeFindingsText(scratch, argString(args, "zlint_findings") orelse "[]", .zlint) catch return mcp_errors.missingArgument(allocator, "zig_lint_compare", "zlint_findings", "valid JSON findings");
    const zwanzig = lint_intelligence.normalizeFindingsText(scratch, argString(args, "zwanzig_findings") orelse "[]", .zwanzig) catch return mcp_errors.missingArgument(allocator, "zig_lint_compare", "zwanzig_findings", "valid JSON findings");
    const value = try lint_intelligence.lintCompareValue(scratch, zlint.array, zwanzig.array);
    return structuredLintValue(allocator, scratch, "zig_lint_compare", value);
}

/// Handles MCP `zig_lint_profile` requests by delegating to app logic and shaping owned results/errors.
pub fn zigLintProfile(
    allocator: std.mem.Allocator,
    _: app_context.StaticAnalysisContext,
    args: ?std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    // Keep this logic centralized so callers observe one consistent behavior path.
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const value = try lint_intelligence.lintProfileValue(scratch, argString(args, "profile") orelse "standard");
    return structuredLintValue(allocator, scratch, "zig_lint_profile", value);
}

/// Handles MCP `zig_lint_gate` requests by delegating to app logic and shaping owned results/errors.
pub fn zigLintGate(
    allocator: std.mem.Allocator,
    _: app_context.StaticAnalysisContext,
    args: ?std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    // Keep this logic centralized so callers observe one consistent behavior path.
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

/// Handles MCP `zig_lint_fix_plan` requests by delegating to app logic and shaping owned results/errors.
pub fn zigLintFixPlan(
    allocator: std.mem.Allocator,
    _: app_context.StaticAnalysisContext,
    args: ?std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    // Keep this logic centralized so callers observe one consistent behavior path.
    const text = argString(args, "findings") orelse return mcp_errors.missingArgument(allocator, "zig_lint_fix_plan", "findings", "valid JSON findings");
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const findings = lint_intelligence.normalizeFindingsText(scratch, text, .zlint) catch return mcp_errors.missingArgument(allocator, "zig_lint_fix_plan", "findings", "valid JSON findings");
    const value = try lint_intelligence.fixPlanValue(scratch, findings.array);
    return structuredLintValue(allocator, scratch, "zig_lint_fix_plan", value);
}

/// Handles MCP `zig_lint_baseline` requests by delegating to app logic and shaping owned results/errors.
pub fn zigLintBaseline(
    allocator: std.mem.Allocator,
    context: app_context.StaticAnalysisContext,
    args: ?std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    // Keep this logic centralized so callers observe one consistent behavior path.
    const text = argString(args, "findings") orelse return mcp_errors.missingArgument(allocator, "zig_lint_baseline", "findings", "valid JSON findings");
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const findings = lint_intelligence.normalizeFindingsText(scratch, text, .zlint) catch return mcp_errors.missingArgument(allocator, "zig_lint_baseline", "findings", "valid JSON findings");
    const baseline = lint_intelligence.normalizeFindingsText(scratch, argString(args, "baseline") orelse "[]", .zlint) catch std.json.Value{ .array = std.json.Array.init(scratch) };
    const output = argString(args, "output") orelse ".zigars-cache/lint-baseline.json";
    const value = lint_intelligence.lintBaseline(scratch, context, findings.array, baseline.array, argBool(args, "apply", false), output) catch |err| return lintToolError(allocator, context, "zig_lint_baseline", output, "write_lint_baseline", "workspace_store", err);
    return structuredLintValue(allocator, scratch, "zig_lint_baseline", value);
}

/// Handles MCP `zig_lint_suppressions` requests by delegating to app logic and shaping owned results/errors.
pub fn zigLintSuppressions(
    allocator: std.mem.Allocator,
    _: app_context.StaticAnalysisContext,
    args: ?std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    // Keep this logic centralized so callers observe one consistent behavior path.
    const text = argString(args, "findings") orelse return mcp_errors.missingArgument(allocator, "zig_lint_suppressions", "findings", "valid JSON findings");
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const findings = lint_intelligence.normalizeFindingsText(scratch, text, .zlint) catch return mcp_errors.missingArgument(allocator, "zig_lint_suppressions", "findings", "valid JSON findings");
    const value = try lint_intelligence.suppressionsValue(scratch, findings.array, argString(args, "suppressions") orelse "[]");
    return structuredLintValue(allocator, scratch, "zig_lint_suppressions", value);
}

/// Handles MCP `zig_lint_trend` requests by delegating to app logic and shaping owned results/errors.
pub fn zigLintTrend(
    allocator: std.mem.Allocator,
    _: app_context.StaticAnalysisContext,
    args: ?std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    // Keep this logic centralized so callers observe one consistent behavior path.
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

/// Handles MCP `zig_lint` requests by delegating to app logic and shaping owned results/errors.
pub fn zigLint(
    allocator: std.mem.Allocator,
    context: app_context.StaticAnalysisContext,
    args: ?std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    return zwanzigLintResult(allocator, context, args, .json, "zig_lint");
}

/// Handles MCP `zig_lint_sarif` requests by delegating to app logic and shaping owned results/errors.
pub fn zigLintSarif(
    allocator: std.mem.Allocator,
    context: app_context.StaticAnalysisContext,
    args: ?std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    return zwanzigLintResult(allocator, context, args, .sarif, "zig_lint_sarif");
}

/// Handles MCP `zig_lint_rules` requests by delegating to app logic and shaping owned results/errors.
pub fn zigLintRules(
    allocator: std.mem.Allocator,
    context: app_context.StaticAnalysisContext,
    args: ?std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    // Keep this logic centralized so callers observe one consistent behavior path.
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const value = lint_intelligence.runZwanzigRules(scratch, context, timeoutMs(context, args)) catch |err| return lintToolError(allocator, context, "zig_lint_rules", ".", "run_zwanzig_rules", "run_backend", err);
    return structuredZwanzigValue(allocator, scratch, "zig_lint_rules", value);
}

/// Handles MCP `zig_analysis_graphs` requests by delegating to app logic and shaping owned results/errors.
pub fn zigAnalysisGraphs(
    allocator: std.mem.Allocator,
    context: app_context.StaticAnalysisContext,
    args: ?std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    // Keep this logic centralized so callers observe one consistent behavior path.
    const mode_raw = argString(args, "mode") orelse return mcp_errors.missingArgument(allocator, "zig_analysis_graphs", "mode", backend_contracts.supportedZwanzigGraphModesText());
    const mode = backend_contracts.parseZwanzigGraphMode(mode_raw) orelse return mcp_errors.invalidArgument(
        allocator,
        "zig_analysis_graphs",
        "mode",
        backend_contracts.supportedZwanzigGraphModesText(),
        mode_raw,
        "Choose one of the graph modes published in tools/list; raw zwanzig graph flags are not accepted as public zigars API.",
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

/// Handles MCP `zig_semantic_index_build` requests by delegating to app logic and shaping owned results/errors.
pub fn zigSemanticIndexBuild(
    allocator: std.mem.Allocator,
    context: app_context.StaticAnalysisContext,
    args: ?std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    return semanticIndexResult(allocator, context, args, "zig_semantic_index_build", argBool(args, "refresh", false));
}

/// Handles MCP `zig_semantic_index_refresh` requests by delegating to app logic and shaping owned results/errors.
pub fn zigSemanticIndexRefresh(
    allocator: std.mem.Allocator,
    context: app_context.StaticAnalysisContext,
    args: ?std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    return semanticIndexResult(allocator, context, args, "zig_semantic_index_refresh", true);
}

/// Handles MCP `zig_semantic_index_status` requests by delegating to app logic and shaping owned results/errors.
pub fn zigSemanticIndexStatus(
    allocator: std.mem.Allocator,
    context: app_context.StaticAnalysisContext,
    _: ?std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    // Keep this logic centralized so callers observe one consistent behavior path.
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

/// Handles MCP `zig_semantic_query` requests by delegating to app logic and shaping owned results/errors.
pub fn zigSemanticQuery(
    allocator: std.mem.Allocator,
    context: app_context.StaticAnalysisContext,
    args: ?std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    // Keep this logic centralized so callers observe one consistent behavior path.
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

/// Handles MCP `zig_semantic_decl` requests by delegating to app logic and shaping owned results/errors.
pub fn zigSemanticDecl(
    allocator: std.mem.Allocator,
    context: app_context.StaticAnalysisContext,
    args: ?std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    // Keep this logic centralized so callers observe one consistent behavior path.
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

/// Handles MCP `zig_semantic_refs` requests by delegating to app logic and shaping owned results/errors.
pub fn zigSemanticRefs(
    allocator: std.mem.Allocator,
    context: app_context.StaticAnalysisContext,
    args: ?std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    const symbol = argString(args, "symbol") orelse return mcp_errors.missingArgument(allocator, "zig_semantic_refs", "symbol", "symbol name");
    return sourceRefsResult(allocator, context, args, "zig_semantic_refs", symbol, false);
}

/// Handles MCP `zig_semantic_callers` requests by delegating to app logic and shaping owned results/errors.
pub fn zigSemanticCallers(
    allocator: std.mem.Allocator,
    context: app_context.StaticAnalysisContext,
    args: ?std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    const symbol = argString(args, "symbol") orelse return mcp_errors.missingArgument(allocator, "zig_semantic_callers", "symbol", "function name");
    return sourceRefsResult(allocator, context, args, "zig_semantic_callers", symbol, true);
}

/// Handles MCP `zig_static_fusion` requests by delegating to app logic and shaping owned results/errors.
pub fn zigStaticFusion(
    allocator: std.mem.Allocator,
    context: app_context.StaticAnalysisContext,
    args: ?std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    const query_text = argString(args, "query") orelse return mcp_errors.missingArgument(allocator, "zig_static_fusion", "query", "symbol or lint subject");
    // Reject malformed optional findings up front so fusion never runs against
    // half-parsed evidence; a present-but-valid value falls through unchanged.
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

/// Handles MCP `zig_code_index_export` requests by delegating to app logic and shaping owned results/errors.
pub fn zigCodeIndexExport(
    allocator: std.mem.Allocator,
    context: app_context.StaticAnalysisContext,
    args: ?std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    return exportIndexResult(allocator, context, args, "zig_code_index_export", "zigars.code_index", ".zigars-cache/code-index.json");
}

/// Handles MCP `zig_scip_export` requests by delegating to app logic and shaping owned results/errors.
pub fn zigScipExport(
    allocator: std.mem.Allocator,
    context: app_context.StaticAnalysisContext,
    args: ?std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    return exportIndexResult(allocator, context, args, "zig_scip_export", "scip-like-json", ".zigars-cache/code-index.scip.json");
}

/// Returns the MCP tool result for semantic index.
fn semanticIndexResult(
    allocator: std.mem.Allocator,
    context: app_context.StaticAnalysisContext,
    args: ?std.json.Value,
    tool_name: []const u8,
    force_refresh: bool,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    // Keep this logic centralized so callers observe one consistent behavior path.
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

/// Finishes a use case that already produced a JSON value (or error): on success
/// it stamps contract metadata and wraps it; on error it maps to a structured
/// static tool error. `context` is accepted only to keep one call shape across
/// handlers and is intentionally unused here.
fn staticValueResult(
    allocator: std.mem.Allocator,
    context: app_context.StaticAnalysisContext,
    tool_name: []const u8,
    result: anyerror!std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    // Keep this logic centralized so callers observe one consistent behavior path.
    _ = context;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const value = result catch |err| return staticToolError(allocator, tool_name, "run_static_analysis", "static_analysis", err);
    return staticStructuredValue(allocator, scratch, tool_name, value);
}

/// Returns an allocator-owned JSON value for static structured.
fn staticStructuredValue(
    allocator: std.mem.Allocator,
    scratch: std.mem.Allocator,
    tool_name: []const u8,
    value: std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    // Keep this logic centralized so callers observe one consistent behavior path.
    var mutable = value;
    switch (mutable) {
        .object => |*obj| try putMetadata(scratch, obj, tool_name),
        else => {},
    }
    return mcp_result.structured(allocator, mutable);
}

/// Returns the MCP tool result for static text.
fn staticTextResult(allocator: std.mem.Allocator, tool_name: []const u8, body: []const u8) mcp.tools.ToolError!mcp.tools.ToolResult {
    // Keep this logic centralized so callers observe one consistent behavior path.
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    var obj = std.json.ObjectMap.empty;
    try obj.put(scratch, "kind", .{ .string = tool_name });
    try putMetadata(scratch, &obj, tool_name);
    try obj.put(scratch, "text", .{ .string = body });
    return mcp_result.structured(allocator, .{ .object = obj });
}

/// Returns an allocator-owned JSON value for import graph JSON.
fn importGraphJsonValue(allocator: std.mem.Allocator, graph: workspace_scans.ImportGraphResult) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
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

/// Returns an allocator-owned JSON value for test discovery JSON.
fn testDiscoverJsonValue(allocator: std.mem.Allocator, result: workspace_scans.TestDiscoverResult) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
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

/// Maps static tool error failures to structured MCP errors.
fn staticToolError(
    allocator: std.mem.Allocator,
    tool_name: []const u8,
    operation: []const u8,
    phase: []const u8,
    err: anyerror,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    // Preserve a single error-shaping path so callers receive consistent metadata.
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

/// Maps static path error failures to structured MCP errors.
fn staticPathError(
    allocator: std.mem.Allocator,
    context: app_context.StaticAnalysisContext,
    tool_name: []const u8,
    path: []const u8,
    err: anyerror,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    // Preserve a single error-shaping path so callers receive consistent metadata.
    return switch (err) {
        error.PathOutsideWorkspace, error.EmptyPath => mcp_errors.workspacePath(allocator, tool_name, path, context.workspace.root, err),
        else => staticToolError(allocator, tool_name, "resolve_workspace_path", "workspace_path", err),
    };
}

/// Maps static error code failures to structured MCP errors.
fn staticErrorCode(err: anyerror) []const u8 {
    // Keep this logic centralized so callers observe one consistent behavior path.
    return switch (err) {
        error.MissingCommandRunner => "missing_command_runner",
        error.PathOutsideWorkspace, error.EmptyPath => "workspace_path",
        error.FileNotFound, error.NotFound => "file_not_found",
        error.Timeout, error.RequestTimeout => "timeout",
        error.OutputLimitExceeded, error.StreamTooLong => "output_limit",
        else => "static_analysis_failed",
    };
}

/// Maps static error category failures to structured MCP errors.
fn staticErrorCategory(err: anyerror) []const u8 {
    // Keep this logic centralized so callers observe one consistent behavior path.
    return switch (err) {
        error.MissingCommandRunner => "configuration",
        error.PathOutsideWorkspace, error.EmptyPath => "workspace_path",
        error.FileNotFound, error.NotFound => "filesystem",
        error.Timeout, error.RequestTimeout => "timeout",
        error.OutputLimitExceeded, error.StreamTooLong => "output_limit",
        else => "static_analysis",
    };
}

/// Maps static error retryable failures to structured MCP errors.
fn staticErrorRetryable(err: anyerror) bool {
    return switch (err) {
        error.Timeout, error.RequestTimeout => true,
        else => false,
    };
}

/// Maps static error resolution failures to structured MCP errors.
fn staticErrorResolution(err: anyerror) []const u8 {
    // Keep this logic centralized so callers observe one consistent behavior path.
    return switch (err) {
        error.MissingCommandRunner => "Run this tool through a runtime that supplies the command runner port.",
        error.PathOutsideWorkspace, error.EmptyPath => "Retry with a non-empty workspace-relative path inside the configured workspace.",
        error.FileNotFound, error.NotFound => "Create the expected build or source file, or call a nullable project summary tool first.",
        error.Timeout, error.RequestTimeout => "Retry with a smaller scope or a larger timeout_ms value.",
        else => "Retry with a smaller limit or inspect unreadable workspace files.",
    };
}

/// Returns the MCP tool result for source refs.
fn sourceRefsResult(
    allocator: std.mem.Allocator,
    context: app_context.StaticAnalysisContext,
    args: ?std.json.Value,
    tool_name: []const u8,
    symbol: []const u8,
    calls_only: bool,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    // Keep this logic centralized so callers observe one consistent behavior path.
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

/// Returns the MCP tool result for export index.
fn exportIndexResult(
    allocator: std.mem.Allocator,
    context: app_context.StaticAnalysisContext,
    args: ?std.json.Value,
    tool_name: []const u8,
    format: []const u8,
    default_output: []const u8,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    // Keep this logic centralized so callers observe one consistent behavior path.
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

/// Adds cache export metadata to a structured semantic-index result.
fn addExportMetadata(allocator: std.mem.Allocator, value: *std.json.Value, tool_name: []const u8) !void {
    // Keep this logic centralized so callers observe one consistent behavior path.
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

/// Returns an allocator-owned JSON value for structured semantic.
fn structuredSemanticValue(
    allocator: std.mem.Allocator,
    scratch: std.mem.Allocator,
    tool_name: []const u8,
    value: std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    // Keep this logic centralized so callers observe one consistent behavior path.
    var mutable = value;
    switch (mutable) {
        .object => |*obj| try putMetadata(scratch, obj, tool_name),
        else => {},
    }
    return mcp_result.structured(allocator, mutable);
}

/// Returns an allocator-owned JSON value for structured lint.
fn structuredLintValue(
    allocator: std.mem.Allocator,
    scratch: std.mem.Allocator,
    tool_name: []const u8,
    value: std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    // Keep this logic centralized so callers observe one consistent behavior path.
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

/// Returns an allocator-owned JSON value for structured zwanzig.
fn structuredZwanzigValue(
    allocator: std.mem.Allocator,
    scratch: std.mem.Allocator,
    tool_name: []const u8,
    value: std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    // Keep this logic centralized so callers observe one consistent behavior path.
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

/// Returns an allocator-owned JSON value for structured graph.
fn structuredGraphValue(
    allocator: std.mem.Allocator,
    scratch: std.mem.Allocator,
    value: std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    // Keep this logic centralized so callers observe one consistent behavior path.
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

/// Returns the MCP tool result for ZLint diagnostics.
fn zlintDiagnosticsResult(
    allocator: std.mem.Allocator,
    context: app_context.StaticAnalysisContext,
    args: ?std.json.Value,
    tool_name: []const u8,
    sarif: bool,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    // Keep this logic centralized so callers observe one consistent behavior path.
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

/// Returns the MCP tool result for zwanzig lint.
fn zwanzigLintResult(
    allocator: std.mem.Allocator,
    context: app_context.StaticAnalysisContext,
    args: ?std.json.Value,
    format: backend_contracts.ZwanzigLintFormat,
    tool_name: []const u8,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    // Keep this logic centralized so callers observe one consistent behavior path.
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

/// Maps semantic tool error failures to structured MCP errors.
fn semanticToolError(
    allocator: std.mem.Allocator,
    tool_name: []const u8,
    operation: []const u8,
    phase: []const u8,
    err: anyerror,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    // Preserve a single error-shaping path so callers receive consistent metadata.
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

/// Maps lint tool error failures to structured MCP errors.
fn lintToolError(
    allocator: std.mem.Allocator,
    context: app_context.StaticAnalysisContext,
    tool_name: []const u8,
    path: []const u8,
    operation: []const u8,
    phase: []const u8,
    err: anyerror,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    // Preserve a single error-shaping path so callers receive consistent metadata.
    if (err == error.OutOfMemory) return error.OutOfMemory;
    return switch (err) {
        error.PathOutsideWorkspace, error.EmptyPath => mcp_errors.workspacePath(allocator, tool_name, path, context.workspace.root, err),
        error.InvalidRequest => mcp_errors.invalidArgument(
            allocator,
            tool_name,
            "path",
            "workspace-relative path inside the configured workspace",
            path,
            "Retry with a workspace-relative path that can be resolved by the active zigars workspace.",
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

/// Maps split tool args error failures to structured MCP errors.
fn splitToolArgsError(
    allocator: std.mem.Allocator,
    tool_name: []const u8,
    field: []const u8,
    actual: []const u8,
    err: anyerror,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    // Preserve a single error-shaping path so callers receive consistent metadata.
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

/// Maps lint error code failures to structured MCP errors.
fn lintErrorCode(err: anyerror) []const u8 {
    // Keep this logic centralized so callers observe one consistent behavior path.
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

/// Maps lint error category failures to structured MCP errors.
fn lintErrorCategory(err: anyerror) []const u8 {
    // Keep this logic centralized so callers observe one consistent behavior path.
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

/// Maps lint error retryable failures to structured MCP errors.
fn lintErrorRetryable(err: anyerror) bool {
    return switch (err) {
        error.Timeout, error.RequestTimeout => true,
        else => false,
    };
}

/// Maps lint error resolution failures to structured MCP errors.
fn lintErrorResolution(err: anyerror) []const u8 {
    // Keep this logic centralized so callers observe one consistent behavior path.
    return switch (err) {
        error.MissingCommandRunner => "Run this tool through a runtime that supplies the command runner port.",
        error.PathOutsideWorkspace, error.EmptyPath => "Retry with a non-empty workspace-relative path inside the configured workspace.",
        error.InvalidRequest => "Inspect the tools/list inputSchema and retry with valid arguments.",
        error.Timeout, error.RequestTimeout => "Retry with a smaller scope or a larger timeout_ms value.",
        error.OutputLimitExceeded, error.StreamTooLong => "Retry with narrower lint output, a smaller path scope, or backend flags that reduce output.",
        else => "Inspect the configured optional backend, workspace path, and tool arguments, then retry.",
    };
}

/// Maps export error failures to structured MCP errors.
fn exportError(
    allocator: std.mem.Allocator,
    context: app_context.StaticAnalysisContext,
    tool_name: []const u8,
    output: []const u8,
    err: anyerror,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    // Preserve a single error-shaping path so callers receive consistent metadata.
    if (err == error.OutOfMemory) return error.OutOfMemory;
    return switch (err) {
        error.PathOutsideWorkspace, error.EmptyPath => mcp_errors.workspacePath(allocator, tool_name, output, context.workspace.root, err),
        else => semanticToolError(allocator, tool_name, "export_index", "export_index", err),
    };
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
    const graph_json = try zigImportGraph(allocator, context, try testArgs(arena.allocator(), "{\"limit\":1,\"output_format\":\"json\"}"));
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

/// Creates test static adapter context from the ports required by the adapter.
fn testStaticAdapterContext(
    commands: *command_runner_fake.FakeCommandRunner,
    store: *workspace_store_fake.FakeWorkspaceStore,
    scanner: *workspace_scanner_fake.FakeWorkspaceScanner,
    cache: *static_cache_fake.FakeStaticCache,
) app_context.StaticAnalysisContext {
    // Keep this logic centralized so callers observe one consistent behavior path.
    return .{
        .workspace = .{ .root = "/workspace", .cache_root = "/workspace/.zigars-cache" },
        .tool_paths = .{ .zig = "zig-test", .zlint = "zlint-test", .zwanzig = "zwanzig-test" },
        .timeouts = .{ .command_ms = 42 },
        .command_runner = commands.port(),
        .workspace_store = store.port(),
        .workspace_scanner = scanner.port(),
        .semantic_index_cache = cache.port(),
    };
}

/// Creates no runner context with cache from the ports required by the adapter.
fn no_runnerContextWithCache(context: app_context.StaticAnalysisContext) app_context.StaticAnalysisContext {
    var copy = context;
    copy.semantic_index_cache = null;
    return copy;
}

/// Parses test args from MCP JSON arguments.
fn testArgs(allocator: std.mem.Allocator, text: []const u8) !std.json.Value {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, text, .{});
    return parsed.value;
}

/// Frees argv strings allocated while splitting command arguments.
fn freeArgList(allocator: std.mem.Allocator, args: []const []const u8) void {
    for (args) |arg| allocator.free(arg);
    allocator.free(args);
}

/// Asserts result object kind in adapter tests.
fn expectResultObjectKind(result: mcp.tools.ToolResult, expected_kind: []const u8) !void {
    const structured = result.structuredContent orelse return error.MissingStructuredContent;
    try std.testing.expect(structured == .object);
    const kind = structured.object.get("kind") orelse return error.MissingKind;
    try std.testing.expect(kind == .string);
    try std.testing.expectEqualStrings(expected_kind, kind.string);
}

/// Asserts result has metadata in adapter tests.
fn expectResultHasMetadata(result: mcp.tools.ToolResult) !void {
    const structured = result.structuredContent orelse return error.MissingStructuredContent;
    try std.testing.expect(structured == .object);
    try std.testing.expect(structured.object.get("analysis_kind") != null);
    try std.testing.expect(structured.object.get("capability_tier") != null);
    try std.testing.expect(structured.object.get("confidence") != null);
}

/// Asserts build graph reads in adapter tests.
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

/// Asserts build options read in adapter tests.
fn expectBuildOptionsRead(store: *workspace_store_fake.FakeWorkspaceStore) !void {
    // Keep this logic centralized so callers observe one consistent behavior path.
    try store.expectRead(.{ .path = "build.zig", .max_bytes = project_values.default_build_read_limit, .provenance = "static_analysis.build_options" },
        \\const target = b.standardTargetOptions(.{});
        \\const optimize = b.standardOptimizeOption(.{});
        \\const feature = b.option(bool, "feature", "Enable feature") orelse false;
        \\_ = target;
        \\_ = optimize;
        \\_ = feature;
    );
}

/// Asserts dependency inspect in adapter tests.
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
