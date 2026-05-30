//! Transactional-editing MCP adapters for patch sessions, previews, commits,
//! rollback, and edit history.
//!
//! Source mutation is gated three ways: apply=true is required, the caller must
//! echo back the expected_preimages captured during preview (a hash check that
//! refuses the write if the file changed underneath, guarding against TOCTOU),
//! and apply additionally requests MCP elicitation so the client can confirm.
//! When elicitation is unavailable the apply=true + expected_preimages pair
//! remains the fallback safety contract. Generated/vendored paths are routed,
//! not edited.
const std = @import("std");
const mcp = @import("mcp");

const app_context = @import("../../../app/context.zig");
const ports = @import("../../../app/ports.zig");
const editing = @import("../../../app/usecases/editing/patch_sessions.zig");
const editing_workflows = @import("../../../app/usecases/editing/workflows.zig");
const validation_workflows = @import("../../../app/usecases/validation/workflows.zig");
const validation_adapter = @import("project_intelligence.zig");
const mcp_errors = @import("../errors.zig");
const mcp_result = @import("../result.zig");

/// Reason text surfaced when a client lacks MCP elicitation: apply still proceeds
/// under the apply=true + expected_preimages contract, so this explains why no
/// interactive confirmation was requested rather than signaling a blocked apply.
const elicitation_apply_fallback_reason = "MCP elicitation was unavailable; apply=true and expected_preimages remain the fallback safety contract.";

/// Handles MCP `zigars_patch_session_create` requests by delegating to app logic and shaping owned results/errors.
pub fn zigarsPatchSessionCreate(allocator: std.mem.Allocator, context: app_context.Context, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    // Keep this logic centralized so callers observe one consistent behavior path.
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    var paths = std.ArrayList([]const u8).empty;
    defer paths.deinit(scratch);
    try appendPathTokens(scratch, &paths, argString(args, "files"));
    try appendPatchPaths(scratch, &paths, argString(args, "patch"));
    if (argString(args, "edits")) |raw| try appendEditPaths(scratch, &paths, raw);
    const ctx = context.editing() catch |err| return transactionalError(allocator, "zigars_patch_session_create", "build_app_context", err);
    var result = editing.create(scratch, ctx, .{
        .session_id = try sessionId(scratch, "create", argString(args, "goal"), argString(args, "files"), argString(args, "patch"), argString(args, "edits")),
        .goal = argString(args, "goal"),
        .paths = paths.items,
    }) catch |err| return transactionalError(allocator, "zigars_patch_session_create", "create_session", err);
    defer result.deinit(scratch);
    return structuredScratch(allocator, scratch, try patchSessionCreateValue(scratch, result));
}

/// Handles MCP `zigars_patch_session_preview` requests by delegating to app logic and shaping owned results/errors.
pub fn zigarsPatchSessionPreview(allocator: std.mem.Allocator, context: app_context.Context, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return patchSessionReplacementTool(allocator, context, args, "zigars_patch_session_preview", false);
}

/// Handles MCP `zigars_patch_session_apply` requests by delegating to app logic and shaping owned results/errors.
pub fn zigarsPatchSessionApply(allocator: std.mem.Allocator, context: app_context.Context, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return patchSessionReplacementTool(allocator, context, args, "zigars_patch_session_apply", argBool(args, "apply", false));
}

/// Handles MCP `zigars_patch_session_validate` requests by delegating to app logic and shaping owned results/errors.
pub fn zigarsPatchSessionValidate(allocator: std.mem.Allocator, context: app_context.Context, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    // Keep this logic centralized so callers observe one consistent behavior path.
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const validation_args = try validationArgsFromSessionArgs(scratch, args);
    var parsed = validation_adapter.validationRunRequestFromArgs(scratch, validation_args, timeoutMs(context, args)) catch |err| return transactionalError(allocator, "zigars_patch_session_validate", "parse_validation_request", err);
    defer parsed.deinit(scratch);
    var outcome = editing.validate(scratch, context.validation() catch |err| return transactionalError(allocator, "zigars_patch_session_validate", "build_validation_context", err), parsed.request) catch |err| return transactionalError(allocator, "zigars_patch_session_validate", "run_validation", err);
    defer outcome.deinit(scratch);
    const report = switch (outcome) {
        .ok => |value| value,
        .err => return transactionalError(allocator, "zigars_patch_session_validate", "run_validation", error.ValidationHistoryWriteFailed),
    };
    var obj = std.json.ObjectMap.empty;
    try obj.put(scratch, "kind", .{ .string = "zigars_patch_session_validate" });
    try obj.put(scratch, "schema_version", .{ .integer = editing.schema_version });
    try obj.put(scratch, "session_id", try optionalStringValue(scratch, argString(args, "session_id")));
    try obj.put(scratch, "ok", .{ .bool = report.ok });
    try obj.put(scratch, "validation", try validation_adapter.validationRunValue(scratch, report));
    try obj.put(scratch, "stop_condition", .{ .string = "Treat skipped validation phases as unknown; rollback remains available only for recorded applied sessions." });
    return structuredScratch(allocator, scratch, .{ .object = obj });
}

