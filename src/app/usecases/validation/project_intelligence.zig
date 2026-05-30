//! Validation intelligence orchestration for next-step planning and patch safety checks.
const std = @import("std");

const app_context = @import("../../context.zig");
const ports = @import("../../ports.zig");
const zig_analysis = @import("../../../domain/zig/analysis.zig");
const project_values = @import("../static_analysis/project_values.zig");
const semantic_usecase = @import("../static_analysis/semantic_index.zig");
const workflows = @import("workflows.zig");

/// Schema version written into this module's structured payloads.
pub const schema_version: i64 = 1;
/// Default semantic limit used when the caller omits an explicit value.
pub const semantic_limit_default: usize = 500;
/// Default memory path used when the caller omits an explicit value.
pub const memory_path_default = ".zigars/project-memory.jsonl";
/// Default profile path used when the caller omits an explicit value.
pub const profile_path_default = ".zigars/profile.json";

/// Carries path list data across use case and port boundaries.
pub const PathList = struct {
    items: []const []const u8,

    /// Releases allocations owned by this value; callers must not use owned slices after this returns.
    pub fn deinit(self: *PathList, allocator: std.mem.Allocator) void {
        freeStringList(allocator, self.items);
        allocator.free(self.items);
        self.* = undefined;
    }
};

/// Carries context pack request data across use case and port boundaries.
pub const ContextPackRequest = struct {
    mode: []const u8 = "standard",
    token_budget: i64 = 4000,
};

/// Carries validate patch request data across use case and port boundaries.
pub const ValidatePatchRequest = struct {
    mode: []const u8 = "standard",
    changed_files: ?[]const u8 = null,
    timeout_ms: i64,
    stop_on_failure: bool = false,
};

/// Carries failure fusion request data across use case and port boundaries.
pub const FailureFusionRequest = struct {
    text: ?[]const u8 = null,
    command: ?[]const u8 = null,
    file: ?[]const u8 = null,
    filter: ?[]const u8 = null,
    extra_args: []const []const u8 = &.{},
    timeout_ms: i64,
};

/// Carries impact request data across use case and port boundaries.
pub const ImpactRequest = struct {
    files: ?[]const u8 = null,
    symbols: ?[]const u8 = null,
    limit: usize = 300,
};

/// Carries project profile request data across use case and port boundaries.
pub const ProjectProfileRequest = struct {
    content: ?[]const u8 = null,
    apply: bool = false,
};

/// Carries patch guard request data across use case and port boundaries.
pub const PatchGuardRequest = struct {
    files: ?[]const u8 = null,
    patch: ?[]const u8 = null,
};

/// Carries semantic impact request data across use case and port boundaries.
pub const SemanticImpactRequest = struct {
    files: ?[]const u8 = null,
    diff: ?[]const u8 = null,
    symbols: ?[]const u8 = null,
    limit: usize = semantic_limit_default,
};

/// Defines the allowed event command kind variants accepted by this workflow.
pub const EventCommandKind = enum { build, test_cmd };

/// Carries command events request data across use case and port boundaries.
pub const CommandEventsRequest = struct {
    text: ?[]const u8 = null,
    command: ?[]const u8 = null,
    file: ?[]const u8 = null,
    filter: ?[]const u8 = null,
    extra_args: []const []const u8 = &.{},
    timeout_ms: i64,
    kind: EventCommandKind,
};

/// Carries session snapshot request data across use case and port boundaries.
pub const SessionSnapshotRequest = struct {
    kind: []const u8,
    goal: ?[]const u8 = null,
    changed_files: ?[]const u8 = null,
    diff: ?[]const u8 = null,
    validation: ?[]const u8 = null,
    last_error: ?[]const u8 = null,
};

/// Carries decision record request data across use case and port boundaries.
pub const DecisionRecordRequest = struct {
    title: []const u8,
    decision: []const u8,
    rationale: ?[]const u8 = null,
    category: []const u8 = "architecture",
    path: []const u8 = memory_path_default,
    apply: bool = false,
};

/// Carries project memory request data across use case and port boundaries.
pub const ProjectMemoryRequest = struct {
    content: ?[]const u8 = null,
    path: []const u8 = memory_path_default,
    query: ?[]const u8 = null,
    category: ?[]const u8 = null,
    limit: usize = 100,
    include_builtins: bool = false,
    tool_name: []const u8,
};

/// Carries tool risk data across use case and port boundaries.
pub const ToolRisk = struct {
    level: []const u8,
    mcp_read_only_hint: bool,
    writes_source: bool,
    writes_artifacts: bool,
    writes_require_apply: bool,
    preview_by_default: bool,
    mutates_lsp_state: bool,
    executes_project_code: bool,
    executes_user_command: bool,
    executes_backend: bool,
};

/// Carries capability entry data across use case and port boundaries.
pub const CapabilityEntry = struct {
    name: []const u8,
    description: []const u8,
    group: []const u8,
    group_keywords: []const []const u8,
    risk: ToolRisk,
    plan_kind: []const u8,
};

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

/// Reports whether target matches the caller-provided data.
pub fn importsTarget(contents: []const u8, target: []const u8) bool {
    const base = std.fs.path.basename(target);
    return std.mem.indexOf(u8, contents, base) != null or std.mem.indexOf(u8, contents, target) != null;
}

/// Reports whether file stem matches the caller-provided data.
pub fn referencesFileStem(contents: []const u8, target: []const u8) bool {
    const base = std.fs.path.basename(target);
    const dot = std.mem.lastIndexOfScalar(u8, base, '.') orelse base.len;
    if (dot == 0) return false;
    return std.mem.indexOf(u8, contents, base[0..dot]) != null;
}

/// Reports whether like test file matches the caller-provided data.
pub fn looksLikeTestFile(path: []const u8) bool {
    return std.mem.indexOf(u8, path, "test") != null or std.mem.endsWith(u8, path, "_test.zig");
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

/// Serializes validation risk fields into an allocator-owned JSON value; allocation failures propagate.
fn validationRiskValue(allocator: std.mem.Allocator, risk: workflows.Risk) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "changed_file_count", .{ .integer = @intCast(risk.changed_file_count) });
    try obj.put(allocator, "touches_zig_source", .{ .bool = risk.touches_zig_source });
    try obj.put(allocator, "touches_build_config", .{ .bool = risk.touches_build_config });
    try obj.put(allocator, "touches_docs", .{ .bool = risk.touches_docs });
    try obj.put(allocator, "level", try ownedString(allocator, risk.level));
    return .{ .object = obj };
}

/// Serializes validation phases fields into an allocator-owned JSON value; allocation failures propagate.
fn validationPhasesValue(allocator: std.mem.Allocator, phases: []const workflows.Phase) !std.json.Value {
    var array = std.json.Array.init(allocator);
    for (phases) |phase| try array.append(try validationPhaseValue(allocator, phase));
    return .{ .array = array };
}

/// Serializes validation phase fields into an allocator-owned JSON value; allocation failures propagate.
fn validationPhaseValue(allocator: std.mem.Allocator, phase: workflows.Phase) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "id", try ownedString(allocator, phase.id));
    try obj.put(allocator, "kind", try ownedString(allocator, phase.kind.name()));
    try obj.put(allocator, "tool", if (phase.tool) |tool| try ownedString(allocator, tool) else .null);
    try obj.put(allocator, "argv", if (phase.argv) |argv| try argvOwnedValue(allocator, argv.items) else .null);
    try obj.put(allocator, "reason", try ownedString(allocator, phase.reason));
    try obj.put(allocator, "required", .{ .bool = phase.required });
    try obj.put(allocator, "risk", try ownedString(allocator, phase.risk));
    return .{ .object = obj };
}

/// Serializes skipped phases fields into an allocator-owned JSON value; allocation failures propagate.
fn skippedPhasesValue(allocator: std.mem.Allocator, skipped: []const workflows.SkippedPhase) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
    var array = std.json.Array.init(allocator);
    for (skipped) |item| {
        var obj = std.json.ObjectMap.empty;
        try obj.put(allocator, "name", try ownedString(allocator, item.name));
        try obj.put(allocator, "reason", try ownedString(allocator, item.reason));
        try array.append(.{ .object = obj });
    }
    return .{ .array = array };
}

/// Serializes validation phase run fields into an allocator-owned JSON value; allocation failures propagate.
fn validationPhaseRunValue(allocator: std.mem.Allocator, phase: workflows.PhaseRun) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "name", try ownedString(allocator, phase.name));
    try obj.put(allocator, "ok", .{ .bool = phase.ok });
    try obj.put(allocator, "command", try phaseCommandValue(allocator, phase));
    try obj.put(allocator, "events", try phaseEventsValue(allocator, phase));
    return .{ .object = obj };
}

/// Serializes phase command fields into an allocator-owned JSON value; allocation failures propagate.
fn phaseCommandValue(allocator: std.mem.Allocator, phase: workflows.PhaseRun) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
    return switch (phase.outcome) {
        .result => |result| try commandResultValue(allocator, phase.name, phase.argv.items, phase.cwd, phase.timeout_ms, .{
            .exit_code = result.exit_code,
            .term = result.term,
            .stdout = result.stdout,
            .stderr = result.stderr,
            .duration_ms = result.duration_ms,
            .timed_out = result.timed_out,
            .stdout_truncated = result.stdout_truncated,
            .stderr_truncated = result.stderr_truncated,
        }),
        .port_error => |err| try commandErrorValue(allocator, phase.name, phase.argv.items, phase.cwd, phase.timeout_ms, err),
    };
}

