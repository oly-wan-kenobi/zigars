//! Project-intelligence MCP adapters for context packs, validation
//! planning/run, build/test event history, project memory, and capability
//! guidance. Handlers project arguments onto validation/project-intelligence
//! use cases and shape owned results or structured errors. Client sampling
//! (failure-fusion summaries) is always optional: when it is unrequested or
//! unavailable the deterministic evidence is returned and the result records
//! why no sampled summary was produced.
const std = @import("std");
const mcp = @import("mcp");

const app_context = @import("../../../app/context.zig");
const manifest = @import("../../../manifest/mod.zig");
const ports = @import("../../../app/ports.zig");
const project_intelligence = @import("../../../app/usecases/validation/project_intelligence.zig");
const workflows = @import("../../../app/usecases/validation/workflows.zig");
const mcp_errors = @import("../errors.zig");
const mcp_result = @import("../result.zig");

const pi = project_intelligence;
const sampling_failure_fusion_reason = "MCP sampling was not requested or was unavailable; compiler, test, and command evidence summaries are returned directly.";

/// Handles MCP `zigars_context_pack` requests by delegating to app logic and shaping owned results/errors.
pub fn zigarsContextPack(allocator: std.mem.Allocator, context: app_context.ProjectIntelligenceContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return structured(allocator, "zigars_context_pack", "context_pack", pi.contextPackValue(allocator, context, .{
        .mode = argString(args, "mode") orelse "standard",
        .token_budget = @max(500, @min(argInt(args, "token_budget", 4000), 50_000)),
    }));
}

/// Handles MCP `zigars_next_action` requests by delegating to app logic and shaping owned results/errors.
pub fn zigarsNextAction(allocator: std.mem.Allocator, _: app_context.ProjectIntelligenceContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const goal = argString(args, "goal") orelse return mcp_errors.missingArgument(allocator, "zigars_next_action", "goal", "short task or failure description");
    return structured(allocator, "zigars_next_action", "plan_next_action", pi.nextActionPlanValue(allocator, goal, argString(args, "changed_files"), argString(args, "last_error")));
}

/// Handles MCP `zigars_agent_guide` requests by delegating to app logic and shaping owned results/errors.
pub fn zigarsAgentGuide(allocator: std.mem.Allocator, _: app_context.ProjectIntelligenceContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return structured(allocator, "zigars_agent_guide", "agent_guide", pi.agentGuideValue(allocator, argString(args, "client") orelse "generic", argString(args, "task") orelse "any"));
}

/// Handles MCP `zigars_validate_patch` requests by delegating to app logic and shaping owned results/errors.
pub fn zigarsValidatePatch(allocator: std.mem.Allocator, context: app_context.ProjectIntelligenceContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return structured(allocator, "zigars_validate_patch", "validate_patch", pi.validatePatchValue(allocator, context, .{
        .mode = argString(args, "mode") orelse "standard",
        .changed_files = argString(args, "changed_files"),
        .timeout_ms = timeoutMs(context, args),
        .stop_on_failure = argBool(args, "stop_on_failure", false),
    }));
}

/// Handles MCP `zigars_failure_fusion` requests by delegating to app logic and shaping owned results/errors.
pub fn zigarsFailureFusion(allocator: std.mem.Allocator, context: app_context.ProjectIntelligenceContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const extra_args = splitToolArgs(allocator, argString(args, "args")) catch |err| return splitArgsError(allocator, "zigars_failure_fusion", err);
    defer freeStringList(allocator, extra_args);
    var value = pi.failureFusionFromCommandValue(allocator, context, .{
        .text = argString(args, "text"),
        .command = argString(args, "command"),
        .file = argString(args, "file"),
        .filter = argString(args, "filter"),
        .extra_args = extra_args,
        .timeout_ms = timeoutMs(context, args),
    }) catch |err| return workflowError(allocator, "zigars_failure_fusion", "failure_fusion", err);
    defer deinitTopLevel(allocator, &value);
    if (value == .object) try applyFailureFusionSampling(allocator, &value.object, context.protocol_client, argBool(args, "summarize", false), value);
    return mcp_result.structured(allocator, value);
}

/// Handles MCP `zigars_impact` requests by delegating to app logic and shaping owned results/errors.
pub fn zigarsImpact(allocator: std.mem.Allocator, context: app_context.ProjectIntelligenceContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return structured(allocator, "zigars_impact", "impact", pi.impactValue(allocator, context, .{
        .files = argString(args, "files"),
        .symbols = argString(args, "symbols"),
        .limit = @intCast(@max(1, argInt(args, "limit", 300))),
    }));
}

/// Handles MCP `zigars_project_profile` requests by delegating to app logic and shaping owned results/errors.
pub fn zigarsProjectProfile(allocator: std.mem.Allocator, context: app_context.ProjectIntelligenceContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return structured(allocator, "zigars_project_profile", "project_profile", pi.projectProfileValue(allocator, context, .{
        .content = argString(args, "content"),
        .apply = argBool(args, "apply", false),
    }));
}

/// Handles MCP `zigars_patch_guard` requests by delegating to app logic and shaping owned results/errors.
pub fn zigarsPatchGuard(allocator: std.mem.Allocator, context: app_context.ProjectIntelligenceContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return structured(allocator, "zigars_patch_guard", "patch_guard", pi.patchGuardValue(allocator, context, .{
        .files = argString(args, "files"),
        .patch = argString(args, "patch"),
    }));
}

