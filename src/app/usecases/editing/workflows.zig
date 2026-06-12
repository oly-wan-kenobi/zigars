//! Focused editing workflows for file snapshots, replacements, renames, and formatting.
//!
//! Source-mutating entry points require explicit `apply=true`; preview results
//! own their returned JSON values.
const std = @import("std");

const app_context = @import("../../context.zig");
const core_commands = @import("../core/zig_commands.zig");
const ports = @import("../../ports.zig");
const patch_sessions = @import("patch_sessions.zig");
const path_policy = @import("../../../domain/editing/path_policy.zig");
const session_domain = @import("../../../domain/editing/patch_session.zig");

/// Schema version written into this module's structured payloads.
pub const schema_version = patch_sessions.schema_version;
/// Maximum session file bytes accepted by this workflow module.
pub const max_session_file_bytes = patch_sessions.max_session_file_bytes;
/// Shared replacement result type used by this workflow module.
pub const Replacement = patch_sessions.Replacement;

/// Carries byte range data across use case and port boundaries.
const ByteRange = struct {
    start: usize,
    end: usize,
};

/// Serializes generated file trace fields into an allocator-owned JSON value; allocation failures propagate.
pub fn generatedFileTraceValue(allocator: std.mem.Allocator, context: app_context.EditingContext, path: []const u8) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
    const resolved = try context.workspace_store.resolve(allocator, .{ .path = path, .for_output = true, .provenance = "editing.generated_file_trace" });
    defer resolved.deinit(allocator);
    const rel = try workspaceRelative(allocator, context.workspace.root, resolved.path);
    defer allocator.free(rel);
    const policy = classifyPath(rel);
    var obj = std.json.ObjectMap.empty;
    var obj_owned = true;
    defer if (obj_owned) obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zig_generated_file_trace" });
    try obj.put(allocator, "schema_version", .{ .integer = schema_version });
    try obj.put(allocator, "path", try ownedString(allocator, rel));
    try obj.put(allocator, "policy", try policyValue(allocator, policy));
    try obj.put(allocator, "evidence_source", .{ .string = "workspace_path_heuristics_and_zigars_generated_path_policy" });
    try obj.put(allocator, "confidence", try ownedString(allocator, policy.confidence));
    obj_owned = false;
    return .{ .object = obj };
}

/// Classifies each path against edit policy and reports which are blocked for
/// direct editing, as an allocator-owned JSON value. `allow_direct_edit` is
/// true only when every path is editable; mutating tools still require apply=true.
pub fn editPolicyCheckValue(allocator: std.mem.Allocator, paths: []const []const u8) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
    var checked = std.json.Array.init(allocator);
    var blocked = std.json.Array.init(allocator);
    var allow = true;
    for (paths) |path| {
        const policy = classifyPath(path);
        if (!policy.direct_edit_allowed) {
            allow = false;
            try blocked.append(try ownedString(allocator, path));
        }
        var item = std.json.ObjectMap.empty;
        try item.put(allocator, "path", try ownedString(allocator, path));
        try item.put(allocator, "policy", try policyValue(allocator, policy));
        try checked.append(.{ .object = item });
    }

    var obj = std.json.ObjectMap.empty;
    var obj_owned = true;
    defer if (obj_owned) obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zigars_edit_policy_check" });
    try obj.put(allocator, "schema_version", .{ .integer = schema_version });
    try obj.put(allocator, "allow_direct_edit", .{ .bool = allow });
    try obj.put(allocator, "checked", .{ .array = checked });
    try obj.put(allocator, "blocked_paths", .{ .array = blocked });
    try obj.put(allocator, "write_policy", .{ .string = "Direct source edits must avoid generated, cache, artifact, and vendored paths; mutating tools still require apply=true." });
    obj_owned = false;
    return .{ .object = obj };
}

/// Serializes generated route fields into an allocator-owned JSON value; allocation failures propagate.
pub fn generatedRouteValue(allocator: std.mem.Allocator, context: app_context.EditingContext, path: []const u8, goal: ?[]const u8) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
    const resolved = try context.workspace_store.resolve(allocator, .{ .path = path, .for_output = true, .provenance = "editing.generated_route" });
    defer resolved.deinit(allocator);
    const rel = try workspaceRelative(allocator, context.workspace.root, resolved.path);
    defer allocator.free(rel);
    const policy = classifyPath(rel);
    var obj = std.json.ObjectMap.empty;
    var obj_owned = true;
    defer if (obj_owned) obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zigars_generated_route" });
    try obj.put(allocator, "schema_version", .{ .integer = schema_version });
    try obj.put(allocator, "path", try ownedString(allocator, rel));
    try obj.put(allocator, "goal", if (goal) |text| try ownedString(allocator, text) else .null);
    try obj.put(allocator, "policy", try policyValue(allocator, policy));
    try obj.put(allocator, "route", try ownedString(allocator, policy.route));
    try obj.put(allocator, "source_candidates", try stringArrayValue(allocator, policy.sources));
    try obj.put(allocator, "regeneration_commands", try stringArrayValue(allocator, policy.commands));
    try obj.put(allocator, "stop_condition", .{ .string = "Edit the source or dependency policy, regenerate the derived output, then validate the generated diff before release decisions." });
    obj_owned = false;
    return .{ .object = obj };
}

/// Serializes organize imports fields into an allocator-owned JSON value; allocation failures propagate.
pub fn organizeImportsValue(allocator: std.mem.Allocator, context: app_context.EditingContext, file: []const u8, apply: bool) !std.json.Value {
    const snap = try readSnapshot(allocator, context, file);
    defer snap.deinit(allocator);
    const updated = try organizeImportsText(allocator, snap.bytes);
    defer allocator.free(updated);
    const replacements = [_]Replacement{.{ .file = snap.file, .content = updated }};
    return replacementSessionValue(allocator, context, "zig_organize_imports", &replacements, apply, "organize top-level @import declarations", "Only top-level const/pub const @import lines are sorted and deduplicated; scoped imports are left untouched.");
}

