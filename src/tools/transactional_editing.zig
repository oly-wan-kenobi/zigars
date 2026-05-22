const std = @import("std");
const mcp = @import("mcp");
const zigar = @import("zigar");

const artifacts = zigar.artifacts;
const bootstrap_runtime_ports = zigar.bootstrap.runtime_ports;
const editing_usecase = zigar.app.usecases.editing.patch_sessions;
const json_result = zigar.json_result;
const lsp_edits = zigar.lsp_edits;
const validation_workflows = @import("validation_workflows.zig");
const common = @import("common.zig");

const App = common.App;
const argBool = common.argBool;
const argInt = common.argInt;
const argString = common.argString;
const missingArgumentResult = common.missingArgumentResult;
const invalidArgumentResult = common.invalidArgumentResult;
const structured = common.structured;
const toolErrorFromError = common.toolErrorFromError;
const workspacePathErrorResult = common.workspacePathErrorResult;
const appendPathTokens = common.appendPathTokens;
const appendPatchPaths = common.appendPatchPaths;
const appendUniqueString = common.appendUniqueString;
const stringListContains = common.stringListContains;
const freeStringList = common.freeStringList;
const ownedString = common.ownedString;

const schema_version = editing_usecase.schema_version;
const patch_history_path_default = editing_usecase.history_path_default;
const max_session_file_bytes = editing_usecase.max_session_file_bytes;

fn editingRuntimePorts(a: *App) bootstrap_runtime_ports.RuntimePorts {
    return bootstrap_runtime_ports.RuntimePorts.init(a, .{
        .workspace_read_resolution = .output,
        .default_read_limit = max_session_file_bytes,
    });
}

const FileSnapshot = struct {
    rel: []const u8,
    abs: []const u8,
    bytes: []const u8,
    exists: bool,
    bytes_owned: bool,

    fn deinit(self: FileSnapshot, allocator: std.mem.Allocator) void {
        allocator.free(self.rel);
        allocator.free(self.abs);
        if (self.bytes_owned) allocator.free(self.bytes);
    }
};

const Replacement = editing_usecase.Replacement;
const PathPolicy = editing_usecase.PathPolicy;

const ByteRange = struct {
    start: usize,
    end: usize,
};

pub fn zigarPatchSessionCreate(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    var paths = std.ArrayList([]const u8).empty;
    defer paths.deinit(scratch);
    defer freeStringList(scratch, paths.items);
    try appendPathTokens(scratch, &paths, argString(args, "files"));
    try appendPatchPaths(scratch, &paths, argString(args, "patch"));
    if (argString(args, "edits")) |raw| try appendEditPaths(scratch, &paths, raw);
    const normalized_paths = try normalizePathsBestEffort(scratch, a, paths.items);

    const session_id = try sessionId(scratch, "create", argString(args, "goal"), argString(args, "files"), argString(args, "patch"), argString(args, "edits"));
    var runtime_ports = editingRuntimePorts(a);
    const ctx = runtime_ports.editingContext() catch |err| return validationError(allocator, "zigar_patch_session_create", "build_app_context", err);
    var result = editing_usecase.create(scratch, ctx, .{
        .session_id = session_id,
        .goal = argString(args, "goal"),
        .paths = normalized_paths,
    }) catch |err| return validationError(allocator, "zigar_patch_session_create", "create_session", err);
    defer result.deinit(scratch);
    return structured(allocator, try patchSessionCreateValue(scratch, result));
}

pub fn zigarPatchSessionPreview(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return patchSessionReplacementTool(a, allocator, args, "zigar_patch_session_preview", false);
}

pub fn zigarPatchSessionApply(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return patchSessionReplacementTool(a, allocator, args, "zigar_patch_session_apply", argBool(args, "apply", false));
}

pub fn zigarPatchSessionValidate(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const validation_args = try validationArgsFromSessionArgs(scratch, args);
    var runtime_ports = bootstrap_runtime_ports.RuntimePorts.init(a, .{});
    const validation_ctx = runtime_ports.validationContext() catch |err| return validationError(allocator, "zigar_patch_session_validate", "build_validation_context", err);
    var parsed = validation_workflows.validationRunRequestFromArgs(a, scratch, validation_args) catch |err| return validationError(allocator, "zigar_patch_session_validate", "parse_validation_request", err);
    defer parsed.deinit(scratch);
    var validation_outcome = editing_usecase.validate(scratch, validation_ctx, parsed.request) catch |err| return validationError(allocator, "zigar_patch_session_validate", "run_validation", err);
    defer validation_outcome.deinit(scratch);
    const validation_report = switch (validation_outcome) {
        .ok => |report| report,
        .err => return validationError(allocator, "zigar_patch_session_validate", "run_validation", error.ValidationHistoryWriteFailed),
    };
    const validation_value = validation_workflows.validationRunValue(scratch, validation_report) catch |err| return validationError(allocator, "zigar_patch_session_validate", "render_validation", err);

    var obj = std.json.ObjectMap.empty;
    try obj.put(scratch, "kind", .{ .string = "zigar_patch_session_validate" });
    try obj.put(scratch, "schema_version", .{ .integer = schema_version });
    try obj.put(scratch, "session_id", optionalStringValue(scratch, argString(args, "session_id")) catch .null);
    try obj.put(scratch, "ok", .{ .bool = validation_report.ok });
    try obj.put(scratch, "validation", validation_value);
    try obj.put(scratch, "stop_condition", .{ .string = "Treat skipped validation phases as unknown; rollback remains available only for recorded applied sessions." });
    return structured(allocator, .{ .object = obj });
}

pub fn zigarPatchSessionRevert(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const session_id = argString(args, "session_id") orelse return missingArgumentResult(allocator, "zigar_patch_session_revert", "session_id", "recorded patch session id");
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    var runtime_ports = editingRuntimePorts(a);
    const ctx = runtime_ports.editingContext() catch |err| return validationError(allocator, "zigar_patch_session_revert", "build_app_context", err);
    var outcome = editing_usecase.revert(scratch, ctx, .{
        .session_id = session_id,
        .apply = argBool(args, "apply", false),
        .history = argString(args, "history"),
        .history_path = argString(args, "history_path") orelse patch_history_path_default,
    }) catch |err| return validationError(allocator, "zigar_patch_session_revert", "revert_session", err);
    defer outcome.deinit(scratch);
    return switch (outcome) {
        .ok => |result| structured(allocator, try patchSessionRevertValue(scratch, result)),
        .err => sessionNotFound(allocator, session_id),
    };
}

pub fn zigGeneratedFileTrace(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const path = argString(args, "path") orelse return missingArgumentResult(allocator, "zig_generated_file_trace", "path", "workspace-relative path");
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const resolved = a.workspace.resolveOutput(path) catch |err| return workspacePathErrorResult(a, allocator, "zig_generated_file_trace", path, err);
    defer a.workspace.allocator.free(resolved);
    const rel = a.workspace.relative(resolved);
    const policy = classifyPath(rel);
    var obj = std.json.ObjectMap.empty;
    try obj.put(scratch, "kind", .{ .string = "zig_generated_file_trace" });
    try obj.put(scratch, "schema_version", .{ .integer = schema_version });
    try obj.put(scratch, "path", try ownedString(scratch, rel));
    try obj.put(scratch, "policy", try policyValue(scratch, policy));
    try obj.put(scratch, "evidence_source", .{ .string = "workspace_path_heuristics_and_zigar_generated_path_policy" });
    try obj.put(scratch, "confidence", try ownedString(scratch, policy.confidence));
    return structured(allocator, .{ .object = obj });
}