/// Handles MCP `zig_impact_semantic` requests by delegating to app logic and shaping owned results/errors.
pub fn zigImpactSemantic(allocator: std.mem.Allocator, context: app_context.ProjectIntelligenceContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return semanticTool(allocator, context, args, "zig_impact_semantic", false);
}

/// Handles MCP `zig_test_select_semantic` requests by delegating to app logic and shaping owned results/errors.
pub fn zigTestSelectSemantic(allocator: std.mem.Allocator, context: app_context.ProjectIntelligenceContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return semanticTool(allocator, context, args, "zig_test_select_semantic", true);
}

/// Invokes the project-intelligence semantic workflow.
fn semanticTool(allocator: std.mem.Allocator, context: app_context.ProjectIntelligenceContext, args: ?std.json.Value, tool_name: []const u8, select: bool) mcp.tools.ToolError!mcp.tools.ToolResult {
    const request = pi.SemanticImpactRequest{
        .files = argString(args, "files"),
        .diff = argString(args, "diff"),
        .symbols = argString(args, "symbols"),
        .limit = @intCast(@max(1, argInt(args, "limit", pi.semantic_limit_default))),
    };
    const result = if (select)
        pi.testSelectSemanticValue(allocator, context, request)
    else
        pi.semanticImpactValue(allocator, context, request, tool_name);
    return structured(allocator, tool_name, "semantic_impact", result);
}

/// Handles MCP `zigars_validation_plan` requests by delegating to app logic and shaping owned results/errors.
pub fn zigarsValidationPlan(allocator: std.mem.Allocator, context: app_context.ProjectIntelligenceContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    var parsed = try validationPlanRequestFromArgs(allocator, args);
    defer parsed.deinit(allocator);
    var result = workflows.plan(allocator, context.validation(), parsed.request) catch |err| return workflowError(allocator, "zigars_validation_plan", "plan", err);
    defer result.deinit(allocator);
    return structured(allocator, "zigars_validation_plan", "plan", pi.validationPlanValueFromUsecase(allocator, result));
}

/// Handles MCP `zigars_validation_run` requests by delegating to app logic and shaping owned results/errors.
pub fn zigarsValidationRun(allocator: std.mem.Allocator, context: app_context.ProjectIntelligenceContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    var parsed = try validationRunRequestFromArgs(allocator, args, timeoutMs(context, args));
    defer parsed.deinit(allocator);
    var outcome = workflows.run(allocator, context.validation(), parsed.request) catch |err| return workflowError(allocator, "zigars_validation_run", "run", err);
    defer outcome.deinit(allocator);
    return switch (outcome) {
        .ok => |report| structured(allocator, "zigars_validation_run", "run", pi.validationRunValue(allocator, report)),
        .err => |failure| switch (failure) {
            .history_write_failed => |details| mcp_errors.workspacePath(allocator, "zigars_validation_run", details.path, context.workspace.root, details.err),
        },
    };
}

/// Handles MCP `zig_build_events` requests by delegating to app logic and shaping owned results/errors.
pub fn zigBuildEvents(allocator: std.mem.Allocator, context: app_context.ProjectIntelligenceContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return commandEventsTool(allocator, context, args, "zig_build_events", .build);
}

/// Handles MCP `zig_test_events` requests by delegating to app logic and shaping owned results/errors.
pub fn zigTestEvents(allocator: std.mem.Allocator, context: app_context.ProjectIntelligenceContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return commandEventsTool(allocator, context, args, "zig_test_events", .test_cmd);
}

/// Invokes the project-intelligence command-events workflow.
fn commandEventsTool(allocator: std.mem.Allocator, context: app_context.ProjectIntelligenceContext, args: ?std.json.Value, tool_name: []const u8, kind: pi.EventCommandKind) mcp.tools.ToolError!mcp.tools.ToolResult {
    const extra_args = splitToolArgs(allocator, argString(args, "args")) catch |err| return splitArgsError(allocator, tool_name, err);
    defer freeStringList(allocator, extra_args);
    // `filter` is a test-name filter and is only registered on `zig_test_events`.
    // `zig_build_events` does not advertise it (a build has no test filter), and
    // central validation rejects unknown arguments before this handler runs, so
    // only read `filter` for the test command kind to keep schema and handler in
    // sync.
    const filter = if (kind == .test_cmd) argString(args, "filter") else null;
    return structured(allocator, tool_name, "build_events", pi.commandEventsValue(allocator, context, tool_name, .{
        .text = argString(args, "text"),
        .command = argString(args, "command"),
        .file = argString(args, "file"),
        .filter = filter,
        .extra_args = extra_args,
        .timeout_ms = timeoutMs(context, args),
        .kind = kind,
    }));
}

/// Handles MCP `zig_test_timing` requests by delegating to app logic and shaping owned results/errors.
pub fn zigTestTiming(allocator: std.mem.Allocator, _: app_context.ProjectIntelligenceContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const text = argString(args, "text") orelse return mcp_errors.missingArgument(allocator, "zig_test_timing", "text", "captured Zig test output");
    return structured(allocator, "zig_test_timing", "parse_timing", pi.testTimingValue(allocator, text));
}

