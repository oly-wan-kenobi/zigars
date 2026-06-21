//! Validation intelligence orchestration for next-step planning and patch safety checks.
const std = @import("std");

const app_context = @import("../../context.zig");
const ports = @import("../../ports.zig");
const zig_analysis = @import("../../../domain/zig/analysis.zig");
const project_values = @import("../static_analysis/project_values.zig");
const semantic_usecase = @import("../static_analysis/semantic_index.zig");
const workflows = @import("workflows.zig");
const support = @import("project_intelligence/support.zig");

// Shared leaf helpers extracted to project_intelligence/support.zig. Re-aliased
// here so every existing call site and white-box test in this file is unchanged.
const SafeText = support.SafeText;
const argvOwnedValue = support.argvOwnedValue;
const commandTermValue = support.commandTermValue;
const safeTextAlloc = support.safeTextAlloc;
const putStreamFields = support.putStreamFields;
const commandErrorKind = support.commandErrorKind;
const backendErrorValue = support.backendErrorValue;
const isOutputLimitError = support.isOutputLimitError;
const isTimeoutError = support.isTimeoutError;
const stringListContains = support.stringListContains;
const freeStringList = support.freeStringList;
const jsonArrayLen = support.jsonArrayLen;
const boolField = support.boolField;
const stringField = support.stringField;
const integerField = support.integerField;
const ownedString = support.ownedString;
const stringArrayValue = support.stringArrayValue;
const cloneValue = support.cloneValue;
const serializeValue = support.serializeValue;
const jsonLineForRecord = support.jsonLineForRecord;
const sha256Hex = support.sha256Hex;
pub const importsTarget = support.importsTarget;
pub const referencesFileStem = support.referencesFileStem;
pub const looksLikeTestFile = support.looksLikeTestFile;

// Shared request/value types and defaults extracted to project_intelligence/types.zig.
// Re-exported so the module's public surface and every in-file call site are unchanged.
const types = @import("project_intelligence/types.zig");
pub const schema_version = types.schema_version;
pub const semantic_limit_default = types.semantic_limit_default;
pub const memory_path_default = types.memory_path_default;
pub const profile_path_default = types.profile_path_default;
pub const PathList = types.PathList;
pub const ContextPackRequest = types.ContextPackRequest;
pub const ValidatePatchRequest = types.ValidatePatchRequest;
pub const FailureFusionRequest = types.FailureFusionRequest;
pub const ImpactRequest = types.ImpactRequest;
pub const ProjectProfileRequest = types.ProjectProfileRequest;
pub const PatchGuardRequest = types.PatchGuardRequest;
pub const SemanticImpactRequest = types.SemanticImpactRequest;
pub const EventCommandKind = types.EventCommandKind;
pub const CommandEventsRequest = types.CommandEventsRequest;
pub const SessionSnapshotRequest = types.SessionSnapshotRequest;
pub const DecisionRecordRequest = types.DecisionRecordRequest;
pub const ProjectMemoryRequest = types.ProjectMemoryRequest;
pub const ToolRisk = types.ToolRisk;
pub const CapabilityEntry = types.CapabilityEntry;
const ArgvList = types.ArgvList;

// Internal implementation helpers extracted to project_intelligence/internals.zig.
const internals = @import("project_intelligence/internals.zig");
const appendCapabilityMatch = internals.appendCapabilityMatch;
const appendCommandsForImpact = internals.appendCommandsForImpact;
const appendCommandsFromMatches = internals.appendCommandsFromMatches;
const appendExtraArgs = internals.appendExtraArgs;
const appendImpactMatch = internals.appendImpactMatch;
const appendOwnedArg = internals.appendOwnedArg;
const appendPatchPathToken = internals.appendPatchPathToken;
const appendPatchPaths = internals.appendPatchPaths;
const appendPathTokens = internals.appendPathTokens;
const appendUniqueCommand = internals.appendUniqueCommand;
const appendUniqueFileObject = internals.appendUniqueFileObject;
const appendUniqueString = internals.appendUniqueString;
const appendValidationPhase = internals.appendValidationPhase;
const appendWorkspaceFormatCheckCommand = internals.appendWorkspaceFormatCheckCommand;
const appendWorkspaceFormatCheckPhase = internals.appendWorkspaceFormatCheckPhase;
const buildEventArgv = internals.buildEventArgv;
const buildEventsValue = internals.buildEventsValue;
const buildExplainArgv = internals.buildExplainArgv;
const buildZigArgv = internals.buildZigArgv;
const builtInProjectPoliciesValue = internals.builtInProjectPoliciesValue;
const changedPathList = internals.changedPathList;
const classifyEventLine = internals.classifyEventLine;
const collectDeclarationsForSymbol = internals.collectDeclarationsForSymbol;
const collectImportersForFile = internals.collectImportersForFile;
const collectLineEvents = internals.collectLineEvents;
const collectPublicApiForFile = internals.collectPublicApiForFile;
const collectTestsForFile = internals.collectTestsForFile;
const collectTestsForSymbol = internals.collectTestsForSymbol;
const commandErrorEventsValue = internals.commandErrorEventsValue;
const commandErrorSummaryValue = internals.commandErrorSummaryValue;
const commandErrorValue = internals.commandErrorValue;
const commandResultValue = internals.commandResultValue;
const decisionRecordDataValue = internals.decisionRecordDataValue;
const failureGroupsValueFromUsecase = internals.failureGroupsValueFromUsecase;
const failureSummaryValue = internals.failureSummaryValue;
const filterRecords = internals.filterRecords;
const historyRecordValueFromUsecase = internals.historyRecordValueFromUsecase;
const historyRunJsonValue = internals.historyRunJsonValue;
const historyRunsArrayValue = internals.historyRunsArrayValue;
const importMatchesTarget = internals.importMatchesTarget;
const isDeniedBuildFlag = internals.isDeniedBuildFlag;
const likelyFailureScopeValue = internals.likelyFailureScopeValue;
const loadJsonLines = internals.loadJsonLines;
const matchScore = internals.matchScore;
const parseDurationMs = internals.parseDurationMs;
const parseJsonLinesOrArray = internals.parseJsonLinesOrArray;
const parseJsonValueOrString = internals.parseJsonValueOrString;
pub const pathListFromTextAndPatch = internals.pathListFromTextAndPatch;
const phaseByName = internals.phaseByName;
const phaseCommandValue = internals.phaseCommandValue;
const phaseEventsValue = internals.phaseEventsValue;
const policyValue = internals.policyValue;
const preimageIdentityForPath = internals.preimageIdentityForPath;
const preimageValue = internals.preimageValue;
const preimageValueFromUsecase = internals.preimageValueFromUsecase;
const profileStateValue = internals.profileStateValue;
const putSemanticMetadata = internals.putSemanticMetadata;
const riskValue = internals.riskValue;
const searchableRecordText = internals.searchableRecordText;
const semanticCrossCheckValue = internals.semanticCrossCheckValue;
const semanticEvidenceBasisValue = internals.semanticEvidenceBasisValue;
const sequenceStepValue = internals.sequenceStepValue;
const skippedPhaseValue = internals.skippedPhaseValue;
const skippedPhasesValue = internals.skippedPhasesValue;
const skippedStepValue = internals.skippedStepValue;
const sortMatches = internals.sortMatches;
const statusLinePath = internals.statusLinePath;
const timingValue = internals.timingValue;
const validationPhaseRunValue = internals.validationPhaseRunValue;
const validationPhaseValue = internals.validationPhaseValue;
const validationPhasesValue = internals.validationPhasesValue;
const validationRiskValue = internals.validationRiskValue;
const workspacePathExists = internals.workspacePathExists;

/// Serializes context pack fields into an allocator-owned JSON value; allocation failures propagate.
pub fn contextPackValue(
    allocator: std.mem.Allocator,
    context: app_context.ProjectIntelligenceContext,
    request: ContextPackRequest,
) !std.json.Value {
    const mode = request.mode;
    const token_budget = @max(500, @min(request.token_budget, 50_000));
    const limit: usize = if (std.mem.eql(u8, mode, "tiny")) 40 else if (std.mem.eql(u8, mode, "deep")) 500 else 150;
    const tiny = std.mem.eql(u8, mode, "tiny");
    // The included/omitted lists mirror the payload shape so callers can tell
    // which sections were intentionally excluded by the selected mode.
    var included = std.json.Array.init(allocator);
    var omitted = std.json.Array.init(allocator);
    try included.append(try ownedString(allocator, "workspace"));
    try included.append(try ownedString(allocator, "project_type"));
    try included.append(try ownedString(allocator, "build"));
    try included.append(try ownedString(allocator, "source_map"));
    try included.append(try ownedString(allocator, "quality"));
    if (tiny) {
        try omitted.append(try ownedString(allocator, "tests: omitted in tiny mode"));
        try omitted.append(try ownedString(allocator, "deps: omitted in tiny mode"));
    } else {
        try included.append(try ownedString(allocator, "tests"));
        try included.append(try ownedString(allocator, "deps"));
    }

    const static_context = context.staticAnalysis();
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zigars_context_pack" });
    try obj.put(allocator, "mode", .{ .string = mode });
    try obj.put(allocator, "token_budget", .{ .integer = token_budget });
    try obj.put(allocator, "workspace", try contextWorkspaceValue(allocator, context));
    try obj.put(allocator, "project_type", try projectTypeValue(allocator, context));
    try obj.put(allocator, "build", project_values.buildWorkspaceValue(allocator, static_context) catch .null);
    if (!tiny) {
        try obj.put(allocator, "tests", project_values.testMapValue(allocator, static_context, @min(limit, 200)) catch .null);
        try obj.put(allocator, "deps", dependencyContextValue(allocator, context) catch .null);
    }
    try obj.put(allocator, "source_map", sourceMapValue(allocator, context, limit) catch .null);
    try obj.put(allocator, "quality", try qualityCommandsValue(allocator, context));
    try obj.put(allocator, "agent_rules", try agentRulesValue(allocator, "generic", "any"));
    try obj.put(allocator, "recommended_start", try nextActionPlanValue(allocator, "orient", null, null));
    try obj.put(allocator, "included_sections", .{ .array = included });
    try obj.put(allocator, "omitted_sections", .{ .array = omitted });
    try obj.put(allocator, "workflow_contract", try workflowContractValue(allocator, "workspace files, build metadata, optional dependency/test summaries, and ZLS status", "orientation pack for routing; not a semantic project proof", if (tiny) "low" else "medium", "mode and token_budget intentionally omit sections; inspect omitted_sections before assuming absence", "zigars_validate_patch", "stop after the selected low-level tool or final validation gate passes", &.{ "zigars_next_action", "zigars_validate_patch" }));
    try obj.put(allocator, "limits", try contextLimitsValue(allocator));
    return .{ .object = obj };
}

/// Serializes agent guide fields into an allocator-owned JSON value; allocation failures propagate.
pub fn agentGuideValue(allocator: std.mem.Allocator, client: []const u8, task: []const u8) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zigars_agent_guide" });
    try obj.put(allocator, "client", .{ .string = client });
    try obj.put(allocator, "task", .{ .string = task });
    try obj.put(allocator, "rules", try agentRulesValue(allocator, client, task));
    try obj.put(allocator, "workflows", try agentWorkflowHintsValue(allocator, task));
    try obj.put(allocator, "tool_aliases", try agentToolAliasesValue(allocator));
    return .{ .object = obj };
}

