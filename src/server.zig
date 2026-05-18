const std = @import("std");
const mcp = @import("mcp");
const zigar = @import("zigar");

const runtime_mod = zigar.runtime;
const tool_metadata = zigar.tool_metadata;
const tool_registry = zigar.tool_registry;

const discovery = @import("tools/discovery.zig");
const agent = @import("tools/agent.zig");
const core = @import("tools/core.zig");
const edit_zls = @import("tools/edit_zls.zig");
const docs = @import("tools/docs.zig");
const static_analysis = @import("tools/static_analysis.zig");
const ci = @import("tools/ci.zig");
const zwanzig = @import("tools/zwanzig.zig");
const profiling = @import("tools/profiling.zig");
const resources = @import("tools/resources.zig");

const App = runtime_mod.App;
const ToolHandler = tool_registry.ToolHandler;

pub fn registerTools(server: *mcp.Server, runtime: *App) !void {
    inline for (tool_metadata.specs) |spec| {
        try tool_registry.addTool(server, runtime.allocator, runtime, spec, handlerFor(spec.id));
    }
}

fn handlerFor(comptime id: tool_metadata.ToolId) ToolHandler {
    return switch (id) {
        .zigar_capabilities,
        .zigar_tool_index,
        .zigar_schema,
        .zigar_doctor,
        .zigar_workspace_info,
        .zigar_metrics,
        .zigar_http_status,
        .zig_command_plan,
        .zig_toolchain_resolve,
        => discoveryHandlerFor(id),

        .zigar_context_pack,
        .zigar_next_action,
        .zigar_agent_guide,
        .zigar_validate_patch,
        .zigar_failure_fusion,
        .zigar_impact,
        .zigar_project_profile,
        .zigar_patch_guard,
        => agentWorkflowHandlerFor(id),

        .zig_version,
        .zig_env,
        .zig_targets,
        .zig_build,
        .zig_test,
        .zig_check,
        .zig_compile_error_index,
        .zig_explain_errors,
        .zig_translate_c,
        => coreZigHandlerFor(id),

        .zig_format,
        .zig_format_check,
        .zig_patch_preview,
        .zig_rename,
        .zig_code_actions,
        .zig_code_action_apply,
        => editHandlerFor(id),

        .zig_document_open,
        .zig_document_change,
        .zig_document_close,
        .zig_document_status,
        .zig_diagnostics,
        .zig_diagnostics_all,
        .zig_diagnostics_workspace,
        .zig_hover,
        .zig_definition,
        .zig_references,
        .zig_completion,
        .zig_signature_help,
        .zig_document_symbols,
        .zig_workspace_symbols,
        => zlsHandlerFor(id),

        .zig_builtin_list,
        .zig_builtin_list_json,
        .zig_builtin_doc,
        .zig_std_search,
        .zig_std_search_json,
        .zig_std_item,
        .zig_lang_ref_search,
        => docsHandlerFor(id),

        .zig_import_graph,
        .zig_import_graph_json,
        .zig_decl_summary,
        .zig_decl_summary_json,
        .zig_allocations,
        .zig_error_sets,
        .zig_public_api,
        .zig_dead_decl_candidates,
        .zig_build_graph,
        .zig_build_targets,
        .zig_build_options,
        .zig_file_owner,
        .zig_import_resolve,
        .zig_test_discover,
        .zig_changed_files_plan,
        .zig_dependency_inspect,
        .zig_target_matrix_plan,
        .zig_test_failure_triage,
        .zig_workspace_symbol_cache,
        .zig_package_cache_doctor,
        .zig_test_map,
        .zig_test_select,
        .zig_public_api_diff,
        => staticAnalysisHandlerFor(id),

        .zig_ci_annotations,
        .zig_junit,
        .zig_matrix_check,
        => ciHandlerFor(id),

        .zig_lint,
        .zig_lint_sarif,
        .zig_lint_rules,
        .zig_analysis_graphs,
        => zwanzigHandlerFor(id),

        .zig_profile_plan,
        .zig_profile_run,
        .zig_flamegraph,
        .zig_flamegraph_diff,
        => profilingHandlerFor(id),
    };
}

