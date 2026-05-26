//! Transactional-editing MCP adapters for patch sessions, previews, commits,
//! rollback, and edit history.
const std = @import("std");
const mcp = @import("mcp");

const app_context = @import("../../../app/context.zig");
const editing = @import("../../../app/usecases/editing/patch_sessions.zig");
const editing_workflows = @import("../../../app/usecases/editing/workflows.zig");
const validation_workflows = @import("../../../app/usecases/validation/workflows.zig");
const validation_adapter = @import("project_intelligence.zig");
const mcp_errors = @import("../errors.zig");
const mcp_result = @import("../result.zig");

/// Handles MCP `zigar_patch_session_create` requests by delegating to app logic and shaping owned results/errors.
pub fn zigarPatchSessionCreate(allocator: std.mem.Allocator, context: app_context.Context, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    var paths = std.ArrayList([]const u8).empty;
    defer paths.deinit(scratch);
    try appendPathTokens(scratch, &paths, argString(args, "files"));
    try appendPatchPaths(scratch, &paths, argString(args, "patch"));
    if (argString(args, "edits")) |raw| try appendEditPaths(scratch, &paths, raw);
    const ctx = context.editing() catch |err| return transactionalError(allocator, "zigar_patch_session_create", "build_app_context", err);
    var result = editing.create(scratch, ctx, .{
        .session_id = try sessionId(scratch, "create", argString(args, "goal"), argString(args, "files"), argString(args, "patch"), argString(args, "edits")),
        .goal = argString(args, "goal"),
        .paths = paths.items,
    }) catch |err| return transactionalError(allocator, "zigar_patch_session_create", "create_session", err);
    defer result.deinit(scratch);
    return structuredScratch(allocator, scratch, try patchSessionCreateValue(scratch, result));
}

/// Handles MCP `zigar_patch_session_preview` requests by delegating to app logic and shaping owned results/errors.
pub fn zigarPatchSessionPreview(allocator: std.mem.Allocator, context: app_context.Context, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return patchSessionReplacementTool(allocator, context, args, "zigar_patch_session_preview", false);
}

/// Handles MCP `zigar_patch_session_apply` requests by delegating to app logic and shaping owned results/errors.
pub fn zigarPatchSessionApply(allocator: std.mem.Allocator, context: app_context.Context, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return patchSessionReplacementTool(allocator, context, args, "zigar_patch_session_apply", argBool(args, "apply", false));
}

/// Handles MCP `zigar_patch_session_validate` requests by delegating to app logic and shaping owned results/errors.
pub fn zigarPatchSessionValidate(allocator: std.mem.Allocator, context: app_context.Context, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const validation_args = try validationArgsFromSessionArgs(scratch, args);
    var parsed = validation_adapter.validationRunRequestFromArgs(scratch, validation_args, timeoutMs(context, args)) catch |err| return transactionalError(allocator, "zigar_patch_session_validate", "parse_validation_request", err);
    defer parsed.deinit(scratch);
    var outcome = editing.validate(scratch, context.validation() catch |err| return transactionalError(allocator, "zigar_patch_session_validate", "build_validation_context", err), parsed.request) catch |err| return transactionalError(allocator, "zigar_patch_session_validate", "run_validation", err);
    defer outcome.deinit(scratch);
    const report = switch (outcome) {
        .ok => |value| value,
        .err => return transactionalError(allocator, "zigar_patch_session_validate", "run_validation", error.ValidationHistoryWriteFailed),
    };
    var obj = std.json.ObjectMap.empty;
    try obj.put(scratch, "kind", .{ .string = "zigar_patch_session_validate" });
    try obj.put(scratch, "schema_version", .{ .integer = editing.schema_version });
    try obj.put(scratch, "session_id", try optionalStringValue(scratch, argString(args, "session_id")));
    try obj.put(scratch, "ok", .{ .bool = report.ok });
    try obj.put(scratch, "validation", try validation_adapter.validationRunValue(scratch, report));
    try obj.put(scratch, "stop_condition", .{ .string = "Treat skipped validation phases as unknown; rollback remains available only for recorded applied sessions." });
    return structuredScratch(allocator, scratch, .{ .object = obj });
}

/// Handles MCP `zigar_patch_session_revert` requests by delegating to app logic and shaping owned results/errors.
pub fn zigarPatchSessionRevert(allocator: std.mem.Allocator, context: app_context.Context, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const session_id = argString(args, "session_id") orelse return mcp_errors.missingArgument(allocator, "zigar_patch_session_revert", "session_id", "recorded patch session id");
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    var outcome = editing.revert(scratch, context.editing() catch |err| return transactionalError(allocator, "zigar_patch_session_revert", "build_app_context", err), .{
        .session_id = session_id,
        .apply = argBool(args, "apply", false),
        .history = argString(args, "history"),
        .history_path = argString(args, "history_path") orelse editing.history_path_default,
    }) catch |err| return transactionalError(allocator, "zigar_patch_session_revert", "revert_session", err);
    defer outcome.deinit(scratch);
    return switch (outcome) {
        .ok => |result| structuredScratch(allocator, scratch, try patchSessionRevertValue(scratch, result)),
        .err => sessionNotFound(allocator, session_id),
    };
}