pub fn zigarEditPolicyCheck(_: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    var paths = std.ArrayList([]const u8).empty;
    defer paths.deinit(scratch);
    defer freeStringList(scratch, paths.items);
    try appendPathTokens(scratch, &paths, argString(args, "files"));
    try appendPatchPaths(scratch, &paths, argString(args, "patch"));

    var checked = std.json.Array.init(scratch);
    var blocked = std.json.Array.init(scratch);
    var allow = true;
    for (paths.items) |path| {
        const policy = classifyPath(path);
        if (!policy.direct_edit_allowed) {
            allow = false;
            try blocked.append(try ownedString(scratch, path));
        }
        var item = std.json.ObjectMap.empty;
        try item.put(scratch, "path", try ownedString(scratch, path));
        try item.put(scratch, "policy", try policyValue(scratch, policy));
        try checked.append(.{ .object = item });
    }

    var obj = std.json.ObjectMap.empty;
    try obj.put(scratch, "kind", .{ .string = "zigar_edit_policy_check" });
    try obj.put(scratch, "schema_version", .{ .integer = schema_version });
    try obj.put(scratch, "allow_direct_edit", .{ .bool = allow });
    try obj.put(scratch, "checked", .{ .array = checked });
    try obj.put(scratch, "blocked_paths", .{ .array = blocked });
    try obj.put(scratch, "write_policy", .{ .string = "Direct source edits must avoid generated, cache, artifact, and vendored paths; mutating tools still require apply=true." });
    return structured(allocator, .{ .object = obj });
}

pub fn zigarGeneratedRoute(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const path = argString(args, "path") orelse return missingArgumentResult(allocator, "zigar_generated_route", "path", "workspace-relative generated or vendored path");
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const resolved = a.workspace.resolveOutput(path) catch |err| return workspacePathErrorResult(a, allocator, "zigar_generated_route", path, err);
    defer a.workspace.allocator.free(resolved);
    const rel = a.workspace.relative(resolved);
    const policy = classifyPath(rel);
    var obj = std.json.ObjectMap.empty;
    try obj.put(scratch, "kind", .{ .string = "zigar_generated_route" });
    try obj.put(scratch, "schema_version", .{ .integer = schema_version });
    try obj.put(scratch, "path", try ownedString(scratch, rel));
    try obj.put(scratch, "goal", optionalStringValue(scratch, argString(args, "goal")) catch .null);
    try obj.put(scratch, "policy", try policyValue(scratch, policy));
    try obj.put(scratch, "route", try ownedString(scratch, policy.route));
    try obj.put(scratch, "source_candidates", try stringArrayValue(scratch, policy.sources));
    try obj.put(scratch, "regeneration_commands", try stringArrayValue(scratch, policy.commands));
    try obj.put(scratch, "stop_condition", .{ .string = "Edit the source or dependency policy, regenerate the derived output, then validate the generated diff before release decisions." });
    return structured(allocator, .{ .object = obj });
}

pub fn zigOrganizeImports(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const file = argString(args, "file") orelse return missingArgumentResult(allocator, "zig_organize_imports", "file", "workspace-relative Zig file");
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const snap = readSnapshot(scratch, a, file) catch |err| return workspacePathErrorResult(a, allocator, "zig_organize_imports", file, err);
    const updated = try organizeImportsText(scratch, snap.bytes);
    const replacements = [_]Replacement{.{ .file = snap.rel, .content = updated }};
    const value = replacementSessionValue(scratch, a, "zig_organize_imports", &replacements, argBool(args, "apply", false), "organize top-level @import declarations", "Only top-level const/pub const @import lines are sorted and deduplicated; scoped imports are left untouched.") catch |err| return validationError(allocator, "zig_organize_imports", "preview_or_apply", err);
    return structured(allocator, value);
}

pub fn zigUpdateImports(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const old_import = argString(args, "old_import") orelse return missingArgumentResult(allocator, "zig_update_imports", "old_import", "existing @import string");
    const new_import = argString(args, "new_import") orelse return missingArgumentResult(allocator, "zig_update_imports", "new_import", "replacement @import string");
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    var files = std.ArrayList([]const u8).empty;
    defer files.deinit(scratch);
    defer freeStringList(scratch, files.items);
    try appendPathTokens(scratch, &files, argString(args, "files"));
    if (argString(args, "file")) |file| try appendUniqueString(scratch, &files, file);
    if (files.items.len == 0) return missingArgumentResult(allocator, "zig_update_imports", "files", "one or more Zig files");

    var replacements = std.ArrayList(Replacement).empty;
    for (files.items) |file| {
        const snap = readSnapshot(scratch, a, file) catch |err| return workspacePathErrorResult(a, allocator, "zig_update_imports", file, err);
        try replacements.append(scratch, .{ .file = try scratch.dupe(u8, snap.rel), .content = try replaceImportText(scratch, snap.bytes, old_import, new_import) });
    }
    const value = replacementSessionValue(scratch, a, "zig_update_imports", replacements.items, argBool(args, "apply", false), "update @import paths", "Import updates are exact string replacements inside @import(\"...\") calls; semantic module moves still need validation.") catch |err| return validationError(allocator, "zig_update_imports", "preview_or_apply", err);
    return structured(allocator, value);
}

pub fn zigMoveDecl(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const source_file = argString(args, "source_file") orelse return missingArgumentResult(allocator, "zig_move_decl", "source_file", "workspace-relative source file");
    const target_file = argString(args, "target_file") orelse return missingArgumentResult(allocator, "zig_move_decl", "target_file", "workspace-relative target file");
    const name = argString(args, "name") orelse return missingArgumentResult(allocator, "zig_move_decl", "name", "top-level declaration name");
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const source = readSnapshot(scratch, a, source_file) catch |err| return workspacePathErrorResult(a, allocator, "zig_move_decl", source_file, err);
    const target = readSnapshot(scratch, a, target_file) catch |err| return workspacePathErrorResult(a, allocator, "zig_move_decl", target_file, err);
    const range = findDeclarationRange(source.bytes, name) orelse return invalidArgumentResult(allocator, "zig_move_decl", "name", "existing top-level declaration", name, "Choose a top-level const/var/fn declaration visible in source_file.");
    const decl_text = std.mem.trim(u8, source.bytes[range.start..range.end], "\n");
    const source_updated = try concat3(scratch, source.bytes[0..range.start], "", source.bytes[range.end..]);
    const target_updated = try appendDeclText(scratch, target.bytes, decl_text);
    const replacements = [_]Replacement{
        .{ .file = source.rel, .content = source_updated },
        .{ .file = target.rel, .content = target_updated },
    };
    const value = replacementSessionValue(scratch, a, "zig_move_decl", &replacements, argBool(args, "apply", false), "move a top-level declaration between files", "Declaration boundaries are syntax-heuristic; run semantic impact and compiler validation after applying.") catch |err| return validationError(allocator, "zig_move_decl", "preview_or_apply", err);
    return structured(allocator, value);
}

