const std = @import("std");
const mcp = @import("mcp");
const zigar = @import("zigar");

const analysis = zigar.analysis;
const catalog = zigar.catalog;
const command = zigar.command;
const docs = zigar.docs;
const doctor = zigar.doctor;
const json_result = zigar.json_result;
const runtime_mod = zigar.runtime;
const tool_metadata = zigar.tool_metadata;
const tool_registry = zigar.tool_registry;
const tooling = zigar.tooling;
const workspace_mod = zigar.workspace;
const zls_session = zigar.zls_session;
const LspClient = zigar.lsp_client.LspClient;
const lsp_edits = zigar.lsp_edits;
const uri_util = zigar.uri;

const App = runtime_mod.App;
const BackendProbeCache = runtime_mod.BackendProbeCache;

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
        .zigar_capabilities, .zigar_tool_index => zigarCapabilities,
        .zigar_schema => zigarSchema,
        .zigar_doctor => zigarDoctor,
        .zigar_workspace_info => workspaceInfo,
        .zigar_metrics => zigarMetrics,
        .zigar_http_status => zigarHttpStatus,
        .zig_command_plan => zigCommandPlan,
        .zig_toolchain_resolve => zigToolchainResolve,
        else => unreachable,
    };
}

fn agentWorkflowHandlerFor(comptime id: tool_metadata.ToolId) ToolHandler {
    return switch (id) {
        .zigar_context_pack => zigarContextPack,
        .zigar_next_action => zigarNextAction,
        .zigar_agent_guide => zigarAgentGuide,
        .zigar_validate_patch => zigarValidatePatch,
        .zigar_failure_fusion => zigarFailureFusion,
        .zigar_impact => zigarImpact,
        .zigar_project_profile => zigarProjectProfile,
        .zigar_patch_guard => zigarPatchGuard,
        else => unreachable,
    };
}

fn coreZigHandlerFor(comptime id: tool_metadata.ToolId) ToolHandler {
    return switch (id) {
        .zig_version => zigVersion,
        .zig_env => zigEnv,
        .zig_targets => zigTargets,
        .zig_build => zigBuild,
        .zig_test => zigTest,
        .zig_check => zigCheck,
        .zig_compile_error_index => zigCompileErrorIndex,
        .zig_explain_errors => zigExplainErrors,
        .zig_translate_c => zigTranslateC,
        else => unreachable,
    };
}

fn editHandlerFor(comptime id: tool_metadata.ToolId) ToolHandler {
    return switch (id) {
        .zig_format => zigFormat,
        .zig_format_check => zigFormatCheck,
        .zig_patch_preview => zigPatchPreview,
        .zig_rename => zigRename,
        .zig_code_actions => zigCodeActions,
        .zig_code_action_apply => zigCodeActionApply,
        else => unreachable,
    };
}

fn zlsHandlerFor(comptime id: tool_metadata.ToolId) ToolHandler {
    return switch (id) {
        .zig_document_open, .zig_document_change => zigDocumentOpen,
        .zig_document_close => zigDocumentClose,
        .zig_document_status => zigDocumentStatus,
        .zig_diagnostics => zigDiagnostics,
        .zig_diagnostics_all => zigDiagnosticsAll,
        .zig_diagnostics_workspace => zigDiagnosticsWorkspace,
        .zig_hover => zigHover,
        .zig_definition => zigDefinition,
        .zig_references => zigReferences,
        .zig_completion => zigCompletion,
        .zig_signature_help => zigSignatureHelp,
        .zig_document_symbols => zigDocumentSymbols,
        .zig_workspace_symbols => zigWorkspaceSymbols,
        else => unreachable,
    };
}

fn docsHandlerFor(comptime id: tool_metadata.ToolId) ToolHandler {
    return switch (id) {
        .zig_builtin_list => zigBuiltinList,
        .zig_builtin_list_json => zigBuiltinListJson,
        .zig_builtin_doc => zigBuiltinDoc,
        .zig_std_search => zigStdSearch,
        .zig_std_search_json => zigStdSearchJson,
        .zig_std_item => zigStdItem,
        .zig_lang_ref_search => zigLangRefSearch,
        else => unreachable,
    };
}

fn staticAnalysisHandlerFor(comptime id: tool_metadata.ToolId) ToolHandler {
    return switch (id) {
        .zig_import_graph => zigImportGraph,
        .zig_import_graph_json => zigImportGraphJson,
        .zig_decl_summary => zigDeclSummary,
        .zig_decl_summary_json => zigDeclSummaryJson,
        .zig_allocations => zigAllocations,
        .zig_error_sets => zigErrorSets,
        .zig_public_api => zigPublicApi,
        .zig_dead_decl_candidates => zigDeadDeclCandidates,
        .zig_build_graph => zigBuildGraph,
        .zig_build_targets => zigBuildTargets,
        .zig_build_options => zigBuildOptions,
        .zig_file_owner => zigFileOwner,
        .zig_import_resolve => zigImportResolve,
        .zig_test_discover => zigTestDiscover,
        .zig_changed_files_plan => zigChangedFilesPlan,
        .zig_dependency_inspect => zigDependencyInspect,
        .zig_target_matrix_plan => zigTargetMatrixPlan,
        .zig_test_failure_triage => zigTestFailureTriage,
        .zig_workspace_symbol_cache => zigWorkspaceSymbolCache,
        .zig_package_cache_doctor => zigPackageCacheDoctor,
        .zig_test_map => zigTestMap,
        .zig_test_select => zigTestSelect,
        .zig_public_api_diff => zigPublicApiDiff,
        else => unreachable,
    };
}

fn ciHandlerFor(comptime id: tool_metadata.ToolId) ToolHandler {
    return switch (id) {
        .zig_ci_annotations => zigCiAnnotations,
        .zig_junit => zigJunit,
        .zig_matrix_check => zigMatrixCheck,
        else => unreachable,
    };
}

fn zwanzigHandlerFor(comptime id: tool_metadata.ToolId) ToolHandler {
    return switch (id) {
        .zig_lint => zigLint,
        .zig_lint_sarif => zigLintSarif,
        .zig_lint_rules => zigLintRules,
        .zig_analysis_graphs => zigAnalysisGraphs,
        else => unreachable,
    };
}

fn profilingHandlerFor(comptime id: tool_metadata.ToolId) ToolHandler {
    return switch (id) {
        .zig_profile_plan => zigProfilePlan,
        .zig_profile_run => zigProfileRun,
        .zig_flamegraph => zigFlamegraph,
        .zig_flamegraph_diff => zigFlamegraphDiff,
        else => unreachable,
    };
}

pub fn registerResources(server: *mcp.Server, runtime: *App) !void {
    try server.addResource(.{
        .uri = "zigar://workspace",
        .name = "Zigar Workspace",
        .description = "Current zigar workspace and backend configuration.",
        .mimeType = "text/plain",
        .handler = resourceHandler(workspaceResource),
        .user_data = runtime,
    });
    try server.addResource(.{
        .uri = "zigar://zls/status",
        .name = "ZLS Status",
        .description = "Current ZLS session state and capability summary.",
        .mimeType = "application/json",
        .handler = resourceHandler(zlsStatusResource),
        .user_data = runtime,
    });
    try server.addResource(.{
        .uri = "zigar://tools/capabilities",
        .name = "Zigar Tool Capabilities",
        .description = "Deterministic capability summary for zigar tool groups.",
        .mimeType = "application/json",
        .handler = resourceHandler(capabilitiesResource),
        .user_data = runtime,
    });
    try server.addResource(.{
        .uri = "zigar://tools/schema",
        .name = "Zigar Tool Schema",
        .description = "Compact zigar tool catalog, safety defaults, and discovery hints.",
        .mimeType = "application/json",
        .handler = resourceHandler(schemaResource),
        .user_data = runtime,
    });
    try server.addResource(.{
        .uri = "zigar://workspace/import-graph",
        .name = "Workspace Import Graph",
        .description = "Heuristic Zig import graph for the active workspace.",
        .mimeType = "text/plain",
        .handler = resourceHandler(importGraphResource),
        .user_data = runtime,
    });
    try server.addResource(.{
        .uri = "zigar://metrics",
        .name = "Zigar Metrics",
        .description = "Process-local zigar counters and backend state.",
        .mimeType = "application/json",
        .handler = resourceHandler(metricsResource),
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
        .handler = promptHandler(profilePrompt),
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

fn errorText(allocator: std.mem.Allocator, value: []const u8) mcp.tools.ToolError!mcp.tools.ToolResult {
    return mcp.tools.errorResult(allocator, value) catch return error.OutOfMemory;
}

fn structured(allocator: std.mem.Allocator, value: std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return json_result.structured(allocator, value);
}

fn structuredOwned(allocator: std.mem.Allocator, value: std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return json_result.structuredOwned(allocator, value);
}

fn putOwnedKey(allocator: std.mem.Allocator, obj: *std.json.ObjectMap, key: []const u8, value: std.json.Value) !void {
    const owned_key = try allocator.dupe(u8, key);
    errdefer allocator.free(owned_key);
    try obj.put(allocator, owned_key, value);
}

fn argString(args: ?std.json.Value, name: []const u8) ?[]const u8 {
    return mcp.tools.getString(args, name);
}

fn argBool(args: ?std.json.Value, name: []const u8, default: bool) bool {
    return mcp.tools.getBoolean(args, name) orelse default;
}

fn argInt(args: ?std.json.Value, name: []const u8, default: i64) i64 {
    return mcp.tools.getInteger(args, name) orelse default;
}

fn workspacePathErrorResult(a: *App, allocator: std.mem.Allocator, tool_name: []const u8, path: []const u8, err: anyerror) mcp.tools.ToolError!mcp.tools.ToolResult {
    switch (err) {
        error.PathOutsideWorkspace, error.EmptyPath => {
            const message = workspacePathErrorMessage(allocator, tool_name, path, a.workspace.root, err) catch return error.OutOfMemory;
            defer allocator.free(message);
            return errorText(allocator, message);
        },
        error.InvalidArguments => return error.InvalidArguments,
        error.NotConnected => return zlsUnavailable(a, allocator),
        error.DocumentTooLarge => return errorText(allocator, "ZLS document sync rejected content larger than zigar's per-document memory budget. Save the file on disk and call a file-based tool, or send a smaller unsaved document."),
        error.OpenDocumentLimitExceeded => return errorText(allocator, "ZLS document sync rejected the document because zigar reached its open-document budget. Close unused documents with zig_document_close and retry."),
        error.ExecutionFailed => return error.ExecutionFailed,
        else => {
            const message = std.fmt.allocPrint(
                allocator,
                "{s}: rejected path `{s}` while resolving it inside the configured workspace: {s}.",
                .{ tool_name, path, @errorName(err) },
            ) catch return error.OutOfMemory;
            defer allocator.free(message);
            return errorText(allocator, message);
        },
    }
}

fn workspacePathErrorMessage(allocator: std.mem.Allocator, tool_name: []const u8, path: []const u8, root: []const u8, err: anyerror) ![]u8 {
    if (err == error.EmptyPath) {
        return std.fmt.allocPrint(
            allocator,
            "{s}: rejected an empty path.\n\nRun zigar_workspace_info to confirm the active workspace `{s}`. Pass a workspace-relative path, or restart/configure zigar with --workspace set to the Zig project you are editing.",
            .{ tool_name, root },
        );
    }
    return std.fmt.allocPrint(
        allocator,
        "{s}: rejected path `{s}` because it is outside the configured zigar workspace `{s}`.\n\nRun zigar_workspace_info to confirm the active workspace. Pass a workspace-relative path, or restart/configure zigar with --workspace set to the Zig project you are editing.",
        .{ tool_name, path, root },
    );
}

fn runAndFormat(a: *App, allocator: std.mem.Allocator, argv: []const []const u8, title: []const u8) mcp.tools.ToolError!mcp.tools.ToolResult {
    return runAndFormatTimeout(a, allocator, argv, title, a.config.timeout_ms);
}

fn runAndFormatTimeout(a: *App, allocator: std.mem.Allocator, argv: []const []const u8, title: []const u8, timeout_ms: i64) mcp.tools.ToolError!mcp.tools.ToolResult {
    a.command_calls += 1;
    const result = command.run(allocator, a.io, a.workspace.root, argv, timeout_ms) catch |err| {
        a.tool_errors += 1;
        const value = commandErrorValue(allocator, title, argv, a.workspace.root, timeout_ms, err) catch return error.OutOfMemory;
        return structured(allocator, value);
    };
    defer result.deinit(allocator);
    const value = commandResultValue(allocator, title, argv, a.workspace.root, timeout_ms, result) catch return error.OutOfMemory;
    return structured(allocator, value);
}

fn toolTimeout(a: *App, args: ?std.json.Value) i64 {
    return @max(1, @min(argInt(args, "timeout_ms", a.config.timeout_ms), 60 * 60 * 1000));
}

fn argvValue(allocator: std.mem.Allocator, argv: []const []const u8) !std.json.Value {
    var array = std.json.Array.init(allocator);
    errdefer array.deinit();
    for (argv) |arg| try array.append(.{ .string = arg });
    return .{ .array = array };
}

fn commandTermValue(allocator: std.mem.Allocator, term: std.process.Child.Term) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    switch (term) {
        .exited => |code| {
            try obj.put(allocator, "kind", .{ .string = "exited" });
            try obj.put(allocator, "code", .{ .integer = @intCast(code) });
        },
        .signal => {
            try obj.put(allocator, "kind", .{ .string = "signal" });
        },
        .stopped => {
            try obj.put(allocator, "kind", .{ .string = "stopped" });
        },
        .unknown => {
            try obj.put(allocator, "kind", .{ .string = "unknown" });
        },
    }
    return .{ .object = obj };
}

fn commandResultValue(allocator: std.mem.Allocator, title: []const u8, argv: []const []const u8, cwd: []const u8, timeout_ms: i64, result: command.RunResult) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "command" });
    try obj.put(allocator, "title", .{ .string = title });
    try obj.put(allocator, "ok", .{ .bool = result.succeeded() });
    try obj.put(allocator, "cwd", .{ .string = cwd });
    try obj.put(allocator, "argv", try argvValue(allocator, argv));
    try obj.put(allocator, "timeout_ms", .{ .integer = timeout_ms });
    try obj.put(allocator, "term", try commandTermValue(allocator, result.term));
    try obj.put(allocator, "stdout", .{ .string = result.stdout });
    try obj.put(allocator, "stderr", .{ .string = result.stderr });
    try obj.put(allocator, "stdout_truncated", .{ .bool = result.stdout_truncated });
    try obj.put(allocator, "stderr_truncated", .{ .bool = result.stderr_truncated });
    try obj.put(allocator, "stdout_limit", .{ .integer = @intCast(result.stdout_limit) });
    try obj.put(allocator, "stderr_limit", .{ .integer = @intCast(result.stderr_limit) });
    try obj.put(allocator, "output_limit_mode", .{ .string = command.output_limit_mode });
    const insights = try compilerInsightsValue(allocator, result.stdout, result.stderr, argv);
    try obj.put(allocator, "diagnostics", insights);
    try obj.put(allocator, "failure_summary", try failureSummaryValue(allocator, insights, result.succeeded(), argv));
    return .{ .object = obj };
}

fn commandErrorValue(allocator: std.mem.Allocator, title: []const u8, argv: []const []const u8, cwd: []const u8, timeout_ms: i64, err: anyerror) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "command_error" });
    try obj.put(allocator, "title", .{ .string = title });
    try obj.put(allocator, "ok", .{ .bool = false });
    try obj.put(allocator, "cwd", .{ .string = cwd });
    try obj.put(allocator, "argv", try argvValue(allocator, argv));
    try obj.put(allocator, "timeout_ms", .{ .integer = timeout_ms });
    try obj.put(allocator, "error", .{ .string = @errorName(err) });
    try obj.put(allocator, "error_kind", .{ .string = command.errorKind(err) });
    try obj.put(allocator, "stdout_limit", .{ .integer = command.output_limit });
    try obj.put(allocator, "stderr_limit", .{ .integer = command.output_limit });
    try obj.put(allocator, "output_limit_mode", .{ .string = command.output_limit_mode });
    try obj.put(allocator, "output_limit_exceeded", .{ .bool = command.isOutputLimitError(err) });
    try obj.put(allocator, "stdout_truncated", .{ .bool = false });
    try obj.put(allocator, "stderr_truncated", .{ .bool = false });
    if (command.isOutputLimitError(err)) {
        try obj.put(allocator, "note", .{ .string = "Command output exceeded zigar's capture limit. zigar fails the command instead of returning partial output; narrow the command or run it directly when full output is needed." });
    }
    try obj.put(allocator, "failure_summary", try commandErrorSummaryValue(allocator, err, argv));
    return .{ .object = obj };
}

fn failureSummaryValue(allocator: std.mem.Allocator, insights: std.json.Value, ok: bool, argv: []const []const u8) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "ok", .{ .bool = ok });
    const insights_obj = switch (insights) {
        .object => |o| o,
        else => {
            try obj.put(allocator, "primary", .null);
            return .{ .object = obj };
        },
    };
    const primary = insights_obj.get("primary") orelse .null;
    try obj.put(allocator, "primary", primary);
    try obj.put(allocator, "error_class", insights_obj.get("category") orelse .{ .string = "none" });
    try obj.put(allocator, "rerun_command", insights_obj.get("next_command") orelse .null);
    var suggested = std.json.Array.init(allocator);
    if (!ok) {
        try suggested.append(try ownedString(allocator, "zig_compile_error_index"));
        if (argvContains(argv, "test")) try suggested.append(try ownedString(allocator, "zig_test_failure_triage"));
        try suggested.append(try ownedString(allocator, "zigar_failure_fusion"));
        try suggested.append(try ownedString(allocator, "zigar_impact"));
    }
    try obj.put(allocator, "suggested_tools", .{ .array = suggested });
    try obj.put(allocator, "likely_scope", try likelyFailureScopeValue(allocator, primary));
    return .{ .object = obj };
}

fn commandErrorSummaryValue(allocator: std.mem.Allocator, err: anyerror, argv: []const []const u8) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "ok", .{ .bool = false });
    try obj.put(allocator, "primary", .null);
    try obj.put(allocator, "error_class", .{ .string = command.errorKind(err) });
    try obj.put(allocator, "rerun_command", .{ .string = try commandString(allocator, argv) });
    var suggested = std.json.Array.init(allocator);
    try suggested.append(try ownedString(allocator, "zigar_doctor"));
    try suggested.append(try ownedString(allocator, "zigar_context_pack"));
    try obj.put(allocator, "suggested_tools", .{ .array = suggested });
    try obj.put(allocator, "likely_scope", .{ .string = if (command.isTimeoutError(err)) "command_timeout" else "tool_or_backend_configuration" });
    return .{ .object = obj };
}

fn likelyFailureScopeValue(allocator: std.mem.Allocator, primary: std.json.Value) !std.json.Value {
    const primary_obj = switch (primary) {
        .object => |o| o,
        else => return .{ .string = "none" },
    };
    const path = switch (primary_obj.get("path") orelse .null) {
        .string => |s| s,
        else => return .{ .string = "workspace_or_build" },
    };
    if (std.mem.eql(u8, path, "build.zig") or std.mem.eql(u8, path, "build.zig.zon")) return .{ .string = "build_configuration" };
    if (std.mem.endsWith(u8, path, ".zig")) return .{ .string = "source_file" };
    return .{ .string = try std.fmt.allocPrint(allocator, "path:{s}", .{path}) };
}

fn backendErrorKind(err: anyerror) []const u8 {
    return switch (err) {
        error.RequestTimeout, error.Timeout => "timeout",
        error.NotConnected, error.EndOfStream, error.BrokenPipe => "unavailable",
        error.FileNotFound => "executable_not_found",
        error.AccessDenied, error.PermissionDenied => "permission",
        error.StreamTooLong => "output_limit",
        else => command.errorKind(err),
    };
}

fn backendErrorValue(allocator: std.mem.Allocator, backend_name: []const u8, operation: []const u8, err: anyerror, resolution: []const u8) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "backend_error" });
    try obj.put(allocator, "ok", .{ .bool = false });
    try obj.put(allocator, "backend", .{ .string = backend_name });
    try obj.put(allocator, "operation", .{ .string = operation });
    try obj.put(allocator, "error", .{ .string = @errorName(err) });
    try obj.put(allocator, "error_kind", .{ .string = backendErrorKind(err) });
    try obj.put(allocator, "resolution", .{ .string = resolution });
    return .{ .object = obj };
}

fn backendErrorResult(allocator: std.mem.Allocator, backend_name: []const u8, operation: []const u8, err: anyerror, resolution: []const u8) mcp.tools.ToolError!mcp.tools.ToolResult {
    return structured(allocator, backendErrorValue(allocator, backend_name, operation, err, resolution) catch return error.OutOfMemory);
}

fn backendUnavailableResult(allocator: std.mem.Allocator, backend_name: []const u8, operation: []const u8, configured_path: []const u8, status: []const u8, resolution: []const u8) mcp.tools.ToolError!mcp.tools.ToolResult {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "backend_error" });
    try obj.put(allocator, "ok", .{ .bool = false });
    try obj.put(allocator, "backend", .{ .string = backend_name });
    try obj.put(allocator, "operation", .{ .string = operation });
    try obj.put(allocator, "error", .{ .string = "Unavailable" });
    try obj.put(allocator, "error_kind", .{ .string = "unavailable" });
    try obj.put(allocator, "configured_path", .{ .string = configured_path });
    try obj.put(allocator, "status", .{ .string = status });
    try obj.put(allocator, "resolution", .{ .string = resolution });
    return structured(allocator, .{ .object = obj });
}

fn splitToolArgs(allocator: std.mem.Allocator, text_value: ?[]const u8) mcp.tools.ToolError![]const []const u8 {
    return command.splitArgs(allocator, text_value) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidArguments => error.InvalidArguments,
    };
}

const CompilerLine = struct {
    severity: []const u8,
    path: ?[]const u8 = null,
    line: ?i64 = null,
    column: ?i64 = null,
    message: []const u8,
    raw: []const u8,
};

fn compilerInsightsValue(allocator: std.mem.Allocator, stdout: []const u8, stderr: []const u8, argv: []const []const u8) !std.json.Value {
    var findings = std.json.Array.init(allocator);
    var error_count: i64 = 0;
    var warning_count: i64 = 0;
    var note_count: i64 = 0;
    var primary: ?CompilerLine = null;

    try collectCompilerLines(allocator, &findings, stderr, &primary, &error_count, &warning_count, &note_count);
    try collectCompilerLines(allocator, &findings, stdout, &primary, &error_count, &warning_count, &note_count);

    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "finding_count", .{ .integer = @intCast(findings.items.len) });
    try obj.put(allocator, "error_count", .{ .integer = error_count });
    try obj.put(allocator, "warning_count", .{ .integer = warning_count });
    try obj.put(allocator, "note_count", .{ .integer = note_count });
    try obj.put(allocator, "findings", .{ .array = findings });
    if (primary) |p| {
        try obj.put(allocator, "primary", try compilerLineValue(allocator, p));
        try obj.put(allocator, "category", .{ .string = classifyDiagnosticMessage(p.message) });
        try obj.put(allocator, "next_command", try compilerNextCommand(allocator, p, argv));
        try obj.put(allocator, "next_actions", try compilerNextActions(allocator, p, note_count));
    } else {
        try obj.put(allocator, "primary", .null);
        try obj.put(allocator, "category", .{ .string = "none" });
        try obj.put(allocator, "next_command", .null);
        try obj.put(allocator, "next_actions", .{ .array = std.json.Array.init(allocator) });
    }
    return .{ .object = obj };
}

fn collectCompilerLines(
    allocator: std.mem.Allocator,
    findings: *std.json.Array,
    text_value: []const u8,
    primary: *?CompilerLine,
    error_count: *i64,
    warning_count: *i64,
    note_count: *i64,
) !void {
    var lines = std.mem.splitScalar(u8, text_value, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, "\r");
        const parsed = parseCompilerLine(line) orelse continue;
        if (std.mem.eql(u8, parsed.severity, "error")) {
            error_count.* += 1;
            if (primary.* == null) primary.* = parsed;
        } else if (std.mem.eql(u8, parsed.severity, "warning")) {
            warning_count.* += 1;
            if (primary.* == null) primary.* = parsed;
        } else if (std.mem.eql(u8, parsed.severity, "note")) {
            note_count.* += 1;
        }
        try findings.append(try compilerLineValue(allocator, parsed));
    }
}

fn parseCompilerLine(line: []const u8) ?CompilerLine {
    if (parseLocatedCompilerLine(line, "error")) |parsed| return parsed;
    if (parseLocatedCompilerLine(line, "warning")) |parsed| return parsed;
    if (parseLocatedCompilerLine(line, "note")) |parsed| return parsed;
    if (std.mem.startsWith(u8, line, "error: ")) return .{ .severity = "error", .message = line["error: ".len..], .raw = line };
    if (std.mem.startsWith(u8, line, "warning: ")) return .{ .severity = "warning", .message = line["warning: ".len..], .raw = line };
    if (std.mem.startsWith(u8, line, "note: ")) return .{ .severity = "note", .message = line["note: ".len..], .raw = line };
    return null;
}

fn parseLocatedCompilerLine(line: []const u8, severity: []const u8) ?CompilerLine {
    var token_buf: [16]u8 = undefined;
    const token = std.fmt.bufPrint(&token_buf, ": {s}: ", .{severity}) catch return null;
    const severity_pos = std.mem.indexOf(u8, line, token) orelse return null;
    const prefix = line[0..severity_pos];
    const message = line[severity_pos + token.len ..];
    const col_sep = std.mem.lastIndexOfScalar(u8, prefix, ':') orelse return .{ .severity = severity, .message = message, .raw = line };
    const line_prefix = prefix[0..col_sep];
    const line_sep = std.mem.lastIndexOfScalar(u8, line_prefix, ':') orelse return .{ .severity = severity, .message = message, .raw = line };
    const line_no = std.fmt.parseInt(i64, line_prefix[line_sep + 1 ..], 10) catch return .{ .severity = severity, .message = message, .raw = line };
    const col_no = std.fmt.parseInt(i64, prefix[col_sep + 1 ..], 10) catch return .{ .severity = severity, .message = message, .raw = line };
    return .{
        .severity = severity,
        .path = line_prefix[0..line_sep],
        .line = line_no,
        .column = col_no,
        .message = message,
        .raw = line,
    };
}

fn compilerLineValue(allocator: std.mem.Allocator, parsed: CompilerLine) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "severity", .{ .string = parsed.severity });
    try obj.put(allocator, "message", try ownedString(allocator, parsed.message));
    try obj.put(allocator, "raw", try ownedString(allocator, parsed.raw));
    if (parsed.path) |path| {
        try obj.put(allocator, "path", try ownedString(allocator, path));
    } else {
        try obj.put(allocator, "path", .null);
    }
    if (parsed.line) |line_no| {
        try obj.put(allocator, "line", .{ .integer = line_no });
    } else {
        try obj.put(allocator, "line", .null);
    }
    if (parsed.column) |col_no| {
        try obj.put(allocator, "column", .{ .integer = col_no });
    } else {
        try obj.put(allocator, "column", .null);
    }
    return .{ .object = obj };
}

fn classifyDiagnosticMessage(message: []const u8) []const u8 {
    if (std.mem.indexOf(u8, message, "expected type") != null) return "type_mismatch";
    if (std.mem.indexOf(u8, message, "expected ") != null and std.mem.indexOf(u8, message, "found ") != null) return "syntax_or_type_mismatch";
    if (std.mem.indexOf(u8, message, "expected ") != null) return "syntax_error";
    if (std.mem.indexOf(u8, message, "use of undeclared identifier") != null) return "undeclared_identifier";
    if (std.mem.indexOf(u8, message, "no field named") != null) return "missing_field";
    if (std.mem.indexOf(u8, message, "unable to load") != null or std.mem.indexOf(u8, message, "FileNotFound") != null) return "missing_file_or_import";
    if (std.mem.indexOf(u8, message, "unused") != null) return "unused_code";
    if (std.mem.indexOf(u8, message, "invalid token") != null) return "syntax_error";
    return "compiler_error";
}

fn compilerNextCommand(allocator: std.mem.Allocator, primary: CompilerLine, argv: []const []const u8) !std.json.Value {
    const zig = if (argv.len > 0) argv[0] else "zig";
    const path = primary.path orelse return .{ .string = try commandString(allocator, argv) };
    if (path.len > 0 and std.mem.endsWith(u8, path, ".zig")) {
        if (argvContains(argv, "test")) {
            return .{ .string = try std.fmt.allocPrint(allocator, "{s} test {s}", .{ zig, path }) };
        }
        return .{ .string = try std.fmt.allocPrint(allocator, "{s} ast-check {s}", .{ zig, path }) };
    }
    return .{ .string = try commandString(allocator, argv) };
}

fn compilerNextActions(allocator: std.mem.Allocator, primary: CompilerLine, note_count: i64) !std.json.Value {
    var actions = std.json.Array.init(allocator);
    if (primary.path) |path| {
        if (primary.line) |line_no| {
            if (primary.column) |col_no| {
                try actions.append(.{ .string = try std.fmt.allocPrint(allocator, "Open {s}:{d}:{d} and address the primary {s}: {s}", .{ path, line_no, col_no, primary.severity, primary.message }) });
            } else {
                try actions.append(.{ .string = try std.fmt.allocPrint(allocator, "Open {s}:{d} and address the primary {s}: {s}", .{ path, line_no, primary.severity, primary.message }) });
            }
        } else {
            try actions.append(.{ .string = try std.fmt.allocPrint(allocator, "Inspect {s} and address the primary {s}: {s}", .{ path, primary.severity, primary.message }) });
        }
    } else {
        try actions.append(.{ .string = try std.fmt.allocPrint(allocator, "Address the primary {s}: {s}", .{ primary.severity, primary.message }) });
    }
    if (note_count > 0) {
        try actions.append(try ownedString(allocator, "Review compiler note entries before editing; Zig often puts the fix-relevant type or declaration context there."));
    }
    if (std.mem.eql(u8, classifyDiagnosticMessage(primary.message), "missing_file_or_import")) {
        try actions.append(try ownedString(allocator, "Run zig_import_resolve for the failing @import name, then check build.zig addImport and build.zig.zon dependency wiring."));
    }
    try actions.append(try ownedString(allocator, "Rerun the next_command after the focused edit."));
    return .{ .array = actions };
}

fn commandString(allocator: std.mem.Allocator, argv: []const []const u8) ![]u8 {
    if (argv.len == 0) return allocator.dupe(u8, "");
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (argv, 0..) |arg, index| {
        if (index > 0) try out.append(allocator, ' ');
        try out.appendSlice(allocator, arg);
    }
    return out.toOwnedSlice(allocator);
}

fn argvContains(argv: []const []const u8, needle: []const u8) bool {
    for (argv) |arg| {
        if (std.mem.eql(u8, arg, needle)) return true;
    }
    return false;
}

fn structuredText(allocator: std.mem.Allocator, kind: []const u8, body: []const u8) mcp.tools.ToolError!mcp.tools.ToolResult {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    obj.put(allocator, "kind", .{ .string = kind }) catch return error.OutOfMemory;
    obj.put(allocator, "text", .{ .string = body }) catch return error.OutOfMemory;
    return structured(allocator, .{ .object = obj });
}

fn jsonTextOnly(allocator: std.mem.Allocator, bytes: []u8) mcp.tools.ToolError!mcp.tools.ToolResult {
    errdefer allocator.free(bytes);
    const content = allocator.alloc(mcp.types.ContentBlock, 1) catch return error.OutOfMemory;
    content[0] = .{ .text = .{ .text = bytes } };
    return .{ .content = content };
}

fn zigarCapabilities(_: *App, allocator: std.mem.Allocator, _: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return catalogToolResult(allocator);
}

fn zigarSchema(_: *App, allocator: std.mem.Allocator, _: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return catalogToolResult(allocator);
}

fn catalogToolResult(allocator: std.mem.Allocator) mcp.tools.ToolError!mcp.tools.ToolResult {
    return jsonTextOnly(allocator, catalog.text(allocator) catch return error.OutOfMemory);
}

fn zigarDoctor(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const probe_backends = argBool(args, "probe_backends", false);
    const probe_timeout_ms = @max(1, @min(argInt(args, "timeout_ms", 1_000), 10_000));
    const value = doctor.report(allocator, .{
        .workspace = a.workspace.root,
        .cache = a.workspace.cache_root,
        .strict_workspace = a.config.strict_workspace,
        .transport = switch (a.config.transport) {
            .stdio => "stdio",
            .http => "http",
        },
        .zig_path = a.config.zig_path,
        .zls_path = a.config.zls_path,
        .zwanzig_path = a.config.zwanzig_path,
        .zflame_path = a.config.zflame_path,
        .diff_folded_path = a.config.diff_folded_path,
        .zls_status = a.zls_status,
        .zls_last_failure = a.zls_last_failure,
        .timeout_ms = a.config.timeout_ms,
        .zls_timeout_ms = a.config.zls_timeout_ms,
        .mcp_dependency = "mcp.zig 0.0.4",
        .http_available = true,
        .zig_probe = if (probe_backends) probeBackend(a, allocator, "zig", &.{ a.config.zig_path, "version" }, probe_timeout_ms) else null,
        .zls_probe = if (probe_backends) probeBackend(a, allocator, "zls", &.{ a.config.zls_path, "--version" }, probe_timeout_ms) else null,
        .zwanzig_probe = if (probe_backends) probeBackend(a, allocator, "zwanzig", &.{ a.config.zwanzig_path, "--help" }, probe_timeout_ms) else null,
        .zflame_probe = if (probe_backends) probeBackend(a, allocator, "zflame", &.{ a.config.zflame_path, "--help" }, probe_timeout_ms) else null,
        .diff_folded_probe = if (probe_backends) probeBackend(a, allocator, "diff-folded", &.{ a.config.diff_folded_path, "--help" }, probe_timeout_ms) else null,
    }) catch return error.OutOfMemory;
    return structured(allocator, value);
}