/// Handles MCP `zig_generated_file_trace` requests by delegating to app logic and shaping owned results/errors.
pub fn zigGeneratedFileTrace(allocator: std.mem.Allocator, context: app_context.Context, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const path = argString(args, "path") orelse return mcp_errors.missingArgument(allocator, "zig_generated_file_trace", "path", "workspace-relative path");
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    return structuredScratch(allocator, scratch, editing_workflows.generatedFileTraceValue(scratch, context.editing() catch |err| return transactionalError(allocator, "zig_generated_file_trace", "build_app_context", err), path) catch |err| return transactionalError(allocator, "zig_generated_file_trace", "run_workflow", err));
}

/// Handles MCP `zigar_edit_policy_check` requests by delegating to app logic and shaping owned results/errors.
pub fn zigarEditPolicyCheck(allocator: std.mem.Allocator, _: app_context.Context, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    var paths = std.ArrayList([]const u8).empty;
    defer paths.deinit(scratch);
    try appendPathTokens(scratch, &paths, argString(args, "files"));
    try appendPatchPaths(scratch, &paths, argString(args, "patch"));
    return structuredScratch(allocator, scratch, try editing_workflows.editPolicyCheckValue(scratch, paths.items));
}

/// Handles MCP `zigar_generated_route` requests by delegating to app logic and shaping owned results/errors.
pub fn zigarGeneratedRoute(allocator: std.mem.Allocator, context: app_context.Context, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const path = argString(args, "path") orelse return mcp_errors.missingArgument(allocator, "zigar_generated_route", "path", "workspace-relative generated or vendored path");
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    return structuredScratch(allocator, scratch, editing_workflows.generatedRouteValue(scratch, context.editing() catch |err| return transactionalError(allocator, "zigar_generated_route", "build_app_context", err), path, argString(args, "goal")) catch |err| return transactionalError(allocator, "zigar_generated_route", "run_workflow", err));
}

/// Handles MCP `zig_organize_imports` requests by delegating to app logic and shaping owned results/errors.
pub fn zigOrganizeImports(allocator: std.mem.Allocator, context: app_context.Context, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const file = argString(args, "file") orelse return mcp_errors.missingArgument(allocator, "zig_organize_imports", "file", "workspace-relative Zig file");
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    return structuredScratch(allocator, scratch, editing_workflows.organizeImportsValue(scratch, context.editing() catch |err| return transactionalError(allocator, "zig_organize_imports", "build_app_context", err), file, argBool(args, "apply", false)) catch |err| return transactionalError(allocator, "zig_organize_imports", "run_workflow", err));
}

/// Handles MCP `zig_update_imports` requests by delegating to app logic and shaping owned results/errors.
pub fn zigUpdateImports(allocator: std.mem.Allocator, context: app_context.Context, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const old_import = argString(args, "old_import") orelse return mcp_errors.missingArgument(allocator, "zig_update_imports", "old_import", "existing @import string");
    const new_import = argString(args, "new_import") orelse return mcp_errors.missingArgument(allocator, "zig_update_imports", "new_import", "replacement @import string");
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    var files = std.ArrayList([]const u8).empty;
    defer files.deinit(scratch);
    try appendPathTokens(scratch, &files, argString(args, "files"));
    if (argString(args, "file")) |file| try appendUniqueString(scratch, &files, file);
    if (files.items.len == 0) return mcp_errors.missingArgument(allocator, "zig_update_imports", "files", "one or more Zig files");
    return structuredScratch(allocator, scratch, editing_workflows.updateImportsValue(scratch, context.editing() catch |err| return transactionalError(allocator, "zig_update_imports", "build_app_context", err), files.items, old_import, new_import, argBool(args, "apply", false)) catch |err| return transactionalError(allocator, "zig_update_imports", "run_workflow", err));
}

/// Handles MCP `zig_move_decl` requests by delegating to app logic and shaping owned results/errors.
pub fn zigMoveDecl(allocator: std.mem.Allocator, context: app_context.Context, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const source_file = argString(args, "source_file") orelse return mcp_errors.missingArgument(allocator, "zig_move_decl", "source_file", "workspace-relative source file");
    const target_file = argString(args, "target_file") orelse return mcp_errors.missingArgument(allocator, "zig_move_decl", "target_file", "workspace-relative target file");
    const name = argString(args, "name") orelse return mcp_errors.missingArgument(allocator, "zig_move_decl", "name", "top-level declaration name");
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    return structuredScratch(allocator, scratch, editing_workflows.moveDeclValue(scratch, context.editing() catch |err| return transactionalError(allocator, "zig_move_decl", "build_app_context", err), source_file, target_file, name, argBool(args, "apply", false)) catch |err| return transactionalError(allocator, "zig_move_decl", "run_workflow", err));
}