/// Runs the patch-readiness validation phases (fmt --check, ast-check per
/// changed Zig file, then a build test gate per mode), short-circuiting on
/// failure when stop_on_failure is set and recording skipped phases. Returns an
/// allocator-owned JSON result the caller must deinit.
pub fn validatePatchValue(
    allocator: std.mem.Allocator,
    context: app_context.ProjectIntelligenceContext,
    request: ValidatePatchRequest,
) !std.json.Value {
    // Reject incompatible inputs early so callers get a precise failure reason.
    var paths = try changedPathList(allocator, context, request.changed_files, request.timeout_ms);
    defer paths.deinit(allocator);

    var phases = std.json.Array.init(allocator);
    var skipped_phases = std.json.Array.init(allocator);
    var files = std.json.Array.init(allocator);
    var ok = true;
    var ran_full_build = false;
    var saw_build_file = false;

    for (paths.items) |path| {
        try files.append(try ownedString(allocator, path));
        if (std.mem.eql(u8, path, "build.zig") or std.mem.eql(u8, path, "build.zig.zon")) saw_build_file = true;
        if (!workspacePathExists(allocator, context, path)) continue;
        if (std.mem.endsWith(u8, path, ".zig") or std.mem.endsWith(u8, path, ".zig.zon")) {
            const fmt_ok = try appendValidationPhase(allocator, context, &phases, "format_check", &.{ context.tool_paths.zig, "fmt", "--check", path }, request.timeout_ms);
            if (!fmt_ok) {
                ok = false;
                if (request.stop_on_failure) break;
            }
        }
        if (std.mem.endsWith(u8, path, ".zig")) {
            const check_ok = try appendValidationPhase(allocator, context, &phases, "ast_check", &.{ context.tool_paths.zig, "ast-check", path }, request.timeout_ms);
            if (!check_ok) {
                ok = false;
                if (request.stop_on_failure) break;
            }
        }
    }

    if ((ok or !request.stop_on_failure) and paths.items.len == 0) {
        try appendWorkspaceFormatCheckPhase(allocator, context, &phases, request.timeout_ms, &ok, request.stop_on_failure);
    }
    if ((ok or !request.stop_on_failure) and !std.mem.eql(u8, request.mode, "quick")) {
        if (std.mem.eql(u8, request.mode, "full") or std.mem.eql(u8, request.mode, "standard") or saw_build_file or paths.items.len == 0) {
            ran_full_build = true;
            const build_ok = try appendValidationPhase(allocator, context, &phases, "build_test", &.{ context.tool_paths.zig, "build", "test" }, request.timeout_ms);
            if (!build_ok) ok = false;
        }
    }
    if (!ran_full_build) try skipped_phases.append(try skippedPhaseValue(allocator, "build_test", "mode/path selection or stop_on_failure skipped full build test"));

    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zigars_validate_patch" });
    try obj.put(allocator, "ok", .{ .bool = ok });
    try obj.put(allocator, "mode", .{ .string = request.mode });
    try obj.put(allocator, "changed_files", .{ .array = files });
    try obj.put(allocator, "phases", .{ .array = phases });
    try obj.put(allocator, "skipped_phases", .{ .array = skipped_phases });
    try obj.put(allocator, "ran_full_build_test", .{ .bool = ran_full_build });
    try obj.put(allocator, "workflow_contract", try workflowContractValue(allocator, "git/status changed files or user-supplied changed_files plus command exit status", "patch readiness from selected validation phases", if (ran_full_build) "high" else "medium", "quick mode and stop_on_failure can skip later phases; inspect skipped_phases", "rerun failed phase or run zigars_validate_patch mode=full", "stop when all selected phases pass", &.{ "zigars_failure_fusion", "zigars_validate_patch" }));
    try obj.put(allocator, "next_action", try validationNextActionValue(allocator, ok, phases));
    return .{ .object = obj };
}

/// Serializes failure fusion from command fields into an allocator-owned JSON value; allocation failures propagate.
pub fn failureFusionFromCommandValue(
    allocator: std.mem.Allocator,
    context: app_context.ProjectIntelligenceContext,
    request: FailureFusionRequest,
) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
    if (request.text) |raw_text| return failureFusionValue(allocator, raw_text, "", &.{ "zig", "build", "test" }, false);
    var argv = try buildExplainArgv(allocator, context, request);
    defer argv.deinit(allocator);
    var result = context.command_runner.run(allocator, .{
        .argv = argv.items,
        .cwd = context.workspace.root,
        .timeout_ms = @intCast(@max(1, request.timeout_ms)),
        .max_stdout_bytes = workflows.command_output_limit,
        .max_stderr_bytes = workflows.command_output_limit,
        .provenance = "zigars_failure_fusion",
    }) catch |err| return backendErrorValue(allocator, "zig", "failure_fusion", err, "pass captured output as text or confirm --zig-path is executable");
    defer result.deinit(allocator);
    const term = result.effectiveTerm();
    return failureFusionValue(allocator, result.stderr, result.stdout, argv.items, !term.failed() and !result.timed_out);
}

/// Serializes impact fields into an allocator-owned JSON value; allocation failures propagate.
pub fn impactValue(
    allocator: std.mem.Allocator,
    context: app_context.ProjectIntelligenceContext,
    request: ImpactRequest,
) !std.json.Value {
    // Treat paths and symbols as independent impact seeds; both can add
    // commands, likely tests, and public API hints to the response.
    var files = std.ArrayList([]const u8).empty;
    defer files.deinit(allocator);
    defer freeStringList(allocator, files.items);
    try appendPathTokens(allocator, &files, request.files);
    var symbols = std.ArrayList([]const u8).empty;
    defer symbols.deinit(allocator);
    defer freeStringList(allocator, symbols.items);
    try appendPathTokens(allocator, &symbols, request.symbols);

    var importers = std.json.Array.init(allocator);
    var symbol_hits = std.json.Array.init(allocator);
    var public_api = std.json.Array.init(allocator);
    var commands = std.json.Array.init(allocator);
    var likely_tests = std.json.Array.init(allocator);

    var scan = try context.workspace_scanner.scanZigFiles(allocator, .{
        .path_prefix = "",
        .max_files = request.limit,
        .provenance = "project_intelligence.impact",
    });
    defer scan.deinit(allocator);

    for (scan.files) |file| {
        const contents_result = context.workspace_store.read(allocator, .{
            .path = file.path,
            .max_bytes = 512 * 1024,
            .provenance = "project_intelligence.impact",
        }) catch continue;
        defer contents_result.deinit(allocator);
        const contents = contents_result.bytes;
        for (files.items) |target| {
            if (importsTarget(contents, target)) {
                try importers.append(try impactHitValue(allocator, file.path, target, "imports_target"));
            }
            if (std.mem.eql(u8, file.path, target)) {
                try appendUniqueCommand(allocator, &commands, try std.fmt.allocPrint(allocator, "zig ast-check {s}", .{target}));
                try appendUniqueCommand(allocator, &commands, try std.fmt.allocPrint(allocator, "zig test {s}", .{target}));
                try appendPublicDeclsForFile(allocator, &public_api, target, contents);
            }
            if (looksLikeTestFile(file.path) and referencesFileStem(contents, target)) {
                try likely_tests.append(try impactHitValue(allocator, file.path, target, "test_references_file"));
            }
        }
        for (symbols.items) |symbol| {
            if (std.mem.indexOf(u8, contents, symbol) != null) {
                try symbol_hits.append(try impactHitValue(allocator, file.path, symbol, "symbol_reference"));
                if (looksLikeTestFile(file.path)) try likely_tests.append(try impactHitValue(allocator, file.path, symbol, "test_references_symbol"));
            }
        }
    }
    try appendUniqueCommand(allocator, &commands, "zig build test");

    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zigars_impact" });
    try obj.put(allocator, "analysis_kind", .{ .string = "heuristic_import_symbol_test_scan" });
    try obj.put(allocator, "confidence", .{ .string = "medium" });
    try obj.put(allocator, "direct_importers", .{ .array = importers });
    try obj.put(allocator, "symbol_hits", .{ .array = symbol_hits });
    try obj.put(allocator, "likely_tests", .{ .array = likely_tests });
    try obj.put(allocator, "public_api", .{ .array = public_api });
    try obj.put(allocator, "recommended_commands", .{ .array = commands });
    try obj.put(allocator, "limitations", .{ .string = "heuristic text/import scan; not semantic dependency proof" });
    try obj.put(allocator, "workflow_contract", try workflowContractValue(allocator, "workspace Zig file scan, import text, symbol text, and public declaration lines", "likely affected files/tests and commands", "medium", "heuristic text matches can over- or under-select; verify with compiler-backed commands", "zigars_validate_patch", "stop after focused commands or zigars_validate_patch pass", &.{ "zig_test_select", "zigars_validate_patch" }));
    return .{ .object = obj };
}

/// Generates (or accepts supplied) a project profile and, only when
/// request.apply is true, writes it to the default profile path through the
/// sandboxed workspace. Without apply it previews and reports requires_apply.
/// Returns an allocator-owned JSON result the caller must deinit.
pub fn projectProfileValue(
    allocator: std.mem.Allocator,
    context: app_context.ProjectIntelligenceContext,
    request: ProjectProfileRequest,
) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
    const generated = if (request.content) |content| blk: {
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, content, .{});
        defer parsed.deinit();
        break :blk try cloneValue(allocator, parsed.value);
    } else try generatedProjectProfileValue(allocator, context);

    if (request.apply) {
        const bytes = try serializeValue(allocator, generated);
        defer allocator.free(bytes);
        _ = try context.workspace_store.write(.{
            .path = profile_path_default,
            .bytes = bytes,
            .provenance = "project_intelligence.project_profile",
        });
    }

    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zigars_project_profile" });
    try obj.put(allocator, "path", .{ .string = profile_path_default });
    try obj.put(allocator, "applied", .{ .bool = request.apply });
    try obj.put(allocator, "requires_apply", .{ .bool = !request.apply });
    if (context.workspace_store.read(allocator, .{ .path = profile_path_default, .max_bytes = 1024 * 1024, .provenance = "project_intelligence.project_profile.existing" }) catch null) |existing| {
        defer existing.deinit(allocator);
        try obj.put(allocator, "existing", try ownedString(allocator, existing.bytes));
    } else {
        try obj.put(allocator, "existing", .null);
    }
    try obj.put(allocator, "profile", generated);
    return .{ .object = obj };
}

/// Checks each candidate path (from files and/or a patch) against the workspace
/// sandbox and the generated/vendored-path policy, marking it safe or a
/// violation. safe=false if any path escapes the workspace or targets a
/// generated path. Read-only: it never writes. Returns an allocator-owned JSON
/// result the caller must deinit.
pub fn patchGuardValue(
    allocator: std.mem.Allocator,
    context: app_context.ProjectIntelligenceContext,
    request: PatchGuardRequest,
) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
    var paths = std.ArrayList([]const u8).empty;
    defer paths.deinit(allocator);
    defer freeStringList(allocator, paths.items);
    try appendPathTokens(allocator, &paths, request.files);
    try appendPatchPaths(allocator, &paths, request.patch);

    var checked = std.json.Array.init(allocator);
    var violations = std.json.Array.init(allocator);
    var safe = true;
    for (paths.items) |path| {
        if (path.len == 0 or std.mem.eql(u8, path, "/dev/null")) continue;
        var item = std.json.ObjectMap.empty;
        try item.put(allocator, "path", try ownedString(allocator, path));
        const resolved = context.workspace_store.resolve(allocator, .{
            .path = path,
            .for_output = true,
            .provenance = "project_intelligence.patch_guard",
        }) catch |err| {
            safe = false;
            try item.put(allocator, "ok", .{ .bool = false });
            try item.put(allocator, "reason", .{ .string = @errorName(err) });
            try violations.append(try ownedString(allocator, path));
            try checked.append(.{ .object = item });
            continue;
        };
        resolved.deinit(allocator);
        const generated = zig_analysis.skipWorkspacePath(path);
        if (generated) safe = false;
        try item.put(allocator, "ok", .{ .bool = !generated });
        try item.put(allocator, "generated_or_vendored", .{ .bool = generated });
        try item.put(allocator, "reason", .{ .string = if (generated) "generated_or_vendored_path" else "workspace_local_path" });
        if (generated) try violations.append(try ownedString(allocator, path));
        try checked.append(.{ .object = item });
    }

    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zigars_patch_guard" });
    try obj.put(allocator, "safe", .{ .bool = safe });
    try obj.put(allocator, "checked", .{ .array = checked });
    try obj.put(allocator, "violations", .{ .array = violations });
    try obj.put(allocator, "write_policy", .{ .string = "zigars source writes require the specific mutating tool to receive apply=true" });
    return .{ .object = obj };
}

