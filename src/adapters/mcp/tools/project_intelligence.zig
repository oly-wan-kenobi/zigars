const std = @import("std");
const mcp = @import("mcp");

const app_context = @import("../../../app/context.zig");
const manifest = @import("../../../manifest/mod.zig");
const project_intelligence = @import("../../../app/usecases/validation/project_intelligence.zig");
const workflows = @import("../../../app/usecases/validation/workflows.zig");
const mcp_errors = @import("../errors.zig");
const mcp_result = @import("../result.zig");

const pi = project_intelligence;

pub fn zigarContextPack(allocator: std.mem.Allocator, context: app_context.ProjectIntelligenceContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return structured(allocator, "zigar_context_pack", "context_pack", pi.contextPackValue(allocator, context, .{
        .mode = argString(args, "mode") orelse "standard",
        .token_budget = @max(500, @min(argInt(args, "token_budget", 4000), 50_000)),
    }));
}

pub fn zigarNextAction(allocator: std.mem.Allocator, _: app_context.ProjectIntelligenceContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const goal = argString(args, "goal") orelse return mcp_errors.missingArgument(allocator, "zigar_next_action", "goal", "short task or failure description");
    return structured(allocator, "zigar_next_action", "plan_next_action", pi.nextActionPlanValue(allocator, goal, argString(args, "changed_files"), argString(args, "last_error")));
}

pub fn zigarAgentGuide(allocator: std.mem.Allocator, _: app_context.ProjectIntelligenceContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return structured(allocator, "zigar_agent_guide", "agent_guide", pi.agentGuideValue(allocator, argString(args, "client") orelse "generic", argString(args, "task") orelse "any"));
}

pub fn zigarValidatePatch(allocator: std.mem.Allocator, context: app_context.ProjectIntelligenceContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return structured(allocator, "zigar_validate_patch", "validate_patch", pi.validatePatchValue(allocator, context, .{
        .mode = argString(args, "mode") orelse "standard",
        .changed_files = argString(args, "changed_files"),
        .timeout_ms = timeoutMs(context, args),
        .stop_on_failure = argBool(args, "stop_on_failure", false),
    }));
}

pub fn zigarFailureFusion(allocator: std.mem.Allocator, context: app_context.ProjectIntelligenceContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const extra_args = splitToolArgs(allocator, argString(args, "args")) catch |err| return splitArgsError(allocator, "zigar_failure_fusion", err);
    defer freeStringList(allocator, extra_args);
    return structured(allocator, "zigar_failure_fusion", "failure_fusion", pi.failureFusionFromCommandValue(allocator, context, .{
        .text = argString(args, "text"),
        .command = argString(args, "command"),
        .file = argString(args, "file"),
        .filter = argString(args, "filter"),
        .extra_args = extra_args,
        .timeout_ms = timeoutMs(context, args),
    }));
}

pub fn zigarImpact(allocator: std.mem.Allocator, context: app_context.ProjectIntelligenceContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return structured(allocator, "zigar_impact", "impact", pi.impactValue(allocator, context, .{
        .files = argString(args, "files"),
        .symbols = argString(args, "symbols"),
        .limit = @intCast(@max(1, argInt(args, "limit", 300))),
    }));
}

pub fn zigarProjectProfile(allocator: std.mem.Allocator, context: app_context.ProjectIntelligenceContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return structured(allocator, "zigar_project_profile", "project_profile", pi.projectProfileValue(allocator, context, .{
        .content = argString(args, "content"),
        .apply = argBool(args, "apply", false),
    }));
}

pub fn zigarPatchGuard(allocator: std.mem.Allocator, context: app_context.ProjectIntelligenceContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return structured(allocator, "zigar_patch_guard", "patch_guard", pi.patchGuardValue(allocator, context, .{
        .files = argString(args, "files"),
        .patch = argString(args, "patch"),
    }));
}

pub fn zigImpactSemantic(allocator: std.mem.Allocator, context: app_context.ProjectIntelligenceContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return semanticTool(allocator, context, args, "zig_impact_semantic", false);
}

pub fn zigTestSelectSemantic(allocator: std.mem.Allocator, context: app_context.ProjectIntelligenceContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return semanticTool(allocator, context, args, "zig_test_select_semantic", true);
}

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

pub fn zigarValidationPlan(allocator: std.mem.Allocator, context: app_context.ProjectIntelligenceContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    var parsed = try validationPlanRequestFromArgs(allocator, args);
    defer parsed.deinit(allocator);
    var result = workflows.plan(allocator, context.validation(), parsed.request) catch |err| return workflowError(allocator, "zigar_validation_plan", "plan", err);
    defer result.deinit(allocator);
    return structured(allocator, "zigar_validation_plan", "plan", pi.validationPlanValueFromUsecase(allocator, result));
}