fn probeBackend(a: *App, allocator: std.mem.Allocator, name: []const u8, argv: []const []const u8, timeout_ms: i64) doctor.Probe {
    if (backendProbeSlot(a, name)) |slot| {
        if (slot.*) |probe| return probe;
        const probe = probeBackendDirect(allocator, a, argv, timeout_ms);
        slot.* = probe;
        return probe;
    }
    return probeBackendDirect(allocator, a, argv, timeout_ms);
}

fn backendProbeSlot(a: *App, name: []const u8) ?*?doctor.Probe {
    if (std.mem.eql(u8, name, "zig")) return &a.backend_probe_cache.zig;
    if (std.mem.eql(u8, name, "zls")) return &a.backend_probe_cache.zls;
    if (std.mem.eql(u8, name, "zwanzig")) return &a.backend_probe_cache.zwanzig;
    if (std.mem.eql(u8, name, "zflame")) return &a.backend_probe_cache.zflame;
    if (std.mem.eql(u8, name, "diff-folded")) return &a.backend_probe_cache.diff_folded;
    return null;
}

fn probeBackendDirect(allocator: std.mem.Allocator, a: *App, argv: []const []const u8, timeout_ms: i64) doctor.Probe {
    const result = command.run(allocator, a.io, a.workspace.root, argv, timeout_ms) catch |err| {
        return .{ .ok = false, .status = @errorName(err), .resolution = "confirm the configured backend path and executable permissions" };
    };
    defer result.deinit(allocator);
    if (result.succeeded()) {
        return .{ .ok = true, .status = "ok", .resolution = "backend command completed" };
    }
    return .{ .ok = false, .status = command.termText(result.term), .resolution = "backend command exited non-zero; run the configured command directly to inspect stderr" };
}

fn backendProbeCacheValue(allocator: std.mem.Allocator, cache: BackendProbeCache) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "zig", try cachedProbeValue(allocator, cache.zig));
    try obj.put(allocator, "zls", try cachedProbeValue(allocator, cache.zls));
    try obj.put(allocator, "zwanzig", try cachedProbeValue(allocator, cache.zwanzig));
    try obj.put(allocator, "zflame", try cachedProbeValue(allocator, cache.zflame));
    try obj.put(allocator, "diff_folded", try cachedProbeValue(allocator, cache.diff_folded));
    return .{ .object = obj };
}

fn cachedProbeValue(allocator: std.mem.Allocator, probe: ?doctor.Probe) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    if (probe) |p| {
        try obj.put(allocator, "probed", .{ .bool = true });
        try obj.put(allocator, "ok", .{ .bool = p.ok });
        try obj.put(allocator, "status", .{ .string = p.status });
        try obj.put(allocator, "resolution", .{ .string = p.resolution });
    } else {
        try obj.put(allocator, "probed", .{ .bool = false });
        try obj.put(allocator, "ok", .null);
        try obj.put(allocator, "status", .{ .string = "not probed" });
        try obj.put(allocator, "resolution", .{ .string = "call zigar_doctor with probe_backends=true to cache backend availability" });
    }
    return .{ .object = obj };
}

fn ownedString(allocator: std.mem.Allocator, value: []const u8) !std.json.Value {
    return .{ .string = try allocator.dupe(u8, value) };
}

fn zigarMetrics(a: *App, allocator: std.mem.Allocator, _: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return structured(allocator, metricsValue(a, allocator) catch return error.OutOfMemory);
}

fn zigarHttpStatus(a: *App, allocator: std.mem.Allocator, _: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    obj.put(allocator, "configured_transport", .{ .string = switch (a.config.transport) {
        .stdio => "stdio",
        .http => "http",
    } }) catch return error.OutOfMemory;
    obj.put(allocator, "host", .{ .string = a.config.host }) catch return error.OutOfMemory;
    obj.put(allocator, "port", .{ .integer = a.config.port }) catch return error.OutOfMemory;
    obj.put(allocator, "http_available", .{ .bool = true }) catch return error.OutOfMemory;
    obj.put(allocator, "reason", .{ .string = "HTTP transport is enabled through mcp.zig 0.0.4; stdio remains the safest default for Codex" }) catch return error.OutOfMemory;
    return structured(allocator, .{ .object = obj });
}

fn zigarContextPack(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const mode = argString(args, "mode") orelse "standard";
    const token_budget = @max(500, @min(argInt(args, "token_budget", 4000), 50_000));
    const limit: usize = if (std.mem.eql(u8, mode, "tiny")) 40 else if (std.mem.eql(u8, mode, "deep")) 500 else 150;

    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zigar_context_pack" });
    try obj.put(allocator, "mode", .{ .string = mode });
    try obj.put(allocator, "token_budget", .{ .integer = token_budget });
    try obj.put(allocator, "workspace", try contextWorkspaceValue(allocator, a));
    try obj.put(allocator, "project_type", try projectTypeValue(allocator, a));
    try obj.put(allocator, "build", buildWorkspaceValue(allocator, a) catch .null);
    if (!std.mem.eql(u8, mode, "tiny")) {
        try obj.put(allocator, "tests", testMapValue(allocator, a, @min(limit, 200)) catch .null);
        try obj.put(allocator, "deps", dependencyContextValue(allocator, a) catch .null);
    }
    try obj.put(allocator, "source_map", sourceMapValue(allocator, a, limit) catch .null);
    try obj.put(allocator, "quality", try qualityCommandsValue(allocator, a));
    try obj.put(allocator, "agent_rules", try agentRulesValue(allocator, "generic", "any"));
    try obj.put(allocator, "recommended_start", try nextActionPlanValue(allocator, "orient", null, null));
    try obj.put(allocator, "limits", try contextLimitsValue(allocator));
    return structured(allocator, .{ .object = obj });
}

fn zigarNextAction(_: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const goal = argString(args, "goal") orelse return error.InvalidArguments;
    return structured(allocator, nextActionPlanValue(allocator, goal, argString(args, "changed_files"), argString(args, "last_error")) catch return error.OutOfMemory);
}

fn zigarAgentGuide(_: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const client = argString(args, "client") orelse "generic";
    const task = argString(args, "task") orelse "any";
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zigar_agent_guide" });
    try obj.put(allocator, "client", .{ .string = client });
    try obj.put(allocator, "task", .{ .string = task });
    try obj.put(allocator, "rules", try agentRulesValue(allocator, client, task));
    try obj.put(allocator, "workflows", try agentWorkflowHintsValue(allocator, task));
    try obj.put(allocator, "tool_aliases", try agentToolAliasesValue(allocator));
    return structured(allocator, .{ .object = obj });
}

fn zigarValidatePatch(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const mode = argString(args, "mode") orelse "standard";
    const timeout_ms = toolTimeout(a, args);
    const stop_on_failure = argBool(args, "stop_on_failure", true);
    var paths = changedPathList(allocator, a, argString(args, "changed_files"), timeout_ms) catch return error.OutOfMemory;
    defer paths.deinit(allocator);
    defer freeStringList(allocator, paths.items);

    var phases = std.json.Array.init(allocator);
    var files = std.json.Array.init(allocator);
    var ok = true;
    var ran_full_build = false;
    var saw_build_file = false;

    for (paths.items) |path| {
        try files.append(try ownedString(allocator, path));
        if (std.mem.eql(u8, path, "build.zig") or std.mem.eql(u8, path, "build.zig.zon")) saw_build_file = true;
        if (!workspacePathExists(allocator, a, path)) continue;
        if (std.mem.endsWith(u8, path, ".zig") or std.mem.endsWith(u8, path, ".zig.zon")) {
            const fmt_ok = try appendValidationPhase(allocator, a, &phases, "format_check", &.{ a.config.zig_path, "fmt", "--check", path }, timeout_ms);
            if (!fmt_ok) {
                ok = false;
                if (stop_on_failure) break;
            }
        }
        if (std.mem.endsWith(u8, path, ".zig")) {
            const check_ok = try appendValidationPhase(allocator, a, &phases, "ast_check", &.{ a.config.zig_path, "ast-check", path }, timeout_ms);
            if (!check_ok) {
                ok = false;
                if (stop_on_failure) break;
            }
        }
    }

    if (ok or !stop_on_failure) {
        if (paths.items.len == 0) {
            try appendWorkspaceFormatCheckPhase(allocator, a, &phases, timeout_ms, &ok, stop_on_failure);
        }
    }
    if ((ok or !stop_on_failure) and !std.mem.eql(u8, mode, "quick")) {
        if (std.mem.eql(u8, mode, "full") or std.mem.eql(u8, mode, "standard") or saw_build_file or paths.items.len == 0) {
            ran_full_build = true;
            const build_ok = try appendValidationPhase(allocator, a, &phases, "build_test", &.{ a.config.zig_path, "build", "test" }, timeout_ms);
            if (!build_ok) ok = false;
        }
    }

    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zigar_validate_patch" });
    try obj.put(allocator, "ok", .{ .bool = ok });
    try obj.put(allocator, "mode", .{ .string = mode });
    try obj.put(allocator, "changed_files", .{ .array = files });
    try obj.put(allocator, "phases", .{ .array = phases });
    try obj.put(allocator, "ran_full_build_test", .{ .bool = ran_full_build });
    try obj.put(allocator, "next_action", try validationNextActionValue(allocator, ok, phases));
    return structured(allocator, .{ .object = obj });
}

fn zigarFailureFusion(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    if (argString(args, "text")) |raw_text| {
        return structured(allocator, failureFusionValue(allocator, raw_text, "", &.{ "zig", "build", "test" }, false) catch return error.OutOfMemory);
    }
    var list = buildExplainCommand(allocator, args, a) catch |err| return explainCommandSetupError(a, allocator, "zigar_failure_fusion", args, err);
    defer {
        for (list.owned_paths.items) |path| allocator.free(path);
        list.owned_paths.deinit(allocator);
        list.argv.deinit(allocator);
    }
    a.command_calls += 1;
    const result = command.run(allocator, a.io, a.workspace.root, list.argv.items, toolTimeout(a, args)) catch |err| {
        return backendErrorResult(allocator, "zig", "failure_fusion", err, "pass captured output as text or confirm --zig-path is executable");
    };
    defer result.deinit(allocator);
    return structured(allocator, failureFusionValue(allocator, result.stderr, result.stdout, list.argv.items, result.succeeded()) catch return error.OutOfMemory);
}

fn zigarImpact(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return structured(allocator, impactValue(allocator, a, argString(args, "files"), argString(args, "symbols"), @intCast(@max(1, argInt(args, "limit", 300)))) catch return error.OutOfMemory);
}

fn zigarProjectProfile(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const profile_path = ".zigar/profile.json";
    const generated = if (argString(args, "content")) |content| blk: {
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{}) catch return error.InvalidArguments;
        defer parsed.deinit();
        break :blk json_result.cloneValue(allocator, parsed.value) catch return error.OutOfMemory;
    } else try generatedProjectProfileValue(allocator, a);

    const apply = argBool(args, "apply", false);
    if (apply) {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(allocator);
        try json_result.serializeValue(allocator, &out, generated);
        a.workspace.writeFile(a.io, profile_path, out.items) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.PathOutsideWorkspace, error.EmptyPath, error.AccessDenied, error.PermissionDenied => return workspacePathErrorResult(a, allocator, "zigar_project_profile", profile_path, err),
            else => return error.ExecutionFailed,
        };
    }

    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zigar_project_profile" });
    try obj.put(allocator, "path", .{ .string = profile_path });
    try obj.put(allocator, "applied", .{ .bool = apply });
    try obj.put(allocator, "requires_apply", .{ .bool = !apply });
    if (a.workspace.readFileAlloc(a.io, profile_path, 1024 * 1024) catch null) |existing| {
        defer allocator.free(existing);
        try obj.put(allocator, "existing", .{ .string = existing });
    } else {
        try obj.put(allocator, "existing", .null);
    }
    try obj.put(allocator, "profile", generated);
    return structured(allocator, .{ .object = obj });
}

fn zigarPatchGuard(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    var paths = std.ArrayList([]const u8).empty;
    defer paths.deinit(allocator);
    defer freeStringList(allocator, paths.items);
    try appendPathTokens(allocator, &paths, argString(args, "files"));
    try appendPatchPaths(allocator, &paths, argString(args, "patch"));

    var checked = std.json.Array.init(allocator);
    var violations = std.json.Array.init(allocator);
    var safe = true;
    for (paths.items) |path| {
        if (path.len == 0 or std.mem.eql(u8, path, "/dev/null")) continue;
        var item = std.json.ObjectMap.empty;
        try item.put(allocator, "path", try ownedString(allocator, path));
        const resolved = a.workspace.resolveOutput(path) catch |err| {
            safe = false;
            try item.put(allocator, "ok", .{ .bool = false });
            try item.put(allocator, "reason", .{ .string = @errorName(err) });
            try violations.append(try ownedString(allocator, path));
            try checked.append(.{ .object = item });
            continue;
        };
        allocator.free(resolved);
        const generated = analysis.skipWorkspacePath(path);
        if (generated) safe = false;
        try item.put(allocator, "ok", .{ .bool = !generated });
        try item.put(allocator, "generated_or_vendored", .{ .bool = generated });
        try item.put(allocator, "reason", .{ .string = if (generated) "generated_or_vendored_path" else "workspace_local_path" });
        if (generated) try violations.append(try ownedString(allocator, path));
        try checked.append(.{ .object = item });
    }

    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zigar_patch_guard" });
    try obj.put(allocator, "safe", .{ .bool = safe });
    try obj.put(allocator, "checked", .{ .array = checked });
    try obj.put(allocator, "violations", .{ .array = violations });
    try obj.put(allocator, "write_policy", .{ .string = "zigar source writes require the specific mutating tool to receive apply=true" });
    return structured(allocator, .{ .object = obj });
}

fn contextWorkspaceValue(allocator: std.mem.Allocator, a: *App) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "root", .{ .string = a.workspace.root });
    try obj.put(allocator, "cache", .{ .string = a.workspace.cache_root });
    try obj.put(allocator, "strict_workspace", .{ .bool = a.config.strict_workspace });
    try obj.put(allocator, "transport", .{ .string = switch (a.config.transport) {
        .stdio => "stdio",
        .http => "http",
    } });
    try obj.put(allocator, "zig_path", .{ .string = a.config.zig_path });
    try obj.put(allocator, "zls_status", .{ .string = a.zls_status });
    try obj.put(allocator, "zls_running", .{ .bool = if (a.lsp_client) |client| client.isRunning() else false });
    return .{ .object = obj };
}

fn projectTypeValue(allocator: std.mem.Allocator, a: *App) !std.json.Value {
    const graph = buildWorkspaceValue(allocator, a) catch .null;
    const build_obj = buildZigObject(graph);
    const artifact_count = if (build_obj) |o| jsonArrayLen(o.get("artifacts") orelse .null) else 0;
    const module_count = if (build_obj) |o| jsonArrayLen(o.get("modules") orelse .null) else 0;
    const test_count = if (build_obj) |o| jsonArrayLen(o.get("tests") orelse .null) else 0;
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = if (artifact_count > 0 and module_count > 0)
        "multi_artifact_package"
    else if (artifact_count > 0)
        "artifact_project"
    else if (module_count > 0)
        "library_or_module_project"
    else if (workspacePathExists(allocator, a, "build.zig"))
        "build_script_project"
    else
        "source_tree" });
    try obj.put(allocator, "artifact_count", .{ .integer = @intCast(artifact_count) });
    try obj.put(allocator, "module_count", .{ .integer = @intCast(module_count) });
    try obj.put(allocator, "build_test_count", .{ .integer = @intCast(test_count) });
    try obj.put(allocator, "confidence", .{ .string = if (workspacePathExists(allocator, a, "build.zig")) "medium" else "low" });
    return .{ .object = obj };
}

fn dependencyContextValue(allocator: std.mem.Allocator, a: *App) !std.json.Value {
    if (a.workspace.readFileAlloc(a.io, "build.zig.zon", 1024 * 1024) catch null) |bytes| {
        defer allocator.free(bytes);
        return dependencyInspectionValue(allocator, a, bytes);
    }
    return .null;
}

fn sourceMapValue(allocator: std.mem.Allocator, a: *App, limit: usize) !std.json.Value {
    var files = std.json.Array.init(allocator);
    var dirs = std.json.Array.init(allocator);
    var seen_dirs = std.ArrayList([]const u8).empty;
    defer seen_dirs.deinit(allocator);
    defer freeStringList(allocator, seen_dirs.items);
    var dir = try std.Io.Dir.openDirAbsolute(a.io, a.workspace.root, .{ .iterate = true });
    defer dir.close(a.io);
    var walker = try dir.walk(allocator);
    defer walker.deinit();
    var seen: usize = 0;
    while ((walker.next(a.io) catch null)) |entry| {
        if (seen >= limit) break;
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".zig") or analysis.skipWorkspacePath(entry.path)) continue;
        seen += 1;
        try files.append(try ownedString(allocator, entry.path));
        if (std.fs.path.dirname(entry.path)) |dirname| {
            if (!stringListContains(seen_dirs.items, dirname)) {
                try seen_dirs.append(allocator, try allocator.dupe(u8, dirname));
                try dirs.append(try ownedString(allocator, dirname));
            }
        }
    }
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "analysis_kind", .{ .string = "workspace_file_scan" });
    try obj.put(allocator, "file_count", .{ .integer = @intCast(seen) });
    try obj.put(allocator, "dirs", .{ .array = dirs });
    try obj.put(allocator, "files", .{ .array = files });
    return .{ .object = obj };
}

fn qualityCommandsValue(allocator: std.mem.Allocator, a: *App) !std.json.Value {
    var commands = std.json.Array.init(allocator);
    try appendWorkspaceFormatCheckCommand(allocator, a, &commands);
    try appendUniqueCommand(allocator, &commands, "zig build test");
    try appendUniqueCommand(allocator, &commands, "zigar_validate_patch");
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "default_commands", .{ .array = commands });
    try obj.put(allocator, "final_gate", .{ .string = "zigar_validate_patch" });
    return .{ .object = obj };
}

fn contextLimitsValue(allocator: std.mem.Allocator) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "source_writes", .{ .string = "only tools with apply=true write source" });
    try obj.put(allocator, "analysis", .{ .string = "heuristic unless a ZLS/command-backed field says otherwise" });
    try obj.put(allocator, "stdout", .{ .string = "MCP JSON-RPC only; logs go to stderr" });
    return .{ .object = obj };
}

fn agentRulesValue(allocator: std.mem.Allocator, client: []const u8, task: []const u8) !std.json.Value {
    var rules = std.json.Array.init(allocator);
    try rules.append(try ownedString(allocator, "Call zigar_context_pack first when entering an unfamiliar Zig workspace."));
    try rules.append(try ownedString(allocator, "Use zig_format or zig_format_check for formatting; do not fall back to raw zig fmt unless zigar is unavailable."));
    try rules.append(try ownedString(allocator, "Use zig_compile_error_index or zigar_failure_fusion before interpreting compiler stderr manually."));
    try rules.append(try ownedString(allocator, "Use zigar_validate_patch as the final readiness gate before handing work back."));
    try rules.append(try ownedString(allocator, "Source-writing zigar tools are preview-only unless apply=true is explicit."));
    if (std.mem.eql(u8, client, "claude")) try rules.append(try ownedString(allocator, "Prefer compact JSON fields over long command output when summarizing to the user."));
    if (std.mem.eql(u8, client, "codex")) try rules.append(try ownedString(allocator, "Prefer zigar_patch_guard before broad multi-file edits."));
    if (std.mem.indexOf(u8, task, "profile") != null) try rules.append(try ownedString(allocator, "Use zig_profile_plan before capture and zflame-backed tools only for rendering existing profiler data."));
    return .{ .array = rules };
}

fn agentWorkflowHintsValue(allocator: std.mem.Allocator, task: []const u8) !std.json.Value {
    var workflows = std.json.Array.init(allocator);
    try workflows.append(try workflowHintValue(allocator, "orientation", &.{ "zigar_context_pack", "zigar_next_action" }));
    try workflows.append(try workflowHintValue(allocator, "compile_error", &.{ "zig_compile_error_index", "zigar_failure_fusion", "zigar_impact" }));
    try workflows.append(try workflowHintValue(allocator, "tests", &.{ "zig_test_failure_triage", "zig_test_select", "zigar_validate_patch" }));
    try workflows.append(try workflowHintValue(allocator, "patch_readiness", &.{ "zigar_patch_guard", "zigar_validate_patch", "zig_public_api_diff" }));
    if (std.mem.indexOf(u8, task, "api") != null) try workflows.append(try workflowHintValue(allocator, "api_change", &.{ "zig_public_api_diff", "zigar_impact", "zig_test_select" }));
    return .{ .array = workflows };
}

fn workflowHintValue(allocator: std.mem.Allocator, name: []const u8, tools: []const []const u8) !std.json.Value {
    var tool_values = std.json.Array.init(allocator);
    for (tools) |tool| try tool_values.append(try ownedString(allocator, tool));
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "name", try ownedString(allocator, name));
    try obj.put(allocator, "tools", .{ .array = tool_values });
    return .{ .object = obj };
}

fn agentToolAliasesValue(allocator: std.mem.Allocator) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "fmt", .{ .string = "zig_format" });
    try obj.put(allocator, "formatter", .{ .string = "zig_format" });
    try obj.put(allocator, "errors", .{ .string = "zig_compile_error_index" });
    try obj.put(allocator, "health", .{ .string = "zigar_doctor" });
    try obj.put(allocator, "done", .{ .string = "zigar_validate_patch" });
    try obj.put(allocator, "impact", .{ .string = "zigar_impact" });
    return .{ .object = obj };
}

fn nextActionPlanValue(allocator: std.mem.Allocator, goal: []const u8, changed_files: ?[]const u8, last_error: ?[]const u8) !std.json.Value {
    const lower = try asciiLowerAllocLocal(allocator, goal);
    defer allocator.free(lower);
    var steps = std.json.Array.init(allocator);
    if (std.mem.indexOf(u8, lower, "test") != null) {
        try steps.append(try toolStepValue(allocator, "zig_test_failure_triage", "group failing tests and panic clues"));
        try steps.append(try toolStepValue(allocator, "zig_test_select", "choose focused rerun commands for touched files or symbols"));
        try steps.append(try toolStepValue(allocator, "zigar_validate_patch", "confirm the fix with the standard validation gate"));
    } else if (std.mem.indexOf(u8, lower, "compile") != null or std.mem.indexOf(u8, lower, "build") != null or last_error != null) {
        try steps.append(try toolStepValue(allocator, "zig_compile_error_index", "group compiler diagnostics by file"));
        try steps.append(try toolStepValue(allocator, "zigar_failure_fusion", "extract primary failure, rerun command, and suggested tools"));
        try steps.append(try toolStepValue(allocator, "zigar_impact", "find affected importers/tests before editing"));
    } else if (std.mem.indexOf(u8, lower, "format") != null or std.mem.indexOf(u8, lower, "fmt") != null) {
        try steps.append(try toolStepValue(allocator, "zig_format_check", "check formatting without writing"));
        try steps.append(try toolStepValue(allocator, "zig_format", "preview or apply formatting with apply=true"));
    } else if (std.mem.indexOf(u8, lower, "profile") != null or std.mem.indexOf(u8, lower, "flame") != null) {
        try steps.append(try toolStepValue(allocator, "zig_profile_plan", "choose platform capture workflow"));
        try steps.append(try toolStepValue(allocator, "zig_flamegraph", "render captured profiler output through zflame"));
    } else if (std.mem.indexOf(u8, lower, "pr") != null or std.mem.indexOf(u8, lower, "review") != null or std.mem.indexOf(u8, lower, "done") != null) {
        try steps.append(try toolStepValue(allocator, "zigar_validate_patch", "run the final readiness gate"));
        try steps.append(try toolStepValue(allocator, "zig_public_api_diff", "check accidental public API changes"));
    } else {
        try steps.append(try toolStepValue(allocator, "zigar_context_pack", "orient to project shape and validation policy"));
        try steps.append(try toolStepValue(allocator, "zigar_impact", "map touched files or symbols to likely tests"));
        try steps.append(try toolStepValue(allocator, "zigar_validate_patch", "validate before handoff"));
    }
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zigar_next_action" });
    try obj.put(allocator, "goal", try ownedString(allocator, goal));
    if (changed_files) |files| try obj.put(allocator, "changed_files", try ownedString(allocator, files)) else try obj.put(allocator, "changed_files", .null);
    if (last_error) |err| try obj.put(allocator, "last_error", try ownedString(allocator, err)) else try obj.put(allocator, "last_error", .null);
    try obj.put(allocator, "recommended_steps", .{ .array = steps });
    try obj.put(allocator, "stop_when", .{ .string = "stop when zigar_validate_patch passes or the next tool returns a focused source edit blocker" });
    return .{ .object = obj };
}

fn toolStepValue(allocator: std.mem.Allocator, tool: []const u8, reason: []const u8) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "tool", .{ .string = tool });
    try obj.put(allocator, "reason", .{ .string = reason });
    return .{ .object = obj };
}

fn appendValidationPhase(allocator: std.mem.Allocator, a: *App, phases: *std.json.Array, name: []const u8, argv: []const []const u8, timeout_ms: i64) !bool {
    a.command_calls += 1;
    const result = command.run(allocator, a.io, a.workspace.root, argv, timeout_ms) catch |err| {
        var phase = std.json.ObjectMap.empty;
        try phase.put(allocator, "name", .{ .string = name });
        try phase.put(allocator, "ok", .{ .bool = false });
        try phase.put(allocator, "command", try commandErrorValue(allocator, name, argv, a.workspace.root, timeout_ms, err));
        try phases.append(.{ .object = phase });
        return false;
    };
    defer result.deinit(allocator);
    const ok = result.succeeded();
    var phase = std.json.ObjectMap.empty;
    try phase.put(allocator, "name", .{ .string = name });
    try phase.put(allocator, "ok", .{ .bool = ok });
    try phase.put(allocator, "command", try commandResultValue(allocator, name, argv, a.workspace.root, timeout_ms, result));
    try phases.append(.{ .object = phase });
    return ok;
}

fn appendWorkspaceFormatCheckPhase(allocator: std.mem.Allocator, a: *App, phases: *std.json.Array, timeout_ms: i64, ok: *bool, stop_on_failure: bool) !void {
    const candidates = [_][]const u8{ "build.zig", "build.zig.zon", "src" };
    var argv_list: std.ArrayList([]const u8) = .empty;
    defer argv_list.deinit(allocator);
    try argv_list.append(allocator, a.config.zig_path);
    try argv_list.append(allocator, "fmt");
    try argv_list.append(allocator, "--check");
    var appended = false;
    for (candidates) |candidate| {
        if (!workspacePathExists(allocator, a, candidate)) continue;
        try argv_list.append(allocator, candidate);
        appended = true;
    }
    if (!appended) return;
    const fmt_ok = try appendValidationPhase(allocator, a, phases, "workspace_format_check", argv_list.items, timeout_ms);
    if (!fmt_ok) {
        ok.* = false;
        if (stop_on_failure) return;
    }
}

fn validationNextActionValue(allocator: std.mem.Allocator, ok: bool, phases: std.json.Array) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    if (ok) {
        try obj.put(allocator, "status", .{ .string = "ready" });
        try obj.put(allocator, "tool", .null);
        try obj.put(allocator, "reason", .{ .string = "validation phases passed" });
        return .{ .object = obj };
    }
    for (phases.items) |phase_value| {
        const phase = switch (phase_value) {
            .object => |o| o,
            else => continue,
        };
        const phase_ok = switch (phase.get("ok") orelse .null) {
            .bool => |b| b,
            else => true,
        };
        if (phase_ok) continue;
        try obj.put(allocator, "status", .{ .string = "blocked" });
        try obj.put(allocator, "phase", phase.get("name") orelse .null);
        try obj.put(allocator, "tool", .{ .string = "zigar_failure_fusion" });
        try obj.put(allocator, "reason", .{ .string = "inspect the first failing validation phase and primary diagnostic" });
        return .{ .object = obj };
    }
    try obj.put(allocator, "status", .{ .string = "blocked" });
    try obj.put(allocator, "tool", .{ .string = "zigar_validate_patch" });
    try obj.put(allocator, "reason", .{ .string = "validation failed without a command phase" });
    return .{ .object = obj };
}

fn changedPathList(allocator: std.mem.Allocator, a: *App, explicit_files: ?[]const u8, timeout_ms: i64) !std.ArrayList([]const u8) {
    var list = std.ArrayList([]const u8).empty;
    errdefer {
        freeStringList(allocator, list.items);
        list.deinit(allocator);
    }
    try appendPathTokens(allocator, &list, explicit_files);
    if (list.items.len > 0) return list;
    const result = command.run(allocator, a.io, a.workspace.root, &.{ "git", "status", "--porcelain" }, @min(timeout_ms, 5000)) catch return list;
    defer result.deinit(allocator);
    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    while (lines.next()) |line| {
        if (line.len < 4) continue;
        const path = statusLinePath(line);
        if (path.len == 0 or analysis.skipWorkspacePath(path)) continue;
        try appendUniqueString(allocator, &list, path);
    }
    return list;
}

fn appendPathTokens(allocator: std.mem.Allocator, list: *std.ArrayList([]const u8), text_value: ?[]const u8) !void {
    const text_input = text_value orelse return;
    var tokens = std.mem.tokenizeAny(u8, text_input, ", \t\r\n");
    while (tokens.next()) |token| {
        if (token.len == 0) continue;
        try appendUniqueString(allocator, list, token);
    }
}

fn appendPatchPaths(allocator: std.mem.Allocator, list: *std.ArrayList([]const u8), patch_text: ?[]const u8) !void {
    const patch = patch_text orelse return;
    var lines = std.mem.splitScalar(u8, patch, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (std.mem.startsWith(u8, trimmed, "+++ ")) {
            try appendPatchPathToken(allocator, list, std.mem.trim(u8, trimmed["+++ ".len..], " \t"));
        } else if (std.mem.startsWith(u8, trimmed, "--- ")) {
            try appendPatchPathToken(allocator, list, std.mem.trim(u8, trimmed["--- ".len..], " \t"));
        } else if (std.mem.startsWith(u8, trimmed, "diff --git ")) {
            var parts = std.mem.tokenizeScalar(u8, trimmed, ' ');
            _ = parts.next();
            _ = parts.next();
            if (parts.next()) |left| try appendPatchPathToken(allocator, list, left);
            if (parts.next()) |right| try appendPatchPathToken(allocator, list, right);
        }
    }
}

fn appendPatchPathToken(allocator: std.mem.Allocator, list: *std.ArrayList([]const u8), raw: []const u8) !void {
    var path = raw;
    if (std.mem.startsWith(u8, path, "a/") or std.mem.startsWith(u8, path, "b/")) path = path[2..];
    if (std.mem.eql(u8, path, "/dev/null")) return;
    try appendUniqueString(allocator, list, path);
}

fn appendUniqueString(allocator: std.mem.Allocator, list: *std.ArrayList([]const u8), value: []const u8) !void {
    if (stringListContains(list.items, value)) return;
    try list.append(allocator, try allocator.dupe(u8, value));
}

fn stringListContains(list: []const []const u8, value: []const u8) bool {
    for (list) |item| {
        if (std.mem.eql(u8, item, value)) return true;
    }
    return false;
}

fn freeStringList(allocator: std.mem.Allocator, list: []const []const u8) void {
    for (list) |item| allocator.free(item);
}

fn jsonArrayLen(value: std.json.Value) usize {
    return switch (value) {
        .array => |a| a.items.len,
        else => 0,
    };
}

fn metricsValue(a: *App, allocator: std.mem.Allocator) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "command_calls", .{ .integer = @intCast(a.command_calls) });
    try obj.put(allocator, "zls_requests", .{ .integer = @intCast(a.zls_requests) });
    try obj.put(allocator, "tool_errors", .{ .integer = @intCast(a.tool_errors) });
    try obj.put(allocator, "zls_status", .{ .string = a.zls_status });
    try obj.put(allocator, "zls", try zlsStatusValue(allocator, a));
    try obj.put(allocator, "zls_running", .{ .bool = if (a.lsp_client) |client| client.isRunning() else false });
    try obj.put(allocator, "zls_restart_attempts", .{ .integer = @intCast(a.zls_restart_attempts) });
    if (a.zls_last_failure) |failure| {
        try obj.put(allocator, "zls_last_failure", .{ .string = failure });
    } else if (a.lsp_client) |client| {
        if (try client.lastError(allocator)) |err| {
            try obj.put(allocator, "zls_last_failure", .{ .string = err });
        } else {
            try obj.put(allocator, "zls_last_failure", .null);
        }
    } else {
        try obj.put(allocator, "zls_last_failure", .null);
    }
    try obj.put(allocator, "workspace", .{ .string = a.workspace.root });
    try obj.put(allocator, "backend_probe_cache", try backendProbeCacheValue(allocator, a.backend_probe_cache));
    try obj.put(allocator, "analysis_cache", try analysisCacheStatusValue(allocator, a));
    return .{ .object = obj };
}

fn analysisCacheStatusValue(allocator: std.mem.Allocator, a: *App) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "present", .{ .bool = a.analysis_cache.index_json != null });
    try obj.put(allocator, "signature", .{ .string = try std.fmt.allocPrint(allocator, "{x:0>16}", .{a.analysis_cache.signature}) });
    try obj.put(allocator, "hits", .{ .integer = @intCast(a.analysis_cache.hits) });
    try obj.put(allocator, "refreshes", .{ .integer = @intCast(a.analysis_cache.refreshes) });
    if (a.analysis_cache.index_json) |bytes| {
        try obj.put(allocator, "bytes", .{ .integer = @intCast(bytes.len) });
    } else {
        try obj.put(allocator, "bytes", .{ .integer = 0 });
    }
    return .{ .object = obj };
}