/// Serializes semantic impact fields into an allocator-owned JSON value; allocation failures propagate.
pub fn semanticImpactValue(
    allocator: std.mem.Allocator,
    context: app_context.ProjectIntelligenceContext,
    request: SemanticImpactRequest,
    tool_name: []const u8,
) !std.json.Value {
    const index = try semantic_usecase.semanticIndexValue(allocator, context.staticAnalysis(), request.limit, "zig_semantic_index_build");
    const root = switch (index) {
        .object => |o| o,
        else => std.json.ObjectMap.empty,
    };

    // Normalize explicit files, diff paths, and symbols into owned token lists
    // before projecting them through the semantic index.
    var files = std.ArrayList([]const u8).empty;
    defer files.deinit(allocator);
    defer freeStringList(allocator, files.items);
    try appendPathTokens(allocator, &files, request.files);
    try appendPatchPaths(allocator, &files, request.diff);

    var symbols = std.ArrayList([]const u8).empty;
    defer symbols.deinit(allocator);
    defer freeStringList(allocator, symbols.items);
    try appendPathTokens(allocator, &symbols, request.symbols);

    var touched = std.json.Array.init(allocator);
    var importers = std.json.Array.init(allocator);
    var declarations = std.json.Array.init(allocator);
    var tests = std.json.Array.init(allocator);
    var public_api = std.json.Array.init(allocator);
    var commands = std.json.Array.init(allocator);
    var inferred = std.json.Array.init(allocator);
    var unknowns = std.json.Array.init(allocator);

    for (files.items) |file| {
        if (file.len == 0 or std.mem.eql(u8, file, "/dev/null")) continue;
        try appendUniqueFileObject(allocator, &touched, file, "input_changed_file", "high");
        if (std.mem.endsWith(u8, file, ".zig")) {
            try appendUniqueCommand(allocator, &commands, try std.fmt.allocPrint(allocator, "zig ast-check {s}", .{file}));
            try appendUniqueCommand(allocator, &commands, try std.fmt.allocPrint(allocator, "zig test {s}", .{file}));
        }
        try collectImportersForFile(allocator, root.get("imports") orelse .null, &importers, file);
        try collectTestsForFile(allocator, root.get("tests") orelse .null, &tests, file);
        try collectPublicApiForFile(allocator, root.get("declarations") orelse .null, &public_api, file);
    }

    for (symbols.items) |symbol| {
        if (symbol.len == 0) continue;
        try collectDeclarationsForSymbol(allocator, root.get("declarations") orelse .null, &declarations, symbol);
        try collectTestsForSymbol(allocator, root.get("tests") orelse .null, &tests, symbol);
    }

    try appendCommandsFromMatches(allocator, &commands, tests);
    try appendUniqueCommand(allocator, &commands, "zig build test");
    if (files.items.len == 0 and symbols.items.len == 0) {
        try unknowns.append(try ownedString(allocator, "No files, symbols, or diff paths were supplied; result falls back to workspace-level validation."));
    }
    try inferred.append(try ownedString(allocator, "Importers are inferred from parser-backed @import declarations when available and basename matching otherwise."));
    try inferred.append(try ownedString(allocator, "Affected tests are selected from parser-backed test declarations and file/symbol name matches."));

    var inspected = std.json.ObjectMap.empty;
    try inspected.put(allocator, "semantic_index_format", root.get("format") orelse .{ .string = "zigars.semantic_index" });
    try inspected.put(allocator, "file_count", root.get("file_count") orelse .{ .integer = 0 });
    try inspected.put(allocator, "declaration_count", root.get("declaration_count") orelse .{ .integer = 0 });
    try inspected.put(allocator, "import_count", root.get("import_count") orelse .{ .integer = 0 });
    try inspected.put(allocator, "test_count", root.get("test_count") orelse .{ .integer = 0 });
    try inspected.put(allocator, "partial_result", root.get("partial_result") orelse .{ .bool = true });
    try inspected.put(allocator, "parse_status", root.get("parse_status") orelse .{ .string = "unknown" });

    var skipped = std.json.Array.init(allocator);
    try skipped.append(try skippedStepValue(allocator, "runtime_execution", "Semantic impact reads source evidence only; it does not run tests or builds."));
    try skipped.append(try skippedStepValue(allocator, "coverage", "No coverage data is inspected, so unselected tests are not proven safe to skip."));

    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", try ownedString(allocator, tool_name));
    try putSemanticMetadata(allocator, &obj, tool_name);
    try obj.put(allocator, "schema_version", .{ .integer = schema_version });
    try obj.put(allocator, "evidence_sources", try stringArrayValue(allocator, &.{ "parser", "heuristic" }));
    try obj.put(allocator, "inspected", .{ .object = inspected });
    try obj.put(allocator, "directly_touched_files", .{ .array = touched });
    try obj.put(allocator, "affected_importers", .{ .array = importers });
    try obj.put(allocator, "affected_declarations", .{ .array = declarations });
    try obj.put(allocator, "affected_tests", .{ .array = tests });
    try obj.put(allocator, "public_api", .{ .array = public_api });
    try obj.put(allocator, "recommended_checks", .{ .array = commands });
    try obj.put(allocator, "inferences", .{ .array = inferred });
    try obj.put(allocator, "unknowns", .{ .array = unknowns });
    try obj.put(allocator, "skipped_validation", .{ .array = skipped });
    try obj.put(allocator, "result_complete", .{ .bool = false });
    try obj.put(allocator, "stop_condition", .{ .string = "Stop only after recommended checks and any project release gate pass; impact analysis alone is advisory." });
    return .{ .object = obj };
}

/// Serializes test select semantic fields into an allocator-owned JSON value; allocation failures propagate.
pub fn testSelectSemanticValue(
    allocator: std.mem.Allocator,
    context: app_context.ProjectIntelligenceContext,
    request: SemanticImpactRequest,
) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
    const impact = try semanticImpactValue(allocator, context, request, "zig_test_select_semantic");
    const impact_obj = switch (impact) {
        .object => |o| o,
        else => std.json.ObjectMap.empty,
    };

    var commands = std.json.Array.init(allocator);
    var reasons = std.json.Array.init(allocator);
    try appendCommandsForImpact(allocator, &commands, &reasons, impact_obj.get("directly_touched_files") orelse .null, "changed Zig file");
    try appendCommandsForImpact(allocator, &commands, &reasons, impact_obj.get("affected_tests") orelse .null, "semantic test match");
    try appendUniqueCommand(allocator, &commands, "zig build test");

    var skipped = std.json.Array.init(allocator);
    try skipped.append(try skippedStepValue(allocator, "coverage", "No coverage backend is run by this selector; use project CI or coverage tooling for release proof."));
    try skipped.append(try skippedStepValue(allocator, "performance", "No benchmark/profile evidence is collected by this selector."));

    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "kind", .{ .string = "zig_test_select_semantic" });
    try putSemanticMetadata(allocator, &obj, "zig_test_select_semantic");
    try obj.put(allocator, "schema_version", .{ .integer = schema_version });
    try obj.put(allocator, "impact", impact);
    try obj.put(allocator, "commands", .{ .array = commands });
    try obj.put(allocator, "reasons", .{ .array = reasons });
    try obj.put(allocator, "selection_basis", .{ .string = "parser-backed semantic impact plus conservative fallback" });
    try obj.put(allocator, "fallback", .{ .string = "zig build test" });
    try obj.put(allocator, "selection_complete", .{ .bool = false });
    try obj.put(allocator, "skipped_validation", .{ .array = skipped });
    try obj.put(allocator, "stop_condition", .{ .string = "Stop only after the focused commands pass and a release-appropriate full gate such as zig build test or project CI passes." });
    return .{ .object = obj };
}

/// Serializes validation plan fields into an allocator-owned JSON value; allocation failures propagate.
pub fn validationPlanValueFromUsecase(allocator: std.mem.Allocator, result: workflows.PlanResult) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zigars_validation_plan" });
    try obj.put(allocator, "schema_version", .{ .integer = result.schema_version });
    try obj.put(allocator, "plan_id", try ownedString(allocator, result.plan_id));
    try obj.put(allocator, "mode", try ownedString(allocator, result.mode));
    try obj.put(allocator, "goal", if (result.goal) |goal| try ownedString(allocator, goal) else .null);
    try obj.put(allocator, "facts", try stringArrayValue(allocator, result.facts.items));
    try obj.put(allocator, "risk", try validationRiskValue(allocator, result.risk));
    try obj.put(allocator, "phases", try validationPhasesValue(allocator, result.phases));
    try obj.put(allocator, "skipped_phases", try skippedPhasesValue(allocator, result.skipped_phases));
    try obj.put(allocator, "unknowns", try stringArrayValue(allocator, result.unknowns.items));
    try obj.put(allocator, "execution_policy", .{ .string = "plan-first; no environment installs or source writes are performed by this planner" });
    try obj.put(allocator, "stop_condition", .{ .string = "Run required phases until they pass or the first blocking failure is understood." });
    try obj.put(allocator, "next_action", try toolStepValue(allocator, "zigars_validation_run", "execute command phases and retain structured events/history"));
    return .{ .object = obj };
}

/// Serializes validation run fields into an allocator-owned JSON value; allocation failures propagate.
pub fn validationRunValue(allocator: std.mem.Allocator, report: workflows.RunReport) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
    var phases = std.json.Array.init(allocator);
    for (report.phases) |phase_run| try phases.append(try validationPhaseRunValue(allocator, phase_run));
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zigars_validation_run" });
    try obj.put(allocator, "schema_version", .{ .integer = report.schema_version });
    try obj.put(allocator, "ok", .{ .bool = report.ok });
    try obj.put(allocator, "plan", try validationPlanValueFromUsecase(allocator, report.plan));
    try obj.put(allocator, "phases", .{ .array = phases });
    try obj.put(allocator, "skipped_phases", try skippedPhasesValue(allocator, report.skipped_phases));
    try obj.put(allocator, "history_record", try historyRecordValueFromUsecase(allocator, report.history_record, report.phases, report.skipped_phases));
    try obj.put(allocator, "history_path", try ownedString(allocator, report.history_path));
    try obj.put(allocator, "history_applied", .{ .bool = report.history_applied });
    try obj.put(allocator, "requires_apply_for_history", .{ .bool = report.requires_apply_for_history });
    try obj.put(allocator, "preimage_identity", try preimageValueFromUsecase(allocator, report.preimage_identity));
    try obj.put(allocator, "next_action", try validationNextActionValue(allocator, report.ok, phases));
    try obj.put(allocator, "stop_condition", .{ .string = "Stop when all selected phases pass and skipped_phases are acceptable for the change risk." });
    return .{ .object = obj };
}

/// Serializes validation history tool fields into an allocator-owned JSON value; allocation failures propagate.
pub fn validationHistoryToolValue(
    allocator: std.mem.Allocator,
    tool_name: []const u8,
    result: workflows.HistoryResult,
) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
    return switch (result.view) {
        .runs => validationRunsHistoryValue(allocator, tool_name, result),
        .flakes => validationFlakeHistoryValue(allocator, tool_name, result),
        .failures => validationFailureHistoryValue(allocator, tool_name, result),
    };
}