fn discoveryHandlerFor(comptime id: tool_metadata.ToolId) ToolHandler {
    return switch (id) {
        .zigar_capabilities, .zigar_tool_index => discovery.zigarCapabilities,
        .zigar_schema => discovery.zigarSchema,
        .zigar_doctor => discovery.zigarDoctor,
        .zigar_workspace_info => discovery.workspaceInfo,
        .zigar_metrics => discovery.zigarMetrics,
        .zigar_http_status => discovery.zigarHttpStatus,
        .zig_command_plan => discovery.zigCommandPlan,
        .zig_toolchain_resolve => discovery.zigToolchainResolve,
        else => unreachable,
    };
}

fn agentWorkflowHandlerFor(comptime id: tool_metadata.ToolId) ToolHandler {
    return switch (id) {
        .zigar_context_pack => agent.zigarContextPack,
        .zigar_next_action => agent.zigarNextAction,
        .zigar_agent_guide => agent.zigarAgentGuide,
        .zigar_validate_patch => agent.zigarValidatePatch,
        .zigar_failure_fusion => agent.zigarFailureFusion,
        .zigar_impact => agent.zigarImpact,
        .zigar_project_profile => agent.zigarProjectProfile,
        .zigar_patch_guard => agent.zigarPatchGuard,
        else => unreachable,
    };
}

fn coreZigHandlerFor(comptime id: tool_metadata.ToolId) ToolHandler {
    return switch (id) {
        .zig_version => core.zigVersion,
        .zig_env => core.zigEnv,
        .zig_targets => core.zigTargets,
        .zig_build => core.zigBuild,
        .zig_test => core.zigTest,
        .zig_check => core.zigCheck,
        .zig_compile_error_index => core.zigCompileErrorIndex,
        .zig_explain_errors => core.zigExplainErrors,
        .zig_translate_c => core.zigTranslateC,
        else => unreachable,
    };
}

fn editHandlerFor(comptime id: tool_metadata.ToolId) ToolHandler {
    return switch (id) {
        .zig_format => edit_zls.zigFormat,
        .zig_format_check => edit_zls.zigFormatCheck,
        .zig_patch_preview => edit_zls.zigPatchPreview,
        .zig_rename => edit_zls.zigRename,
        .zig_code_actions => edit_zls.zigCodeActions,
        .zig_code_action_apply => edit_zls.zigCodeActionApply,
        else => unreachable,
    };
}

fn zlsHandlerFor(comptime id: tool_metadata.ToolId) ToolHandler {
    return switch (id) {
        .zig_document_open, .zig_document_change => edit_zls.zigDocumentOpen,
        .zig_document_close => edit_zls.zigDocumentClose,
        .zig_document_status => edit_zls.zigDocumentStatus,
        .zig_diagnostics => edit_zls.zigDiagnostics,
        .zig_diagnostics_all => edit_zls.zigDiagnosticsAll,
        .zig_diagnostics_workspace => edit_zls.zigDiagnosticsWorkspace,
        .zig_hover => edit_zls.zigHover,
        .zig_definition => edit_zls.zigDefinition,
        .zig_references => edit_zls.zigReferences,
        .zig_completion => edit_zls.zigCompletion,
        .zig_signature_help => edit_zls.zigSignatureHelp,
        .zig_document_symbols => edit_zls.zigDocumentSymbols,
        .zig_workspace_symbols => edit_zls.zigWorkspaceSymbols,
        else => unreachable,
    };
}