/// Serializes phase events fields into an allocator-owned JSON value; allocation failures propagate.
fn phaseEventsValue(allocator: std.mem.Allocator, phase: workflows.PhaseRun) !std.json.Value {
    return switch (phase.outcome) {
        .result => |result| try buildEventsValue(allocator, "validation_phase", result.stderr, result.stdout, phase.argv.items, phase.ok, "executed_command"),
        .port_error => |err| try commandErrorEventsValue(allocator, "validation_phase", phase.argv.items, phase.cwd, phase.timeout_ms, err),
    };
}

/// Serializes history record fields into an allocator-owned JSON value; allocation failures propagate.
fn historyRecordValueFromUsecase(
    allocator: std.mem.Allocator,
    record: workflows.HistoryRecord,
    phases: []const workflows.PhaseRun,
    skipped: []const workflows.SkippedPhase,
) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
    var failures = std.json.Array.init(allocator);
    for (record.failures) |failure| {
        var obj = std.json.ObjectMap.empty;
        try obj.put(allocator, "phase", try ownedString(allocator, failure.phase));
        try obj.put(allocator, "fingerprint", try ownedString(allocator, failure.fingerprint));
        if (phaseByName(phases, failure.phase)) |phase| try obj.put(allocator, "command", try phaseCommandValue(allocator, phase));
        try failures.append(.{ .object = obj });
    }
    var slow = std.json.Array.init(allocator);
    for (record.slow_phases) |slow_phase| {
        var obj = std.json.ObjectMap.empty;
        try obj.put(allocator, "phase", try ownedString(allocator, slow_phase.phase));
        try obj.put(allocator, "duration_ms", .{ .integer = slow_phase.duration_ms });
        try slow.append(.{ .object = obj });
    }
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "schema_version", .{ .integer = workflows.schema_version });
    try obj.put(allocator, "recorded_unix_ms", .{ .integer = record.recorded_unix_ms });
    try obj.put(allocator, "ok", .{ .bool = record.ok });
    try obj.put(allocator, "plan_id", try ownedString(allocator, record.plan_id));
    try obj.put(allocator, "phase_count", .{ .integer = @intCast(record.phase_count) });
    try obj.put(allocator, "skipped_count", .{ .integer = @intCast(record.skipped_count) });
    try obj.put(allocator, "failures", .{ .array = failures });
    try obj.put(allocator, "slow_phases", .{ .array = slow });
    var phase_values = std.json.Array.init(allocator);
    for (phases) |phase| try phase_values.append(try validationPhaseRunValue(allocator, phase));
    try obj.put(allocator, "phases", .{ .array = phase_values });
    try obj.put(allocator, "skipped_phases", try skippedPhasesValue(allocator, skipped));
    return .{ .object = obj };
}

/// Serializes preimage fields into an allocator-owned JSON value; allocation failures propagate.
fn preimageValueFromUsecase(allocator: std.mem.Allocator, preimage: workflows.Preimage) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "exists", .{ .bool = preimage.exists });
    try obj.put(allocator, "bytes", .{ .integer = @intCast(preimage.bytes) });
    try obj.put(allocator, "sha256", if (preimage.sha256) |hash| try ownedString(allocator, hash) else .null);
    return .{ .object = obj };
}

/// Implements phase by name workflow logic using caller-owned inputs.
fn phaseByName(phases: []const workflows.PhaseRun, name: []const u8) ?workflows.PhaseRun {
    for (phases) |phase| {
        if (std.mem.eql(u8, phase.name, name)) return phase;
    }
    return null;
}

/// Serializes history runs array fields into an allocator-owned JSON value; allocation failures propagate.
fn historyRunsArrayValue(allocator: std.mem.Allocator, runs: []const workflows.HistoryRun) !std.json.Value {
    var array = std.json.Array.init(allocator);
    for (runs) |run_item| try array.append(try historyRunJsonValue(allocator, run_item));
    return .{ .array = array };
}

/// Serializes history run json fields into an allocator-owned JSON value; allocation failures propagate.
fn historyRunJsonValue(allocator: std.mem.Allocator, run_item: workflows.HistoryRun) !std.json.Value {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, run_item.raw_json, .{}) catch return ownedString(allocator, run_item.raw_json);
    defer parsed.deinit();
    return cloneValue(allocator, parsed.value);
}

/// Serializes failure groups fields into an allocator-owned JSON value; allocation failures propagate.
fn failureGroupsValueFromUsecase(allocator: std.mem.Allocator, groups: []const workflows.FailureGroup) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
    var array = std.json.Array.init(allocator);
    for (groups) |group| {
        var obj = std.json.ObjectMap.empty;
        try obj.put(allocator, "fingerprint", try ownedString(allocator, group.fingerprint));
        try obj.put(allocator, "count", .{ .integer = @intCast(group.count) });
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, group.sample_json, .{}) catch null;
        if (parsed) |*value| {
            defer value.deinit();
            try obj.put(allocator, "sample", try cloneValue(allocator, value.value));
        } else {
            try obj.put(allocator, "sample", try ownedString(allocator, group.sample_json));
        }
        try array.append(.{ .object = obj });
    }
    return .{ .array = array };
}

/// Serializes command result fields into an allocator-owned JSON value; allocation failures propagate.
fn commandResultValue(
    allocator: std.mem.Allocator,
    title: []const u8,
    argv: []const []const u8,
    cwd: []const u8,
    timeout_ms: i64,
    result: ports.CommandResult,
) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    const term = result.effectiveTerm();
    const ok = !term.failed() and !result.timed_out;
    try obj.put(allocator, "kind", .{ .string = "command" });
    try obj.put(allocator, "title", .{ .string = title });
    try obj.put(allocator, "ok", .{ .bool = ok });
    try obj.put(allocator, "cwd", .{ .string = cwd });
    try obj.put(allocator, "argv", try argvOwnedValue(allocator, argv));
    try obj.put(allocator, "timeout_ms", .{ .integer = timeout_ms });
    try obj.put(allocator, "duration_ms", .{ .integer = @intCast(result.duration_ms) });
    try obj.put(allocator, "term", try commandTermValue(allocator, term));
    const stdout = try safeTextAlloc(allocator, result.stdout);
    const stderr = try safeTextAlloc(allocator, result.stderr);
    try putStreamFields(allocator, &obj, "stdout", stdout);
    try putStreamFields(allocator, &obj, "stderr", stderr);
    try obj.put(allocator, "stdout_truncated", .{ .bool = result.stdout_truncated });
    try obj.put(allocator, "stderr_truncated", .{ .bool = result.stderr_truncated });
    try obj.put(allocator, "stdout_limit", .{ .integer = @intCast(workflows.command_output_limit) });
    try obj.put(allocator, "stderr_limit", .{ .integer = @intCast(workflows.command_output_limit) });
    try obj.put(allocator, "output_limit_mode", .{ .string = "truncate_on_limit" });
    try obj.put(allocator, "output_limit_exceeded", .{ .bool = result.stdout_truncated or result.stderr_truncated });
    if (result.stdout_truncated or result.stderr_truncated) {
        try obj.put(allocator, "note", .{ .string = "Command output exceeded zigars' capture limit. zigars returned the captured prefix and marked the truncated stream so the result remains inspectable." });
    }
    const insights = try project_values.compilerInsightsValue(allocator, stdout.text, stderr.text, argv);
    try obj.put(allocator, "diagnostics", insights);
    try obj.put(allocator, "failure_summary", try failureSummaryValue(allocator, insights, ok, argv));
    return .{ .object = obj };
}

/// Serializes command error fields into an allocator-owned JSON value; allocation failures propagate.
fn commandErrorValue(allocator: std.mem.Allocator, title: []const u8, argv: []const []const u8, cwd: []const u8, timeout_ms: i64, err: anyerror) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "command_error" });
    try obj.put(allocator, "title", .{ .string = title });
    try obj.put(allocator, "ok", .{ .bool = false });
    try obj.put(allocator, "cwd", .{ .string = cwd });
    try obj.put(allocator, "argv", try argvOwnedValue(allocator, argv));
    try obj.put(allocator, "timeout_ms", .{ .integer = timeout_ms });
    try obj.put(allocator, "error", .{ .string = @errorName(err) });
    try obj.put(allocator, "error_kind", .{ .string = commandErrorKind(err) });
    try obj.put(allocator, "stdout_limit", .{ .integer = @intCast(workflows.command_output_limit) });
    try obj.put(allocator, "stderr_limit", .{ .integer = @intCast(workflows.command_output_limit) });
    try obj.put(allocator, "output_limit_mode", .{ .string = "truncate_on_limit" });
    try obj.put(allocator, "output_limit_exceeded", .{ .bool = isOutputLimitError(err) });
    try obj.put(allocator, "stdout_truncated", .{ .bool = false });
    try obj.put(allocator, "stderr_truncated", .{ .bool = false });
    if (isOutputLimitError(err)) {
        try obj.put(allocator, "note", .{ .string = "Command output exceeded zigars' capture limit before zigars could retain a bounded prefix. Narrow the command or run it directly when full output is needed." });
    }
    try obj.put(allocator, "failure_summary", try commandErrorSummaryValue(allocator, err, argv));
    return .{ .object = obj };
}

/// Serializes failure summary fields into an allocator-owned JSON value; allocation failures propagate.
fn failureSummaryValue(allocator: std.mem.Allocator, insights: std.json.Value, ok: bool, argv: []const []const u8) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
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
        if (project_values.argvContains(argv, "test")) try suggested.append(try ownedString(allocator, "zig_test_failure_triage"));
        try suggested.append(try ownedString(allocator, "zigars_failure_fusion"));
        try suggested.append(try ownedString(allocator, "zigars_impact"));
    }
    try obj.put(allocator, "suggested_tools", .{ .array = suggested });
    try obj.put(allocator, "likely_scope", try likelyFailureScopeValue(allocator, primary));
    return .{ .object = obj };
}