/// Handles MCP `zigars_validation_history` requests by delegating to app logic and shaping owned results/errors.
pub fn zigarsValidationHistory(allocator: std.mem.Allocator, context: app_context.ProjectIntelligenceContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return historyTool(allocator, context, args, "zigars_validation_history", .runs);
}

/// Handles MCP `zig_test_flake_history` requests by delegating to app logic and shaping owned results/errors.
pub fn zigTestFlakeHistory(allocator: std.mem.Allocator, context: app_context.ProjectIntelligenceContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return historyTool(allocator, context, args, "zig_test_flake_history", .flakes);
}

/// Handles MCP `zig_failure_history` requests by delegating to app logic and shaping owned results/errors.
pub fn zigFailureHistory(allocator: std.mem.Allocator, context: app_context.ProjectIntelligenceContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return historyTool(allocator, context, args, "zig_failure_history", .failures);
}

/// Invokes the project-intelligence history workflow.
fn historyTool(allocator: std.mem.Allocator, context: app_context.ProjectIntelligenceContext, args: ?std.json.Value, tool_name: []const u8, view: workflows.HistoryView) mcp.tools.ToolError!mcp.tools.ToolResult {
    var outcome = workflows.history(allocator, context.validation(), .{
        .view = view,
        .history_text = argString(args, "history"),
        .path = argString(args, "path") orelse workflows.history_path_default,
        .limit = @intCast(@max(1, argInt(args, "limit", 50))),
    }) catch |err| return workflowError(allocator, tool_name, "parse_history", err);
    defer outcome.deinit(allocator);
    return switch (outcome) {
        .ok => |result| structured(allocator, tool_name, "history", pi.validationHistoryToolValue(allocator, tool_name, result)),
        .err => |failure| workflowError(allocator, tool_name, "read_history", failure.err),
    };
}

/// Handles MCP `zigars_session_snapshot` requests by delegating to app logic and shaping owned results/errors.
pub fn zigarsSessionSnapshot(allocator: std.mem.Allocator, context: app_context.ProjectIntelligenceContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return structured(allocator, "zigars_session_snapshot", "snapshot", pi.sessionSnapshotValue(allocator, context, snapshotRequest(args, "zigars_session_snapshot")));
}

/// Handles MCP `zigars_handoff_pack` requests by delegating to app logic and shaping owned results/errors.
pub fn zigarsHandoffPack(allocator: std.mem.Allocator, context: app_context.ProjectIntelligenceContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return structured(allocator, "zigars_handoff_pack", "handoff", pi.handoffPackValue(allocator, context, snapshotRequest(args, "zigars_handoff_pack")));
}

/// Builds the project-intelligence snapshot request from MCP arguments.
fn snapshotRequest(args: ?std.json.Value, kind: []const u8) pi.SessionSnapshotRequest {
    return .{
        .kind = kind,
        .goal = argString(args, "goal"),
        .changed_files = argString(args, "changed_files"),
        .diff = argString(args, "diff"),
        .validation = argString(args, "validation"),
        .last_error = argString(args, "last_error"),
    };
}

/// Handles MCP `zigars_decision_record` requests by delegating to app logic and shaping owned results/errors.
pub fn zigarsDecisionRecord(allocator: std.mem.Allocator, context: app_context.ProjectIntelligenceContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const title = argString(args, "title") orelse return mcp_errors.missingArgument(allocator, "zigars_decision_record", "title", "short decision title");
    const decision = argString(args, "decision") orelse return mcp_errors.missingArgument(allocator, "zigars_decision_record", "decision", "decision text");
    return structured(allocator, "zigars_decision_record", "decision_record", pi.decisionRecordValue(allocator, context, .{
        .title = title,
        .decision = decision,
        .rationale = argString(args, "rationale"),
        .category = argString(args, "category") orelse "architecture",
        .path = argString(args, "path") orelse pi.memory_path_default,
        .apply = argBool(args, "apply", false),
    }));
}

/// Handles MCP `zigars_project_notes` requests by delegating to app logic and shaping owned results/errors.
pub fn zigarsProjectNotes(allocator: std.mem.Allocator, context: app_context.ProjectIntelligenceContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return projectMemoryTool(allocator, context, args, "zigars_project_notes", false);
}

/// Handles MCP `zigars_project_memory` requests by delegating to app logic and shaping owned results/errors.
pub fn zigarsProjectMemory(allocator: std.mem.Allocator, context: app_context.ProjectIntelligenceContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return projectMemoryTool(allocator, context, args, "zigars_project_memory", true);
}

/// Invokes the project-intelligence memory workflow.
fn projectMemoryTool(allocator: std.mem.Allocator, context: app_context.ProjectIntelligenceContext, args: ?std.json.Value, tool_name: []const u8, include_builtins: bool) mcp.tools.ToolError!mcp.tools.ToolResult {
    return structured(allocator, tool_name, "project_memory", pi.projectMemoryValue(allocator, context, .{
        .content = argString(args, "content"),
        .path = argString(args, "path") orelse pi.memory_path_default,
        .query = argString(args, "query"),
        .category = argString(args, "category"),
        .limit = @intCast(@max(1, argInt(args, "limit", 100))),
        .include_builtins = include_builtins,
        .tool_name = tool_name,
    }));
}