pub fn zigarValidationRun(allocator: std.mem.Allocator, context: app_context.ProjectIntelligenceContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    var parsed = try validationRunRequestFromArgs(allocator, args, timeoutMs(context, args));
    defer parsed.deinit(allocator);
    var outcome = workflows.run(allocator, context.validation(), parsed.request) catch |err| return workflowError(allocator, "zigar_validation_run", "run", err);
    defer outcome.deinit(allocator);
    return switch (outcome) {
        .ok => |report| structured(allocator, "zigar_validation_run", "run", pi.validationRunValue(allocator, report)),
        .err => |failure| switch (failure) {
            .history_write_failed => |details| mcp_errors.workspacePath(allocator, "zigar_validation_run", details.path, context.workspace.root, details.err),
        },
    };
}

pub fn zigBuildEvents(allocator: std.mem.Allocator, context: app_context.ProjectIntelligenceContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return commandEventsTool(allocator, context, args, "zig_build_events", .build);
}

pub fn zigTestEvents(allocator: std.mem.Allocator, context: app_context.ProjectIntelligenceContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return commandEventsTool(allocator, context, args, "zig_test_events", .test_cmd);
}

fn commandEventsTool(allocator: std.mem.Allocator, context: app_context.ProjectIntelligenceContext, args: ?std.json.Value, tool_name: []const u8, kind: pi.EventCommandKind) mcp.tools.ToolError!mcp.tools.ToolResult {
    const extra_args = splitToolArgs(allocator, argString(args, "args")) catch |err| return splitArgsError(allocator, tool_name, err);
    defer freeStringList(allocator, extra_args);
    return structured(allocator, tool_name, "build_events", pi.commandEventsValue(allocator, context, tool_name, .{
        .text = argString(args, "text"),
        .command = argString(args, "command"),
        .file = argString(args, "file"),
        .filter = argString(args, "filter"),
        .extra_args = extra_args,
        .timeout_ms = timeoutMs(context, args),
        .kind = kind,
    }));
}

pub fn zigTestTiming(allocator: std.mem.Allocator, _: app_context.ProjectIntelligenceContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const text = argString(args, "text") orelse return mcp_errors.missingArgument(allocator, "zig_test_timing", "text", "captured Zig test output");
    return structured(allocator, "zig_test_timing", "parse_timing", pi.testTimingValue(allocator, text));
}

pub fn zigarValidationHistory(allocator: std.mem.Allocator, context: app_context.ProjectIntelligenceContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return historyTool(allocator, context, args, "zigar_validation_history", .runs);
}

pub fn zigTestFlakeHistory(allocator: std.mem.Allocator, context: app_context.ProjectIntelligenceContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return historyTool(allocator, context, args, "zig_test_flake_history", .flakes);
}

pub fn zigFailureHistory(allocator: std.mem.Allocator, context: app_context.ProjectIntelligenceContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return historyTool(allocator, context, args, "zig_failure_history", .failures);
}

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

pub fn zigarSessionSnapshot(allocator: std.mem.Allocator, context: app_context.ProjectIntelligenceContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return structured(allocator, "zigar_session_snapshot", "snapshot", pi.sessionSnapshotValue(allocator, context, snapshotRequest(args, "zigar_session_snapshot")));
}

pub fn zigarHandoffPack(allocator: std.mem.Allocator, context: app_context.ProjectIntelligenceContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return structured(allocator, "zigar_handoff_pack", "handoff", pi.handoffPackValue(allocator, context, snapshotRequest(args, "zigar_handoff_pack")));
}

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

pub fn zigarDecisionRecord(allocator: std.mem.Allocator, context: app_context.ProjectIntelligenceContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const title = argString(args, "title") orelse return mcp_errors.missingArgument(allocator, "zigar_decision_record", "title", "short decision title");
    const decision = argString(args, "decision") orelse return mcp_errors.missingArgument(allocator, "zigar_decision_record", "decision", "decision text");
    return structured(allocator, "zigar_decision_record", "decision_record", pi.decisionRecordValue(allocator, context, .{
        .title = title,
        .decision = decision,
        .rationale = argString(args, "rationale"),
        .category = argString(args, "category") orelse "architecture",
        .path = argString(args, "path") orelse pi.memory_path_default,
        .apply = argBool(args, "apply", false),
    }));
}

pub fn zigarProjectNotes(allocator: std.mem.Allocator, context: app_context.ProjectIntelligenceContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return projectMemoryTool(allocator, context, args, "zigar_project_notes", false);
}

pub fn zigarProjectMemory(allocator: std.mem.Allocator, context: app_context.ProjectIntelligenceContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return projectMemoryTool(allocator, context, args, "zigar_project_memory", true);
}

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