/// Serializes command error summary fields into an allocator-owned JSON value; allocation failures propagate.
fn commandErrorSummaryValue(allocator: std.mem.Allocator, err: anyerror, argv: []const []const u8) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "ok", .{ .bool = false });
    try obj.put(allocator, "primary", .null);
    try obj.put(allocator, "error_class", .{ .string = commandErrorKind(err) });
    try obj.put(allocator, "rerun_command", .{ .string = try project_values.commandString(allocator, argv) });
    var suggested = std.json.Array.init(allocator);
    try suggested.append(try ownedString(allocator, "zigars_doctor"));
    try suggested.append(try ownedString(allocator, "zigars_context_pack"));
    try obj.put(allocator, "suggested_tools", .{ .array = suggested });
    try obj.put(allocator, "likely_scope", .{ .string = if (isTimeoutError(err)) "command_timeout" else "tool_or_backend_configuration" });
    return .{ .object = obj };
}

/// Serializes likely failure scope fields into an allocator-owned JSON value; allocation failures propagate.
fn likelyFailureScopeValue(allocator: std.mem.Allocator, primary: std.json.Value) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
    const primary_obj = switch (primary) {
        .object => |o| o,
        else => return .{ .string = "none" },
    };
    const path = stringField(primary_obj, "path") orelse return .{ .string = "workspace_or_build" };
    if (std.mem.eql(u8, path, "build.zig") or std.mem.eql(u8, path, "build.zig.zon")) return .{ .string = "build_configuration" };
    if (std.mem.endsWith(u8, path, ".zig")) return .{ .string = "source_file" };
    return .{ .string = try std.fmt.allocPrint(allocator, "path:{s}", .{path}) };
}

/// Serializes build events fields into an allocator-owned JSON value; allocation failures propagate.
fn buildEventsValue(allocator: std.mem.Allocator, tool_name: []const u8, stderr: []const u8, stdout: []const u8, argv: []const []const u8, ok: bool, basis: []const u8) !std.json.Value {
    // Construct this value in a single path so required fields cannot drift.
    var events = std.json.Array.init(allocator);
    try collectLineEvents(allocator, &events, stderr, "stderr");
    try collectLineEvents(allocator, &events, stdout, "stdout");
    const compiler = try project_values.compilerInsightsValue(allocator, stdout, stderr, argv);
    const tests = try project_values.testFailureTriageValue(allocator, stderr, stdout, argv, ok);
    var timings = try timingValue(allocator, stderr);
    const stdout_timings = try timingValue(allocator, stdout);
    try timings.array.appendSlice(stdout_timings.array.items);
    const compiler_error_count: i64 = if (compiler.object.get("error_count")) |value| switch (value) {
        .integer => |n| n,
        else => 0,
    } else 0;
    const test_failure_count: usize = if (tests.object.get("failures")) |value| switch (value) {
        .array => |failures| failures.items.len,
        else => 0,
    } else 0;
    var summary = std.json.ObjectMap.empty;
    try summary.put(allocator, "event_count", .{ .integer = @intCast(events.items.len) });
    try summary.put(allocator, "compiler_error_count", .{ .integer = compiler_error_count });
    try summary.put(allocator, "test_failure_count", .{ .integer = @intCast(test_failure_count) });
    try summary.put(allocator, "timing_count", .{ .integer = @intCast(timings.array.items.len) });

    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", try ownedString(allocator, tool_name));
    try obj.put(allocator, "schema_version", .{ .integer = schema_version });
    try obj.put(allocator, "ok", .{ .bool = ok });
    try obj.put(allocator, "argv", try argvOwnedValue(allocator, argv));
    try obj.put(allocator, "parsing_basis", try ownedString(allocator, basis));
    try obj.put(allocator, "events", .{ .array = events });
    try obj.put(allocator, "compiler", compiler);
    try obj.put(allocator, "tests", tests);
    try obj.put(allocator, "timings", timings);
    try obj.put(allocator, "summary", .{ .object = summary });
    try obj.put(allocator, "confidence", .{ .string = if (std.mem.eql(u8, basis, "executed_command")) "high" else "medium" });
    try obj.put(allocator, "limitations", .{ .string = "Event parsing is best-effort over Zig stdout/stderr; raw command output remains the audit source." });
    return .{ .object = obj };
}

/// Serializes command error events fields into an allocator-owned JSON value; allocation failures propagate.
fn commandErrorEventsValue(allocator: std.mem.Allocator, tool_name: []const u8, argv: []const []const u8, cwd: []const u8, timeout_ms: i64, err: anyerror) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", try ownedString(allocator, tool_name));
    try obj.put(allocator, "schema_version", .{ .integer = schema_version });
    try obj.put(allocator, "ok", .{ .bool = false });
    try obj.put(allocator, "command", try commandErrorValue(allocator, tool_name, argv, cwd, timeout_ms, err));
    try obj.put(allocator, "events", .{ .array = std.json.Array.init(allocator) });
    try obj.put(allocator, "error_kind", .{ .string = commandErrorKind(err) });
    try obj.put(allocator, "resolution", .{ .string = "Confirm the configured Zig executable and workspace command can run, or pass captured output as text." });
    return .{ .object = obj };
}

/// Collects line events data into caller-provided output storage without taking ownership of inputs.
fn collectLineEvents(allocator: std.mem.Allocator, events: *std.json.Array, text_value: []const u8, stream: []const u8) !void {
    // Keep this logic centralized so callers observe one consistent behavior path.
    var lines = std.mem.splitScalar(u8, text_value, '\n');
    var line_no: usize = 1;
    while (lines.next()) |raw| : (line_no += 1) {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        const event_type = classifyEventLine(line);
        if (std.mem.eql(u8, event_type, "output")) continue;
        var obj = std.json.ObjectMap.empty;
        try obj.put(allocator, "line", .{ .integer = @intCast(line_no) });
        try obj.put(allocator, "stream", try ownedString(allocator, stream));
        try obj.put(allocator, "event", try ownedString(allocator, event_type));
        try obj.put(allocator, "message", try ownedString(allocator, line));
        try events.append(.{ .object = obj });
    }
}

/// Classifies a command output line for validation event summaries.
fn classifyEventLine(line: []const u8) []const u8 {
    if (std.mem.indexOf(u8, line, ": error: ") != null or std.mem.startsWith(u8, line, "error: ")) return "compiler_error";
    if (std.mem.indexOf(u8, line, ": warning: ") != null or std.mem.startsWith(u8, line, "warning: ")) return "compiler_warning";
    if (std.mem.indexOf(u8, line, "FAIL") != null or std.mem.indexOf(u8, line, "failed") != null) return "test_failure";
    if (std.mem.indexOf(u8, line, "PASS") != null or std.mem.indexOf(u8, line, "passed") != null) return "test_pass";
    if (std.mem.indexOf(u8, line, "Step ") != null) return "build_step";
    return "output";
}

/// Serializes timing fields into an allocator-owned JSON value; allocation failures propagate.
fn timingValue(allocator: std.mem.Allocator, text: []const u8) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
    var timings = std.json.Array.init(allocator);
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        if (parseDurationMs(line)) |ms| {
            var obj = std.json.ObjectMap.empty;
            try obj.put(allocator, "name", try ownedString(allocator, line));
            try obj.put(allocator, "duration_ms", .{ .integer = ms });
            try obj.put(allocator, "source", .{ .string = "text" });
            try timings.append(.{ .object = obj });
        }
    }
    return .{ .array = timings };
}

/// Parses duration ms input using caller-provided storage; malformed input and allocation failures propagate.
fn parseDurationMs(line: []const u8) ?i64 {
    if (std.mem.indexOf(u8, line, "ms")) |ms_pos| {
        var start = ms_pos;
        while (start > 0 and std.ascii.isDigit(line[start - 1])) start -= 1;
        if (start < ms_pos) return std.fmt.parseInt(i64, line[start..ms_pos], 10) catch null;
    }
    return null;
}

/// Constructs explain argv data from caller-owned inputs, propagating allocation failures.
fn buildExplainArgv(allocator: std.mem.Allocator, context: app_context.ProjectIntelligenceContext, request: FailureFusionRequest) !ArgvList {
    return buildZigArgv(allocator, context, request.command orelse if (request.file == null) "build-test" else "check", request.file, request.filter, request.extra_args);
}

/// Constructs event argv data from caller-owned inputs, propagating allocation failures.
fn buildEventArgv(allocator: std.mem.Allocator, context: app_context.ProjectIntelligenceContext, request: CommandEventsRequest) !ArgvList {
    const command_name = request.command orelse switch (request.kind) {
        .build => "build-test",
        .test_cmd => "test",
    };
    return buildZigArgv(allocator, context, command_name, request.file, request.filter, request.extra_args);
}

/// Carries argv list data across use case and port boundaries.
const ArgvList = struct {
    items: []const []const u8,

    /// Releases allocations owned by this value; callers must not use owned slices after this returns.
    fn deinit(self: *ArgvList, allocator: std.mem.Allocator) void {
        freeStringList(allocator, self.items);
        allocator.free(self.items);
        self.* = undefined;
    }
};