/// Handles MCP `zig_extract_decl` requests by delegating to app logic and shaping owned results/errors.
pub fn zigExtractDecl(allocator: std.mem.Allocator, context: app_context.Context, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const file = argString(args, "file") orelse return mcp_errors.missingArgument(allocator, "zig_extract_decl", "file", "workspace-relative source file");
    const target_file = argString(args, "target_file") orelse return mcp_errors.missingArgument(allocator, "zig_extract_decl", "target_file", "workspace-relative target file");
    const start_line = argInt(args, "start_line", 0);
    const end_line = argInt(args, "end_line", 0);
    if (start_line <= 0 or end_line < start_line) return mcp_errors.invalidArgument(allocator, "zig_extract_decl", "start_line/end_line", "1-based inclusive line range", "invalid_range", "Provide start_line >= 1 and end_line >= start_line.");
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    return structuredScratch(allocator, scratch, editing_workflows.extractDeclValue(scratch, context.editing() catch |err| return transactionalError(allocator, "zig_extract_decl", "build_app_context", err), file, target_file, @intCast(start_line), @intCast(end_line), argBool(args, "apply", false)) catch |err| return transactionalError(allocator, "zig_extract_decl", "run_workflow", err));
}

/// Handles MCP `zig_code_action_batch` requests by delegating to app logic and shaping owned results/errors.
pub fn zigCodeActionBatch(allocator: std.mem.Allocator, context: app_context.Context, _: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    if (!context.zls_state.running) return backendUnavailableResult(allocator, "zls", "zig_code_action_batch", context.tool_paths.zls, context.zls_state.status, "Start or repair ZLS, then retry code action batching.");
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    return structuredScratch(allocator, scratch, editing_workflows.codeActionBatchUnavailableValue(scratch) catch |err| return transactionalError(allocator, "zig_code_action_batch", "run_workflow", err));
}

fn patchSessionReplacementTool(allocator: std.mem.Allocator, context: app_context.Context, args: ?std.json.Value, tool_name: []const u8, apply: bool) mcp.tools.ToolError!mcp.tools.ToolResult {
    const raw_edits = argString(args, "edits") orelse return mcp_errors.missingArgument(allocator, tool_name, "edits", "JSON array of {file, content} replacements");
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    var parsed = std.json.parseFromSlice(std.json.Value, scratch, raw_edits, .{}) catch return mcp_errors.invalidArgument(allocator, tool_name, "edits", "valid JSON array or object", "invalid_json", "Pass edits as JSON, for example [{\"file\":\"src/main.zig\",\"content\":\"...\"}].");
    defer parsed.deinit();
    var replacements = std.ArrayList(editing.Replacement).empty;
    defer replacements.deinit(scratch);
    try collectReplacements(scratch, &replacements, parsed.value);
    const expected = parseExpectedPreimages(scratch, argString(args, "expected_preimages")) catch |err| return transactionalError(allocator, tool_name, "parse_expected_preimages", err);
    var result = editing.replacementSession(scratch, context.editing() catch |err| return transactionalError(allocator, tool_name, "build_app_context", err), .{
        .operation = if (apply) .apply else .preview,
        .session_id = if (argString(args, "session_id")) |id| id else try sessionId(scratch, tool_name, argString(args, "goal"), null, null, raw_edits),
        .goal = argString(args, "goal"),
        .replacements = replacements.items,
        .expected_preimages = expected,
        .apply = apply,
    }) catch |err| return transactionalError(allocator, tool_name, "build_session", err);
    defer result.deinit(scratch);
    return structuredScratch(allocator, scratch, try patchSessionReplacementValue(scratch, result));
}

fn patchSessionCreateValue(allocator: std.mem.Allocator, result: editing.CreateResult) !std.json.Value {
    var files = std.json.Array.init(allocator);
    for (result.files) |file| {
        try files.append(switch (file) {
            .ok => |state| try sessionFileStateValue(allocator, state),
            .err => |failure| try pathFailureNameValue(allocator, failure.file, failure.error_name),
        });
    }
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "kind", .{ .string = "zigar_patch_session_create" });
    try obj.put(allocator, "schema_version", .{ .integer = editing.schema_version });
    try obj.put(allocator, "session_id", try ownedString(allocator, result.session_id));
    try obj.put(allocator, "goal", try optionalStringValue(allocator, result.goal));
    try obj.put(allocator, "status", .{ .string = "created" });
    try obj.put(allocator, "safe_to_edit", .{ .bool = result.safe_to_edit });
    try obj.put(allocator, "files", .{ .array = files });
    try obj.put(allocator, "expected_preimages", try expectedPreimagesValue(allocator, result.expected_preimages));
    try obj.put(allocator, "next_action", try nextToolValue(allocator, if (result.safe_to_edit) "zigar_patch_session_preview" else "zigar_generated_route", if (result.safe_to_edit) "preview replacement content before applying" else "route generated or vendored paths to source/regeneration"));
    try obj.put(allocator, "limitations", .{ .string = "Session creation captures current file identity and policy only; no source writes or validation commands have run." });
    return .{ .object = obj };
}

fn patchSessionReplacementValue(allocator: std.mem.Allocator, result: editing.ReplacementResult) !std.json.Value {
    var files = std.json.Array.init(allocator);
    for (result.files) |file| try files.append(try replacementFileValue(allocator, file));
    if (result.blocked) return applyBlockedValue(allocator, result.session_id, files, result.expected_preimages);
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "kind", .{ .string = result.operation.kind() });
    try obj.put(allocator, "schema_version", .{ .integer = editing.schema_version });
    try obj.put(allocator, "session_id", try ownedString(allocator, result.session_id));
    try obj.put(allocator, "goal", try optionalStringValue(allocator, result.goal));
    try obj.put(allocator, "applied", .{ .bool = result.applied });
    try obj.put(allocator, "requires_apply", .{ .bool = result.requires_apply });
    try obj.put(allocator, "safe_to_apply", .{ .bool = result.safe_to_apply });
    try obj.put(allocator, "changed_file_count", .{ .integer = @intCast(result.changed_file_count) });
    try obj.put(allocator, "files", .{ .array = files });
    try obj.put(allocator, "expected_preimages", try expectedPreimagesValue(allocator, result.expected_preimages));
    try obj.put(allocator, "history_path", .{ .string = editing.history_path_default });
    try obj.put(allocator, "limitations", .{ .string = "Apply requires expected_preimages from preview and refuses generated/vendor paths; validation must be run separately or through zigar_patch_session_validate." });
    return .{ .object = obj };
}