/// Serializes update imports fields into an allocator-owned JSON value; allocation failures propagate.
pub fn updateImportsValue(allocator: std.mem.Allocator, context: app_context.EditingContext, files: []const []const u8, old_import: []const u8, new_import: []const u8, apply: bool) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
    var replacements = std.ArrayList(Replacement).empty;
    defer replacements.deinit(allocator);
    for (files) |file| {
        const snap = try readSnapshot(allocator, context, file);
        defer snap.deinit(allocator);
        try replacements.append(allocator, .{
            .file = try allocator.dupe(u8, snap.file),
            .content = try replaceImportText(allocator, snap.bytes, old_import, new_import),
        });
    }
    return replacementSessionValue(allocator, context, "zig_update_imports", replacements.items, apply, "update @import paths", "Import updates are exact string replacements inside @import(\"...\") calls; semantic module moves still need validation.");
}

/// Serializes move decl fields into an allocator-owned JSON value; allocation failures propagate.
pub fn moveDeclValue(allocator: std.mem.Allocator, context: app_context.EditingContext, source_file: []const u8, target_file: []const u8, name: []const u8, apply: bool) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
    if (std.mem.eql(u8, source_file, target_file)) return error.InvalidArguments;
    const source = try readSnapshot(allocator, context, source_file);
    defer source.deinit(allocator);
    const target = try readSnapshot(allocator, context, target_file);
    defer target.deinit(allocator);
    const range = findDeclarationRange(source.bytes, name) orelse return error.InvalidArguments;
    const decl_text = std.mem.trim(u8, source.bytes[range.start..range.end], "\n");
    const source_updated = try concat3(allocator, source.bytes[0..range.start], "", source.bytes[range.end..]);
    defer allocator.free(source_updated);
    const target_updated = try appendDeclText(allocator, target.bytes, decl_text);
    defer allocator.free(target_updated);
    const replacements = [_]Replacement{
        .{ .file = source.file, .content = source_updated },
        .{ .file = target.file, .content = target_updated },
    };
    return replacementSessionValue(allocator, context, "zig_move_decl", &replacements, apply, "move a top-level declaration between files", "Declaration boundaries are syntax-heuristic; run semantic impact and compiler validation after applying.");
}

/// Serializes extract decl fields into an allocator-owned JSON value; allocation failures propagate.
pub fn extractDeclValue(allocator: std.mem.Allocator, context: app_context.EditingContext, file: []const u8, target_file: []const u8, start_line: usize, end_line: usize, apply: bool) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
    if (std.mem.eql(u8, file, target_file) or start_line == 0 or end_line < start_line) return error.InvalidArguments;
    const source = try readSnapshot(allocator, context, file);
    defer source.deinit(allocator);
    const target = try readSnapshot(allocator, context, target_file);
    defer target.deinit(allocator);
    const range = lineRange(source.bytes, start_line, end_line) orelse return error.InvalidArguments;
    const extracted = std.mem.trim(u8, source.bytes[range.start..range.end], "\n");
    const source_updated = try concat3(allocator, source.bytes[0..range.start], "", source.bytes[range.end..]);
    defer allocator.free(source_updated);
    const target_updated = try appendDeclText(allocator, target.bytes, extracted);
    defer allocator.free(target_updated);
    const replacements = [_]Replacement{
        .{ .file = source.file, .content = source_updated },
        .{ .file = target.file, .content = target_updated },
    };
    return replacementSessionValue(allocator, context, "zig_extract_decl", &replacements, apply, "extract selected lines to a target file", "Extraction is text-range based and does not rewrite call sites or imports automatically.");
}

/// Serializes code action batch unavailable fields into an allocator-owned JSON value; allocation failures propagate.
pub fn codeActionBatchUnavailableValue(allocator: std.mem.Allocator) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
    var obj = std.json.ObjectMap.empty;
    var obj_owned = true;
    defer if (obj_owned) obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zig_code_action_batch" });
    try obj.put(allocator, "schema_version", .{ .integer = schema_version });
    try obj.put(allocator, "ok", .{ .bool = false });
    try obj.put(allocator, "applied", .{ .bool = false });
    try obj.put(allocator, "error_kind", .{ .string = "unsupported_state" });
    try obj.put(allocator, "resolution", .{ .string = "Use zig_code_actions to inspect actions and zig_code_action_apply one action at a time until ZLS exposes transaction-safe batch edits." });
    obj_owned = false;
    return .{ .object = obj };
}

