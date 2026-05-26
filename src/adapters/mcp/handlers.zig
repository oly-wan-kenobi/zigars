const std = @import("std");
const mcp = @import("mcp");

const app_context = @import("../../app/context.zig");
const handler_refs = @import("handler_refs.zig");
const manifest = @import("../../manifest/mod.zig");
const mcp_errors = @import("errors.zig");
const mcp_result = @import("result.zig");
const patch_sessions = @import("../../app/usecases/editing/patch_sessions.zig");
const registry = @import("registry.zig");

const mcp_tools = struct {
    pub const artifacts = @import("tools/artifacts.zig");
    pub const core = @import("tools/core.zig");
    pub const dependencies = @import("tools/dependencies.zig");
    pub const diagnostics = @import("tools/diagnostics.zig");
    pub const discovery = @import("tools/discovery.zig");
    pub const environment = @import("tools/environment.zig");
    pub const observability = @import("tools/runtime_metrics.zig");
    pub const performance = @import("tools/performance.zig");
    pub const profiling = @import("tools/profiling.zig");
    pub const project_intelligence = @import("tools/project_intelligence.zig");
    pub const release = @import("tools/release.zig");
    pub const result_shape = @import("tools/result_shape.zig");
    pub const runtime_ux = @import("tools/runtime_ux.zig");
    pub const static_analysis = @import("tools/static_analysis.zig");
    pub const static_source_summary = @import("tools/static_source_summary.zig");
    pub const transactional_editing = @import("tools/transactional_editing.zig");
    pub const zls = @import("tools/zls.zig");
};

pub fn handlerFor(
    comptime id: manifest.ToolId,
    comptime RuntimePtr: type,
    comptime RuntimePorts: type,
    comptime RuntimePortOptions: type,
) registry.ToolHandler(RuntimePtr) {
    return handler(@tagName(id), handler_refs.handlerFor(id), RuntimePtr, RuntimePorts, RuntimePortOptions);
}