fn patchSessionRevertValue(allocator: std.mem.Allocator, result: editing.RevertResult) !std.json.Value {
    var files = std.json.Array.init(allocator);
    for (result.files) |file| try files.append(try revertFileValue(allocator, file));
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "kind", .{ .string = "zigar_patch_session_revert" });
    try obj.put(allocator, "schema_version", .{ .integer = editing.schema_version });
    try obj.put(allocator, "session_id", try ownedString(allocator, result.session_id));
    try obj.put(allocator, "applied", .{ .bool = result.applied });
    try obj.put(allocator, "requires_apply", .{ .bool = result.requires_apply });
    try obj.put(allocator, "safe_to_revert", .{ .bool = result.safe_to_revert });
    try obj.put(allocator, "files", .{ .array = files });
    try obj.put(allocator, "record", try sessionRecordValue(allocator, result.record));
    try obj.put(allocator, "limitations", .{ .string = "Rollback restores only files whose current hash still equals the recorded session output hash; unrelated edits block the revert." });
    return .{ .object = obj };
}

fn sessionFileStateValue(allocator: std.mem.Allocator, state: editing.SessionFileState) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "file", try ownedString(allocator, state.file));
    try obj.put(allocator, "preimage_identity", try identityValue(allocator, state.preimage_identity));
    try obj.put(allocator, "policy", try policyValue(allocator, state.policy));
    return .{ .object = obj };
}

fn replacementFileValue(allocator: std.mem.Allocator, file: editing.ReplacementFile) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "file", try ownedString(allocator, file.file));
    try obj.put(allocator, "changed", .{ .bool = file.changed });
    try obj.put(allocator, "preimage_identity", try identityValue(allocator, file.preimage_identity));
    try obj.put(allocator, "updated_identity", try identityValue(allocator, file.updated_identity));
    try obj.put(allocator, "policy", try policyValue(allocator, file.policy));
    try obj.put(allocator, "expected_preimage_matched", .{ .bool = file.expected_preimage_matched });
    try obj.put(allocator, "diff", try ownedString(allocator, file.diff));
    return .{ .object = obj };
}

fn revertFileValue(allocator: std.mem.Allocator, file: editing.RevertFile) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "file", try ownedString(allocator, file.file));
    try obj.put(allocator, "safe_to_revert", .{ .bool = file.safe_to_revert });
    try obj.put(allocator, "current_matches_session_output", .{ .bool = file.current_matches_session_output });
    try obj.put(allocator, "current_identity", try identityValue(allocator, file.current_identity));
    try obj.put(allocator, "target_preimage_identity", try identityValue(allocator, file.target_preimage_identity));
    try obj.put(allocator, "preimage_content_path", try optionalStringValue(allocator, file.preimage_content_path));
    try obj.put(allocator, "would_delete", .{ .bool = file.would_delete });
    try obj.put(allocator, "diff", try ownedString(allocator, file.diff));
    return .{ .object = obj };
}

fn sessionRecordValue(allocator: std.mem.Allocator, record: editing.SessionRecord) !std.json.Value {
    var files = std.json.Array.init(allocator);
    for (record.files) |file| {
        var item = std.json.ObjectMap.empty;
        try item.put(allocator, "file", try ownedString(allocator, file.file));
        try item.put(allocator, "preimage_identity", try identityValue(allocator, file.preimage_identity));
        try item.put(allocator, "updated_identity", try identityValue(allocator, file.updated_identity));
        try item.put(allocator, "preimage_content_path", try optionalStringValue(allocator, file.preimage_content_path));
        try files.append(.{ .object = item });
    }
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "kind", .{ .string = "zigar_patch_session_record" });
    try obj.put(allocator, "schema_version", .{ .integer = editing.schema_version });
    try obj.put(allocator, "session_id", try ownedString(allocator, record.session_id));
    try obj.put(allocator, "goal", try optionalStringValue(allocator, record.goal));
    try obj.put(allocator, "recorded_unix_ms", .{ .integer = record.recorded_unix_ms });
    try obj.put(allocator, "files", .{ .array = files });
    return .{ .object = obj };
}

fn identityValue(allocator: std.mem.Allocator, identity: editing.Identity) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "exists", .{ .bool = identity.exists });
    try obj.put(allocator, "bytes", .{ .integer = @intCast(identity.bytes) });
    try obj.put(allocator, "sha256", if (identity.sha256) |hash| try ownedString(allocator, hash) else .null);
    return .{ .object = obj };
}

