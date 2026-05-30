//! Stdio smoke fixtures for transactional editing and generated-file policy.
//! Covers the full patch-session lifecycle (create, preview, apply, validate,
//! revert), generated-file trace, edit-policy check, generated-route,
//! import organization, import update, declaration move/extract, and ZLS
//! batch code-action tools. Source-mutating calls require apply=true; the
//! fixture verifies on-disk state after each apply.

const std = @import("std");
const cli_io = @import("../../common/cli_io.zig");
const smoke = @import("../smoke_support.zig");

const JsonValue = std.json.Value;

/// Exercises patch-session and generated-file policy tool paths end-to-end.
/// `workspace` is the fixture root used to verify that file content changes
/// after an apply and reverts correctly. The caller owns server lifecycle.
pub fn run(client: anytype, workspace: []const u8) !void {
    const create = try client.callTool("zigars_patch_session_create", "{\"goal\":\"fixture edit\",\"files\":\"src/main.zig zig-out/generated.zig\"}");
    defer client.allocator.free(create);
    try client.expectPathString(create, "kind", "zigars_patch_session_create");
    try client.expectPathJson(create, "safe_to_edit", .{ .bool = false });
    try client.expectPathString(create, "files.1.policy.classification", "cache");

    const edits =
        \\[{"file":"src/main.zig","content":"pub fn main() void {\n    const x = 3;\n    _ = x;\n}\n"}]
    ;
    const preview_args = try argsWithEdits(client.allocator, edits);
    defer client.allocator.free(preview_args);
    const preview = try client.callTool("zigars_patch_session_preview", preview_args);
    defer client.allocator.free(preview);
    try client.expectPathString(preview, "kind", "zigars_patch_session_preview");
    try client.expectPathJson(preview, "requires_apply", .{ .bool = true });

    const parsed_preview = try std.json.parseFromSlice(JsonValue, client.allocator, preview, .{});
    defer parsed_preview.deinit();
    const session_id = smoke.valueAt(parsed_preview.value, "session_id").?.string;
    const expected = try cli_io.jsonStringifyAlloc(client.allocator, smoke.valueAt(parsed_preview.value, "expected_preimages").?, .{ .whitespace = .minified });
    defer client.allocator.free(expected);

    const apply_args = try patchApplyArgs(client.allocator, session_id, edits, expected, true);
    defer client.allocator.free(apply_args);
    const applied = try client.callTool("zigars_patch_session_apply", apply_args);
    defer client.allocator.free(applied);
    try client.expectPathString(applied, "kind", "zigars_patch_session_apply");
    try client.expectPathJson(applied, "applied", .{ .bool = true });
    try expectFileContains(client, workspace, "src/main.zig", "const x = 3;");

    const validate = try client.callTool("zigars_patch_session_validate", "{\"session_id\":\"fixture\",\"changed_files\":\"notes.txt\",\"mode\":\"quick\",\"apply\":false}");
    defer client.allocator.free(validate);
    try client.expectPathString(validate, "kind", "zigars_patch_session_validate");
    try client.expectPathString(validate, "validation.kind", "zigars_validation_run");

    const revert_args = try std.fmt.allocPrint(client.allocator, "{{\"session_id\":\"{s}\",\"apply\":true}}", .{session_id});
    defer client.allocator.free(revert_args);
    const reverted = try client.callTool("zigars_patch_session_revert", revert_args);
    defer client.allocator.free(reverted);
    try client.expectPathString(reverted, "kind", "zigars_patch_session_revert");
    try client.expectPathJson(reverted, "applied", .{ .bool = true });
    try expectFileContains(client, workspace, "src/main.zig", "const x = 1;");

    const trace = try client.callTool("zig_generated_file_trace", "{\"path\":\"docs/tool-index.generated.md\"}");
    defer client.allocator.free(trace);
    try client.expectPathString(trace, "kind", "zig_generated_file_trace");
    try client.expectPathString(trace, "policy.classification", "generated");

    const policy = try client.callTool("zigars_edit_policy_check", "{\"files\":\"src/main.zig zig-out/generated.zig\"}");
    defer client.allocator.free(policy);
    try client.expectPathString(policy, "kind", "zigars_edit_policy_check");
    try client.expectPathJson(policy, "allow_direct_edit", .{ .bool = false });

    const route = try client.callTool("zigars_generated_route", "{\"path\":\"docs/tool-index.generated.md\",\"goal\":\"update tool docs\"}");
    defer client.allocator.free(route);
    try client.expectPathString(route, "kind", "zigars_generated_route");
    try client.expectPathString(route, "regeneration_commands.0", "zig build tool-index");

    const organized = try client.callTool("zig_organize_imports", "{\"file\":\"src/tests.zig\",\"apply\":false}");
    defer client.allocator.free(organized);
    try client.expectPathString(organized, "kind", "zig_organize_imports");
    try client.expectPathJson(organized, "files.0.changed", .{ .bool = false });

    const updated = try client.callTool("zig_update_imports", "{\"file\":\"src/tests.zig\",\"old_import\":\"std\",\"new_import\":\"builtin\",\"apply\":false}");
    defer client.allocator.free(updated);
    try client.expectPathString(updated, "kind", "zig_update_imports");
    try client.expectPathJson(updated, "files.0.changed", .{ .bool = true });

    const moved = try client.callTool("zig_move_decl", "{\"source_file\":\"src/tests.zig\",\"target_file\":\"src/main.zig\",\"name\":\"Fixture\",\"apply\":false}");
    defer client.allocator.free(moved);
    try client.expectPathString(moved, "kind", "zig_move_decl");
    try client.expectPathJson(moved, "files.0.changed", .{ .bool = true });

    const extracted = try client.callTool("zig_extract_decl", "{\"file\":\"src/tests.zig\",\"target_file\":\"src/main.zig\",\"start_line\":2,\"end_line\":2,\"apply\":false}");
    defer client.allocator.free(extracted);
    try client.expectPathString(extracted, "kind", "zig_extract_decl");
    try client.expectPathJson(extracted, "files.1.changed", .{ .bool = true });

    const batch = try client.callTool("zig_code_action_batch", "{}");
    defer client.allocator.free(batch);
    try client.expectPathString(batch, "kind", "backend_error");
    try client.expectPathString(batch, "error_kind", "unavailable");
}

