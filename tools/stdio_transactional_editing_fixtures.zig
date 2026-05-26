const std = @import("std");
const cli_io = @import("cli_io.zig");
const smoke = @import("smoke_support.zig");

const JsonValue = std.json.Value;

pub fn run(client: anytype, workspace: []const u8) !void {
    const create = try client.callTool("zigar_patch_session_create", "{\"goal\":\"fixture edit\",\"files\":\"src/main.zig zig-out/generated.zig\"}");
    defer client.allocator.free(create);
    try client.expectPathString(create, "kind", "zigar_patch_session_create");
    try client.expectPathJson(create, "safe_to_edit", .{ .bool = false });
    try client.expectPathString(create, "files.1.policy.classification", "cache");

    const edits =
        \\[{"file":"src/main.zig","content":"pub fn main() void {\n    const x = 3;\n    _ = x;\n}\n"}]
    ;
    const preview_args = try argsWithEdits(client.allocator, edits);
    defer client.allocator.free(preview_args);
    const preview = try client.callTool("zigar_patch_session_preview", preview_args);
    defer client.allocator.free(preview);
    try client.expectPathString(preview, "kind", "zigar_patch_session_preview");
    try client.expectPathJson(preview, "requires_apply", .{ .bool = true });

    const parsed_preview = try std.json.parseFromSlice(JsonValue, client.allocator, preview, .{});
    defer parsed_preview.deinit();
    const session_id = smoke.valueAt(parsed_preview.value, "session_id").?.string;
    const expected = try cli_io.jsonStringifyAlloc(client.allocator, smoke.valueAt(parsed_preview.value, "expected_preimages").?, .{ .whitespace = .minified });
    defer client.allocator.free(expected);

    const apply_args = try patchApplyArgs(client.allocator, session_id, edits, expected, true);
    defer client.allocator.free(apply_args);
    const applied = try client.callTool("zigar_patch_session_apply", apply_args);
    defer client.allocator.free(applied);
    try client.expectPathString(applied, "kind", "zigar_patch_session_apply");
    try client.expectPathJson(applied, "applied", .{ .bool = true });
    try expectFileContains(client, workspace, "src/main.zig", "const x = 3;");

    const validate = try client.callTool("zigar_patch_session_validate", "{\"session_id\":\"fixture\",\"changed_files\":\"notes.txt\",\"mode\":\"quick\",\"apply\":false}");
    defer client.allocator.free(validate);
    try client.expectPathString(validate, "kind", "zigar_patch_session_validate");
    try client.expectPathString(validate, "validation.kind", "zigar_validation_run");

    const revert_args = try std.fmt.allocPrint(client.allocator, "{{\"session_id\":\"{s}\",\"apply\":true}}", .{session_id});
    defer client.allocator.free(revert_args);
    const reverted = try client.callTool("zigar_patch_session_revert", revert_args);
    defer client.allocator.free(reverted);
    try client.expectPathString(reverted, "kind", "zigar_patch_session_revert");
    try client.expectPathJson(reverted, "applied", .{ .bool = true });
    try expectFileContains(client, workspace, "src/main.zig", "const x = 1;");

    const trace = try client.callTool("zig_generated_file_trace", "{\"path\":\"docs/tool-index.generated.md\"}");
    defer client.allocator.free(trace);
    try client.expectPathString(trace, "kind", "zig_generated_file_trace");
    try client.expectPathString(trace, "policy.classification", "generated");

    const policy = try client.callTool("zigar_edit_policy_check", "{\"files\":\"src/main.zig zig-out/generated.zig\"}");
    defer client.allocator.free(policy);
    try client.expectPathString(policy, "kind", "zigar_edit_policy_check");
    try client.expectPathJson(policy, "allow_direct_edit", .{ .bool = false });

    const route = try client.callTool("zigar_generated_route", "{\"path\":\"docs/tool-index.generated.md\",\"goal\":\"update tool docs\"}");
    defer client.allocator.free(route);
    try client.expectPathString(route, "kind", "zigar_generated_route");
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

    const batch = try client.callTool("zig_code_action_batch", "{\"file\":\"src/main.zig\",\"start_line\":1,\"start_char\":1,\"end_line\":1,\"end_char\":1,\"action_indices\":\"0\",\"apply\":false}");
    defer client.allocator.free(batch);
    try client.expectPathString(batch, "kind", "backend_error");
    try client.expectPathString(batch, "error_kind", "unavailable");
}

fn argsWithEdits(allocator: std.mem.Allocator, edits: []const u8) ![]u8 {
    var obj = std.json.ObjectMap.empty;
    defer obj.deinit(allocator);
    try obj.put(allocator, "edits", .{ .string = edits });
    return cli_io.jsonStringifyAlloc(allocator, .{ .object = obj }, .{ .whitespace = .minified });
}

fn patchApplyArgs(allocator: std.mem.Allocator, session_id: []const u8, edits: []const u8, expected: []const u8, apply: bool) ![]u8 {
    var obj = std.json.ObjectMap.empty;
    defer obj.deinit(allocator);
    try obj.put(allocator, "session_id", .{ .string = session_id });
    try obj.put(allocator, "edits", .{ .string = edits });
    try obj.put(allocator, "expected_preimages", .{ .string = expected });
    try obj.put(allocator, "apply", .{ .bool = apply });
    return cli_io.jsonStringifyAlloc(allocator, .{ .object = obj }, .{ .whitespace = .minified });
}

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