pub fn zigExtractDecl(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const file = argString(args, "file") orelse return missingArgumentResult(allocator, "zig_extract_decl", "file", "workspace-relative source file");
    const target_file = argString(args, "target_file") orelse return missingArgumentResult(allocator, "zig_extract_decl", "target_file", "workspace-relative target file");
    if (std.mem.eql(u8, file, target_file)) return invalidArgumentResult(allocator, "zig_extract_decl", "target_file", "different file", target_file, "Choose a different target_file for extraction.");
    const start_line = argInt(args, "start_line", 0);
    const end_line = argInt(args, "end_line", 0);
    if (start_line <= 0 or end_line < start_line) return invalidArgumentResult(allocator, "zig_extract_decl", "start_line/end_line", "1-based inclusive line range", "invalid_range", "Provide start_line >= 1 and end_line >= start_line.");
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const source = readSnapshot(scratch, a, file) catch |err| return workspacePathErrorResult(a, allocator, "zig_extract_decl", file, err);
    const target = readSnapshot(scratch, a, target_file) catch |err| return workspacePathErrorResult(a, allocator, "zig_extract_decl", target_file, err);
    const range = lineRange(source.bytes, @intCast(start_line), @intCast(end_line)) orelse return invalidArgumentResult(allocator, "zig_extract_decl", "start_line/end_line", "line range inside file", "range_out_of_bounds", "Choose a line range that exists in file.");
    const extracted = std.mem.trim(u8, source.bytes[range.start..range.end], "\n");
    const source_updated = try concat3(scratch, source.bytes[0..range.start], "", source.bytes[range.end..]);
    const target_updated = try appendDeclText(scratch, target.bytes, extracted);
    const replacements = [_]Replacement{
        .{ .file = source.rel, .content = source_updated },
        .{ .file = target.rel, .content = target_updated },
    };
    const value = replacementSessionValue(scratch, a, "zig_extract_decl", &replacements, argBool(args, "apply", false), "extract selected lines to a target file", "Extraction is text-range based and does not rewrite call sites or imports automatically.") catch |err| return validationError(allocator, "zig_extract_decl", "preview_or_apply", err);
    return structured(allocator, value);
}

pub fn zigCodeActionBatch(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    _ = args;
    if (a.lsp_client == null) return common.zlsUnavailable(a, allocator);
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zig_code_action_batch" });
    try obj.put(allocator, "schema_version", .{ .integer = schema_version });
    try obj.put(allocator, "ok", .{ .bool = false });
    try obj.put(allocator, "applied", .{ .bool = false });
    try obj.put(allocator, "error_kind", .{ .string = "unsupported_state" });
    try obj.put(allocator, "resolution", .{ .string = "Use zig_code_actions to inspect actions and zig_code_action_apply one action at a time until ZLS exposes transaction-safe batch edits." });
    return structured(allocator, .{ .object = obj });
}

fn patchSessionReplacementTool(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value, tool_name: []const u8, apply: bool) mcp.tools.ToolError!mcp.tools.ToolResult {
    const raw_edits = argString(args, "edits") orelse return missingArgumentResult(allocator, tool_name, "edits", "JSON array of {file, content} replacements");
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    var parsed = std.json.parseFromSlice(std.json.Value, scratch, raw_edits, .{}) catch return invalidArgumentResult(allocator, tool_name, "edits", "valid JSON array or object", "invalid_json", "Pass edits as JSON, for example [{\"file\":\"src/main.zig\",\"content\":\"...\"}].");
    defer parsed.deinit();
    const session_id = if (argString(args, "session_id")) |id| id else try sessionId(scratch, tool_name, argString(args, "goal"), null, null, raw_edits);
    var replacements = std.ArrayList(Replacement).empty;
    try collectReplacements(scratch, &replacements, parsed.value);
    const normalized_replacements = try normalizeReplacementsBestEffort(scratch, a, replacements.items);
    const expected = parseExpectedPreimages(scratch, argString(args, "expected_preimages")) catch |err| return validationError(allocator, tool_name, "parse_expected_preimages", err);
    var runtime_ports = editingRuntimePorts(a);
    const ctx = runtime_ports.editingContext() catch |err| return validationError(allocator, tool_name, "build_app_context", err);
    var result = editing_usecase.replacementSession(scratch, ctx, .{
        .operation = if (apply) .apply else .preview,
        .session_id = session_id,
        .goal = argString(args, "goal"),
        .replacements = normalized_replacements,
        .expected_preimages = expected,
        .apply = apply,
    }) catch |err| return validationError(allocator, tool_name, "build_session", err);
    defer result.deinit(scratch);
    return structured(allocator, try patchSessionReplacementValue(scratch, result));
}

fn patchSessionCreateValue(allocator: std.mem.Allocator, result: editing_usecase.CreateResult) !std.json.Value {
    var files = std.json.Array.init(allocator);
    for (result.files) |file| {
        try files.append(switch (file) {
            .ok => |state| try sessionFileStateTypedValue(allocator, state),
            .err => |failure| try pathFailureNameValue(allocator, failure.file, failure.error_name),
        });
    }
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "kind", .{ .string = "zigar_patch_session_create" });
    try obj.put(allocator, "schema_version", .{ .integer = schema_version });
    try obj.put(allocator, "session_id", try ownedString(allocator, result.session_id));
    try obj.put(allocator, "goal", optionalStringValue(allocator, result.goal) catch .null);
    try obj.put(allocator, "status", .{ .string = "created" });
    try obj.put(allocator, "safe_to_edit", .{ .bool = result.safe_to_edit });
    try obj.put(allocator, "files", .{ .array = files });
    try obj.put(allocator, "expected_preimages", try expectedPreimagesTypedValue(allocator, result.expected_preimages));
    try obj.put(allocator, "next_action", try nextToolValue(allocator, if (result.safe_to_edit) "zigar_patch_session_preview" else "zigar_generated_route", if (result.safe_to_edit) "preview replacement content before applying" else "route generated or vendored paths to source/regeneration"));
    try obj.put(allocator, "limitations", .{ .string = "Session creation captures current file identity and policy only; no source writes or validation commands have run." });
    return .{ .object = obj };
}

fn patchSessionReplacementValue(allocator: std.mem.Allocator, result: editing_usecase.ReplacementResult) !std.json.Value {
    var files = std.json.Array.init(allocator);
    for (result.files) |file| try files.append(try replacementFileValue(allocator, file));
    if (result.blocked) return applyBlockedValueFromUsecase(allocator, result.session_id, files, result.expected_preimages);

    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "kind", .{ .string = result.operation.kind() });
    try obj.put(allocator, "schema_version", .{ .integer = schema_version });
    try obj.put(allocator, "session_id", try ownedString(allocator, result.session_id));
    try obj.put(allocator, "goal", optionalStringValue(allocator, result.goal) catch .null);
    try obj.put(allocator, "applied", .{ .bool = result.applied });
    try obj.put(allocator, "requires_apply", .{ .bool = result.requires_apply });
    try obj.put(allocator, "safe_to_apply", .{ .bool = result.safe_to_apply });
    try obj.put(allocator, "changed_file_count", .{ .integer = @intCast(result.changed_file_count) });
    try obj.put(allocator, "files", .{ .array = files });
    try obj.put(allocator, "expected_preimages", try expectedPreimagesTypedValue(allocator, result.expected_preimages));
    try obj.put(allocator, "history_path", .{ .string = patch_history_path_default });
    try obj.put(allocator, "limitations", .{ .string = "Apply requires expected_preimages from preview and refuses generated/vendor paths; validation must be run separately or through zigar_patch_session_validate." });
    return .{ .object = obj };
}