fn docsHandlerFor(comptime id: tool_metadata.ToolId) ToolHandler {
    return switch (id) {
        .zig_builtin_list => docs.zigBuiltinList,
        .zig_builtin_list_json => docs.zigBuiltinListJson,
        .zig_builtin_doc => docs.zigBuiltinDoc,
        .zig_std_search => docs.zigStdSearch,
        .zig_std_search_json => docs.zigStdSearchJson,
        .zig_std_item => docs.zigStdItem,
        .zig_lang_ref_search => docs.zigLangRefSearch,
        else => unreachable,
    };
}

fn staticAnalysisHandlerFor(comptime id: tool_metadata.ToolId) ToolHandler {
    return switch (id) {
        .zig_import_graph => static_analysis.zigImportGraph,
        .zig_import_graph_json => static_analysis.zigImportGraphJson,
        .zig_decl_summary => static_analysis.zigDeclSummary,
        .zig_decl_summary_json => static_analysis.zigDeclSummaryJson,
        .zig_allocations => static_analysis.zigAllocations,
        .zig_error_sets => static_analysis.zigErrorSets,
        .zig_public_api => static_analysis.zigPublicApi,
        .zig_dead_decl_candidates => static_analysis.zigDeadDeclCandidates,
        .zig_build_graph => static_analysis.zigBuildGraph,
        .zig_build_targets => static_analysis.zigBuildTargets,
        .zig_build_options => static_analysis.zigBuildOptions,
        .zig_file_owner => static_analysis.zigFileOwner,
        .zig_import_resolve => static_analysis.zigImportResolve,
        .zig_test_discover => static_analysis.zigTestDiscover,
        .zig_changed_files_plan => static_analysis.zigChangedFilesPlan,
        .zig_dependency_inspect => static_analysis.zigDependencyInspect,
        .zig_target_matrix_plan => static_analysis.zigTargetMatrixPlan,
        .zig_test_failure_triage => static_analysis.zigTestFailureTriage,
        .zig_workspace_symbol_cache => static_analysis.zigWorkspaceSymbolCache,
        .zig_package_cache_doctor => static_analysis.zigPackageCacheDoctor,
        .zig_test_map => static_analysis.zigTestMap,
        .zig_test_select => static_analysis.zigTestSelect,
        .zig_public_api_diff => static_analysis.zigPublicApiDiff,
        else => unreachable,
    };
}

fn ciHandlerFor(comptime id: tool_metadata.ToolId) ToolHandler {
    return switch (id) {
        .zig_ci_annotations => ci.zigCiAnnotations,
        .zig_junit => ci.zigJunit,
        .zig_matrix_check => ci.zigMatrixCheck,
        else => unreachable,
    };
}

fn zwanzigHandlerFor(comptime id: tool_metadata.ToolId) ToolHandler {
    return switch (id) {
        .zig_lint => zwanzig.zigLint,
        .zig_lint_sarif => zwanzig.zigLintSarif,
        .zig_lint_rules => zwanzig.zigLintRules,
        .zig_analysis_graphs => zwanzig.zigAnalysisGraphs,
        else => unreachable,
    };
}

fn profilingHandlerFor(comptime id: tool_metadata.ToolId) ToolHandler {
    return switch (id) {
        .zig_profile_plan => profiling.zigProfilePlan,
        .zig_profile_run => profiling.zigProfileRun,
        .zig_flamegraph => profiling.zigFlamegraph,
        .zig_flamegraph_diff => profiling.zigFlamegraphDiff,
        else => unreachable,
    };
}