fn handler(
    comptime tool_name: []const u8,
    comptime ref: handler_refs.HandlerRef,
    comptime RuntimePtr: type,
    comptime RuntimePorts: type,
    comptime RuntimePortOptions: type,
) registry.ToolHandler(RuntimePtr) {
    return switch (ref.module) {
        .discovery => adapterHandler(mcp_tools.discovery, tool_name, ref.name, RuntimePtr, RuntimePorts, RuntimePortOptions, .{}),
        .artifacts => adapterHandler(mcp_tools.artifacts, tool_name, ref.name, RuntimePtr, RuntimePorts, RuntimePortOptions, .{ .workspace_read_resolution = .input }),
        .core => adapterHandler(mcp_tools.core, tool_name, ref.name, RuntimePtr, RuntimePorts, RuntimePortOptions, coreOptions(RuntimePortOptions, ref.name)),
        .edit_zls => adapterHandler(mcp_tools.zls, tool_name, ref.name, RuntimePtr, RuntimePorts, RuntimePortOptions, .{ .workspace_read_resolution = .input, .record_command_observability = true }),
        .edit_zls_diagnostics => adapterHandler(mcp_tools.zls, tool_name, ref.name, RuntimePtr, RuntimePorts, RuntimePortOptions, .{ .workspace_read_resolution = .input, .record_command_observability = true }),
        .observability => adapterHandler(mcp_tools.observability, tool_name, ref.name, RuntimePtr, RuntimePorts, RuntimePortOptions, .{}),
        .result_shape => adapterHandler(mcp_tools.result_shape, tool_name, ref.name, RuntimePtr, RuntimePorts, RuntimePortOptions, .{}),
        .transactional_editing => adapterHandler(mcp_tools.transactional_editing, tool_name, ref.name, RuntimePtr, RuntimePorts, RuntimePortOptions, .{ .workspace_read_resolution = .output, .default_read_limit = patch_sessions.max_session_file_bytes }),

        .adoption => adapterHandler(mcp_tools.environment, tool_name, ref.name, RuntimePtr, RuntimePorts, RuntimePortOptions, .{ .record_command_observability = true }),
        .agent => adapterHandler(mcp_tools.project_intelligence, tool_name, ref.name, RuntimePtr, RuntimePorts, RuntimePortOptions, .{ .workspace_read_resolution = .input }),
        .ci => adapterHandler(mcp_tools.release, tool_name, ref.name, RuntimePtr, RuntimePorts, RuntimePortOptions, .{ .record_command_observability = true }),
        .diagnostics => adapterHandler(mcp_tools.diagnostics, tool_name, ref.name, RuntimePtr, RuntimePorts, RuntimePortOptions, .{ .record_command_observability = true }),
        .docs => adapterHandler(mcp_tools.release, tool_name, ref.name, RuntimePtr, RuntimePorts, RuntimePortOptions, .{ .workspace_read_resolution = .input }),
        .environment_profiles => adapterHandler(mcp_tools.environment, tool_name, ref.name, RuntimePtr, RuntimePorts, RuntimePortOptions, .{ .record_command_observability = true }),
        .performance => adapterHandler(mcp_tools.performance, tool_name, ref.name, RuntimePtr, RuntimePorts, RuntimePortOptions, .{ .record_command_observability = true }),
        .phase6 => adapterHandler(migrated_phase6, tool_name, ref.name, RuntimePtr, RuntimePorts, RuntimePortOptions, .{ .record_command_observability = true }),
        .profiling => adapterHandler(mcp_tools.profiling, tool_name, ref.name, RuntimePtr, RuntimePorts, RuntimePortOptions, .{}),
        .release_drift => adapterHandler(mcp_tools.release, tool_name, ref.name, RuntimePtr, RuntimePorts, RuntimePortOptions, .{ .record_command_observability = true }),
        .runtime_ux => adapterHandler(mcp_tools.runtime_ux, tool_name, ref.name, RuntimePtr, RuntimePorts, RuntimePortOptions, runtimeUxOptions(RuntimePortOptions, ref.name)),
        .static_analysis => adapterHandler(migrated_static_analysis, tool_name, ref.name, RuntimePtr, RuntimePorts, RuntimePortOptions, .{ .workspace_read_resolution = .input }),
        .trust => adapterHandler(mcp_tools.environment, tool_name, ref.name, RuntimePtr, RuntimePorts, RuntimePortOptions, .{ .record_command_observability = true }),
        .validation_workflows => adapterHandler(mcp_tools.project_intelligence, tool_name, ref.name, RuntimePtr, RuntimePorts, RuntimePortOptions, .{ .workspace_read_resolution = .input }),
        .zwanzig => adapterHandler(mcp_tools.static_analysis, tool_name, ref.name, RuntimePtr, RuntimePorts, RuntimePortOptions, .{ .workspace_read_resolution = .input }),
    };
}

fn adapterHandler(
    comptime module: type,
    comptime tool_name: []const u8,
    comptime name: []const u8,
    comptime RuntimePtr: type,
    comptime RuntimePorts: type,
    comptime RuntimePortOptions: type,
    comptime options: RuntimePortOptions,
) registry.ToolHandler(RuntimePtr) {
    const adapter_fn = @field(module, name);
    const info = @typeInfo(@TypeOf(adapter_fn)).@"fn";
    if (info.params.len == 2) {
        return struct {
            fn call(_: RuntimePtr, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
                return adapter_fn(allocator, args);
            }
        }.call;
    }

    const ContextType = info.params[1].type.?;
    return struct {
        fn call(app: RuntimePtr, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
            var runtime_ports = RuntimePorts.init(app, options);
            runtime_ports.refreshDerivedPorts();
            const context = buildContext(ContextType, &runtime_ports) catch |err| {
                return contextError(ContextType, allocator, tool_name, err);
            };
            return adapter_fn(allocator, context, args);
        }
    }.call;
}