/// Formats `file` (or supplied `content`) and returns the diff as an
/// allocator-owned JSON value. `zig fmt` runs against a throwaway cache copy,
/// never the live file, so formatting has no write side effect on its own; the
/// real source is rewritten only when `apply` is set and edit policy allows it.
pub fn formatValue(allocator: std.mem.Allocator, context: app_context.CoreCommandContext, file: []const u8, content: ?[]const u8, apply: bool, timeout_ms: i64) !std.json.Value {
    const resolved = try context.workspace_store.resolve(allocator, .{ .path = file, .provenance = "editing.format" });
    defer resolved.deinit(allocator);
    const rel = try workspaceRelative(allocator, context.workspace.root, resolved.path);
    defer allocator.free(rel);
    const source = if (content) |bytes|
        ports.WorkspaceReadResult{ .bytes = bytes, .owns_bytes = false }
    else
        try context.workspace_store.read(allocator, .{
            .path = rel,
            .max_bytes = max_session_file_bytes,
            .provenance = "editing.format.read_source",
        });
    defer source.deinit(allocator);

    // Format an isolated copy under the cache rather than the live file: zig fmt
    // rewrites in place, and the source path is content-hashed so concurrent
    // format previews never share a preview file. The copy is deleted on return.
    const preview_name = try std.fmt.allocPrint(allocator, "{x:0>16}.zig", .{std.hash.Wyhash.hash(std.hash.Wyhash.hash(0, rel), source.bytes)});
    defer allocator.free(preview_name);
    const preview_path = try std.fs.path.join(allocator, &.{ ".zigars-cache", "format-preview", preview_name });
    defer allocator.free(preview_path);
    _ = try context.workspace_store.write(.{
        .path = preview_path,
        .bytes = source.bytes,
        .provenance = "editing.format.preview.write_preview",
    });
    defer _ = context.workspace_store.delete(.{ .path = preview_path, .missing_ok = true, .provenance = "editing.format.preview.cleanup" }) catch {};
    const preview_abs = try context.workspace_store.resolve(allocator, .{ .path = preview_path, .for_output = true, .provenance = "editing.format.preview.resolve_preview" });
    defer preview_abs.deinit(allocator);
    const argv = [_][]const u8{ context.tool_paths.zig, "fmt", preview_abs.path };
    var fmt = try context.command_runner.run(allocator, .{
        .argv = &argv,
        .cwd = context.workspace.root,
        .timeout_ms = @intCast(@max(1, timeout_ms)),
        .max_stdout_bytes = core_commands.command_output_limit,
        .max_stderr_bytes = core_commands.command_output_limit,
        .provenance = "editing.format.preview.run",
    });
    defer fmt.deinit(allocator);
    if (fmt.effectiveTerm().failed() or fmt.timed_out) return commandResultValue(allocator, "zig fmt preview", &argv, context.workspace.root, timeout_ms, fmt);
    const formatted = try context.workspace_store.read(allocator, .{
        .path = preview_path,
        .max_bytes = max_session_file_bytes,
        .for_output = true,
        .provenance = "editing.format.preview.read_formatted",
    });
    defer formatted.deinit(allocator);
    const diff = try session_domain.unifiedDiff(allocator, rel, source.bytes, formatted.bytes);
    const policy = classifyPath(rel);
    // Apply gate: write the formatted bytes back only when the caller asked to
    // apply AND policy permits direct edits to this path (e.g. not vendored or
    // generated). Either condition false leaves the live file untouched.
    const applied = apply and policy.direct_edit_allowed;
    if (applied) _ = try context.workspace_store.write(.{
        .path = rel,
        .bytes = formatted.bytes,
        .provenance = "editing.format.apply.write_source",
    });

    var obj = std.json.ObjectMap.empty;
    var obj_owned = true;
    defer if (obj_owned) obj.deinit(allocator);
    try obj.put(allocator, "ok", .{ .bool = true });
    try obj.put(allocator, "applied", .{ .bool = applied });
    try obj.put(allocator, "safe_to_apply", .{ .bool = policy.direct_edit_allowed });
    try obj.put(allocator, "file", try ownedString(allocator, rel));
    try obj.put(allocator, "policy", try policyValue(allocator, policy));
    try obj.put(allocator, "input_source", .{ .string = if (content == null) "workspace_file" else "content" });
    try obj.put(allocator, "source_hash", try hashHexValue(allocator, source.bytes));
    try obj.put(allocator, "updated_hash", try hashHexValue(allocator, formatted.bytes));
    try obj.put(allocator, "changed", .{ .bool = !std.mem.eql(u8, source.bytes, formatted.bytes) });
    try obj.put(allocator, "would_write", .{ .bool = !applied and !std.mem.eql(u8, source.bytes, formatted.bytes) });
    try obj.put(allocator, "diff", .{ .string = diff });
    try obj.put(allocator, "formatted", try ownedString(allocator, formatted.bytes));
    try obj.put(allocator, "preview_retained", .{ .bool = false });
    obj_owned = false;
    return .{ .object = obj };
}

/// Serializes format check fields into an allocator-owned JSON value; allocation failures propagate.
pub fn formatCheckValue(allocator: std.mem.Allocator, context: app_context.CoreCommandContext, path: []const u8, timeout_ms: i64) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
    const resolved = try context.workspace_store.resolve(allocator, .{ .path = path, .provenance = "editing.format_check" });
    defer resolved.deinit(allocator);
    const argv = [_][]const u8{ context.tool_paths.zig, "fmt", "--check", resolved.path };
    const result = try context.command_runner.run(allocator, .{
        .argv = &argv,
        .cwd = context.workspace.root,
        .timeout_ms = @intCast(@max(1, timeout_ms)),
        .max_stdout_bytes = core_commands.command_output_limit,
        .max_stderr_bytes = core_commands.command_output_limit,
        .provenance = "editing.format_check",
    });
    defer result.deinit(allocator);
    return commandResultValue(allocator, "zig fmt --check", &argv, context.workspace.root, timeout_ms, result);
}