// Builds the JSON argument object for zigars_patch_session_preview. The edits
// array is embedded as a JSON string field so callers work with a typed slice
// rather than a raw format string.
fn argsWithEdits(allocator: std.mem.Allocator, edits: []const u8) ![]u8 {
    var obj = std.json.ObjectMap.empty;
    defer obj.deinit(allocator);
    try obj.put(allocator, "edits", .{ .string = edits });
    return cli_io.jsonStringifyAlloc(allocator, .{ .object = obj }, .{ .whitespace = .minified });
}

// Builds the JSON argument object for zigars_patch_session_apply. The
// expected_preimages field is captured from the preview result so the apply
// can verify that file content has not changed since the preview was issued.
fn patchApplyArgs(allocator: std.mem.Allocator, session_id: []const u8, edits: []const u8, expected: []const u8, apply: bool) ![]u8 {
    var obj = std.json.ObjectMap.empty;
    defer obj.deinit(allocator);
    try obj.put(allocator, "session_id", .{ .string = session_id });
    try obj.put(allocator, "edits", .{ .string = edits });
    try obj.put(allocator, "expected_preimages", .{ .string = expected });
    try obj.put(allocator, "apply", .{ .bool = apply });
    return cli_io.jsonStringifyAlloc(allocator, .{ .object = obj }, .{ .whitespace = .minified });
}

// Reads a workspace-relative file and asserts it contains `needle`. Used to
// verify on-disk state after apply and revert without loading the full file
// into an assertion message.
fn expectFileContains(client: anytype, workspace: []const u8, rel: []const u8, needle: []const u8) !void {
    const path = try std.fmt.allocPrint(client.allocator, "{s}/{s}", .{ workspace, rel });
    defer client.allocator.free(path);
    const bytes = try cli_io.readFileAlloc(client.allocator, client.io, path, 1024 * 1024);
    defer client.allocator.free(bytes);
    if (std.mem.indexOf(u8, bytes, needle) == null) return error.AssertionFailed;
}

test "stdio transactional editing fixture exposes run entrypoint" {
    try std.testing.expect(@hasDecl(@This(), "run"));
}