/// Handles MCP `zigars_patch_session_revert` requests by delegating to app logic and shaping owned results/errors.
pub fn zigarsPatchSessionRevert(allocator: std.mem.Allocator, context: app_context.Context, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    // Keep this logic centralized so callers observe one consistent behavior path.
    const session_id = argString(args, "session_id") orelse return mcp_errors.missingArgument(allocator, "zigars_patch_session_revert", "session_id", "recorded patch session id");
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    var outcome = editing.revert(scratch, context.editing() catch |err| return transactionalError(allocator, "zigars_patch_session_revert", "build_app_context", err), .{
        .session_id = session_id,
        .apply = argBool(args, "apply", false),
        .history = argString(args, "history"),
        .history_path = argString(args, "history_path") orelse editing.history_path_default,
    }) catch |err| return transactionalError(allocator, "zigars_patch_session_revert", "revert_session", err);
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

/// Handles MCP `zigars_edit_policy_check` requests by delegating to app logic and shaping owned results/errors.
pub fn zigarsEditPolicyCheck(allocator: std.mem.Allocator, _: app_context.Context, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    // Keep this logic centralized so callers observe one consistent behavior path.
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    var paths = std.ArrayList([]const u8).empty;
    defer paths.deinit(scratch);
    try appendPathTokens(scratch, &paths, argString(args, "files"));
    try appendPatchPaths(scratch, &paths, argString(args, "patch"));
    return structuredScratch(allocator, scratch, try editing_workflows.editPolicyCheckValue(scratch, paths.items));
}

/// Handles MCP `zigars_generated_route` requests by delegating to app logic and shaping owned results/errors.
pub fn zigarsGeneratedRoute(allocator: std.mem.Allocator, context: app_context.Context, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const path = argString(args, "path") orelse return mcp_errors.missingArgument(allocator, "zigars_generated_route", "path", "workspace-relative generated or vendored path");
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    return structuredScratch(allocator, scratch, editing_workflows.generatedRouteValue(scratch, context.editing() catch |err| return transactionalError(allocator, "zigars_generated_route", "build_app_context", err), path, argString(args, "goal")) catch |err| return transactionalError(allocator, "zigars_generated_route", "run_workflow", err));
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
    // Keep this logic centralized so callers observe one consistent behavior path.
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
    // Keep this logic centralized so callers observe one consistent behavior path.
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
    // Keep this logic centralized so callers observe one consistent behavior path.
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

/// Reports that batched ZLS code-action application is not yet supported. A
/// stopped ZLS returns a backend_error; a running ZLS still returns an
/// `unsupported_state` result, since the batch workflow is intentionally unwired
/// rather than performing edits.
pub fn zigCodeActionBatch(allocator: std.mem.Allocator, context: app_context.Context, _: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    if (!context.zls_state.running) return backendUnavailableResult(allocator, "zls", "zig_code_action_batch", context.tool_paths.zls, context.zls_state.status, "Start or repair ZLS, then retry code action batching.");
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    // Even with ZLS running this returns the unavailable/unsupported value: batch
    // code-action application is deliberately not implemented (no source writes).
    return structuredScratch(allocator, scratch, editing_workflows.codeActionBatchUnavailableValue(scratch) catch |err| return transactionalError(allocator, "zig_code_action_batch", "run_workflow", err));
}

/// Handles patch-session preview/apply requests that share replacement parsing.
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
    const editing_context = context.editing() catch |err| return transactionalError(allocator, tool_name, "build_app_context", err);
    const session_id_value = if (argString(args, "session_id")) |id| id else try sessionId(scratch, tool_name, argString(args, "goal"), null, null, raw_edits);
    var elicitation_response: ?ports.ProtocolResponse = null;
    if (apply) {
        // Ask the client to confirm before any write. Only a positive decision
        // proceeds; a decline/cancel/timeout returns a non-applied result so the
        // source files are never touched. An absent client falls through (the
        // expected_preimages check is then the sole guard).
        elicitation_response = requestApplyElicitation(scratch, editing_context.protocol_client, session_id_value, replacements.items.len);
        if (elicitationBlocksApply(elicitation_response.?)) {
            return structuredScratch(allocator, scratch, try applyDeclinedValue(scratch, session_id_value, expected, elicitation_response.?));
        }
    }
    var result = editing.replacementSession(scratch, editing_context, .{
        .operation = if (apply) .apply else .preview,
        .session_id = session_id_value,
        .goal = argString(args, "goal"),
        .replacements = replacements.items,
        .expected_preimages = expected,
        .apply = apply,
    }) catch |err| return transactionalError(allocator, tool_name, "build_session", err);
    defer result.deinit(scratch);
    return structuredScratch(allocator, scratch, try patchSessionReplacementValue(scratch, result, elicitation_response));
}

/// Returns an allocator-owned JSON value for patch session create.
fn patchSessionCreateValue(allocator: std.mem.Allocator, result: editing.CreateResult) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
    var files = std.json.Array.init(allocator);
    for (result.files) |file| {
        try files.append(switch (file) {
            .ok => |state| try sessionFileStateValue(allocator, state),
            .err => |failure| try pathFailureNameValue(allocator, failure.file, failure.error_name),
        });
    }
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "kind", .{ .string = "zigars_patch_session_create" });
    try obj.put(allocator, "schema_version", .{ .integer = editing.schema_version });
    try obj.put(allocator, "session_id", try ownedString(allocator, result.session_id));
    try obj.put(allocator, "goal", try optionalStringValue(allocator, result.goal));
    try obj.put(allocator, "status", .{ .string = "created" });
    try obj.put(allocator, "safe_to_edit", .{ .bool = result.safe_to_edit });
    try obj.put(allocator, "files", .{ .array = files });
    try obj.put(allocator, "expected_preimages", try expectedPreimagesValue(allocator, result.expected_preimages));
    try obj.put(allocator, "next_action", try nextToolValue(allocator, if (result.safe_to_edit) "zigars_patch_session_preview" else "zigars_generated_route", if (result.safe_to_edit) "preview replacement content before applying" else "route generated or vendored paths to source/regeneration"));
    try obj.put(allocator, "limitations", .{ .string = "Session creation captures current file identity and policy only; no source writes or validation commands have run." });
    return .{ .object = obj };
}