/// Constructs zig argv data from caller-owned inputs, propagating allocation failures.
fn buildZigArgv(
    allocator: std.mem.Allocator,
    context: app_context.ProjectIntelligenceContext,
    command_name: []const u8,
    file: ?[]const u8,
    filter: ?[]const u8,
    extra_args: []const []const u8,
) !ArgvList {
    var list = std.ArrayList([]const u8).empty;
    errdefer {
        freeStringList(allocator, list.items);
        list.deinit(allocator);
    }
    try appendOwnedArg(allocator, &list, context.tool_paths.zig);
    if (std.mem.eql(u8, command_name, "build")) {
        try appendOwnedArg(allocator, &list, "build");
    } else if (std.mem.eql(u8, command_name, "build-test")) {
        try appendOwnedArg(allocator, &list, "build");
        try appendOwnedArg(allocator, &list, "test");
    } else if (std.mem.eql(u8, command_name, "check")) {
        try appendOwnedArg(allocator, &list, "ast-check");
        const file_value = file orelse return error.MissingFile;
        const resolved = try context.workspace_store.resolve(allocator, .{
            .path = file_value,
            .provenance = "project_intelligence.command_arg",
        });
        defer resolved.deinit(allocator);
        try appendOwnedArg(allocator, &list, resolved.path);
    } else if (std.mem.eql(u8, command_name, "fmt-check")) {
        try appendOwnedArg(allocator, &list, "fmt");
        try appendOwnedArg(allocator, &list, "--check");
        // Resolve a caller-supplied path through the workspace sandbox before it
        // reaches the `zig fmt --check` argv, matching the `check`/`test`
        // branches. Without this, a raw `../../etc/hosts` would escape the
        // workspace boundary the tool advertises. The `src` default is preserved
        // when no path is supplied.
        if (file) |file_value| {
            const resolved = try context.workspace_store.resolve(allocator, .{
                .path = file_value,
                .provenance = "project_intelligence.command_arg",
            });
            defer resolved.deinit(allocator);
            try appendOwnedArg(allocator, &list, resolved.path);
        } else try appendOwnedArg(allocator, &list, "src");
    } else if (std.mem.eql(u8, command_name, "test")) {
        try appendOwnedArg(allocator, &list, "test");
        const file_value = file orelse return error.MissingFile;
        const resolved = try context.workspace_store.resolve(allocator, .{
            .path = file_value,
            .provenance = "project_intelligence.command_arg",
        });
        defer resolved.deinit(allocator);
        try appendOwnedArg(allocator, &list, resolved.path);
        if (filter) |filter_value| {
            try appendOwnedArg(allocator, &list, "--test-filter");
            try appendOwnedArg(allocator, &list, filter_value);
        }
    } else return error.InvalidCommand;
    try appendExtraArgs(allocator, &list, command_name, extra_args);
    return .{ .items = try list.toOwnedSlice(allocator) };
}

/// Path-bearing `zig build`-system flags that would redirect compilation,
/// caching, emitted output, package/library resolution, or the build runner
/// itself outside the workspace sandbox (the last enabling arbitrary code
/// execution).
///
/// There is no shell on this surface, so user tokens cannot inject commands —
/// but they can inject *flags* to the fixed `zig` binary. These flags take a
/// filesystem operand (as `--flag value`, `--flag=value`, or, for `-femit-*`,
/// `-femit-bin=path`) that escapes the write/exec boundary the rest of the
/// server enforces, so they are denied in the passthrough.
const denied_build_flag_prefixes = [_][]const u8{
    "--build-file",
    "--prefix",
    "--cache-dir",
    "--global-cache-dir",
    "--zig-lib-dir",
    "-femit-",
    // `--prefix-lib-dir` / `--prefix-exe-dir` / `--prefix-include-dir` also
    // redirect install output; they share the `--prefix` stem above only as a
    // separate token, so list them explicitly.
    "--prefix-lib-dir",
    "--prefix-exe-dir",
    "--prefix-include-dir",
    // `-p` is the documented short alias of `--prefix` (`zig build -h`:
    // "-p, --prefix [path]"), so it redirects install output just like
    // `--prefix`. Zig only accepts its operand space-separated (`-p <path>`);
    // the glued `-p<path>` and `-p=<path>` forms are rejected by the build
    // runner as unrecognized, so the exact-token / `=` matching below is exactly
    // the live surface.
    "-p",
    // `--build-runner [file]` overrides the build runner with an arbitrary Zig
    // file, executing attacker-chosen code outside the workspace — strictly
    // worse than the already-denied `--build-file`.
    "--build-runner",
    // System-integration flags that take a path operand (`zig build -h`,
    // "System Integration Options"). Each points compilation, linking, libc, or
    // package resolution at a directory or file outside the workspace, so they
    // can both read host paths and pull in foreign build/link inputs.
    "--search-prefix",
    "--sysroot",
    "--libc",
    "--libc-runtimes",
    "--system",
};

/// Returns true when `arg` is (or begins, for `--flag=value`/`-femit-*` forms) a
/// denied path-bearing build-system flag.
fn isDeniedBuildFlag(arg: []const u8) bool {
    for (denied_build_flag_prefixes) |flag| {
        if (std.mem.eql(u8, arg, flag)) return true;
        // `--cache-dir=foo` and `-femit-bin=foo` carry the operand inline.
        if (std.mem.startsWith(u8, arg, flag) and arg.len > flag.len) {
            const next = arg[flag.len];
            if (next == '=' or std.mem.startsWith(u8, flag, "-femit-")) return true;
        }
    }
    return false;
}

/// Appends caller-supplied passthrough tokens to the assembled argv with a
/// sandbox guard appropriate to the subcommand.
///
/// - `zig test`: a `--` end-of-options separator is inserted first, so every
///   following token is handed to the compiled test binary rather than
///   interpreted as a compiler flag. `zig test --` does not carry run-step
///   semantics, so this is both safe and sufficient.
/// - `zig build` / `zig build test` and the `zig ast-check` / `zig fmt`
///   helpers: `--` is *not* added (for `zig build` it would mean "arguments to
///   the run step"). Instead path-bearing build-system flags that escape the
///   workspace are rejected outright, failing closed.
fn appendExtraArgs(
    allocator: std.mem.Allocator,
    list: *std.ArrayList([]const u8),
    command_name: []const u8,
    extra_args: []const []const u8,
) !void {
    // Append in deterministic order so completion and snapshot output remain stable.
    if (extra_args.len == 0) return;
    if (std.mem.eql(u8, command_name, "test")) {
        try appendOwnedArg(allocator, list, "--");
        for (extra_args) |arg| try appendOwnedArg(allocator, list, arg);
        return;
    }
    for (extra_args) |arg| {
        if (isDeniedBuildFlag(arg)) return error.UnsafeBuildFlag;
        try appendOwnedArg(allocator, list, arg);
    }
}

/// Appends owned arg data into caller-provided storage, propagating allocation failures.
fn appendOwnedArg(allocator: std.mem.Allocator, list: *std.ArrayList([]const u8), value: []const u8) !void {
    try list.append(allocator, try allocator.dupe(u8, value));
}

/// Appends validation phase data into caller-provided storage, propagating allocation failures.
fn appendValidationPhase(
    allocator: std.mem.Allocator,
    context: app_context.ProjectIntelligenceContext,
    phases: *std.json.Array,
    name: []const u8,
    argv: []const []const u8,
    timeout_ms: i64,
) !bool {
    // Append in deterministic order so completion and snapshot output remain stable.
    var result = context.command_runner.run(allocator, .{
        .argv = argv,
        .cwd = context.workspace.root,
        .timeout_ms = @intCast(@max(1, timeout_ms)),
        .max_stdout_bytes = workflows.command_output_limit,
        .max_stderr_bytes = workflows.command_output_limit,
        .provenance = "zigars_validate_patch phase",
    }) catch |err| {
        var phase = std.json.ObjectMap.empty;
        try phase.put(allocator, "name", .{ .string = name });
        try phase.put(allocator, "ok", .{ .bool = false });
        try phase.put(allocator, "command", try commandErrorValue(allocator, name, argv, context.workspace.root, timeout_ms, err));
        try phases.append(.{ .object = phase });
        return false;
    };
    defer result.deinit(allocator);
    const term = result.effectiveTerm();
    const ok = !term.failed() and !result.timed_out;
    var phase = std.json.ObjectMap.empty;
    try phase.put(allocator, "name", .{ .string = name });
    try phase.put(allocator, "ok", .{ .bool = ok });
    try phase.put(allocator, "command", try commandResultValue(allocator, name, argv, context.workspace.root, timeout_ms, result));
    try phases.append(.{ .object = phase });
    return ok;
}

/// Appends workspace format check phase data into caller-provided storage, propagating allocation failures.
fn appendWorkspaceFormatCheckPhase(
    allocator: std.mem.Allocator,
    context: app_context.ProjectIntelligenceContext,
    phases: *std.json.Array,
    timeout_ms: i64,
    ok: *bool,
    stop_on_failure: bool,
) !void {
    // Append in deterministic order so completion and snapshot output remain stable.
    const candidates = [_][]const u8{ "build.zig", "build.zig.zon", "src" };
    var argv_list: std.ArrayList([]const u8) = .empty;
    defer argv_list.deinit(allocator);
    try argv_list.append(allocator, context.tool_paths.zig);
    try argv_list.append(allocator, "fmt");
    try argv_list.append(allocator, "--check");
    var appended = false;
    for (candidates) |candidate| {
        if (!workspacePathExists(allocator, context, candidate)) continue;
        try argv_list.append(allocator, candidate);
        appended = true;
    }
    if (!appended) return;
    const fmt_ok = try appendValidationPhase(allocator, context, phases, "workspace_format_check", argv_list.items, timeout_ms);
    if (!fmt_ok) {
        ok.* = false;
        if (stop_on_failure) return;
    }
}