fn patchSessionRevertValue(allocator: std.mem.Allocator, result: editing_usecase.RevertResult) !std.json.Value {
    var files = std.json.Array.init(allocator);
    for (result.files) |file| try files.append(try revertFileValue(allocator, file));
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "kind", .{ .string = "zigar_patch_session_revert" });
    try obj.put(allocator, "schema_version", .{ .integer = schema_version });
    try obj.put(allocator, "session_id", try ownedString(allocator, result.session_id));
    try obj.put(allocator, "applied", .{ .bool = result.applied });
    try obj.put(allocator, "requires_apply", .{ .bool = result.requires_apply });
    try obj.put(allocator, "safe_to_revert", .{ .bool = result.safe_to_revert });
    try obj.put(allocator, "files", .{ .array = files });
    try obj.put(allocator, "record", try sessionRecordTypedValue(allocator, result.record));
    try obj.put(allocator, "limitations", .{ .string = "Rollback restores only files whose current hash still equals the recorded session output hash; unrelated edits block the revert." });
    return .{ .object = obj };
}

fn sessionFileStateTypedValue(allocator: std.mem.Allocator, state: editing_usecase.SessionFileState) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "file", try ownedString(allocator, state.file));
    try obj.put(allocator, "preimage_identity", try identityTypedValue(allocator, state.preimage_identity));
    try obj.put(allocator, "policy", try policyValue(allocator, state.policy));
    return .{ .object = obj };
}

fn replacementFileValue(allocator: std.mem.Allocator, file: editing_usecase.ReplacementFile) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "file", try ownedString(allocator, file.file));
    try obj.put(allocator, "changed", .{ .bool = file.changed });
    try obj.put(allocator, "preimage_identity", try identityTypedValue(allocator, file.preimage_identity));
    try obj.put(allocator, "updated_identity", try identityTypedValue(allocator, file.updated_identity));
    try obj.put(allocator, "policy", try policyValue(allocator, file.policy));
    try obj.put(allocator, "expected_preimage_matched", .{ .bool = file.expected_preimage_matched });
    try obj.put(allocator, "diff", .{ .string = try allocator.dupe(u8, file.diff) });
    return .{ .object = obj };
}

fn revertFileValue(allocator: std.mem.Allocator, file: editing_usecase.RevertFile) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "file", try ownedString(allocator, file.file));
    try obj.put(allocator, "safe_to_revert", .{ .bool = file.safe_to_revert });
    try obj.put(allocator, "current_matches_session_output", .{ .bool = file.current_matches_session_output });
    try obj.put(allocator, "current_identity", try identityTypedValue(allocator, file.current_identity));
    try obj.put(allocator, "target_preimage_identity", try identityTypedValue(allocator, file.target_preimage_identity));
    try obj.put(allocator, "preimage_content_path", optionalStringValue(allocator, file.preimage_content_path) catch .null);
    try obj.put(allocator, "would_delete", .{ .bool = file.would_delete });
    try obj.put(allocator, "diff", .{ .string = try allocator.dupe(u8, file.diff) });
    return .{ .object = obj };
}

fn sessionRecordTypedValue(allocator: std.mem.Allocator, record: editing_usecase.SessionRecord) !std.json.Value {
    var files = std.json.Array.init(allocator);
    for (record.files) |file| try files.append(try historyFileRecordValue(allocator, file));
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "kind", .{ .string = "zigar_patch_session_record" });
    try obj.put(allocator, "schema_version", .{ .integer = schema_version });
    try obj.put(allocator, "session_id", try ownedString(allocator, record.session_id));
    try obj.put(allocator, "goal", optionalStringValue(allocator, record.goal) catch .null);
    try obj.put(allocator, "recorded_unix_ms", .{ .integer = record.recorded_unix_ms });
    try obj.put(allocator, "files", .{ .array = files });
    return .{ .object = obj };
}

fn historyFileRecordValue(allocator: std.mem.Allocator, file: editing_usecase.HistoryFileRecord) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "file", try ownedString(allocator, file.file));
    try obj.put(allocator, "preimage_identity", try identityTypedValue(allocator, file.preimage_identity));
    try obj.put(allocator, "updated_identity", try identityTypedValue(allocator, file.updated_identity));
    try obj.put(allocator, "preimage_content_path", optionalStringValue(allocator, file.preimage_content_path) catch .null);
    return .{ .object = obj };
}

fn identityTypedValue(allocator: std.mem.Allocator, identity: editing_usecase.Identity) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "exists", .{ .bool = identity.exists });
    try obj.put(allocator, "bytes", .{ .integer = @intCast(identity.bytes) });
    try obj.put(allocator, "sha256", if (identity.sha256) |hash| try ownedString(allocator, hash) else .null);
    return .{ .object = obj };
}

fn expectedPreimagesTypedValue(allocator: std.mem.Allocator, expected: []const editing_usecase.ExpectedPreimage) !std.json.Value {
    var array = std.json.Array.init(allocator);
    for (expected) |item| try array.append(try expectedPreimageTypedValue(allocator, item));
    return .{ .array = array };
}

fn expectedPreimageTypedValue(allocator: std.mem.Allocator, item: editing_usecase.ExpectedPreimage) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "file", try ownedString(allocator, item.file));
    try obj.put(allocator, "exists", .{ .bool = item.identity.exists });
    try obj.put(allocator, "bytes", .{ .integer = @intCast(item.identity.bytes) });
    try obj.put(allocator, "sha256", if (item.identity.sha256) |hash| try ownedString(allocator, hash) else .null);
    return .{ .object = obj };
}

fn applyBlockedValueFromUsecase(allocator: std.mem.Allocator, session_id: []const u8, files: std.json.Array, expected_preimages: []const editing_usecase.ExpectedPreimage) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "kind", .{ .string = "zigar_patch_session_apply" });
    try obj.put(allocator, "schema_version", .{ .integer = schema_version });
    try obj.put(allocator, "session_id", try ownedString(allocator, session_id));
    try obj.put(allocator, "applied", .{ .bool = false });
    try obj.put(allocator, "safe_to_apply", .{ .bool = false });
    try obj.put(allocator, "files", .{ .array = files });
    try obj.put(allocator, "expected_preimages", try expectedPreimagesTypedValue(allocator, expected_preimages));
    try obj.put(allocator, "resolution", .{ .string = "Re-run preview, pass its expected_preimages unchanged, and avoid generated or vendored paths." });
    return .{ .object = obj };
}

fn pathFailureNameValue(allocator: std.mem.Allocator, path: []const u8, error_name: []const u8) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "file", try ownedString(allocator, path));
    try obj.put(allocator, "ok", .{ .bool = false });
    try obj.put(allocator, "error", try ownedString(allocator, error_name));
    return .{ .object = obj };
}

fn parseExpectedPreimages(allocator: std.mem.Allocator, raw: ?[]const u8) ![]const editing_usecase.ExpectedPreimage {
    const text = raw orelse return &.{};
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, text, .{});
    defer parsed.deinit();
    const array = switch (parsed.value) {
        .array => |items| items,
        else => return error.InvalidArguments,
    };
    var out = std.ArrayList(editing_usecase.ExpectedPreimage).empty;
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

fn normalizePathsBestEffort(allocator: std.mem.Allocator, a: *App, paths: []const []const u8) std.mem.Allocator.Error![]const []const u8 {
    var out = std.ArrayList([]const u8).empty;
    for (paths) |path| {
        const normalized = normalizePath(allocator, a, path) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => try allocator.dupe(u8, path),
        };
        try out.append(allocator, normalized);
    }
    return out.toOwnedSlice(allocator);
}