/// Serializes validation runs history fields into an allocator-owned JSON value; allocation failures propagate.
fn validationRunsHistoryValue(allocator: std.mem.Allocator, tool_name: []const u8, result: workflows.HistoryResult) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = tool_name });
    try obj.put(allocator, "schema_version", .{ .integer = result.schema_version });
    try obj.put(allocator, "history_available", .{ .bool = result.history_available });
    try obj.put(allocator, "run_count", .{ .integer = @intCast(result.runs.len) });
    try obj.put(allocator, "last_run", if (result.last_run_index) |index| try historyRunJsonValue(allocator, result.runs[index]) else .null);
    try obj.put(allocator, "last_good", if (result.last_good_index) |index| try historyRunJsonValue(allocator, result.runs[index]) else .null);
    try obj.put(allocator, "runs", try historyRunsArrayValue(allocator, result.runs));
    try obj.put(allocator, "failure_summary", try failureGroupsValueFromUsecase(allocator, result.failure_groups));
    try obj.put(allocator, "limitations", .{ .string = "History reflects records supplied to or written by zigars validation tools; it is not a complete CI database." });
    return .{ .object = obj };
}

/// Serializes validation flake history fields into an allocator-owned JSON value; allocation failures propagate.
fn validationFlakeHistoryValue(allocator: std.mem.Allocator, tool_name: []const u8, result: workflows.HistoryResult) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = tool_name });
    try obj.put(allocator, "schema_version", .{ .integer = result.schema_version });
    try obj.put(allocator, "history_available", .{ .bool = result.history_available });
    try obj.put(allocator, "flakes", try failureGroupsValueFromUsecase(allocator, result.failure_groups));
    try obj.put(allocator, "confidence", .{ .string = if (result.runs.len >= 3) "medium" else "low" });
    try obj.put(allocator, "limitations", .{ .string = "Flake detection is recurrence over retained validation records; confirm with repeated test runs before suppressing failures." });
    return .{ .object = obj };
}

/// Serializes validation failure history fields into an allocator-owned JSON value; allocation failures propagate.
fn validationFailureHistoryValue(allocator: std.mem.Allocator, tool_name: []const u8, result: workflows.HistoryResult) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = tool_name });
    try obj.put(allocator, "schema_version", .{ .integer = result.schema_version });
    try obj.put(allocator, "history_available", .{ .bool = result.history_available });
    try obj.put(allocator, "recurring_failures", try failureGroupsValueFromUsecase(allocator, result.failure_groups));
    try obj.put(allocator, "run_count", .{ .integer = @intCast(result.runs.len) });
    return .{ .object = obj };
}

/// Serializes command events fields into an allocator-owned JSON value; allocation failures propagate.
pub fn commandEventsValue(
    allocator: std.mem.Allocator,
    context: app_context.ProjectIntelligenceContext,
    tool_name: []const u8,
    request: CommandEventsRequest,
) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
    if (request.text) |text| return buildEventsValue(allocator, tool_name, text, "", &.{}, false, "captured_text");
    var argv = try buildEventArgv(allocator, context, request);
    defer argv.deinit(allocator);
    var result = context.command_runner.run(allocator, .{
        .argv = argv.items,
        .cwd = context.workspace.root,
        .timeout_ms = @intCast(@max(1, request.timeout_ms)),
        .max_stdout_bytes = workflows.command_output_limit,
        .max_stderr_bytes = workflows.command_output_limit,
        .provenance = tool_name,
    }) catch |err| return commandErrorEventsValue(allocator, tool_name, argv.items, context.workspace.root, request.timeout_ms, err);
    defer result.deinit(allocator);
    const term = result.effectiveTerm();
    return buildEventsValue(allocator, tool_name, result.stderr, result.stdout, argv.items, !term.failed() and !result.timed_out, "executed_command");
}

/// Serializes test timing fields into an allocator-owned JSON value; allocation failures propagate.
pub fn testTimingValue(allocator: std.mem.Allocator, text: []const u8) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zig_test_timing" });
    try obj.put(allocator, "schema_version", .{ .integer = schema_version });
    try obj.put(allocator, "timings", try timingValue(allocator, text));
    try obj.put(allocator, "parsing_basis", .{ .string = "captured text timing markers" });
    try obj.put(allocator, "confidence", .{ .string = "medium" });
    return .{ .object = obj };
}

/// Serializes session snapshot fields into an allocator-owned JSON value; allocation failures propagate.
pub fn sessionSnapshotValue(
    allocator: std.mem.Allocator,
    context: app_context.ProjectIntelligenceContext,
    request: SessionSnapshotRequest,
) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
    var paths = std.ArrayList([]const u8).empty;
    defer paths.deinit(allocator);
    defer freeStringList(allocator, paths.items);
    try appendPathTokens(allocator, &paths, request.changed_files);
    try appendPatchPaths(allocator, &paths, request.diff);
    var files = std.json.Array.init(allocator);
    for (paths.items) |path| try files.append(try ownedString(allocator, path));
    const validation = if (request.validation) |text| parseJsonValueOrString(allocator, text) catch try ownedString(allocator, text) else .null;
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", try ownedString(allocator, request.kind));
    try obj.put(allocator, "schema_version", .{ .integer = schema_version });
    try obj.put(allocator, "goal", if (request.goal) |goal| try ownedString(allocator, goal) else .null);
    try obj.put(allocator, "changed_files", .{ .array = files });
    try obj.put(allocator, "validation", validation);
    try obj.put(allocator, "last_error", if (request.last_error) |err| try ownedString(allocator, err) else .null);
    try obj.put(allocator, "workspace", try contextWorkspaceValue(allocator, context));
    try obj.put(allocator, "profile_state", try profileStateValue(allocator, context));
    try obj.put(allocator, "recommended_next_action", try nextActionPlanValue(allocator, request.goal orelse "continue validation", request.changed_files, request.last_error));
    try obj.put(allocator, "limitations", .{ .string = "Snapshot is a point-in-time summary over caller-supplied state and current workspace metadata." });
    return .{ .object = obj };
}

/// Serializes handoff pack fields into an allocator-owned JSON value; allocation failures propagate.
pub fn handoffPackValue(
    allocator: std.mem.Allocator,
    context: app_context.ProjectIntelligenceContext,
    request: SessionSnapshotRequest,
) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
    const snapshot = try sessionSnapshotValue(allocator, context, .{
        .kind = "zigars_handoff_pack",
        .goal = request.goal,
        .changed_files = request.changed_files,
        .diff = request.diff,
        .validation = request.validation,
        .last_error = request.last_error,
    });
    var steps = std.json.Array.init(allocator);
    try steps.append(try toolStepValue(allocator, "zigars_validation_history", "read recent validation state before rerunning expensive checks"));
    try steps.append(try toolStepValue(allocator, "zigars_capability_match", "route the next goal to a focused tool sequence"));
    try steps.append(try toolStepValue(allocator, "zigars_validation_plan", "recompute checks after any additional edits"));
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zigars_handoff_pack" });
    try obj.put(allocator, "schema_version", .{ .integer = schema_version });
    try obj.put(allocator, "snapshot", snapshot);
    try obj.put(allocator, "recommended_next_steps", .{ .array = steps });
    try obj.put(allocator, "portable", .{ .bool = true });
    try obj.put(allocator, "limitations", .{ .string = "Handoff packs summarize observed state; they do not freeze the workspace or prove that unrun validation passed." });
    return .{ .object = obj };
}

/// Builds an architecture decision record and, only when request.apply is true,
/// appends it as a JSONL line to the project-memory file (capturing a preimage
/// first). Without apply it previews and reports requires_apply. Returns an
/// allocator-owned JSON result the caller must deinit.
pub fn decisionRecordValue(
    allocator: std.mem.Allocator,
    context: app_context.ProjectIntelligenceContext,
    request: DecisionRecordRequest,
) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
    const record = try decisionRecordDataValue(allocator, context, request.title, request.decision, request.rationale, request.category);
    const preimage = preimageIdentityForPath(allocator, context, request.path) catch .null;
    if (request.apply) {
        const line = try jsonLineForRecord(allocator, record);
        defer allocator.free(line);
        const existing = if (context.workspace_store.read(allocator, .{
            .path = request.path,
            .max_bytes = 4 * 1024 * 1024,
            .provenance = "project_intelligence.decision_record.existing",
        }) catch null) |read_result| blk: {
            defer read_result.deinit(allocator);
            break :blk try allocator.dupe(u8, read_result.bytes);
        } else try allocator.dupe(u8, "");
        defer allocator.free(existing);
        var bytes: std.ArrayList(u8) = .empty;
        defer bytes.deinit(allocator);
        try bytes.appendSlice(allocator, existing);
        if (bytes.items.len > 0 and bytes.items[bytes.items.len - 1] != '\n') try bytes.append(allocator, '\n');
        try bytes.appendSlice(allocator, line);
        try bytes.append(allocator, '\n');
        _ = try context.workspace_store.write(.{
            .path = request.path,
            .bytes = bytes.items,
            .provenance = "project_intelligence.decision_record",
        });
    }
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zigars_decision_record" });
    try obj.put(allocator, "record", record);
    try obj.put(allocator, "path", try ownedString(allocator, request.path));
    try obj.put(allocator, "applied", .{ .bool = request.apply });
    try obj.put(allocator, "requires_apply", .{ .bool = !request.apply });
    try obj.put(allocator, "preimage_identity", preimage);
    return .{ .object = obj };
}

/// Serializes project memory fields into an allocator-owned JSON value; allocation failures propagate.
pub fn projectMemoryValue(
    allocator: std.mem.Allocator,
    context: app_context.ProjectIntelligenceContext,
    request: ProjectMemoryRequest,
) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
    const notes = try loadJsonLines(allocator, context, request.content, request.path, request.limit);
    const filtered = try filterRecords(allocator, notes, request.query, request.category, request.limit);
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", try ownedString(allocator, request.tool_name));
    try obj.put(allocator, "path", try ownedString(allocator, request.path));
    try obj.put(allocator, "notes", filtered);
    try obj.put(allocator, "note_count", .{ .integer = @intCast(filtered.array.items.len) });
    try obj.put(allocator, "memory_available", .{ .bool = notes.array.items.len > 0 });
    if (request.include_builtins) try obj.put(allocator, "built_in_project_policies", try builtInProjectPoliciesValue(allocator));
    try obj.put(allocator, "write_tool", .{ .string = "zigars_decision_record" });
    return .{ .object = obj };
}

/// Serializes capability match fields into an allocator-owned JSON value; allocation failures propagate.
pub fn capabilityMatchValue(
    allocator: std.mem.Allocator,
    goal: []const u8,
    limit: usize,
    entries: []const CapabilityEntry,
) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
    const lower = try std.ascii.allocLowerString(allocator, goal);
    var matches = std.json.Array.init(allocator);
    for (entries) |entry| {
        const score = matchScore(allocator, lower, entry) catch 0;
        if (score == 0) continue;
        try appendCapabilityMatch(allocator, &matches, entry, score);
    }
    sortMatches(&matches);
    while (matches.items.len > limit) _ = matches.pop();
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zigars_capability_match" });
    try obj.put(allocator, "goal", try ownedString(allocator, goal));
    try obj.put(allocator, "matches", .{ .array = matches });
    try obj.put(allocator, "confidence", .{ .string = if (matches.items.len > 0) "medium" else "low" });
    try obj.put(allocator, "limitations", .{ .string = "Capability matching uses manifest descriptions, groups, and keywords; it does not execute tools or inspect all project state." });
    return .{ .object = obj };
}