fn expectedPreimagesValue(allocator: std.mem.Allocator, expected: []const editing.ExpectedPreimage) !std.json.Value {
    var array = std.json.Array.init(allocator);
    for (expected) |item| {
        var obj = std.json.ObjectMap.empty;
        try obj.put(allocator, "file", try ownedString(allocator, item.file));
        try obj.put(allocator, "exists", .{ .bool = item.identity.exists });
        try obj.put(allocator, "bytes", .{ .integer = @intCast(item.identity.bytes) });
        try obj.put(allocator, "sha256", if (item.identity.sha256) |hash| try ownedString(allocator, hash) else .null);
        try array.append(.{ .object = obj });
    }
    return .{ .array = array };
}

fn policyValue(allocator: std.mem.Allocator, policy: editing.PathPolicy) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "classification", try ownedString(allocator, policy.classification));
    try obj.put(allocator, "direct_edit_allowed", .{ .bool = policy.direct_edit_allowed });
    try obj.put(allocator, "reason", try ownedString(allocator, policy.reason));
    try obj.put(allocator, "route", try ownedString(allocator, policy.route));
    try obj.put(allocator, "source_candidates", try stringArrayValue(allocator, policy.sources));
    try obj.put(allocator, "regeneration_commands", try stringArrayValue(allocator, policy.commands));
    try obj.put(allocator, "confidence", try ownedString(allocator, policy.confidence));
    return .{ .object = obj };
}

fn applyBlockedValue(allocator: std.mem.Allocator, session_id: []const u8, files: std.json.Array, expected_preimages: []const editing.ExpectedPreimage) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "kind", .{ .string = "zigar_patch_session_apply" });
    try obj.put(allocator, "schema_version", .{ .integer = editing.schema_version });
    try obj.put(allocator, "session_id", try ownedString(allocator, session_id));
    try obj.put(allocator, "applied", .{ .bool = false });
    try obj.put(allocator, "safe_to_apply", .{ .bool = false });
    try obj.put(allocator, "files", .{ .array = files });
    try obj.put(allocator, "expected_preimages", try expectedPreimagesValue(allocator, expected_preimages));
    try obj.put(allocator, "resolution", .{ .string = "Re-run preview, pass its expected_preimages unchanged, and avoid generated or vendored paths." });
    return .{ .object = obj };
}

fn parseExpectedPreimages(allocator: std.mem.Allocator, raw: ?[]const u8) ![]const editing.ExpectedPreimage {
    const text = raw orelse return &.{};
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, text, .{});
    defer parsed.deinit();
    const array = switch (parsed.value) {
        .array => |items| items,
        else => return error.InvalidArguments,
    };
    var out = std.ArrayList(editing.ExpectedPreimage).empty;
    for (array.items) |item| {
        const obj = switch (item) {
            .object => |value| value,
            else => return error.InvalidArguments,
        };
        try out.append(allocator, .{
            .file = try allocator.dupe(u8, stringField(obj, "file") orelse return error.InvalidArguments),
            .identity = .{
                .exists = boolField(obj, "exists") orelse false,
                .bytes = @intCast(integerField(obj, "bytes") orelse 0),
                .sha256 = switch (obj.get("sha256") orelse .null) {
                    .string => |hash| try allocator.dupe(u8, hash),
                    else => null,
                },
            },
        });
    }
    return out.toOwnedSlice(allocator);
}

fn collectReplacements(allocator: std.mem.Allocator, replacements: *std.ArrayList(editing.Replacement), value: std.json.Value) !void {
    switch (value) {
        .array => |array| for (array.items) |item| try appendReplacement(allocator, replacements, item),
        .object => |obj| {
            if (obj.get("files")) |files| {
                const array = switch (files) {
                    .array => |a| a,
                    else => return error.InvalidArguments,
                };
                for (array.items) |item| try appendReplacement(allocator, replacements, item);
            } else try appendReplacement(allocator, replacements, value);
        },
        else => return error.InvalidArguments,
    }
}

fn appendReplacement(allocator: std.mem.Allocator, replacements: *std.ArrayList(editing.Replacement), value: std.json.Value) !void {
    const obj = switch (value) {
        .object => |o| o,
        else => return error.InvalidArguments,
    };
    try replacements.append(allocator, .{
        .file = stringField(obj, "file") orelse stringField(obj, "path") orelse return error.InvalidArguments,
        .content = stringField(obj, "content") orelse return error.InvalidArguments,
    });
}

fn validationArgsFromSessionArgs(allocator: std.mem.Allocator, args: ?std.json.Value) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    inline for (.{ "mode", "changed_files", "diff", "goal", "output" }) |field| {
        if (argString(args, field)) |value| try obj.put(allocator, field, try ownedString(allocator, value));
    }
    inline for (.{ "include_semantic", "stop_on_failure", "apply" }) |field| {
        if (argBoolOptional(args, field)) |value| try obj.put(allocator, field, .{ .bool = value });
    }
    if (argIntOptional(args, "timeout_ms")) |value| try obj.put(allocator, "timeout_ms", .{ .integer = value });
    if (obj.get("changed_files") == null) {
        var paths = std.ArrayList([]const u8).empty;
        defer paths.deinit(allocator);
        if (argString(args, "edits")) |raw| try appendEditPaths(allocator, &paths, raw);
        if (paths.items.len > 0) try obj.put(allocator, "changed_files", try joinedStringsValue(allocator, paths.items));
    }
    return .{ .object = obj };
}