fn zlsStatusValue(allocator: std.mem.Allocator, a: *App) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    const running = if (a.lsp_client) |client| client.isRunning() else false;
    try obj.put(allocator, "status", .{ .string = a.zls_status });
    try obj.put(allocator, "configured_path", .{ .string = a.config.zls_path });
    try obj.put(allocator, "request_timeout_ms", .{ .integer = a.config.zls_timeout_ms });
    try obj.put(allocator, "restart_attempts", .{ .integer = @intCast(a.zls_restart_attempts) });
    try obj.put(allocator, "running", .{ .bool = running });
    try obj.put(allocator, "document_sync", .{ .bool = a.doc_state != null });
    if (a.lsp_client) |client| {
        const diagnostics = client.diagnosticsStatus();
        try obj.put(allocator, "diagnostics_cached_files", .{ .integer = @intCast(diagnostics.files) });
        try obj.put(allocator, "diagnostics_retained_bytes", .{ .integer = @intCast(diagnostics.retained_bytes) });
        try obj.put(allocator, "max_diagnostics_bytes", .{ .integer = @intCast(diagnostics.max_bytes) });
    }
    try obj.put(allocator, "initialize_response_present", .{ .bool = a.zls_initialize_response != null });
    if (a.zls_last_failure) |failure| {
        try obj.put(allocator, "last_failure", .{ .string = failure });
    } else if (a.lsp_client) |client| {
        if (try client.lastError(allocator)) |err| {
            try obj.put(allocator, "last_failure", .{ .string = err });
        } else {
            try obj.put(allocator, "last_failure", .null);
        }
    } else {
        try obj.put(allocator, "last_failure", .null);
    }
    try obj.put(allocator, "resolution", .{ .string = if (running)
        "ZLS-backed tools are available"
    else
        "confirm --zls-path points to a compatible ZLS binary; command-backed Zig tools remain available" });
    return .{ .object = obj };
}

fn unsupportedCapability(allocator: std.mem.Allocator, method: []const u8, capability: []const u8) mcp.tools.ToolError!mcp.tools.ToolResult {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    obj.put(allocator, "ok", .{ .bool = false }) catch return error.OutOfMemory;
    obj.put(allocator, "method", .{ .string = method }) catch return error.OutOfMemory;
    obj.put(allocator, "capability", .{ .string = capability }) catch return error.OutOfMemory;
    obj.put(allocator, "error", .{ .string = "ZLS did not advertise this capability" }) catch return error.OutOfMemory;
    return structured(allocator, .{ .object = obj });
}

fn zlsCapabilityName(method: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, method, "textDocument/hover")) return "hoverProvider";
    if (std.mem.eql(u8, method, "textDocument/definition")) return "definitionProvider";
    if (std.mem.eql(u8, method, "textDocument/references")) return "referencesProvider";
    if (std.mem.eql(u8, method, "textDocument/completion")) return "completionProvider";
    if (std.mem.eql(u8, method, "textDocument/signatureHelp")) return "signatureHelpProvider";
    if (std.mem.eql(u8, method, "textDocument/documentSymbol")) return "documentSymbolProvider";
    if (std.mem.eql(u8, method, "textDocument/formatting")) return "documentFormattingProvider";
    if (std.mem.eql(u8, method, "textDocument/rename")) return "renameProvider";
    if (std.mem.eql(u8, method, "textDocument/codeAction")) return "codeActionProvider";
    if (std.mem.eql(u8, method, "workspace/symbol")) return "workspaceSymbolProvider";
    return null;
}

fn zlsSupportsCapability(a: *App, allocator: std.mem.Allocator, method: []const u8) bool {
    const capability = zlsCapabilityName(method) orelse return true;
    const response = a.zls_initialize_response orelse return false;
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, response, .{}) catch return false;
    defer parsed.deinit();
    const result = responseResult(parsed.value) orelse return false;
    const result_obj = switch (result) {
        .object => |o| o,
        else => return false,
    };
    const caps = switch (result_obj.get("capabilities") orelse .null) {
        .object => |o| o,
        else => return false,
    };
    const value = caps.get(capability) orelse return false;
    return switch (value) {
        .bool => |b| b,
        .object => true,
        .array => true,
        else => false,
    };
}

fn requireZlsCapability(a: *App, allocator: std.mem.Allocator, method: []const u8) ?mcp.tools.ToolResult {
    const capability = zlsCapabilityName(method) orelse return null;
    if (zlsSupportsCapability(a, allocator, method)) return null;
    return unsupportedCapability(allocator, method, capability) catch null;
}

fn workspaceInfo(a: *App, allocator: std.mem.Allocator, _: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    obj.put(allocator, "workspace", .{ .string = a.workspace.root }) catch return error.OutOfMemory;
    obj.put(allocator, "cache", .{ .string = a.workspace.cache_root }) catch return error.OutOfMemory;
    obj.put(allocator, "zig", .{ .string = a.config.zig_path }) catch return error.OutOfMemory;
    obj.put(allocator, "zls", .{ .string = a.config.zls_path }) catch return error.OutOfMemory;
    obj.put(allocator, "zls_status", .{ .string = a.zls_status }) catch return error.OutOfMemory;
    obj.put(allocator, "zls_session", zlsStatusValue(allocator, a) catch return error.OutOfMemory) catch return error.OutOfMemory;
    if (a.zls_last_failure) |failure| {
        obj.put(allocator, "zls_last_failure", .{ .string = failure }) catch return error.OutOfMemory;
    } else {
        obj.put(allocator, "zls_last_failure", .null) catch return error.OutOfMemory;
    }
    obj.put(allocator, "zwanzig", .{ .string = a.config.zwanzig_path }) catch return error.OutOfMemory;
    obj.put(allocator, "zflame", .{ .string = a.config.zflame_path }) catch return error.OutOfMemory;
    obj.put(allocator, "timeout_ms", .{ .integer = a.config.timeout_ms }) catch return error.OutOfMemory;
    obj.put(allocator, "zls_timeout_ms", .{ .integer = a.config.zls_timeout_ms }) catch return error.OutOfMemory;
    obj.put(allocator, "strict_workspace", .{ .bool = a.config.strict_workspace }) catch return error.OutOfMemory;
    obj.put(allocator, "backend_probe_cache", backendProbeCacheValue(allocator, a.backend_probe_cache) catch return error.OutOfMemory) catch return error.OutOfMemory;
    return structured(allocator, .{ .object = obj });
}

fn zigVersion(a: *App, allocator: std.mem.Allocator, _: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const zig = command.run(allocator, a.io, a.workspace.root, &.{ a.config.zig_path, "version" }, a.config.timeout_ms) catch |err| {
        return backendErrorResult(allocator, "zig", "version", err, "confirm --zig-path points to an executable Zig 0.16.0 binary");
    };
    defer zig.deinit(allocator);
    const zls = command.run(allocator, a.io, a.workspace.root, &.{ a.config.zls_path, "--version" }, a.config.timeout_ms) catch null;
    defer if (zls) |r| r.deinit(allocator);
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    obj.put(allocator, "zig", .{ .string = std.mem.trim(u8, zig.stdout, " \t\r\n") }) catch return error.OutOfMemory;
    obj.put(allocator, "zig_ok", .{ .bool = zig.succeeded() }) catch return error.OutOfMemory;
    if (zls) |r| {
        obj.put(allocator, "zls", .{ .string = std.mem.trim(u8, r.stdout, " \t\r\n") }) catch return error.OutOfMemory;
        obj.put(allocator, "zls_ok", .{ .bool = r.succeeded() }) catch return error.OutOfMemory;
    } else {
        obj.put(allocator, "zls", .{ .string = "unavailable" }) catch return error.OutOfMemory;
        obj.put(allocator, "zls_ok", .{ .bool = false }) catch return error.OutOfMemory;
    }
    obj.put(allocator, "zls_status", .{ .string = a.zls_status }) catch return error.OutOfMemory;
    return structured(allocator, .{ .object = obj });
}

fn zigToolchainResolve(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const timeout_ms = toolTimeout(a, args);
    const zig = command.run(allocator, a.io, a.workspace.root, &.{ a.config.zig_path, "version" }, timeout_ms) catch null;
    defer if (zig) |r| r.deinit(allocator);
    const zls = command.run(allocator, a.io, a.workspace.root, &.{ a.config.zls_path, "--version" }, timeout_ms) catch null;
    defer if (zls) |r| r.deinit(allocator);

    var expected = std.json.Array.init(allocator);
    tryAppendVersionHint(allocator, &expected, a, ".zigversion", "first non-empty line", ".zigversion");
    tryAppendToolVersionsHint(allocator, &expected, a);
    tryAppendMiseHint(allocator, &expected, a);
    tryAppendBuildZonMinimumHint(allocator, &expected, a);

    const active_zig = if (zig) |r| std.mem.trim(u8, r.stdout, " \t\r\n") else "";
    var issues = std.json.Array.init(allocator);
    var zig_hint_count: usize = 0;
    var exact_match_found = false;
    var minimum_satisfied = false;
    var unknown_version_hint = false;
    for (expected.items) |hint| {
        const hint_obj = switch (hint) {
            .object => |o| o,
            else => continue,
        };
        switch (zigVersionHintStatus(active_zig, hint_obj)) {
            .ignored => {},
            .exact_match => {
                zig_hint_count += 1;
                exact_match_found = true;
            },
            .minimum_satisfied => {
                zig_hint_count += 1;
                minimum_satisfied = true;
            },
            .mismatch => zig_hint_count += 1,
            .unknown => {
                zig_hint_count += 1;
                unknown_version_hint = true;
            },
        }
    }
    const version_match = zig_hint_count == 0 or exact_match_found or minimum_satisfied;
    const version_status = if (zig_hint_count == 0)
        "no_zig_hints"
    else if (exact_match_found)
        "exact_match"
    else if (minimum_satisfied)
        "minimum_satisfied"
    else if (active_zig.len == 0 or unknown_version_hint)
        "unknown"
    else
        "mismatch";
    if (zig_hint_count > 0 and active_zig.len > 0 and !version_match) {
        try issues.append(.{ .string = try std.fmt.allocPrint(allocator, "active zig version `{s}` does not satisfy any project Zig version hint", .{active_zig}) });
    }
    if (zig == null or !zig.?.succeeded()) {
        try issues.append(try ownedString(allocator, "configured --zig-path is not executable or did not return a version"));
    }
    if (zls == null or !zls.?.succeeded()) {
        try issues.append(try ownedString(allocator, "configured --zls-path is unavailable; ZLS-backed tools will be limited"));
    }

    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zig_toolchain_resolve" });
    try obj.put(allocator, "workspace", .{ .string = a.workspace.root });
    try obj.put(allocator, "zig_path", .{ .string = a.config.zig_path });
    try obj.put(allocator, "zig_version", if (zig) |r| .{ .string = std.mem.trim(u8, r.stdout, " \t\r\n") } else .null);
    try obj.put(allocator, "zig_ok", .{ .bool = if (zig) |r| r.succeeded() else false });
    try obj.put(allocator, "zls_path", .{ .string = a.config.zls_path });
    try obj.put(allocator, "zls_version", if (zls) |r| .{ .string = std.mem.trim(u8, if (r.stdout.len > 0) r.stdout else r.stderr, " \t\r\n") } else .null);
    try obj.put(allocator, "zls_ok", .{ .bool = if (zls) |r| r.succeeded() else false });
    try obj.put(allocator, "project_version_hints", .{ .array = expected });
    try obj.put(allocator, "version_match", .{ .bool = version_match });
    try obj.put(allocator, "zig_hint_count", .{ .integer = @intCast(zig_hint_count) });
    try obj.put(allocator, "version_status", .{ .string = version_status });
    try obj.put(allocator, "managers", try versionManagersValue(allocator, a, argBool(args, "probe_managers", true), timeout_ms));
    try obj.put(allocator, "issues", .{ .array = issues });
    try obj.put(allocator, "resolution", .{ .string = "Use an existing manager such as mise, asdf, zvm, or zigup to install/select the expected Zig version, then restart zigar with matching --zig-path and --zls-path." });
    return structured(allocator, .{ .object = obj });
}

const ZigVersionHintStatus = enum {
    ignored,
    exact_match,
    minimum_satisfied,
    mismatch,
    unknown,
};

fn zigVersionHintStatus(active_zig: []const u8, hint_obj: std.json.ObjectMap) ZigVersionHintStatus {
    const key = switch (hint_obj.get("key") orelse .null) {
        .string => |s| s,
        else => return .ignored,
    };
    if (!zigVersionHintAppliesToZig(key)) return .ignored;
    const version_hint = switch (hint_obj.get("version") orelse .null) {
        .string => |s| s,
        else => return .unknown,
    };
    if (active_zig.len == 0) return .unknown;
    if (std.mem.eql(u8, key, "minimum_zig_version")) {
        if (versionMeetsMinimum(active_zig, version_hint)) return .minimum_satisfied;
        if (parseVersionPrefix(active_zig) == null or parseVersionPrefix(version_hint) == null) return .unknown;
        return .mismatch;
    }
    if (std.mem.eql(u8, active_zig, version_hint)) return .exact_match;
    return .mismatch;
}

fn zigVersionHintAppliesToZig(key: []const u8) bool {
    return !std.mem.eql(u8, key, "zls");
}

fn versionMeetsMinimum(active_zig: []const u8, minimum_zig: []const u8) bool {
    const active = parseVersionPrefix(active_zig) orelse return false;
    const minimum = parseVersionPrefix(minimum_zig) orelse return false;
    for (active, minimum) |active_part, minimum_part| {
        if (active_part > minimum_part) return true;
        if (active_part < minimum_part) return false;
    }
    return true;
}

fn parseVersionPrefix(raw: []const u8) ?[3]u64 {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n\"'");
    if (trimmed.len == 0) return null;
    var pos: usize = if (trimmed[0] == 'v') 1 else 0;
    var parts: [3]u64 = .{ 0, 0, 0 };
    var index: usize = 0;
    while (index < parts.len) : (index += 1) {
        if (pos >= trimmed.len or !std.ascii.isDigit(trimmed[pos])) break;
        var value: u64 = 0;
        while (pos < trimmed.len and std.ascii.isDigit(trimmed[pos])) : (pos += 1) {
            value = value * 10 + (trimmed[pos] - '0');
        }
        parts[index] = value;
        if (pos >= trimmed.len or trimmed[pos] != '.') {
            index += 1;
            break;
        }
        pos += 1;
    }
    if (index < 2) return null;
    return parts;
}

fn appendVersionHint(allocator: std.mem.Allocator, hints: *std.json.Array, source: []const u8, key: []const u8, version_value: []const u8) !void {
    const trimmed = std.mem.trim(u8, version_value, " \t\r\n\"'");
    if (trimmed.len == 0) return;
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "source", try ownedString(allocator, source));
    try obj.put(allocator, "key", try ownedString(allocator, key));
    try obj.put(allocator, "version", try ownedString(allocator, trimmed));
    try hints.append(.{ .object = obj });
}

fn tryAppendVersionHint(allocator: std.mem.Allocator, hints: *std.json.Array, a: *App, path: []const u8, key: []const u8, source: []const u8) void {
    const bytes = a.workspace.readFileAlloc(a.io, path, 64 * 1024) catch return;
    defer allocator.free(bytes);
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len == 0 or std.mem.startsWith(u8, trimmed, "#")) continue;
        appendVersionHint(allocator, hints, source, key, trimmed) catch return;
        return;
    }
}

fn tryAppendToolVersionsHint(allocator: std.mem.Allocator, hints: *std.json.Array, a: *App) void {
    const bytes = a.workspace.readFileAlloc(a.io, ".tool-versions", 64 * 1024) catch return;
    defer allocator.free(bytes);
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        var parts = std.mem.tokenizeAny(u8, line, " \t\r\n");
        const tool = parts.next() orelse continue;
        if (!std.mem.eql(u8, tool, "zig") and !std.mem.eql(u8, tool, "zls")) continue;
        const version_hint = parts.next() orelse continue;
        appendVersionHint(allocator, hints, ".tool-versions", tool, version_hint) catch return;
    }
}

fn tryAppendMiseHint(allocator: std.mem.Allocator, hints: *std.json.Array, a: *App) void {
    const bytes = a.workspace.readFileAlloc(a.io, "mise.toml", 128 * 1024) catch return;
    defer allocator.free(bytes);
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (std.mem.startsWith(u8, trimmed, "zig =")) {
            if (quotedString(trimmed)) |version_hint| appendVersionHint(allocator, hints, "mise.toml", "zig", version_hint) catch return;
        }
    }
}

fn tryAppendBuildZonMinimumHint(allocator: std.mem.Allocator, hints: *std.json.Array, a: *App) void {
    const bytes = a.workspace.readFileAlloc(a.io, "build.zig.zon", 256 * 1024) catch return;
    defer allocator.free(bytes);
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (std.mem.indexOf(u8, trimmed, "minimum_zig_version") != null) {
            if (quotedString(trimmed)) |version_hint| appendVersionHint(allocator, hints, "build.zig.zon", "minimum_zig_version", version_hint) catch return;
        }
    }
}

fn versionManagersValue(allocator: std.mem.Allocator, a: *App, probe: bool, timeout_ms: i64) !std.json.Value {
    var managers = std.json.Array.init(allocator);
    const names = [_][]const u8{ "mise", "asdf", "zvm", "zigup" };
    const args = [_][]const u8{ "--version", "--version", "version", "--version" };
    for (names, args) |name, version_arg| {
        var obj = std.json.ObjectMap.empty;
        try obj.put(allocator, "name", .{ .string = name });
        if (probe) {
            const result = command.run(allocator, a.io, a.workspace.root, &.{ name, version_arg }, @min(timeout_ms, 3000)) catch null;
            if (result) |r| {
                defer r.deinit(allocator);
                try obj.put(allocator, "available", .{ .bool = r.succeeded() });
                try obj.put(allocator, "version_output", try ownedString(allocator, std.mem.trim(u8, if (r.stdout.len > 0) r.stdout else r.stderr, " \t\r\n")));
            } else {
                try obj.put(allocator, "available", .{ .bool = false });
                try obj.put(allocator, "version_output", .null);
            }
        } else {
            try obj.put(allocator, "available", .null);
            try obj.put(allocator, "version_output", .null);
        }
        try managers.append(.{ .object = obj });
    }
    return .{ .array = managers };
}

fn zigCommandPlan(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const tool_name = argString(args, "tool") orelse return error.InvalidArguments;
    const spec = tool_metadata.find(tool_name) orelse return error.InvalidArguments;
    var list: std.ArrayList([]const u8) = .empty;
    defer list.deinit(allocator);
    var owned_path: ?[]u8 = null;
    defer if (owned_path) |path| allocator.free(path);
    list.append(allocator, a.config.zig_path) catch return error.OutOfMemory;

    if (std.mem.eql(u8, tool_name, "zig_build")) {
        list.append(allocator, "build") catch return error.OutOfMemory;
    } else if (std.mem.eql(u8, tool_name, "zig_test")) {
        if (argString(args, "file")) |file| {
            const resolved = a.workspace.resolve(file) catch |err| return workspacePathErrorResult(a, allocator, "zig_command_plan", file, err);
            defer allocator.free(resolved);
            owned_path = allocator.dupe(u8, resolved) catch return error.OutOfMemory;
            list.append(allocator, "test") catch return error.OutOfMemory;
            list.append(allocator, owned_path.?) catch return error.OutOfMemory;
        } else {
            list.append(allocator, "build") catch return error.OutOfMemory;
            list.append(allocator, "test") catch return error.OutOfMemory;
        }
    } else if (std.mem.eql(u8, tool_name, "zig_check")) {
        const file = argString(args, "file") orelse return error.InvalidArguments;
        const resolved = a.workspace.resolve(file) catch |err| return workspacePathErrorResult(a, allocator, "zig_command_plan", file, err);
        defer allocator.free(resolved);
        owned_path = allocator.dupe(u8, resolved) catch return error.OutOfMemory;
        list.append(allocator, "ast-check") catch return error.OutOfMemory;
        list.append(allocator, owned_path.?) catch return error.OutOfMemory;
    } else if (std.mem.eql(u8, tool_name, "zig_format_check")) {
        const path = argString(args, "path") orelse return error.InvalidArguments;
        const resolved = a.workspace.resolve(path) catch |err| return workspacePathErrorResult(a, allocator, "zig_command_plan", path, err);
        defer allocator.free(resolved);
        owned_path = allocator.dupe(u8, resolved) catch return error.OutOfMemory;
        list.append(allocator, "fmt") catch return error.OutOfMemory;
        list.append(allocator, "--check") catch return error.OutOfMemory;
        list.append(allocator, owned_path.?) catch return error.OutOfMemory;
    } else {
        return error.InvalidArguments;
    }
    const extra = try splitToolArgs(allocator, argString(args, "args"));
    defer freeArgList(allocator, extra);
    list.appendSlice(allocator, extra) catch return error.OutOfMemory;

    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    obj.put(allocator, "tool", .{ .string = tool_name }) catch return error.OutOfMemory;
    obj.put(allocator, "cwd", .{ .string = a.workspace.root }) catch return error.OutOfMemory;
    obj.put(allocator, "argv", argvValue(allocator, list.items) catch return error.OutOfMemory) catch return error.OutOfMemory;
    obj.put(allocator, "timeout_ms", .{ .integer = toolTimeout(a, args) }) catch return error.OutOfMemory;
    const risk = tool_metadata.riskFor(spec.id);
    obj.put(allocator, "risk", tool_metadata.riskValue(allocator, spec) catch return error.OutOfMemory) catch return error.OutOfMemory;
    obj.put(allocator, "risk_level", .{ .string = tool_metadata.riskLevel(risk) }) catch return error.OutOfMemory;
    obj.put(allocator, "writes_source", .{ .bool = risk.writes_source }) catch return error.OutOfMemory;
    return structured(allocator, .{ .object = obj });
}

fn zigEnv(a: *App, allocator: std.mem.Allocator, _: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return runAndFormat(a, allocator, &.{ a.config.zig_path, "env" }, "zig env");
}

fn zigTargets(a: *App, allocator: std.mem.Allocator, _: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return runAndFormat(a, allocator, &.{ a.config.zig_path, "targets" }, "zig targets");
}

fn zigBuild(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const extra = try splitToolArgs(allocator, argString(args, "args"));
    defer freeArgList(allocator, extra);
    const argv = command.joinArgv(allocator, &.{ a.config.zig_path, "build" }, extra) catch return error.OutOfMemory;
    defer allocator.free(argv);
    return runAndFormatTimeout(a, allocator, argv, "zig build", toolTimeout(a, args));
}

fn zigTest(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    var list: std.ArrayList([]const u8) = .empty;
    defer list.deinit(allocator);
    var resolved_file: ?[]const u8 = null;
    defer if (resolved_file) |path| allocator.free(path);
    list.append(allocator, a.config.zig_path) catch return error.OutOfMemory;
    if (argString(args, "file")) |file| {
        resolved_file = a.workspace.resolve(file) catch |err| return workspacePathErrorResult(a, allocator, "zig_test", file, err);
        list.append(allocator, "test") catch return error.OutOfMemory;
        list.append(allocator, resolved_file.?) catch return error.OutOfMemory;
        if (argString(args, "filter")) |filter| {
            list.append(allocator, "--test-filter") catch return error.OutOfMemory;
            list.append(allocator, filter) catch return error.OutOfMemory;
        }
    } else {
        list.append(allocator, "build") catch return error.OutOfMemory;
        list.append(allocator, "test") catch return error.OutOfMemory;
    }
    const extra = try splitToolArgs(allocator, argString(args, "args"));
    defer freeArgList(allocator, extra);
    list.appendSlice(allocator, extra) catch return error.OutOfMemory;
    return runAndFormatTimeout(a, allocator, list.items, "zig test", toolTimeout(a, args));
}

fn zigCheck(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const file = argString(args, "file") orelse return error.InvalidArguments;
    const resolved = a.workspace.resolve(file) catch |err| return workspacePathErrorResult(a, allocator, "zig_check", file, err);
    defer allocator.free(resolved);
    return runAndFormatTimeout(a, allocator, &.{ a.config.zig_path, "ast-check", resolved }, "zig ast-check", toolTimeout(a, args));
}

fn zigCompileErrorIndex(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    if (argString(args, "text")) |raw_text| {
        const value = compilerErrorIndexValue(allocator, raw_text, "", &.{a.config.zig_path}) catch return error.OutOfMemory;
        return structured(allocator, value);
    }
    var list = buildExplainCommand(allocator, args, a) catch |err| return explainCommandSetupError(a, allocator, "zig_compile_error_index", args, err);
    defer {
        for (list.owned_paths.items) |path| allocator.free(path);
        list.owned_paths.deinit(allocator);
        list.argv.deinit(allocator);
    }
    a.command_calls += 1;
    const result = command.run(allocator, a.io, a.workspace.root, list.argv.items, toolTimeout(a, args)) catch |err| {
        a.tool_errors += 1;
        return backendErrorResult(allocator, "zig", "compile_error_index", err, "confirm --zig-path is executable or pass captured compiler output as text");
    };
    defer result.deinit(allocator);

    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "ok", .{ .bool = result.succeeded() });
    try obj.put(allocator, "command", try commandResultValue(allocator, "zig compile error index", list.argv.items, a.workspace.root, toolTimeout(a, args), result));
    try obj.put(allocator, "index", try compilerErrorIndexValue(allocator, result.stderr, result.stdout, list.argv.items));
    return structured(allocator, .{ .object = obj });
}

const ExplainCommand = struct {
    argv: std.ArrayList([]const u8),
    owned_paths: std.ArrayList([]const u8),
    mode: []const u8,
};

const ExplainCommandError = mcp.tools.ToolError || error{WorkspacePathRejected};

fn buildExplainCommand(allocator: std.mem.Allocator, args: ?std.json.Value, a: *App) ExplainCommandError!ExplainCommand {
    const mode = argString(args, "command") orelse if (argString(args, "file") != null) "check" else "build-test";
    var list: std.ArrayList([]const u8) = .empty;
    var owned_paths: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (owned_paths.items) |path| allocator.free(path);
        owned_paths.deinit(allocator);
        list.deinit(allocator);
    }
    list.append(allocator, a.config.zig_path) catch return error.OutOfMemory;

    if (std.mem.eql(u8, mode, "check")) {
        const file = argString(args, "file") orelse return error.InvalidArguments;
        const resolved = a.workspace.resolve(file) catch return error.WorkspacePathRejected;
        owned_paths.append(allocator, resolved) catch return error.OutOfMemory;
        list.append(allocator, "ast-check") catch return error.OutOfMemory;
        list.append(allocator, resolved) catch return error.OutOfMemory;
    } else if (std.mem.eql(u8, mode, "test")) {
        if (argString(args, "file")) |file| {
            const resolved = a.workspace.resolve(file) catch return error.WorkspacePathRejected;
            owned_paths.append(allocator, resolved) catch return error.OutOfMemory;
            list.append(allocator, "test") catch return error.OutOfMemory;
            list.append(allocator, resolved) catch return error.OutOfMemory;
        } else {
            list.append(allocator, "build") catch return error.OutOfMemory;
            list.append(allocator, "test") catch return error.OutOfMemory;
        }
    } else if (std.mem.eql(u8, mode, "build")) {
        list.append(allocator, "build") catch return error.OutOfMemory;
    } else if (std.mem.eql(u8, mode, "build-test")) {
        list.append(allocator, "build") catch return error.OutOfMemory;
        list.append(allocator, "test") catch return error.OutOfMemory;
    } else if (std.mem.eql(u8, mode, "fmt-check")) {
        const file = argString(args, "file") orelse ".";
        const resolved = a.workspace.resolve(file) catch return error.WorkspacePathRejected;
        owned_paths.append(allocator, resolved) catch return error.OutOfMemory;
        list.append(allocator, "fmt") catch return error.OutOfMemory;
        list.append(allocator, "--check") catch return error.OutOfMemory;
        list.append(allocator, resolved) catch return error.OutOfMemory;
    } else {
        return error.InvalidArguments;
    }

    const extra = try splitToolArgs(allocator, argString(args, "args"));
    defer freeArgList(allocator, extra);
    list.appendSlice(allocator, extra) catch return error.OutOfMemory;
    return .{ .argv = list, .owned_paths = owned_paths, .mode = mode };
}

fn explainCommandSetupError(a: *App, allocator: std.mem.Allocator, tool_name: []const u8, args: ?std.json.Value, err: anyerror) mcp.tools.ToolError!mcp.tools.ToolResult {
    return switch (err) {
        error.WorkspacePathRejected => if (argString(args, "file")) |file|
            workspacePathErrorResult(a, allocator, tool_name, file, error.PathOutsideWorkspace)
        else
            error.PermissionDenied,
        error.InvalidArguments => error.InvalidArguments,
        error.OutOfMemory => error.OutOfMemory,
        else => error.ExecutionFailed,
    };
}

fn compilerErrorIndexValue(allocator: std.mem.Allocator, stderr: []const u8, stdout: []const u8, argv: []const []const u8) !std.json.Value {
    const insights = try compilerInsightsValue(allocator, stdout, stderr, argv);
    const insights_obj = switch (insights) {
        .object => |o| o,
        else => return insights,
    };
    var files = std.json.Array.init(allocator);
    const findings = switch (insights_obj.get("findings") orelse .null) {
        .array => |a| a,
        else => std.json.Array.init(allocator),
    };
    for (findings.items) |finding| {
        const finding_obj = switch (finding) {
            .object => |o| o,
            else => continue,
        };
        const path = switch (finding_obj.get("path") orelse .null) {
            .string => |s| s,
            else => "(unlocated)",
        };
        var found_index: ?usize = null;
        for (files.items, 0..) |file_value, index| {
            const file_obj = switch (file_value) {
                .object => |o| o,
                else => continue,
            };
            const existing = switch (file_obj.get("path") orelse .null) {
                .string => |s| s,
                else => continue,
            };
            if (std.mem.eql(u8, existing, path)) {
                found_index = index;
                break;
            }
        }
        if (found_index) |index| {
            var file_obj = files.items[index].object;
            var file_findings = file_obj.get("findings").?.array;
            try file_findings.append(finding);
            try file_obj.put(allocator, "findings", .{ .array = file_findings });
            try file_obj.put(allocator, "count", .{ .integer = @intCast(file_findings.items.len) });
            files.items[index] = .{ .object = file_obj };
        } else {
            var file_findings = std.json.Array.init(allocator);
            try file_findings.append(finding);
            var file_obj = std.json.ObjectMap.empty;
            try file_obj.put(allocator, "path", try ownedString(allocator, path));
            try file_obj.put(allocator, "count", .{ .integer = 1 });
            try file_obj.put(allocator, "findings", .{ .array = file_findings });
            try files.append(.{ .object = file_obj });
        }
    }

    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zig_compile_error_index" });
    try obj.put(allocator, "summary", insights);
    try obj.put(allocator, "files", .{ .array = files });
    try obj.put(allocator, "file_count", .{ .integer = @intCast(files.items.len) });
    return .{ .object = obj };
}

fn zigExplainErrors(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    var list = buildExplainCommand(allocator, args, a) catch |err| return explainCommandSetupError(a, allocator, "zig_explain_errors", args, err);
    defer {
        for (list.owned_paths.items) |path| allocator.free(path);
        list.owned_paths.deinit(allocator);
        list.argv.deinit(allocator);
    }

    a.command_calls += 1;
    const result = command.run(allocator, a.io, a.workspace.root, list.argv.items, toolTimeout(a, args)) catch |err| {
        a.tool_errors += 1;
        return backendErrorResult(allocator, "zig", "explain_errors", err, "confirm --zig-path is executable or narrow the command arguments");
    };
    defer result.deinit(allocator);

    const command_value = commandResultValue(allocator, "zig explain errors", list.argv.items, a.workspace.root, toolTimeout(a, args), result) catch return error.OutOfMemory;
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    obj.put(allocator, "mode", .{ .string = list.mode }) catch return error.OutOfMemory;
    obj.put(allocator, "ok", .{ .bool = result.succeeded() }) catch return error.OutOfMemory;
    if (command_value == .object) {
        if (command_value.object.get("diagnostics")) |diagnostics| {
            obj.put(allocator, "diagnostics", diagnostics) catch return error.OutOfMemory;
        }
    }
    obj.put(allocator, "command", command_value) catch return error.OutOfMemory;
    return structured(allocator, .{ .object = obj });
}

fn zigTranslateC(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const file = argString(args, "file") orelse return error.InvalidArguments;
    const resolved = a.workspace.resolve(file) catch |err| return workspacePathErrorResult(a, allocator, "zig_translate_c", file, err);
    defer allocator.free(resolved);
    const extra = try splitToolArgs(allocator, argString(args, "args"));
    defer freeArgList(allocator, extra);
    const base = &.{ a.config.zig_path, "translate-c", resolved };
    const argv = command.joinArgv(allocator, base, extra) catch return error.OutOfMemory;
    defer allocator.free(argv);
    return runAndFormatTimeout(a, allocator, argv, "zig translate-c", toolTimeout(a, args));
}