/// Handles MCP `zigars_capability_match` requests by delegating to app logic and shaping owned results/errors.
pub fn zigarsCapabilityMatch(allocator: std.mem.Allocator, _: app_context.ProjectIntelligenceContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const goal = argString(args, "goal") orelse argString(args, "error") orelse argString(args, "diff") orelse return mcp_errors.missingArgument(allocator, "zigars_capability_match", "goal", "goal, error, or diff text");
    const entries = capabilityEntries(allocator) catch return error.OutOfMemory;
    defer allocator.free(entries);
    return structured(allocator, "zigars_capability_match", "capability_match", pi.capabilityMatchValue(allocator, goal, @intCast(@max(1, argInt(args, "limit", 8))), entries));
}

/// Handles MCP `zigars_tool_sequence_plan` requests by delegating to app logic and shaping owned results/errors.
pub fn zigarsToolSequencePlan(allocator: std.mem.Allocator, _: app_context.ProjectIntelligenceContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const goal = argString(args, "goal") orelse argString(args, "error") orelse argString(args, "diff") orelse return mcp_errors.missingArgument(allocator, "zigars_tool_sequence_plan", "goal", "goal, error, or diff text");
    return structured(allocator, "zigars_tool_sequence_plan", "sequence_plan", pi.toolSequencePlanValue(allocator, goal, argString(args, "changed_files")));
}

/// Parsed validation-plan arguments plus owned changed-path storage.
pub const ParsedValidationPlanRequest = struct {
    request: workflows.PlanRequest,
    changed_paths: pi.PathList,

    /// Frees changed-path storage cloned while parsing MCP arguments.
    pub fn deinit(self: *ParsedValidationPlanRequest, allocator: std.mem.Allocator) void {
        self.changed_paths.deinit(allocator);
        self.* = undefined;
    }
};

/// Parsed validation-run arguments with the embedded owned plan request.
pub const ParsedValidationRunRequest = struct {
    request: workflows.RunRequest,
    plan: ParsedValidationPlanRequest,

    /// Releases the embedded validation-plan request storage.
    pub fn deinit(self: *ParsedValidationRunRequest, allocator: std.mem.Allocator) void {
        self.plan.deinit(allocator);
        self.* = undefined;
    }
};

/// Parses MCP arguments into a validation PlanRequest. The changed-path list is
/// derived from `changed_files` plus `diff` and is owned by the returned struct;
/// the caller must deinit it. The request borrows that list's backing storage.
pub fn validationPlanRequestFromArgs(allocator: std.mem.Allocator, args: ?std.json.Value) !ParsedValidationPlanRequest {
    const changed_paths = try pi.pathListFromTextAndPatch(allocator, argString(args, "changed_files"), argString(args, "diff"));
    return .{
        .request = .{
            .mode = argString(args, "mode") orelse "standard",
            .goal = argString(args, "goal"),
            .changed_paths = changed_paths.items,
            .include_semantic = argBool(args, "include_semantic", true),
        },
        .changed_paths = changed_paths,
    };
}

/// Parses MCP arguments into a validation RunRequest wrapping the parsed plan.
/// `timeout_ms` is already adapter-clamped and is floored to at least 1ms here.
/// The returned struct owns the embedded plan request; the caller must deinit.
pub fn validationRunRequestFromArgs(allocator: std.mem.Allocator, args: ?std.json.Value, timeout_ms: i64) !ParsedValidationRunRequest {
    var plan_request = try validationPlanRequestFromArgs(allocator, args);
    errdefer plan_request.deinit(allocator);
    return .{
        .request = .{
            .plan = plan_request.request,
            .output = argString(args, "output") orelse workflows.history_path_default,
            .apply = argBool(args, "apply", false),
            .stop_on_failure = argBool(args, "stop_on_failure", false),
            .timeout_ms = @intCast(@max(1, timeout_ms)),
        },
        .plan = plan_request,
    };
}

/// Re-exports the use-case run-report JSON builder so adapter tests and callers
/// share one stable result shape. Value owned by `allocator`.
pub fn validationRunValue(allocator: std.mem.Allocator, report: workflows.RunReport) !std.json.Value {
    return pi.validationRunValue(allocator, report);
}

/// Normalizes context-construction failures into structured MCP tool errors.
pub fn contextSetupError(allocator: std.mem.Allocator, tool_name: []const u8, err: anyerror) mcp.tools.ToolError!mcp.tools.ToolResult {
    if (err == error.OutOfMemory) return error.OutOfMemory;
    return mcp_errors.fromError(allocator, .{
        .tool = tool_name,
        .operation = "build_project_intelligence_context",
        .phase = "bootstrap_ports",
        .code = "missing_project_intelligence_context",
        .category = "internal_contract",
        .resolution = "Restart the MCP server; project-intelligence handlers require command, workspace, scanner, and clock ports from bootstrap runtime composition.",
    }, err);
}

/// Central success/error fork for most handlers: on a thrown use-case error it
/// returns a structured tool error tagged with `tool_name`/`phase`; otherwise it
/// wraps the value as a structured result. The top-level container is freed here
/// after structured() copies what it needs.
fn structured(allocator: std.mem.Allocator, tool_name: []const u8, phase: []const u8, value_or_error: anyerror!std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    var value = value_or_error catch |err| return workflowError(allocator, tool_name, phase, err);
    defer deinitTopLevel(allocator, &value);
    return mcp_result.structured(allocator, value);
}