fn normalizeReplacementsBestEffort(allocator: std.mem.Allocator, a: *App, replacements: []const Replacement) std.mem.Allocator.Error![]const Replacement {
    var out = std.ArrayList(Replacement).empty;
    for (replacements) |replacement| {
        const normalized = normalizePath(allocator, a, replacement.file) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => try allocator.dupe(u8, replacement.file),
        };
        try out.append(allocator, .{
            .file = normalized,
            .content = replacement.content,
        });
    }
    return out.toOwnedSlice(allocator);
}

fn normalizePath(allocator: std.mem.Allocator, a: *App, path: []const u8) ![]const u8 {
    const resolved = try a.workspace.resolveOutput(path);
    defer a.workspace.allocator.free(resolved);
    return allocator.dupe(u8, a.workspace.relative(resolved));
}

fn buildPatchSessionReplacementValue(allocator: std.mem.Allocator, a: *App, edits_value: std.json.Value, session_id: []const u8, goal: ?[]const u8, expected: std.json.Value, apply: bool) !std.json.Value {
    var files = std.json.Array.init(allocator);
    var expected_preimages = std.json.Array.init(allocator);
    var history_files = std.json.Array.init(allocator);
    var replacements = std.ArrayList(Replacement).empty;
    try collectReplacements(allocator, &replacements, edits_value);

    var safe = true;
    var changed_count: usize = 0;
    for (replacements.items, 0..) |replacement, index| {
        const snap = try readSnapshot(allocator, a, replacement.file);
        const policy = classifyPath(snap.rel);
        const source_hash = try hashOrNull(allocator, snap.exists, snap.bytes);
        const changed = !snap.exists or !std.mem.eql(u8, snap.bytes, replacement.content);
        if (changed) changed_count += 1;
        const expected_ok = !apply or expectedMatches(expected, snap.rel, snap.exists, source_hash);
        if (!policy.direct_edit_allowed or !expected_ok) safe = false;
        const diff = try lsp_edits.unifiedDiff(allocator, snap.rel, snap.bytes, replacement.content);
        const preimage = try identityValue(allocator, snap.exists, snap.bytes);
        const updated_identity = try identityValue(allocator, true, replacement.content);
        try expected_preimages.append(try expectedPreimageValue(allocator, snap.rel, snap.exists, snap.bytes));
        var item = std.json.ObjectMap.empty;
        try item.put(allocator, "file", try ownedString(allocator, snap.rel));
        try item.put(allocator, "changed", .{ .bool = changed });
        try item.put(allocator, "preimage_identity", preimage);
        try item.put(allocator, "updated_identity", updated_identity);
        try item.put(allocator, "policy", try policyValue(allocator, policy));
        try item.put(allocator, "expected_preimage_matched", .{ .bool = expected_ok });
        try item.put(allocator, "diff", .{ .string = diff });
        try files.append(.{ .object = item });

        var hist = std.json.ObjectMap.empty;
        try hist.put(allocator, "file", try ownedString(allocator, snap.rel));
        try hist.put(allocator, "preimage_identity", try identityValue(allocator, snap.exists, snap.bytes));
        try hist.put(allocator, "updated_identity", try identityValue(allocator, true, replacement.content));
        try hist.put(allocator, "preimage_content_path", if (changed) try ownedString(allocator, try preimageArtifactPath(allocator, session_id, index, snap.rel)) else .null);
        try history_files.append(.{ .object = hist });
    }

    if (apply and !safe) return applyBlockedValue(allocator, session_id, files, expected_preimages);
    if (apply) {
        for (replacements.items, 0..) |replacement, index| {
            const snap = try readSnapshot(allocator, a, replacement.file);
            if (!snap.exists or !std.mem.eql(u8, snap.bytes, replacement.content)) {
                const artifact_path = try preimageArtifactPath(allocator, session_id, index, snap.rel);
                try a.workspace.writeFile(a.io, artifact_path, snap.bytes);
                try a.workspace.writeFile(a.io, snap.rel, replacement.content);
            }
        }
        const record = try sessionRecordValue(allocator, a, session_id, goal, history_files);
        try appendSessionHistory(allocator, a, patch_history_path_default, record);
    }

    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "kind", .{ .string = if (apply) "zigar_patch_session_apply" else "zigar_patch_session_preview" });
    try obj.put(allocator, "schema_version", .{ .integer = schema_version });
    try obj.put(allocator, "session_id", try ownedString(allocator, session_id));
    try obj.put(allocator, "goal", optionalStringValue(allocator, goal) catch .null);
    try obj.put(allocator, "applied", .{ .bool = apply });
    try obj.put(allocator, "requires_apply", .{ .bool = !apply });
    try obj.put(allocator, "safe_to_apply", .{ .bool = safe });
    try obj.put(allocator, "changed_file_count", .{ .integer = @intCast(changed_count) });
    try obj.put(allocator, "files", .{ .array = files });
    try obj.put(allocator, "expected_preimages", .{ .array = expected_preimages });
    try obj.put(allocator, "history_path", .{ .string = patch_history_path_default });
    try obj.put(allocator, "limitations", .{ .string = "Apply requires expected_preimages from preview and refuses generated/vendor paths; validation must be run separately or through zigar_patch_session_validate." });
    return .{ .object = obj };
}

fn replacementSessionValue(allocator: std.mem.Allocator, a: *App, tool_name: []const u8, replacements: []const Replacement, apply: bool, goal: []const u8, limitation: []const u8) !std.json.Value {
    var files = std.json.Array.init(allocator);
    var safe = true;
    for (replacements) |replacement| {
        const snap = try readSnapshot(allocator, a, replacement.file);
        const policy = classifyPath(snap.rel);
        if (!policy.direct_edit_allowed) safe = false;
        const diff = try lsp_edits.unifiedDiff(allocator, snap.rel, snap.bytes, replacement.content);
        var item = std.json.ObjectMap.empty;
        try item.put(allocator, "file", try ownedString(allocator, snap.rel));
        try item.put(allocator, "changed", .{ .bool = !snap.exists or !std.mem.eql(u8, snap.bytes, replacement.content) });
        try item.put(allocator, "preimage_identity", try identityValue(allocator, snap.exists, snap.bytes));
        try item.put(allocator, "updated_identity", try identityValue(allocator, true, replacement.content));
        try item.put(allocator, "policy", try policyValue(allocator, policy));
        try item.put(allocator, "diff", .{ .string = diff });
        try files.append(.{ .object = item });
    }
    if (apply and safe) {
        for (replacements) |replacement| {
            const snap = try readSnapshot(allocator, a, replacement.file);
            if (!snap.exists or !std.mem.eql(u8, snap.bytes, replacement.content)) try a.workspace.writeFile(a.io, snap.rel, replacement.content);
        }
    }
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "kind", try ownedString(allocator, tool_name));
    try obj.put(allocator, "schema_version", .{ .integer = schema_version });
    try obj.put(allocator, "applied", .{ .bool = apply and safe });
    try obj.put(allocator, "requires_apply", .{ .bool = !apply });
    try obj.put(allocator, "safe_to_apply", .{ .bool = safe });
    try obj.put(allocator, "goal", try ownedString(allocator, goal));
    try obj.put(allocator, "files", .{ .array = files });
    try obj.put(allocator, "limitations", try ownedString(allocator, limitation));
    try obj.put(allocator, "next_action", try nextToolValue(allocator, "zigar_patch_session_validate", "validate the refactor before treating it as complete"));
    return .{ .object = obj };
}