fn zigFormat(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const file = argString(args, "file") orelse return error.InvalidArguments;
    const apply = argBool(args, "apply", false);

    if (a.lsp_client != null and a.doc_state != null) {
        return zigFormatZls(a, allocator, args, apply);
    }

    const resolved = a.workspace.resolve(file) catch |err| return workspacePathErrorResult(a, allocator, "zig_format", file, err);
    defer allocator.free(resolved);
    if (apply) {
        return runAndFormatTimeout(a, allocator, &.{ a.config.zig_path, "fmt", resolved }, "zig fmt apply", toolTimeout(a, args));
    }

    const rel = a.workspace.relative(resolved);
    const preview_path = std.fs.path.join(allocator, &.{ ".zigar-cache", "format-preview", rel }) catch return error.OutOfMemory;
    defer allocator.free(preview_path);
    const input = a.workspace.readFileAlloc(a.io, file, 4 * 1024 * 1024) catch return error.ResourceNotFound;
    defer allocator.free(input);
    a.workspace.writeFile(a.io, preview_path, input) catch return error.ExecutionFailed;
    const preview_abs = a.workspace.resolve(preview_path) catch return error.ExecutionFailed;
    defer allocator.free(preview_abs);
    defer std.Io.Dir.cwd().deleteFile(a.io, preview_abs) catch {};
    const fmt = command.run(allocator, a.io, a.workspace.root, &.{ a.config.zig_path, "fmt", preview_abs }, a.config.timeout_ms) catch |err| {
        return backendErrorResult(allocator, "zig", "fmt_preview", err, "confirm --zig-path is executable and zig fmt can run in the configured workspace");
    };
    defer fmt.deinit(allocator);
    if (!fmt.succeeded()) {
        const output = command.formatRunResult(allocator, "zig fmt preview failed", fmt) catch return error.OutOfMemory;
        defer allocator.free(output);
        return errorText(allocator, output);
    }
    const formatted = a.workspace.readFileAlloc(a.io, preview_path, 4 * 1024 * 1024) catch return error.ExecutionFailed;
    defer allocator.free(formatted);
    const diff = lsp_edits.unifiedDiff(allocator, file, input, formatted) catch return error.ExecutionFailed;
    defer allocator.free(diff);
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    obj.put(allocator, "applied", .{ .bool = false }) catch return error.OutOfMemory;
    obj.put(allocator, "file", .{ .string = file }) catch return error.OutOfMemory;
    obj.put(allocator, "source_hash", .{ .string = lsp_edits.hashHex(allocator, input) catch return error.OutOfMemory }) catch return error.OutOfMemory;
    obj.put(allocator, "updated_hash", .{ .string = lsp_edits.hashHex(allocator, formatted) catch return error.OutOfMemory }) catch return error.OutOfMemory;
    obj.put(allocator, "diff", .{ .string = diff }) catch return error.OutOfMemory;
    obj.put(allocator, "formatted", .{ .string = formatted }) catch return error.OutOfMemory;
    obj.put(allocator, "preview_retained", .{ .bool = false }) catch return error.OutOfMemory;
    return structured(allocator, .{ .object = obj });
}

fn zigFormatCheck(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const path = argString(args, "path") orelse return error.InvalidArguments;
    const resolved = a.workspace.resolve(path) catch |err| return workspacePathErrorResult(a, allocator, "zig_format_check", path, err);
    defer allocator.free(resolved);
    return runAndFormatTimeout(a, allocator, &.{ a.config.zig_path, "fmt", "--check", resolved }, "zig fmt --check", toolTimeout(a, args));
}

fn zigPatchPreview(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const file = argString(args, "file") orelse return error.InvalidArguments;
    const content = argString(args, "content") orelse return error.InvalidArguments;
    const apply = argBool(args, "apply", false);
    const resolved = a.workspace.resolve(file) catch |err| return workspacePathErrorResult(a, allocator, "zig_patch_preview", file, err);
    defer allocator.free(resolved);
    const rel = a.workspace.relative(resolved);
    const source = a.workspace.readFileAlloc(a.io, rel, 4 * 1024 * 1024) catch return error.ResourceNotFound;
    defer allocator.free(source);
    const diff = lsp_edits.unifiedDiff(allocator, rel, source, content) catch return error.ExecutionFailed;
    defer allocator.free(diff);
    if (apply) a.workspace.writeFile(a.io, rel, content) catch return error.ExecutionFailed;

    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zig_patch_preview" });
    try obj.put(allocator, "applied", .{ .bool = apply });
    try obj.put(allocator, "preview_only", .{ .bool = !apply });
    try obj.put(allocator, "requires_apply", .{ .bool = !apply });
    try obj.put(allocator, "file", .{ .string = rel });
    try obj.put(allocator, "source_hash", .{ .string = try lsp_edits.hashHex(allocator, source) });
    try obj.put(allocator, "updated_hash", .{ .string = try lsp_edits.hashHex(allocator, content) });
    try obj.put(allocator, "changed", .{ .bool = !std.mem.eql(u8, source, content) });
    try obj.put(allocator, "would_write", .{ .bool = !apply and !std.mem.eql(u8, source, content) });
    try obj.put(allocator, "diff", .{ .string = diff });
    return structured(allocator, .{ .object = obj });
}

fn zlsUnavailable(a: *App, allocator: std.mem.Allocator) mcp.tools.ToolError!mcp.tools.ToolResult {
    return backendUnavailableResult(
        allocator,
        "zls",
        "lsp_session",
        a.config.zls_path,
        a.zls_status,
        "confirm --zls-path points to a ZLS build compatible with the configured Zig version, then restart the MCP client",
    );
}

fn zlsFileUri(a: *App, allocator: std.mem.Allocator, file: []const u8) ![]const u8 {
    try zls_session.ensureReady(a);
    const client = a.lsp_client orelse return error.NotConnected;
    const doc_state = a.doc_state orelse return error.NotConnected;
    const resolved = try a.workspace.resolve(file);
    defer allocator.free(resolved);
    return doc_state.ensureOpen(client, resolved, allocator);
}

fn zlsFileUriFromArgs(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) ![]const u8 {
    const file = argString(args, "file") orelse return error.InvalidArguments;
    if (argString(args, "content")) |content| {
        try zls_session.ensureReady(a);
        const client = a.lsp_client orelse return error.NotConnected;
        const doc_state = a.doc_state orelse return error.NotConnected;
        const resolved = try a.workspace.resolve(file);
        defer allocator.free(resolved);
        return doc_state.syncText(client, resolved, content, allocator);
    }
    return zlsFileUri(a, allocator, file);
}

fn zlsSetupErrorResult(a: *App, allocator: std.mem.Allocator, operation: []const u8, file: ?[]const u8, err: anyerror) mcp.tools.ToolError!mcp.tools.ToolResult {
    switch (err) {
        error.InvalidArguments => return error.InvalidArguments,
        error.PathOutsideWorkspace, error.EmptyPath => {
            if (file) |path| return workspacePathErrorResult(a, allocator, operation, path, err);
            return error.InvalidArguments;
        },
        error.NotConnected => return zlsUnavailable(a, allocator),
        error.DocumentTooLarge => return errorText(allocator, "ZLS document sync rejected content larger than zigar's per-document memory budget. Save the file on disk and call a file-based tool, or send a smaller unsaved document."),
        error.OpenDocumentLimitExceeded => return errorText(allocator, "ZLS document sync rejected the document because zigar reached its open-document budget. Close unused documents with zig_document_close and retry."),
        else => return backendErrorResult(
            allocator,
            "zls",
            operation,
            err,
            "confirm --zls-path points to a compatible ZLS binary and retry; command-backed Zig tools remain available without ZLS",
        ),
    }
}

fn lspResultJson(allocator: std.mem.Allocator, response: []const u8) ![]const u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, response, .{});
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return allocator.dupe(u8, response),
    };
    const value = obj.get("result") orelse obj.get("error") orelse parsed.value;
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    try std.json.Stringify.value(value, .{ .whitespace = .indent_2 }, &aw.writer);
    return try aw.toOwnedSlice();
}

fn lspStructuredValue(allocator: std.mem.Allocator, method: []const u8, response: []const u8) !std.json.Value {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, response, .{});
    defer parsed.deinit();

    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "method", .{ .string = method });

    const response_obj = switch (parsed.value) {
        .object => |o| o,
        else => {
            try obj.put(allocator, "ok", .{ .bool = false });
            try obj.put(allocator, "raw", try json_result.cloneValue(allocator, parsed.value));
            return .{ .object = obj };
        },
    };

    if (response_obj.get("error")) |err_value| {
        try obj.put(allocator, "ok", .{ .bool = false });
        try obj.put(allocator, "error", try json_result.cloneValue(allocator, err_value));
    } else {
        try obj.put(allocator, "ok", .{ .bool = true });
        const result = response_obj.get("result") orelse .null;
        try obj.put(allocator, "result", try json_result.cloneValue(allocator, result));
        if (std.mem.eql(u8, method, "textDocument/diagnostic")) {
            try obj.put(allocator, "diagnostics", try lspDiagnosticsInsightsValue(allocator, result));
        }
    }
    return .{ .object = obj };
}

fn lspStructuredTool(allocator: std.mem.Allocator, method: []const u8, response: []const u8) mcp.tools.ToolError!mcp.tools.ToolResult {
    const value = lspStructuredValue(allocator, method, response) catch return error.ExecutionFailed;
    return structured(allocator, value);
}

fn lspHasError(allocator: std.mem.Allocator, response: []const u8) bool {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, response, .{}) catch return true;
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return true,
    };
    return obj.get("error") != null;
}

fn zigHover(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return zlsPositionRequest(a, allocator, args, "textDocument/hover");
}

fn zigDefinition(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return zlsPositionRequest(a, allocator, args, "textDocument/definition");
}

fn zigReferences(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    if (requireZlsCapability(a, allocator, "textDocument/references")) |result| return result;
    const file_uri = zlsFileUriFromArgs(a, allocator, args) catch |err| return zlsSetupErrorResult(a, allocator, "textDocument/references", argString(args, "file"), err);
    defer allocator.free(file_uri);
    const client = a.lsp_client orelse return zlsUnavailable(a, allocator);
    const Params = struct {
        textDocument: struct { uri: []const u8 },
        position: struct { line: i64, character: i64 },
        context: struct { includeDeclaration: bool },
    };
    a.zls_requests += 1;
    const response = client.sendRequest(allocator, "textDocument/references", Params{
        .textDocument = .{ .uri = file_uri },
        .position = .{ .line = argInt(args, "line", 0), .character = argInt(args, "character", 0) },
        .context = .{ .includeDeclaration = argBool(args, "include_declaration", true) },
    }) catch |err| return backendErrorResult(allocator, "zls", "textDocument/references", err, "ZLS request failed; check zigar_workspace_info and zigar_doctor for session status");
    defer allocator.free(response);
    return lspStructuredTool(allocator, "textDocument/references", response);
}

fn zigCompletion(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return zlsPositionRequest(a, allocator, args, "textDocument/completion");
}

fn zigSignatureHelp(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return zlsPositionRequest(a, allocator, args, "textDocument/signatureHelp");
}

fn zlsPositionRequest(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value, method: []const u8) mcp.tools.ToolError!mcp.tools.ToolResult {
    if (requireZlsCapability(a, allocator, method)) |result| return result;
    const file_uri = zlsFileUriFromArgs(a, allocator, args) catch |err| return zlsSetupErrorResult(a, allocator, method, argString(args, "file"), err);
    defer allocator.free(file_uri);
    const client = a.lsp_client orelse return zlsUnavailable(a, allocator);
    const Params = struct {
        textDocument: struct { uri: []const u8 },
        position: struct { line: i64, character: i64 },
    };
    a.zls_requests += 1;
    const response = client.sendRequest(allocator, method, Params{
        .textDocument = .{ .uri = file_uri },
        .position = .{ .line = argInt(args, "line", 0), .character = argInt(args, "character", 0) },
    }) catch |err| return backendErrorResult(allocator, "zls", method, err, "ZLS request failed; check zigar_workspace_info and zigar_doctor for session status");
    defer allocator.free(response);
    return lspStructuredTool(allocator, method, response);
}

fn zigDocumentSymbols(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    if (requireZlsCapability(a, allocator, "textDocument/documentSymbol")) |result| return result;
    const file_uri = zlsFileUriFromArgs(a, allocator, args) catch |err| return zlsSetupErrorResult(a, allocator, "textDocument/documentSymbol", argString(args, "file"), err);
    defer allocator.free(file_uri);
    const client = a.lsp_client orelse return zigDeclSummary(a, allocator, args);
    const Params = struct { textDocument: struct { uri: []const u8 } };
    a.zls_requests += 1;
    const response = client.sendRequest(allocator, "textDocument/documentSymbol", Params{ .textDocument = .{ .uri = file_uri } }) catch |err| return backendErrorResult(allocator, "zls", "textDocument/documentSymbol", err, "ZLS request failed; fall back to zig_decl_summary_json if symbols are unavailable");
    defer allocator.free(response);
    return lspStructuredTool(allocator, "textDocument/documentSymbol", response);
}

fn zigCodeActions(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    if (requireZlsCapability(a, allocator, "textDocument/codeAction")) |result| return result;
    const file_uri = zlsFileUriFromArgs(a, allocator, args) catch |err| return zlsSetupErrorResult(a, allocator, "textDocument/codeAction", argString(args, "file"), err);
    defer allocator.free(file_uri);
    const client = a.lsp_client orelse return zlsUnavailable(a, allocator);
    const Params = struct {
        textDocument: struct { uri: []const u8 },
        range: struct {
            start: struct { line: i64, character: i64 },
            end: struct { line: i64, character: i64 },
        },
        context: struct { diagnostics: []const std.json.Value = &.{} },
    };
    a.zls_requests += 1;
    const response = client.sendRequest(allocator, "textDocument/codeAction", Params{
        .textDocument = .{ .uri = file_uri },
        .range = .{
            .start = .{ .line = argInt(args, "start_line", 0), .character = argInt(args, "start_char", 0) },
            .end = .{ .line = argInt(args, "end_line", 0), .character = argInt(args, "end_char", 0) },
        },
        .context = .{},
    }) catch |err| return backendErrorResult(allocator, "zls", "textDocument/codeAction", err, "ZLS request failed; check whether ZLS supports code actions for this file");
    defer allocator.free(response);
    return lspStructuredTool(allocator, "textDocument/codeAction", response);
}

fn zigCodeActionApply(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    if (requireZlsCapability(a, allocator, "textDocument/codeAction")) |result| return result;
    const file_uri = zlsFileUriFromArgs(a, allocator, args) catch |err| return zlsSetupErrorResult(a, allocator, "textDocument/codeAction", argString(args, "file"), err);
    defer allocator.free(file_uri);
    const client = a.lsp_client orelse return zlsUnavailable(a, allocator);
    const Params = struct {
        textDocument: struct { uri: []const u8 },
        range: struct {
            start: struct { line: i64, character: i64 },
            end: struct { line: i64, character: i64 },
        },
        context: struct { diagnostics: []const std.json.Value = &.{} },
    };
    a.zls_requests += 1;
    const response = client.sendRequest(allocator, "textDocument/codeAction", Params{
        .textDocument = .{ .uri = file_uri },
        .range = .{
            .start = .{ .line = argInt(args, "start_line", 0), .character = argInt(args, "start_char", 0) },
            .end = .{ .line = argInt(args, "end_line", 0), .character = argInt(args, "end_char", 0) },
        },
        .context = .{},
    }) catch |err| return backendErrorResult(allocator, "zls", "textDocument/codeAction", err, "ZLS request failed; check whether ZLS supports code actions for this file");
    defer allocator.free(response);

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, response, .{}) catch return error.ExecutionFailed;
    defer parsed.deinit();
    const result = responseResult(parsed.value) orelse return error.InvalidArguments;
    const actions = switch (result) {
        .array => |array| array,
        else => return error.InvalidArguments,
    };
    const action_index = argInt(args, "action_index", -1);
    if (action_index < 0 or action_index >= actions.items.len) return error.InvalidArguments;
    const action = actions.items[@intCast(action_index)];
    const action_obj = switch (action) {
        .object => |o| o,
        else => return error.InvalidArguments,
    };

    var out = std.json.ObjectMap.empty;
    errdefer out.deinit(allocator);
    out.put(allocator, "selected_index", .{ .integer = action_index }) catch return error.OutOfMemory;
    out.put(allocator, "action", json_result.cloneValue(allocator, action) catch return error.OutOfMemory) catch return error.OutOfMemory;
    out.put(allocator, "applied", .{ .bool = argBool(args, "apply", false) }) catch return error.OutOfMemory;

    if (action_obj.get("edit")) |edit| {
        out.put(allocator, "workspace_edit", workspaceEditValue(a, allocator, edit, argBool(args, "apply", false)) catch return error.ExecutionFailed) catch return error.OutOfMemory;
    } else if (action_obj.get("command")) |cmd| {
        out.put(allocator, "command", json_result.cloneValue(allocator, cmd) catch return error.OutOfMemory) catch return error.OutOfMemory;
        const cmd_obj = switch (cmd) {
            .object => |o| o,
            else => {
                out.put(allocator, "note", .{ .string = "code action command has an invalid shape" }) catch return error.OutOfMemory;
                return structured(allocator, .{ .object = out });
            },
        };
        const command_name = switch (cmd_obj.get("command") orelse .null) {
            .string => |s| s,
            else => "",
        };
        if (argBool(args, "apply", false) and isAllowedZlsCommand(command_name)) {
            const ExecuteParams = struct {
                command: []const u8,
                arguments: ?std.json.Value = null,
            };
            a.zls_requests += 1;
            const exec_response = client.sendRequest(allocator, "workspace/executeCommand", ExecuteParams{
                .command = command_name,
                .arguments = cmd_obj.get("arguments"),
            }) catch |err| return backendErrorResult(allocator, "zls", "workspace/executeCommand", err, "ZLS command execution failed; retry after checking the ZLS session status");
            defer allocator.free(exec_response);
            out.put(allocator, "execute_response", lspStructuredValue(allocator, "workspace/executeCommand", exec_response) catch return error.ExecutionFailed) catch return error.OutOfMemory;
        } else if (argBool(args, "apply", false)) {
            out.put(allocator, "note", .{ .string = "code action command is not on zigar's explicit allowlist" }) catch return error.OutOfMemory;
        } else {
            out.put(allocator, "note", .{ .string = "code action contains a command; pass apply=true to execute only if it is allowlisted" }) catch return error.OutOfMemory;
        }
    } else {
        out.put(allocator, "note", .{ .string = "code action has no workspace edit" }) catch return error.OutOfMemory;
    }
    return structured(allocator, .{ .object = out });
}

fn isAllowedZlsCommand(command_name: []const u8) bool {
    return std.mem.eql(u8, command_name, "source.organizeImports") or
        std.mem.eql(u8, command_name, "zls.organizeImports") or
        std.mem.eql(u8, command_name, "zls.applyCodeAction");
}

fn zigDocumentOpen(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const file = argString(args, "file") orelse return error.InvalidArguments;
    const content = argString(args, "content") orelse return error.InvalidArguments;
    zls_session.ensureReady(a) catch return error.ExecutionFailed;
    const client = a.lsp_client orelse return zlsUnavailable(a, allocator);
    const doc_state = a.doc_state orelse return zlsUnavailable(a, allocator);
    const resolved = a.workspace.resolve(file) catch |err| return workspacePathErrorResult(a, allocator, "zig_document_open", file, err);
    defer allocator.free(resolved);
    const uri = doc_state.syncText(client, resolved, content, allocator) catch |err| return zlsSetupErrorResult(a, allocator, "zig_document_open", file, err);
    defer allocator.free(uri);

    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    obj.put(allocator, "uri", .{ .string = uri }) catch return error.OutOfMemory;
    obj.put(allocator, "version", .{ .integer = doc_state.versionForUri(uri) orelse 0 }) catch return error.OutOfMemory;
    obj.put(allocator, "open", .{ .bool = true }) catch return error.OutOfMemory;
    return structured(allocator, .{ .object = obj });
}

fn zigDocumentClose(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const file = argString(args, "file") orelse return error.InvalidArguments;
    zls_session.ensureReady(a) catch return error.ExecutionFailed;
    const client = a.lsp_client orelse return zlsUnavailable(a, allocator);
    const doc_state = a.doc_state orelse return zlsUnavailable(a, allocator);
    const resolved = a.workspace.resolve(file) catch |err| return workspacePathErrorResult(a, allocator, "zig_document_close", file, err);
    defer allocator.free(resolved);
    const uri = uri_util.pathToUri(allocator, resolved) catch return error.OutOfMemory;
    defer allocator.free(uri);
    doc_state.closeDoc(client, uri) catch return error.ExecutionFailed;

    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    obj.put(allocator, "uri", .{ .string = uri }) catch return error.OutOfMemory;
    obj.put(allocator, "open", .{ .bool = false }) catch return error.OutOfMemory;
    return structured(allocator, .{ .object = obj });
}

fn zigDocumentStatus(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const file = argString(args, "file") orelse return error.InvalidArguments;
    const resolved = a.workspace.resolve(file) catch |err| return workspacePathErrorResult(a, allocator, "zig_document_status", file, err);
    defer allocator.free(resolved);
    const uri = uri_util.pathToUri(allocator, resolved) catch return error.OutOfMemory;
    defer allocator.free(uri);

    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    obj.put(allocator, "file", .{ .string = file }) catch return error.OutOfMemory;
    obj.put(allocator, "uri", .{ .string = uri }) catch return error.OutOfMemory;
    if (a.doc_state) |doc_state| {
        if (doc_state.statusForUri(uri)) |status| {
            obj.put(allocator, "open", .{ .bool = true }) catch return error.OutOfMemory;
            obj.put(allocator, "version", .{ .integer = status.version }) catch return error.OutOfMemory;
            obj.put(allocator, "dirty", .{ .bool = status.dirty }) catch return error.OutOfMemory;
            obj.put(allocator, "content_hash", .{ .string = std.fmt.allocPrint(allocator, "{x:0>16}", .{status.content_hash}) catch return error.OutOfMemory }) catch return error.OutOfMemory;
            obj.put(allocator, "content_bytes", .{ .integer = @intCast(status.content_bytes) }) catch return error.OutOfMemory;
            obj.put(allocator, "retained_content_bytes", .{ .integer = @intCast(status.retained_content_bytes) }) catch return error.OutOfMemory;
            obj.put(allocator, "open_documents", .{ .integer = @intCast(status.open_documents) }) catch return error.OutOfMemory;
            obj.put(allocator, "max_document_bytes", .{ .integer = @intCast(status.max_document_bytes) }) catch return error.OutOfMemory;
            obj.put(allocator, "max_retained_content_bytes", .{ .integer = @intCast(status.max_retained_content_bytes) }) catch return error.OutOfMemory;
            obj.put(allocator, "max_open_documents", .{ .integer = @intCast(status.max_open_documents) }) catch return error.OutOfMemory;
            obj.put(allocator, "last_reopen", reopenSummaryValue(allocator, status.last_reopen) catch return error.OutOfMemory) catch return error.OutOfMemory;
            return structured(allocator, .{ .object = obj });
        }
    }
    obj.put(allocator, "open", .{ .bool = false }) catch return error.OutOfMemory;
    return structured(allocator, .{ .object = obj });
}

fn reopenSummaryValue(allocator: std.mem.Allocator, summary: zigar.document_state.DocumentState.ReopenSummary) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "attempted", .{ .integer = @intCast(summary.attempted) });
    try obj.put(allocator, "succeeded", .{ .integer = @intCast(summary.succeeded) });
    try obj.put(allocator, "skipped", .{ .integer = @intCast(summary.skipped) });
    try obj.put(allocator, "failed", .{ .integer = @intCast(summary.failed) });
    return .{ .object = obj };
}

fn zigRename(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    if (requireZlsCapability(a, allocator, "textDocument/rename")) |result| return result;
    const new_name = argString(args, "new_name") orelse return error.InvalidArguments;
    const file_uri = zlsFileUriFromArgs(a, allocator, args) catch |err| return zlsSetupErrorResult(a, allocator, "textDocument/rename", argString(args, "file"), err);
    defer allocator.free(file_uri);
    const client = a.lsp_client orelse return zlsUnavailable(a, allocator);
    const Params = struct {
        textDocument: struct { uri: []const u8 },
        position: struct { line: i64, character: i64 },
        newName: []const u8,
    };
    a.zls_requests += 1;
    const response = client.sendRequest(allocator, "textDocument/rename", Params{
        .textDocument = .{ .uri = file_uri },
        .position = .{ .line = argInt(args, "line", 0), .character = argInt(args, "character", 0) },
        .newName = new_name,
    }) catch |err| return backendErrorResult(allocator, "zls", "textDocument/rename", err, "ZLS rename failed; confirm the symbol location and ZLS session status");
    defer allocator.free(response);

    if (argBool(args, "apply", false)) {
        return workspaceEditToolResult(a, allocator, response, true);
    }

    return workspaceEditToolResult(a, allocator, response, false);
}

fn zigDiagnostics(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const file = argString(args, "file") orelse return error.InvalidArguments;
    const file_uri = zlsFileUriFromArgs(a, allocator, args) catch |err| return zlsSetupErrorResult(a, allocator, "zig_diagnostics", file, err);
    defer allocator.free(file_uri);
    const client = a.lsp_client orelse return zigCheck(a, allocator, args);

    const Params = struct { textDocument: struct { uri: []const u8 } };
    const pull = client.sendRequest(allocator, "textDocument/diagnostic", Params{ .textDocument = .{ .uri = file_uri } }) catch null;
    if (pull) |response| {
        defer allocator.free(response);
        if (!lspHasError(allocator, response)) {
            return lspStructuredTool(allocator, "textDocument/diagnostic", response);
        }
    }

    const wait_ms = @max(0, @min(argInt(args, "wait_ms", 500), 5000));
    waitForDiagnostics(a, client, file_uri, wait_ms);
    if (client.getDiagnostics(allocator, file_uri) catch null) |diagnostics| {
        defer allocator.free(diagnostics);
        const value = diagnosticsStructuredValue(allocator, diagnostics) catch return error.ExecutionFailed;
        return structured(allocator, value);
    }
    return zigCheck(a, allocator, args);
}

fn zigDiagnosticsAll(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const file = argString(args, "file") orelse return error.InvalidArguments;
    const file_uri = zlsFileUriFromArgs(a, allocator, args) catch |err| return zlsSetupErrorResult(a, allocator, "zig_diagnostics_all", file, err);
    defer allocator.free(file_uri);

    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    obj.put(allocator, "file", .{ .string = file }) catch return error.OutOfMemory;
    obj.put(allocator, "uri", .{ .string = file_uri }) catch return error.OutOfMemory;
    var sources = std.json.Array.init(allocator);

    if (a.lsp_client) |client| {
        const Params = struct { textDocument: struct { uri: []const u8 } };
        const pull = client.sendRequest(allocator, "textDocument/diagnostic", Params{ .textDocument = .{ .uri = file_uri } }) catch null;
        if (pull) |response| {
            defer allocator.free(response);
            sources.append(lspStructuredValue(allocator, "textDocument/diagnostic", response) catch return error.ExecutionFailed) catch return error.OutOfMemory;
        }

        const wait_ms = @max(0, @min(argInt(args, "wait_ms", 500), 5000));
        waitForDiagnostics(a, client, file_uri, wait_ms);
        if (client.getDiagnostics(allocator, file_uri) catch null) |diagnostics| {
            defer allocator.free(diagnostics);
            sources.append(diagnosticsStructuredValue(allocator, diagnostics) catch return error.ExecutionFailed) catch return error.OutOfMemory;
        }
    }

    const resolved = a.workspace.resolve(file) catch |err| return workspacePathErrorResult(a, allocator, "zig_diagnostics_all", file, err);
    defer allocator.free(resolved);
    const ast = command.run(allocator, a.io, a.workspace.root, &.{ a.config.zig_path, "ast-check", resolved }, toolTimeout(a, args)) catch |err| {
        var err_obj = std.json.ObjectMap.empty;
        err_obj.put(allocator, "method", .{ .string = "zig ast-check" }) catch return error.OutOfMemory;
        err_obj.put(allocator, "ok", .{ .bool = false }) catch return error.OutOfMemory;
        err_obj.put(allocator, "error", .{ .string = @errorName(err) }) catch return error.OutOfMemory;
        sources.append(.{ .object = err_obj }) catch return error.OutOfMemory;
        obj.put(allocator, "sources", .{ .array = sources }) catch return error.OutOfMemory;
        return structured(allocator, .{ .object = obj });
    };
    defer ast.deinit(allocator);
    sources.append(commandResultValue(allocator, "zig ast-check", &.{ a.config.zig_path, "ast-check", resolved }, a.workspace.root, toolTimeout(a, args), ast) catch return error.OutOfMemory) catch return error.OutOfMemory;
    obj.put(allocator, "sources", .{ .array = sources }) catch return error.OutOfMemory;
    return structured(allocator, .{ .object = obj });
}

fn zigDiagnosticsWorkspace(a: *App, allocator: std.mem.Allocator, _: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const client = a.lsp_client orelse return structuredText(allocator, "zig_diagnostics_workspace", "ZLS session is unavailable; no workspace diagnostics cache exists.");
    const snapshot = client.diagnosticsSnapshot(allocator) catch return error.ExecutionFailed;
    defer {
        for (snapshot) |item| allocator.free(item);
        allocator.free(snapshot);
    }

    var files = std.json.Array.init(allocator);
    var total: usize = 0;
    var errors: usize = 0;
    var warnings: usize = 0;
    var info: usize = 0;
    var hints: usize = 0;

    for (snapshot) |notification| {
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, notification, .{}) catch continue;
        const obj = switch (parsed.value) {
            .object => |o| o,
            else => continue,
        };
        const params = switch (obj.get("params") orelse .null) {
            .object => |o| o,
            else => continue,
        };
        const uri = switch (params.get("uri") orelse .null) {
            .string => |s| s,
            else => "",
        };
        const diagnostics = switch (params.get("diagnostics") orelse .null) {
            .array => |array| array,
            else => continue,
        };
        var file_errors: usize = 0;
        var file_warnings: usize = 0;
        var file_info: usize = 0;
        var file_hints: usize = 0;
        for (diagnostics.items) |diag| {
            total += 1;
            const diag_obj = switch (diag) {
                .object => |o| o,
                else => continue,
            };
            const severity = switch (diag_obj.get("severity") orelse .null) {
                .integer => |i| i,
                else => 0,
            };
            switch (severity) {
                1 => {
                    errors += 1;
                    file_errors += 1;
                },
                2 => {
                    warnings += 1;
                    file_warnings += 1;
                },
                3 => {
                    info += 1;
                    file_info += 1;
                },
                4 => {
                    hints += 1;
                    file_hints += 1;
                },
                else => {},
            }
        }
        var file_obj = std.json.ObjectMap.empty;
        file_obj.put(allocator, "uri", .{ .string = uri }) catch return error.OutOfMemory;
        file_obj.put(allocator, "total", .{ .integer = @intCast(diagnostics.items.len) }) catch return error.OutOfMemory;
        file_obj.put(allocator, "errors", .{ .integer = @intCast(file_errors) }) catch return error.OutOfMemory;
        file_obj.put(allocator, "warnings", .{ .integer = @intCast(file_warnings) }) catch return error.OutOfMemory;
        file_obj.put(allocator, "information", .{ .integer = @intCast(file_info) }) catch return error.OutOfMemory;
        file_obj.put(allocator, "hints", .{ .integer = @intCast(file_hints) }) catch return error.OutOfMemory;
        files.append(.{ .object = file_obj }) catch return error.OutOfMemory;
    }

    var out = std.json.ObjectMap.empty;
    errdefer out.deinit(allocator);
    out.put(allocator, "files", .{ .array = files }) catch return error.OutOfMemory;
    out.put(allocator, "total", .{ .integer = @intCast(total) }) catch return error.OutOfMemory;
    out.put(allocator, "errors", .{ .integer = @intCast(errors) }) catch return error.OutOfMemory;
    out.put(allocator, "warnings", .{ .integer = @intCast(warnings) }) catch return error.OutOfMemory;
    out.put(allocator, "information", .{ .integer = @intCast(info) }) catch return error.OutOfMemory;
    out.put(allocator, "hints", .{ .integer = @intCast(hints) }) catch return error.OutOfMemory;
    return structured(allocator, .{ .object = out });
}

fn zigFormatZls(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value, apply: bool) mcp.tools.ToolError!mcp.tools.ToolResult {
    if (requireZlsCapability(a, allocator, "textDocument/formatting")) |result| return result;
    const file_uri = zlsFileUriFromArgs(a, allocator, args) catch |err| return zlsSetupErrorResult(a, allocator, "textDocument/formatting", argString(args, "file"), err);
    defer allocator.free(file_uri);
    const client = a.lsp_client orelse return zlsUnavailable(a, allocator);
    const doc_state = a.doc_state orelse return zlsUnavailable(a, allocator);
    const Params = struct {
        textDocument: struct { uri: []const u8 },
        options: struct { tabSize: i64 = 4, insertSpaces: bool = true },
    };
    a.zls_requests += 1;
    const response = client.sendRequest(allocator, "textDocument/formatting", Params{
        .textDocument = .{ .uri = file_uri },
        .options = .{},
    }) catch |err| return backendErrorResult(allocator, "zls", "textDocument/formatting", err, "ZLS formatting failed; zig_format can fall back to zig fmt when the ZLS session is unavailable");
    defer allocator.free(response);

    if (apply) {
        const value = textEditToolValue(a, allocator, file_uri, response, true) catch return error.ExecutionFailed;
        doc_state.closeDoc(client, file_uri) catch {};
        return structuredOwned(allocator, value);
    }

    const value = textEditToolValue(a, allocator, file_uri, response, false) catch return error.ExecutionFailed;
    return structuredOwned(allocator, value);
}

fn waitForDiagnostics(a: *App, client: *LspClient, file_uri: []const u8, wait_ms: i64) void {
    var elapsed: i64 = 0;
    while (elapsed <= wait_ms) : (elapsed += 50) {
        if (client.getDiagnostics(a.allocator, file_uri) catch null) |diagnostics| {
            a.allocator.free(diagnostics);
            return;
        }
        if (elapsed == wait_ms) return;
        const step_ms = @min(@as(i64, 50), wait_ms - elapsed);
        if (step_ms <= 0) return;
        std.Io.Timeout.sleep(.{ .duration = .{ .raw = std.Io.Duration.fromMilliseconds(step_ms), .clock = .awake } }, a.io) catch return;
    }
}