/// Serializes tool sequence plan fields into an allocator-owned JSON value; allocation failures propagate.
pub fn toolSequencePlanValue(allocator: std.mem.Allocator, goal: []const u8, changed_files: ?[]const u8) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
    const lower = try std.ascii.allocLowerString(allocator, goal);
    var steps = std.json.Array.init(allocator);
    if (std.mem.indexOf(u8, lower, "test") != null or std.mem.indexOf(u8, lower, "fail") != null) {
        try steps.append(try sequenceStepValue(allocator, "zig_test_events", "Parse failing test output or run a focused test command.", false));
        try steps.append(try sequenceStepValue(allocator, "zig_failure_history", "Check whether the failure is recurring.", false));
        try steps.append(try sequenceStepValue(allocator, "zigars_validation_plan", "Plan the post-fix validation gate.", false));
        try steps.append(try sequenceStepValue(allocator, "zigars_validation_run", "Execute selected command phases.", true));
    } else if (std.mem.indexOf(u8, lower, "impact") != null or changed_files != null) {
        try steps.append(try sequenceStepValue(allocator, "zig_impact_semantic", "Map changed files to semantic impact.", false));
        try steps.append(try sequenceStepValue(allocator, "zig_test_select_semantic", "Choose focused tests from semantic evidence.", false));
        try steps.append(try sequenceStepValue(allocator, "zigars_validation_plan", "Escalate to risk-aware validation.", false));
    } else if (std.mem.indexOf(u8, lower, "handoff") != null or std.mem.indexOf(u8, lower, "resume") != null) {
        try steps.append(try sequenceStepValue(allocator, "zigars_session_snapshot", "Capture current workspace and validation state.", false));
        try steps.append(try sequenceStepValue(allocator, "zigars_handoff_pack", "Package recommended next steps.", false));
    } else {
        try steps.append(try sequenceStepValue(allocator, "zigars_capability_match", "Find the strongest zigars tools for the goal.", false));
        try steps.append(try sequenceStepValue(allocator, "zigars_validation_plan", "Plan checks before handing work back.", false));
        try steps.append(try sequenceStepValue(allocator, "zigars_validation_run", "Run selected checks when ready.", true));
    }
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zigars_tool_sequence_plan" });
    try obj.put(allocator, "goal", try ownedString(allocator, goal));
    try obj.put(allocator, "changed_files", if (changed_files) |files| try ownedString(allocator, files) else .null);
    try obj.put(allocator, "sequence", .{ .array = steps });
    try obj.put(allocator, "stop_condition", .{ .string = "Stop after the first blocking tool result or after validation_run reports ok=true with acceptable skipped phases." });
    return .{ .object = obj };
}

/// Serializes context workspace fields into an allocator-owned JSON value; allocation failures propagate.
pub fn contextWorkspaceValue(allocator: std.mem.Allocator, context: app_context.ProjectIntelligenceContext) !std.json.Value {
    // Derive context values from one source so audit and response metadata do not diverge.
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "root", .{ .string = context.workspace.root });
    try obj.put(allocator, "cache", .{ .string = context.workspace.cache_root });
    try obj.put(allocator, "workspace_boundary", .{ .string = "realpath" });
    try obj.put(allocator, "symlink_escapes", .{ .string = "rejected" });
    try obj.put(allocator, "transport", .{ .string = context.workspace.transport });
    try obj.put(allocator, "zig_path", .{ .string = context.tool_paths.zig });
    try obj.put(allocator, "zls_status", .{ .string = context.zls_state.status });
    try obj.put(allocator, "zls_running", .{ .bool = context.zls_state.running });
    return .{ .object = obj };
}

/// Serializes project type fields into an allocator-owned JSON value; allocation failures propagate.
pub fn projectTypeValue(allocator: std.mem.Allocator, context: app_context.ProjectIntelligenceContext) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
    const graph = project_values.buildWorkspaceValue(allocator, context.staticAnalysis()) catch .null;
    const build_obj = project_values.buildZigObject(graph);
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
    else if (workspacePathExists(allocator, context, "build.zig"))
        "build_script_project"
    else
        "source_tree" });
    try obj.put(allocator, "artifact_count", .{ .integer = @intCast(artifact_count) });
    try obj.put(allocator, "module_count", .{ .integer = @intCast(module_count) });
    try obj.put(allocator, "build_test_count", .{ .integer = @intCast(test_count) });
    try obj.put(allocator, "confidence", .{ .string = if (workspacePathExists(allocator, context, "build.zig")) "medium" else "low" });
    return .{ .object = obj };
}

/// Serializes dependency context fields into an allocator-owned JSON value; allocation failures propagate.
pub fn dependencyContextValue(allocator: std.mem.Allocator, context: app_context.ProjectIntelligenceContext) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
    const read_result = context.workspace_store.read(allocator, .{
        .path = "build.zig.zon",
        .max_bytes = 1024 * 1024,
        .provenance = "project_intelligence.dependency_context",
    }) catch return .null;
    defer read_result.deinit(allocator);
    return project_values.dependencyInspectionValue(allocator, context.staticAnalysis(), read_result.bytes);
}

/// Serializes source map fields into an allocator-owned JSON value; allocation failures propagate.
pub fn sourceMapValue(allocator: std.mem.Allocator, context: app_context.ProjectIntelligenceContext, limit: usize) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
    var files = std.json.Array.init(allocator);
    var dirs = std.json.Array.init(allocator);
    var seen_dirs = std.ArrayList([]const u8).empty;
    defer seen_dirs.deinit(allocator);
    defer freeStringList(allocator, seen_dirs.items);
    var scan = try context.workspace_scanner.scanZigFiles(allocator, .{
        .path_prefix = "",
        .max_files = limit,
        .provenance = "project_intelligence.source_map",
    });
    defer scan.deinit(allocator);
    for (scan.files) |file| {
        try files.append(try ownedString(allocator, file.path));
        if (std.fs.path.dirname(file.path)) |dirname| {
            if (!stringListContains(seen_dirs.items, dirname)) {
                try seen_dirs.append(allocator, try allocator.dupe(u8, dirname));
                try dirs.append(try ownedString(allocator, dirname));
            }
        }
    }
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "analysis_kind", .{ .string = "workspace_file_scan" });
    try obj.put(allocator, "file_count", .{ .integer = @intCast(scan.files.len) });
    try obj.put(allocator, "dirs", .{ .array = dirs });
    try obj.put(allocator, "files", .{ .array = files });
    return .{ .object = obj };
}

/// Serializes quality commands fields into an allocator-owned JSON value; allocation failures propagate.
pub fn qualityCommandsValue(allocator: std.mem.Allocator, context: app_context.ProjectIntelligenceContext) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
    var commands = std.json.Array.init(allocator);
    try appendWorkspaceFormatCheckCommand(allocator, context, &commands);
    try appendUniqueCommand(allocator, &commands, "zig build test");
    try appendUniqueCommand(allocator, &commands, "zigars_validate_patch");
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "default_commands", .{ .array = commands });
    try obj.put(allocator, "final_gate", .{ .string = "zigars_validate_patch" });
    return .{ .object = obj };
}

/// Serializes context limits fields into an allocator-owned JSON value; allocation failures propagate.
pub fn contextLimitsValue(allocator: std.mem.Allocator) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "source_writes", .{ .string = "only tools with apply=true write source" });
    try obj.put(allocator, "analysis", .{ .string = "heuristic unless a ZLS/command-backed field says otherwise" });
    try obj.put(allocator, "stdout", .{ .string = "MCP JSON-RPC only; logs go to stderr" });
    return .{ .object = obj };
}

/// Serializes agent rules fields into an allocator-owned JSON value; allocation failures propagate.
pub fn agentRulesValue(allocator: std.mem.Allocator, client: []const u8, task: []const u8) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
    var rules = std.json.Array.init(allocator);
    try rules.append(try ownedString(allocator, "Call zigars_context_pack first when entering an unfamiliar Zig workspace."));
    try rules.append(try ownedString(allocator, "Use zig_format or zig_format_check for formatting; do not fall back to raw zig fmt unless zigars is unavailable."));
    try rules.append(try ownedString(allocator, "Use zig_compile_error_index or zigars_failure_fusion before interpreting compiler stderr manually."));
    try rules.append(try ownedString(allocator, "Use zigars_validate_patch as the final readiness gate before handing work back."));
    try rules.append(try ownedString(allocator, "Source-writing zigars tools are preview-only unless apply=true is explicit."));
    if (std.mem.eql(u8, client, "claude")) try rules.append(try ownedString(allocator, "Prefer compact JSON fields over long command output when summarizing to the user."));
    if (std.mem.eql(u8, client, "codex")) try rules.append(try ownedString(allocator, "Prefer zigars_patch_guard before broad multi-file edits."));
    if (std.mem.eql(u8, client, "gemini")) try rules.append(try ownedString(allocator, "Use tools/list schemas directly and keep trust/confirmation settings explicit in Gemini CLI."));
    if (std.mem.eql(u8, client, "hermes")) try rules.append(try ownedString(allocator, "Prefer an MCP integration or thin skill wrapper that passes zigars JSON through without scraping human text."));
    if (std.mem.indexOf(u8, task, "profile") != null) try rules.append(try ownedString(allocator, "Use zig_profile_plan before capture and zflame-backed tools only for rendering existing profiler data."));
    return .{ .array = rules };
}

/// Serializes agent workflow hints fields into an allocator-owned JSON value; allocation failures propagate.
pub fn agentWorkflowHintsValue(allocator: std.mem.Allocator, task: []const u8) !std.json.Value {
    // Route through a single workflow path so policy checks run in a consistent order.
    var workflows_array = std.json.Array.init(allocator);
    try workflows_array.append(try workflowHintValue(allocator, "orientation", &.{ "zigars_context_pack", "zigars_next_action" }));
    try workflows_array.append(try workflowHintValue(allocator, "compile_error", &.{ "zig_compile_error_index", "zigars_failure_fusion", "zigars_impact" }));
    try workflows_array.append(try workflowHintValue(allocator, "tests", &.{ "zig_test_failure_triage", "zig_test_select", "zigars_validate_patch" }));
    try workflows_array.append(try workflowHintValue(allocator, "patch_readiness", &.{ "zigars_patch_guard", "zigars_validate_patch", "zig_public_api_diff" }));
    if (std.mem.indexOf(u8, task, "api") != null) try workflows_array.append(try workflowHintValue(allocator, "api_change", &.{ "zig_public_api_diff", "zigars_impact", "zig_test_select" }));
    return .{ .array = workflows_array };
}

/// Serializes workflow hint fields into an allocator-owned JSON value; allocation failures propagate.
pub fn workflowHintValue(allocator: std.mem.Allocator, name: []const u8, tools: []const []const u8) !std.json.Value {
    var tool_values = std.json.Array.init(allocator);
    for (tools) |tool| try tool_values.append(try ownedString(allocator, tool));
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "name", try ownedString(allocator, name));
    try obj.put(allocator, "tools", .{ .array = tool_values });
    return .{ .object = obj };
}

/// Serializes agent tool aliases fields into an allocator-owned JSON value; allocation failures propagate.
pub fn agentToolAliasesValue(allocator: std.mem.Allocator) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "fmt", .{ .string = "zig_format" });
    try obj.put(allocator, "formatter", .{ .string = "zig_format" });
    try obj.put(allocator, "errors", .{ .string = "zig_compile_error_index" });
    try obj.put(allocator, "health", .{ .string = "zigars_doctor" });
    try obj.put(allocator, "done", .{ .string = "zigars_validate_patch" });
    try obj.put(allocator, "impact", .{ .string = "zigars_impact" });
    return .{ .object = obj };
}

/// Serializes workflow contract fields into an allocator-owned JSON value; allocation failures propagate.
pub fn workflowContractValue(
    allocator: std.mem.Allocator,
    evidence: []const u8,
    inference: []const u8,
    confidence: []const u8,
    limitations: []const u8,
    verification: []const u8,
    stop_condition: []const u8,
    tools: []const []const u8,
) !std.json.Value {
    // Route through a single workflow path so policy checks run in a consistent order.
    var next_tools = std.json.Array.init(allocator);
    for (tools) |tool| try next_tools.append(try ownedString(allocator, tool));
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "evidence", .{ .string = evidence });
    try obj.put(allocator, "inference", .{ .string = inference });
    try obj.put(allocator, "confidence", .{ .string = confidence });
    try obj.put(allocator, "limitations", .{ .string = limitations });
    try obj.put(allocator, "verification", .{ .string = verification });
    try obj.put(allocator, "stop_condition", .{ .string = stop_condition });
    try obj.put(allocator, "recommended_next_tools", .{ .array = next_tools });
    return .{ .object = obj };
}