/// Optionally requests client sampling for a compact failure-fusion summary.
fn applyFailureFusionSampling(
    allocator: std.mem.Allocator,
    obj: *std.json.ObjectMap,
    client: ?ports.ProtocolClient,
    summarize: bool,
    value: std.json.Value,
) !void {
    if (!summarize) {
        try putSamplingMetadata(allocator, obj, .{
            .supported = false,
            .used = false,
            .status = .unsupported,
            .unavailable_reason = "summarize=false; deterministic failure evidence was returned without client sampling.",
        });
        return;
    }
    const protocol_client = client orelse {
        try putSamplingMetadata(allocator, obj, .{
            .supported = false,
            .used = false,
            .status = .unsupported,
            .unavailable_reason = sampling_failure_fusion_reason,
        });
        return;
    };
    const response = protocol_client.request(allocator, .{
        .feature = .sampling,
        .method = "sampling/createMessage",
        .params = try failureFusionSamplingParams(allocator, value),
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => ports.ProtocolResponse{
            .supported = true,
            .used = false,
            .status = .timeout,
            .unavailable_reason = "MCP sampling request failed before a client response was available.",
        },
    };
    if (response.status == .accepted) {
        if (sampledText(response.result)) |text| {
            try obj.put(allocator, "sampling_used", .{ .bool = true });
            try obj.put(allocator, "sampling_status", .{ .string = "accepted" });
            try obj.put(allocator, "sampled_summary", .{ .string = text });
            return;
        }
        try putSamplingMetadata(allocator, obj, .{
            .supported = true,
            .used = false,
            .status = .malformed,
            .unavailable_reason = "MCP sampling response did not include text content.",
        });
        return;
    }
    try putSamplingMetadata(allocator, obj, response);
}

/// Builds sampling/createMessage params from deterministic failure-fusion evidence.
fn failureFusionSamplingParams(allocator: std.mem.Allocator, value: std.json.Value) !std.json.Value {
    const evidence = try mcp_result.serializeAlloc(allocator, value);
    defer allocator.free(evidence);
    var prompt = std.ArrayList(u8).empty;
    errdefer prompt.deinit(allocator);
    try prompt.appendSlice(allocator, "Summarize this deterministic Zig failure-fusion evidence. Do not invent facts.\n\n");
    try prompt.appendSlice(allocator, evidence);

    var content = std.json.ObjectMap.empty;
    try content.put(allocator, "type", .{ .string = "text" });
    try content.put(allocator, "text", .{ .string = try prompt.toOwnedSlice(allocator) });

    var message = std.json.ObjectMap.empty;
    try message.put(allocator, "role", .{ .string = "user" });
    try message.put(allocator, "content", .{ .object = content });
    var messages = std.json.Array.init(allocator);
    try messages.append(.{ .object = message });

    var params = std.json.ObjectMap.empty;
    try params.put(allocator, "messages", .{ .array = messages });
    try params.put(allocator, "systemPrompt", .{ .string = "Summarize zigars failure evidence tersely and cite only facts present in the payload." });
    try params.put(allocator, "maxTokens", .{ .integer = 256 });
    return .{ .object = params };
}

/// Adds deterministic sampling status metadata to failure-fusion outputs.
fn putSamplingMetadata(allocator: std.mem.Allocator, obj: *std.json.ObjectMap, response: ports.ProtocolResponse) !void {
    try obj.put(allocator, "sampling_used", .{ .bool = response.used });
    try obj.put(allocator, "sampling_status", .{ .string = protocolStatusName(response.status) });
    try obj.put(allocator, "summary_unavailable_reason", .{ .string = if (response.unavailable_reason.len > 0) response.unavailable_reason else sampling_failure_fusion_reason });
}

/// Extracts sampled text from common MCP sampling response shapes.
fn sampledText(result: ?std.json.Value) ?[]const u8 {
    const value = result orelse return null;
    if (value != .object) return null;
    if (value.object.get("content")) |content| {
        if (content == .object) {
            if (content.object.get("text")) |text| {
                if (text == .string) return text.string;
            }
        } else if (content == .string) return content.string;
    }
    if (value.object.get("message")) |message| {
        if (message == .object) {
            if (message.object.get("content")) |content| {
                if (content == .object) {
                    if (content.object.get("text")) |text| {
                        if (text == .string) return text.string;
                    }
                } else if (content == .string) return content.string;
            }
        }
    }
    return null;
}

/// Stable JSON spelling for protocol helper status.
fn protocolStatusName(status: ports.ProtocolResponseStatus) []const u8 {
    return switch (status) {
        .accepted => "accepted",
        .declined => "declined",
        .cancelled => "cancelled",
        .malformed => "malformed",
        .timeout => "timeout",
        .unsupported => "unsupported",
        .error_response => "error_response",
    };
}

/// Maps workflow failures to structured MCP tool errors.
fn workflowError(allocator: std.mem.Allocator, tool_name: []const u8, phase: []const u8, err: anyerror) mcp.tools.ToolError!mcp.tools.ToolResult {
    if (err == error.OutOfMemory) return error.OutOfMemory;
    if (err == error.MissingFile) return mcp_errors.missingArgument(allocator, tool_name, "file", "workspace-relative Zig file for this command");
    if (err == error.InvalidCommand) return mcp_errors.invalidArgument(allocator, tool_name, "command", "one of build, build-test, test, check, fmt-check", argActual(err), "Choose an allow-listed command.");
    if (err == error.InvalidArguments) return mcp_errors.invalidArgument(allocator, tool_name, null, "valid tool arguments", "invalid", "Inspect the tool inputSchema and retry with supported values.");
    if (err == error.PathOutsideWorkspace or err == error.EmptyPath) return mcp_errors.workspacePath(allocator, tool_name, "", "", err);
    return mcp_errors.fromError(allocator, .{
        .tool = tool_name,
        .operation = "validation_workflow",
        .phase = phase,
        .code = "validation_workflow_failed",
        .category = "agent_workflow",
        .resolution = "Inspect tool arguments and workspace paths; pass captured text for parsing-only workflows when command execution is unavailable.",
    }, err);
}

/// Placeholder "actual value" for invalid-command errors. The triggering error
/// carries no captured argument text, so a constant marker is reported.
fn argActual(_: anyerror) []const u8 {
    return "invalid";
}

/// Maps split args error failures to structured MCP errors.
fn splitArgsError(allocator: std.mem.Allocator, tool_name: []const u8, err: anyerror) mcp.tools.ToolError!mcp.tools.ToolResult {
    return switch (err) {
        error.InvalidArguments => mcp_errors.invalidArgument(allocator, tool_name, "args", "shell-like argument string", "invalid", "Use balanced quotes and escapes, or omit args for no extra Zig arguments."),
        error.OutOfMemory => error.OutOfMemory,
        else => workflowError(allocator, tool_name, "parse_args", err),
    };
}

/// Flattens the static tool manifest into CapabilityEntry records (name, group,
/// risk/write flags, plan kind) for goal-to-tool matching. Slice owned by
/// `allocator`; the entry fields borrow manifest-owned static strings.
fn capabilityEntries(allocator: std.mem.Allocator) ![]pi.CapabilityEntry {
    var entries = try allocator.alloc(pi.CapabilityEntry, manifest.entries.len);
    for (manifest.entries, 0..) |entry, index| {
        const risk = entry.risk;
        entries[index] = .{
            .name = entry.name,
            .description = entry.meta.description,
            .group = manifest.groupName(entry.group),
            .group_keywords = manifest.groupKeywords(entry.group),
            .risk = .{
                .level = manifest.riskLevel(risk),
                .mcp_read_only_hint = manifest.readOnlyHintFor(entry.meta),
                .writes_source = risk.writes_source,
                .writes_artifacts = risk.writes_artifacts,
                .writes_require_apply = risk.writes_require_apply,
                .preview_by_default = risk.preview_by_default,
                .mutates_lsp_state = risk.mutates_lsp_state,
                .executes_project_code = risk.executes_project_code,
                .executes_user_command = risk.executes_user_command,
                .executes_backend = risk.executes_backend,
            },
            .plan_kind = manifest.planKind(entry.plan),
        };
    }
    return entries;
}

/// Reads a string argument when it is present with the expected type.
fn argString(args: ?std.json.Value, name: []const u8) ?[]const u8 {
    return mcp.tools.getString(args, name);
}

/// Reads a bool argument when it is present with the expected type.
fn argBool(args: ?std.json.Value, name: []const u8, default: bool) bool {
    return mcp.tools.getBoolean(args, name) orelse default;
}

/// Reads an int argument when it is present with the expected type.
fn argInt(args: ?std.json.Value, name: []const u8, default: i64) i64 {
    return mcp.tools.getInteger(args, name) orelse default;
}

/// Clamps requested timeout to the supported command timeout range.
fn timeoutMs(context: app_context.ProjectIntelligenceContext, args: ?std.json.Value) i64 {
    return @max(1, @min(argInt(args, "timeout_ms", context.timeouts.command_ms), 60 * 60 * 1000));
}

/// Tokenizes an optional shell-style argument string into an owned argv slice,
/// honoring single/double quotes and backslash escapes; null yields an empty
/// slice. Returns error.InvalidArguments on a dangling escape or unterminated
/// quote. Caller frees via freeStringList.
fn splitToolArgs(allocator: std.mem.Allocator, text_value: ?[]const u8) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    var current: std.ArrayList(u8) = .empty;
    errdefer {
        freeStringItems(allocator, list.items);
        list.deinit(allocator);
        current.deinit(allocator);
    }
    if (text_value) |value| {
        var quote: ?u8 = null;
        var escaping = false;
        var in_token = false;
        for (value) |c| {
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
    }
    return list.toOwnedSlice(allocator);
}

/// Flushes the in-progress token buffer as one owned argv entry and resets it.
fn finishArg(allocator: std.mem.Allocator, list: *std.ArrayList([]const u8), current: *std.ArrayList(u8)) !void {
    const arg = try current.toOwnedSlice(allocator);
    errdefer allocator.free(arg);
    try list.append(allocator, arg);
}

/// Frees each allocated string in a split argument list.
fn freeStringList(allocator: std.mem.Allocator, values: []const []const u8) void {
    freeStringItems(allocator, values);
    allocator.free(values);
}

/// Frees allocated string items without freeing the slice container.
fn freeStringItems(allocator: std.mem.Allocator, values: []const []const u8) void {
    for (values) |value| allocator.free(value);
}

/// Frees the top-level JSON container allocated for a structured error payload.
fn deinitTopLevel(allocator: std.mem.Allocator, value: *std.json.Value) void {
    switch (value.*) {
        .object => |*obj| obj.deinit(allocator),
        else => {},
    }
}

test "project intelligence adapter maps validation workflow failures" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var runtime = AdapterRuntime{ .write_error = error.AccessDenied };
    const context = runtime.context();

    var run_args = std.json.ObjectMap.empty;
    try run_args.put(allocator, "mode", .{ .string = "quick" });
    try run_args.put(allocator, "changed_files", .{ .string = "src/main.zig" });
    try run_args.put(allocator, "timeout_ms", .{ .integer = 1000 });
    try run_args.put(allocator, "apply", .{ .bool = true });
    var run_result = try zigarsValidationRun(allocator, context, .{ .object = run_args });
    defer mcp_result.deinitToolResult(allocator, run_result);
    try std.testing.expect(run_result.is_error);
    try std.testing.expectEqualStrings("AccessDenied", run_result.structuredContent.?.object.get("error").?.string);

    var history_runtime = AdapterRuntime{ .history_read_error = error.PermissionDenied };
    var history_args = std.json.ObjectMap.empty;
    try history_args.put(allocator, "path", .{ .string = "history.jsonl" });
    var history_result = try zigarsValidationHistory(allocator, history_runtime.context(), .{ .object = history_args });
    defer mcp_result.deinitToolResult(allocator, history_result);
    try std.testing.expect(history_result.is_error);
    try std.testing.expectEqualStrings("PermissionDenied", history_result.structuredContent.?.object.get("error").?.string);

    var helper_runtime = AdapterRuntime{};
    const helper_context = helper_runtime.context();
    const resolved = try helper_context.workspace_store.resolve(allocator, .{ .path = "src/main.zig" });
    defer resolved.deinit(allocator);
    try std.testing.expectEqualStrings("/repo/src/main.zig", resolved.path);
    try std.testing.expectError(error.PathOutsideWorkspace, helper_context.workspace_store.resolve(allocator, .{ .path = "../secret" }));
    const wrote = try helper_context.workspace_store.write(.{ .path = "out.jsonl", .bytes = "{}", .provenance = "test" });
    try std.testing.expectEqual(@as(usize, 2), wrote.bytes_written);
    const exists = try helper_context.workspace_store.exists(allocator, .{ .path = "src/main.zig" });
    try std.testing.expect(exists.exists);
    var scan = try helper_context.workspace_scanner.scanZigFiles(allocator, .{ .provenance = "test" });
    defer scan.deinit(allocator);
    try std.testing.expectEqualStrings("src/main.zig", scan.files[0].path);
    const id = try helper_context.clock_and_ids.nextId(allocator, .{ .prefix = "run" });
    defer allocator.free(id);
    try std.testing.expectEqualStrings("run-1", id);
}