fn appendEditPaths(allocator: std.mem.Allocator, paths: *std.ArrayList([]const u8), raw_edits: []const u8) !void {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, raw_edits, .{}) catch return;
    defer parsed.deinit();
    var replacements = std.ArrayList(editing.Replacement).empty;
    defer replacements.deinit(allocator);
    try collectReplacements(allocator, &replacements, parsed.value);
    for (replacements.items) |replacement| try appendUniqueString(allocator, paths, replacement.file);
}

fn appendPathTokens(allocator: std.mem.Allocator, paths: *std.ArrayList([]const u8), maybe_text: ?[]const u8) !void {
    const text = maybe_text orelse return;
    var it = std.mem.tokenizeAny(u8, text, " \t\r\n,");
    while (it.next()) |path| try appendUniqueString(allocator, paths, path);
}

fn appendPatchPaths(allocator: std.mem.Allocator, paths: *std.ArrayList([]const u8), maybe_patch: ?[]const u8) !void {
    const patch = maybe_patch orelse return;
    var lines = std.mem.splitScalar(u8, patch, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "+++ b/")) try appendUniqueString(allocator, paths, line[6..]);
        if (std.mem.startsWith(u8, line, "--- a/")) try appendUniqueString(allocator, paths, line[6..]);
    }
}

fn appendUniqueString(allocator: std.mem.Allocator, values: *std.ArrayList([]const u8), value: []const u8) !void {
    for (values.items) |existing| if (std.mem.eql(u8, existing, value)) return;
    try values.append(allocator, try allocator.dupe(u8, value));
}

fn sessionId(allocator: std.mem.Allocator, prefix: []const u8, goal: ?[]const u8, a: ?[]const u8, b: ?[]const u8, c: ?[]const u8) ![]const u8 {
    var seed = std.ArrayList(u8).empty;
    defer seed.deinit(allocator);
    try seed.appendSlice(allocator, prefix);
    if (goal) |value| try seed.appendSlice(allocator, value);
    if (a) |value| try seed.appendSlice(allocator, value);
    if (b) |value| try seed.appendSlice(allocator, value);
    if (c) |value| try seed.appendSlice(allocator, value);
    const hex = try sha256Hex(allocator, seed.items);
    return std.fmt.allocPrint(allocator, "session-{s}", .{hex[0..16]});
}

fn structuredScratch(allocator: std.mem.Allocator, scratch: std.mem.Allocator, value: std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    _ = scratch;
    return mcp_result.structured(allocator, value);
}

fn transactionalError(allocator: std.mem.Allocator, tool_name: []const u8, phase: []const u8, err: anyerror) mcp.tools.ToolError!mcp.tools.ToolResult {
    if (err == error.OutOfMemory) return error.OutOfMemory;
    if (err == error.InvalidArguments) return mcp_errors.invalidArgument(allocator, tool_name, null, "valid transactional editing arguments", "invalid", "Inspect the tool inputSchema and retry with supported arguments.");
    if (err == error.PathOutsideWorkspace or err == error.EmptyPath) return mcp_errors.workspacePath(allocator, tool_name, "", "", err);
    return mcp_errors.fromError(allocator, .{
        .tool = tool_name,
        .operation = "transactional_editing",
        .phase = phase,
        .code = "transactional_editing_failed",
        .category = "transactional_editing",
        .resolution = "Inspect structured fields, fix invalid arguments or workspace state, then retry.",
    }, err);
}

fn backendUnavailableResult(allocator: std.mem.Allocator, backend_name: []const u8, operation: []const u8, configured_path: []const u8, status: []const u8, resolution: []const u8) mcp.tools.ToolError!mcp.tools.ToolResult {
    var obj = std.json.ObjectMap.empty;
    defer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "backend_error" });
    try obj.put(allocator, "ok", .{ .bool = false });
    try obj.put(allocator, "backend", .{ .string = backend_name });
    try obj.put(allocator, "operation", .{ .string = operation });
    try obj.put(allocator, "error", .{ .string = "Unavailable" });
    try obj.put(allocator, "error_kind", .{ .string = "unavailable" });
    try obj.put(allocator, "configured_path", .{ .string = configured_path });
    try obj.put(allocator, "status", .{ .string = status });
    try obj.put(allocator, "resolution", .{ .string = resolution });
    return mcp_result.structured(allocator, .{ .object = obj });
}

fn sessionNotFound(allocator: std.mem.Allocator, session_id: []const u8) mcp.tools.ToolError!mcp.tools.ToolResult {
    var obj = std.json.ObjectMap.empty;
    defer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zigar_patch_session_revert" });
    try obj.put(allocator, "ok", .{ .bool = false });
    try obj.put(allocator, "session_id", .{ .string = session_id });
    try obj.put(allocator, "error_kind", .{ .string = "not_found" });
    try obj.put(allocator, "resolution", .{ .string = "Pass history/history_path containing a zigar_patch_session_record emitted by zigar_patch_session_apply apply=true." });
    return mcp_result.structured(allocator, .{ .object = obj });
}

fn optionalStringValue(allocator: std.mem.Allocator, value: ?[]const u8) !std.json.Value {
    if (value) |text| return ownedString(allocator, text);
    return .null;
}