/// Returns an allocator-owned JSON value for patch session replacement.
fn patchSessionReplacementValue(allocator: std.mem.Allocator, result: editing.ReplacementResult, elicitation_response: ?ports.ProtocolResponse) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
    var files = std.json.Array.init(allocator);
    for (result.files) |file| try files.append(try replacementFileValue(allocator, file));
    if (result.blocked) return applyBlockedValue(allocator, result.session_id, files, result.expected_preimages, elicitation_response);
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
    try obj.put(allocator, "limitations", .{ .string = "Apply requires expected_preimages from preview and refuses generated/vendor paths; validation must be run separately or through zigars_patch_session_validate." });
    if (result.operation == .apply) try putElicitationMetadata(allocator, &obj, elicitation_response);
    return .{ .object = obj };
}

/// Returns an allocator-owned JSON value for patch session revert.
fn patchSessionRevertValue(allocator: std.mem.Allocator, result: editing.RevertResult) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
    var files = std.json.Array.init(allocator);
    for (result.files) |file| try files.append(try revertFileValue(allocator, file));
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "kind", .{ .string = "zigars_patch_session_revert" });
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

/// Returns an allocator-owned JSON value for session file state.
fn sessionFileStateValue(allocator: std.mem.Allocator, state: editing.SessionFileState) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "file", try ownedString(allocator, state.file));
    try obj.put(allocator, "preimage_identity", try identityValue(allocator, state.preimage_identity));
    try obj.put(allocator, "policy", try policyValue(allocator, state.policy));
    return .{ .object = obj };
}