fn buildContext(comptime ContextType: type, runtime_ports: anytype) app_context.ContextError!ContextType {
    if (ContextType == app_context.Context) return runtime_ports.context();
    if (ContextType == app_context.AdoptionContext) return runtime_ports.adoptionContext();
    if (ContextType == app_context.ArtifactContext) return runtime_ports.artifactContext();
    if (ContextType == app_context.CoreCommandContext) return runtime_ports.coreContext();
    if (ContextType == app_context.DiagnosticsContext) return runtime_ports.diagnosticsContext();
    if (ContextType == app_context.EnvironmentContext) return runtime_ports.environmentContext();
    if (ContextType == app_context.PerformanceContext) return runtime_ports.performanceContext();
    if (ContextType == app_context.ProfilingContext) return runtime_ports.profilingContext();
    if (ContextType == app_context.ProjectIntelligenceContext) return runtime_ports.projectIntelligenceContext();
    if (ContextType == app_context.ObservabilityContext) return runtime_ports.observabilityContext();
    if (ContextType == app_context.ReleaseDocsContext) return runtime_ports.releaseDocsContext();
    if (ContextType == app_context.ReleaseWorkflowContext) return runtime_ports.releaseWorkflowContext();
    if (ContextType == app_context.RuntimeUxContext) return runtime_ports.runtimeUxContext();
    if (ContextType == app_context.StaticAnalysisContext) return runtime_ports.context().staticAnalysis();
    if (ContextType == app_context.TrustContext) return runtime_ports.trustContext();
    @compileError("unsupported MCP adapter context type");
}

fn contextError(
    comptime ContextType: type,
    allocator: std.mem.Allocator,
    tool_name: []const u8,
    err: anyerror,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    return mcp_errors.fromError(allocator, .{
        .tool = tool_name,
        .operation = contextOperation(ContextType),
        .phase = "build_app_context",
        .code = contextCode(ContextType),
        .category = "configuration",
        .resolution = contextResolution(ContextType),
    }, err);
}

fn contextOperation(comptime ContextType: type) []const u8 {
    if (ContextType == app_context.Context) return "app_context";
    if (ContextType == app_context.AdoptionContext) return "adoption_context";
    if (ContextType == app_context.ArtifactContext) return "artifact_context";
    if (ContextType == app_context.CoreCommandContext) return "core_command_context";
    if (ContextType == app_context.DiagnosticsContext) return "diagnostics_context";
    if (ContextType == app_context.EnvironmentContext) return "environment_context";
    if (ContextType == app_context.PerformanceContext) return "performance_context";
    if (ContextType == app_context.ProfilingContext) return "profiling_context";
    if (ContextType == app_context.ProjectIntelligenceContext) return "project_intelligence_context";
    if (ContextType == app_context.ObservabilityContext) return "observability_context";
    if (ContextType == app_context.ReleaseDocsContext) return "release_docs_context";
    if (ContextType == app_context.ReleaseWorkflowContext) return "release_workflow_context";
    if (ContextType == app_context.RuntimeUxContext) return "runtime_ux_context";
    if (ContextType == app_context.StaticAnalysisContext) return "static_analysis_context";
    if (ContextType == app_context.TrustContext) return "trust_context";
    @compileError("unsupported MCP adapter context type");
}

fn contextCode(comptime ContextType: type) []const u8 {
    if (ContextType == app_context.Context) return "app_context_unavailable";
    if (ContextType == app_context.AdoptionContext) return "adoption_context_unavailable";
    if (ContextType == app_context.ArtifactContext) return "artifact_context_unavailable";
    if (ContextType == app_context.CoreCommandContext) return "core_command_context_unavailable";
    if (ContextType == app_context.DiagnosticsContext) return "diagnostics_context_unavailable";
    if (ContextType == app_context.EnvironmentContext) return "environment_context_unavailable";
    if (ContextType == app_context.PerformanceContext) return "performance_context_unavailable";
    if (ContextType == app_context.ProfilingContext) return "profiling_context_unavailable";
    if (ContextType == app_context.ProjectIntelligenceContext) return "project_intelligence_context_unavailable";
    if (ContextType == app_context.ObservabilityContext) return "observability_context_unavailable";
    if (ContextType == app_context.ReleaseDocsContext) return "release_context_unavailable";
    if (ContextType == app_context.ReleaseWorkflowContext) return "release_context_unavailable";
    if (ContextType == app_context.RuntimeUxContext) return "runtime_ux_context_unavailable";
    if (ContextType == app_context.StaticAnalysisContext) return "static_analysis_context_unavailable";
    if (ContextType == app_context.TrustContext) return "trust_context_unavailable";
    @compileError("unsupported MCP adapter context type");
}