fn ownedString(allocator: std.mem.Allocator, text: []const u8) !std.json.Value {
    return .{ .string = try allocator.dupe(u8, text) };
}

fn stringArrayValue(allocator: std.mem.Allocator, values: []const []const u8) !std.json.Value {
    var array = std.json.Array.init(allocator);
    for (values) |value| try array.append(try ownedString(allocator, value));
    return .{ .array = array };
}

fn joinedStringsValue(allocator: std.mem.Allocator, values: []const []const u8) !std.json.Value {
    var out = std.ArrayList(u8).empty;
    for (values, 0..) |value, index| {
        if (index > 0) try out.append(allocator, ' ');
        try out.appendSlice(allocator, value);
    }
    return .{ .string = try out.toOwnedSlice(allocator) };
}

fn nextToolValue(allocator: std.mem.Allocator, tool: []const u8, reason: []const u8) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "tool", try ownedString(allocator, tool));
    try obj.put(allocator, "reason", try ownedString(allocator, reason));
    return .{ .object = obj };
}

fn pathFailureNameValue(allocator: std.mem.Allocator, path: []const u8, error_name: []const u8) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "file", try ownedString(allocator, path));
    try obj.put(allocator, "ok", .{ .bool = false });
    try obj.put(allocator, "error", try ownedString(allocator, error_name));
    return .{ .object = obj };
}

fn stringField(obj: std.json.ObjectMap, field: []const u8) ?[]const u8 {
    return switch (obj.get(field) orelse .null) {
        .string => |s| s,
        else => null,
    };
}

fn boolField(obj: std.json.ObjectMap, field: []const u8) ?bool {
    return switch (obj.get(field) orelse .null) {
        .bool => |b| b,
        else => null,
    };
}

fn integerField(obj: std.json.ObjectMap, field: []const u8) ?i64 {
    return switch (obj.get(field) orelse .null) {
        .integer => |i| i,
        else => null,
    };
}

fn argString(args: ?std.json.Value, name: []const u8) ?[]const u8 {
    const obj = switch (args orelse return null) {
        .object => |o| o,
        else => return null,
    };
    return stringField(obj, name);
}

fn argBool(args: ?std.json.Value, name: []const u8, default: bool) bool {
    return argBoolOptional(args, name) orelse default;
}

fn argBoolOptional(args: ?std.json.Value, name: []const u8) ?bool {
    const obj = switch (args orelse return null) {
        .object => |o| o,
        else => return null,
    };
    return boolField(obj, name);
}

fn argInt(args: ?std.json.Value, name: []const u8, default: i64) i64 {
    return argIntOptional(args, name) orelse default;
}

fn argIntOptional(args: ?std.json.Value, name: []const u8) ?i64 {
    const obj = switch (args orelse return null) {
        .object => |o| o,
        else => return null,
    };
    return integerField(obj, name);
}

fn timeoutMs(context: app_context.Context, args: ?std.json.Value) i64 {
    return @max(1, @min(argInt(args, "timeout_ms", context.timeouts.command_ms), 60 * 60 * 1000));
}

fn sha256Hex(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    return allocator.dupe(u8, &hex);
}

const fakes = @import("../../../testing/fakes/root.zig");

test "transactional editing adapter covers create validate revert and code action flows" {
    const allocator = std.testing.allocator;
    var commands = fakes.FakeCommandRunner.init(allocator);
    defer commands.deinit();
    var workspace = fakes.FakeWorkspaceStore.init(allocator);
    defer workspace.deinit();
    var clock = fakes.FakeClockAndIds.init(allocator);
    defer clock.deinit();
    const context = transactionalTestContext(&commands, &workspace, &clock);

    try workspace.expectRead(.{
        .path = "src/main.zig",
        .max_bytes = editing.max_session_file_bytes,
        .provenance = "patch_session_snapshot",
    }, "const value = 1;\n");
    try workspace.expectReadError(.{
        .path = "src/denied.zig",
        .max_bytes = editing.max_session_file_bytes,
        .provenance = "patch_session_snapshot",
    }, error.AccessDenied);
    var create_args = std.json.ObjectMap.empty;
    defer create_args.deinit(allocator);
    try create_args.put(allocator, "files", .{ .string = "src/main.zig src/denied.zig" });
    try create_args.put(allocator, "goal", .{ .string = "cover mixed session creation" });
    const created = try zigarPatchSessionCreate(allocator, context, .{ .object = create_args });
    defer mcp_result.deinitToolResult(allocator, created);
    try std.testing.expect(!created.structuredContent.?.object.get("safe_to_edit").?.bool);

    var revert_args = std.json.ObjectMap.empty;
    defer revert_args.deinit(allocator);
    try revert_args.put(allocator, "session_id", .{ .string = "missing-session" });
    try revert_args.put(allocator, "history", .{ .string = "" });
    const missing_revert = try zigarPatchSessionRevert(allocator, context, .{ .object = revert_args });
    defer mcp_result.deinitToolResult(allocator, missing_revert);
    try std.testing.expectEqualStrings("not_found", missing_revert.structuredContent.?.object.get("error_kind").?.string);

    try clock.pushInstant(.{ .unix_ms = 1_700_000_010_000, .monotonic_ms = 1 });
    try workspace.expectReadError(.{
        .path = "validation.jsonl",
        .max_bytes = validation_workflows.history_max_bytes,
        .provenance = "zigar_validation_run history preimage",
    }, error.FileNotFound);
    var validate_args = std.json.ObjectMap.empty;
    defer validate_args.deinit(allocator);
    try validate_args.put(allocator, "mode", .{ .string = "quick" });
    try validate_args.put(allocator, "changed_files", .{ .string = "notes.txt" });
    try validate_args.put(allocator, "output", .{ .string = "validation.jsonl" });
    try validate_args.put(allocator, "apply", .{ .bool = true });
    const validation_failed = try zigarPatchSessionValidate(allocator, context, .{ .object = validate_args });
    defer mcp_result.deinitToolResult(allocator, validation_failed);
    try std.testing.expectEqualStrings("tool_error", validation_failed.structuredContent.?.object.get("kind").?.string);
    try std.testing.expectEqual(@as(usize, 1), workspace.writeCalls().len);

    var zls_running = context;
    zls_running.zls_state = .{ .running = true, .status = "connected" };
    const batch = try zigCodeActionBatch(allocator, zls_running, null);
    defer mcp_result.deinitToolResult(allocator, batch);
    try std.testing.expectEqualStrings("unsupported_state", batch.structuredContent.?.object.get("error_kind").?.string);

    try workspace.verify();
    try commands.verify();
    try clock.verify();
}