/// Returns an allocator-owned JSON value for replacement file.
fn replacementFileValue(allocator: std.mem.Allocator, file: editing.ReplacementFile) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
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

/// Returns an allocator-owned JSON value for revert file.
fn revertFileValue(allocator: std.mem.Allocator, file: editing.RevertFile) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
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

/// Returns an allocator-owned JSON value for session record.
fn sessionRecordValue(allocator: std.mem.Allocator, record: editing.SessionRecord) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
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
    try obj.put(allocator, "kind", .{ .string = "zigars_patch_session_record" });
    try obj.put(allocator, "schema_version", .{ .integer = editing.schema_version });
    try obj.put(allocator, "session_id", try ownedString(allocator, record.session_id));
    try obj.put(allocator, "goal", try optionalStringValue(allocator, record.goal));
    try obj.put(allocator, "recorded_unix_ms", .{ .integer = record.recorded_unix_ms });
    try obj.put(allocator, "files", .{ .array = files });
    return .{ .object = obj };
}

/// Returns an allocator-owned JSON value for identity.
fn identityValue(allocator: std.mem.Allocator, identity: editing.Identity) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "exists", .{ .bool = identity.exists });
    try obj.put(allocator, "bytes", .{ .integer = @intCast(identity.bytes) });
    try obj.put(allocator, "sha256", if (identity.sha256) |hash| try ownedString(allocator, hash) else .null);
    return .{ .object = obj };
}

/// Returns an allocator-owned JSON value for expected preimages.
fn expectedPreimagesValue(allocator: std.mem.Allocator, expected: []const editing.ExpectedPreimage) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
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

/// Returns an allocator-owned JSON value for policy.
fn policyValue(allocator: std.mem.Allocator, policy: editing.PathPolicy) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
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

/// Returns an allocator-owned JSON value for apply blocked.
fn applyBlockedValue(allocator: std.mem.Allocator, session_id: []const u8, files: std.json.Array, expected_preimages: []const editing.ExpectedPreimage, elicitation_response: ?ports.ProtocolResponse) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "kind", .{ .string = "zigars_patch_session_apply" });
    try obj.put(allocator, "schema_version", .{ .integer = editing.schema_version });
    try obj.put(allocator, "session_id", try ownedString(allocator, session_id));
    try obj.put(allocator, "applied", .{ .bool = false });
    try obj.put(allocator, "safe_to_apply", .{ .bool = false });
    try obj.put(allocator, "files", .{ .array = files });
    try obj.put(allocator, "expected_preimages", try expectedPreimagesValue(allocator, expected_preimages));
    try obj.put(allocator, "resolution", .{ .string = "Re-run preview, pass its expected_preimages unchanged, and avoid generated or vendored paths." });
    try putElicitationMetadata(allocator, &obj, elicitation_response);
    return .{ .object = obj };
}

/// Returns a non-applied patch-session result when client elicitation blocks the source write.
fn applyDeclinedValue(allocator: std.mem.Allocator, session_id: []const u8, expected_preimages: []const editing.ExpectedPreimage, response: ports.ProtocolResponse) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
    const files = std.json.Array.init(allocator);
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "kind", .{ .string = "zigars_patch_session_apply" });
    try obj.put(allocator, "schema_version", .{ .integer = editing.schema_version });
    try obj.put(allocator, "session_id", try ownedString(allocator, session_id));
    try obj.put(allocator, "applied", .{ .bool = false });
    try obj.put(allocator, "requires_apply", .{ .bool = true });
    try obj.put(allocator, "safe_to_apply", .{ .bool = false });
    try obj.put(allocator, "files", .{ .array = files });
    try obj.put(allocator, "expected_preimages", try expectedPreimagesValue(allocator, expected_preimages));
    try obj.put(allocator, "resolution", .{ .string = "Client elicitation did not accept the apply request; no source file was changed." });
    try putElicitationMetadata(allocator, &obj, response);
    return .{ .object = obj };
}