/// Serializes next action plan fields into an allocator-owned JSON value; allocation failures propagate.
pub fn nextActionPlanValue(allocator: std.mem.Allocator, goal: []const u8, changed_files: ?[]const u8, last_error: ?[]const u8) !std.json.Value {
    const lower = try project_values.asciiLowerAllocLocal(allocator, goal);
    defer allocator.free(lower);
    var steps = std.json.Array.init(allocator);
    // Keyword buckets intentionally choose a small, ordered tool sequence rather
    // than trying to infer a complete plan from free-form goal text.
    if (std.mem.indexOf(u8, lower, "test") != null) {
        try steps.append(try toolStepValue(allocator, "zig_test_failure_triage", "group failing tests and panic clues"));
        try steps.append(try toolStepValue(allocator, "zig_test_select", "choose focused rerun commands for touched files or symbols"));
        try steps.append(try toolStepValue(allocator, "zigars_validate_patch", "confirm the fix with the standard validation gate"));
    } else if (std.mem.indexOf(u8, lower, "compile") != null or std.mem.indexOf(u8, lower, "build") != null or last_error != null) {
        try steps.append(try toolStepValue(allocator, "zig_compile_error_index", "group compiler diagnostics by file"));
        try steps.append(try toolStepValue(allocator, "zigars_failure_fusion", "extract primary failure, rerun command, and suggested tools"));
        try steps.append(try toolStepValue(allocator, "zigars_impact", "find affected importers/tests before editing"));
    } else if (std.mem.indexOf(u8, lower, "format") != null or std.mem.indexOf(u8, lower, "fmt") != null) {
        try steps.append(try toolStepValue(allocator, "zig_format_check", "check formatting without writing"));
        try steps.append(try toolStepValue(allocator, "zig_format", "preview or apply formatting with apply=true"));
    } else if (std.mem.indexOf(u8, lower, "profile") != null or std.mem.indexOf(u8, lower, "flame") != null) {
        try steps.append(try toolStepValue(allocator, "zig_profile_plan", "choose platform capture workflow"));
        try steps.append(try toolStepValue(allocator, "zig_flamegraph", "render captured profiler output through zflame"));
    } else if (std.mem.indexOf(u8, lower, "pr") != null or std.mem.indexOf(u8, lower, "review") != null or std.mem.indexOf(u8, lower, "done") != null) {
        try steps.append(try toolStepValue(allocator, "zigars_validate_patch", "run the final readiness gate"));
        try steps.append(try toolStepValue(allocator, "zig_public_api_diff", "check accidental public API changes"));
    } else {
        try steps.append(try toolStepValue(allocator, "zigars_context_pack", "orient to project shape and validation policy"));
        try steps.append(try toolStepValue(allocator, "zigars_impact", "map touched files or symbols to likely tests"));
        try steps.append(try toolStepValue(allocator, "zigars_validate_patch", "validate before handoff"));
    }
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zigars_next_action" });
    try obj.put(allocator, "goal", try ownedString(allocator, goal));
    try obj.put(allocator, "changed_files", if (changed_files) |files| try ownedString(allocator, files) else .null);
    try obj.put(allocator, "last_error", if (last_error) |err| try ownedString(allocator, err) else .null);
    try obj.put(allocator, "recommended_steps", .{ .array = steps });
    try obj.put(allocator, "classification_reasons", .{ .string = "keyword match over user goal, optional changed_files, and optional last_error" });
    try obj.put(allocator, "workflow_contract", try workflowContractValue(allocator, "user_supplied_goal plus optional git/status text and last_error", "deterministic routing hint, not semantic proof of correctness", "medium", "keyword classification can miss project-specific intent; run the recommended verification gate", "zigars_validate_patch", "stop when zigars_validate_patch passes or the next tool returns a focused source edit blocker", &.{ "zigars_context_pack", "zigars_validate_patch" }));
    try obj.put(allocator, "stop_when", .{ .string = "stop when zigars_validate_patch passes or the next tool returns a focused source edit blocker" });
    return .{ .object = obj };
}

/// Serializes tool step fields into an allocator-owned JSON value; allocation failures propagate.
pub fn toolStepValue(allocator: std.mem.Allocator, tool: []const u8, reason: []const u8) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "tool", .{ .string = tool });
    try obj.put(allocator, "reason", .{ .string = reason });
    return .{ .object = obj };
}

/// Serializes validation next action fields into an allocator-owned JSON value; allocation failures propagate.
pub fn validationNextActionValue(allocator: std.mem.Allocator, ok: bool, phases: std.json.Array) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
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
        try obj.put(allocator, "tool", .{ .string = "zigars_failure_fusion" });
        try obj.put(allocator, "reason", .{ .string = "inspect the first failing validation phase and primary diagnostic" });
        return .{ .object = obj };
    }
    try obj.put(allocator, "status", .{ .string = "blocked" });
    try obj.put(allocator, "tool", .{ .string = "zigars_validate_patch" });
    try obj.put(allocator, "reason", .{ .string = "validation failed without a command phase" });
    return .{ .object = obj };
}

/// Serializes failure fusion fields into an allocator-owned JSON value; allocation failures propagate.
pub fn failureFusionValue(allocator: std.mem.Allocator, stderr: []const u8, stdout: []const u8, argv: []const []const u8, ok: bool) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
    const compiler = try project_values.compilerErrorIndexValue(allocator, stderr, stdout, argv);
    const tests = try project_values.testFailureTriageValue(allocator, stderr, stdout, argv, ok);
    var suggested = std.json.Array.init(allocator);
    try suggested.append(try ownedString(allocator, "zigars_impact"));
    try suggested.append(try ownedString(allocator, "zig_test_select"));
    try suggested.append(try ownedString(allocator, "zigars_validate_patch"));

    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zigars_failure_fusion" });
    try obj.put(allocator, "ok", .{ .bool = ok });
    try obj.put(allocator, "compiler", compiler);
    try obj.put(allocator, "tests", tests);
    try obj.put(allocator, "primary_failure", try primaryFailureValue(allocator, compiler, tests));
    try obj.put(allocator, "suggested_tools", .{ .array = suggested });
    try obj.put(allocator, "rerun_command", .{ .string = try project_values.commandString(allocator, argv) });
    try obj.put(allocator, "workflow_contract", try workflowContractValue(allocator, "compiler stderr/stdout and command exit status", "primary failure is selected from parsed compiler/test output", "medium", "compiler and test parsing is best-effort; raw command output remains the audit source", "rerun_command then zigars_validate_patch", "stop when the primary diagnostic is resolved or validation passes", &.{ "zigars_impact", "zig_test_select", "zigars_validate_patch" }));
    return .{ .object = obj };
}

/// Serializes primary failure fields into an allocator-owned JSON value; allocation failures propagate.
pub fn primaryFailureValue(_: std.mem.Allocator, compiler: std.json.Value, tests: std.json.Value) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
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
    return .null;
}

/// Serializes impact hit fields into an allocator-owned JSON value; allocation failures propagate.
pub fn impactHitValue(allocator: std.mem.Allocator, file: []const u8, target: []const u8, reason: []const u8) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "file", try ownedString(allocator, file));
    try obj.put(allocator, "target", try ownedString(allocator, target));
    try obj.put(allocator, "reason", .{ .string = reason });
    return .{ .object = obj };
}

/// Appends public decls for file data into caller-provided storage, propagating allocation failures.
pub fn appendPublicDeclsForFile(allocator: std.mem.Allocator, out: *std.json.Array, file: []const u8, contents: []const u8) !void {
    // Append in deterministic order so completion and snapshot output remain stable.
    var lines = std.mem.splitScalar(u8, contents, '\n');
    var line_no: usize = 1;
    while (lines.next()) |line| : (line_no += 1) {
        const trimmed = std.mem.trim(u8, line, " \t");
        if (!std.mem.startsWith(u8, trimmed, "pub ")) continue;
        if (zig_analysis.declKind(trimmed)) |kind| {
            var obj = std.json.ObjectMap.empty;
            try obj.put(allocator, "file", try ownedString(allocator, file));
            try obj.put(allocator, "line", .{ .integer = @intCast(line_no) });
            try obj.put(allocator, "kind", .{ .string = kind });
            try obj.put(allocator, "name", if (project_values.declName(trimmed, kind)) |name| try ownedString(allocator, name) else .null);
            try obj.put(allocator, "signature", try ownedString(allocator, trimmed));
            try out.append(.{ .object = obj });
        }
    }
}

/// Serializes generated project profile fields into an allocator-owned JSON value; allocation failures propagate.
pub fn generatedProjectProfileValue(allocator: std.mem.Allocator, context: app_context.ProjectIntelligenceContext) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "schema_version", .{ .integer = 1 });
    try obj.put(allocator, "workspace", .{ .string = context.workspace.root });
    try obj.put(allocator, "project_type", try projectTypeValue(allocator, context));
    try obj.put(allocator, "quality", try qualityCommandsValue(allocator, context));
    try obj.put(allocator, "generated_dirs", try generatedDirsValue(allocator));
    try obj.put(allocator, "agent_entrypoint", .{ .string = "zigars_context_pack" });
    return .{ .object = obj };
}

/// Serializes generated dirs fields into an allocator-owned JSON value; allocation failures propagate.
pub fn generatedDirsValue(allocator: std.mem.Allocator) !std.json.Value {
    var dirs = std.json.Array.init(allocator);
    for ([_][]const u8{ ".zig-cache", ".zigars-cache", "zig-out", "zig-pkg", "coverage" }) |dir| {
        try dirs.append(try ownedString(allocator, dir));
    }
    return .{ .array = dirs };
}

test "project intelligence private helpers cover fallback edge cases" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const no_phase = [_]workflows.PhaseRun{};
    try std.testing.expect(phaseByName(no_phase[0..], "missing") == null);

    var unique_files = std.json.Array.init(allocator);
    try unique_files.append(.{ .string = "ignored" });
    try appendUniqueFileObject(allocator, &unique_files, "src/main.zig", "input_changed_file", "high");
    try appendUniqueFileObject(allocator, &unique_files, "src/main.zig", "duplicate", "low");
    try std.testing.expectEqual(@as(usize, 2), unique_files.items.len);

    var test_obj = std.json.ObjectMap.empty;
    try test_obj.put(allocator, "file", try ownedString(allocator, "tests/foo_test.zig"));
    try test_obj.put(allocator, "name", try ownedString(allocator, "foo handles edge cases"));
    var test_items = std.json.Array.init(allocator);
    try test_items.append(.{ .string = "ignored" });
    try test_items.append(.{ .object = test_obj });
    var matched_tests = std.json.Array.init(allocator);
    try collectTestsForFile(allocator, .{ .array = test_items }, &matched_tests, "src/foo.zig");
    try std.testing.expectEqual(@as(usize, 1), matched_tests.items.len);

    const non_object_summary = (try failureSummaryValue(allocator, .null, false, &.{ "zig", "build" })).object;
    try std.testing.expect(non_object_summary.get("primary").? == .null);

    var other_path_primary = std.json.ObjectMap.empty;
    try other_path_primary.put(allocator, "path", try ownedString(allocator, "README.md"));
    try std.testing.expectEqualStrings("path:README.md", (try likelyFailureScopeValue(allocator, .{ .object = other_path_primary })).string);

    const lossy = try safeTextAlloc(allocator, "\xffok\xc3");
    try std.testing.expect(lossy.invalid_utf8);
    try std.testing.expectEqualStrings("utf-8-lossy", lossy.encoding);
    try std.testing.expectEqual(@as(usize, 4), lossy.byte_count);

    const backend = (try backendErrorValue(allocator, "zls", "request", error.Timeout, "restart backend")).object;
    try std.testing.expectEqualStrings("timeout", backend.get("error_kind").?.string);

    var number_object = std.json.ObjectMap.empty;
    try number_object.put(allocator, "count", .{ .number_string = "42" });
    try std.testing.expectEqual(@as(?i64, 42), integerField(number_object, "count"));

    const cloned_number = try cloneValue(allocator, .{ .number_string = "99" });
    try std.testing.expectEqualStrings("99", cloned_number.number_string);
}