fn contextResolution(comptime ContextType: type) []const u8 {
    if (ContextType == app_context.Context) return "The discovery use case requires the runtime app context projection and typed ports from the runtime bridge.";
    if (ContextType == app_context.ArtifactContext) return "The artifact registry use case requires workspace ports from the runtime bridge.";
    if (ContextType == app_context.CoreCommandContext) return "The core command use case requires command runner and workspace ports from the runtime bridge.";
    if (ContextType == app_context.ProfilingContext) return "The profiling use case requires command runner and workspace ports from the runtime bridge.";
    if (ContextType == app_context.RuntimeUxContext) return "The runtime UX use case requires runtime session, command runner, workspace, catalog, and clock ports from the runtime bridge.";
    if (ContextType == app_context.StaticAnalysisContext) return "The static-analysis use case requires workspace, scanner, cache, command, and observability ports from the runtime bridge.";
    return "The migrated MCP handler requires typed app ports from the runtime bridge.";
}

fn coreOptions(comptime RuntimePortOptions: type, comptime name: []const u8) RuntimePortOptions {
    const records_command = !std.mem.eql(u8, name, "zigVersion");
    return .{
        .non_exited_exit_code = 0,
        .count_command_calls = records_command,
        .record_command_observability = records_command,
    };
}

fn runtimeUxOptions(comptime RuntimePortOptions: type, comptime name: []const u8) RuntimePortOptions {
    return .{
        .workspace_read_resolution = .input,
        .record_command_observability = std.mem.eql(u8, name, "zigarJobStart") or std.mem.eql(u8, name, "zigarRunStream"),
    };
}

test "context metadata covers every migrated handler context" {
    const Case = struct {
        context_type: type,
        operation: []const u8,
        code: []const u8,
    };
    const cases = [_]Case{
        .{ .context_type = app_context.Context, .operation = "app_context", .code = "app_context_unavailable" },
        .{ .context_type = app_context.AdoptionContext, .operation = "adoption_context", .code = "adoption_context_unavailable" },
        .{ .context_type = app_context.ArtifactContext, .operation = "artifact_context", .code = "artifact_context_unavailable" },
        .{ .context_type = app_context.CoreCommandContext, .operation = "core_command_context", .code = "core_command_context_unavailable" },
        .{ .context_type = app_context.DiagnosticsContext, .operation = "diagnostics_context", .code = "diagnostics_context_unavailable" },
        .{ .context_type = app_context.EnvironmentContext, .operation = "environment_context", .code = "environment_context_unavailable" },
        .{ .context_type = app_context.PerformanceContext, .operation = "performance_context", .code = "performance_context_unavailable" },
        .{ .context_type = app_context.ProfilingContext, .operation = "profiling_context", .code = "profiling_context_unavailable" },
        .{ .context_type = app_context.ProjectIntelligenceContext, .operation = "project_intelligence_context", .code = "project_intelligence_context_unavailable" },
        .{ .context_type = app_context.ObservabilityContext, .operation = "observability_context", .code = "observability_context_unavailable" },
        .{ .context_type = app_context.ReleaseDocsContext, .operation = "release_docs_context", .code = "release_context_unavailable" },
        .{ .context_type = app_context.ReleaseWorkflowContext, .operation = "release_workflow_context", .code = "release_context_unavailable" },
        .{ .context_type = app_context.RuntimeUxContext, .operation = "runtime_ux_context", .code = "runtime_ux_context_unavailable" },
        .{ .context_type = app_context.StaticAnalysisContext, .operation = "static_analysis_context", .code = "static_analysis_context_unavailable" },
        .{ .context_type = app_context.TrustContext, .operation = "trust_context", .code = "trust_context_unavailable" },
    };

    inline for (cases) |case| {
        try std.testing.expectEqualStrings(case.operation, contextOperation(case.context_type));
        try std.testing.expectEqualStrings(case.code, contextCode(case.context_type));
        try std.testing.expect(contextResolution(case.context_type).len > 0);
    }
}

