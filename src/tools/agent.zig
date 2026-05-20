const std = @import("std");
const mcp = @import("mcp");
const zigar = @import("zigar");

const analysis = zigar.analysis;
const command = zigar.command;
const json_result = zigar.json_result;
const common = @import("common.zig");
const static_analysis = @import("static_analysis.zig");
const values = @import("agent_values.zig");

const App = common.App;
const structured = common.structured;
const argString = common.argString;
const argBool = common.argBool;
const argInt = common.argInt;
const missingArgumentResult = common.missingArgumentResult;
const invalidArgumentResult = common.invalidArgumentResult;
const toolErrorFromError = common.toolErrorFromError;
const workspacePathErrorResult = common.workspacePathErrorResult;
const toolTimeout = common.toolTimeout;
const backendErrorResult = common.backendErrorResult;
const ownedString = common.ownedString;
const changedPathList = common.changedPathList;
const appendPathTokens = common.appendPathTokens;
const appendPatchPaths = common.appendPatchPaths;
const freeStringList = common.freeStringList;
const buildExplainCommand = common.buildExplainCommand;
const explainCommandSetupError = common.explainCommandSetupError;
const buildWorkspaceValue = static_analysis.buildWorkspaceValue;
const testMapValue = static_analysis.testMapValue;
const workspacePathExists = static_analysis.workspacePathExists;

pub fn zigarContextPack(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const mode = argString(args, "mode") orelse "standard";
    const token_budget = @max(500, @min(argInt(args, "token_budget", 4000), 50_000));
    const limit: usize = if (std.mem.eql(u8, mode, "tiny")) 40 else if (std.mem.eql(u8, mode, "deep")) 500 else 150;
    const tiny = std.mem.eql(u8, mode, "tiny");
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

    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zigar_context_pack" });
    try obj.put(allocator, "mode", .{ .string = mode });
    try obj.put(allocator, "token_budget", .{ .integer = token_budget });
    try obj.put(allocator, "workspace", try values.contextWorkspaceValue(allocator, a));
    try obj.put(allocator, "project_type", try values.projectTypeValue(allocator, a));
    try obj.put(allocator, "build", buildWorkspaceValue(allocator, a) catch .null);
    if (!tiny) {
        try obj.put(allocator, "tests", testMapValue(allocator, a, @min(limit, 200)) catch .null);
        try obj.put(allocator, "deps", values.dependencyContextValue(allocator, a) catch .null);
    }
    try obj.put(allocator, "source_map", values.sourceMapValue(allocator, a, limit) catch .null);
    try obj.put(allocator, "quality", try values.qualityCommandsValue(allocator, a));
    try obj.put(allocator, "agent_rules", try values.agentRulesValue(allocator, "generic", "any"));
    try obj.put(allocator, "recommended_start", try values.nextActionPlanValue(allocator, "orient", null, null));
    try obj.put(allocator, "included_sections", .{ .array = included });
    try obj.put(allocator, "omitted_sections", .{ .array = omitted });
    try obj.put(allocator, "workflow_contract", try values.workflowContractValue(allocator, "workspace files, build metadata, optional dependency/test summaries, and ZLS status", "orientation pack for routing; not a semantic project proof", if (tiny) "low" else "medium", "mode and token_budget intentionally omit sections; inspect omitted_sections before assuming absence", "zigar_validate_patch", "stop after the selected low-level tool or final validation gate passes", &.{ "zigar_next_action", "zigar_validate_patch" }));
    try obj.put(allocator, "limits", try values.contextLimitsValue(allocator));
    return structured(allocator, .{ .object = obj });
}

pub fn zigarNextAction(_: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const goal = argString(args, "goal") orelse return missingArgumentResult(allocator, "zigar_next_action", "goal", "short task or failure description");
    return structured(allocator, values.nextActionPlanValue(allocator, goal, argString(args, "changed_files"), argString(args, "last_error")) catch return error.OutOfMemory);
}

pub fn zigarAgentGuide(_: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const client = argString(args, "client") orelse "generic";
    const task = argString(args, "task") orelse "any";
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zigar_agent_guide" });
    try obj.put(allocator, "client", .{ .string = client });
    try obj.put(allocator, "task", .{ .string = task });
    try obj.put(allocator, "rules", try values.agentRulesValue(allocator, client, task));
    try obj.put(allocator, "workflows", try values.agentWorkflowHintsValue(allocator, task));
    try obj.put(allocator, "tool_aliases", try values.agentToolAliasesValue(allocator));
    return structured(allocator, .{ .object = obj });
}