test "project intelligence JSON builders clean up allocation failures" {
    try sweepAllocationFailures(projectIntelligenceAllocationScenario);
}

test "project intelligence allocation sweep propagates non allocation errors" {
    try std.testing.expectError(error.AccessDenied, sweepAllocationFailures(nonAllocationFailureScenario));
}

test "buildZigArgv resolves the fmt-check path through the workspace sandbox" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var runtime = AllocationRuntime{};
    const context = runtime.context();

    // An escaping path is rejected by the workspace resolve before it can reach
    // the `zig fmt --check` argv. Pre-fix this path was appended verbatim.
    try std.testing.expectError(
        error.PathOutsideWorkspace,
        buildZigArgv(allocator, context, "fmt-check", "../../../../etc/hosts", null, &.{}),
    );

    // A valid path is resolved and the *resolved* path lands in the argv.
    {
        var argv = try buildZigArgv(allocator, context, "fmt-check", "lib/api.zig", null, &.{});
        defer argv.deinit(allocator);
        try std.testing.expectEqual(@as(usize, 4), argv.items.len);
        try std.testing.expectEqualStrings("zig", argv.items[0]);
        try std.testing.expectEqualStrings("fmt", argv.items[1]);
        try std.testing.expectEqualStrings("--check", argv.items[2]);
        try std.testing.expectEqualStrings("/repo/lib/api.zig", argv.items[3]);
    }

    // The `src` default is preserved when no path is supplied.
    {
        var argv = try buildZigArgv(allocator, context, "fmt-check", null, null, &.{});
        defer argv.deinit(allocator);
        try std.testing.expectEqual(@as(usize, 4), argv.items.len);
        try std.testing.expectEqualStrings("src", argv.items[3]);
    }
}

test "buildZigArgv guards extra args against workspace-escaping build flags" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var runtime = AllocationRuntime{};
    const context = runtime.context();

    // `zig build` family: each path-bearing build-system flag is rejected,
    // covering the space- and `=`-separated forms. Pre-fix these tokens were
    // appended directly to `zig build`, redirecting build/exec output outside
    // the workspace.
    const denied = [_][]const []const u8{
        &.{ "--build-file", "/tmp/evil/build.zig" },
        &.{ "--prefix", "/tmp/escape" },
        &.{"--cache-dir=/tmp/escape"},
        &.{ "--global-cache-dir", "/tmp/escape" },
        &.{ "--zig-lib-dir", "/tmp/escape" },
        &.{"-femit-bin=/tmp/escape/out"},
        &.{"--prefix-lib-dir=/tmp/escape"},
        // System-integration flags that take a path operand also escape.
        &.{ "--search-prefix", "/tmp/escape" },
        &.{ "--sysroot", "/tmp/escape" },
        &.{"--libc=/tmp/escape/libc.txt"},
        &.{ "--libc-runtimes", "/tmp/escape" },
        &.{ "--system", "/tmp/escape/pkgs" },
    };
    for (denied) |extra| {
        try std.testing.expectError(
            error.UnsafeBuildFlag,
            buildZigArgv(allocator, context, "build", null, null, extra),
        );
        try std.testing.expectError(
            error.UnsafeBuildFlag,
            buildZigArgv(allocator, context, "build-test", null, null, extra),
        );
    }

    // Benign build options are preserved verbatim with no `--` separator (which
    // would otherwise carry run-step semantics for `zig build`).
    {
        var argv = try buildZigArgv(allocator, context, "build", null, null, &.{"-Doptimize=ReleaseSafe"});
        defer argv.deinit(allocator);
        try std.testing.expectEqual(@as(usize, 3), argv.items.len);
        try std.testing.expectEqualStrings("zig", argv.items[0]);
        try std.testing.expectEqualStrings("build", argv.items[1]);
        try std.testing.expectEqualStrings("-Doptimize=ReleaseSafe", argv.items[2]);
        try std.testing.expect(!argvHasToken(argv.items, "--"));
    }

    // `zig test`: a `--` separator is inserted before user tokens, so even a
    // build-system flag is handed inert to the test binary instead of the
    // compiler. Pre-fix the token followed `zig test <file>` directly.
    {
        var argv = try buildZigArgv(allocator, context, "test", "src/util.zig", null, &.{"-femit-bin=/tmp/escape"});
        defer argv.deinit(allocator);
        try std.testing.expectEqual(@as(usize, 5), argv.items.len);
        try std.testing.expectEqualStrings("zig", argv.items[0]);
        try std.testing.expectEqualStrings("test", argv.items[1]);
        try std.testing.expectEqualStrings("/repo/src/util.zig", argv.items[2]);
        try std.testing.expectEqualStrings("--", argv.items[3]);
        try std.testing.expectEqualStrings("-femit-bin=/tmp/escape", argv.items[4]);
    }
}

test "buildZigArgv denies -p prefix alias and --build-runner override" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var runtime = AllocationRuntime{};
    const context = runtime.context();

    // Residual deny-list gap on the `zig build` family: `-p` is the documented
    // short alias of `--prefix` (redirects install output), and `--build-runner`
    // points the build at an arbitrary Zig file (arbitrary code execution
    // outside the workspace, strictly worse than the already-denied
    // `--build-file`). Both must fail closed in every operand form Zig accepts:
    // `-p` only takes a space-separated operand, while `--build-runner` accepts
    // both the space- and `=`-separated forms.
    const denied = [_][]const []const u8{
        &.{ "-p", "/tmp/escape" },
        &.{ "--build-runner", "/tmp/x.zig" },
        &.{"--build-runner=/tmp/x.zig"},
    };
    for (denied) |extra| {
        try std.testing.expectError(
            error.UnsafeBuildFlag,
            buildZigArgv(allocator, context, "build", null, null, extra),
        );
        try std.testing.expectError(
            error.UnsafeBuildFlag,
            buildZigArgv(allocator, context, "build-test", null, null, extra),
        );
    }

    // The benign short build option `-Doptimize=ReleaseSafe` still passes
    // through untouched; the new `-p` entry must not over-match `-D*` tokens.
    {
        var argv = try buildZigArgv(allocator, context, "build", null, null, &.{"-Doptimize=ReleaseSafe"});
        defer argv.deinit(allocator);
        try std.testing.expectEqual(@as(usize, 3), argv.items.len);
        try std.testing.expectEqualStrings("-Doptimize=ReleaseSafe", argv.items[2]);
    }
}

/// Returns true when `argv` contains an exact token match for `needle`.
fn argvHasToken(argv: []const []const u8, needle: []const u8) bool {
    for (argv) |arg| {
        if (std.mem.eql(u8, arg, needle)) return true;
    }
    return false;
}

/// Runs `scenario` once to count its allocations, then replays it under a
/// FailingAllocator that fails at each index (capped at 32), asserting every
/// failure surfaces as OutOfMemory with no leak — an OOM-cleanup fuzz harness.
fn sweepAllocationFailures(comptime scenario: fn (std.mem.Allocator) anyerror!void) !void {
    // Keep this logic centralized so callers observe one consistent behavior path.
    const allocation_count = blk: {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var failing = std.testing.FailingAllocator.init(arena.allocator(), .{});
        try scenario(failing.allocator());
        break :blk failing.alloc_index;
    };
    try std.testing.expect(allocation_count > 0);
    for (0..@min(allocation_count, 32)) |fail_index| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var failing = std.testing.FailingAllocator.init(arena.allocator(), .{ .fail_index = fail_index });
        scenario(failing.allocator()) catch |err| switch (err) {
            error.OutOfMemory => continue,
            error.WriteFailed => continue,
            else => return err,
        };
    }
}