/// Diffs `content` against the resolved source file and returns the preview as
/// an allocator-owned JSON value. Replaces the whole file with `content` only
/// when `apply` is set and edit policy allows the path; otherwise it is
/// preview-only and the source is left untouched.
pub fn patchPreviewValue(allocator: std.mem.Allocator, context: app_context.CoreCommandContext, file: []const u8, content: []const u8, apply: bool) !std.json.Value {
    const resolved = try context.workspace_store.resolve(allocator, .{ .path = file, .provenance = "editing.patch_preview.resolve" });
    defer resolved.deinit(allocator);
    const rel = try workspaceRelative(allocator, context.workspace.root, resolved.path);
    defer allocator.free(rel);
    const source = try context.workspace_store.read(allocator, .{
        .path = rel,
        .max_bytes = max_session_file_bytes,
        .provenance = "editing.patch_preview.read_source",
    });
    defer source.deinit(allocator);
    const diff = try session_domain.unifiedDiff(allocator, rel, source.bytes, content);
    const policy = classifyPath(rel);
    // Apply gate: both the caller's apply flag and edit policy must agree before
    // the live file is overwritten with arbitrary caller content.
    const applied = apply and policy.direct_edit_allowed;
    if (applied) _ = try context.workspace_store.write(.{
        .path = rel,
        .bytes = content,
        .provenance = "editing.patch_preview.write",
    });

    var obj = std.json.ObjectMap.empty;
    var obj_owned = true;
    defer if (obj_owned) obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zig_patch_preview" });
    try obj.put(allocator, "applied", .{ .bool = applied });
    try obj.put(allocator, "safe_to_apply", .{ .bool = policy.direct_edit_allowed });
    try obj.put(allocator, "preview_only", .{ .bool = !applied });
    try obj.put(allocator, "requires_apply", .{ .bool = !apply });
    try obj.put(allocator, "file", try ownedString(allocator, rel));
    try obj.put(allocator, "policy", try policyValue(allocator, policy));
    try obj.put(allocator, "source_hash", try hashHexValue(allocator, source.bytes));
    try obj.put(allocator, "updated_hash", try hashHexValue(allocator, content));
    try obj.put(allocator, "changed", .{ .bool = !std.mem.eql(u8, source.bytes, content) });
    try obj.put(allocator, "would_write", .{ .bool = !applied and !std.mem.eql(u8, source.bytes, content) });
    try obj.put(allocator, "diff", .{ .string = diff });
    obj_owned = false;
    return .{ .object = obj };
}

/// Builds the preview/apply result for a multi-file text replacement as an
/// allocator-owned JSON value. Each file is classified; writes happen only when
/// `apply` is set and every file is policy-safe (`apply and safe`), so one
/// blocked path suppresses the whole apply.
fn replacementSessionValue(allocator: std.mem.Allocator, context: app_context.EditingContext, tool_name: []const u8, replacements: []const Replacement, apply: bool, goal: []const u8, limitation: []const u8) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
    var files = std.json.Array.init(allocator);
    var safe = true;
    for (replacements) |replacement| {
        const snap = try readSnapshot(allocator, context, replacement.file);
        defer snap.deinit(allocator);
        const policy = classifyPath(snap.file);
        if (!policy.direct_edit_allowed) safe = false;
        const diff = try session_domain.unifiedDiff(allocator, snap.file, snap.bytes, replacement.content);
        var item = std.json.ObjectMap.empty;
        try item.put(allocator, "file", try ownedString(allocator, snap.file));
        try item.put(allocator, "changed", .{ .bool = !snap.exists or !std.mem.eql(u8, snap.bytes, replacement.content) });
        try item.put(allocator, "preimage_identity", try identityValue(allocator, snap.exists, snap.bytes));
        try item.put(allocator, "updated_identity", try identityValue(allocator, true, replacement.content));
        try item.put(allocator, "policy", try policyValue(allocator, policy));
        try item.put(allocator, "diff", .{ .string = diff });
        try files.append(.{ .object = item });
    }
    if (apply and safe) {
        for (replacements) |replacement| {
            const snap = try readSnapshot(allocator, context, replacement.file);
            defer snap.deinit(allocator);
            if (!snap.exists or !std.mem.eql(u8, snap.bytes, replacement.content)) {
                _ = try context.workspace_store.write(.{ .path = snap.file, .bytes = replacement.content, .provenance = tool_name });
            }
        }
    }
    var obj = std.json.ObjectMap.empty;
    var obj_owned = true;
    defer if (obj_owned) obj.deinit(allocator);
    try obj.put(allocator, "kind", try ownedString(allocator, tool_name));
    try obj.put(allocator, "schema_version", .{ .integer = schema_version });
    try obj.put(allocator, "applied", .{ .bool = apply and safe });
    try obj.put(allocator, "requires_apply", .{ .bool = !apply });
    try obj.put(allocator, "safe_to_apply", .{ .bool = safe });
    try obj.put(allocator, "goal", try ownedString(allocator, goal));
    try obj.put(allocator, "files", .{ .array = files });
    try obj.put(allocator, "limitations", try ownedString(allocator, limitation));
    try obj.put(allocator, "next_action", try nextToolValue(allocator, "zigars_patch_session_validate", "validate the refactor before treating it as complete"));
    obj_owned = false;
    return .{ .object = obj };
}

/// Carries file snapshot data across use case and port boundaries.
const FileSnapshot = struct {
    file: []const u8,
    bytes: []const u8,
    exists: bool,
    read_result: ?@import("../../ports.zig").WorkspaceReadResult = null,

    /// Releases allocations owned by this value; callers must not use owned slices after this returns.
    fn deinit(self: FileSnapshot, allocator: std.mem.Allocator) void {
        if (self.read_result) |result| result.deinit(allocator);
    }
};

/// Reads snapshot data from the provided context without taking ownership of inputs.
fn readSnapshot(allocator: std.mem.Allocator, context: app_context.EditingContext, path: []const u8) !FileSnapshot {
    // Keep this logic centralized so callers observe one consistent behavior path.
    const result = context.workspace_store.read(allocator, .{
        .path = path,
        .max_bytes = max_session_file_bytes,
        .provenance = "editing_workflow_snapshot",
    }) catch |err| switch (err) {
        error.FileNotFound, error.NotFound => return .{ .file = path, .bytes = "", .exists = false },
        else => return err,
    };
    return .{ .file = path, .bytes = result.bytes, .exists = true, .read_result = result };
}