/// Appends workspace format check command data into caller-provided storage, propagating allocation failures.
fn appendWorkspaceFormatCheckCommand(allocator: std.mem.Allocator, context: app_context.ProjectIntelligenceContext, commands: *std.json.Array) !void {
    // Append in deterministic order so completion and snapshot output remain stable.
    const candidates = [_][]const u8{ "build.zig", "build.zig.zon", "src" };
    var command_text: std.ArrayList(u8) = .empty;
    defer command_text.deinit(allocator);
    try command_text.appendSlice(allocator, "zig fmt --check");
    var appended_path = false;
    for (candidates) |candidate| {
        if (!workspacePathExists(allocator, context, candidate)) continue;
        try command_text.print(allocator, " {s}", .{candidate});
        appended_path = true;
    }
    if (appended_path) try appendUniqueCommand(allocator, commands, command_text.items);
}

/// Serializes skipped phase fields into an allocator-owned JSON value; allocation failures propagate.
fn skippedPhaseValue(allocator: std.mem.Allocator, name: []const u8, reason: []const u8) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "name", .{ .string = name });
    try obj.put(allocator, "reason", .{ .string = reason });
    return .{ .object = obj };
}

/// Serializes skipped step fields into an allocator-owned JSON value; allocation failures propagate.
fn skippedStepValue(allocator: std.mem.Allocator, name: []const u8, reason: []const u8) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "name", try ownedString(allocator, name));
    try obj.put(allocator, "reason", try ownedString(allocator, reason));
    return .{ .object = obj };
}

/// Appends unique file object data into caller-provided storage, propagating allocation failures.
fn appendUniqueFileObject(allocator: std.mem.Allocator, out: *std.json.Array, file: []const u8, reason: []const u8, confidence: []const u8) !void {
    // Append in deterministic order so completion and snapshot output remain stable.
    for (out.items) |item| {
        const obj = switch (item) {
            .object => |o| o,
            else => continue,
        };
        if (std.mem.eql(u8, stringField(obj, "file") orelse "", file)) return;
    }
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "file", try ownedString(allocator, file));
    try obj.put(allocator, "reason", try ownedString(allocator, reason));
    try obj.put(allocator, "confidence", .{ .string = confidence });
    try out.append(.{ .object = obj });
}

/// Collects importers for file data into caller-provided output storage without taking ownership of inputs.
fn collectImportersForFile(allocator: std.mem.Allocator, imports_value: std.json.Value, out: *std.json.Array, target: []const u8) !void {
    // Keep this logic centralized so callers observe one consistent behavior path.
    const imports = switch (imports_value) {
        .array => |a| a,
        else => return,
    };
    for (imports.items) |item| {
        const obj = switch (item) {
            .object => |o| o,
            else => continue,
        };
        const imported = stringField(obj, "import") orelse "";
        if (!importMatchesTarget(imported, target)) continue;
        const file = stringField(obj, "file") orelse continue;
        try appendImpactMatch(allocator, out, file, target, "imports_changed_file", "parser", "high");
    }
}

/// Collects tests for file data into caller-provided output storage without taking ownership of inputs.
fn collectTestsForFile(allocator: std.mem.Allocator, tests_value: std.json.Value, out: *std.json.Array, target: []const u8) !void {
    // Keep this logic centralized so callers observe one consistent behavior path.
    const tests = switch (tests_value) {
        .array => |a| a,
        else => return,
    };
    for (tests.items) |item| {
        const obj = switch (item) {
            .object => |o| o,
            else => continue,
        };
        const file = stringField(obj, "file") orelse continue;
        if (std.mem.eql(u8, file, target) or referencesFileStem(stringField(obj, "name") orelse "", target)) {
            try appendImpactMatch(allocator, out, file, target, "test_matches_changed_file", "parser", "high");
        }
    }
}

/// Collects public api for file data into caller-provided output storage without taking ownership of inputs.
fn collectPublicApiForFile(allocator: std.mem.Allocator, decls_value: std.json.Value, out: *std.json.Array, target: []const u8) !void {
    // Keep this logic centralized so callers observe one consistent behavior path.
    const decls = switch (decls_value) {
        .array => |a| a,
        else => return,
    };
    for (decls.items) |item| {
        const obj = switch (item) {
            .object => |o| o,
            else => continue,
        };
        if (!std.mem.eql(u8, stringField(obj, "file") orelse "", target)) continue;
        if (!(boolField(obj, "public") orelse false)) continue;
        try out.append(try cloneValue(allocator, item));
    }
}

/// Collects declarations for symbol data into caller-provided output storage without taking ownership of inputs.
fn collectDeclarationsForSymbol(allocator: std.mem.Allocator, decls_value: std.json.Value, out: *std.json.Array, symbol: []const u8) !void {
    // Keep this logic centralized so callers observe one consistent behavior path.
    const decls = switch (decls_value) {
        .array => |a| a,
        else => return,
    };
    for (decls.items) |item| {
        const obj = switch (item) {
            .object => |o| o,
            else => continue,
        };
        const name = stringField(obj, "name") orelse "";
        const signature = stringField(obj, "signature") orelse "";
        if (std.mem.indexOf(u8, name, symbol) == null and std.mem.indexOf(u8, signature, symbol) == null) continue;
        try out.append(try cloneValue(allocator, item));
    }
}

/// Collects tests for symbol data into caller-provided output storage without taking ownership of inputs.
fn collectTestsForSymbol(allocator: std.mem.Allocator, tests_value: std.json.Value, out: *std.json.Array, symbol: []const u8) !void {
    // Keep this logic centralized so callers observe one consistent behavior path.
    const tests = switch (tests_value) {
        .array => |a| a,
        else => return,
    };
    for (tests.items) |item| {
        const obj = switch (item) {
            .object => |o| o,
            else => continue,
        };
        const name = stringField(obj, "name") orelse "";
        const file = stringField(obj, "file") orelse "";
        if (std.mem.indexOf(u8, name, symbol) == null and std.mem.indexOf(u8, file, symbol) == null) continue;
        try appendImpactMatch(allocator, out, file, symbol, "test_matches_symbol", "parser", "high");
    }
}

/// Appends impact match data into caller-provided storage, propagating allocation failures.
fn appendImpactMatch(allocator: std.mem.Allocator, out: *std.json.Array, file: []const u8, target: []const u8, reason: []const u8, source: []const u8, confidence: []const u8) !void {
    // Append in deterministic order so completion and snapshot output remain stable.
    for (out.items) |item| {
        const obj = switch (item) {
            .object => |o| o,
            else => continue,
        };
        if (std.mem.eql(u8, stringField(obj, "file") orelse "", file) and std.mem.eql(u8, stringField(obj, "target") orelse "", target) and std.mem.eql(u8, stringField(obj, "reason") orelse "", reason)) return;
    }
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "file", try ownedString(allocator, file));
    try obj.put(allocator, "target", try ownedString(allocator, target));
    try obj.put(allocator, "reason", try ownedString(allocator, reason));
    try obj.put(allocator, "source", .{ .string = source });
    try obj.put(allocator, "confidence", .{ .string = confidence });
    try out.append(.{ .object = obj });
}

/// Appends commands from matches data into caller-provided storage, propagating allocation failures.
fn appendCommandsFromMatches(allocator: std.mem.Allocator, commands: *std.json.Array, matches: std.json.Array) !void {
    // Append in deterministic order so completion and snapshot output remain stable.
    for (matches.items) |item| {
        const obj = switch (item) {
            .object => |o| o,
            else => continue,
        };
        const file = stringField(obj, "file") orelse continue;
        if (std.mem.endsWith(u8, file, ".zig")) try appendUniqueCommand(allocator, commands, try std.fmt.allocPrint(allocator, "zig test {s}", .{file}));
    }
}

/// Appends commands for impact data into caller-provided storage, propagating allocation failures.
fn appendCommandsForImpact(allocator: std.mem.Allocator, commands: *std.json.Array, reasons: *std.json.Array, value: std.json.Value, reason: []const u8) !void {
    // Append in deterministic order so completion and snapshot output remain stable.
    const array = switch (value) {
        .array => |a| a,
        else => return,
    };
    for (array.items) |item| {
        const obj = switch (item) {
            .object => |o| o,
            else => continue,
        };
        const file = stringField(obj, "file") orelse continue;
        if (!std.mem.endsWith(u8, file, ".zig")) continue;
        try appendUniqueCommand(allocator, commands, try std.fmt.allocPrint(allocator, "zig test {s}", .{file}));
        try reasons.append(try ownedString(allocator, try std.fmt.allocPrint(allocator, "{s}: {s}", .{ file, reason })));
    }
}

/// Reports whether an `@import` path likely refers to the target file: exact
/// match, basename match, or basename-substring. Heuristic, so it can over-match
/// (e.g. similarly named files); callers treat hits as advisory.
fn importMatchesTarget(imported: []const u8, target: []const u8) bool {
    const base = std.fs.path.basename(target);
    return std.mem.eql(u8, imported, target) or
        std.mem.eql(u8, imported, base) or
        std.mem.indexOf(u8, imported, base) != null;
}