test "adapter handler maps missing runtime context to structured tool error" {
    const Options = struct {};
    const Runtime = struct {
        fail_context: bool = false,
    };
    const RuntimePorts = struct {
        fail_context: bool,

        pub fn init(runtime: *Runtime, _: Options) @This() {
            return .{ .fail_context = runtime.fail_context };
        }

        pub fn refreshDerivedPorts(_: *@This()) void {}

        pub fn artifactContext(self: *@This()) app_context.ContextError!app_context.ArtifactContext {
            if (self.fail_context) return error.MissingPort;
            return .{ .workspace = .{}, .workspace_store = undefined };
        }
    };
    const Adapter = struct {
        pub fn needsArtifact(_: std.mem.Allocator, _: app_context.ArtifactContext, _: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
            return .{ .content = &.{} };
        }
    };

    const call = adapterHandler(Adapter, "fixture_artifact", "needsArtifact", *Runtime, RuntimePorts, Options, .{});
    var ok_runtime = Runtime{};
    const ok_result = try call(&ok_runtime, std.testing.allocator, null);
    mcp_result.deinitToolResult(std.testing.allocator, ok_result);

    var failing_runtime = Runtime{ .fail_context = true };
    const error_result = try call(&failing_runtime, std.testing.allocator, null);
    defer mcp_result.deinitToolResult(std.testing.allocator, error_result);
    try std.testing.expect(error_result.is_error);
    const obj = error_result.structuredContent.?.object;
    try std.testing.expectEqualStrings("fixture_artifact", obj.get("tool").?.string);
    try std.testing.expectEqualStrings("artifact_context_unavailable", obj.get("code").?.string);
    try std.testing.expectEqualStrings("MissingPort", obj.get("error").?.string);
}

const migrated_phase6 = struct {
    pub const zigCiIngest = mcp_tools.release.zigCiIngest;
    pub const zigCiReproPlan = mcp_tools.release.zigCiReproPlan;
    pub const zigCiFailureMap = mcp_tools.release.zigCiFailureMap;
    pub const zigReleasePlan = mcp_tools.release.zigReleasePlan;
    pub const zigSemverSuggest = mcp_tools.release.zigSemverSuggest;
    pub const zigReleaseNotesDraft = mcp_tools.release.zigReleaseNotesDraft;
    pub const zigReleaseEvidencePack = mcp_tools.release.zigReleaseEvidencePack;
    pub const zigApiBaselineInit = mcp_tools.release.zigApiBaselineInit;
    pub const zigApiCheck = mcp_tools.release.zigApiCheck;
    pub const zigApiDiffBaseline = mcp_tools.release.zigApiDiffBaseline;
    pub const zigApiDocsDiff = mcp_tools.release.zigApiDocsDiff;
    pub const zigDocsIndexBuild = mcp_tools.release.zigDocsIndexBuild;
    pub const zigDocsQuery = mcp_tools.release.zigDocsQuery;
    pub const zigStdSignature = mcp_tools.release.zigStdSignature;
    pub const zigLangrefItem = mcp_tools.release.zigLangrefItem;
    pub const zigAutodocIngest = mcp_tools.release.zigAutodocIngest;
    pub const zigProjectDocsQuery = mcp_tools.release.zigProjectDocsQuery;
    pub const zigDocExampleCheck = mcp_tools.release.zigDocExampleCheck;
    pub const zigSnippetCheck = mcp_tools.release.zigSnippetCheck;
    pub const zigReadmeCommandCheck = mcp_tools.release.zigReadmeCommandCheck;
    pub const zigDependencyUpdatePlan = mcp_tools.dependencies.zigDependencyUpdatePlan;
    pub const zigDependencyFetchCheck = mcp_tools.dependencies.zigDependencyFetchCheck;
    pub const zigDependencyLockAudit = mcp_tools.dependencies.zigDependencyLockAudit;
    pub const zigDependencyImpact = mcp_tools.dependencies.zigDependencyImpact;
    pub const zigSbom = mcp_tools.dependencies.zigSbom;
    pub const zigZatScan = mcp_tools.dependencies.zigZatScan;
    pub const zigOsvScan = mcp_tools.dependencies.zigOsvScan;
    pub const zigDependencySecurityReport = mcp_tools.dependencies.zigDependencySecurityReport;
    pub const zigDependencyProvenance = mcp_tools.dependencies.zigDependencyProvenance;
    pub const zigDependencyLicenseSummary = mcp_tools.dependencies.zigDependencyLicenseSummary;
    pub const zigGithubDependencySubmitPlan = mcp_tools.dependencies.zigGithubDependencySubmitPlan;
};