/// Thin wrapper that keeps callers from importing path_policy directly.
fn classifyPath(path: []const u8) path_policy.PathPolicy {
    return path_policy.classify(path);
}

/// Serializes policy fields into an allocator-owned JSON value; allocation failures propagate.
fn policyValue(allocator: std.mem.Allocator, policy: path_policy.PathPolicy) !std.json.Value {
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

/// Serializes identity fields into an allocator-owned JSON value; allocation failures propagate.
fn identityValue(allocator: std.mem.Allocator, exists: bool, bytes: []const u8) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
    var identity = try session_domain.identityFromBytes(allocator, exists, bytes);
    defer identity.deinit(allocator);
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "exists", .{ .bool = identity.exists });
    try obj.put(allocator, "bytes", .{ .integer = @intCast(identity.bytes) });
    try obj.put(allocator, "sha256", if (identity.sha256) |hash| try ownedString(allocator, hash) else .null);
    return .{ .object = obj };
}

/// Implements organize imports text workflow logic using caller-owned inputs.
fn organizeImportsText(allocator: std.mem.Allocator, source: []const u8) ![]const u8 {
    // Keep this logic centralized so callers observe one consistent behavior path.
    var imports = std.ArrayList([]const u8).empty;
    defer imports.deinit(allocator);
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

/// Returns true only for non-indented lines that bind a name to an @import
/// literal. Indented (scoped) imports and non-import declarations return false.
fn isTopLevelImportLine(line: []const u8) bool {
    if (line.len == 0 or line[0] == ' ' or line[0] == '\t') return false;
    return (std.mem.startsWith(u8, line, "const ") or std.mem.startsWith(u8, line, "pub const ")) and std.mem.indexOf(u8, line, "@import(\"") != null;
}

/// Rewrites every `@import("old_import")` occurrence to `@import("new_import")`
/// without touching import names that merely contain the needle as a substring.
fn replaceImportText(allocator: std.mem.Allocator, source: []const u8, old_import: []const u8, new_import: []const u8) ![]const u8 {
    const needle = try std.fmt.allocPrint(allocator, "@import(\"{s}\")", .{old_import});
    defer allocator.free(needle);
    const replacement = try std.fmt.allocPrint(allocator, "@import(\"{s}\")", .{new_import});
    defer allocator.free(replacement);
    return replaceAll(allocator, source, needle, replacement);
}

/// Returns an allocator-owned copy of `source` with every non-overlapping
/// occurrence of `needle` replaced by `replacement`.
fn replaceAll(allocator: std.mem.Allocator, source: []const u8, needle: []const u8, replacement: []const u8) ![]const u8 {
    // Keep this logic centralized so callers observe one consistent behavior path.
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

/// Scans `source` line-by-line for a top-level declaration named `name` (const,
/// var, or fn). Returns the byte range [start, end) covering the declaration
/// through the line before the next top-level declaration, or null when absent.
fn findDeclarationRange(source: []const u8, name: []const u8) ?ByteRange {
    // Keep this logic centralized so callers observe one consistent behavior path.
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

/// Returns true if `line` starts a top-level declaration whose identifier is
/// exactly `name` (not merely a prefix of a longer name).
fn isNamedDeclLine(line: []const u8, name: []const u8) bool {
    if (!isTopLevelDeclLine(line)) return false;
    inline for (.{ "const ", "var ", "fn " }) |needle| {
        if (declLineContainsName(line, needle, name)) return true;
    }
    return false;
}

/// Returns true if `line` contains `marker` immediately followed by `name` as a
/// complete identifier (not a prefix of something longer).
fn declLineContainsName(line: []const u8, marker: []const u8, name: []const u8) bool {
    const index = std.mem.indexOf(u8, line, marker) orelse return false;
    const rest = line[index + marker.len ..];
    return std.mem.startsWith(u8, rest, name) and (rest.len == name.len or !isIdentChar(rest[name.len]));
}

/// Returns true for non-indented lines that begin a recognized Zig top-level
/// declaration keyword (pub/private const, var, fn, export fn, extern fn).
fn isTopLevelDeclLine(line: []const u8) bool {
    if (line.len == 0 or line[0] == ' ' or line[0] == '\t') return false;
    return std.mem.startsWith(u8, line, "pub const ") or std.mem.startsWith(u8, line, "const ") or
        std.mem.startsWith(u8, line, "pub var ") or std.mem.startsWith(u8, line, "var ") or
        std.mem.startsWith(u8, line, "pub fn ") or std.mem.startsWith(u8, line, "fn ") or
        std.mem.startsWith(u8, line, "export fn ") or std.mem.startsWith(u8, line, "extern fn ");
}

/// Returns true if `ch` can appear inside a Zig identifier (alphanumeric or underscore).
fn isIdentChar(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_';
}

/// Returns the byte range covering lines `start_line` through `end_line`
/// (1-based, inclusive). Returns null if either line number is out of range.
fn lineRange(source: []const u8, start_line: usize, end_line: usize) ?ByteRange {
    // Keep this logic centralized so callers observe one consistent behavior path.
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

/// Returns a new allocator-owned string that is `target` with `decl_text`
/// appended after a blank-line separator. Ensures the result ends with a newline.
fn appendDeclText(allocator: std.mem.Allocator, target: []const u8, decl_text: []const u8) ![]const u8 {
    // Append in deterministic order so completion and snapshot output remain stable.
    var out = std.ArrayList(u8).empty;
    try out.appendSlice(allocator, target);
    if (out.items.len > 0 and out.items[out.items.len - 1] != '\n') try out.append(allocator, '\n');
    if (out.items.len > 0) try out.append(allocator, '\n');
    try out.appendSlice(allocator, decl_text);
    try out.append(allocator, '\n');
    return out.toOwnedSlice(allocator);
}

/// Returns an allocator-owned concatenation of `a`, `b`, and `c`.
/// Used to splice a declaration out of a source file by joining the prefix,
/// an empty middle gap, and the suffix in one allocation.
fn concat3(allocator: std.mem.Allocator, a: []const u8, b: []const u8, c: []const u8) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    try out.appendSlice(allocator, a);
    try out.appendSlice(allocator, b);
    try out.appendSlice(allocator, c);
    return out.toOwnedSlice(allocator);
}

/// Returns true if `values` contains a string equal to `needle`.
fn stringListContains(values: []const []const u8, needle: []const u8) bool {
    for (values) |value| if (std.mem.eql(u8, value, needle)) return true;
    return false;
}

/// Comparator for std.mem.sort: lexicographic order over import line strings.
fn stringLessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// Serializes string array fields into an allocator-owned JSON value; allocation failures propagate.
fn stringArrayValue(allocator: std.mem.Allocator, values: []const []const u8) !std.json.Value {
    var array = std.json.Array.init(allocator);
    for (values) |value| try array.append(try ownedString(allocator, value));
    return .{ .array = array };
}

/// Builds a `{tool, reason}` guidance object telling callers which tool to
/// invoke next after a refactor step completes.
fn nextToolValue(allocator: std.mem.Allocator, tool: []const u8, reason: []const u8) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "tool", try ownedString(allocator, tool));
    try obj.put(allocator, "reason", try ownedString(allocator, reason));
    return .{ .object = obj };
}

/// Serializes command result fields into an allocator-owned JSON value; allocation failures propagate.
fn commandResultValue(allocator: std.mem.Allocator, title: []const u8, argv: []const []const u8, cwd: []const u8, timeout_ms: i64, result: ports.CommandResult) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
    var obj = std.json.ObjectMap.empty;
    var obj_owned = true;
    defer if (obj_owned) obj.deinit(allocator);
    const term = result.effectiveTerm();
    try obj.put(allocator, "kind", .{ .string = "command" });
    try obj.put(allocator, "title", try ownedString(allocator, title));
    try obj.put(allocator, "ok", .{ .bool = !term.failed() and !result.timed_out });
    try obj.put(allocator, "cwd", try ownedString(allocator, cwd));
    try obj.put(allocator, "argv", try stringArrayValue(allocator, argv));
    try obj.put(allocator, "timeout_ms", .{ .integer = timeout_ms });
    try obj.put(allocator, "duration_ms", .{ .integer = @intCast(result.duration_ms) });
    try obj.put(allocator, "exit_code", .{ .integer = result.exit_code });
    try obj.put(allocator, "stdout", try ownedString(allocator, result.stdout));
    try obj.put(allocator, "stderr", try ownedString(allocator, result.stderr));
    try obj.put(allocator, "stdout_truncated", .{ .bool = result.stdout_truncated });
    try obj.put(allocator, "stderr_truncated", .{ .bool = result.stderr_truncated });
    try obj.put(allocator, "output_limit_mode", .{ .string = core_commands.command_output_limit_mode });
    try obj.put(allocator, "output_limit_exceeded", .{ .bool = result.stdout_truncated or result.stderr_truncated });
    obj_owned = false;
    return .{ .object = obj };
}