/// Serializes profile state fields into an allocator-owned JSON value; allocation failures propagate.
fn profileStateValue(allocator: std.mem.Allocator, context: app_context.ProjectIntelligenceContext) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "profile_v2_path", .{ .string = ".zigars/profile.v2.json" });
    if (context.workspace_store.read(allocator, .{ .path = ".zigars/profile.v2.json", .max_bytes = 1024 * 1024, .provenance = "project_intelligence.profile_state" }) catch null) |read_result| {
        defer read_result.deinit(allocator);
        try obj.put(allocator, "profile_v2_present", .{ .bool = true });
        try obj.put(allocator, "sha256", .{ .string = try sha256Hex(allocator, read_result.bytes) });
    } else {
        try obj.put(allocator, "profile_v2_present", .{ .bool = false });
        try obj.put(allocator, "sha256", .null);
    }
    return .{ .object = obj };
}

/// Serializes decision record data fields into an allocator-owned JSON value; allocation failures propagate.
fn decisionRecordDataValue(
    allocator: std.mem.Allocator,
    context: app_context.ProjectIntelligenceContext,
    title: []const u8,
    decision: []const u8,
    rationale: ?[]const u8,
    category: []const u8,
) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
    const instant = try context.clock_and_ids.now();
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "schema_version", .{ .integer = schema_version });
    try obj.put(allocator, "id", try ownedString(allocator, try std.fmt.allocPrint(allocator, "decision-{d}", .{instant.unix_ms})));
    try obj.put(allocator, "category", try ownedString(allocator, category));
    try obj.put(allocator, "title", try ownedString(allocator, title));
    try obj.put(allocator, "decision", try ownedString(allocator, decision));
    try obj.put(allocator, "rationale", if (rationale) |value| try ownedString(allocator, value) else .null);
    try obj.put(allocator, "source", .{ .string = "zigars_decision_record" });
    return .{ .object = obj };
}

/// Builds preimage identity metadata for the requested workspace path.
fn preimageIdentityForPath(allocator: std.mem.Allocator, context: app_context.ProjectIntelligenceContext, path: []const u8) !std.json.Value {
    // Normalize and constrain path handling here before any downstream filesystem action.
    const read_result = context.workspace_store.read(allocator, .{
        .path = path,
        .max_bytes = 8 * 1024 * 1024,
        .provenance = "project_intelligence.preimage",
    }) catch return preimageValue(allocator, false, 0, "");
    defer read_result.deinit(allocator);
    const hash = try sha256Hex(allocator, read_result.bytes);
    return preimageValue(allocator, true, read_result.bytes.len, hash);
}

/// Serializes preimage fields into an allocator-owned JSON value; allocation failures propagate.
fn preimageValue(allocator: std.mem.Allocator, exists: bool, bytes: usize, sha256: []const u8) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "exists", .{ .bool = exists });
    try obj.put(allocator, "bytes", .{ .integer = @intCast(bytes) });
    try obj.put(allocator, "sha256", if (sha256.len > 0) try ownedString(allocator, sha256) else .null);
    return .{ .object = obj };
}

/// Parses json value or string input using caller-provided storage; malformed input and allocation failures propagate.
fn parseJsonValueOrString(allocator: std.mem.Allocator, text: []const u8) !std.json.Value {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, text, .{}) catch return ownedString(allocator, text);
    defer parsed.deinit();
    return cloneValue(allocator, parsed.value);
}

/// Reads json lines data from the provided context without taking ownership of inputs.
fn loadJsonLines(allocator: std.mem.Allocator, context: app_context.ProjectIntelligenceContext, content: ?[]const u8, path: []const u8, limit: usize) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
    if (content) |text| return .{ .array = try parseJsonLinesOrArray(allocator, text, limit) };
    const read_result = context.workspace_store.read(allocator, .{
        .path = path,
        .max_bytes = 4 * 1024 * 1024,
        .provenance = "project_intelligence.project_memory",
    }) catch |err| switch (err) {
        error.FileNotFound, error.NotFound => return .{ .array = std.json.Array.init(allocator) },
        else => return err,
    };
    defer read_result.deinit(allocator);
    return .{ .array = try parseJsonLinesOrArray(allocator, read_result.bytes, limit) };
}

/// Parses json lines or array input using caller-provided storage; malformed input and allocation failures propagate.
fn parseJsonLinesOrArray(allocator: std.mem.Allocator, text: []const u8, limit: usize) !std.json.Array {
    // Normalize input here so downstream paths can rely on validated shape.
    var out = std.json.Array.init(allocator);
    if (std.mem.trim(u8, text, " \t\r\n").len == 0) return out;
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed[0] == '[') {
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, text, .{});
        defer parsed.deinit();
        const array = switch (parsed.value) {
            .array => |a| a,
            else => return out,
        };
        for (array.items) |item| {
            if (out.items.len >= limit) break;
            try out.append(try cloneValue(allocator, item));
        }
        return out;
    }
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        if (out.items.len >= limit) break;
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
        defer parsed.deinit();
        try out.append(try cloneValue(allocator, parsed.value));
    }
    return out;
}

/// Filters project-memory records by optional category (exact) and query
/// (case-insensitive substring over title/decision/rationale/category), capped
/// at `limit`. Returns an allocator-owned JSON array of cloned matches.
fn filterRecords(allocator: std.mem.Allocator, records: std.json.Value, query: ?[]const u8, category: ?[]const u8, limit: usize) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
    const array = switch (records) {
        .array => |a| a,
        else => return .{ .array = std.json.Array.init(allocator) },
    };
    const lower_query = if (query) |q| try std.ascii.allocLowerString(allocator, q) else "";
    var out = std.json.Array.init(allocator);
    for (array.items) |item| {
        if (out.items.len >= limit) break;
        const obj = switch (item) {
            .object => |o| o,
            else => continue,
        };
        if (category) |cat| if (!std.mem.eql(u8, stringField(obj, "category") orelse "", cat)) continue;
        if (query != null) {
            const hay = try std.ascii.allocLowerString(allocator, try searchableRecordText(allocator, obj));
            if (std.mem.indexOf(u8, hay, lower_query) == null) continue;
        }
        try out.append(try cloneValue(allocator, item));
    }
    return .{ .array = out };
}

/// Concatenates a record's title/decision/rationale/category into one
/// allocator-owned haystack string for substring query matching.
fn searchableRecordText(allocator: std.mem.Allocator, obj: std.json.ObjectMap) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s} {s} {s} {s}", .{
        stringField(obj, "title") orelse "",
        stringField(obj, "decision") orelse "",
        stringField(obj, "rationale") orelse "",
        stringField(obj, "category") orelse "",
    });
}

/// Serializes built in project policies fields into an allocator-owned JSON value; allocation failures propagate.
fn builtInProjectPoliciesValue(allocator: std.mem.Allocator) !std.json.Value {
    var array = std.json.Array.init(allocator);
    try array.append(try policyValue(allocator, "generated_paths", "Do not edit generated/cache outputs directly; change source or regeneration steps.", &.{ ".zig-cache", ".zigars-cache", "zig-out", "coverage" }));
    try array.append(try policyValue(allocator, "validation", "Treat skipped phases as unknown, not passed.", &.{ "zigars_validation_plan", "zigars_validation_run" }));
    try array.append(try policyValue(allocator, "writes", "Source and project-memory writes require explicit apply=true.", &.{"zigars_decision_record"}));
    return .{ .array = array };
}

/// Serializes policy fields into an allocator-owned JSON value; allocation failures propagate.
fn policyValue(allocator: std.mem.Allocator, name: []const u8, policy: []const u8, values: []const []const u8) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "name", try ownedString(allocator, name));
    try obj.put(allocator, "policy", try ownedString(allocator, policy));
    try obj.put(allocator, "values", try stringArrayValue(allocator, values));
    return .{ .object = obj };
}

/// Scores a capability match against the requested task text.
fn matchScore(allocator: std.mem.Allocator, lower_goal: []const u8, entry: CapabilityEntry) !i64 {
    // Keep this logic centralized so callers observe one consistent behavior path.
    var score: i64 = 0;
    const lower_name = try std.ascii.allocLowerString(allocator, entry.name);
    if (std.mem.indexOf(u8, lower_goal, lower_name) != null) score += 10;
    const lower_desc = try std.ascii.allocLowerString(allocator, entry.description);
    var tokens = std.mem.tokenizeAny(u8, lower_goal, " \t\r\n,.;:/_-");
    while (tokens.next()) |token| {
        if (token.len < 3) continue;
        if (std.mem.indexOf(u8, lower_name, token) != null) score += 3;
        if (std.mem.indexOf(u8, lower_desc, token) != null) score += 1;
    }
    for (entry.group_keywords) |keyword| {
        const lower_keyword = try std.ascii.allocLowerString(allocator, keyword);
        if (std.mem.indexOf(u8, lower_goal, lower_keyword) != null) score += 2;
    }
    return score;
}

/// Appends capability match data into caller-provided storage, propagating allocation failures.
fn appendCapabilityMatch(allocator: std.mem.Allocator, matches: *std.json.Array, entry: CapabilityEntry, score: i64) !void {
    // Append in deterministic order so completion and snapshot output remain stable.
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "tool", try ownedString(allocator, entry.name));
    try obj.put(allocator, "score", .{ .integer = score });
    try obj.put(allocator, "confidence", .{ .string = if (score >= 8) "high" else if (score >= 3) "medium" else "low" });
    try obj.put(allocator, "group", .{ .string = entry.group });
    try obj.put(allocator, "risk", try riskValue(allocator, entry.risk));
    try obj.put(allocator, "plan_kind", .{ .string = entry.plan_kind });
    try obj.put(allocator, "description", try ownedString(allocator, entry.description));
    try matches.append(.{ .object = obj });
}