const migrated_static_analysis = struct {
    pub const zigImportGraph = mcp_tools.static_analysis.zigImportGraph;
    pub const zigImportGraphJson = mcp_tools.static_analysis.zigImportGraphJson;
    pub const zigBuildGraph = mcp_tools.static_analysis.zigBuildGraph;
    pub const zigBuildTargets = mcp_tools.static_analysis.zigBuildTargets;
    pub const zigBuildOptions = mcp_tools.static_analysis.zigBuildOptions;
    pub const zigFileOwner = mcp_tools.static_analysis.zigFileOwner;
    pub const zigImportResolve = mcp_tools.static_analysis.zigImportResolve;
    pub const zigTestDiscover = mcp_tools.static_analysis.zigTestDiscover;
    pub const zigChangedFilesPlan = mcp_tools.static_analysis.zigChangedFilesPlan;
    pub const zigDependencyInspect = mcp_tools.static_analysis.zigDependencyInspect;
    pub const zigTargetMatrixPlan = mcp_tools.static_analysis.zigTargetMatrixPlan;
    pub const zigTestFailureTriage = mcp_tools.static_analysis.zigTestFailureTriage;
    pub const zigWorkspaceSymbolCache = mcp_tools.static_analysis.zigWorkspaceSymbolCache;
    pub const zigPackageCacheDoctor = mcp_tools.static_analysis.zigPackageCacheDoctor;
    pub const zigTestMap = mcp_tools.static_analysis.zigTestMap;
    pub const zigTestSelect = mcp_tools.static_analysis.zigTestSelect;
    pub const zigPublicApiDiff = mcp_tools.static_analysis.zigPublicApiDiff;
    pub const zigDeclSummary = mcp_tools.static_source_summary.zigDeclSummary;
    pub const zigDeclSummaryJson = mcp_tools.static_source_summary.zigDeclSummaryJson;
    pub const zigAstImports = mcp_tools.static_source_summary.zigAstImports;
    pub const zigAstDeclSummary = mcp_tools.static_source_summary.zigAstDeclSummary;
    pub const zigAllocations = mcp_tools.static_source_summary.zigAllocations;
    pub const zigErrorSets = mcp_tools.static_source_summary.zigErrorSets;
    pub const zigPublicApi = mcp_tools.static_source_summary.zigPublicApi;
    pub const zigDeadDeclCandidates = mcp_tools.static_source_summary.zigDeadDeclCandidates;
    pub const zigAstTests = mcp_tools.static_source_summary.zigAstTests;
    pub const zigSemanticIndexBuild = mcp_tools.static_analysis.zigSemanticIndexBuild;
    pub const zigSemanticIndexStatus = mcp_tools.static_analysis.zigSemanticIndexStatus;
    pub const zigSemanticIndexRefresh = mcp_tools.static_analysis.zigSemanticIndexRefresh;
    pub const zigSemanticQuery = mcp_tools.static_analysis.zigSemanticQuery;
    pub const zigSemanticRefs = mcp_tools.static_analysis.zigSemanticRefs;
    pub const zigSemanticDecl = mcp_tools.static_analysis.zigSemanticDecl;
    pub const zigSemanticCallers = mcp_tools.static_analysis.zigSemanticCallers;
    pub const zigStaticFusion = mcp_tools.static_analysis.zigStaticFusion;
    pub const zigCodeIndexExport = mcp_tools.static_analysis.zigCodeIndexExport;
    pub const zigScipExport = mcp_tools.static_analysis.zigScipExport;
    pub const zigZlint = mcp_tools.static_analysis.zigZlint;
    pub const zigZlintSarif = mcp_tools.static_analysis.zigZlintSarif;
    pub const zigZlintRules = mcp_tools.static_analysis.zigZlintRules;
    pub const zigZlintFix = mcp_tools.static_analysis.zigZlintFix;
    pub const zigLintCompare = mcp_tools.static_analysis.zigLintCompare;
    pub const zigLintProfile = mcp_tools.static_analysis.zigLintProfile;
    pub const zigLintGate = mcp_tools.static_analysis.zigLintGate;
    pub const zigLintFixPlan = mcp_tools.static_analysis.zigLintFixPlan;
    pub const zigLintBaseline = mcp_tools.static_analysis.zigLintBaseline;
    pub const zigLintSuppressions = mcp_tools.static_analysis.zigLintSuppressions;
    pub const zigLintTrend = mcp_tools.static_analysis.zigLintTrend;
};