fn diagnosticsStructuredValue(allocator: std.mem.Allocator, notification: []const u8) !std.json.Value {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, notification, .{});
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "method", .{ .string = "textDocument/publishDiagnostics" });
    try obj.put(allocator, "ok", .{ .bool = true });

    const notification_obj = switch (parsed.value) {
        .object => |o| o,
        else => {
            try obj.put(allocator, "raw", parsed.value);
            return .{ .object = obj };
        },
    };
    const params = notification_obj.get("params") orelse .null;
    try obj.put(allocator, "result", params);
    try obj.put(allocator, "diagnostics", try lspDiagnosticsInsightsValue(allocator, params));
    return .{ .object = obj };
}

fn lspDiagnosticsInsightsValue(allocator: std.mem.Allocator, value: std.json.Value) !std.json.Value {
    const value_obj = switch (value) {
        .object => |o| o,
        else => {
            var empty = std.json.ObjectMap.empty;
            try empty.put(allocator, "finding_count", .{ .integer = 0 });
            try empty.put(allocator, "findings", .{ .array = std.json.Array.init(allocator) });
            try empty.put(allocator, "primary", .null);
            try empty.put(allocator, "next_actions", .{ .array = std.json.Array.init(allocator) });
            return .{ .object = empty };
        },
    };
    const uri = switch (value_obj.get("uri") orelse .null) {
        .string => |s| s,
        else => null,
    };
    const items = value_obj.get("diagnostics") orelse value_obj.get("items") orelse std.json.Value{ .array = std.json.Array.init(allocator) };
    const item_array = switch (items) {
        .array => |a| a,
        else => std.json.Array.init(allocator),
    };

    var findings = std.json.Array.init(allocator);
    var error_count: i64 = 0;
    var warning_count: i64 = 0;
    var info_count: i64 = 0;
    var primary_message: ?[]const u8 = null;
    var primary_path: ?[]const u8 = uri;
    var primary_line: ?i64 = null;
    var primary_column: ?i64 = null;
    var primary_severity: []const u8 = "info";

    for (item_array.items) |item| {
        const item_obj = switch (item) {
            .object => |o| o,
            else => continue,
        };
        const message = switch (item_obj.get("message") orelse .null) {
            .string => |s| s,
            else => continue,
        };
        const severity_code = switch (item_obj.get("severity") orelse .null) {
            .integer => |i| i,
            else => 3,
        };
        const severity = lspSeverityName(severity_code);
        if (std.mem.eql(u8, severity, "error")) {
            error_count += 1;
        } else if (std.mem.eql(u8, severity, "warning")) {
            warning_count += 1;
        } else {
            info_count += 1;
        }
        const start = lspDiagnosticStart(item_obj.get("range") orelse .null);
        var finding = std.json.ObjectMap.empty;
        try finding.put(allocator, "source", .{ .string = "zls" });
        try finding.put(allocator, "severity", .{ .string = severity });
        try finding.put(allocator, "message", try ownedString(allocator, message));
        if (uri) |u| {
            try finding.put(allocator, "uri", try ownedString(allocator, u));
        } else {
            try finding.put(allocator, "uri", .null);
        }
        if (start.line) |line_no| {
            try finding.put(allocator, "line", .{ .integer = line_no });
        } else {
            try finding.put(allocator, "line", .null);
        }
        if (start.column) |col_no| {
            try finding.put(allocator, "column", .{ .integer = col_no });
        } else {
            try finding.put(allocator, "column", .null);
        }
        try findings.append(.{ .object = finding });

        if (primary_message == null or (std.mem.eql(u8, severity, "error") and !std.mem.eql(u8, primary_severity, "error"))) {
            primary_message = message;
            primary_line = start.line;
            primary_column = start.column;
            primary_severity = severity;
            primary_path = uri;
        }
    }

    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "finding_count", .{ .integer = @intCast(findings.items.len) });
    try obj.put(allocator, "error_count", .{ .integer = error_count });
    try obj.put(allocator, "warning_count", .{ .integer = warning_count });
    try obj.put(allocator, "info_count", .{ .integer = info_count });
    try obj.put(allocator, "findings", .{ .array = findings });
    if (primary_message) |message| {
        var primary = std.json.ObjectMap.empty;
        try primary.put(allocator, "source", .{ .string = "zls" });
        try primary.put(allocator, "severity", .{ .string = primary_severity });
        try primary.put(allocator, "message", try ownedString(allocator, message));
        if (primary_path) |path| {
            try primary.put(allocator, "uri", try ownedString(allocator, path));
        } else {
            try primary.put(allocator, "uri", .null);
        }
        if (primary_line) |line_no| {
            try primary.put(allocator, "line", .{ .integer = line_no });
        } else {
            try primary.put(allocator, "line", .null);
        }
        if (primary_column) |col_no| {
            try primary.put(allocator, "column", .{ .integer = col_no });
        } else {
            try primary.put(allocator, "column", .null);
        }
        try obj.put(allocator, "primary", .{ .object = primary });
        try obj.put(allocator, "category", .{ .string = classifyDiagnosticMessage(message) });
        try obj.put(allocator, "next_actions", try lspNextActions(allocator, primary_path, primary_line, primary_column, primary_severity, message));
    } else {
        try obj.put(allocator, "primary", .null);
        try obj.put(allocator, "category", .{ .string = "none" });
        try obj.put(allocator, "next_actions", .{ .array = std.json.Array.init(allocator) });
    }
    return .{ .object = obj };
}

const LspStart = struct {
    line: ?i64 = null,
    column: ?i64 = null,
};

fn lspDiagnosticStart(range_value: std.json.Value) LspStart {
    const range_obj = switch (range_value) {
        .object => |o| o,
        else => return .{},
    };
    const start_obj = switch (range_obj.get("start") orelse .null) {
        .object => |o| o,
        else => return .{},
    };
    const line_no = switch (start_obj.get("line") orelse .null) {
        .integer => |i| i + 1,
        else => null,
    };
    const col_no = switch (start_obj.get("character") orelse .null) {
        .integer => |i| i + 1,
        else => null,
    };
    return .{ .line = line_no, .column = col_no };
}

fn lspSeverityName(code: i64) []const u8 {
    return switch (code) {
        1 => "error",
        2 => "warning",
        3 => "info",
        4 => "hint",
        else => "info",
    };
}

fn lspNextActions(allocator: std.mem.Allocator, uri: ?[]const u8, line_no: ?i64, col_no: ?i64, severity: []const u8, message: []const u8) !std.json.Value {
    var actions = std.json.Array.init(allocator);
    if (uri) |u| {
        if (line_no) |line_value| {
            if (col_no) |col_value| {
                try actions.append(.{ .string = try std.fmt.allocPrint(allocator, "Open {s}:{d}:{d} and address the primary ZLS {s}: {s}", .{ u, line_value, col_value, severity, message }) });
            } else {
                try actions.append(.{ .string = try std.fmt.allocPrint(allocator, "Open {s}:{d} and address the primary ZLS {s}: {s}", .{ u, line_value, severity, message }) });
            }
        } else {
            try actions.append(.{ .string = try std.fmt.allocPrint(allocator, "Inspect {s} and address the primary ZLS {s}: {s}", .{ u, severity, message }) });
        }
    } else {
        try actions.append(.{ .string = try std.fmt.allocPrint(allocator, "Address the primary ZLS {s}: {s}", .{ severity, message }) });
    }
    try actions.append(try ownedString(allocator, "Rerun zig_diagnostics after the focused edit."));
    return .{ .array = actions };
}

fn textEditToolValue(a: *App, allocator: std.mem.Allocator, file_uri: []const u8, response: []const u8, apply: bool) !std.json.Value {
    const path = try uri_util.uriToPath(allocator, file_uri);
    defer allocator.free(path);
    const safe_path = try a.workspace.resolve(path);
    defer allocator.free(safe_path);
    const rel_view = a.workspace.relative(safe_path);
    const rel = try allocator.dupe(u8, rel_view);
    const source = try a.workspace.readFileAlloc(a.io, rel, 4 * 1024 * 1024);
    defer allocator.free(source);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, response, .{});
    defer parsed.deinit();
    const result = responseResult(parsed.value) orelse .null;
    const updated = if (result == .null) try allocator.dupe(u8, source) else try lsp_edits.applyTextEdits(allocator, source, result);
    var updated_moved = false;
    defer if (!updated_moved) allocator.free(updated);
    const diff = try lsp_edits.unifiedDiff(allocator, rel, source, updated);
    if (apply) try a.workspace.writeFile(a.io, rel, updated);

    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try putOwnedKey(allocator, &obj, "applied", .{ .bool = apply });
    try putOwnedKey(allocator, &obj, "file", .{ .string = rel });
    try putOwnedKey(allocator, &obj, "edit_count", .{ .integer = @intCast(lsp_edits.textEditCount(result)) });
    try putOwnedKey(allocator, &obj, "source_hash", .{ .string = try lsp_edits.hashHex(allocator, source) });
    try putOwnedKey(allocator, &obj, "updated_hash", .{ .string = try lsp_edits.hashHex(allocator, updated) });
    try putOwnedKey(allocator, &obj, "diff", .{ .string = diff });
    try putOwnedKey(allocator, &obj, "edits", try json_result.cloneValue(allocator, result));
    if (!apply) {
        try putOwnedKey(allocator, &obj, "formatted", .{ .string = updated });
        updated_moved = true;
    }
    return .{ .object = obj };
}

fn previewTextEditResponse(a: *App, allocator: std.mem.Allocator, file_uri: []const u8, response: []const u8) ![]u8 {
    const path = try uri_util.uriToPath(allocator, file_uri);
    defer allocator.free(path);
    const safe_path = try a.workspace.resolve(path);
    defer allocator.free(safe_path);
    const rel = a.workspace.relative(safe_path);
    const source = try a.workspace.readFileAlloc(a.io, rel, 4 * 1024 * 1024);
    defer allocator.free(source);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, response, .{});
    defer parsed.deinit();
    const result = responseResult(parsed.value) orelse return allocator.dupe(u8, source);
    if (result == .null) return allocator.dupe(u8, source);
    return lsp_edits.applyTextEdits(allocator, source, result);
}

fn applyTextEditResponseToFile(a: *App, allocator: std.mem.Allocator, file_uri: []const u8, response: []const u8) ![]u8 {
    const path = try uri_util.uriToPath(allocator, file_uri);
    defer allocator.free(path);
    const safe_path = try a.workspace.resolve(path);
    defer allocator.free(safe_path);
    const rel = a.workspace.relative(safe_path);
    const updated = try previewTextEditResponse(a, allocator, file_uri, response);
    defer allocator.free(updated);
    try a.workspace.writeFile(a.io, rel, updated);
    return std.fmt.allocPrint(allocator, "applied edits to {s}\n", .{rel});
}

fn workspaceEditToolResult(a: *App, allocator: std.mem.Allocator, response: []const u8, apply: bool) mcp.tools.ToolError!mcp.tools.ToolResult {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, response, .{}) catch return error.ExecutionFailed;
    defer parsed.deinit();
    const result = responseResult(parsed.value) orelse .null;
    const value = workspaceEditValue(a, allocator, result, apply) catch return error.ExecutionFailed;
    return structuredOwned(allocator, value);
}

fn workspaceEditValue(a: *App, allocator: std.mem.Allocator, result: std.json.Value, apply: bool) !std.json.Value {
    if (result == .null) {
        var empty = std.json.ObjectMap.empty;
        try putOwnedKey(allocator, &empty, "applied", .{ .bool = apply });
        try putOwnedKey(allocator, &empty, "affected_files", .{ .array = std.json.Array.init(allocator) });
        try putOwnedKey(allocator, &empty, "total_edits", .{ .integer = 0 });
        try putOwnedKey(allocator, &empty, "edit", .null);
        return .{ .object = empty };
    }
    const edit_obj = switch (result) {
        .object => |o| o,
        else => return error.InvalidTextEdit,
    };

    var files = std.json.Array.init(allocator);
    var total_edits: usize = 0;

    if (edit_obj.get("changes")) |changes| {
        if (changes == .object) {
            var it = changes.object.iterator();
            while (it.next()) |entry| {
                total_edits += lsp_edits.textEditCount(entry.value_ptr.*);
                try files.append(try workspaceEditFileValue(a, allocator, entry.key_ptr.*, entry.value_ptr.*, apply));
            }
        }
    }

    if (edit_obj.get("documentChanges")) |document_changes| {
        if (document_changes == .array) {
            for (document_changes.array.items) |change| {
                const change_obj = switch (change) {
                    .object => |o| o,
                    else => continue,
                };
                const text_doc = switch (change_obj.get("textDocument") orelse .null) {
                    .object => |o| o,
                    else => continue,
                };
                const uri = switch (text_doc.get("uri") orelse .null) {
                    .string => |s| s,
                    else => continue,
                };
                const edits = change_obj.get("edits") orelse continue;
                total_edits += lsp_edits.textEditCount(edits);
                try files.append(try workspaceEditFileValue(a, allocator, uri, edits, apply));
            }
        }
    }

    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try putOwnedKey(allocator, &obj, "applied", .{ .bool = apply });
    try putOwnedKey(allocator, &obj, "affected_files", .{ .array = files });
    try putOwnedKey(allocator, &obj, "total_edits", .{ .integer = @intCast(total_edits) });
    try putOwnedKey(allocator, &obj, "edit", try json_result.cloneValue(allocator, result));
    return .{ .object = obj };
}

fn workspaceEditFileValue(a: *App, allocator: std.mem.Allocator, uri: []const u8, edits: std.json.Value, apply: bool) !std.json.Value {
    const path = try uri_util.uriToPath(allocator, uri);
    defer allocator.free(path);
    const safe_path = try a.workspace.resolve(path);
    defer allocator.free(safe_path);
    const rel_view = a.workspace.relative(safe_path);
    const rel = try allocator.dupe(u8, rel_view);
    const source = try a.workspace.readFileAlloc(a.io, rel, 4 * 1024 * 1024);
    defer allocator.free(source);
    const updated = try lsp_edits.applyTextEdits(allocator, source, edits);
    defer allocator.free(updated);
    const diff = try lsp_edits.unifiedDiff(allocator, rel, source, updated);
    if (apply) {
        try a.workspace.writeFile(a.io, rel, updated);
        if (a.lsp_client) |client| {
            if (a.doc_state) |doc_state| doc_state.closeDoc(client, uri) catch {};
        }
    }

    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try putOwnedKey(allocator, &obj, "file", .{ .string = rel });
    try putOwnedKey(allocator, &obj, "edit_count", .{ .integer = @intCast(lsp_edits.textEditCount(edits)) });
    try putOwnedKey(allocator, &obj, "source_hash", .{ .string = try lsp_edits.hashHex(allocator, source) });
    try putOwnedKey(allocator, &obj, "updated_hash", .{ .string = try lsp_edits.hashHex(allocator, updated) });
    try putOwnedKey(allocator, &obj, "diff", .{ .string = diff });
    return .{ .object = obj };
}

fn applyEditsForUri(a: *App, allocator: std.mem.Allocator, uri: []const u8, edits: std.json.Value) !void {
    const path = try uri_util.uriToPath(allocator, uri);
    defer allocator.free(path);
    const safe_path = try a.workspace.resolve(path);
    defer allocator.free(safe_path);
    const rel = a.workspace.relative(safe_path);
    const source = try a.workspace.readFileAlloc(a.io, rel, 4 * 1024 * 1024);
    defer allocator.free(source);
    const updated = try lsp_edits.applyTextEdits(allocator, source, edits);
    defer allocator.free(updated);
    try a.workspace.writeFile(a.io, rel, updated);
    if (a.lsp_client) |client| {
        if (a.doc_state) |doc_state| doc_state.closeDoc(client, uri) catch {};
    }
}

fn responseResult(value: std.json.Value) ?std.json.Value {
    const obj = switch (value) {
        .object => |o| o,
        else => return null,
    };
    return obj.get("result");
}

fn zigBuiltinList(_: *App, allocator: std.mem.Allocator, _: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const output = docs.builtinList(allocator) catch return error.OutOfMemory;
    defer allocator.free(output);
    return structuredText(allocator, "zig_builtin_list", output);
}

fn zigBuiltinListJson(_: *App, allocator: std.mem.Allocator, _: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    var items = std.json.Array.init(allocator);
    for (docs.builtins) |item| {
        var obj = std.json.ObjectMap.empty;
        obj.put(allocator, "name", .{ .string = item.name }) catch return error.OutOfMemory;
        obj.put(allocator, "signature", .{ .string = item.signature }) catch return error.OutOfMemory;
        obj.put(allocator, "summary", .{ .string = item.summary }) catch return error.OutOfMemory;
        items.append(.{ .object = obj }) catch return error.OutOfMemory;
    }
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    obj.put(allocator, "builtins", .{ .array = items }) catch return error.OutOfMemory;
    return structured(allocator, .{ .object = obj });
}

fn zigBuiltinDoc(_: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const query = argString(args, "query") orelse return error.InvalidArguments;
    const output = docs.builtinDoc(allocator, query) catch return error.OutOfMemory;
    defer allocator.free(output);
    return structuredText(allocator, "zig_builtin_doc", output);
}

fn zigStdSearch(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const query = argString(args, "query") orelse return error.InvalidArguments;
    const std_dir = zigEnvValue(a, allocator, "std_dir") catch return error.ExecutionFailed;
    defer allocator.free(std_dir);
    const output = docs.searchStd(allocator, a.io, std_dir, query, @intCast(@max(1, argInt(args, "limit", 20)))) catch return error.ExecutionFailed;
    defer allocator.free(output);
    return structuredText(allocator, "zig_std_search", output);
}

fn zigStdSearchJson(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const query = argString(args, "query") orelse return error.InvalidArguments;
    const std_dir = zigEnvValue(a, allocator, "std_dir") catch return error.ExecutionFailed;
    defer allocator.free(std_dir);
    return searchZigFilesJson(allocator, a.io, std_dir, "std", query, @intCast(@max(1, argInt(args, "limit", 20))));
}

fn searchZigFilesJson(allocator: std.mem.Allocator, io: std.Io, root: []const u8, label: []const u8, query: []const u8, limit: usize) mcp.tools.ToolError!mcp.tools.ToolResult {
    const lower_query = asciiLowerAllocLocal(allocator, query) catch return error.OutOfMemory;
    defer allocator.free(lower_query);
    var matches = std.json.Array.init(allocator);
    var dir = std.Io.Dir.openDirAbsolute(io, root, .{ .iterate = true }) catch return error.ExecutionFailed;
    defer dir.close(io);
    var walker = dir.walk(allocator) catch return error.ExecutionFailed;
    defer walker.deinit();
    var count: usize = 0;
    var skipped_files: usize = 0;
    var walk_errors: usize = 0;
    while (true) {
        const maybe_entry = walker.next(io) catch {
            walk_errors += 1;
            break;
        };
        const entry = maybe_entry orelse break;
        if (count >= limit) break;
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".zig")) continue;
        const abs = std.fs.path.join(allocator, &.{ root, entry.path }) catch return error.OutOfMemory;
        defer allocator.free(abs);
        const contents = std.Io.Dir.cwd().readFileAlloc(io, abs, allocator, .limited(512 * 1024)) catch {
            skipped_files += 1;
            continue;
        };
        defer allocator.free(contents);
        const lower = asciiLowerAllocLocal(allocator, contents) catch return error.OutOfMemory;
        defer allocator.free(lower);
        const hit = std.mem.indexOf(u8, lower, lower_query) orelse continue;
        count += 1;
        var obj = std.json.ObjectMap.empty;
        obj.put(allocator, "root", .{ .string = label }) catch return error.OutOfMemory;
        obj.put(allocator, "path", ownedString(allocator, entry.path) catch return error.OutOfMemory) catch return error.OutOfMemory;
        obj.put(allocator, "line", .{ .integer = @intCast(lineNumberLocal(contents, hit)) }) catch return error.OutOfMemory;
        obj.put(allocator, "snippet", ownedString(allocator, lineAtLocal(contents, hit)) catch return error.OutOfMemory) catch return error.OutOfMemory;
        matches.append(.{ .object = obj }) catch return error.OutOfMemory;
    }
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    obj.put(allocator, "query", .{ .string = query }) catch return error.OutOfMemory;
    obj.put(allocator, "skipped_files", .{ .integer = @intCast(skipped_files) }) catch return error.OutOfMemory;
    obj.put(allocator, "walk_errors", .{ .integer = @intCast(walk_errors) }) catch return error.OutOfMemory;
    obj.put(allocator, "matches", .{ .array = matches }) catch return error.OutOfMemory;
    return structured(allocator, .{ .object = obj });
}

fn zigStdItem(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const name = argString(args, "name") orelse return error.InvalidArguments;
    return zigStdSearch(a, allocator, makeArgs2(allocator, "query", name, "limit", argInt(args, "limit", 20)) catch return error.OutOfMemory);
}

fn zigLangRefSearch(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const query = argString(args, "query") orelse return error.InvalidArguments;
    const lib_dir = zigEnvValue(a, allocator, "lib_dir") catch return error.ExecutionFailed;
    defer allocator.free(lib_dir);
    const output = docs.langRefSearch(allocator, a.io, lib_dir, query, @intCast(@max(1, argInt(args, "limit", 20)))) catch return error.ExecutionFailed;
    defer allocator.free(output);
    return structuredText(allocator, "zig_lang_ref_search", output);
}

fn readSourceArg(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) !struct { name: []const u8, bytes: []u8 } {
    _ = allocator;
    const file = argString(args, "file") orelse return error.InvalidArguments;
    const bytes = try a.workspace.readFileAlloc(a.io, file, 4 * 1024 * 1024);
    return .{ .name = file, .bytes = bytes };
}

fn zigImportGraph(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const output = analysis.importGraph(allocator, a.io, a.workspace.root, @intCast(@max(1, argInt(args, "limit", 200)))) catch return error.ExecutionFailed;
    defer allocator.free(output);
    return structuredText(allocator, "zig_import_graph", output);
}

fn zigImportGraphJson(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const limit: usize = @intCast(@max(1, argInt(args, "limit", 200)));
    const value = analysis.importGraphJson(allocator, a.io, a.workspace.root, limit) catch return error.ExecutionFailed;
    return structured(allocator, value);
}

fn zigDeclSummary(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const source = readSourceArg(a, allocator, args) catch return error.InvalidArguments;
    defer allocator.free(source.bytes);
    const output = analysis.declSummary(allocator, source.name, source.bytes) catch return error.OutOfMemory;
    defer allocator.free(output);
    return structuredText(allocator, "zig_decl_summary", output);
}

fn zigDeclSummaryJson(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const source = readSourceArg(a, allocator, args) catch return error.InvalidArguments;
    defer allocator.free(source.bytes);
    const value = analysis.declSummaryJson(allocator, source.name, source.bytes) catch return error.OutOfMemory;
    return structured(allocator, value);
}

fn asciiLowerAllocLocal(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    const out = try allocator.alloc(u8, input.len);
    for (input, 0..) |c, i| out[i] = std.ascii.toLower(c);
    return out;
}

fn lineNumberLocal(text_value: []const u8, index: usize) usize {
    var line: usize = 1;
    for (text_value[0..@min(index, text_value.len)]) |c| {
        if (c == '\n') line += 1;
    }
    return line;
}

fn lineAtLocal(text_value: []const u8, index: usize) []const u8 {
    var start = index;
    while (start > 0 and text_value[start - 1] != '\n') start -= 1;
    var end = index;
    while (end < text_value.len and text_value[end] != '\n') end += 1;
    return text_value[start..end];
}

fn zigAllocations(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const source = readSourceArg(a, allocator, args) catch return error.InvalidArguments;
    defer allocator.free(source.bytes);
    const output = analysis.allocationSummary(allocator, source.name, source.bytes) catch return error.OutOfMemory;
    defer allocator.free(output);
    return structuredText(allocator, "zig_allocations", output);
}

fn zigErrorSets(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const source = readSourceArg(a, allocator, args) catch return error.InvalidArguments;
    defer allocator.free(source.bytes);
    const output = analysis.errorSetSummary(allocator, source.name, source.bytes) catch return error.OutOfMemory;
    defer allocator.free(output);
    return structuredText(allocator, "zig_error_sets", output);
}

fn zigPublicApi(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const source = readSourceArg(a, allocator, args) catch return error.InvalidArguments;
    defer allocator.free(source.bytes);
    const output = analysis.publicApiSummary(allocator, source.name, source.bytes) catch return error.OutOfMemory;
    defer allocator.free(output);
    return structuredText(allocator, "zig_public_api", output);
}

fn zigDeadDeclCandidates(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const source = readSourceArg(a, allocator, args) catch return error.InvalidArguments;
    defer allocator.free(source.bytes);
    const output = analysis.deadDeclCandidates(allocator, source.name, source.bytes) catch return error.OutOfMemory;
    defer allocator.free(output);
    return structuredText(allocator, "zig_dead_decl_candidates", output);
}

fn zigBuildGraph(a: *App, allocator: std.mem.Allocator, _: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return structured(allocator, buildWorkspaceValue(allocator, a) catch return error.OutOfMemory);
}

fn zigBuildTargets(a: *App, allocator: std.mem.Allocator, _: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const graph = buildWorkspaceValue(allocator, a) catch return error.OutOfMemory;
    const graph_obj = switch (graph) {
        .object => |o| o,
        else => return error.ExecutionFailed,
    };
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    obj.put(allocator, "workspace", .{ .string = a.workspace.root }) catch return error.OutOfMemory;
    if (graph_obj.get("build_zig")) |build_zig| {
        const build_obj = switch (build_zig) {
            .object => |o| o,
            else => return error.ExecutionFailed,
        };
        obj.put(allocator, "modules", build_obj.get("modules") orelse .null) catch return error.OutOfMemory;
        obj.put(allocator, "artifacts", build_obj.get("artifacts") orelse .null) catch return error.OutOfMemory;
        obj.put(allocator, "named_artifacts", build_obj.get("named_artifacts") orelse .null) catch return error.OutOfMemory;
        obj.put(allocator, "tests", build_obj.get("tests") orelse .null) catch return error.OutOfMemory;
        obj.put(allocator, "steps", build_obj.get("steps") orelse .null) catch return error.OutOfMemory;
        obj.put(allocator, "commands", build_obj.get("commands") orelse .null) catch return error.OutOfMemory;
    }
    return structured(allocator, .{ .object = obj });
}

fn zigBuildOptions(a: *App, allocator: std.mem.Allocator, _: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const bytes = a.workspace.readFileAlloc(a.io, "build.zig", 1024 * 1024) catch return error.ResourceNotFound;
    defer allocator.free(bytes);
    var options = std.json.Array.init(allocator);
    var commands = std.json.Array.init(allocator);
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    var line_no: usize = 1;
    var has_target = false;
    var has_optimize = false;
    while (lines.next()) |line| : (line_no += 1) {
        const trimmed = std.mem.trim(u8, line, " \t");
        if (std.mem.indexOf(u8, trimmed, "standardTargetOptions") != null) {
            has_target = true;
            try options.append(try buildOptionValue(allocator, "target", "std.Build.ResolvedTarget", "standardTargetOptions", line_no, trimmed));
        }
        if (std.mem.indexOf(u8, trimmed, "standardOptimizeOption") != null) {
            has_optimize = true;
            try options.append(try buildOptionValue(allocator, "optimize", "std.builtin.OptimizeMode", "standardOptimizeOption", line_no, trimmed));
        }
        if (std.mem.indexOf(u8, trimmed, "b.option(")) |_| {
            const name = optionNameFromLine(trimmed) orelse continue;
            const type_name = optionTypeFromLine(trimmed) orelse "unknown";
            try options.append(try buildOptionValue(allocator, name, type_name, "b.option", line_no, trimmed));
        }
    }
    try commands.append(try ownedString(allocator, "zig build --help"));
    if (has_target) try commands.append(try ownedString(allocator, "zig build -Dtarget=<triple>"));
    if (has_optimize) try commands.append(try ownedString(allocator, "zig build -Doptimize=Debug|ReleaseSafe|ReleaseFast|ReleaseSmall"));
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zig_build_options" });
    try obj.put(allocator, "analysis_kind", .{ .string = "heuristic_build_option_scan" });
    try obj.put(allocator, "confidence", .{ .string = "medium" });
    try obj.put(allocator, "options", .{ .array = options });
    try obj.put(allocator, "commands", .{ .array = commands });
    return structured(allocator, .{ .object = obj });
}

fn buildOptionValue(allocator: std.mem.Allocator, name: []const u8, type_name: []const u8, source: []const u8, line_no: usize, text_value: []const u8) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "name", try ownedString(allocator, name));
    try obj.put(allocator, "flag", .{ .string = try std.fmt.allocPrint(allocator, "-D{s}=<value>", .{name}) });
    try obj.put(allocator, "type", try ownedString(allocator, type_name));
    try obj.put(allocator, "source", try ownedString(allocator, source));
    try obj.put(allocator, "line", .{ .integer = @intCast(line_no) });
    try obj.put(allocator, "text", try ownedString(allocator, text_value));
    return .{ .object = obj };
}

fn optionNameFromLine(line: []const u8) ?[]const u8 {
    const pos = std.mem.indexOf(u8, line, "b.option(") orelse return null;
    const first_quote = std.mem.indexOfScalarPos(u8, line, pos, '"') orelse return null;
    const second_quote = std.mem.indexOfScalarPos(u8, line, first_quote + 1, '"') orelse return null;
    return line[first_quote + 1 .. second_quote];
}

fn optionTypeFromLine(line: []const u8) ?[]const u8 {
    const start = (std.mem.indexOf(u8, line, "b.option(") orelse return null) + "b.option(".len;
    const comma = std.mem.indexOfScalarPos(u8, line, start, ',') orelse return null;
    return std.mem.trim(u8, line[start..comma], " \t");
}

fn zigFileOwner(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const file = argString(args, "file") orelse return error.InvalidArguments;
    const resolved = a.workspace.resolve(file) catch |err| return workspacePathErrorResult(a, allocator, "zig_file_owner", file, err);
    defer allocator.free(resolved);
    const rel = a.workspace.relative(resolved);
    const graph = buildWorkspaceValue(allocator, a) catch return error.OutOfMemory;
    const owner = fileOwnerValue(allocator, graph, rel) catch return error.OutOfMemory;
    return structured(allocator, owner);
}

fn zigImportResolve(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const import_name = argString(args, "import") orelse return error.InvalidArguments;
    const from = argString(args, "from");
    const graph = buildWorkspaceValue(allocator, a) catch return error.OutOfMemory;
    const resolved = importResolveValue(allocator, a, graph, import_name, from) catch return error.OutOfMemory;
    return structured(allocator, resolved);
}

fn buildWorkspaceValue(allocator: std.mem.Allocator, a: *App) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "workspace", .{ .string = a.workspace.root });
    try obj.put(allocator, "analysis_kind", .{ .string = "heuristic_build_file_scan" });
    try obj.put(allocator, "confidence", .{ .string = "medium" });

    if (a.workspace.readFileAlloc(a.io, "build.zig", 1024 * 1024) catch null) |build_bytes| {
        defer allocator.free(build_bytes);
        try obj.put(allocator, "build_zig", try buildZigSummaryValue(allocator, build_bytes));
    } else {
        try obj.put(allocator, "build_zig", .null);
    }
    if (a.workspace.readFileAlloc(a.io, "build.zig.zon", 1024 * 1024) catch null) |zon_bytes| {
        defer allocator.free(zon_bytes);
        try obj.put(allocator, "build_zig_zon", try zonSummaryValue(allocator, zon_bytes));
    } else {
        try obj.put(allocator, "build_zig_zon", .null);
    }
    return .{ .object = obj };
}