/// Serializes risk fields into an allocator-owned JSON value; allocation failures propagate.
fn riskValue(allocator: std.mem.Allocator, risk: ToolRisk) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "level", .{ .string = risk.level });
    try obj.put(allocator, "mcp_read_only_hint", .{ .bool = risk.mcp_read_only_hint });
    try obj.put(allocator, "writes_source", .{ .bool = risk.writes_source });
    try obj.put(allocator, "writes_artifacts", .{ .bool = risk.writes_artifacts });
    try obj.put(allocator, "writes_require_apply", .{ .bool = risk.writes_require_apply });
    try obj.put(allocator, "preview_by_default", .{ .bool = risk.preview_by_default });
    try obj.put(allocator, "mutates_lsp_state", .{ .bool = risk.mutates_lsp_state });
    try obj.put(allocator, "executes_project_code", .{ .bool = risk.executes_project_code });
    try obj.put(allocator, "executes_user_command", .{ .bool = risk.executes_user_command });
    try obj.put(allocator, "executes_backend", .{ .bool = risk.executes_backend });
    return .{ .object = obj };
}

/// Sorts matches data into deterministic result order.
fn sortMatches(matches: *std.json.Array) void {
    std.mem.sort(std.json.Value, matches.items, {}, struct {
        /// Orders matches by score for deterministic result sorting.
        fn lessThan(_: void, lhs: std.json.Value, rhs: std.json.Value) bool {
            const left = switch (lhs) {
                .object => |o| integerField(o, "score") orelse 0,
                else => 0,
            };
            const right = switch (rhs) {
                .object => |o| integerField(o, "score") orelse 0,
                else => 0,
            };
            return left > right;
        }
    }.lessThan);
}

/// Serializes sequence step fields into an allocator-owned JSON value; allocation failures propagate.
fn sequenceStepValue(allocator: std.mem.Allocator, tool: []const u8, reason: []const u8, executes: bool) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "tool", try ownedString(allocator, tool));
    try obj.put(allocator, "reason", try ownedString(allocator, reason));
    try obj.put(allocator, "executes_project_code", .{ .bool = executes });
    return .{ .object = obj };
}

/// Writes the shared semantic-impact evidence envelope (analysis_kind, parser-
/// backed confidence, coverage, limitations, verify_with, cross-checks) onto a
/// result, branching on whether the tool is impact or test-selection. Keeps
/// these results honest: parser-backed yet advisory, never a skip-tests proof.
fn putSemanticMetadata(allocator: std.mem.Allocator, obj: *std.json.ObjectMap, tool_name: []const u8) !void {
    // Keep this logic centralized so callers observe one consistent behavior path.
    const select = std.mem.eql(u8, tool_name, "zig_test_select_semantic");
    const analysis_kind = if (select) "parser_backed_semantic_test_selection" else "parser_backed_semantic_impact";
    try obj.put(allocator, "analysis_kind", .{ .string = analysis_kind });
    try obj.put(allocator, "capability_tier", .{ .string = "parser_backed" });
    try obj.put(allocator, "confidence", .{ .string = "high" });
    try obj.put(allocator, "confidence_class", .{ .string = "advisory" });
    try obj.put(allocator, "source_coverage", .{ .string = semantic_impact_coverage });
    try obj.put(allocator, "limitations", try stringArrayValue(allocator, semantic_impact_limits));
    try obj.put(allocator, "verify_with", try stringArrayValue(allocator, if (select) semantic_select_verify_with else semantic_impact_verify_with));
    try obj.put(allocator, "evidence_basis", try semanticEvidenceBasisValue(allocator, analysis_kind));
    try obj.put(allocator, "cross_check", try semanticCrossCheckValue(allocator, if (select) semantic_select_verify_with else semantic_impact_verify_with));
    try obj.put(allocator, "recommended_cross_check", .{ .string = if (select) semantic_select_verify_with[0] else semantic_impact_verify_with[0] });
}

const semantic_impact_coverage = "Readable workspace Zig files up to the requested limit; changed files, diff paths, symbols, imports, declarations, and tests are matched against the std.zig.Ast parser-backed semantic index; parse_status, partial_result, and parse_error_count are preserved with heuristic fallbacks called out explicitly.";
const semantic_impact_limits = &.{
    "Advisory impact and test-selection evidence; it does not prove that unselected tests can be skipped.",
    "Parse errors are reported through parser metadata when available and can make file-level impact evidence partial.",
    "Import matching uses parser-backed import declarations plus path/basename matching and can miss generated, aliased, or comptime-selected dependencies.",
    "Release decisions still require compiler-backed validation such as zig build test or project CI.",
};
const semantic_impact_verify_with = &.{ "zig ast-check on impacted files", "zig_test_select_semantic", "zigars_validation_plan", "zig build test" };
const semantic_select_verify_with = &.{ "zig ast-check on selected test files", "zigars_validation_run", "zig build test", "project CI" };

/// Serializes semantic evidence basis fields into an allocator-owned JSON value; allocation failures propagate.
fn semanticEvidenceBasisValue(allocator: std.mem.Allocator, analysis_kind: []const u8) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "analysis_kind", .{ .string = analysis_kind });
    try obj.put(allocator, "capability_tier", .{ .string = "parser_backed" });
    try obj.put(allocator, "confidence", .{ .string = "high" });
    try obj.put(allocator, "classification", .{ .string = "advisory" });
    try obj.put(allocator, "source_coverage", .{ .string = semantic_impact_coverage });
    return .{ .object = obj };
}

/// Serializes semantic cross check fields into an allocator-owned JSON value; allocation failures propagate.
fn semanticCrossCheckValue(allocator: std.mem.Allocator, verify_with: []const []const u8) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "required", .{ .bool = true });
    try obj.put(allocator, "verify_with", try stringArrayValue(allocator, verify_with));
    try obj.put(allocator, "reason", .{ .string = "Static analysis is advisory; compiler-backed validation remains the release gate." });
    return .{ .object = obj };
}

/// Collects a deduplicated path list from a whitespace/comma-separated `text`
/// argument plus paths parsed out of a unified `patch`. Returns an
/// allocator-owned PathList the caller must deinit.
pub fn pathListFromTextAndPatch(allocator: std.mem.Allocator, text: ?[]const u8, patch: ?[]const u8) !PathList {
    // Normalize and constrain path handling here before any downstream filesystem action.
    var paths = std.ArrayList([]const u8).empty;
    errdefer {
        freeStringList(allocator, paths.items);
        paths.deinit(allocator);
    }
    try appendPathTokens(allocator, &paths, text);
    try appendPatchPaths(allocator, &paths, patch);
    return .{ .items = try paths.toOwnedSlice(allocator) };
}

/// Determines the changed-file set: caller-supplied `explicit_files` win;
/// otherwise it falls back to `git status --porcelain` (bounded timeout),
/// dropping generated/vendored paths. A git failure yields an empty list rather
/// than an error. Returns an allocator-owned PathList the caller must deinit.
fn changedPathList(allocator: std.mem.Allocator, context: app_context.ProjectIntelligenceContext, explicit_files: ?[]const u8, timeout_ms: i64) !PathList {
    // Normalize and constrain path handling here before any downstream filesystem action.
    var list = std.ArrayList([]const u8).empty;
    errdefer {
        freeStringList(allocator, list.items);
        list.deinit(allocator);
    }
    try appendPathTokens(allocator, &list, explicit_files);
    if (list.items.len > 0) return .{ .items = try list.toOwnedSlice(allocator) };
    var result = context.command_runner.run(allocator, .{
        .argv = &.{ "git", "status", "--porcelain" },
        .cwd = context.workspace.root,
        .timeout_ms = @intCast(@max(1, @min(timeout_ms, 5000))),
        .max_stdout_bytes = workflows.command_output_limit,
        .max_stderr_bytes = workflows.command_output_limit,
        .provenance = "zigars_validate_patch changed paths",
    }) catch return .{ .items = try list.toOwnedSlice(allocator) };
    defer result.deinit(allocator);
    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    while (lines.next()) |line| {
        if (line.len < 4) continue;
        const path = statusLinePath(line);
        if (path.len == 0 or zig_analysis.skipWorkspacePath(path)) continue;
        try appendUniqueString(allocator, &list, path);
    }
    return .{ .items = try list.toOwnedSlice(allocator) };
}

/// Appends path tokens data into caller-provided storage, propagating allocation failures.
fn appendPathTokens(allocator: std.mem.Allocator, list: *std.ArrayList([]const u8), text_value: ?[]const u8) !void {
    const text_input = text_value orelse return;
    var tokens = std.mem.tokenizeAny(u8, text_input, ", \t\r\n");
    while (tokens.next()) |token| {
        if (token.len == 0) continue;
        try appendUniqueString(allocator, list, token);
    }
}

/// Appends patch paths data into caller-provided storage, propagating allocation failures.
fn appendPatchPaths(allocator: std.mem.Allocator, list: *std.ArrayList([]const u8), patch_text: ?[]const u8) !void {
    // Append in deterministic order so completion and snapshot output remain stable.
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

/// Appends patch path token data into caller-provided storage, propagating allocation failures.
fn appendPatchPathToken(allocator: std.mem.Allocator, list: *std.ArrayList([]const u8), raw: []const u8) !void {
    var path = raw;
    if (std.mem.startsWith(u8, path, "a/") or std.mem.startsWith(u8, path, "b/")) path = path[2..];
    if (std.mem.eql(u8, path, "/dev/null")) return;
    try appendUniqueString(allocator, list, path);
}

/// Appends unique string data into caller-provided storage, propagating allocation failures.
fn appendUniqueString(allocator: std.mem.Allocator, list: *std.ArrayList([]const u8), value: []const u8) !void {
    if (stringListContains(list.items, value)) return;
    try list.append(allocator, try allocator.dupe(u8, value));
}

/// Appends unique command data into caller-provided storage, propagating allocation failures.
fn appendUniqueCommand(allocator: std.mem.Allocator, commands: *std.json.Array, command_text: []const u8) !void {
    // Append in deterministic order so completion and snapshot output remain stable.
    for (commands.items) |item| {
        const existing = switch (item) {
            .string => |s| s,
            else => continue,
        };
        if (std.mem.eql(u8, existing, command_text)) return;
    }
    try commands.append(try ownedString(allocator, command_text));
}

/// Extracts the path portion from a porcelain status line.
fn statusLinePath(line: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, if (line.len > 3) line[3..] else "", " \t");
    if (std.mem.indexOf(u8, trimmed, " -> ")) |arrow| return trimmed[arrow + " -> ".len ..];
    return trimmed;
}