/// Decides whether an elicitation response should block the apply. When the
/// client does not support elicitation we do NOT block (the expected_preimages
/// contract still guards the write); when it is supported, only an explicit
/// `accepted` proceeds, so a malformed/timed-out/declined response blocks.
fn elicitationBlocksApply(response: ports.ProtocolResponse) bool {
    if (!response.supported or response.status == .unsupported) return false;
    return response.status != .accepted;
}

/// Requests client confirmation for a source-mutating patch-session apply via
/// MCP elicitation/create. A null client returns an `unsupported` response
/// (apply falls back to the preimage contract). Any failure while building the
/// request returns a `malformed` response, which blocks the apply: confirmation
/// failures fail closed rather than silently proceeding with the write.
fn requestApplyElicitation(allocator: std.mem.Allocator, client: ?ports.ProtocolClient, session_id: []const u8, file_count: usize) ports.ProtocolResponse {
    // Keep this logic centralized so callers observe one consistent behavior path.
    const protocol_client = client orelse return .{
        .supported = false,
        .used = false,
        .status = .unsupported,
        .unavailable_reason = elicitation_apply_fallback_reason,
    };
    var params = std.json.ObjectMap.empty;
    params.put(allocator, "message", .{ .string = "Apply this zigars patch session to workspace source files?" }) catch return protocolFailureResponse();
    var requested_schema = std.json.ObjectMap.empty;
    requested_schema.put(allocator, "type", .{ .string = "object" }) catch return protocolFailureResponse();
    var properties = std.json.ObjectMap.empty;
    var confirm = std.json.ObjectMap.empty;
    confirm.put(allocator, "type", .{ .string = "boolean" }) catch return protocolFailureResponse();
    confirm.put(allocator, "description", .{ .string = "Set true to permit this apply=true source mutation." }) catch return protocolFailureResponse();
    properties.put(allocator, "confirm", .{ .object = confirm }) catch return protocolFailureResponse();
    requested_schema.put(allocator, "properties", .{ .object = properties }) catch return protocolFailureResponse();
    var required = std.json.Array.init(allocator);
    required.append(.{ .string = "confirm" }) catch return protocolFailureResponse();
    requested_schema.put(allocator, "required", .{ .array = required }) catch return protocolFailureResponse();
    params.put(allocator, "requestedSchema", .{ .object = requested_schema }) catch return protocolFailureResponse();
    params.put(allocator, "session_id", .{ .string = session_id }) catch return protocolFailureResponse();
    params.put(allocator, "changed_file_count", .{ .integer = @intCast(file_count) }) catch return protocolFailureResponse();
    return protocol_client.request(allocator, .{
        .feature = .elicitation,
        .method = "elicitation/create",
        .params = .{ .object = params },
    }) catch |err| switch (err) {
        error.OutOfMemory => protocolFailureResponse(),
        else => .{
            .supported = true,
            .used = false,
            .status = .timeout,
            .unavailable_reason = "MCP elicitation request failed before a client response was available.",
        },
    };
}

/// Fail-closed response for local allocation/construction failures: status
/// `.malformed` with `supported = true` so elicitationBlocksApply blocks the
/// apply instead of letting a build error open an unconfirmed write path.
fn protocolFailureResponse() ports.ProtocolResponse {
    return .{
        .supported = true,
        .used = false,
        .status = .malformed,
        .unavailable_reason = "MCP elicitation request could not be constructed.",
    };
}

/// Adds elicitation status metadata to apply outputs.
fn putElicitationMetadata(allocator: std.mem.Allocator, obj: *std.json.ObjectMap, response: ?ports.ProtocolResponse) !void {
    // Keep this logic centralized so callers observe one consistent behavior path.
    const protocol_response = response orelse ports.ProtocolResponse{
        .supported = false,
        .used = false,
        .status = .unsupported,
        .unavailable_reason = elicitation_apply_fallback_reason,
    };
    try obj.put(allocator, "elicitation_used", .{ .bool = protocol_response.used });
    try obj.put(allocator, "elicitation_status", .{ .string = protocolStatusName(protocol_response.status) });
    if (protocol_response.unavailable_reason.len > 0) {
        try obj.put(allocator, "elicitation_unavailable_reason", .{ .string = protocol_response.unavailable_reason });
    }
}