fn buildZigSummaryValue(allocator: std.mem.Allocator, bytes: []const u8) !std.json.Value {
    var modules = std.json.Array.init(allocator);
    var artifacts = std.json.Array.init(allocator);
    var named_artifacts = std.json.Array.init(allocator);
    var tests = std.json.Array.init(allocator);
    var steps = std.json.Array.init(allocator);
    var imports = std.json.Array.init(allocator);
    var source_files = std.json.Array.init(allocator);
    var commands = std.json.Array.init(allocator);
    try commands.append(try commandSuggestionValue(allocator, "build", "zig build"));
    try commands.append(try commandSuggestionValue(allocator, "test", "zig build test"));

    var lines = std.mem.splitScalar(u8, bytes, '\n');
    var line_no: usize = 1;
    var current_owner: ?[]const u8 = null;
    var current_kind: ?[]const u8 = null;
    while (lines.next()) |line| : (line_no += 1) {
        const trimmed = std.mem.trim(u8, line, " \t");
        if (std.mem.indexOf(u8, trimmed, "addModule(") != null or std.mem.indexOf(u8, trimmed, "createModule(") != null) {
            const owner = ownerVarName(trimmed);
            current_owner = owner;
            current_kind = "module";
            try modules.append(try buildEntityValue(allocator, "module", owner, buildNameFromCall(trimmed), line_no, trimmed));
        }
        if (std.mem.indexOf(u8, trimmed, "addExecutable(") != null or std.mem.indexOf(u8, trimmed, "addLibrary(") != null) {
            const owner = ownerVarName(trimmed);
            current_owner = owner;
            current_kind = "artifact";
            try artifacts.append(try buildEntityValue(allocator, "artifact", owner, buildNameFromLine(trimmed), line_no, trimmed));
        }
        if (std.mem.indexOf(u8, trimmed, "addTest(") != null) {
            const owner = ownerVarName(trimmed);
            current_owner = owner;
            current_kind = "test";
            try tests.append(try buildEntityValue(allocator, "test", owner, null, line_no, trimmed));
        }
        if (std.mem.indexOf(u8, trimmed, ".step(") != null) {
            try steps.append(try buildStepValue(allocator, line_no, trimmed));
            if (buildNameFromCall(trimmed)) |step_name| {
                try commands.append(.{ .object = blk: {
                    var cmd = std.json.ObjectMap.empty;
                    try cmd.put(allocator, "kind", .{ .string = "step" });
                    try cmd.put(allocator, "name", try ownedString(allocator, step_name));
                    try cmd.put(allocator, "command", .{ .string = try std.fmt.allocPrint(allocator, "zig build {s}", .{step_name}) });
                    break :blk cmd;
                } });
            }
        }
        if (current_kind != null and std.mem.eql(u8, current_kind.?, "artifact") and std.mem.startsWith(u8, trimmed, ".name")) {
            if (quotedString(trimmed)) |name| try named_artifacts.append(try buildEntityValue(allocator, "artifact", current_owner, name, line_no, trimmed));
        }
        if (std.mem.indexOf(u8, trimmed, "addImport(") != null) {
            try imports.append(try buildImportValue(allocator, current_owner, line_no, trimmed));
        }
        if (std.mem.indexOf(u8, trimmed, "root_source_file") != null) {
            if (buildPathFromLine(trimmed)) |path| try source_files.append(try sourceFileOwnerValue(allocator, current_owner, current_kind, path, line_no));
        }
    }
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "modules", .{ .array = modules });
    try obj.put(allocator, "artifacts", .{ .array = artifacts });
    try obj.put(allocator, "named_artifacts", .{ .array = named_artifacts });
    try obj.put(allocator, "tests", .{ .array = tests });
    try obj.put(allocator, "steps", .{ .array = steps });
    try obj.put(allocator, "imports", .{ .array = imports });
    try obj.put(allocator, "source_files", .{ .array = source_files });
    try obj.put(allocator, "commands", .{ .array = commands });
    return .{ .object = obj };
}

fn zonSummaryValue(allocator: std.mem.Allocator, bytes: []const u8) !std.json.Value {
    var deps = std.json.Array.init(allocator);
    var paths = std.json.Array.init(allocator);
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    var in_deps = false;
    var in_paths = false;
    var line_no: usize = 1;
    while (lines.next()) |line| : (line_no += 1) {
        const trimmed = std.mem.trim(u8, line, " \t");
        if (std.mem.startsWith(u8, trimmed, ".dependencies")) in_deps = true;
        if (std.mem.startsWith(u8, trimmed, ".paths")) in_paths = true;
        if (in_deps and std.mem.startsWith(u8, trimmed, ".")) {
            if (dependencyNameFromLine(trimmed)) |name| {
                var dep = std.json.ObjectMap.empty;
                try dep.put(allocator, "name", try ownedString(allocator, name));
                try dep.put(allocator, "line", .{ .integer = @intCast(line_no) });
                try dep.put(allocator, "text", try ownedString(allocator, trimmed));
                try deps.append(.{ .object = dep });
            }
        }
        if (in_paths and std.mem.startsWith(u8, trimmed, "\"")) {
            if (quotedString(trimmed)) |path| try paths.append(try ownedString(allocator, path));
        }
        if (in_deps and std.mem.eql(u8, trimmed, "},")) in_deps = false;
        if (in_paths and std.mem.eql(u8, trimmed, "},")) in_paths = false;
    }
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "dependencies", .{ .array = deps });
    try obj.put(allocator, "paths", .{ .array = paths });
    return .{ .object = obj };
}

fn buildEntityValue(allocator: std.mem.Allocator, kind: []const u8, owner: ?[]const u8, name: ?[]const u8, line_no: usize, text_value: []const u8) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "kind", .{ .string = kind });
    if (owner) |value| try obj.put(allocator, "var", try ownedString(allocator, value)) else try obj.put(allocator, "var", .null);
    if (name) |value| try obj.put(allocator, "name", try ownedString(allocator, value)) else try obj.put(allocator, "name", .null);
    try obj.put(allocator, "line", .{ .integer = @intCast(line_no) });
    try obj.put(allocator, "text", try ownedString(allocator, text_value));
    return .{ .object = obj };
}

fn buildStepValue(allocator: std.mem.Allocator, line_no: usize, text_value: []const u8) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    if (buildNameFromCall(text_value)) |name| try obj.put(allocator, "name", try ownedString(allocator, name)) else try obj.put(allocator, "name", .null);
    try obj.put(allocator, "line", .{ .integer = @intCast(line_no) });
    try obj.put(allocator, "command", if (buildNameFromCall(text_value)) |name| .{ .string = try std.fmt.allocPrint(allocator, "zig build {s}", .{name}) } else .null);
    try obj.put(allocator, "text", try ownedString(allocator, text_value));
    return .{ .object = obj };
}

fn buildImportValue(allocator: std.mem.Allocator, owner: ?[]const u8, line_no: usize, text_value: []const u8) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    if (owner) |value| try obj.put(allocator, "owner", try ownedString(allocator, value)) else try obj.put(allocator, "owner", .null);
    if (buildNameFromCall(text_value)) |name| try obj.put(allocator, "import", try ownedString(allocator, name)) else try obj.put(allocator, "import", .null);
    try obj.put(allocator, "line", .{ .integer = @intCast(line_no) });
    try obj.put(allocator, "text", try ownedString(allocator, text_value));
    return .{ .object = obj };
}

fn sourceFileOwnerValue(allocator: std.mem.Allocator, owner: ?[]const u8, kind: ?[]const u8, path: []const u8, line_no: usize) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "path", try ownedString(allocator, path));
    if (owner) |value| try obj.put(allocator, "owner", try ownedString(allocator, value)) else try obj.put(allocator, "owner", .null);
    if (kind) |value| try obj.put(allocator, "kind", .{ .string = value }) else try obj.put(allocator, "kind", .null);
    try obj.put(allocator, "line", .{ .integer = @intCast(line_no) });
    return .{ .object = obj };
}

fn commandSuggestionValue(allocator: std.mem.Allocator, kind: []const u8, command_text: []const u8) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "kind", .{ .string = kind });
    try obj.put(allocator, "command", .{ .string = command_text });
    return .{ .object = obj };
}

fn ownerVarName(line: []const u8) ?[]const u8 {
    const eq = std.mem.indexOf(u8, line, " = ") orelse return null;
    const before = std.mem.trim(u8, line[0..eq], " \t");
    if (std.mem.startsWith(u8, before, "const ")) return std.mem.trim(u8, before["const ".len..], " \t");
    if (std.mem.startsWith(u8, before, "var ")) return std.mem.trim(u8, before["var ".len..], " \t");
    return null;
}

fn buildNameFromCall(line: []const u8) ?[]const u8 {
    const open = std.mem.indexOfScalar(u8, line, '(') orelse return null;
    const first_quote = std.mem.indexOfScalarPos(u8, line, open, '"') orelse return null;
    const second_quote = std.mem.indexOfScalarPos(u8, line, first_quote + 1, '"') orelse return null;
    return line[first_quote + 1 .. second_quote];
}

fn buildNameFromLine(line: []const u8) ?[]const u8 {
    if (std.mem.indexOf(u8, line, ".name")) |_| {
        if (quotedString(line)) |name| return name;
    }
    return buildNameFromCall(line);
}

fn buildPathFromLine(line: []const u8) ?[]const u8 {
    if (std.mem.indexOf(u8, line, "b.path(")) |pos| {
        const first_quote = std.mem.indexOfScalarPos(u8, line, pos, '"') orelse return null;
        const second_quote = std.mem.indexOfScalarPos(u8, line, first_quote + 1, '"') orelse return null;
        return line[first_quote + 1 .. second_quote];
    }
    return quotedString(line);
}

fn dependencyNameFromLine(line: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, line, ".")) return null;
    const rest = line[1..];
    const end = std.mem.indexOfAny(u8, rest, " \t=") orelse return null;
    if (end == 0) return null;
    return rest[0..end];
}

fn quotedString(line: []const u8) ?[]const u8 {
    const first_quote = std.mem.indexOfScalar(u8, line, '"') orelse return null;
    const second_quote = std.mem.indexOfScalarPos(u8, line, first_quote + 1, '"') orelse return null;
    return line[first_quote + 1 .. second_quote];
}

fn fileOwnerValue(allocator: std.mem.Allocator, graph: std.json.Value, rel: []const u8) !std.json.Value {
    var owners = std.json.Array.init(allocator);
    const build_zig = buildZigObject(graph);
    if (build_zig) |build_obj| {
        if (build_obj.get("source_files")) |source_files| {
            if (source_files == .array) {
                for (source_files.array.items) |item| {
                    const item_obj = switch (item) {
                        .object => |o| o,
                        else => continue,
                    };
                    const path = switch (item_obj.get("path") orelse .null) {
                        .string => |s| s,
                        else => continue,
                    };
                    if (std.mem.eql(u8, path, rel)) try owners.append(item);
                }
            }
        }
    }

    var commands = std.json.Array.init(allocator);
    try commands.append(.{ .string = try std.fmt.allocPrint(allocator, "zig ast-check {s}", .{rel}) });
    try commands.append(.{ .string = try std.fmt.allocPrint(allocator, "zig test {s}", .{rel}) });
    try commands.append(try ownedString(allocator, "zig build test"));

    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "file", try ownedString(allocator, rel));
    try obj.put(allocator, "owners", .{ .array = owners });
    try obj.put(allocator, "owner_count", .{ .integer = @intCast(owners.items.len) });
    try obj.put(allocator, "likely_commands", .{ .array = commands });
    if (owners.items.len == 0) {
        try obj.put(allocator, "confidence", .{ .string = "low" });
        try obj.put(allocator, "reason", try ownedString(allocator, "No exact root_source_file match found in build.zig; commands are file-focused fallbacks."));
    } else {
        try obj.put(allocator, "confidence", .{ .string = "high" });
        try obj.put(allocator, "reason", try ownedString(allocator, "File is referenced directly by build.zig root_source_file metadata."));
    }
    return .{ .object = obj };
}

fn importResolveValue(allocator: std.mem.Allocator, a: *App, graph: std.json.Value, import_name: []const u8, from: ?[]const u8) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "import", try ownedString(allocator, import_name));
    if (from) |from_file| try obj.put(allocator, "from", try ownedString(allocator, from_file)) else try obj.put(allocator, "from", .null);

    if (std.mem.eql(u8, import_name, "std")) {
        try obj.put(allocator, "kind", .{ .string = "stdlib" });
        try obj.put(allocator, "resolved", .{ .bool = true });
        try obj.put(allocator, "next_action", try ownedString(allocator, "Use zig_std_search or zig_std_item for stdlib details."));
        return .{ .object = obj };
    }
    if (std.mem.eql(u8, import_name, "builtin") or std.mem.eql(u8, import_name, "root")) {
        try obj.put(allocator, "kind", .{ .string = "compiler_builtin" });
        try obj.put(allocator, "resolved", .{ .bool = true });
        try obj.put(allocator, "next_action", try ownedString(allocator, "This import is supplied by Zig or by the current root module."));
        return .{ .object = obj };
    }

    if (findModuleOrDependency(allocator, &obj, graph, import_name)) return .{ .object = obj };

    if (std.mem.endsWith(u8, import_name, ".zig")) {
        const candidate = try relativeImportCandidate(allocator, from, import_name);
        defer allocator.free(candidate);
        if (a.workspace.resolve(candidate) catch null) |resolved| {
            defer allocator.free(resolved);
            try obj.put(allocator, "kind", .{ .string = "workspace_file" });
            try obj.put(allocator, "resolved", .{ .bool = true });
            try obj.put(allocator, "path", try ownedString(allocator, a.workspace.relative(resolved)));
            try obj.put(allocator, "next_action", .{ .string = try std.fmt.allocPrint(allocator, "Run zig ast-check {s}", .{a.workspace.relative(resolved)}) });
            return .{ .object = obj };
        }
    }

    try obj.put(allocator, "kind", .{ .string = "unresolved" });
    try obj.put(allocator, "resolved", .{ .bool = false });
    try obj.put(allocator, "next_action", try ownedString(allocator, "Check build.zig addImport calls and build.zig.zon dependencies for this import name."));
    return .{ .object = obj };
}

fn buildZigObject(graph: std.json.Value) ?std.json.ObjectMap {
    const graph_obj = switch (graph) {
        .object => |o| o,
        else => return null,
    };
    const build_zig = graph_obj.get("build_zig") orelse return null;
    return switch (build_zig) {
        .object => |o| o,
        else => null,
    };
}

fn findModuleOrDependency(allocator: std.mem.Allocator, obj: *std.json.ObjectMap, graph: std.json.Value, import_name: []const u8) bool {
    if (buildZigObject(graph)) |build_obj| {
        if (build_obj.get("modules")) |modules| {
            if (modules == .array) {
                for (modules.array.items) |item| {
                    const item_obj = switch (item) {
                        .object => |o| o,
                        else => continue,
                    };
                    const name = switch (item_obj.get("name") orelse item_obj.get("var") orelse .null) {
                        .string => |s| s,
                        else => continue,
                    };
                    if (std.mem.eql(u8, name, import_name)) {
                        obj.put(allocator, "kind", .{ .string = "build_module" }) catch return false;
                        obj.put(allocator, "resolved", .{ .bool = true }) catch return false;
                        obj.put(allocator, "module", item) catch return false;
                        obj.put(allocator, "next_action", .{ .string = "Inspect build.zig module addImport wiring for this module." }) catch return false;
                        return true;
                    }
                }
            }
        }
    }
    const graph_obj = switch (graph) {
        .object => |o| o,
        else => return false,
    };
    const zon = graph_obj.get("build_zig_zon") orelse return false;
    const zon_obj = switch (zon) {
        .object => |o| o,
        else => return false,
    };
    const deps = zon_obj.get("dependencies") orelse return false;
    if (deps == .array) {
        for (deps.array.items) |item| {
            const item_obj = switch (item) {
                .object => |o| o,
                else => continue,
            };
            const name = switch (item_obj.get("name") orelse .null) {
                .string => |s| s,
                else => continue,
            };
            if (std.mem.eql(u8, name, import_name)) {
                obj.put(allocator, "kind", .{ .string = "package_dependency" }) catch return false;
                obj.put(allocator, "resolved", .{ .bool = true }) catch return false;
                obj.put(allocator, "dependency", item) catch return false;
                obj.put(allocator, "next_action", .{ .string = "Check b.dependency(...) and module addImport(...) wiring for this dependency." }) catch return false;
                return true;
            }
        }
    }
    return false;
}

fn relativeImportCandidate(allocator: std.mem.Allocator, from: ?[]const u8, import_name: []const u8) ![]u8 {
    if (from) |from_file| {
        if (std.fs.path.dirname(from_file)) |dir| return std.fs.path.join(allocator, &.{ dir, import_name });
    }
    return allocator.dupe(u8, import_name);
}

fn appendLineRecord(allocator: std.mem.Allocator, array: *std.json.Array, line_no: usize, text_value: []const u8) !void {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "line", .{ .integer = @intCast(line_no) });
    try obj.put(allocator, "text", try ownedString(allocator, text_value));
    try array.append(.{ .object = obj });
}

fn zigTestDiscover(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const limit: usize = @intCast(@max(1, argInt(args, "limit", 500)));
    const value = analysis.testDiscoverJson(allocator, a.io, a.workspace.root, limit) catch return error.ExecutionFailed;
    return structured(allocator, value);
}

fn zigChangedFilesPlan(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const result = command.run(allocator, a.io, a.workspace.root, &.{ "git", "status", "--porcelain" }, toolTimeout(a, args)) catch |err| {
        return backendErrorResult(allocator, "git", "status", err, "run this tool inside a git checkout or inspect changed files manually");
    };
    defer result.deinit(allocator);

    var files = std.json.Array.init(allocator);
    var commands = std.json.Array.init(allocator);
    var saw_zig = false;
    var saw_build = false;
    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    while (lines.next()) |line| {
        if (line.len < 4) continue;
        const path = statusLinePath(line);
        if (path.len == 0 or analysis.skipWorkspacePath(path)) continue;
        var item = std.json.ObjectMap.empty;
        try item.put(allocator, "status", try ownedString(allocator, std.mem.trim(u8, line[0..2], " ")));
        try item.put(allocator, "path", try ownedString(allocator, path));
        try files.append(.{ .object = item });
        if (std.mem.endsWith(u8, path, ".zig") and workspacePathExists(allocator, a, path)) {
            saw_zig = true;
            const fmt_cmd = try std.fmt.allocPrint(allocator, "zig fmt --check {s}", .{path});
            defer allocator.free(fmt_cmd);
            try appendUniqueCommand(allocator, &commands, fmt_cmd);
            const check_cmd = try std.fmt.allocPrint(allocator, "zig ast-check {s}", .{path});
            defer allocator.free(check_cmd);
            try appendUniqueCommand(allocator, &commands, check_cmd);
            const test_cmd = try std.fmt.allocPrint(allocator, "zig test {s}", .{path});
            defer allocator.free(test_cmd);
            try appendUniqueCommand(allocator, &commands, test_cmd);
        }
        if ((std.mem.eql(u8, path, "build.zig") or std.mem.eql(u8, path, "build.zig.zon")) and workspacePathExists(allocator, a, path)) saw_build = true;
    }
    if (saw_build) {
        try appendUniqueCommand(allocator, &commands, "zig build --help");
        try appendUniqueCommand(allocator, &commands, "zig build test");
    } else if (saw_zig) {
        try appendUniqueCommand(allocator, &commands, "zig build test");
    }
    try appendWorkspaceFormatCheckCommand(allocator, a, &commands);

    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zig_changed_files_plan" });
    try obj.put(allocator, "ok", .{ .bool = result.succeeded() });
    try obj.put(allocator, "files", .{ .array = files });
    try obj.put(allocator, "commands", .{ .array = commands });
    try obj.put(allocator, "raw_status", .{ .string = result.stdout });
    return structured(allocator, .{ .object = obj });
}

fn statusLinePath(line: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, if (line.len > 3) line[3..] else "", " \t");
    if (std.mem.indexOf(u8, trimmed, " -> ")) |arrow| return trimmed[arrow + " -> ".len ..];
    return trimmed;
}

fn appendWorkspaceFormatCheckCommand(allocator: std.mem.Allocator, a: *App, commands: *std.json.Array) !void {
    const candidates = [_][]const u8{ "build.zig", "build.zig.zon", "src" };
    var command_text: std.ArrayList(u8) = .empty;
    defer command_text.deinit(allocator);
    try command_text.appendSlice(allocator, "zig fmt --check");
    var appended_path = false;
    for (candidates) |candidate| {
        if (!workspacePathExists(allocator, a, candidate)) continue;
        try command_text.print(allocator, " {s}", .{candidate});
        appended_path = true;
    }
    if (appended_path) try appendUniqueCommand(allocator, commands, command_text.items);
}

fn appendUniqueCommand(allocator: std.mem.Allocator, commands: *std.json.Array, command_text: []const u8) !void {
    for (commands.items) |item| {
        const existing = switch (item) {
            .string => |s| s,
            else => continue,
        };
        if (std.mem.eql(u8, existing, command_text)) return;
    }
    try commands.append(try ownedString(allocator, command_text));
}

fn workspacePathExists(allocator: std.mem.Allocator, a: *App, path: []const u8) bool {
    const resolved = a.workspace.resolve(path) catch return false;
    defer allocator.free(resolved);
    if (countTopLevelEntries(allocator, a.io, resolved)) |_| {
        return true;
    } else |_| {}
    if (std.Io.Dir.cwd().readFileAlloc(a.io, resolved, allocator, .limited(1)) catch null) |bytes| {
        allocator.free(bytes);
        return true;
    }
    return false;
}

fn zigDependencyInspect(a: *App, allocator: std.mem.Allocator, _: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const bytes = a.workspace.readFileAlloc(a.io, "build.zig.zon", 1024 * 1024) catch return error.ResourceNotFound;
    defer allocator.free(bytes);
    const value = dependencyInspectionValue(allocator, a, bytes) catch return error.OutOfMemory;
    return structured(allocator, value);
}

const DependencyRecord = struct {
    name: []const u8,
    url: ?[]const u8 = null,
    hash: ?[]const u8 = null,
    path: ?[]const u8 = null,
    line: usize,
};

fn dependencyInspectionValue(allocator: std.mem.Allocator, a: *App, bytes: []const u8) !std.json.Value {
    var deps = std.json.Array.init(allocator);
    var issues = std.json.Array.init(allocator);
    var current: ?DependencyRecord = null;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    var line_no: usize = 1;
    while (lines.next()) |line| : (line_no += 1) {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (dependencyBlockNameFromLine(trimmed)) |name| {
            if (current) |record| try appendDependencyRecord(allocator, &deps, &issues, record);
            current = .{ .name = name, .line = line_no };
            continue;
        }
        if (current) |*record| {
            if (std.mem.indexOf(u8, trimmed, ".url") != null) {
                record.url = quotedString(trimmed);
            } else if (std.mem.indexOf(u8, trimmed, ".hash") != null) {
                record.hash = quotedString(trimmed);
            } else if (std.mem.indexOf(u8, trimmed, ".path") != null) {
                record.path = quotedString(trimmed);
            } else if (std.mem.startsWith(u8, trimmed, "},")) {
                try appendDependencyRecord(allocator, &deps, &issues, record.*);
                current = null;
            }
        }
    }
    if (current) |record| try appendDependencyRecord(allocator, &deps, &issues, record);

    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zig_dependency_inspect" });
    try obj.put(allocator, "workspace", .{ .string = a.workspace.root });
    try obj.put(allocator, "dependencies", .{ .array = deps });
    try obj.put(allocator, "dependency_count", .{ .integer = @intCast(deps.items.len) });
    try obj.put(allocator, "issues", .{ .array = issues });
    try obj.put(allocator, "zig_pkg_cache", try cachePathStatusValue(allocator, a, "zig-pkg"));
    try obj.put(allocator, "analysis_kind", .{ .string = "heuristic_zon_dependency_scan" });
    try obj.put(allocator, "confidence", .{ .string = "medium" });
    return .{ .object = obj };
}

fn dependencyBlockNameFromLine(line: []const u8) ?[]const u8 {
    if (std.mem.indexOf(u8, line, "= .{") == null) return null;
    const name = dependencyNameFromLine(line) orelse return null;
    if (std.mem.eql(u8, name, "dependencies") or
        std.mem.eql(u8, name, "paths") or
        std.mem.eql(u8, name, "url") or
        std.mem.eql(u8, name, "hash") or
        std.mem.eql(u8, name, "path")) return null;
    return name;
}

fn appendDependencyRecord(allocator: std.mem.Allocator, deps: *std.json.Array, issues: *std.json.Array, record: DependencyRecord) !void {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "name", try ownedString(allocator, record.name));
    try obj.put(allocator, "line", .{ .integer = @intCast(record.line) });
    if (record.url) |url| try obj.put(allocator, "url", try ownedString(allocator, url)) else try obj.put(allocator, "url", .null);
    if (record.hash) |hash| try obj.put(allocator, "hash", try ownedString(allocator, hash)) else try obj.put(allocator, "hash", .null);
    if (record.path) |path| try obj.put(allocator, "path", try ownedString(allocator, path)) else try obj.put(allocator, "path", .null);
    try deps.append(.{ .object = obj });
    if (record.url != null and record.hash == null) {
        try issues.append(.{ .string = try std.fmt.allocPrint(allocator, "dependency `{s}` has a URL but no hash", .{record.name}) });
    }
    if (record.url != null and record.path != null) {
        try issues.append(.{ .string = try std.fmt.allocPrint(allocator, "dependency `{s}` declares both url and path", .{record.name}) });
    }
}

fn zigTargetMatrixPlan(_: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const targets_text = argString(args, "targets") orelse "native x86_64-linux-gnu x86_64-macos-none aarch64-macos-none x86_64-windows-gnu wasm32-freestanding";
    const steps_text = argString(args, "steps") orelse "build test";
    var targets = std.mem.tokenizeAny(u8, targets_text, ", \t\r\n");
    var matrix = std.json.Array.init(allocator);
    while (targets.next()) |target| {
        var commands = std.json.Array.init(allocator);
        var steps = std.mem.tokenizeAny(u8, steps_text, ", \t\r\n");
        while (steps.next()) |step| {
            if (std.mem.eql(u8, target, "native")) {
                try commands.append(.{ .string = try std.fmt.allocPrint(allocator, "zig build {s}", .{step}) });
            } else {
                try commands.append(.{ .string = try std.fmt.allocPrint(allocator, "zig build {s} -Dtarget={s}", .{ step, target }) });
            }
        }
        var item = std.json.ObjectMap.empty;
        try item.put(allocator, "target", try ownedString(allocator, target));
        try item.put(allocator, "commands", .{ .array = commands });
        try item.put(allocator, "note", .{ .string = targetMatrixNote(target) });
        try matrix.append(.{ .object = item });
    }
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zig_target_matrix_plan" });
    try obj.put(allocator, "matrix", .{ .array = matrix });
    try obj.put(allocator, "resolution", .{ .string = "Use zig_matrix_check when you have concrete Zig binaries to execute; this tool only plans commands." });
    return structured(allocator, .{ .object = obj });
}

fn targetMatrixNote(target: []const u8) []const u8 {
    if (std.mem.eql(u8, target, "native")) return "uses the active host target";
    if (std.mem.indexOf(u8, target, "windows") != null) return "may require avoiding host-only libc/system-library assumptions";
    if (std.mem.indexOf(u8, target, "wasm") != null) return "freestanding/web targets commonly need custom entrypoints and no OS APIs";
    if (std.mem.indexOf(u8, target, "linux") != null) return "Linux cross-target checks catch many libc and target-feature issues";
    if (std.mem.indexOf(u8, target, "macos") != null) return "macOS targets may require SDK availability for linked artifacts";
    return "generic cross-target check";
}

fn zigTestFailureTriage(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    if (argString(args, "text")) |raw_text| {
        return structured(allocator, testFailureTriageValue(allocator, raw_text, "", &.{ "zig", "test" }, false) catch return error.OutOfMemory);
    }
    var list: std.ArrayList([]const u8) = .empty;
    defer list.deinit(allocator);
    var resolved_file: ?[]const u8 = null;
    defer if (resolved_file) |path| allocator.free(path);
    try list.append(allocator, a.config.zig_path);
    if (argString(args, "file")) |file| {
        resolved_file = a.workspace.resolve(file) catch |err| return workspacePathErrorResult(a, allocator, "zig_test_failure_triage", file, err);
        try list.append(allocator, "test");
        try list.append(allocator, resolved_file.?);
        if (argString(args, "filter")) |filter| {
            try list.append(allocator, "--test-filter");
            try list.append(allocator, filter);
        }
    } else {
        try list.append(allocator, "build");
        try list.append(allocator, "test");
    }
    const extra = try splitToolArgs(allocator, argString(args, "args"));
    defer freeArgList(allocator, extra);
    try list.appendSlice(allocator, extra);
    a.command_calls += 1;
    const run = command.run(allocator, a.io, a.workspace.root, list.items, toolTimeout(a, args)) catch |err| return backendErrorResult(allocator, "zig", "test_failure_triage", err, "pass captured test output as text or confirm --zig-path is executable");
    defer run.deinit(allocator);
    return structured(allocator, testFailureTriageValue(allocator, run.stderr, run.stdout, list.items, run.succeeded()) catch return error.OutOfMemory);
}

fn testFailureTriageValue(allocator: std.mem.Allocator, stderr: []const u8, stdout: []const u8, argv: []const []const u8, ok: bool) !std.json.Value {
    var failures = std.json.Array.init(allocator);
    var panics = std.json.Array.init(allocator);
    var expected_actual = std.json.Array.init(allocator);
    try collectTestFailureLines(allocator, &failures, &panics, &expected_actual, stderr);
    try collectTestFailureLines(allocator, &failures, &panics, &expected_actual, stdout);
    var commands = std.json.Array.init(allocator);
    try commands.append(.{ .string = try commandString(allocator, argv) });
    if (argvContains(argv, "test")) try commands.append(try ownedString(allocator, "rerun with --test-filter <failing test name>"));
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zig_test_failure_triage" });
    try obj.put(allocator, "ok", .{ .bool = ok });
    try obj.put(allocator, "failures", .{ .array = failures });
    try obj.put(allocator, "panic_clues", .{ .array = panics });
    try obj.put(allocator, "expected_actual", .{ .array = expected_actual });
    try obj.put(allocator, "compile_diagnostics", try compilerErrorIndexValue(allocator, stderr, stdout, argv));
    try obj.put(allocator, "rerun_commands", .{ .array = commands });
    return .{ .object = obj };
}

fn collectTestFailureLines(allocator: std.mem.Allocator, failures: *std.json.Array, panics: *std.json.Array, expected_actual: *std.json.Array, text_value: []const u8) !void {
    var lines = std.mem.splitScalar(u8, text_value, '\n');
    var line_no: usize = 1;
    while (lines.next()) |line| : (line_no += 1) {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len == 0) continue;
        if (std.mem.indexOf(u8, trimmed, "FAIL") != null or std.mem.indexOf(u8, trimmed, "failed") != null) try appendLineRecord(allocator, failures, line_no, trimmed);
        if (std.mem.indexOf(u8, trimmed, "panic") != null or std.mem.indexOf(u8, trimmed, "thread ") != null) try appendLineRecord(allocator, panics, line_no, trimmed);
        if (std.mem.indexOf(u8, trimmed, "expected") != null or std.mem.indexOf(u8, trimmed, "actual") != null) try appendLineRecord(allocator, expected_actual, line_no, trimmed);
    }
}

fn zigWorkspaceSymbolCache(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const limit: usize = @intCast(@max(1, argInt(args, "limit", 500)));
    const signature = workspaceSymbolSignature(allocator, a, limit) catch return error.ExecutionFailed;
    const refresh = argBool(args, "refresh", false) or a.analysis_cache.index_json == null or a.analysis_cache.signature != signature;
    if (refresh) {
        const index = workspaceSymbolIndexValue(allocator, a, limit) catch return error.ExecutionFailed;
        var bytes_list: std.ArrayList(u8) = .empty;
        json_result.serializeValue(allocator, &bytes_list, index) catch return error.OutOfMemory;
        const bytes = bytes_list.toOwnedSlice(allocator) catch return error.OutOfMemory;
        if (a.analysis_cache.index_json) |old| allocator.free(old);
        a.analysis_cache.index_json = bytes;
        a.analysis_cache.signature = signature;
        a.analysis_cache.refreshes += 1;
    } else {
        a.analysis_cache.hits += 1;
    }

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, a.analysis_cache.index_json.?, .{}) catch return error.ExecutionFailed;
    defer parsed.deinit();
    const cached_obj = switch (parsed.value) {
        .object => |o| o,
        else => return error.ExecutionFailed,
    };
    var obj = std.json.ObjectMap.empty;
    defer obj.deinit(allocator);
    var it = cached_obj.iterator();
    while (it.next()) |entry| {
        try obj.put(allocator, entry.key_ptr.*, entry.value_ptr.*);
    }
    try obj.put(allocator, "cache", try analysisCacheStatusValue(allocator, a));
    if (argString(args, "query")) |query| {
        try obj.put(allocator, "matches", try symbolCacheMatchesValue(allocator, parsed.value, query));
    }
    return structured(allocator, .{ .object = obj });
}

fn workspaceSymbolSignature(allocator: std.mem.Allocator, a: *App, limit: usize) !u64 {
    var hasher = std.hash.Wyhash.init(0);
    var dir = try std.Io.Dir.openDirAbsolute(a.io, a.workspace.root, .{ .iterate = true });
    defer dir.close(a.io);
    var walker = try dir.walk(allocator);
    defer walker.deinit();
    var seen: usize = 0;
    while ((walker.next(a.io) catch null)) |entry| {
        if (seen >= limit) break;
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".zig") or analysis.skipWorkspacePath(entry.path)) continue;
        seen += 1;
        hasher.update(entry.path);
        const bytes = a.workspace.readFileAlloc(a.io, entry.path, 256 * 1024) catch continue;
        defer allocator.free(bytes);
        hasher.update(bytes);
    }
    return hasher.final();
}