test "project intelligence adapter maps context workflow and split errors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try std.testing.expectError(error.OutOfMemory, contextSetupError(allocator, "zigars_context_pack", error.OutOfMemory));
    const context_error = try contextSetupError(allocator, "zigars_context_pack", error.MissingPort);
    defer mcp_result.deinitToolResult(allocator, context_error);
    try std.testing.expect(context_error.is_error);

    var invalid_command = try workflowError(allocator, "zigars_failure_fusion", "run", error.InvalidCommand);
    defer mcp_result.deinitToolResult(allocator, invalid_command);
    try std.testing.expect(invalid_command.is_error);
    try std.testing.expectEqualStrings("command", invalid_command.structuredContent.?.object.get("field").?.string);

    var generic = try workflowError(allocator, "zigars_validation_history", "read_history", error.AccessDenied);
    defer mcp_result.deinitToolResult(allocator, generic);
    try std.testing.expect(generic.is_error);
    try std.testing.expectEqualStrings("AccessDenied", generic.structuredContent.?.object.get("error").?.string);

    const split_invalid = try splitArgsError(allocator, "zigars_failure_fusion", error.InvalidArguments);
    defer mcp_result.deinitToolResult(allocator, split_invalid);
    try std.testing.expect(split_invalid.is_error);
    try std.testing.expectError(error.OutOfMemory, splitArgsError(allocator, "zigars_failure_fusion", error.OutOfMemory));

    const split_generic = try splitArgsError(allocator, "zigars_failure_fusion", error.AccessDenied);
    defer mcp_result.deinitToolResult(allocator, split_generic);
    try std.testing.expect(split_generic.is_error);
}