fn readSnapshot(allocator: std.mem.Allocator, a: *App, path: []const u8) !FileSnapshot {
    const resolved_tmp = try a.workspace.resolveOutput(path);
    defer a.workspace.allocator.free(resolved_tmp);
    const abs = try allocator.dupe(u8, resolved_tmp);
    errdefer allocator.free(abs);
    const rel = try allocator.dupe(u8, a.workspace.relative(resolved_tmp));
    errdefer allocator.free(rel);
    const bytes = std.Io.Dir.cwd().readFileAlloc(a.io, abs, allocator, .limited(max_session_file_bytes)) catch |err| switch (err) {
        error.FileNotFound => return .{ .rel = rel, .abs = abs, .bytes = "", .exists = false, .bytes_owned = false },
        else => return err,
    };
    return .{ .rel = rel, .abs = abs, .bytes = bytes, .exists = true, .bytes_owned = true };
}

fn classifyPath(path: []const u8) PathPolicy {
    return editing_usecase.classifyPath(path);
}

fn policyValue(allocator: std.mem.Allocator, policy: PathPolicy) !std.json.Value {
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

fn identityValue(allocator: std.mem.Allocator, exists: bool, bytes: []const u8) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "exists", .{ .bool = exists });
    try obj.put(allocator, "bytes", .{ .integer = if (exists) @as(i64, @intCast(bytes.len)) else 0 });
    try obj.put(allocator, "sha256", if (exists) .{ .string = try artifacts.sha256Hex(allocator, bytes) } else .null);
    return .{ .object = obj };
}

fn expectedPreimageValue(allocator: std.mem.Allocator, file: []const u8, exists: bool, bytes: []const u8) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "file", try ownedString(allocator, file));
    try obj.put(allocator, "exists", .{ .bool = exists });
    try obj.put(allocator, "bytes", .{ .integer = if (exists) @as(i64, @intCast(bytes.len)) else 0 });
    try obj.put(allocator, "sha256", if (exists) .{ .string = try artifacts.sha256Hex(allocator, bytes) } else .null);
    return .{ .object = obj };
}

fn hashOrNull(allocator: std.mem.Allocator, exists: bool, bytes: []const u8) !?[]const u8 {
    if (!exists) return null;
    return try artifacts.sha256Hex(allocator, bytes);
}

fn expectedMatches(expected: std.json.Value, file: []const u8, exists: bool, sha: ?[]const u8) bool {
    const array = switch (expected) {
        .array => |a| a,
        else => return false,
    };
    for (array.items) |item| {
        const obj = switch (item) {
            .object => |o| o,
            else => continue,
        };
        if (!std.mem.eql(u8, stringField(obj, "file") orelse "", file)) continue;
        if ((boolField(obj, "exists") orelse false) != exists) return false;
        const expected_sha = switch (obj.get("sha256") orelse .null) {
            .string => |s| s,
            else => null,
        };
        if (sha == null and expected_sha == null) return true;
        if (sha == null or expected_sha == null) return false;
        return std.mem.eql(u8, sha.?, expected_sha.?);
    }
    return false;
}

fn sessionFileStateValue(allocator: std.mem.Allocator, file: []const u8, preimage: std.json.Value, policy: PathPolicy) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "file", try ownedString(allocator, file));
    try obj.put(allocator, "preimage_identity", preimage);
    try obj.put(allocator, "policy", try policyValue(allocator, policy));
    return .{ .object = obj };
}

fn collectReplacements(allocator: std.mem.Allocator, replacements: *std.ArrayList(Replacement), value: std.json.Value) !void {
    switch (value) {
        .array => |array| {
            for (array.items) |item| try appendReplacement(allocator, replacements, item);
        },
        .object => |obj| {
            if (obj.get("files")) |files| {
                const array = switch (files) {
                    .array => |a| a,
                    else => return error.InvalidArguments,
                };
                for (array.items) |item| try appendReplacement(allocator, replacements, item);
            } else {
                try appendReplacement(allocator, replacements, value);
            }
        },
        else => return error.InvalidArguments,
    }
}

fn appendReplacement(allocator: std.mem.Allocator, replacements: *std.ArrayList(Replacement), value: std.json.Value) !void {
    const obj = switch (value) {
        .object => |o| o,
        else => return error.InvalidArguments,
    };
    const file = stringField(obj, "file") orelse stringField(obj, "path") orelse return error.InvalidArguments;
    const content = stringField(obj, "content") orelse return error.InvalidArguments;
    try replacements.append(allocator, .{ .file = file, .content = content });
}

fn appendEditPaths(allocator: std.mem.Allocator, paths: *std.ArrayList([]const u8), raw_edits: []const u8) !void {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, raw_edits, .{}) catch return;
    defer parsed.deinit();
    var replacements = std.ArrayList(Replacement).empty;
    try collectReplacements(allocator, &replacements, parsed.value);
    for (replacements.items) |replacement| try appendUniqueString(allocator, paths, replacement.file);
}

fn sessionRecordValue(allocator: std.mem.Allocator, a: *App, session_id: []const u8, goal: ?[]const u8, files: std.json.Array) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "kind", .{ .string = "zigar_patch_session_record" });
    try obj.put(allocator, "schema_version", .{ .integer = schema_version });
    try obj.put(allocator, "session_id", try ownedString(allocator, session_id));
    try obj.put(allocator, "goal", optionalStringValue(allocator, goal) catch .null);
    const recorded_unix_ms: i64 = @intCast(@divTrunc(std.Io.Clock.now(.real, a.io).nanoseconds, std.time.ns_per_ms));
    try obj.put(allocator, "recorded_unix_ms", .{ .integer = recorded_unix_ms });
    try obj.put(allocator, "files", .{ .array = files });
    return .{ .object = obj };
}

fn appendSessionHistory(allocator: std.mem.Allocator, a: *App, path: []const u8, record: std.json.Value) !void {
    const line = try jsonLine(allocator, record);
    var existing_owned = false;
    const existing = blk: {
        const bytes = a.workspace.readFileAlloc(a.io, path, 8 * 1024 * 1024) catch |err| switch (err) {
            error.FileNotFound => break :blk "",
            else => return err,
        };
        existing_owned = true;
        break :blk bytes;
    };
    defer if (existing_owned) a.workspace.allocator.free(existing);
    var bytes = std.ArrayList(u8).empty;
    try bytes.appendSlice(allocator, existing);
    if (bytes.items.len > 0 and bytes.items[bytes.items.len - 1] != '\n') try bytes.append(allocator, '\n');
    try bytes.appendSlice(allocator, line);
    try bytes.append(allocator, '\n');
    try a.workspace.writeFile(a.io, path, bytes.items);
}

fn loadSessionRecord(allocator: std.mem.Allocator, a: *App, args: ?std.json.Value, session_id: []const u8) !std.json.Value {
    const text: []const u8 = if (argString(args, "history")) |history|
        history
    else blk: {
        const path = argString(args, "history_path") orelse patch_history_path_default;
        break :blk try a.workspace.readFileAlloc(a.io, path, 8 * 1024 * 1024);
    };
    const text_owned = argString(args, "history") == null;
    defer if (text_owned) a.workspace.allocator.free(text);
    const parsed = try parseJsonLinesOrArray(allocator, text);
    for (parsed.items) |record| {
        const obj = switch (record) {
            .object => |o| o,
            else => continue,
        };
        if (std.mem.eql(u8, stringField(obj, "session_id") orelse "", session_id)) return record;
    }
    return .null;
}