pub fn zigarCapabilityMatch(allocator: std.mem.Allocator, _: app_context.ProjectIntelligenceContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const goal = argString(args, "goal") orelse argString(args, "error") orelse argString(args, "diff") orelse return mcp_errors.missingArgument(allocator, "zigar_capability_match", "goal", "goal, error, or diff text");
    const entries = capabilityEntries(allocator) catch return error.OutOfMemory;
    defer allocator.free(entries);
    return structured(allocator, "zigar_capability_match", "capability_match", pi.capabilityMatchValue(allocator, goal, @intCast(@max(1, argInt(args, "limit", 8))), entries));
}

pub fn zigarToolSequencePlan(allocator: std.mem.Allocator, _: app_context.ProjectIntelligenceContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const goal = argString(args, "goal") orelse argString(args, "error") orelse argString(args, "diff") orelse return mcp_errors.missingArgument(allocator, "zigar_tool_sequence_plan", "goal", "goal, error, or diff text");
    return structured(allocator, "zigar_tool_sequence_plan", "sequence_plan", pi.toolSequencePlanValue(allocator, goal, argString(args, "changed_files")));
}

pub const ParsedValidationPlanRequest = struct {
    request: workflows.PlanRequest,
    changed_paths: pi.PathList,

    pub fn deinit(self: *ParsedValidationPlanRequest, allocator: std.mem.Allocator) void {
        self.changed_paths.deinit(allocator);
        self.* = undefined;
    }
};

pub const ParsedValidationRunRequest = struct {
    request: workflows.RunRequest,
    plan: ParsedValidationPlanRequest,

    pub fn deinit(self: *ParsedValidationRunRequest, allocator: std.mem.Allocator) void {
        self.plan.deinit(allocator);
        self.* = undefined;
    }
};

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

pub fn validationRunValue(allocator: std.mem.Allocator, report: workflows.RunReport) !std.json.Value {
    return pi.validationRunValue(allocator, report);
}

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

fn structured(allocator: std.mem.Allocator, tool_name: []const u8, phase: []const u8, value_or_error: anyerror!std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    var value = value_or_error catch |err| return workflowError(allocator, tool_name, phase, err);
    defer deinitTopLevel(allocator, &value);
    return mcp_result.structured(allocator, value);
}

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

fn argActual(_: anyerror) []const u8 {
    return "invalid";
}

fn splitArgsError(allocator: std.mem.Allocator, tool_name: []const u8, err: anyerror) mcp.tools.ToolError!mcp.tools.ToolResult {
    return switch (err) {
        error.InvalidArguments => mcp_errors.invalidArgument(allocator, tool_name, "args", "shell-like argument string", "invalid", "Use balanced quotes and escapes, or omit args for no extra Zig arguments."),
        error.OutOfMemory => error.OutOfMemory,
        else => workflowError(allocator, tool_name, "parse_args", err),
    };
}

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

fn argString(args: ?std.json.Value, name: []const u8) ?[]const u8 {
    return mcp.tools.getString(args, name);
}

fn argBool(args: ?std.json.Value, name: []const u8, default: bool) bool {
    return mcp.tools.getBoolean(args, name) orelse default;
}

fn argInt(args: ?std.json.Value, name: []const u8, default: i64) i64 {
    return mcp.tools.getInteger(args, name) orelse default;
}

fn timeoutMs(context: app_context.ProjectIntelligenceContext, args: ?std.json.Value) i64 {
    return @max(1, @min(argInt(args, "timeout_ms", context.timeouts.command_ms), 60 * 60 * 1000));
}

fn splitToolArgs(allocator: std.mem.Allocator, text_value: ?[]const u8) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    var current: std.ArrayList(u8) = .empty;
    errdefer {
        freeStringList(allocator, list.items);
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

fn finishArg(allocator: std.mem.Allocator, list: *std.ArrayList([]const u8), current: *std.ArrayList(u8)) !void {
    const arg = try current.toOwnedSlice(allocator);
    errdefer allocator.free(arg);
    try list.append(allocator, arg);
}

fn freeStringList(allocator: std.mem.Allocator, values: []const []const u8) void {
    for (values) |value| allocator.free(value);
    allocator.free(values);
}

fn deinitTopLevel(allocator: std.mem.Allocator, value: *std.json.Value) void {
    switch (value.*) {
        .object => |*obj| obj.deinit(allocator),
        else => {},
    }
}

test "project intelligence adapter parses validation run requests" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var args = std.json.ObjectMap.empty;
    try args.put(allocator, "changed_files", .{ .string = "src/main.zig" });
    var parsed = try validationRunRequestFromArgs(allocator, .{ .object = args }, 10_000);
    defer parsed.deinit(allocator);
    try std.testing.expectEqualStrings("src/main.zig", parsed.request.plan.changed_paths[0]);
}