/// Returns a 16-hex-char Wyhash digest of `bytes` as a JSON string value.
/// Used for change-detection identity in format/patch results; not cryptographic.
fn hashHexValue(allocator: std.mem.Allocator, bytes: []const u8) !std.json.Value {
    return .{ .string = try std.fmt.allocPrint(allocator, "{x:0>16}", .{std.hash.Wyhash.hash(0, bytes)}) };
}

/// Dupes `text` into the allocator and wraps it as a JSON string value.
/// The JSON object that holds this value takes ownership of the allocation.
fn ownedString(allocator: std.mem.Allocator, text: []const u8) !std.json.Value {
    return .{ .string = try allocator.dupe(u8, text) };
}

/// Strips the workspace root prefix from an already-resolved absolute path so
/// results and policy classification use a stable workspace-relative form.
/// Returns `path` unchanged if it is not under `root` (kept for display only;
/// the workspace store, not this helper, enforces the sandbox boundary).
/// Returns the workspace-relative form of `path` as an allocator-owned,
/// `/`-separated logical path. Windows resolved paths carry `\`, which would
/// miss the `/`-keyed generated-path policy table and leak platform
/// separators into the public result contract.
fn workspaceRelative(allocator: std.mem.Allocator, root: []const u8, path: []const u8) ![]u8 {
    var rel: []const u8 = path;
    if (std.mem.startsWith(u8, path, root)) {
        rel = path[root.len..];
        while (rel.len > 0 and (rel[0] == '/' or rel[0] == '\\')) rel = rel[1..];
    }
    const owned = try allocator.dupe(u8, rel);
    std.mem.replaceScalar(u8, owned, '\\', '/');
    return owned;
}

const fakes = @import("../../../testing/fakes/root.zig");