test "transactional editing adapter helper parsers and errors are explicit" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    const parsed = try std.json.parseFromSlice(std.json.Value, scratch,
        \\{"files":[{"path":"src/a.zig","content":"a"},{"file":"src/b.zig","content":"b"}]}
    , .{});
    var replacements = std.ArrayList(editing.Replacement).empty;
    defer replacements.deinit(scratch);
    try collectReplacements(scratch, &replacements, parsed.value);
    try std.testing.expectEqual(@as(usize, 2), replacements.items.len);

    const bad_files = try std.json.parseFromSlice(std.json.Value, scratch, "{\"files\":123}", .{});
    try std.testing.expectError(error.InvalidArguments, collectReplacements(scratch, &replacements, bad_files.value));
    const bad_item = try std.json.parseFromSlice(std.json.Value, scratch, "[123]", .{});
    try std.testing.expectError(error.InvalidArguments, collectReplacements(scratch, &replacements, bad_item.value));

    var validation_args_source = std.json.ObjectMap.empty;
    defer validation_args_source.deinit(allocator);
    try validation_args_source.put(allocator, "edits", .{ .string = "[{\"file\":\"src/a.zig\",\"content\":\"a\"},{\"path\":\"src/b.zig\",\"content\":\"b\"}]" });
    const validation_args = try validationArgsFromSessionArgs(scratch, .{ .object = validation_args_source });
    try std.testing.expectEqualStrings("src/a.zig src/b.zig", validation_args.object.get("changed_files").?.string);

    var policy_args = std.json.ObjectMap.empty;
    defer policy_args.deinit(allocator);
    try policy_args.put(allocator, "patch", .{ .string = "--- a/src/old.zig\n+++ b/src/new.zig\n" });
    const policy = try zigarEditPolicyCheck(allocator, app_context.Context{}, .{ .object = policy_args });
    defer mcp_result.deinitToolResult(allocator, policy);
    try std.testing.expectEqual(@as(usize, 2), policy.structuredContent.?.object.get("checked").?.array.items.len);

    try std.testing.expectError(error.OutOfMemory, transactionalError(allocator, "zig_update_imports", "parse", error.OutOfMemory));
    const invalid = try transactionalError(allocator, "zig_update_imports", "parse", error.InvalidArguments);
    defer mcp_result.deinitToolResult(allocator, invalid);
    try std.testing.expectEqualStrings("argument_error", invalid.structuredContent.?.object.get("kind").?.string);
    const outside = try transactionalError(allocator, "zig_update_imports", "read", error.PathOutsideWorkspace);
    defer mcp_result.deinitToolResult(allocator, outside);
    try std.testing.expectEqualStrings("workspace_path_error", outside.structuredContent.?.object.get("kind").?.string);
    const generic = try transactionalError(allocator, "zig_update_imports", "read", error.AccessDenied);
    defer mcp_result.deinitToolResult(allocator, generic);
    try std.testing.expectEqualStrings("tool_error", generic.structuredContent.?.object.get("kind").?.string);

    try std.testing.expect(argString(.{ .string = "not-object" }, "file") == null);
    try std.testing.expect(argBoolOptional(.{ .string = "not-object" }, "apply") == null);
    try std.testing.expect(argIntOptional(.{ .string = "not-object" }, "timeout_ms") == null);
}

fn transactionalTestContext(
    command_runner: *fakes.FakeCommandRunner,
    workspace_store: *fakes.FakeWorkspaceStore,
    clock_and_ids: *fakes.FakeClockAndIds,
) app_context.Context {
    return .{
        .workspace = .{ .root = "/repo", .cache_root = "/repo/.zigar-cache" },
        .tool_paths = .{ .zig = "zig" },
        .timeouts = .{ .command_ms = 30_000, .zls_ms = 30_000 },
        .zls_state = .{},
        .ports = .{
            .command_runner = command_runner.port(),
            .workspace = workspace_store.port(),
            .clock_and_ids = clock_and_ids.port(),
        },
    };
}