/// Stable JSON spelling for protocol helper status.
fn protocolStatusName(status: ports.ProtocolResponseStatus) []const u8 {
    // Keep this logic centralized so callers observe one consistent behavior path.
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

/// Parses the caller's expected_preimages JSON (file + identity hash per entry)
/// used to detect drift before apply. Absent input yields an empty slice;
/// anything that is not an array of objects is rejected as InvalidArguments.
fn parseExpectedPreimages(allocator: std.mem.Allocator, raw: ?[]const u8) ![]const editing.ExpectedPreimage {
    // Normalize input here so downstream paths can rely on validated shape.
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

/// Collects replacements into the caller-provided output list.
fn collectReplacements(allocator: std.mem.Allocator, replacements: *std.ArrayList(editing.Replacement), value: std.json.Value) !void {
    // Keep this logic centralized so callers observe one consistent behavior path.
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

/// Appends replacement to the caller-provided output list.
fn appendReplacement(allocator: std.mem.Allocator, replacements: *std.ArrayList(editing.Replacement), value: std.json.Value) !void {
    // Append in deterministic order so completion and snapshot output remain stable.
    const obj = switch (value) {
        .object => |o| o,
        else => return error.InvalidArguments,
    };
    try replacements.append(allocator, .{
        .file = stringField(obj, "file") orelse stringField(obj, "path") orelse return error.InvalidArguments,
        .content = stringField(obj, "content") orelse return error.InvalidArguments,
    });
}

/// Copies validation-related fields from session arguments into a new JSON object.
fn validationArgsFromSessionArgs(allocator: std.mem.Allocator, args: ?std.json.Value) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
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

/// Appends edit paths to the caller-provided output list.
fn appendEditPaths(allocator: std.mem.Allocator, paths: *std.ArrayList([]const u8), raw_edits: []const u8) !void {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, raw_edits, .{}) catch return;
    defer parsed.deinit();
    var replacements = std.ArrayList(editing.Replacement).empty;
    defer replacements.deinit(allocator);
    try collectReplacements(allocator, &replacements, parsed.value);
    for (replacements.items) |replacement| try appendUniqueString(allocator, paths, replacement.file);
}

/// Appends path tokens to the caller-provided output list.
fn appendPathTokens(allocator: std.mem.Allocator, paths: *std.ArrayList([]const u8), maybe_text: ?[]const u8) !void {
    const text = maybe_text orelse return;
    var it = std.mem.tokenizeAny(u8, text, " \t\r\n,");
    while (it.next()) |path| try appendUniqueString(allocator, paths, path);
}

/// Extracts touched file paths from a unified diff by reading its `+++ b/` and
/// `--- a/` header lines (the 6-char prefix is stripped). Used to learn which
/// files a patch affects so they can be policy-checked before any edit.
fn appendPatchPaths(allocator: std.mem.Allocator, paths: *std.ArrayList([]const u8), maybe_patch: ?[]const u8) !void {
    const patch = maybe_patch orelse return;
    var lines = std.mem.splitScalar(u8, patch, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "+++ b/")) try appendUniqueString(allocator, paths, line[6..]);
        if (std.mem.startsWith(u8, line, "--- a/")) try appendUniqueString(allocator, paths, line[6..]);
    }
}

/// Appends unique string to the caller-provided output list.
fn appendUniqueString(allocator: std.mem.Allocator, values: *std.ArrayList([]const u8), value: []const u8) !void {
    for (values.items) |existing| if (std.mem.eql(u8, existing, value)) return;
    try values.append(allocator, try allocator.dupe(u8, value));
}