test "replacement sessions apply safe changed files through workspace store" {
    var workspace = fakes.FakeWorkspaceStore.init(std.testing.allocator);
    defer workspace.deinit();
    var clock = fakes.FakeClockAndIds.init(std.testing.allocator);
    defer clock.deinit();
    const context = app_context.EditingContext{
        .workspace = .{ .root = "/workspace", .cache_root = "/workspace/.zigars-cache" },
        .workspace_store = workspace.port(),
        .clock_and_ids = clock.port(),
    };

    try workspace.expectRead(.{ .path = "src/main.zig", .max_bytes = max_session_file_bytes, .provenance = "editing_workflow_snapshot" }, "const old = true;\n");
    try workspace.expectRead(.{ .path = "src/main.zig", .max_bytes = max_session_file_bytes, .provenance = "editing_workflow_snapshot" }, "const old = true;\n");
    try workspace.expectWrite(.{ .path = "src/main.zig", .bytes = "const new = true;\n", .provenance = "zig_test_edit" }, .{ .bytes_written = "const new = true;\n".len });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const replacements = [_]Replacement{.{ .file = "src/main.zig", .content = "const new = true;\n" }};
    const value = try replacementSessionValue(arena.allocator(), context, "zig_test_edit", &replacements, true, "replace fixture", "unit test limitation");
    try std.testing.expect(value.object.get("applied").?.bool);
    try std.testing.expect(value.object.get("safe_to_apply").?.bool);
    try workspace.verify();
    try clock.verify();
}

test "formatValue formats supplied content without reading source on preview" {
    var workspace = fakes.FakeWorkspaceStore.init(std.testing.allocator);
    defer workspace.deinit();
    var runner = fakes.FakeCommandRunner.init(std.testing.allocator);
    defer runner.deinit();
    const context = app_context.CoreCommandContext{
        .workspace = .{ .root = "/workspace", .cache_root = "/workspace/.zigars-cache" },
        .tool_paths = .{ .zig = "zig" },
        .timeouts = .{ .command_ms = 1000 },
        .zls_state = .{},
        .command_runner = runner.port(),
        .workspace_store = workspace.port(),
    };

    const rel = "src/main.zig";
    const input = "const x=1;\n";
    const formatted_text = "const x = 1;\n";
    const preview_name = try std.fmt.allocPrint(std.testing.allocator, "{x:0>16}.zig", .{std.hash.Wyhash.hash(std.hash.Wyhash.hash(0, rel), input)});
    defer std.testing.allocator.free(preview_name);
    const preview_path = try std.fs.path.join(std.testing.allocator, &.{ ".zigars-cache", "format-preview", preview_name });
    defer std.testing.allocator.free(preview_path);
    const preview_abs = try std.fs.path.join(std.testing.allocator, &.{ "/workspace", preview_path });
    defer std.testing.allocator.free(preview_abs);

    try workspace.expectResolve(.{ .path = rel, .provenance = "editing.format" }, "/workspace/src/main.zig");
    try workspace.expectWrite(.{ .path = preview_path, .bytes = input, .provenance = "editing.format.preview.write_preview" }, .{ .bytes_written = input.len });
    try workspace.expectResolve(.{ .path = preview_path, .for_output = true, .provenance = "editing.format.preview.resolve_preview" }, preview_abs);
    try runner.expectRun(.{
        .argv = &.{ "zig", "fmt", preview_abs },
        .cwd = "/workspace",
        .timeout_ms = 1000,
        .max_stdout_bytes = core_commands.command_output_limit,
        .max_stderr_bytes = core_commands.command_output_limit,
        .provenance = "editing.format.preview.run",
    }, .{ .exit_code = 0 });
    try workspace.expectRead(.{ .path = preview_path, .max_bytes = max_session_file_bytes, .for_output = true, .provenance = "editing.format.preview.read_formatted" }, formatted_text);
    try workspace.expectDelete(.{ .path = preview_path, .missing_ok = true, .provenance = "editing.format.preview.cleanup" }, .{ .deleted = true });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const value = try formatValue(arena.allocator(), context, rel, input, false, 1000);
    try std.testing.expect(value.object.get("ok").?.bool);
    try std.testing.expect(!value.object.get("applied").?.bool);
    try std.testing.expectEqualStrings("content", value.object.get("input_source").?.string);
    try std.testing.expect(value.object.get("changed").?.bool);
    try std.testing.expectEqualStrings(formatted_text, value.object.get("formatted").?.string);
    try std.testing.expectEqual(@as(usize, 1), workspace.readCalls().len);
    try std.testing.expectEqualStrings(preview_path, workspace.readCalls()[0].path);
    try std.testing.expectEqual(@as(usize, 1), workspace.writeCalls().len);
    try workspace.verify();
    try runner.verify();
}

test "readSnapshot treats missing files as empty absent snapshots" {
    var workspace = fakes.FakeWorkspaceStore.init(std.testing.allocator);
    defer workspace.deinit();
    var clock = fakes.FakeClockAndIds.init(std.testing.allocator);
    defer clock.deinit();
    const context = app_context.EditingContext{
        .workspace = .{ .root = "/workspace", .cache_root = "/workspace/.zigars-cache" },
        .workspace_store = workspace.port(),
        .clock_and_ids = clock.port(),
    };

    try workspace.expectReadError(.{ .path = "missing.zig", .max_bytes = max_session_file_bytes, .provenance = "editing_workflow_snapshot" }, error.FileNotFound);
    const snapshot = try readSnapshot(std.testing.allocator, context, "missing.zig");
    defer snapshot.deinit(std.testing.allocator);
    try std.testing.expect(!snapshot.exists);
    try std.testing.expectEqualStrings("missing.zig", snapshot.file);
    try std.testing.expectEqualStrings("", snapshot.bytes);
    try workspace.verify();
    try clock.verify();
}

test "editing range helpers return null for absent declarations and out of range lines" {
    try std.testing.expect(findDeclarationRange("const present = 1;\n", "missing") == null);
    try std.testing.expect(lineRange("one\n", 3, 4) == null);
}