test "project intelligence adapter splits tool args and cleans up allocation failures" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const parsed = try splitToolArgs(allocator, "  --flag 'quoted value' \"double value\" escaped\\ space\tplain\n");
    defer freeStringList(allocator, parsed);
    try std.testing.expectEqual(@as(usize, 5), parsed.len);
    try std.testing.expectEqualStrings("--flag", parsed[0]);
    try std.testing.expectEqualStrings("quoted value", parsed[1]);
    try std.testing.expectEqualStrings("double value", parsed[2]);
    try std.testing.expectEqualStrings("escaped space", parsed[3]);
    try std.testing.expectEqualStrings("plain", parsed[4]);

    const empty = try splitToolArgs(allocator, null);
    defer freeStringList(allocator, empty);
    try std.testing.expectEqual(@as(usize, 0), empty.len);
    try std.testing.expectError(error.InvalidArguments, splitToolArgs(allocator, "'unterminated"));
    try std.testing.expectError(error.InvalidArguments, splitToolArgs(allocator, "dangling\\"));

    try std.testing.checkAllAllocationFailures(std.testing.allocator, splitToolArgsAllocationCase, .{});
}

test "project intelligence sampling helpers classify sampled text and fallback metadata" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var content = std.json.ObjectMap.empty;
    try content.put(allocator, "text", .{ .string = "short summary" });
    var response = std.json.ObjectMap.empty;
    try response.put(allocator, "content", .{ .object = content });
    try std.testing.expectEqualStrings("short summary", sampledText(.{ .object = response }).?);

    var obj = std.json.ObjectMap.empty;
    try putSamplingMetadata(allocator, &obj, .{
        .supported = false,
        .status = .unsupported,
        .unavailable_reason = "no sampling",
    });
    try std.testing.expect(!obj.get("sampling_used").?.bool);
    try std.testing.expectEqualStrings("unsupported", obj.get("sampling_status").?.string);
    try std.testing.expectEqualStrings("no sampling", obj.get("summary_unavailable_reason").?.string);
}