/// Derives a deterministic session id by hashing the prefix plus goal and edit
/// inputs, so an unchanged request yields the same id across calls without the
/// server retaining session state. Used only when the caller omits session_id.
fn sessionId(allocator: std.mem.Allocator, prefix: []const u8, goal: ?[]const u8, a: ?[]const u8, b: ?[]const u8, c: ?[]const u8) ![]const u8 {
    // Keep this logic centralized so callers observe one consistent behavior path.
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

/// Returns a structured MCP result while matching callbacks that pass scratch arenas.
fn structuredScratch(allocator: std.mem.Allocator, scratch: std.mem.Allocator, value: std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    _ = scratch;
    return mcp_result.structured(allocator, value);
}

/// Maps transactional error failures to structured MCP errors.
fn transactionalError(allocator: std.mem.Allocator, tool_name: []const u8, phase: []const u8, err: anyerror) mcp.tools.ToolError!mcp.tools.ToolResult {
    // Preserve a single error-shaping path so callers receive consistent metadata.
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

/// Returns the MCP tool result for backend unavailable.
fn backendUnavailableResult(allocator: std.mem.Allocator, backend_name: []const u8, operation: []const u8, configured_path: []const u8, status: []const u8, resolution: []const u8) mcp.tools.ToolError!mcp.tools.ToolResult {
    // Keep this logic centralized so callers observe one consistent behavior path.
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

/// Returns a structured not-found response for an unknown patch session id.
fn sessionNotFound(allocator: std.mem.Allocator, session_id: []const u8) mcp.tools.ToolError!mcp.tools.ToolResult {
    // Keep this logic centralized so callers observe one consistent behavior path.
    var obj = std.json.ObjectMap.empty;
    defer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zigars_patch_session_revert" });
    try obj.put(allocator, "ok", .{ .bool = false });
    try obj.put(allocator, "session_id", .{ .string = session_id });
    try obj.put(allocator, "error_kind", .{ .string = "not_found" });
    try obj.put(allocator, "resolution", .{ .string = "Pass history/history_path containing a zigars_patch_session_record emitted by zigars_patch_session_apply apply=true." });
    return mcp_result.structured(allocator, .{ .object = obj });
}

/// Returns an allocator-owned JSON value for optional string.
fn optionalStringValue(allocator: std.mem.Allocator, value: ?[]const u8) !std.json.Value {
    if (value) |text| return ownedString(allocator, text);
    return .null;
}

/// Copies text into an allocator-owned JSON string value.
fn ownedString(allocator: std.mem.Allocator, text: []const u8) !std.json.Value {
    return .{ .string = try allocator.dupe(u8, text) };
}

/// Copies a string slice into an allocator-owned JSON array.
fn stringArrayValue(allocator: std.mem.Allocator, values: []const []const u8) !std.json.Value {
    var array = std.json.Array.init(allocator);
    for (values) |value| try array.append(try ownedString(allocator, value));
    return .{ .array = array };
}

/// Returns an allocator-owned JSON value for joined strings.
fn joinedStringsValue(allocator: std.mem.Allocator, values: []const []const u8) !std.json.Value {
    var out = std.ArrayList(u8).empty;
    for (values, 0..) |value, index| {
        if (index > 0) try out.append(allocator, ' ');
        try out.appendSlice(allocator, value);
    }
    return .{ .string = try out.toOwnedSlice(allocator) };
}

/// Returns an allocator-owned JSON value for next tool.
fn nextToolValue(allocator: std.mem.Allocator, tool: []const u8, reason: []const u8) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "tool", try ownedString(allocator, tool));
    try obj.put(allocator, "reason", try ownedString(allocator, reason));
    return .{ .object = obj };
}

/// Returns an allocator-owned JSON value for path failure name.
fn pathFailureNameValue(allocator: std.mem.Allocator, path: []const u8, error_name: []const u8) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "file", try ownedString(allocator, path));
    try obj.put(allocator, "ok", .{ .bool = false });
    try obj.put(allocator, "error", try ownedString(allocator, error_name));
    return .{ .object = obj };
}

/// Reads a string field from a JSON object when it has the expected type.
fn stringField(obj: std.json.ObjectMap, field: []const u8) ?[]const u8 {
    return switch (obj.get(field) orelse .null) {
        .string => |s| s,
        else => null,
    };
}

/// Reads a boolean field from a JSON object when it has the expected type.
fn boolField(obj: std.json.ObjectMap, field: []const u8) ?bool {
    return switch (obj.get(field) orelse .null) {
        .bool => |b| b,
        else => null,
    };
}

/// Reads an integer field from a JSON object when it has the expected type.
fn integerField(obj: std.json.ObjectMap, field: []const u8) ?i64 {
    return switch (obj.get(field) orelse .null) {
        .integer => |i| i,
        else => null,
    };
}

/// Reads a string argument when it is present with the expected type.
fn argString(args: ?std.json.Value, name: []const u8) ?[]const u8 {
    const obj = switch (args orelse return null) {
        .object => |o| o,
        else => return null,
    };
    return stringField(obj, name);
}