fn revertFilePreviewValue(allocator: std.mem.Allocator, a: *App, record_file: std.json.ObjectMap) !std.json.Value {
    const file = stringField(record_file, "file") orelse return error.InvalidArguments;
    const snap = try readSnapshot(allocator, a, file);
    const updated = switch (record_file.get("updated_identity") orelse .null) {
        .object => |o| o,
        else => return error.InvalidArguments,
    };
    const expected_updated_sha = stringField(updated, "sha256") orelse "";
    const current_sha = if (snap.exists) try artifacts.sha256Hex(allocator, snap.bytes) else "";
    const current_matches = snap.exists and std.mem.eql(u8, current_sha, expected_updated_sha);
    const preimage_path = stringField(record_file, "preimage_content_path");
    const preimage = switch (record_file.get("preimage_identity") orelse .null) {
        .object => |o| o,
        else => return error.InvalidArguments,
    };
    const preimage_exists = boolField(preimage, "exists") orelse false;
    const preimage_bytes = if (preimage_exists and preimage_path != null) try a.workspace.readFileAlloc(a.io, preimage_path.?, max_session_file_bytes) else "";
    defer if (preimage_exists and preimage_path != null) a.workspace.allocator.free(preimage_bytes);
    const diff = try lsp_edits.unifiedDiff(allocator, snap.rel, snap.bytes, preimage_bytes);
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "file", try ownedString(allocator, snap.rel));
    try obj.put(allocator, "safe_to_revert", .{ .bool = current_matches });
    try obj.put(allocator, "current_matches_session_output", .{ .bool = current_matches });
    try obj.put(allocator, "current_identity", try identityValue(allocator, snap.exists, snap.bytes));
    try obj.put(allocator, "target_preimage_identity", try json_result.cloneValue(allocator, record_file.get("preimage_identity") orelse .null));
    try obj.put(allocator, "preimage_content_path", optionalStringValue(allocator, preimage_path) catch .null);
    try obj.put(allocator, "would_delete", .{ .bool = !preimage_exists });
    try obj.put(allocator, "diff", .{ .string = diff });
    return .{ .object = obj };
}

fn applyRevertFile(a: *App, record_file: std.json.ObjectMap) !void {
    const file = stringField(record_file, "file") orelse return error.InvalidArguments;
    const preimage = switch (record_file.get("preimage_identity") orelse .null) {
        .object => |o| o,
        else => return error.InvalidArguments,
    };
    if (!(boolField(preimage, "exists") orelse false)) {
        const resolved = try a.workspace.resolve(file);
        defer a.workspace.allocator.free(resolved);
        std.Io.Dir.cwd().deleteFile(a.io, resolved) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
        return;
    }
    const preimage_path = stringField(record_file, "preimage_content_path") orelse return error.InvalidArguments;
    const bytes = try a.workspace.readFileAlloc(a.io, preimage_path, max_session_file_bytes);
    defer a.workspace.allocator.free(bytes);
    try a.workspace.writeFile(a.io, file, bytes);
}

fn organizeImportsText(allocator: std.mem.Allocator, source: []const u8) ![]const u8 {
    var imports = std.ArrayList([]const u8).empty;
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| {
        if (isTopLevelImportLine(line) and !stringListContains(imports.items, line)) try imports.append(allocator, try allocator.dupe(u8, line));
    }
    if (imports.items.len <= 1) return allocator.dupe(u8, source);
    std.mem.sort([]const u8, imports.items, {}, stringLessThan);
    var out = std.ArrayList(u8).empty;
    var inserted = false;
    lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| {
        if (isTopLevelImportLine(line)) {
            if (!inserted) {
                for (imports.items) |import_line| {
                    try out.appendSlice(allocator, import_line);
                    try out.append(allocator, '\n');
                }
                inserted = true;
            }
            continue;
        }
        const more = lines.index != null;
        if (line.len == 0 and !more and std.mem.endsWith(u8, source, "\n")) break;
        try out.appendSlice(allocator, line);
        if (more or std.mem.endsWith(u8, source, "\n")) try out.append(allocator, '\n');
    }
    return out.toOwnedSlice(allocator);
}

fn isTopLevelImportLine(line: []const u8) bool {
    if (line.len == 0 or line[0] == ' ' or line[0] == '\t') return false;
    return (std.mem.startsWith(u8, line, "const ") or std.mem.startsWith(u8, line, "pub const ")) and std.mem.indexOf(u8, line, "@import(\"") != null;
}

fn replaceImportText(allocator: std.mem.Allocator, source: []const u8, old_import: []const u8, new_import: []const u8) ![]const u8 {
    const needle = try std.fmt.allocPrint(allocator, "@import(\"{s}\")", .{old_import});
    const replacement = try std.fmt.allocPrint(allocator, "@import(\"{s}\")", .{new_import});
    return replaceAll(allocator, source, needle, replacement);
}

fn replaceAll(allocator: std.mem.Allocator, source: []const u8, needle: []const u8, replacement: []const u8) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    var index: usize = 0;
    while (std.mem.indexOf(u8, source[index..], needle)) |match_rel| {
        const match_abs = index + match_rel;
        try out.appendSlice(allocator, source[index..match_abs]);
        try out.appendSlice(allocator, replacement);
        index = match_abs + needle.len;
    }
    try out.appendSlice(allocator, source[index..]);
    return out.toOwnedSlice(allocator);
}

fn findDeclarationRange(source: []const u8, name: []const u8) ?ByteRange {
    var lines = std.mem.splitScalar(u8, source, '\n');
    var offset: usize = 0;
    var start: ?usize = null;
    var end: usize = source.len;
    while (lines.next()) |line| {
        const line_end = offset + line.len + if (offset + line.len < source.len) @as(usize, 1) else 0;
        if (start == null and isNamedDeclLine(line, name)) {
            start = offset;
        } else if (start != null and offset > start.? and isTopLevelDeclLine(line)) {
            end = offset;
            break;
        }
        offset = line_end;
    }
    if (start) |s| return .{ .start = s, .end = end };
    return null;
}

fn isNamedDeclLine(line: []const u8, name: []const u8) bool {
    if (!isTopLevelDeclLine(line)) return false;
    const needles = [_][]const u8{ "const ", "var ", "fn " };
    for (needles) |needle| {
        if (declLineContainsName(line, needle, name)) return true;
    }
    return false;
}

fn declLineContainsName(line: []const u8, marker: []const u8, name: []const u8) bool {
    const index = std.mem.indexOf(u8, line, marker) orelse return false;
    const rest = line[index + marker.len ..];
    return std.mem.startsWith(u8, rest, name) and (rest.len == name.len or !isIdentChar(rest[name.len]));
}

fn isTopLevelDeclLine(line: []const u8) bool {
    if (line.len == 0 or line[0] == ' ' or line[0] == '\t') return false;
    return std.mem.startsWith(u8, line, "pub const ") or std.mem.startsWith(u8, line, "const ") or
        std.mem.startsWith(u8, line, "pub var ") or std.mem.startsWith(u8, line, "var ") or
        std.mem.startsWith(u8, line, "pub fn ") or std.mem.startsWith(u8, line, "fn ") or
        std.mem.startsWith(u8, line, "export fn ") or std.mem.startsWith(u8, line, "extern fn ");
}

fn isIdentChar(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_';
}