/// Exercises split-argument allocation failure handling in tests.
fn splitToolArgsAllocationCase(allocator: std.mem.Allocator) !void {
    const parsed = try splitToolArgs(allocator, "alpha 'beta gamma' delta\\ epsilon");
    defer freeStringList(allocator, parsed);
    try std.testing.expectEqual(@as(usize, 3), parsed.len);
}

/// Data fixture for adapter runtime adapter tests.
const AdapterRuntime = struct {
    write_error: ?ports.PortError = null,
    history_read_error: ?ports.PortError = null,

    /// Builds the fake app context exposed by the adapter runtime fixture.
    fn context(self: *AdapterRuntime) app_context.ProjectIntelligenceContext {
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

    /// Records fake command invocations for adapter runtime tests.
    fn commandRun(_: *anyopaque, allocator: std.mem.Allocator, _: ports.CommandRequest) ports.PortError!ports.CommandResult {
        return .{
            .exit_code = 0,
            .stdout = try allocator.dupe(u8, "ok\n"),
            .stderr = try allocator.dupe(u8, ""),
            .duration_ms = 1,
            .owns_stdout = true,
            .owns_stderr = true,
        };
    }

    /// Resolves a workspace path inside the adapter runtime fixture.
    fn workspaceResolve(_: *anyopaque, allocator: std.mem.Allocator, request: ports.WorkspaceResolveRequest) ports.PortError!ports.WorkspaceResolveResult {
        if (std.mem.indexOf(u8, request.path, "..") != null) return error.PathOutsideWorkspace;
        return .{ .path = try std.fmt.allocPrint(allocator, "/repo/{s}", .{request.path}), .owns_path = true };
    }

    /// Reads fixture workspace content for adapter runtime tests.
    fn workspaceRead(ptr: *anyopaque, allocator: std.mem.Allocator, request: ports.WorkspaceReadRequest) ports.PortError!ports.WorkspaceReadResult {
        const self: *AdapterRuntime = @ptrCast(@alignCast(ptr));
        if (self.history_read_error) |err| {
            if (std.mem.eql(u8, request.provenance, "zigars_validation_history read")) return err;
        }
        const bytes = if (std.mem.eql(u8, request.path, "src/main.zig"))
            "pub fn main() void {}\n"
        else if (std.mem.eql(u8, request.path, workflows.history_path_default) or std.mem.eql(u8, request.path, "history.jsonl"))
            "{\"ok\":true}\n"
        else
            return error.FileNotFound;
        return .{ .bytes = try allocator.dupe(u8, bytes), .owns_bytes = true };
    }

    /// Records fixture workspace writes for adapter runtime tests.
    fn workspaceWrite(ptr: *anyopaque, request: ports.WorkspaceWriteRequest) ports.PortError!ports.WorkspaceWriteResult {
        const self: *AdapterRuntime = @ptrCast(@alignCast(ptr));
        if (self.write_error) |err| return err;
        return .{ .bytes_written = request.bytes.len };
    }

    /// Reports fixture workspace file existence for adapter runtime tests.
    fn workspaceExists(_: *anyopaque, _: std.mem.Allocator, request: ports.WorkspaceExistsRequest) ports.PortError!ports.WorkspaceExistsResult {
        return .{ .exists = std.mem.eql(u8, request.path, "src") or std.mem.eql(u8, request.path, "src/main.zig"), .kind = .file };
    }

    /// Returns fixture Zig source paths for adapter runtime tests.
    fn scanZigFiles(_: *anyopaque, allocator: std.mem.Allocator, _: ports.WorkspaceScanRequest) ports.PortError!ports.WorkspaceScanResult {
        const files = try allocator.alloc(ports.WorkspaceScanFile, 1);
        files[0] = .{ .path = try allocator.dupe(u8, "src/main.zig") };
        return .{ .files = files, .owns_memory = true };
    }

    /// Returns a deterministic timestamp for adapter runtime tests.
    fn now(_: *anyopaque) ports.PortError!ports.Instant {
        return .{ .unix_ms = 1_700_000_000_000, .monotonic_ms = 1 };
    }

    /// Returns a deterministic id for adapter runtime tests.
    fn nextId(_: *anyopaque, allocator: std.mem.Allocator, request: ports.IdRequest) ports.PortError![]const u8 {
        return std.fmt.allocPrint(allocator, "{s}-1", .{request.prefix});
    }
};