test "moveDeclValue rejects identical source and target file before touching the workspace" {
    var workspace = fakes.FakeWorkspaceStore.init(std.testing.allocator);
    defer workspace.deinit();
    var clock = fakes.FakeClockAndIds.init(std.testing.allocator);
    defer clock.deinit();
    const context = app_context.EditingContext{
        .workspace = .{ .root = "/workspace", .cache_root = "/workspace/.zigars-cache" },
        .workspace_store = workspace.port(),
        .clock_and_ids = clock.port(),
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // A same-file move would otherwise duplicate the decl and drop its removal; reject up front.
    try std.testing.expectError(error.InvalidArguments, moveDeclValue(arena.allocator(), context, "src/main.zig", "src/main.zig", "value", true));
    // No snapshot read or source write should have happened.
    try std.testing.expectEqual(@as(usize, 0), workspace.readCalls().len);
    try std.testing.expectEqual(@as(usize, 0), workspace.writeCalls().len);
    try workspace.verify();
    try clock.verify();
}

test "formatValue refuses to apply onto a vendored path and flags safe_to_apply false" {
    var workspace = fakes.FakeWorkspaceStore.init(std.testing.allocator);
    defer workspace.deinit();
    var runner = fakes.FakeCommandRunner.init(std.testing.allocator);
    defer runner.deinit();
    const context = app_context.CoreCommandContext{
        .workspace = .{ .root = "/workspace", .cache_root = "/workspace/.zigars-cache" },
        .tool_paths = .{ .zig = "zig" },
        .timeouts = .{ .command_ms = 1000 },
        .zls_state = .{},
        .command_runner = runner.port(),
        .workspace_store = workspace.port(),
    };

    const rel = "vendor/dep.zig";
    const input = "const x=1;\n";
    const formatted_text = "const x = 1;\n";
    const preview_name = try std.fmt.allocPrint(std.testing.allocator, "{x:0>16}.zig", .{std.hash.Wyhash.hash(std.hash.Wyhash.hash(0, rel), input)});
    defer std.testing.allocator.free(preview_name);
    const preview_path = try std.fs.path.join(std.testing.allocator, &.{ ".zigars-cache", "format-preview", preview_name });
    defer std.testing.allocator.free(preview_path);
    const preview_abs = try std.fs.path.join(std.testing.allocator, &.{ "/workspace", preview_path });
    defer std.testing.allocator.free(preview_abs);

    try workspace.expectResolve(.{ .path = rel, .provenance = "editing.format" }, "/workspace/vendor/dep.zig");
    try workspace.expectWrite(.{ .path = preview_path, .bytes = input, .provenance = "editing.format.preview.write_preview" }, .{ .bytes_written = input.len });
    try workspace.expectResolve(.{ .path = preview_path, .for_output = true, .provenance = "editing.format.preview.resolve_preview" }, preview_abs);
    try runner.expectRun(.{
        .argv = &.{ "zig", "fmt", preview_abs },
        .cwd = "/workspace",
        .timeout_ms = 1000,
        .max_stdout_bytes = core_commands.command_output_limit,
        .max_stderr_bytes = core_commands.command_output_limit,
        .provenance = "editing.format.preview.run",
    }, .{ .exit_code = 0 });
    try workspace.expectRead(.{ .path = preview_path, .max_bytes = max_session_file_bytes, .for_output = true, .provenance = "editing.format.preview.read_formatted" }, formatted_text);
    try workspace.expectDelete(.{ .path = preview_path, .missing_ok = true, .provenance = "editing.format.preview.cleanup" }, .{ .deleted = true });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const value = try formatValue(arena.allocator(), context, rel, input, true, 1000);
    try std.testing.expect(value.object.get("ok").?.bool);
    // apply=true must NOT land on a vendored path; only the preview write is expected.
    try std.testing.expect(!value.object.get("applied").?.bool);
    try std.testing.expect(!value.object.get("safe_to_apply").?.bool);
    try std.testing.expectEqualStrings("vendor", value.object.get("policy").?.object.get("classification").?.string);
    try std.testing.expectEqual(@as(usize, 1), workspace.writeCalls().len);
    try std.testing.expectEqualStrings(preview_path, workspace.writeCalls()[0].path);
    try workspace.verify();
    try runner.verify();
}

test "patchPreviewValue refuses to apply onto a vendored path and flags safe_to_apply false" {
    var workspace = fakes.FakeWorkspaceStore.init(std.testing.allocator);
    defer workspace.deinit();
    var runner = fakes.FakeCommandRunner.init(std.testing.allocator);
    defer runner.deinit();
    const context = app_context.CoreCommandContext{
        .workspace = .{ .root = "/workspace", .cache_root = "/workspace/.zigars-cache" },
        .tool_paths = .{ .zig = "zig" },
        .timeouts = .{ .command_ms = 1000 },
        .zls_state = .{},
        .command_runner = runner.port(),
        .workspace_store = workspace.port(),
    };

    const rel = "vendor/dep.zig";
    try workspace.expectResolve(.{ .path = rel, .provenance = "editing.patch_preview.resolve" }, "/workspace/vendor/dep.zig");
    try workspace.expectRead(.{ .path = rel, .max_bytes = max_session_file_bytes, .provenance = "editing.patch_preview.read_source" }, "const old = 1;\n");

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const value = try patchPreviewValue(arena.allocator(), context, rel, "const new = 2;\n", true);
    // apply=true must NOT land arbitrary content on a vendored path.
    try std.testing.expect(!value.object.get("applied").?.bool);
    try std.testing.expect(!value.object.get("safe_to_apply").?.bool);
    try std.testing.expect(value.object.get("preview_only").?.bool);
    try std.testing.expectEqualStrings("vendor", value.object.get("policy").?.object.get("classification").?.string);
    try std.testing.expectEqual(@as(usize, 0), workspace.writeCalls().len);
    try workspace.verify();
    try runner.verify();
}