pub fn zigarValidatePatch(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const mode = argString(args, "mode") orelse "standard";
    const timeout_ms = toolTimeout(a, args);
    const stop_on_failure = argBool(args, "stop_on_failure", false);
    var paths = changedPathList(allocator, a, argString(args, "changed_files"), timeout_ms) catch return error.OutOfMemory;
    defer paths.deinit(allocator);
    defer freeStringList(allocator, paths.items);

    var phases = std.json.Array.init(allocator);
    var skipped_phases = std.json.Array.init(allocator);
    var files = std.json.Array.init(allocator);
    var ok = true;
    var ran_full_build = false;
    var saw_build_file = false;

    for (paths.items) |path| {
        try files.append(try ownedString(allocator, path));
        if (std.mem.eql(u8, path, "build.zig") or std.mem.eql(u8, path, "build.zig.zon")) saw_build_file = true;
        if (!workspacePathExists(allocator, a, path)) continue;
        if (std.mem.endsWith(u8, path, ".zig") or std.mem.endsWith(u8, path, ".zig.zon")) {
            const fmt_ok = try values.appendValidationPhase(allocator, a, &phases, "format_check", &.{ a.config.zig_path, "fmt", "--check", path }, timeout_ms);
            if (!fmt_ok) {
                ok = false;
                if (stop_on_failure) break;
            }
        }
        if (std.mem.endsWith(u8, path, ".zig")) {
            const check_ok = try values.appendValidationPhase(allocator, a, &phases, "ast_check", &.{ a.config.zig_path, "ast-check", path }, timeout_ms);
            if (!check_ok) {
                ok = false;
                if (stop_on_failure) break;
            }
        }
    }

    if (ok or !stop_on_failure) {
        if (paths.items.len == 0) {
            try values.appendWorkspaceFormatCheckPhase(allocator, a, &phases, timeout_ms, &ok, stop_on_failure);
        }
    }
    if ((ok or !stop_on_failure) and !std.mem.eql(u8, mode, "quick")) {
        if (std.mem.eql(u8, mode, "full") or std.mem.eql(u8, mode, "standard") or saw_build_file or paths.items.len == 0) {
            ran_full_build = true;
            const build_ok = try values.appendValidationPhase(allocator, a, &phases, "build_test", &.{ a.config.zig_path, "build", "test" }, timeout_ms);
            if (!build_ok) ok = false;
        }
    }
    if (!ran_full_build) try skipped_phases.append(try skippedPhaseValue(allocator, "build_test", "mode/path selection or stop_on_failure skipped full build test"));

    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zigar_validate_patch" });
    try obj.put(allocator, "ok", .{ .bool = ok });
    try obj.put(allocator, "mode", .{ .string = mode });
    try obj.put(allocator, "changed_files", .{ .array = files });
    try obj.put(allocator, "phases", .{ .array = phases });
    try obj.put(allocator, "skipped_phases", .{ .array = skipped_phases });
    try obj.put(allocator, "ran_full_build_test", .{ .bool = ran_full_build });
    try obj.put(allocator, "workflow_contract", try values.workflowContractValue(allocator, "git/status changed files or user-supplied changed_files plus command exit status", "patch readiness from selected validation phases", if (ran_full_build) "high" else "medium", "quick mode and stop_on_failure can skip later phases; inspect skipped_phases", "rerun failed phase or run zigar_validate_patch mode=full", "stop when all selected phases pass", &.{ "zigar_failure_fusion", "zigar_validate_patch" }));
    try obj.put(allocator, "next_action", try values.validationNextActionValue(allocator, ok, phases));
    return structured(allocator, .{ .object = obj });
}

fn skippedPhaseValue(allocator: std.mem.Allocator, name: []const u8, reason: []const u8) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "name", .{ .string = name });
    try obj.put(allocator, "reason", .{ .string = reason });
    return .{ .object = obj };
}

pub fn zigarFailureFusion(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    if (argString(args, "text")) |raw_text| {
        return structured(allocator, values.failureFusionValue(allocator, raw_text, "", &.{ "zig", "build", "test" }, false) catch return error.OutOfMemory);
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
    return structured(allocator, values.failureFusionValue(allocator, result.stderr, result.stdout, list.argv.items, result.succeeded()) catch return error.OutOfMemory);
}

pub fn zigarImpact(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return structured(allocator, values.impactValue(allocator, a, argString(args, "files"), argString(args, "symbols"), @intCast(@max(1, argInt(args, "limit", 300)))) catch return error.OutOfMemory);
}

pub fn zigarProjectProfile(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const profile_path = ".zigar/profile.json";
    const generated = if (argString(args, "content")) |content| blk: {
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{}) catch return invalidArgumentResult(allocator, "zigar_project_profile", "content", "valid JSON object", "invalid_json", "Pass a JSON object produced by zigar_project_profile or omit content to regenerate the profile.");
        defer parsed.deinit();
        break :blk json_result.cloneValue(allocator, parsed.value) catch return error.OutOfMemory;
    } else try values.generatedProjectProfileValue(allocator, a);

    const apply = argBool(args, "apply", false);
    if (apply) {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(allocator);
        try json_result.serializeValue(allocator, &out, generated);
        a.workspace.writeFile(a.io, profile_path, out.items) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.PathOutsideWorkspace, error.EmptyPath, error.AccessDenied, error.PermissionDenied => return workspacePathErrorResult(a, allocator, "zigar_project_profile", profile_path, err),
            else => return toolErrorFromError(allocator, .{
                .tool = "zigar_project_profile",
                .operation = "write_project_profile",
                .phase = "workspace_write",
                .code = "write_failed",
                .category = "filesystem",
                .resolution = "Confirm .zigar/profile.json can be created or overwritten inside the workspace, then retry with apply=true.",
                .details = &.{.{ .key = "path", .value = .{ .string = profile_path } }},
            }, err),
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

pub fn zigarPatchGuard(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
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