fn lineRange(source: []const u8, start_line: usize, end_line: usize) ?ByteRange {
    var line: usize = 1;
    var offset: usize = 0;
    var start: ?usize = null;
    var end: ?usize = null;
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |text| {
        const line_end = offset + text.len + if (offset + text.len < source.len) @as(usize, 1) else 0;
        if (line == start_line) start = offset;
        if (line == end_line) {
            end = line_end;
            break;
        }
        offset = line_end;
        line += 1;
    }
    if (start) |s| if (end) |e| return .{ .start = s, .end = e };
    return null;
}

fn appendDeclText(allocator: std.mem.Allocator, target: []const u8, decl_text: []const u8) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    try out.appendSlice(allocator, target);
    if (out.items.len > 0 and out.items[out.items.len - 1] != '\n') try out.append(allocator, '\n');
    if (out.items.len > 0) try out.append(allocator, '\n');
    try out.appendSlice(allocator, decl_text);
    try out.append(allocator, '\n');
    return out.toOwnedSlice(allocator);
}

fn concat3(allocator: std.mem.Allocator, a: []const u8, b: []const u8, c: []const u8) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    try out.appendSlice(allocator, a);
    try out.appendSlice(allocator, b);
    try out.appendSlice(allocator, c);
    return out.toOwnedSlice(allocator);
}

fn validationArgsFromSessionArgs(allocator: std.mem.Allocator, args: ?std.json.Value) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    inline for (.{ "mode", "changed_files", "diff", "goal", "output" }) |field| {
        if (argString(args, field)) |value| try obj.put(allocator, field, try ownedString(allocator, value));
    }
    inline for (.{ "include_semantic", "stop_on_failure", "apply" }) |field| {
        if (mcp.tools.getBoolean(args, field)) |value| try obj.put(allocator, field, .{ .bool = value });
    }
    if (mcp.tools.getInteger(args, "timeout_ms")) |value| try obj.put(allocator, "timeout_ms", .{ .integer = value });
    if (obj.get("changed_files") == null) {
        var paths = std.ArrayList([]const u8).empty;
        defer paths.deinit(allocator);
        defer freeStringList(allocator, paths.items);
        if (argString(args, "edits")) |raw| try appendEditPaths(allocator, &paths, raw);
        if (paths.items.len > 0) try obj.put(allocator, "changed_files", try joinedStringsValue(allocator, paths.items));
    }
    return .{ .object = obj };
}

fn parseOptionalJson(allocator: std.mem.Allocator, raw: ?[]const u8) !std.json.Value {
    const text = raw orelse return .null;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, text, .{});
    defer parsed.deinit();
    return try json_result.cloneValue(allocator, parsed.value);
}

fn parseJsonLinesOrArray(allocator: std.mem.Allocator, text: []const u8) !std.json.Array {
    var out = std.json.Array.init(allocator);
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) return out;
    if (trimmed[0] == '[') {
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{});
        defer parsed.deinit();
        const array = switch (parsed.value) {
            .array => |a| a,
            else => return out,
        };
        for (array.items) |item| try out.append(try json_result.cloneValue(allocator, item));
        return out;
    }
    var lines = std.mem.splitScalar(u8, trimmed, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r");
        if (line.len == 0) continue;
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
        defer parsed.deinit();
        try out.append(try json_result.cloneValue(allocator, parsed.value));
    }
    return out;
}

fn applyBlockedValue(allocator: std.mem.Allocator, session_id: []const u8, files: std.json.Array, expected_preimages: std.json.Array) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "kind", .{ .string = "zigar_patch_session_apply" });
    try obj.put(allocator, "schema_version", .{ .integer = schema_version });
    try obj.put(allocator, "session_id", try ownedString(allocator, session_id));
    try obj.put(allocator, "applied", .{ .bool = false });
    try obj.put(allocator, "safe_to_apply", .{ .bool = false });
    try obj.put(allocator, "files", .{ .array = files });
    try obj.put(allocator, "expected_preimages", .{ .array = expected_preimages });
    try obj.put(allocator, "resolution", .{ .string = "Re-run preview, pass its expected_preimages unchanged, and avoid generated or vendored paths." });
    return .{ .object = obj };
}

fn pathFailureValue(allocator: std.mem.Allocator, path: []const u8, err: anyerror) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "file", try ownedString(allocator, path));
    try obj.put(allocator, "ok", .{ .bool = false });
    try obj.put(allocator, "error", .{ .string = @errorName(err) });
    return .{ .object = obj };
}

fn validationError(allocator: std.mem.Allocator, tool_name: []const u8, phase: []const u8, err: anyerror) mcp.tools.ToolError!mcp.tools.ToolResult {
    return toolErrorFromError(allocator, .{
        .tool = tool_name,
        .operation = "transactional_editing",
        .phase = phase,
        .code = "transactional_editing_failed",
        .category = "transactional_editing",
        .resolution = "Inspect structured fields, fix invalid arguments or workspace state, then retry.",
    }, err);
}

fn sessionNotFound(allocator: std.mem.Allocator, session_id: []const u8) mcp.tools.ToolError!mcp.tools.ToolResult {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zigar_patch_session_revert" });
    try obj.put(allocator, "ok", .{ .bool = false });
    try obj.put(allocator, "session_id", .{ .string = session_id });
    try obj.put(allocator, "error_kind", .{ .string = "not_found" });
    try obj.put(allocator, "resolution", .{ .string = "Pass history/history_path containing a zigar_patch_session_record emitted by zigar_patch_session_apply apply=true." });
    return structured(allocator, .{ .object = obj });
}

fn preimageArtifactPath(allocator: std.mem.Allocator, session_id: []const u8, index: usize, file: []const u8) ![]const u8 {
    const safe = try sanitizePath(allocator, file);
    return std.fmt.allocPrint(allocator, ".zigar-cache/patch-sessions/{s}/{d}-{s}.preimage", .{ session_id, index, safe });
}

fn sanitizePath(allocator: std.mem.Allocator, file: []const u8) ![]const u8 {
    const out = try allocator.dupe(u8, file);
    for (out) |*ch| {
        if (ch.* == '/' or ch.* == '\\' or ch.* == ':' or ch.* == ' ') ch.* = '_';
    }
    return out;
}

fn sessionId(allocator: std.mem.Allocator, prefix: []const u8, goal: ?[]const u8, a: ?[]const u8, b: ?[]const u8, c: ?[]const u8) ![]const u8 {
    var seed = std.ArrayList(u8).empty;
    try seed.appendSlice(allocator, prefix);
    if (goal) |value| try seed.appendSlice(allocator, value);
    if (a) |value| try seed.appendSlice(allocator, value);
    if (b) |value| try seed.appendSlice(allocator, value);
    if (c) |value| try seed.appendSlice(allocator, value);
    const hash = try artifacts.sha256Hex(allocator, seed.items);
    return std.fmt.allocPrint(allocator, "session-{s}", .{hash[0..16]});
}

fn jsonLine(allocator: std.mem.Allocator, value: std.json.Value) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    try json_result.serializeValue(allocator, &out, value);
    return out.toOwnedSlice(allocator);
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

fn optionalStringValue(allocator: std.mem.Allocator, value: ?[]const u8) !std.json.Value {
    if (value) |text| return ownedString(allocator, text);
    return .null;
}

fn nextToolValue(allocator: std.mem.Allocator, tool: []const u8, reason: []const u8) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "tool", try ownedString(allocator, tool));
    try obj.put(allocator, "reason", try ownedString(allocator, reason));
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
        .integer => |value| value,
        else => null,
    };
}

fn stringLessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
    return std.mem.order(u8, lhs, rhs) == .lt;
}