pub fn registerResources(server: *mcp.Server, runtime: *App) !void {
    try server.addResource(.{
        .uri = "zigar://workspace",
        .name = "Zigar Workspace",
        .description = "Current zigar workspace and backend configuration.",
        .mimeType = "text/plain",
        .handler = resourceHandler(resources.workspaceResource),
        .user_data = runtime,
    });
    try server.addResource(.{
        .uri = "zigar://zls/status",
        .name = "ZLS Status",
        .description = "Current ZLS session state and capability summary.",
        .mimeType = "application/json",
        .handler = resourceHandler(resources.zlsStatusResource),
        .user_data = runtime,
    });
    try server.addResource(.{
        .uri = "zigar://tools/capabilities",
        .name = "Zigar Tool Capabilities",
        .description = "Deterministic capability summary for zigar tool groups.",
        .mimeType = "application/json",
        .handler = resourceHandler(resources.capabilitiesResource),
        .user_data = runtime,
    });
    try server.addResource(.{
        .uri = "zigar://tools/schema",
        .name = "Zigar Tool Schema",
        .description = "Compact zigar tool catalog, safety defaults, and discovery hints.",
        .mimeType = "application/json",
        .handler = resourceHandler(resources.schemaResource),
        .user_data = runtime,
    });
    try server.addResource(.{
        .uri = "zigar://workspace/import-graph",
        .name = "Workspace Import Graph",
        .description = "Heuristic Zig import graph for the active workspace.",
        .mimeType = "text/plain",
        .handler = resourceHandler(resources.importGraphResource),
        .user_data = runtime,
    });
    try server.addResource(.{
        .uri = "zigar://metrics",
        .name = "Zigar Metrics",
        .description = "Process-local zigar counters and backend state.",
        .mimeType = "application/json",
        .handler = resourceHandler(resources.metricsResource),
        .user_data = runtime,
    });
    try server.addResourceTemplate(.{
        .uriTemplate = "zigar://file/{path}/symbols",
        .name = "File Symbols",
        .description = "Use zig_document_symbols or zig_decl_summary_json for the given workspace file.",
        .mimeType = "application/json",
    });
    try server.addResourceTemplate(.{
        .uriTemplate = "zigar://file/{path}/diagnostics",
        .name = "File Diagnostics",
        .description = "Use zig_diagnostics_all for the given workspace file.",
        .mimeType = "application/json",
    });
    try server.addResourceTemplate(.{
        .uriTemplate = "zigar://file/{path}/imports",
        .name = "File Imports",
        .description = "Use zig_import_graph_json and filter by path for import data.",
        .mimeType = "application/json",
    });
}

pub fn registerPrompts(server: *mcp.Server, runtime: *App) !void {
    try server.addPrompt(.{
        .name = "zigar_profile_workflow",
        .description = "Plan a deterministic Zig profiling workflow using zigar tools.",
        .title = "Zig Profiling Workflow",
        .handler = promptHandler(resources.profilePrompt),
        .user_data = runtime,
    });
}

fn resourceHandler(comptime handler: *const fn (*App, std.mem.Allocator, []const u8) mcp.resources.ResourceError!mcp.resources.ResourceContent) *const fn (?*anyopaque, std.Io, std.mem.Allocator, []const u8) mcp.resources.ResourceError!mcp.resources.ResourceContent {
    return struct {
        fn call(user_data: ?*anyopaque, _: std.Io, allocator: std.mem.Allocator, uri: []const u8) mcp.resources.ResourceError!mcp.resources.ResourceContent {
            const runtime: *App = @ptrCast(@alignCast(user_data orelse return error.Unknown));
            return handler(runtime, allocator, uri);
        }
    }.call;
}

fn promptHandler(comptime handler: *const fn (*App, std.mem.Allocator, ?std.json.Value) mcp.prompts.PromptError![]const mcp.prompts.PromptMessage) *const fn (?*anyopaque, std.Io, std.mem.Allocator, ?std.json.Value) mcp.prompts.PromptError![]const mcp.prompts.PromptMessage {
    return struct {
        fn call(user_data: ?*anyopaque, _: std.Io, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.prompts.PromptError![]const mcp.prompts.PromptMessage {
            const runtime: *App = @ptrCast(@alignCast(user_data orelse return error.Unknown));
            return handler(runtime, allocator, args);
        }
    }.call;
}

test {
    _ = @import("server_tests.zig");
}