fn workspaceSymbolIndexValue(allocator: std.mem.Allocator, a: *App, limit: usize) !std.json.Value {
    var files = std.json.Array.init(allocator);
    var total_decls: usize = 0;
    var total_imports: usize = 0;
    var dir = try std.Io.Dir.openDirAbsolute(a.io, a.workspace.root, .{ .iterate = true });
    defer dir.close(a.io);
    var walker = try dir.walk(allocator);
    defer walker.deinit();
    var seen: usize = 0;
    var skipped_files: usize = 0;
    var walk_errors: usize = 0;
    while (true) {
        const maybe_entry = walker.next(a.io) catch {
            walk_errors += 1;
            break;
        };
        const entry = maybe_entry orelse break;
        if (seen >= limit) break;
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".zig") or analysis.skipWorkspacePath(entry.path)) continue;
        const contents = a.workspace.readFileAlloc(a.io, entry.path, 512 * 1024) catch {
            skipped_files += 1;
            continue;
        };
        defer allocator.free(contents);
        seen += 1;
        var decls = std.json.Array.init(allocator);
        var imports = std.json.Array.init(allocator);
        var lines = std.mem.splitScalar(u8, contents, '\n');
        var line_no: usize = 1;
        while (lines.next()) |line| : (line_no += 1) {
            const trimmed = std.mem.trim(u8, line, " \t");
            if (analysis.declKind(trimmed)) |kind| {
                total_decls += 1;
                var decl = std.json.ObjectMap.empty;
                try decl.put(allocator, "kind", .{ .string = kind });
                try decl.put(allocator, "name", if (declName(trimmed, kind)) |name| try ownedString(allocator, name) else .null);
                try decl.put(allocator, "line", .{ .integer = @intCast(line_no) });
                try decl.put(allocator, "public", .{ .bool = std.mem.startsWith(u8, trimmed, "pub ") });
                try decls.append(.{ .object = decl });
            }
            var pos: usize = 0;
            while (std.mem.indexOfPos(u8, line, pos, "@import(\"")) |hit| {
                const start = hit + "@import(\"".len;
                const end = std.mem.indexOfScalarPos(u8, line, start, '"') orelse break;
                total_imports += 1;
                try imports.append(try ownedString(allocator, line[start..end]));
                pos = end + 1;
            }
        }
        var file_obj = std.json.ObjectMap.empty;
        try file_obj.put(allocator, "file", try ownedString(allocator, entry.path));
        try file_obj.put(allocator, "declarations", .{ .array = decls });
        try file_obj.put(allocator, "imports", .{ .array = imports });
        try files.append(.{ .object = file_obj });
    }
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zig_workspace_symbol_cache" });
    try obj.put(allocator, "analysis_kind", .{ .string = "cached_heuristic_symbol_import_scan" });
    try obj.put(allocator, "confidence", .{ .string = "medium" });
    try obj.put(allocator, "files", .{ .array = files });
    try obj.put(allocator, "file_count", .{ .integer = @intCast(seen) });
    try obj.put(allocator, "declaration_count", .{ .integer = @intCast(total_decls) });
    try obj.put(allocator, "import_count", .{ .integer = @intCast(total_imports) });
    try obj.put(allocator, "skipped_files", .{ .integer = @intCast(skipped_files) });
    try obj.put(allocator, "walk_errors", .{ .integer = @intCast(walk_errors) });
    return .{ .object = obj };
}

fn declName(line: []const u8, kind: []const u8) ?[]const u8 {
    const rest = if (std.mem.startsWith(u8, line, "pub ")) line["pub ".len..] else line;
    const prefix_len = kind.len + 1;
    if (rest.len <= prefix_len) return null;
    var name = std.mem.trim(u8, rest[prefix_len..], " \t");
    const end = std.mem.indexOfAny(u8, name, " (:=,{") orelse name.len;
    name = name[0..end];
    return if (name.len == 0) null else name;
}

fn symbolCacheMatchesValue(allocator: std.mem.Allocator, index: std.json.Value, query: []const u8) !std.json.Value {
    const lower_query = try asciiLowerAllocLocal(allocator, query);
    defer allocator.free(lower_query);
    var matches = std.json.Array.init(allocator);
    const root = switch (index) {
        .object => |o| o,
        else => return .{ .array = matches },
    };
    const files = switch (root.get("files") orelse .null) {
        .array => |a| a,
        else => return .{ .array = matches },
    };
    for (files.items) |file_value| {
        const file_obj = switch (file_value) {
            .object => |o| o,
            else => continue,
        };
        const file = switch (file_obj.get("file") orelse .null) {
            .string => |s| s,
            else => continue,
        };
        const decls = switch (file_obj.get("declarations") orelse .null) {
            .array => |a| a,
            else => continue,
        };
        for (decls.items) |decl_value| {
            const decl_obj = switch (decl_value) {
                .object => |o| o,
                else => continue,
            };
            const name = switch (decl_obj.get("name") orelse .null) {
                .string => |s| s,
                else => continue,
            };
            const lower_name = try asciiLowerAllocLocal(allocator, name);
            defer allocator.free(lower_name);
            if (std.mem.indexOf(u8, lower_name, lower_query) == null) continue;
            var match = std.json.ObjectMap.empty;
            try match.put(allocator, "file", try ownedString(allocator, file));
            try match.put(allocator, "declaration", decl_value);
            try matches.append(.{ .object = match });
        }
    }
    return .{ .array = matches };
}

fn zigPackageCacheDoctor(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    var paths = std.json.Array.init(allocator);
    const names = [_][]const u8{ ".zig-cache", "zig-out", ".zigar-cache", "zig-pkg", "coverage" };
    for (names) |name| try paths.append(try cachePathStatusValue(allocator, a, name));
    var issues = std.json.Array.init(allocator);
    for (names) |name| {
        const tracked = gitTracksPath(allocator, a, name, toolTimeout(a, args)) catch false;
        if (tracked) try issues.append(.{ .string = try std.fmt.allocPrint(allocator, "generated artifact path `{s}` is tracked by git", .{name}) });
    }
    if (a.workspace.readFileAlloc(a.io, "build.zig.zon", 1024 * 1024) catch null) |bytes| {
        defer allocator.free(bytes);
        const deps = dependencyInspectionValue(allocator, a, bytes) catch return error.OutOfMemory;
        try issues.appendSlice(deps.object.get("issues").?.array.items);
    }
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zig_package_cache_doctor" });
    try obj.put(allocator, "paths", .{ .array = paths });
    try obj.put(allocator, "issues", .{ .array = issues });
    try obj.put(allocator, "resolution", .{ .string = "Cache directories should be workspace-local, ignored by git, and safe to delete/recreate when Zig package state becomes stale." });
    return structured(allocator, .{ .object = obj });
}

fn zigTestMap(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return structured(allocator, testMapValue(allocator, a, @intCast(@max(1, argInt(args, "limit", 500)))) catch return error.OutOfMemory);
}

fn zigTestSelect(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return structured(allocator, testSelectValue(allocator, a, argString(args, "files"), argString(args, "symbols"), @intCast(@max(1, argInt(args, "limit", 500)))) catch return error.OutOfMemory);
}

fn zigPublicApiDiff(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const file = argString(args, "file");
    var before_owned: ?[]u8 = null;
    defer if (before_owned) |bytes| allocator.free(bytes);
    var after_owned: ?[]u8 = null;
    defer if (after_owned) |bytes| allocator.free(bytes);

    const before_text = argString(args, "before") orelse blk: {
        const rel = file orelse break :blk "";
        const baseline_ref = argString(args, "baseline_ref") orelse "HEAD";
        const spec = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ baseline_ref, rel });
        defer allocator.free(spec);
        const result = command.run(allocator, a.io, a.workspace.root, &.{ "git", "show", spec }, @min(toolTimeout(a, args), 5000)) catch null;
        if (result) |r| {
            defer r.deinit(allocator);
            if (r.succeeded()) {
                before_owned = try allocator.dupe(u8, r.stdout);
                break :blk before_owned.?;
            }
        }
        break :blk "";
    };
    const after_text = argString(args, "after") orelse blk: {
        const rel = file orelse break :blk "";
        after_owned = a.workspace.readFileAlloc(a.io, rel, 4 * 1024 * 1024) catch break :blk "";
        break :blk after_owned.?;
    };
    return structured(allocator, publicApiDiffValue(allocator, file, before_text, after_text) catch return error.OutOfMemory);
}

fn testMapValue(allocator: std.mem.Allocator, a: *App, limit: usize) !std.json.Value {
    var tests = std.json.Array.init(allocator);
    var files = std.json.Array.init(allocator);
    var commands = std.json.Array.init(allocator);
    var seen_files = std.ArrayList([]const u8).empty;
    defer seen_files.deinit(allocator);
    defer freeStringList(allocator, seen_files.items);

    var dir = try std.Io.Dir.openDirAbsolute(a.io, a.workspace.root, .{ .iterate = true });
    defer dir.close(a.io);
    var walker = try dir.walk(allocator);
    defer walker.deinit();
    var count: usize = 0;
    var skipped_files: usize = 0;
    var walk_errors: usize = 0;
    while (true) {
        const maybe_entry = walker.next(a.io) catch {
            walk_errors += 1;
            break;
        };
        const entry = maybe_entry orelse break;
        if (count >= limit) break;
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".zig") or analysis.skipWorkspacePath(entry.path)) continue;
        const contents = a.workspace.readFileAlloc(a.io, entry.path, 512 * 1024) catch {
            skipped_files += 1;
            continue;
        };
        defer allocator.free(contents);
        var file_test_count: usize = 0;
        var lines = std.mem.splitScalar(u8, contents, '\n');
        var line_no: usize = 1;
        while (lines.next()) |line| : (line_no += 1) {
            if (count >= limit) break;
            const trimmed = std.mem.trim(u8, line, " \t");
            if (!std.mem.startsWith(u8, trimmed, "test ")) continue;
            count += 1;
            file_test_count += 1;
            var item = std.json.ObjectMap.empty;
            try item.put(allocator, "file", try ownedString(allocator, entry.path));
            try item.put(allocator, "line", .{ .integer = @intCast(line_no) });
            try item.put(allocator, "name", if (testNameFromLine(trimmed)) |name| try ownedString(allocator, name) else .null);
            try item.put(allocator, "declaration", try ownedString(allocator, trimmed));
            try item.put(allocator, "likely_symbols", try likelySymbolsFromTestNameValue(allocator, testNameFromLine(trimmed) orelse trimmed));
            try item.put(allocator, "command", .{ .string = try std.fmt.allocPrint(allocator, "zig test {s}", .{entry.path}) });
            try tests.append(.{ .object = item });
        }
        if (file_test_count > 0) {
            try appendUniqueString(allocator, &seen_files, entry.path);
            try files.append(try ownedString(allocator, entry.path));
            try appendUniqueCommand(allocator, &commands, try std.fmt.allocPrint(allocator, "zig test {s}", .{entry.path}));
        }
    }
    try appendUniqueCommand(allocator, &commands, "zig build test");
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zig_test_map" });
    try obj.put(allocator, "analysis_kind", .{ .string = "heuristic_test_declaration_scan" });
    try obj.put(allocator, "confidence", .{ .string = "medium" });
    try obj.put(allocator, "tests", .{ .array = tests });
    try obj.put(allocator, "test_files", .{ .array = files });
    try obj.put(allocator, "commands", .{ .array = commands });
    try obj.put(allocator, "count", .{ .integer = @intCast(count) });
    try obj.put(allocator, "skipped_files", .{ .integer = @intCast(skipped_files) });
    try obj.put(allocator, "walk_errors", .{ .integer = @intCast(walk_errors) });
    return .{ .object = obj };
}

fn testSelectValue(allocator: std.mem.Allocator, a: *App, files_text: ?[]const u8, symbols_text: ?[]const u8, limit: usize) !std.json.Value {
    var files = std.ArrayList([]const u8).empty;
    defer files.deinit(allocator);
    defer freeStringList(allocator, files.items);
    try appendPathTokens(allocator, &files, files_text);
    var symbols = std.ArrayList([]const u8).empty;
    defer symbols.deinit(allocator);
    defer freeStringList(allocator, symbols.items);
    try appendPathTokens(allocator, &symbols, symbols_text);

    var commands = std.json.Array.init(allocator);
    var reasons = std.json.Array.init(allocator);
    for (files.items) |file| {
        if (std.mem.endsWith(u8, file, ".zig") and workspacePathExists(allocator, a, file)) {
            try appendUniqueCommand(allocator, &commands, try std.fmt.allocPrint(allocator, "zig test {s}", .{file}));
            try reasons.append(.{ .string = try std.fmt.allocPrint(allocator, "{s}: touched Zig file", .{file}) });
        }
    }

    const map = try testMapValue(allocator, a, limit);
    const tests = map.object.get("tests") orelse .null;
    if (tests == .array) {
        for (tests.array.items) |test_value| {
            const test_obj = switch (test_value) {
                .object => |o| o,
                else => continue,
            };
            const test_file = switch (test_obj.get("file") orelse .null) {
                .string => |s| s,
                else => continue,
            };
            const name = switch (test_obj.get("name") orelse .null) {
                .string => |s| s,
                else => "",
            };
            for (symbols.items) |symbol| {
                if (std.mem.indexOf(u8, name, symbol) != null or std.mem.indexOf(u8, test_file, symbol) != null) {
                    try appendUniqueCommand(allocator, &commands, try std.fmt.allocPrint(allocator, "zig test {s} --test-filter {s}", .{ test_file, symbol }));
                    try reasons.append(.{ .string = try std.fmt.allocPrint(allocator, "{s}: matched test name/file", .{symbol}) });
                }
            }
        }
    }
    try appendUniqueCommand(allocator, &commands, "zig build test");
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zig_test_select" });
    try obj.put(allocator, "commands", .{ .array = commands });
    try obj.put(allocator, "reasons", .{ .array = reasons });
    try obj.put(allocator, "fallback", .{ .string = "zig build test" });
    return .{ .object = obj };
}

fn testNameFromLine(line: []const u8) ?[]const u8 {
    const rest = std.mem.trim(u8, line["test ".len..], " \t");
    if (rest.len == 0) return null;
    if (rest[0] == '"') return quotedString(rest);
    const end = std.mem.indexOfAny(u8, rest, " {(") orelse rest.len;
    return rest[0..end];
}

fn likelySymbolsFromTestNameValue(allocator: std.mem.Allocator, name: []const u8) !std.json.Value {
    var symbols = std.json.Array.init(allocator);
    var tokens = std.mem.tokenizeAny(u8, name, " .:_-/\t\r\n\"");
    while (tokens.next()) |token| {
        if (token.len < 3) continue;
        if (std.ascii.isUpper(token[0])) try symbols.append(try ownedString(allocator, token));
    }
    return .{ .array = symbols };
}

fn failureFusionValue(allocator: std.mem.Allocator, stderr: []const u8, stdout: []const u8, argv: []const []const u8, ok: bool) !std.json.Value {
    const compiler = try compilerErrorIndexValue(allocator, stderr, stdout, argv);
    const tests = try testFailureTriageValue(allocator, stderr, stdout, argv, ok);
    var suggested = std.json.Array.init(allocator);
    try suggested.append(try ownedString(allocator, "zigar_impact"));
    try suggested.append(try ownedString(allocator, "zig_test_select"));
    try suggested.append(try ownedString(allocator, "zigar_validate_patch"));

    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zigar_failure_fusion" });
    try obj.put(allocator, "ok", .{ .bool = ok });
    try obj.put(allocator, "compiler", compiler);
    try obj.put(allocator, "tests", tests);
    try obj.put(allocator, "primary_failure", try primaryFailureValue(allocator, compiler, tests));
    try obj.put(allocator, "suggested_tools", .{ .array = suggested });
    try obj.put(allocator, "rerun_command", .{ .string = try commandString(allocator, argv) });
    return .{ .object = obj };
}

fn primaryFailureValue(allocator: std.mem.Allocator, compiler: std.json.Value, tests: std.json.Value) !std.json.Value {
    const compiler_obj = switch (compiler) {
        .object => |o| o,
        else => return .null,
    };
    const summary = compiler_obj.get("summary") orelse .null;
    if (summary == .object) {
        const primary = summary.object.get("primary") orelse .null;
        if (primary != .null) return primary;
    }
    const tests_obj = switch (tests) {
        .object => |o| o,
        else => return .null,
    };
    const failures = tests_obj.get("failures") orelse .null;
    if (failures == .array and failures.array.items.len > 0) return failures.array.items[0];
    _ = allocator;
    return .null;
}

fn impactValue(allocator: std.mem.Allocator, a: *App, files_text: ?[]const u8, symbols_text: ?[]const u8, limit: usize) !std.json.Value {
    var files = std.ArrayList([]const u8).empty;
    defer files.deinit(allocator);
    defer freeStringList(allocator, files.items);
    try appendPathTokens(allocator, &files, files_text);
    var symbols = std.ArrayList([]const u8).empty;
    defer symbols.deinit(allocator);
    defer freeStringList(allocator, symbols.items);
    try appendPathTokens(allocator, &symbols, symbols_text);

    var importers = std.json.Array.init(allocator);
    var symbol_hits = std.json.Array.init(allocator);
    var public_api = std.json.Array.init(allocator);
    var commands = std.json.Array.init(allocator);
    var likely_tests = std.json.Array.init(allocator);

    var dir = try std.Io.Dir.openDirAbsolute(a.io, a.workspace.root, .{ .iterate = true });
    defer dir.close(a.io);
    var walker = try dir.walk(allocator);
    defer walker.deinit();
    var seen: usize = 0;
    while ((walker.next(a.io) catch null)) |entry| {
        if (seen >= limit) break;
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".zig") or analysis.skipWorkspacePath(entry.path)) continue;
        const contents = a.workspace.readFileAlloc(a.io, entry.path, 512 * 1024) catch continue;
        defer allocator.free(contents);
        seen += 1;
        for (files.items) |target| {
            if (importsTarget(contents, target)) {
                try importers.append(try impactHitValue(allocator, entry.path, target, "imports_target"));
            }
            if (std.mem.eql(u8, entry.path, target)) {
                try appendUniqueCommand(allocator, &commands, try std.fmt.allocPrint(allocator, "zig ast-check {s}", .{target}));
                try appendUniqueCommand(allocator, &commands, try std.fmt.allocPrint(allocator, "zig test {s}", .{target}));
                try appendPublicDeclsForFile(allocator, &public_api, target, contents);
            }
            if (looksLikeTestFile(entry.path) and referencesFileStem(contents, target)) {
                try likely_tests.append(try impactHitValue(allocator, entry.path, target, "test_references_file"));
            }
        }
        for (symbols.items) |symbol| {
            if (std.mem.indexOf(u8, contents, symbol) != null) {
                try symbol_hits.append(try impactHitValue(allocator, entry.path, symbol, "symbol_reference"));
                if (looksLikeTestFile(entry.path)) try likely_tests.append(try impactHitValue(allocator, entry.path, symbol, "test_references_symbol"));
            }
        }
    }
    try appendUniqueCommand(allocator, &commands, "zig build test");

    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zigar_impact" });
    try obj.put(allocator, "analysis_kind", .{ .string = "heuristic_import_symbol_test_scan" });
    try obj.put(allocator, "confidence", .{ .string = "medium" });
    try obj.put(allocator, "direct_importers", .{ .array = importers });
    try obj.put(allocator, "symbol_hits", .{ .array = symbol_hits });
    try obj.put(allocator, "likely_tests", .{ .array = likely_tests });
    try obj.put(allocator, "public_api", .{ .array = public_api });
    try obj.put(allocator, "recommended_commands", .{ .array = commands });
    return .{ .object = obj };
}

fn impactHitValue(allocator: std.mem.Allocator, file: []const u8, target: []const u8, reason: []const u8) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "file", try ownedString(allocator, file));
    try obj.put(allocator, "target", try ownedString(allocator, target));
    try obj.put(allocator, "reason", .{ .string = reason });
    return .{ .object = obj };
}

fn importsTarget(contents: []const u8, target: []const u8) bool {
    const base = std.fs.path.basename(target);
    return std.mem.indexOf(u8, contents, base) != null or std.mem.indexOf(u8, contents, target) != null;
}

fn referencesFileStem(contents: []const u8, target: []const u8) bool {
    const base = std.fs.path.basename(target);
    const dot = std.mem.lastIndexOfScalar(u8, base, '.') orelse base.len;
    if (dot == 0) return false;
    return std.mem.indexOf(u8, contents, base[0..dot]) != null;
}

fn looksLikeTestFile(path: []const u8) bool {
    return std.mem.indexOf(u8, path, "test") != null or std.mem.endsWith(u8, path, "_test.zig");
}

fn appendPublicDeclsForFile(allocator: std.mem.Allocator, out: *std.json.Array, file: []const u8, contents: []const u8) !void {
    var lines = std.mem.splitScalar(u8, contents, '\n');
    var line_no: usize = 1;
    while (lines.next()) |line| : (line_no += 1) {
        const trimmed = std.mem.trim(u8, line, " \t");
        if (!std.mem.startsWith(u8, trimmed, "pub ")) continue;
        if (analysis.declKind(trimmed)) |kind| {
            var obj = std.json.ObjectMap.empty;
            try obj.put(allocator, "file", try ownedString(allocator, file));
            try obj.put(allocator, "line", .{ .integer = @intCast(line_no) });
            try obj.put(allocator, "kind", .{ .string = kind });
            try obj.put(allocator, "name", if (declName(trimmed, kind)) |name| try ownedString(allocator, name) else .null);
            try obj.put(allocator, "signature", try ownedString(allocator, trimmed));
            try out.append(.{ .object = obj });
        }
    }
}

fn generatedProjectProfileValue(allocator: std.mem.Allocator, a: *App) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "schema_version", .{ .integer = 1 });
    try obj.put(allocator, "workspace", .{ .string = a.workspace.root });
    try obj.put(allocator, "project_type", try projectTypeValue(allocator, a));
    try obj.put(allocator, "quality", try qualityCommandsValue(allocator, a));
    try obj.put(allocator, "generated_dirs", try generatedDirsValue(allocator));
    try obj.put(allocator, "agent_entrypoint", .{ .string = "zigar_context_pack" });
    return .{ .object = obj };
}

fn generatedDirsValue(allocator: std.mem.Allocator) !std.json.Value {
    var dirs = std.json.Array.init(allocator);
    for ([_][]const u8{ ".zig-cache", ".zigar-cache", "zig-out", "zig-pkg", "coverage" }) |dir| {
        try dirs.append(try ownedString(allocator, dir));
    }
    return .{ .array = dirs };
}

fn publicApiDiffValue(allocator: std.mem.Allocator, file: ?[]const u8, before: []const u8, after: []const u8) !std.json.Value {
    const before_decls = try publicDeclSnapshotValue(allocator, file, before);
    const after_decls = try publicDeclSnapshotValue(allocator, file, after);
    var added = std.json.Array.init(allocator);
    var removed = std.json.Array.init(allocator);
    var changed = std.json.Array.init(allocator);
    try comparePublicDecls(allocator, before_decls.array, after_decls.array, &added, &removed, &changed);

    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zig_public_api_diff" });
    if (file) |path| try obj.put(allocator, "file", try ownedString(allocator, path)) else try obj.put(allocator, "file", .null);
    try obj.put(allocator, "before", before_decls);
    try obj.put(allocator, "after", after_decls);
    try obj.put(allocator, "added", .{ .array = added });
    try obj.put(allocator, "removed", .{ .array = removed });
    try obj.put(allocator, "changed", .{ .array = changed });
    try obj.put(allocator, "breaking_change_risk", .{ .bool = removed.items.len > 0 or changed.items.len > 0 });
    return .{ .object = obj };
}

fn publicDeclSnapshotValue(allocator: std.mem.Allocator, file: ?[]const u8, contents: []const u8) !std.json.Value {
    var decls = std.json.Array.init(allocator);
    var lines = std.mem.splitScalar(u8, contents, '\n');
    var line_no: usize = 1;
    while (lines.next()) |line| : (line_no += 1) {
        const trimmed = std.mem.trim(u8, line, " \t");
        if (!std.mem.startsWith(u8, trimmed, "pub ")) continue;
        const kind = analysis.declKind(trimmed) orelse continue;
        var obj = std.json.ObjectMap.empty;
        if (file) |path| try obj.put(allocator, "file", try ownedString(allocator, path)) else try obj.put(allocator, "file", .null);
        try obj.put(allocator, "line", .{ .integer = @intCast(line_no) });
        try obj.put(allocator, "kind", .{ .string = kind });
        try obj.put(allocator, "name", if (declName(trimmed, kind)) |name| try ownedString(allocator, name) else .null);
        try obj.put(allocator, "signature", try ownedString(allocator, trimmed));
        try decls.append(.{ .object = obj });
    }
    return .{ .array = decls };
}

fn comparePublicDecls(allocator: std.mem.Allocator, before: std.json.Array, after: std.json.Array, added: *std.json.Array, removed: *std.json.Array, changed: *std.json.Array) !void {
    for (after.items) |after_decl| {
        const key = declKey(after_decl) orelse continue;
        const match = findDeclByKey(before, key);
        if (match) |before_decl| {
            if (!std.mem.eql(u8, declSignature(before_decl) orelse "", declSignature(after_decl) orelse "")) {
                var item = std.json.ObjectMap.empty;
                try item.put(allocator, "before", before_decl);
                try item.put(allocator, "after", after_decl);
                try changed.append(.{ .object = item });
            }
        } else {
            try added.append(after_decl);
        }
    }
    for (before.items) |before_decl| {
        const key = declKey(before_decl) orelse continue;
        if (findDeclByKey(after, key) == null) try removed.append(before_decl);
    }
}

fn declKey(value: std.json.Value) ?[]const u8 {
    const obj = switch (value) {
        .object => |o| o,
        else => return null,
    };
    return switch (obj.get("name") orelse .null) {
        .string => |s| s,
        else => null,
    };
}

fn declSignature(value: std.json.Value) ?[]const u8 {
    const obj = switch (value) {
        .object => |o| o,
        else => return null,
    };
    return switch (obj.get("signature") orelse .null) {
        .string => |s| s,
        else => null,
    };
}

fn findDeclByKey(array: std.json.Array, key: []const u8) ?std.json.Value {
    for (array.items) |item| {
        if (declKey(item)) |candidate| {
            if (std.mem.eql(u8, candidate, key)) return item;
        }
    }
    return null;
}

fn cachePathStatusValue(allocator: std.mem.Allocator, a: *App, path: []const u8) !std.json.Value {
    const resolved = a.workspace.resolve(path) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => a.workspace.resolveOutput(path) catch null,
    };
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "path", try ownedString(allocator, path));
    if (resolved) |abs| {
        defer allocator.free(abs);
        try obj.put(allocator, "abs", try ownedString(allocator, abs));
        const count = countTopLevelEntries(allocator, a.io, abs) catch null;
        if (count) |n| {
            try obj.put(allocator, "exists", .{ .bool = true });
            try obj.put(allocator, "kind", .{ .string = "directory" });
            try obj.put(allocator, "entry_count", .{ .integer = @intCast(n) });
        } else if (std.Io.Dir.cwd().readFileAlloc(a.io, abs, allocator, .limited(1)) catch null) |bytes| {
            allocator.free(bytes);
            try obj.put(allocator, "exists", .{ .bool = true });
            try obj.put(allocator, "kind", .{ .string = "file" });
            try obj.put(allocator, "entry_count", .null);
        } else {
            try obj.put(allocator, "exists", .{ .bool = false });
            try obj.put(allocator, "kind", .null);
            try obj.put(allocator, "entry_count", .null);
        }
    } else {
        try obj.put(allocator, "abs", .null);
        try obj.put(allocator, "exists", .{ .bool = false });
        try obj.put(allocator, "kind", .null);
        try obj.put(allocator, "entry_count", .null);
    }
    return .{ .object = obj };
}