/// Reports whether the requested workspace path exists.
fn workspacePathExists(allocator: std.mem.Allocator, context: app_context.ProjectIntelligenceContext, path: []const u8) bool {
    const result = context.workspace_store.exists(allocator, .{
        .path = path,
        .provenance = "project_intelligence.workspace_path_exists",
    }) catch return false;
    return result.exists;
}

/// Serializes argv owned fields into an allocator-owned JSON value; allocation failures propagate.
fn argvOwnedValue(allocator: std.mem.Allocator, argv: []const []const u8) !std.json.Value {
    var array = std.json.Array.init(allocator);
    for (argv) |arg| try array.append(try ownedString(allocator, arg));
    return .{ .array = array };
}

/// Serializes command term fields into an allocator-owned JSON value; allocation failures propagate.
fn commandTermValue(allocator: std.mem.Allocator, term: ports.CommandTerm) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = term.name() });
    if (term.exitCode()) |code| try obj.put(allocator, "code", .{ .integer = code });
    return .{ .object = obj };
}

/// Carries safe text data across use case and port boundaries.
const SafeText = struct {
    text: []const u8,
    invalid_utf8: bool,
    encoding: []const u8,
    byte_count: usize,
};

/// Copies bounded text into allocator-owned storage for result payloads.
fn safeTextAlloc(allocator: std.mem.Allocator, bytes: []const u8) !SafeText {
    // Keep this logic centralized so callers observe one consistent behavior path.
    if (std.unicode.utf8ValidateSlice(bytes)) {
        return .{
            .text = try allocator.dupe(u8, bytes),
            .invalid_utf8 = false,
            .encoding = "utf-8",
            .byte_count = bytes.len,
        };
    }
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var index: usize = 0;
    while (index < bytes.len) {
        const len = std.unicode.utf8ByteSequenceLength(bytes[index]) catch {
            try out.appendSlice(allocator, &std.unicode.replacement_character_utf8);
            index += 1;
            continue;
        };
        if (index + len <= bytes.len and std.unicode.utf8ValidateSlice(bytes[index .. index + len])) {
            try out.appendSlice(allocator, bytes[index .. index + len]);
            index += len;
        } else {
            try out.appendSlice(allocator, &std.unicode.replacement_character_utf8);
            index += 1;
        }
    }
    return .{
        .text = try out.toOwnedSlice(allocator),
        .invalid_utf8 = true,
        .encoding = "utf-8-lossy",
        .byte_count = bytes.len,
    };
}

/// Implements put stream fields workflow logic using caller-owned inputs.
fn putStreamFields(allocator: std.mem.Allocator, obj: *std.json.ObjectMap, name: []const u8, safe: SafeText) !void {
    try obj.put(allocator, name, .{ .string = safe.text });
    try obj.put(allocator, try std.fmt.allocPrint(allocator, "{s}_invalid_utf8", .{name}), .{ .bool = safe.invalid_utf8 });
    try obj.put(allocator, try std.fmt.allocPrint(allocator, "{s}_encoding", .{name}), .{ .string = safe.encoding });
    try obj.put(allocator, try std.fmt.allocPrint(allocator, "{s}_byte_count", .{name}), .{ .integer = @intCast(safe.byte_count) });
}

/// Classifies command failures into stable result categories.
fn commandErrorKind(err: anyerror) []const u8 {
    // Keep this logic centralized so callers observe one consistent behavior path.
    return switch (err) {
        error.Timeout, error.RequestTimeout => "timeout",
        error.StreamTooLong, error.OutputLimitExceeded => "output_limit",
        error.FileNotFound, error.NotFound => "executable_not_found",
        error.AccessDenied, error.PermissionDenied => "permission",
        error.EndOfStream, error.BrokenPipe, error.Unavailable, error.NoResponse => "unavailable",
        error.PathOutsideWorkspace, error.EmptyPath => "workspace_path",
        else => "execution",
    };
}

/// Serializes backend error fields into an allocator-owned JSON value; allocation failures propagate.
fn backendErrorValue(allocator: std.mem.Allocator, backend_name: []const u8, operation: []const u8, err: anyerror, resolution: []const u8) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "backend_error" });
    try obj.put(allocator, "ok", .{ .bool = false });
    try obj.put(allocator, "backend", .{ .string = backend_name });
    try obj.put(allocator, "operation", .{ .string = operation });
    try obj.put(allocator, "error", .{ .string = @errorName(err) });
    try obj.put(allocator, "error_kind", .{ .string = commandErrorKind(err) });
    try obj.put(allocator, "resolution", .{ .string = resolution });
    return .{ .object = obj };
}

/// Reports whether output limit error matches the caller-provided data.
fn isOutputLimitError(err: anyerror) bool {
    return err == error.StreamTooLong or err == error.OutputLimitExceeded;
}

/// Reports whether timeout error matches the caller-provided data.
fn isTimeoutError(err: anyerror) bool {
    return err == error.Timeout or err == error.RequestTimeout;
}

/// Reports whether `value` is present in `list` (exact string equality).
fn stringListContains(list: []const []const u8, value: []const u8) bool {
    for (list) |item| {
        if (std.mem.eql(u8, item, value)) return true;
    }
    return false;
}

/// Releases string list allocations; callers must not reuse freed items.
fn freeStringList(allocator: std.mem.Allocator, list: []const []const u8) void {
    for (list) |item| allocator.free(item);
}

/// Extracts json array len data from JSON input without taking ownership of borrowed values.
fn jsonArrayLen(value: std.json.Value) usize {
    return switch (value) {
        .array => |a| a.items.len,
        else => 0,
    };
}

/// Extracts bool field data from JSON input without taking ownership of borrowed values.
fn boolField(obj: std.json.ObjectMap, field: []const u8) ?bool {
    return switch (obj.get(field) orelse .null) {
        .bool => |b| b,
        else => null,
    };
}

/// Extracts string field data from JSON input without taking ownership of borrowed values.
fn stringField(obj: std.json.ObjectMap, field: []const u8) ?[]const u8 {
    return switch (obj.get(field) orelse .null) {
        .string => |s| s,
        else => null,
    };
}

/// Extracts integer field data from JSON input without taking ownership of borrowed values.
fn integerField(obj: std.json.ObjectMap, field: []const u8) ?i64 {
    return switch (obj.get(field) orelse .null) {
        .integer => |i| i,
        .number_string => |s| std.fmt.parseInt(i64, s, 10) catch null,
        else => null,
    };
}

/// Copies the provided string into allocator-owned storage.
fn ownedString(allocator: std.mem.Allocator, value: []const u8) !std.json.Value {
    return .{ .string = try allocator.dupe(u8, value) };
}

/// Serializes string array fields into an allocator-owned JSON value; allocation failures propagate.
fn stringArrayValue(allocator: std.mem.Allocator, values: []const []const u8) !std.json.Value {
    var array = std.json.Array.init(allocator);
    for (values) |value| try array.append(try ownedString(allocator, value));
    return .{ .array = array };
}

/// Serializes clone fields into an allocator-owned JSON value; allocation failures propagate.
fn cloneValue(allocator: std.mem.Allocator, value: std.json.Value) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
    return switch (value) {
        .null => .null,
        .bool => |b| .{ .bool = b },
        .integer => |i| .{ .integer = i },
        .float => |f| .{ .float = f },
        .number_string => |s| .{ .number_string = try allocator.dupe(u8, s) },
        .string => |s| .{ .string = try allocator.dupe(u8, s) },
        .array => |array| blk: {
            var cloned = std.json.Array.init(allocator);
            for (array.items) |item| try cloned.append(try cloneValue(allocator, item));
            break :blk .{ .array = cloned };
        },
        .object => |object| blk: {
            var cloned = std.json.ObjectMap.empty;
            var it = object.iterator();
            while (it.next()) |entry| {
                const key = try allocator.dupe(u8, entry.key_ptr.*);
                try cloned.put(allocator, key, try cloneValue(allocator, entry.value_ptr.*));
            }
            break :blk .{ .object = cloned };
        },
    };
}

/// Serializes serialize fields into an allocator-owned JSON value; allocation failures propagate.
fn serializeValue(allocator: std.mem.Allocator, value: std.json.Value) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try std.json.Stringify.value(value, .{}, &out.writer);
    return out.toOwnedSlice();
}

/// Extracts json line for record data from JSON input without taking ownership of borrowed values.
fn jsonLineForRecord(allocator: std.mem.Allocator, value: std.json.Value) ![]const u8 {
    return serializeValue(allocator, value);
}

/// Computes a lowercase SHA-256 hex digest in allocator-owned storage.
fn sha256Hex(allocator: std.mem.Allocator, data: []const u8) ![]const u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    return allocator.dupe(u8, &hex);
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