/// Exercises project-intelligence serializers under failing allocators without relying on workspace state.
fn projectIntelligenceAllocationScenario(allocator: std.mem.Allocator) !void {
    var runtime = AllocationRuntime{};
    const context = runtime.context();
    const run_id = try context.clock_and_ids.nextId(allocator, .{ .prefix = "alloc" });
    _ = run_id.len;
    const write = try context.workspace_store.write(.{ .path = "trace.json", .bytes = "{}", .provenance = "allocation_scenario" });
    _ = write.bytes_written;
    _ = try contextPackValue(allocator, context, .{ .mode = "standard", .token_budget = 1200 });
    _ = try agentGuideValue(allocator, "codex", "profile api");
    _ = try validatePatchValue(allocator, context, .{ .mode = "quick", .changed_files = "src/main.zig", .timeout_ms = 1000 });
    _ = try impactValue(allocator, context, .{ .files = "src/util.zig", .symbols = "run", .limit = 10 });
    _ = try projectProfileValue(allocator, context, .{});
    _ = try patchGuardValue(allocator, context, .{ .files = "src/main.zig zig-out/generated.zig ../secret" });
    _ = try semanticImpactValue(allocator, context, .{ .files = "src/util.zig", .symbols = "run", .limit = 10 }, "zig_impact_semantic");
    _ = try testSelectSemanticValue(allocator, context, .{ .files = "src/util.zig", .symbols = "run", .limit = 10 });

    // Build representative validation data so allocation sweeps cover nested workflow payloads.
    const phase_argv = workflows.OwnedArgv{ .items = &.{ "zig", "build", "test" } };
    const check_argv = workflows.OwnedArgv{ .items = &.{ "zig", "ast-check", "src/main.zig" } };
    var phases = [_]workflows.Phase{
        .{ .id = "build_test", .kind = .command, .tool = "zigars_validation_run", .argv = phase_argv, .reason = "build", .required = true, .risk = "project_code" },
        .{ .id = "semantic", .kind = .tool_only, .tool = "zig_impact_semantic", .argv = null, .reason = "semantic", .required = false, .risk = "none" },
    };
    var skipped = [_]workflows.SkippedPhase{.{ .name = "coverage", .reason = "not requested" }};
    const facts = workflows.OwnedStringList{ .items = &.{"src/main.zig"} };
    const unknowns = workflows.OwnedStringList{ .items = &.{"coverage not run"} };
    const plan = workflows.PlanResult{
        .plan_id = "plan-1",
        .mode = "standard",
        .goal = "fix bug",
        .facts = facts,
        .risk = .{ .changed_file_count = 1, .touches_zig_source = true, .touches_build_config = false, .touches_docs = false, .level = "medium" },
        .phases = phases[0..],
        .skipped_phases = skipped[0..],
        .unknowns = unknowns,
    };
    _ = try validationPlanValueFromUsecase(allocator, plan);
    var phase_runs = [_]workflows.PhaseRun{
        .{
            .name = "build_test",
            .ok = false,
            .argv = phase_argv,
            .cwd = "/repo",
            .timeout_ms = 1000,
            .outcome = .{ .result = .{
                .exit_code = 1,
                .term = .{ .exited = 1 },
                .stdout = "PASS util_test 12ms\n",
                .stderr = "src/main.zig:1:1: error: bad\n1/1 test.foo...FAIL (TestExpectedEqual)\n",
                .duration_ms = 12,
                .timed_out = false,
                .stdout_truncated = true,
                .stderr_truncated = false,
            } },
        },
        .{
            .name = "ast_check",
            .ok = false,
            .argv = check_argv,
            .cwd = "/repo",
            .timeout_ms = 1000,
            .outcome = .{ .port_error = error.Timeout },
        },
    };
    var failures = [_]workflows.FailureRecord{.{ .phase = "build_test", .fingerprint = "src/main.zig:error:bad" }};
    var slow = [_]workflows.SlowPhase{.{ .phase = "build_test", .duration_ms = 1200 }};
    const record = workflows.HistoryRecord{
        .recorded_unix_ms = 1_700_000_000_000,
        .ok = false,
        .plan_id = "plan-1",
        .phase_count = 2,
        .skipped_count = 1,
        .failures = failures[0..],
        .slow_phases = slow[0..],
    };
    const report = workflows.RunReport{
        .ok = false,
        .plan = plan,
        .phases = phase_runs[0..],
        .skipped_phases = skipped[0..],
        .history_record = record,
        .history_path = workflows.history_path_default,
        .history_applied = false,
        .requires_apply_for_history = true,
        .preimage_identity = .{ .exists = true, .bytes = 3, .sha256 = "abc" },
    };
    _ = try validationRunValue(allocator, report);

    // Exercise history, memory, and routing serializers after the main validation payloads.
    var history_failures = [_]workflows.HistoryFailure{.{ .fingerprint = "src/main.zig:error:bad", .sample_json = "{\"phase\":\"build_test\"}" }};
    var runs = [_]workflows.HistoryRun{
        .{ .raw_json = "{\"ok\":false}", .ok = false, .failures = history_failures[0..] },
        .{ .raw_json = "not-json", .ok = true, .failures = history_failures[0..0] },
        .{ .raw_json = "{\"ok\":true}", .ok = true, .failures = history_failures[0..0] },
    };
    var groups = [_]workflows.FailureGroup{.{ .fingerprint = "src/main.zig:error:bad", .count = 2, .sample_json = "not-json" }};
    var history = workflows.HistoryResult{ .view = .runs, .history_available = true, .runs = runs[0..], .last_run_index = 0, .last_good_index = 2, .failure_groups = groups[0..] };
    _ = try validationHistoryToolValue(allocator, "zigars_validation_history", history);
    history.view = .flakes;
    _ = try validationHistoryToolValue(allocator, "zig_test_flake_history", history);
    history.view = .failures;
    _ = try validationHistoryToolValue(allocator, "zig_failure_history", history);

    _ = try testTimingValue(allocator, "PASS util_test 12ms\nslow case 340ms\n");
    _ = try sessionSnapshotValue(allocator, context, .{ .kind = "zigars_session_snapshot", .goal = "finish", .changed_files = "src/main.zig", .validation = "{\"ok\":false}", .last_error = "error: bad" });
    _ = try handoffPackValue(allocator, context, .{ .kind = "zigars_handoff_pack", .goal = "resume", .changed_files = "src/main.zig" });
    _ = try decisionRecordValue(allocator, context, .{ .title = "Decision", .decision = "Use ports", .rationale = "tests", .apply = false });
    _ = try projectMemoryValue(allocator, context, .{ .query = "ports", .category = "architecture", .limit = 5, .include_builtins = true, .tool_name = "zigars_project_memory" });

    const risk = ToolRisk{ .level = "medium", .mcp_read_only_hint = true, .writes_source = false, .writes_artifacts = false, .writes_require_apply = false, .preview_by_default = true, .mutates_lsp_state = false, .executes_project_code = false, .executes_user_command = false, .executes_backend = false };
    const entries = [_]CapabilityEntry{.{ .name = "zigars_validate_patch", .description = "validate patch", .group = "validation", .group_keywords = &.{ "validate", "patch" }, .risk = risk, .plan_kind = "read" }};
    _ = try capabilityMatchValue(allocator, "validate patch", 1, entries[0..]);
    _ = try toolSequencePlanValue(allocator, "fix failing test", "src/main.zig");
    _ = try contextWorkspaceValue(allocator, context);
    _ = try projectTypeValue(allocator, context);
    _ = try sourceMapValue(allocator, context, 10);
    _ = try qualityCommandsValue(allocator, context);
    _ = try contextLimitsValue(allocator);
    _ = try agentToolAliasesValue(allocator);
    _ = try nextActionPlanValue(allocator, "compile error", "src/main.zig", "error: bad");
    var failed_phase = std.json.ObjectMap.empty;
    try failed_phase.put(allocator, "name", .{ .string = "build_test" });
    try failed_phase.put(allocator, "ok", .{ .bool = false });
    var phase_values = std.json.Array.init(allocator);
    try phase_values.append(.{ .object = failed_phase });
    _ = try validationNextActionValue(allocator, false, phase_values);
    _ = try failureFusionValue(allocator, "src/main.zig:1:1: error: bad\n", "PASS util_test 12ms\n", &.{ "zig", "build", "test" }, false);
    _ = try generatedProjectProfileValue(allocator, context);
    _ = try commandTermValue(allocator, .signal);
    _ = try safeTextAlloc(allocator, "\xffok\xc3");
    _ = try backendErrorValue(allocator, "zig", "run", error.AccessDenied, "fix permissions");
    _ = try serializeValue(allocator, .{ .string = "json" });
    const paths = try pathListFromTextAndPatch(allocator, "src/main.zig", "diff --git a/src/util.zig b/src/util.zig\n--- a/src/util.zig\n+++ b/src/util.zig\n");
    _ = paths.items.len;
    const changed = try changedPathList(allocator, context, null, 1000);
    _ = changed.items.len;
}

/// Negative control for sweepAllocationFailures: turns an allocation failure into
/// a non-OOM error so the sweep is shown to surface unexpected errors rather than
/// silently treating every failure as OutOfMemory.
fn nonAllocationFailureScenario(allocator: std.mem.Allocator) !void {
    const bytes = allocator.alloc(u8, 1) catch return error.AccessDenied;
    defer allocator.free(bytes);
}

/// Carries allocation runtime data across use case and port boundaries.
const AllocationRuntime = struct {
    /// Returns a typed context backed by this fixture or runtime state.
    fn context(self: *AllocationRuntime) app_context.ProjectIntelligenceContext {
        // Derive context values from one source so audit and response metadata do not diverge.
        return .{
            .workspace = .{ .root = "/repo", .cache_root = "/repo/.zigars-cache", .transport = "test" },
            .tool_paths = .{ .zig = "zig" },
            .timeouts = .{ .command_ms = 30_000, .zls_ms = 30_000 },
            .zls_state = .{ .status = "connected", .running = true },
            .command_runner = .{ .ptr = self, .vtable = &.{ .run = commandRun } },
            .workspace_store = .{ .ptr = self, .vtable = &.{
                .resolve = workspaceResolve,
                .read = workspaceRead,
                .write = workspaceWrite,
                .exists = workspaceExists,
            } },
            .workspace_scanner = .{ .ptr = self, .vtable = &.{ .scan_zig_files = scanZigFiles } },
            .clock_and_ids = .{ .ptr = self, .vtable = &.{ .now = now, .nextId = nextId } },
        };
    }

    /// Invokes command run with caller-owned inputs; command and allocation failures propagate.
    fn commandRun(_: *anyopaque, allocator: std.mem.Allocator, request: ports.CommandRequest) ports.PortError!ports.CommandResult {
        const is_git = request.argv.len >= 2 and std.mem.eql(u8, request.argv[0], "git");
        const stdout = if (is_git) " M src/main.zig\nR  old.zig -> src/util.zig\n" else "PASS util_test 12ms\nStep test succeeded\n";
        const stderr = if (!is_git and request.argv.len > 1 and std.mem.eql(u8, request.argv[1], "ast-check")) "src/main.zig:1:1: warning: checked\n" else "";
        return .{ .exit_code = 0, .stdout = try allocator.dupe(u8, stdout), .stderr = try allocator.dupe(u8, stderr), .duration_ms = 12, .owns_stdout = true, .owns_stderr = true };
    }

    /// Resolves a workspace-relative fixture path.
    fn workspaceResolve(_: *anyopaque, allocator: std.mem.Allocator, request: ports.WorkspaceResolveRequest) ports.PortError!ports.WorkspaceResolveResult {
        if (std.mem.indexOf(u8, request.path, "..") != null) return error.PathOutsideWorkspace;
        return .{ .path = try std.fmt.allocPrint(allocator, "/repo/{s}", .{request.path}), .owns_path = true };
    }

    /// Reads workspace fixture bytes for the requested path.
    fn workspaceRead(_: *anyopaque, allocator: std.mem.Allocator, request: ports.WorkspaceReadRequest) ports.PortError!ports.WorkspaceReadResult {
        const bytes =
            if (std.mem.eql(u8, request.path, "build.zig"))
                "const std = @import(\"std\");\npub fn build(b: *std.Build) void { _ = b.addTest(.{ .root_source_file = b.path(\"tests/util_test.zig\") }); }\n"
            else if (std.mem.eql(u8, request.path, "build.zig.zon"))
                ".{ .name = .fixture, .dependencies = .{ .dep = .{ .url = \"https://example.invalid\", .hash = \"abc\" } } }\n"
            else if (std.mem.eql(u8, request.path, "src/main.zig"))
                "const util = @import(\"util.zig\");\npub fn main() void { util.run(); }\n"
            else if (std.mem.eql(u8, request.path, "src/util.zig"))
                "pub fn run() void {}\npub const Api = struct {};\n"
            else if (std.mem.eql(u8, request.path, "tests/util_test.zig"))
                "const util = @import(\"../src/util.zig\");\ntest \"run\" { util.run(); }\n"
            else if (std.mem.eql(u8, request.path, ".zigars/project-memory.jsonl"))
                "{\"category\":\"architecture\",\"title\":\"Ports\",\"decision\":\"Use typed ports\",\"rationale\":\"tests\"}\n"
            else if (std.mem.eql(u8, request.path, ".zigars/profile.json"))
                "{\"schema_version\":1}\n"
            else if (std.mem.eql(u8, request.path, ".zigars/profile.v2.json"))
                "{\"schema_version\":2}\n"
            else
                "";
        return .{ .bytes = try allocator.dupe(u8, bytes), .owns_bytes = true };
    }

    /// Stores workspace fixture bytes for the requested path.
    fn workspaceWrite(_: *anyopaque, request: ports.WorkspaceWriteRequest) ports.PortError!ports.WorkspaceWriteResult {
        return .{ .bytes_written = request.bytes.len };
    }

    /// Reports whether the requested workspace path exists.
    fn workspaceExists(_: *anyopaque, _: std.mem.Allocator, request: ports.WorkspaceExistsRequest) ports.PortError!ports.WorkspaceExistsResult {
        const exists = std.mem.eql(u8, request.path, "build.zig") or std.mem.eql(u8, request.path, "build.zig.zon") or std.mem.eql(u8, request.path, "src") or std.mem.eql(u8, request.path, "src/main.zig") or std.mem.eql(u8, request.path, "src/util.zig") or std.mem.eql(u8, request.path, "tests/util_test.zig");
        return .{ .exists = exists, .kind = if (std.mem.eql(u8, request.path, "src")) .directory else .file };
    }

    /// Scans fixture workspace entries and returns matching paths.
    fn scanZigFiles(_: *anyopaque, allocator: std.mem.Allocator, _: ports.WorkspaceScanRequest) ports.PortError!ports.WorkspaceScanResult {
        const names = [_][]const u8{ "src/main.zig", "src/util.zig", "tests/util_test.zig" };
        const files = try allocator.alloc(ports.WorkspaceScanFile, names.len);
        for (names, 0..) |name, index| files[index] = .{ .path = try allocator.dupe(u8, name) };
        return .{ .files = files, .owns_memory = true };
    }

    /// Returns the fixture clock timestamp.
    fn now(_: *anyopaque) ports.PortError!ports.Instant {
        return .{ .unix_ms = 1_700_000_000_000, .monotonic_ms = 1 };
    }

    /// Allocates the next deterministic fixture identifier.
    fn nextId(_: *anyopaque, allocator: std.mem.Allocator, request: ports.IdRequest) ports.PortError![]const u8 {
        return std.fmt.allocPrint(allocator, "{s}-1", .{request.prefix});
    }
};