/// Reads a bool argument when it is present with the expected type.
fn argBool(args: ?std.json.Value, name: []const u8, default: bool) bool {
    return argBoolOptional(args, name) orelse default;
}

/// Reads a bool optional argument when it is present with the expected type.
fn argBoolOptional(args: ?std.json.Value, name: []const u8) ?bool {
    const obj = switch (args orelse return null) {
        .object => |o| o,
        else => return null,
    };
    return boolField(obj, name);
}

/// Reads an int argument when it is present with the expected type.
fn argInt(args: ?std.json.Value, name: []const u8, default: i64) i64 {
    return argIntOptional(args, name) orelse default;
}

/// Reads an optional int argument when it is present with the expected type.
fn argIntOptional(args: ?std.json.Value, name: []const u8) ?i64 {
    const obj = switch (args orelse return null) {
        .object => |o| o,
        else => return null,
    };
    return integerField(obj, name);
}

/// Clamps requested timeout to the supported command timeout range.
fn timeoutMs(context: app_context.Context, args: ?std.json.Value) i64 {
    return @max(1, @min(argInt(args, "timeout_ms", context.timeouts.command_ms), 60 * 60 * 1000));
}

/// Returns the SHA-256 digest as lowercase hexadecimal text.
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
    const created = try zigarsPatchSessionCreate(allocator, context, .{ .object = create_args });
    defer mcp_result.deinitToolResult(allocator, created);
    try std.testing.expect(!created.structuredContent.?.object.get("safe_to_edit").?.bool);

    var revert_args = std.json.ObjectMap.empty;
    defer revert_args.deinit(allocator);
    try revert_args.put(allocator, "session_id", .{ .string = "missing-session" });
    try revert_args.put(allocator, "history", .{ .string = "" });
    const missing_revert = try zigarsPatchSessionRevert(allocator, context, .{ .object = revert_args });
    defer mcp_result.deinitToolResult(allocator, missing_revert);
    try std.testing.expectEqualStrings("not_found", missing_revert.structuredContent.?.object.get("error_kind").?.string);

    try clock.pushInstant(.{ .unix_ms = 1_700_000_010_000, .monotonic_ms = 1 });
    try workspace.expectReadError(.{
        .path = "validation.jsonl",
        .max_bytes = validation_workflows.history_max_bytes,
        .provenance = "zigars_validation_run history preimage",
    }, error.FileNotFound);
    var validate_args = std.json.ObjectMap.empty;
    defer validate_args.deinit(allocator);
    try validate_args.put(allocator, "mode", .{ .string = "quick" });
    try validate_args.put(allocator, "changed_files", .{ .string = "notes.txt" });
    try validate_args.put(allocator, "output", .{ .string = "validation.jsonl" });
    try validate_args.put(allocator, "apply", .{ .bool = true });
    const validation_failed = try zigarsPatchSessionValidate(allocator, context, .{ .object = validate_args });
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
    const policy = try zigarsEditPolicyCheck(allocator, app_context.Context{}, .{ .object = policy_args });
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

    try std.testing.expect(!elicitationBlocksApply(.{
        .supported = false,
        .status = .unsupported,
    }));
    try std.testing.expect(!elicitationBlocksApply(.{
        .supported = true,
        .used = true,
        .status = .accepted,
    }));
    try std.testing.expect(elicitationBlocksApply(.{
        .supported = true,
        .status = .declined,
    }));

    const declined = try applyDeclinedValue(scratch, "session-1", &.{}, .{
        .supported = true,
        .status = .declined,
        .unavailable_reason = "declined by test client",
    });
    try std.testing.expect(!declined.object.get("applied").?.bool);
    try std.testing.expectEqualStrings("declined", declined.object.get("elicitation_status").?.string);
}

/// Creates transactional test context from the ports required by the adapter.
fn transactionalTestContext(
    command_runner: *fakes.FakeCommandRunner,
    workspace_store: *fakes.FakeWorkspaceStore,
    clock_and_ids: *fakes.FakeClockAndIds,
) app_context.Context {
    // Keep this logic centralized so callers observe one consistent behavior path.
    return .{
        .workspace = .{ .root = "/repo", .cache_root = "/repo/.zigars-cache" },
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