fn countTopLevelEntries(allocator: std.mem.Allocator, io: std.Io, abs: []const u8) !usize {
    var dir = try std.Io.Dir.openDirAbsolute(io, abs, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(allocator);
    defer walker.deinit();
    var count: usize = 0;
    while ((walker.next(io) catch null)) |entry| {
        if (std.mem.indexOfScalar(u8, entry.path, std.fs.path.sep) == null) count += 1;
    }
    return count;
}

fn gitTracksPath(allocator: std.mem.Allocator, a: *App, path: []const u8, timeout_ms: i64) !bool {
    const result = command.run(allocator, a.io, a.workspace.root, &.{ "git", "ls-files", "--error-unmatch", path }, @min(timeout_ms, 3000)) catch return false;
    defer result.deinit(allocator);
    return result.succeeded();
}

fn zigCiAnnotations(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const file = argString(args, "file") orelse return error.InvalidArguments;
    const resolved = a.workspace.resolve(file) catch |err| return workspacePathErrorResult(a, allocator, "zig_ci_annotations", file, err);
    defer allocator.free(resolved);
    a.command_calls += 1;
    const result = command.run(allocator, a.io, a.workspace.root, &.{ a.config.zig_path, "ast-check", resolved }, toolTimeout(a, args)) catch |err| return errorText(allocator, @errorName(err));
    defer result.deinit(allocator);
    var annotations = std.json.Array.init(allocator);
    tryParseAnnotations(allocator, &annotations, file, result.stderr) catch return error.OutOfMemory;
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    obj.put(allocator, "ok", .{ .bool = result.succeeded() }) catch return error.OutOfMemory;
    obj.put(allocator, "annotations", .{ .array = annotations }) catch return error.OutOfMemory;
    obj.put(allocator, "raw", commandResultValue(allocator, "zig ast-check", &.{ a.config.zig_path, "ast-check", resolved }, a.workspace.root, toolTimeout(a, args), result) catch return error.OutOfMemory) catch return error.OutOfMemory;
    return structured(allocator, .{ .object = obj });
}

fn tryParseAnnotations(allocator: std.mem.Allocator, annotations: *std.json.Array, default_file: []const u8, stderr: []const u8) !void {
    var lines = std.mem.splitScalar(u8, stderr, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var file = default_file;
        var line_no: i64 = 1;
        var col_no: i64 = 1;
        if (std.mem.indexOf(u8, line, ".zig:")) |zig_pos| {
            const prefix_end = zig_pos + ".zig".len;
            file = line[0..prefix_end];
            var rest = line[prefix_end..];
            if (std.mem.startsWith(u8, rest, ":")) rest = rest[1..];
            if (std.mem.indexOfScalar(u8, rest, ':')) |line_end| {
                line_no = std.fmt.parseInt(i64, rest[0..line_end], 10) catch 1;
                const after_line = rest[line_end + 1 ..];
                if (std.mem.indexOfScalar(u8, after_line, ':')) |col_end| {
                    col_no = std.fmt.parseInt(i64, after_line[0..col_end], 10) catch 1;
                }
            }
        }
        var obj = std.json.ObjectMap.empty;
        try obj.put(allocator, "path", .{ .string = file });
        try obj.put(allocator, "start_line", .{ .integer = line_no });
        try obj.put(allocator, "start_column", .{ .integer = col_no });
        try obj.put(allocator, "annotation_level", .{ .string = "failure" });
        try obj.put(allocator, "message", .{ .string = line });
        try annotations.append(.{ .object = obj });
    }
}

fn xmlEscape(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (input) |c| {
        switch (c) {
            '&' => try out.appendSlice(allocator, "&amp;"),
            '<' => try out.appendSlice(allocator, "&lt;"),
            '>' => try out.appendSlice(allocator, "&gt;"),
            '"' => try out.appendSlice(allocator, "&quot;"),
            '\'' => try out.appendSlice(allocator, "&apos;"),
            else => try out.append(allocator, c),
        }
    }
    return out.toOwnedSlice(allocator);
}

fn zigJunit(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    var list: std.ArrayList([]const u8) = .empty;
    defer list.deinit(allocator);
    var resolved_file: ?[]const u8 = null;
    defer if (resolved_file) |path| allocator.free(path);
    list.append(allocator, a.config.zig_path) catch return error.OutOfMemory;
    if (argString(args, "file")) |file| {
        resolved_file = a.workspace.resolve(file) catch |err| return workspacePathErrorResult(a, allocator, "zig_junit", file, err);
        list.append(allocator, "test") catch return error.OutOfMemory;
        list.append(allocator, resolved_file.?) catch return error.OutOfMemory;
        if (argString(args, "filter")) |filter| {
            list.append(allocator, "--test-filter") catch return error.OutOfMemory;
            list.append(allocator, filter) catch return error.OutOfMemory;
        }
    } else {
        list.append(allocator, "build") catch return error.OutOfMemory;
        list.append(allocator, "test") catch return error.OutOfMemory;
    }
    const extra = try splitToolArgs(allocator, argString(args, "args"));
    defer freeArgList(allocator, extra);
    list.appendSlice(allocator, extra) catch return error.OutOfMemory;
    a.command_calls += 1;
    const result = command.run(allocator, a.io, a.workspace.root, list.items, toolTimeout(a, args)) catch |err| return errorText(allocator, @errorName(err));
    defer result.deinit(allocator);
    const stdout_xml = xmlEscape(allocator, result.stdout) catch return error.OutOfMemory;
    defer allocator.free(stdout_xml);
    const stderr_xml = xmlEscape(allocator, result.stderr) catch return error.OutOfMemory;
    defer allocator.free(stderr_xml);
    const failure_xml = if (result.succeeded())
        allocator.dupe(u8, "") catch return error.OutOfMemory
    else
        allocator.dupe(u8, "<failure message=\"zig test failed\"/>") catch return error.OutOfMemory;
    defer allocator.free(failure_xml);
    const xml = std.fmt.allocPrint(allocator,
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<testsuite name="zigar" tests="1" failures="{d}">
        \\  <testcase classname="zig" name="zig test">
        \\    {s}
        \\  </testcase>
        \\  <system-out>{s}</system-out>
        \\  <system-err>{s}</system-err>
        \\</testsuite>
        \\
    , .{ if (result.succeeded()) @as(i32, 0) else @as(i32, 1), failure_xml, stdout_xml, stderr_xml }) catch return error.OutOfMemory;
    defer allocator.free(xml);
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    obj.put(allocator, "ok", .{ .bool = result.succeeded() }) catch return error.OutOfMemory;
    obj.put(allocator, "junit_xml", .{ .string = xml }) catch return error.OutOfMemory;
    obj.put(allocator, "command", commandResultValue(allocator, "zig test", list.items, a.workspace.root, toolTimeout(a, args), result) catch return error.OutOfMemory) catch return error.OutOfMemory;
    return structured(allocator, .{ .object = obj });
}

fn zigMatrixCheck(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const paths_text = argString(args, "zig_paths") orelse a.config.zig_path;
    var paths = std.mem.tokenizeAny(u8, paths_text, ", \t\r\n");
    var results = std.json.Array.init(allocator);
    while (paths.next()) |zig_path| {
        const extra = try splitToolArgs(allocator, argString(args, "args"));
        defer freeArgList(allocator, extra);
        const argv = command.joinArgv(allocator, &.{ zig_path, "build", "test" }, extra) catch return error.OutOfMemory;
        defer allocator.free(argv);
        a.command_calls += 1;
        const run = command.run(allocator, a.io, a.workspace.root, argv, toolTimeout(a, args)) catch |err| {
            var err_obj = std.json.ObjectMap.empty;
            err_obj.put(allocator, "zig", .{ .string = zig_path }) catch return error.OutOfMemory;
            err_obj.put(allocator, "ok", .{ .bool = false }) catch return error.OutOfMemory;
            err_obj.put(allocator, "error", .{ .string = @errorName(err) }) catch return error.OutOfMemory;
            results.append(.{ .object = err_obj }) catch return error.OutOfMemory;
            continue;
        };
        defer run.deinit(allocator);
        var item = std.json.ObjectMap.empty;
        item.put(allocator, "zig", .{ .string = zig_path }) catch return error.OutOfMemory;
        item.put(allocator, "result", commandResultValue(allocator, "zig build test", argv, a.workspace.root, toolTimeout(a, args), run) catch return error.OutOfMemory) catch return error.OutOfMemory;
        results.append(.{ .object = item }) catch return error.OutOfMemory;
    }
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    obj.put(allocator, "results", .{ .array = results }) catch return error.OutOfMemory;
    return structured(allocator, .{ .object = obj });
}

fn zigWorkspaceSymbols(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const query = argString(args, "query") orelse return error.InvalidArguments;
    if (a.lsp_client) |client| {
        if (requireZlsCapability(a, allocator, "workspace/symbol")) |result| return result;
        const Params = struct { query: []const u8 };
        a.zls_requests += 1;
        const response = client.sendRequest(allocator, "workspace/symbol", Params{ .query = query }) catch |err| return backendErrorResult(allocator, "zls", "workspace/symbol", err, "ZLS workspace symbol search failed; zigar will use heuristic analysis when no ZLS client is available");
        defer allocator.free(response);
        return lspStructuredTool(allocator, "workspace/symbol", response);
    }
    const graph = analysis.importGraph(allocator, a.io, a.workspace.root, @intCast(@max(1, argInt(args, "limit", 200)))) catch return error.ExecutionFailed;
    defer allocator.free(graph);
    const msg = std.fmt.allocPrint(allocator, "Heuristic workspace symbol search for `{s}` is currently import/declaration text based.\n\n{s}", .{ query, graph }) catch return error.OutOfMemory;
    defer allocator.free(msg);
    return structuredText(allocator, "zig_workspace_symbols_fallback", msg);
}

fn zigLint(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return runZwanzig(a, allocator, args, "json");
}

fn zigLintSarif(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return runZwanzig(a, allocator, args, "sarif");
}

fn runZwanzig(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value, format: []const u8) mcp.tools.ToolError!mcp.tools.ToolResult {
    var list: std.ArrayList([]const u8) = .empty;
    defer list.deinit(allocator);
    var resolved_config: ?[]const u8 = null;
    defer if (resolved_config) |path| allocator.free(path);
    list.append(allocator, a.config.zwanzig_path) catch return error.OutOfMemory;
    list.append(allocator, "--format") catch return error.OutOfMemory;
    list.append(allocator, format) catch return error.OutOfMemory;
    if (argString(args, "config")) |path| {
        resolved_config = a.workspace.resolve(path) catch |err| return workspacePathErrorResult(a, allocator, "zig_lint", path, err);
        list.append(allocator, "--config") catch return error.OutOfMemory;
        list.append(allocator, resolved_config.?) catch return error.OutOfMemory;
    }
    if (argString(args, "rules_do")) |rules| {
        list.append(allocator, "--do") catch return error.OutOfMemory;
        list.append(allocator, rules) catch return error.OutOfMemory;
    }
    if (argString(args, "rules_skip")) |rules| {
        list.append(allocator, "--skip") catch return error.OutOfMemory;
        list.append(allocator, rules) catch return error.OutOfMemory;
    }
    const path = argString(args, "path") orelse ".";
    const resolved_path = a.workspace.resolve(path) catch |err| return workspacePathErrorResult(a, allocator, "zig_lint", path, err);
    defer allocator.free(resolved_path);
    list.append(allocator, resolved_path) catch return error.OutOfMemory;
    const extra = try splitToolArgs(allocator, argString(args, "args"));
    defer freeArgList(allocator, extra);
    list.appendSlice(allocator, extra) catch return error.OutOfMemory;
    return runAndFormat(a, allocator, list.items, "zwanzig");
}

fn zigLintRules(a: *App, allocator: std.mem.Allocator, _: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return runAndFormat(a, allocator, &.{ a.config.zwanzig_path, "--help" }, "zwanzig rules/help");
}

fn zigAnalysisGraphs(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const path = argString(args, "path") orelse return error.InvalidArguments;
    const output = argString(args, "output") orelse return error.InvalidArguments;
    const resolved_path = a.workspace.resolve(path) catch |err| return workspacePathErrorResult(a, allocator, "zig_analysis_graphs", path, err);
    defer allocator.free(resolved_path);
    const resolved_output = a.workspace.resolveOutput(output) catch |err| return workspacePathErrorResult(a, allocator, "zig_analysis_graphs", output, err);
    defer allocator.free(resolved_output);
    const extra = try splitToolArgs(allocator, argString(args, "args"));
    defer freeArgList(allocator, extra);
    const base = &.{ a.config.zwanzig_path, "--dot", resolved_output, resolved_path };
    const argv = command.joinArgv(allocator, base, extra) catch return error.OutOfMemory;
    defer allocator.free(argv);
    return runAndFormat(a, allocator, argv, "zwanzig graph");
}

fn zigProfilePlan(_: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const binary = argString(args, "binary") orelse "zig-out/bin/<app>";
    const msg = std.fmt.allocPrint(allocator,
        \\Profiling plan for {s}
        \\
        \\1. Build with symbols: zig build -Doptimize=ReleaseFast
        \\2. Capture with the platform profiler:
        \\   macOS: xcrun xctrace record --template "Time Profiler" --launch -- {s}
        \\   Linux: perf record -F 997 -g -- {s}
        \\3. Convert profiler output to a supported zflame input.
        \\4. Use zig_flamegraph with format=guess|perf|dtrace|sample|vtune|xctrace.
        \\5. For comparisons, generate folded stacks for before/after and call zig_flamegraph_diff.
        \\
    , .{ binary, binary, binary }) catch return error.OutOfMemory;
    defer allocator.free(msg);
    return structuredText(allocator, "zig_profile_plan", msg);
}

fn zigProfileRun(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const cmd = argString(args, "command") orelse return error.InvalidArguments;
    const split = try splitToolArgs(allocator, cmd);
    defer freeArgList(allocator, split);
    if (split.len == 0) return error.InvalidArguments;
    return runAndFormatTimeout(a, allocator, split, "profile command", toolTimeout(a, args));
}

fn zigFlamegraph(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const format = argString(args, "format") orelse "guess";
    const input = argString(args, "input") orelse return error.InvalidArguments;
    const output = argString(args, "output") orelse return error.InvalidArguments;
    const input_abs = a.workspace.resolve(input) catch |err| return workspacePathErrorResult(a, allocator, "zig_flamegraph", input, err);
    defer allocator.free(input_abs);
    const output_abs = a.workspace.resolveOutput(output) catch |err| return workspacePathErrorResult(a, allocator, "zig_flamegraph", output, err);
    defer allocator.free(output_abs);

    var list: std.ArrayList([]const u8) = .empty;
    defer list.deinit(allocator);
    list.appendSlice(allocator, &.{ a.config.zflame_path, format }) catch return error.OutOfMemory;
    if (argString(args, "title")) |title_value| {
        list.appendSlice(allocator, &.{ "--title", title_value }) catch return error.OutOfMemory;
    }
    if (argString(args, "palette")) |palette| {
        list.appendSlice(allocator, &.{ "--palette", palette }) catch return error.OutOfMemory;
    }
    if (argString(args, "min_width")) |min_width| {
        list.appendSlice(allocator, &.{ "--min-width", min_width }) catch return error.OutOfMemory;
    }
    if (argBool(args, "hash", false)) {
        list.append(allocator, "--hash") catch return error.OutOfMemory;
    }
    list.append(allocator, input_abs) catch return error.OutOfMemory;

    const result = command.run(allocator, a.io, a.workspace.root, list.items, a.config.timeout_ms) catch |err| {
        return backendErrorResult(allocator, "zflame", "render", err, "confirm --zflame-path points to an executable zflame binary and that profiler input is readable");
    };
    defer result.deinit(allocator);
    if (!result.succeeded()) {
        const run_output = command.formatRunResult(allocator, "zflame failed", result) catch return error.OutOfMemory;
        defer allocator.free(run_output);
        return errorText(allocator, run_output);
    }
    a.workspace.writeFile(a.io, output, result.stdout) catch return error.ExecutionFailed;
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    obj.put(allocator, "kind", .{ .string = "zig_flamegraph" }) catch return error.OutOfMemory;
    obj.put(allocator, "output", .{ .string = output }) catch return error.OutOfMemory;
    obj.put(allocator, "output_abs", .{ .string = output_abs }) catch return error.OutOfMemory;
    obj.put(allocator, "format", .{ .string = format }) catch return error.OutOfMemory;
    obj.put(allocator, "bytes", .{ .integer = @intCast(result.stdout.len) }) catch return error.OutOfMemory;
    return structured(allocator, .{ .object = obj });
}

fn zigFlamegraphDiff(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const before = argString(args, "before") orelse return error.InvalidArguments;
    const after = argString(args, "after") orelse return error.InvalidArguments;
    const output = argString(args, "output") orelse return error.InvalidArguments;
    const before_abs = a.workspace.resolve(before) catch |err| return workspacePathErrorResult(a, allocator, "zig_flamegraph_diff", before, err);
    defer allocator.free(before_abs);
    const after_abs = a.workspace.resolve(after) catch |err| return workspacePathErrorResult(a, allocator, "zig_flamegraph_diff", after, err);
    defer allocator.free(after_abs);
    const temp_id = a.temp_counter.fetchAdd(1, .monotonic);
    const folded_name = std.fmt.allocPrint(allocator, "diff-{d}.folded", .{temp_id}) catch return error.OutOfMemory;
    defer allocator.free(folded_name);
    const folded_out = std.fs.path.join(allocator, &.{ ".zigar-cache", "profile", folded_name }) catch return error.OutOfMemory;
    defer allocator.free(folded_out);
    const folded_abs = a.workspace.resolveOutput(folded_out) catch |err| return workspacePathErrorResult(a, allocator, "zig_flamegraph_diff", folded_out, err);
    defer allocator.free(folded_abs);
    const diff = command.run(allocator, a.io, a.workspace.root, &.{ a.config.diff_folded_path, before_abs, after_abs }, a.config.timeout_ms) catch |err| {
        return backendErrorResult(allocator, "diff-folded", "diff", err, "confirm --diff-folded-path points to an executable diff-folded binary and both folded inputs are readable");
    };
    defer diff.deinit(allocator);
    if (!diff.succeeded()) {
        const run_output = command.formatRunResult(allocator, "diff-folded failed", diff) catch return error.OutOfMemory;
        defer allocator.free(run_output);
        return errorText(allocator, run_output);
    }
    a.workspace.writeFile(a.io, folded_out, diff.stdout) catch return error.ExecutionFailed;
    var obj = std.json.ObjectMap.empty;
    obj.put(allocator, "input", .{ .string = folded_out }) catch return error.OutOfMemory;
    obj.put(allocator, "output", .{ .string = output }) catch return error.OutOfMemory;
    if (argString(args, "title")) |title_value| obj.put(allocator, "title", .{ .string = title_value }) catch return error.OutOfMemory;
    const tmp_args = std.json.Value{ .object = obj };
    return zigFlamegraph(a, allocator, tmp_args);
}

fn workspaceResource(a: *App, allocator: std.mem.Allocator, uri: []const u8) mcp.resources.ResourceError!mcp.resources.ResourceContent {
    const body = std.fmt.allocPrint(allocator, "workspace={s}\ncache={s}\nzig={s}\nzwanzig={s}\nzflame={s}\n", .{ a.workspace.root, a.workspace.cache_root, a.config.zig_path, a.config.zwanzig_path, a.config.zflame_path }) catch return error.OutOfMemory;
    return .{ .uri = uri, .mimeType = "text/plain", .text = body };
}

fn jsonResource(allocator: std.mem.Allocator, uri: []const u8, value: std.json.Value) mcp.resources.ResourceError!mcp.resources.ResourceContent {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    std.json.Stringify.value(value, .{ .whitespace = .indent_2 }, &aw.writer) catch return error.Unknown;
    return .{ .uri = uri, .mimeType = "application/json", .text = aw.toOwnedSlice() catch return error.OutOfMemory };
}

fn zlsStatusResource(a: *App, allocator: std.mem.Allocator, uri: []const u8) mcp.resources.ResourceError!mcp.resources.ResourceContent {
    var value = zlsStatusValue(allocator, a) catch return error.Unknown;
    var obj = &value.object;
    if (a.zls_initialize_response) |response| {
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, response, .{}) catch null;
        if (parsed) |p| {
            defer p.deinit();
            const caps = if (responseResult(p.value)) |result| switch (result) {
                .object => |result_obj| result_obj.get("capabilities") orelse .null,
                else => .null,
            } else .null;
            var cap_json: std.ArrayList(u8) = .empty;
            errdefer cap_json.deinit(allocator);
            json_result.serializeValue(allocator, &cap_json, caps) catch return error.Unknown;
            obj.put(allocator, "server_capabilities_json", .{ .string = cap_json.toOwnedSlice(allocator) catch return error.OutOfMemory }) catch return error.OutOfMemory;
        }
    }
    return jsonResource(allocator, uri, value);
}

fn capabilitiesResource(_: *App, allocator: std.mem.Allocator, uri: []const u8) mcp.resources.ResourceError!mcp.resources.ResourceContent {
    return catalogResource(allocator, uri);
}

fn schemaResource(_: *App, allocator: std.mem.Allocator, uri: []const u8) mcp.resources.ResourceError!mcp.resources.ResourceContent {
    return catalogResource(allocator, uri);
}

fn catalogResource(allocator: std.mem.Allocator, uri: []const u8) mcp.resources.ResourceError!mcp.resources.ResourceContent {
    const body = catalog.text(allocator) catch return error.ReadFailed;
    return .{ .uri = uri, .mimeType = "application/json", .text = body };
}

fn importGraphResource(a: *App, allocator: std.mem.Allocator, uri: []const u8) mcp.resources.ResourceError!mcp.resources.ResourceContent {
    const body = analysis.importGraph(allocator, a.io, a.workspace.root, 200) catch return error.ReadFailed;
    return .{ .uri = uri, .mimeType = "text/plain", .text = body };
}

fn metricsResource(a: *App, allocator: std.mem.Allocator, uri: []const u8) mcp.resources.ResourceError!mcp.resources.ResourceContent {
    const value = metricsValue(a, allocator) catch return error.Unknown;
    return jsonResource(allocator, uri, value);
}

fn profilePrompt(_: *App, allocator: std.mem.Allocator, _: ?std.json.Value) mcp.prompts.PromptError![]const mcp.prompts.PromptMessage {
    const messages = allocator.alloc(mcp.prompts.PromptMessage, 1) catch return error.OutOfMemory;
    messages[0] = mcp.prompts.userMessage("Use zigar_workspace_info, zig_profile_plan, zig_profile_run, zig_flamegraph, and zig_flamegraph_diff to build a deterministic Zig profiling workflow. Do not edit source files unless an explicit tool argument requires apply=true.");
    return messages;
}

fn zigEnvValue(a: *App, allocator: std.mem.Allocator, key: []const u8) ![]u8 {
    const result = try command.run(allocator, a.io, a.workspace.root, &.{ a.config.zig_path, "env" }, a.config.timeout_ms);
    defer result.deinit(allocator);
    const needle = try std.fmt.allocPrint(allocator, ".{s} = \"", .{key});
    defer allocator.free(needle);
    const start_needle = std.mem.indexOf(u8, result.stdout, needle) orelse return error.NotFound;
    const start = start_needle + needle.len;
    const end = std.mem.indexOfScalarPos(u8, result.stdout, start, '"') orelse return error.NotFound;
    return allocator.dupe(u8, result.stdout[start..end]);
}

fn makeArgs2(allocator: std.mem.Allocator, key1: []const u8, value1: []const u8, key2: []const u8, value2: i64) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, key1, .{ .string = value1 });
    try obj.put(allocator, key2, .{ .integer = value2 });
    return .{ .object = obj };
}

fn freeArgList(allocator: std.mem.Allocator, args: []const []const u8) void {
    for (args) |arg| allocator.free(arg);
    allocator.free(args);
}

test "schema with required field" {
    var s = try tooling.buildInputSchema(std.testing.allocator, tooling.schema(&.{.{ "file", "string", true }}));
    defer if (s.required) |required| std.testing.allocator.free(required);
    defer if (s.properties) |*properties| {
        var it = properties.object.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.object.deinit(std.testing.allocator);
        }
        properties.object.deinit(std.testing.allocator);
    };
    try std.testing.expectEqualStrings("object", s.type);
}

test "workspace path error messages distinguish empty and outside paths" {
    const allocator = std.testing.allocator;
    const empty = try workspacePathErrorMessage(allocator, "zig_check", "", "/tmp/workspace", error.EmptyPath);
    defer allocator.free(empty);
    try std.testing.expect(std.mem.indexOf(u8, empty, "empty path") != null);
    try std.testing.expect(std.mem.indexOf(u8, empty, "/tmp/workspace") != null);

    const outside = try workspacePathErrorMessage(allocator, "zig_check", "../x.zig", "/tmp/workspace", error.PathOutsideWorkspace);
    defer allocator.free(outside);
    try std.testing.expect(std.mem.indexOf(u8, outside, "../x.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, outside, "outside the configured") != null);
}

test "capabilities index exposes formatting discovery keywords" {
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, tooling.catalog_json, .{});
    defer parsed.deinit();

    try std.testing.expect(std.mem.indexOf(u8, tooling.catalog_json, "\"zig_format\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, tooling.catalog_json, "\"zig_format_check\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, tooling.catalog_json, "\"zigar_schema\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, tooling.catalog_json, "\"zigar_doctor\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, tooling.catalog_json, "\"fmt\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, tooling.catalog_json, "\"formatter\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, tooling.catalog_json, "\"zig fmt\"") != null);
}

test "catalog groups match tool registry" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const parsed = try catalog.parsed(allocator);

    const root = parsed.value.object;
    const groups = root.get("groups").?.array;
    const tool_arguments = root.get("registry_tool_arguments").?.object;

    var grouped_count: usize = 0;
    for (groups.items) |group_value| {
        const tools = group_value.object.get("tools").?.array;
        for (tools.items) |tool_value| {
            const tool_name = tool_value.string;
            grouped_count += 1;
            try std.testing.expect(tool_metadata.find(tool_name) != null);
            if (tool_metadata.find(tool_name)) |spec| {
                if (spec.input_schema.fields.len > 0) {
                    try std.testing.expect(tool_arguments.get(tool_name) != null);
                }
            }
        }
    }
    try std.testing.expectEqual(tool_metadata.specs.len, grouped_count);
}

test "registry catalog arguments can be derived from tool registry" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const parsed = try catalog.parsed(arena.allocator());

    const tool_arguments = parsed.value.object.get("registry_tool_arguments").?.object;
    const zig_format = tool_arguments.get("zig_format").?.object;
    try std.testing.expectEqualStrings("string", zig_format.get("required").?.object.get("file").?.string);
    try std.testing.expectEqualStrings("boolean", zig_format.get("optional").?.object.get("apply").?.string);
    try std.testing.expectEqualStrings("high", zig_format.get("risk").?.object.get("level").?.string);
    try std.testing.expect(zig_format.get("risk").?.object.get("writes_source").?.bool);
    try std.testing.expect(zig_format.get("risk").?.object.get("writes_artifacts").?.bool);
    try std.testing.expect(zig_format.get("risk").?.object.get("writes_require_apply").?.bool);
    try std.testing.expect(zig_format.get("risk").?.object.get("preview_by_default").?.bool);
    const profile_run = tool_arguments.get("zig_profile_run").?.object;
    try std.testing.expect(profile_run.get("risk").?.object.get("executes_user_command").?.bool);
    const matrix_check = tool_arguments.get("zig_matrix_check").?.object;
    try std.testing.expect(matrix_check.get("risk").?.object.get("executes_user_command").?.bool);
    const validate_patch = tool_arguments.get("zigar_validate_patch").?.object;
    try std.testing.expectEqualStrings("medium", validate_patch.get("risk").?.object.get("level").?.string);
    try std.testing.expect(validate_patch.get("risk").?.object.get("executes_project_code").?.bool);
    try std.testing.expect(validate_patch.get("risk").?.object.get("writes_artifacts").?.bool);
}

test "zigar_schema exposes registry-derived risk metadata" {
    const allocator = std.testing.allocator;
    const result = try zigarSchema(allocator, null);
    defer allocator.free(result.content);
    const body = result.content[0].text.text;
    defer allocator.free(body);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();
    const args = parsed.value.object.get("registry_tool_arguments").?.object;
    const validate_patch = args.get("zigar_validate_patch").?.object;
    try std.testing.expect(validate_patch.get("risk").?.object.get("executes_project_code").?.bool);
}

fn testAppForCommandPlanning(allocator: std.mem.Allocator) !App {
    return .{
        .allocator = allocator,
        .io = std.testing.io,
        .config = .{ .workspace = "/tmp", .zig_path = "zig" },
        .workspace = try workspace_mod.Workspace.init(allocator, std.testing.io, "/tmp", null, false),
    };
}

test "zig_command_plan exposes registry risk metadata" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var app = try testAppForCommandPlanning(allocator);

    var args = std.json.ObjectMap.empty;
    try args.put(allocator, "tool", .{ .string = "zig_test" });
    const result = try zigCommandPlan(&app, allocator, .{ .object = args });
    const body = result.content[0].text.text;
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    const root = parsed.value.object;
    const risk = root.get("risk").?.object;

    try std.testing.expectEqualStrings("zig_test", root.get("tool").?.string);
    try std.testing.expectEqualStrings("medium", root.get("risk_level").?.string);
    try std.testing.expectEqualStrings("medium", risk.get("level").?.string);
    try std.testing.expect(risk.get("executes_project_code").?.bool);
    try std.testing.expect(risk.get("writes_artifacts").?.bool);
    try std.testing.expect(!root.get("writes_source").?.bool);
}

test "explain command setup errors use the calling tool name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var app = try testAppForCommandPlanning(allocator);

    var args = std.json.ObjectMap.empty;
    try args.put(allocator, "command", .{ .string = "check" });
    try args.put(allocator, "file", .{ .string = "/zigar-outside-workspace.zig" });

    const explain = try zigExplainErrors(&app, allocator, .{ .object = args });
    try std.testing.expect(std.mem.indexOf(u8, explain.content[0].text.text, "zig_explain_errors") != null);

    const index = try zigCompileErrorIndex(&app, allocator, .{ .object = args });
    try std.testing.expect(std.mem.indexOf(u8, index.content[0].text.text, "zig_compile_error_index") != null);

    const fusion = try zigarFailureFusion(&app, allocator, .{ .object = args });
    try std.testing.expect(std.mem.indexOf(u8, fusion.content[0].text.text, "zigar_failure_fusion") != null);
}

test "catalog derives compact argument hints from registry metadata" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const parsed_catalog = try catalog.parsed(arena.allocator());
    const tool_arguments = parsed_catalog.value.object.get("registry_tool_arguments").?.object;
    const zig_format = tool_arguments.get("zig_format").?.object;
    try std.testing.expectEqualStrings("string", zig_format.get("required").?.object.get("file").?.string);
    try std.testing.expectEqualStrings("boolean", zig_format.get("optional").?.object.get("apply").?.string);
    const doctor_args = tool_arguments.get("zigar_doctor").?.object.get("optional").?.object;
    try std.testing.expectEqualStrings("boolean", doctor_args.get("probe_backends").?.string);
}

test "tool argument validation returns structured errors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const spec = tool_metadata.find("zig_check").?;

    const missing_obj = std.json.ObjectMap.empty;
    const missing = try tool_registry.validateToolArgs(allocator, spec, .{ .object = missing_obj });
    try std.testing.expect(missing != null);

    var wrong_type_obj = std.json.ObjectMap.empty;
    try wrong_type_obj.put(allocator, "file", .{ .integer = 42 });
    const wrong_type = try tool_registry.validateToolArgs(allocator, spec, .{ .object = wrong_type_obj });
    try std.testing.expect(wrong_type != null);

    var valid_obj = std.json.ObjectMap.empty;
    try valid_obj.put(allocator, "file", .{ .string = "src/main.zig" });
    try std.testing.expect((try tool_registry.validateToolArgs(allocator, spec, .{ .object = valid_obj })) == null);
}

test "command error value declares output limit policy" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const value = try commandErrorValue(arena.allocator(), "large command", &.{ "zig", "build" }, "/tmp/project", 1000, error.StreamTooLong);
    const obj = value.object;
    try std.testing.expectEqualStrings("command_error", obj.get("kind").?.string);
    try std.testing.expectEqualStrings(command.output_limit_mode, obj.get("output_limit_mode").?.string);
    try std.testing.expect(obj.get("output_limit_exceeded").?.bool);
    try std.testing.expect(obj.get("note") != null);
}

test "backend error value uses stable structured fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const value = try backendErrorValue(arena.allocator(), "zls", "textDocument/hover", error.RequestTimeout, "retry later");
    const obj = value.object;
    try std.testing.expectEqualStrings("backend_error", obj.get("kind").?.string);
    try std.testing.expectEqualStrings("zls", obj.get("backend").?.string);
    try std.testing.expectEqualStrings("textDocument/hover", obj.get("operation").?.string);
    try std.testing.expectEqualStrings("timeout", obj.get("error_kind").?.string);
}

test "errorText owns borrowed message bytes" {
    var result = try errorText(std.testing.allocator, "borrowed diagnostic error");
    defer {
        if (result.structuredContent) |*structured_value| {
            switch (structured_value.*) {
                .object => |*object| object.deinit(std.testing.allocator),
                else => {},
            }
        }
        std.testing.allocator.free(result.content[0].text.text);
        std.testing.allocator.free(result.content);
    }

    try std.testing.expect(result.is_error);
    try std.testing.expectEqualStrings("borrowed diagnostic error", result.content[0].text.text);
}

test "skipWorkspacePath ignores generated and vendored paths" {
    try std.testing.expect(analysis.skipWorkspacePath(".zig-cache/o/main.zig"));
    try std.testing.expect(analysis.skipWorkspacePath(".zigar-cache/profile/main.zig"));
    try std.testing.expect(analysis.skipWorkspacePath("zig-out/bin/main.zig"));
    try std.testing.expect(analysis.skipWorkspacePath("zig-pkg/mcp/src/main.zig"));
    try std.testing.expect(!analysis.skipWorkspacePath("src/main.zig"));
}

test "xmlEscape keeps junit output well formed" {
    const escaped = try xmlEscape(std.testing.allocator, "a<b>&\"'");
    defer std.testing.allocator.free(escaped);
    try std.testing.expectEqualStrings("a&lt;b&gt;&amp;&quot;&apos;", escaped);
}

test "json serialization emits strings for byte-backed text and escapes controls" {
    var obj = std.json.ObjectMap.empty;
    defer obj.deinit(std.testing.allocator);
    const bytes = try std.testing.allocator.dupe(u8, "a\x1bb");
    defer std.testing.allocator.free(bytes);
    try obj.put(std.testing.allocator, "text", .{ .string = bytes });

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    try json_result.serializeValue(std.testing.allocator, &out, .{ .object = obj });
    try std.testing.expectEqualStrings("{\"text\":\"a\\u001bb\"}", out.items);
}

test "parseCompilerLine extracts located Zig errors" {
    const parsed = parseCompilerLine("src/main.zig:12:5: error: expected type 'u8', found 'u16'") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("error", parsed.severity);
    try std.testing.expectEqualStrings("src/main.zig", parsed.path.?);
    try std.testing.expectEqual(@as(i64, 12), parsed.line.?);
    try std.testing.expectEqual(@as(i64, 5), parsed.column.?);
    try std.testing.expectEqualStrings("type_mismatch", classifyDiagnosticMessage(parsed.message));
}

test "parseCompilerLine handles unlocated compiler errors" {
    const parsed = parseCompilerLine("error: the following command failed with 1 compilation errors") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("error", parsed.severity);
    try std.testing.expect(parsed.path == null);
    try std.testing.expectEqualStrings("the following command failed with 1 compilation errors", parsed.message);
}

test "build metadata helpers parse common build.zig patterns" {
    try std.testing.expectEqualStrings("exe", ownerVarName("const exe = b.addExecutable(.{").?);
    try std.testing.expectEqualStrings("test", buildNameFromCall("const test_step = b.step(\"test\", \"Run tests\");").?);
    try std.testing.expectEqualStrings("src/main.zig", buildPathFromLine(".root_source_file = b.path(\"src/main.zig\"),").?);
    try std.testing.expectEqualStrings("mcp", dependencyNameFromLine(".mcp = .{").?);
    try std.testing.expectEqualStrings("target", optionNameFromLine("const t = b.option([]const u8, \"target\", \"Target\");").?);
    try std.testing.expectEqualStrings("[]const u8", optionTypeFromLine("const t = b.option([]const u8, \"target\", \"Target\");").?);
    try std.testing.expectEqualStrings("zigar", quotedString(".name = \"zigar\",").?);
}

test "relativeImportCandidate resolves beside source file" {
    const candidate = try relativeImportCandidate(std.testing.allocator, "src/root.zig", "config.zig");
    defer std.testing.allocator.free(candidate);
    try std.testing.expectEqualStrings("src/config.zig", candidate);
}

test "new planning helpers parse stable text formats" {
    try std.testing.expectEqualStrings("src/new.zig", statusLinePath("R  src/old.zig -> src/new.zig"));
    try std.testing.expectEqualStrings("src/main.zig", statusLinePath(" M src/main.zig"));
    try std.testing.expectEqualStrings("mcp", dependencyBlockNameFromLine(".mcp = .{").?);
    try std.testing.expect(dependencyBlockNameFromLine(".url = \"https://example\"") == null);
    try std.testing.expectEqualStrings("main", declName("pub fn main() void {}", "fn").?);
    try std.testing.expect(std.mem.indexOf(u8, targetMatrixNote("wasm32-freestanding"), "freestanding") != null);
}

test "toolchain version helpers distinguish minimum hints from exact pins" {
    try std.testing.expect(versionMeetsMinimum("0.16.0", "0.15.1"));
    try std.testing.expect(versionMeetsMinimum("0.16.0-dev.732+abc", "0.16.0"));
    try std.testing.expect(!versionMeetsMinimum("0.15.0", "0.16.0"));
    try std.testing.expect(parseVersionPrefix("master") == null);

    var minimum_hint = std.json.ObjectMap.empty;
    defer minimum_hint.deinit(std.testing.allocator);
    try minimum_hint.put(std.testing.allocator, "key", .{ .string = "minimum_zig_version" });
    try minimum_hint.put(std.testing.allocator, "version", .{ .string = "0.16.0" });
    try std.testing.expectEqual(ZigVersionHintStatus.minimum_satisfied, zigVersionHintStatus("0.16.1", minimum_hint));

    var zls_hint = std.json.ObjectMap.empty;
    defer zls_hint.deinit(std.testing.allocator);
    try zls_hint.put(std.testing.allocator, "key", .{ .string = "zls" });
    try zls_hint.put(std.testing.allocator, "version", .{ .string = "0.16.0" });
    try std.testing.expectEqual(ZigVersionHintStatus.ignored, zigVersionHintStatus("0.16.0", zls_hint));
}

test "compiler error index groups findings by file" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const value = try compilerErrorIndexValue(arena.allocator(), "src/main.zig:1:2: error: bad\nsrc/main.zig:1:2: note: detail\n", "", &.{"zig"});
    const obj = value.object;
    try std.testing.expectEqualStrings("zig_compile_error_index", obj.get("kind").?.string);
    try std.testing.expectEqual(@as(i64, 1), obj.get("summary").?.object.get("error_count").?.integer);
    try std.testing.expectEqual(@as(usize, 1), obj.get("files").?.array.items.len);
}

test "agent workflow helpers parse patch paths and test names" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    try std.testing.expectEqualStrings("Foo.init handles defaults", testNameFromLine("test \"Foo.init handles defaults\" {").?);

    var paths = std.ArrayList([]const u8).empty;
    try appendPatchPaths(allocator, &paths,
        \\diff --git a/src/old.zig b/src/new.zig
        \\--- a/src/old.zig
        \\+++ b/src/new.zig
        \\
    );
    try std.testing.expectEqual(@as(usize, 2), paths.items.len);
    try std.testing.expect(stringListContains(paths.items, "src/old.zig"));
    try std.testing.expect(stringListContains(paths.items, "src/new.zig"));
}

test "public api diff detects breaking removal and additions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const value = try publicApiDiffValue(arena.allocator(), "src/api.zig",
        \\pub fn oldName() void {}
        \\pub const Same = struct {};
        \\
    ,
        \\pub fn newName() void {}
        \\pub const Same = struct {};
        \\
    );
    const obj = value.object;
    try std.testing.expect(obj.get("breaking_change_risk").?.bool);
    try std.testing.expectEqual(@as(usize, 1), obj.get("removed").?.array.items.len);
    try std.testing.expectEqual(@as(usize, 1), obj.get("added").?.array.items.len);
}

test "failure summary suggests agent diagnostic tools" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const insights = try compilerInsightsValue(allocator, "", "src/main.zig:1:2: error: expected type 'u8', found 'u16'\n", &.{ "zig", "build" });
    const summary = try failureSummaryValue(allocator, insights, false, &.{ "zig", "build" });
    const obj = summary.object;
    try std.testing.expectEqualStrings("type_mismatch", obj.get("error_class").?.string);
    try std.testing.expectEqualStrings("source_file", obj.get("likely_scope").?.string);
    try std.testing.expect(obj.get("suggested_tools").?.array.items.len >= 2);
}
