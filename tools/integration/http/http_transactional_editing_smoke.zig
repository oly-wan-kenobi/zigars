//! HTTP smoke fixture for the transactional-editing tool family:
//! patch-session create/preview/apply/validate/revert, generated-file trace,
//! edit-policy check, and import-refactoring tools (IDs 118-130). Includes a
//! filesystem-level assertion that a blocked apply (cache-classified path) does
//! not reach disk.

const std = @import("std");
const smoke = @import("../smoke_support.zig");

const Io = std.Io;
const JsonValue = std.json.Value;
const valueAt = smoke.valueAt;

/// Exercises transactional-editing tools through the HTTP transport and asserts
/// structured result paths against `expected`. `scenario_count` is incremented
/// once per successful assertion group.
pub fn run(allocator: std.mem.Allocator, io: Io, port: u16, expected: JsonValue, scenario_count: *usize) !void {
    try assertToolPaths(allocator, io, port, 118, "zigars_patch_session_create", "{\"goal\":\"fixture edit\",\"files\":\"src/main.zig zig-out/generated.zig\"}", expected, "patch_session_create_paths", scenario_count);
    try assertToolPaths(allocator, io, port, 119, "zigars_patch_session_preview", "{\"edits\":\"[{\\\"file\\\":\\\"tests/fixtures/static-analysis/usingnamespace.zig\\\",\\\"content\\\":\\\"const std = @import(\\\\\\\"std\\\\\\\");\\\\n\\\\nusingnamespace std;\\\\n// fixture preview\\\\n\\\"}]\"}", expected, "patch_session_preview_paths", scenario_count);
    // Blocked apply against a cache-classified path. The server self-reports
    // applied:false; previously nothing confirmed the write was actually
    // suppressed on disk and the HTTP transport never verified filesystem
    // effects at all (MEDIUM-5). Assert the structured contract, the isError
    // envelope (a blocked apply is an ordinary result, not an error → false),
    // and that the target file does NOT exist on disk. The HTTP server's
    // workspace is the process cwd, so the workspace-relative path the tool was
    // asked to write is the same path checked here.
    try assertBlockedApplyNoWrite(allocator, io, port, 120, "zig-out/blocked.zig", expected, "patch_session_apply_blocked_paths", scenario_count);
    try assertToolPaths(allocator, io, port, 121, "zigars_patch_session_validate", "{\"session_id\":\"fixture\",\"changed_files\":\"notes.txt\",\"mode\":\"quick\",\"apply\":false}", expected, "patch_session_validate_paths", scenario_count);
    try assertToolPaths(allocator, io, port, 122, "zigars_patch_session_revert", "{\"session_id\":\"fixture\",\"history\":\"{\\\"session_id\\\":\\\"fixture\\\",\\\"files\\\":[]}\",\"apply\":false}", expected, "patch_session_revert_paths", scenario_count);
    try assertToolPaths(allocator, io, port, 123, "zig_generated_file_trace", "{\"path\":\"docs/tool-index.generated.md\"}", expected, "generated_file_trace_paths", scenario_count);
    try assertToolPaths(allocator, io, port, 124, "zigars_edit_policy_check", "{\"files\":\"src/main.zig zig-out/generated.zig\"}", expected, "edit_policy_check_paths", scenario_count);
    try assertToolPaths(allocator, io, port, 125, "zigars_generated_route", "{\"path\":\"docs/tool-index.generated.md\",\"goal\":\"update tool docs\"}", expected, "generated_route_paths", scenario_count);
    try assertToolPaths(allocator, io, port, 126, "zig_organize_imports", "{\"file\":\"tests/fixtures/static-analysis/tricky.zig\",\"apply\":false}", expected, "organize_imports_paths", scenario_count);
    try assertToolPaths(allocator, io, port, 127, "zig_update_imports", "{\"file\":\"tests/fixtures/static-analysis/tricky.zig\",\"old_import\":\"math.zig\",\"new_import\":\"math2.zig\",\"apply\":false}", expected, "update_imports_paths", scenario_count);
    try assertToolPaths(allocator, io, port, 128, "zig_move_decl", "{\"source_file\":\"tests/fixtures/static-analysis/tricky.zig\",\"target_file\":\"tests/fixtures/static-analysis/usingnamespace.zig\",\"name\":\"LocalErrors\",\"apply\":false}", expected, "move_decl_paths", scenario_count);
    try assertToolPaths(allocator, io, port, 129, "zig_extract_decl", "{\"file\":\"tests/fixtures/static-analysis/tricky.zig\",\"target_file\":\"tests/fixtures/static-analysis/usingnamespace.zig\",\"start_line\":25,\"end_line\":27,\"apply\":false}", expected, "extract_decl_paths", scenario_count);
    try assertToolPaths(allocator, io, port, 130, "zig_code_action_batch", "{}", expected, "code_action_batch_paths", scenario_count);
}

/// Invokes `tool_name` via HTTP JSON-RPC and asserts every JSON path in the
/// `expected_key` sub-object of `expected_root`. Returns `error.AssertionFailed`
/// on a missing path. Increments `scenario_count` on success.
fn assertToolPaths(allocator: std.mem.Allocator, io: Io, port: u16, id: i64, tool_name: []const u8, args_json: []const u8, expected_root: JsonValue, expected_key: []const u8, scenario_count: *usize) !void {
    const tool_json = try smoke.callHttpToolJson(allocator, io, port, id, tool_name, args_json);
    defer allocator.free(tool_json);
    const parsed = try std.json.parseFromSlice(JsonValue, allocator, tool_json, .{});
    defer parsed.deinit();
    var it = expected_root.object.get(expected_key).?.object.iterator();
    while (it.next()) |entry| {
        const actual = valueAt(parsed.value, entry.key_ptr.*) orelse return error.AssertionFailed;
        try smoke.expectJsonEq(io, actual, entry.value_ptr.*, entry.key_ptr.*);
    }
    scenario_count.* += 1;
}

/// Verifies an `apply:true` request against a blocked (cache-classified) path is
/// rejected against the real filesystem, not merely self-reported. Asserts the
/// fixture-owned structured paths, the MCP isError flag (false: a blocked apply
/// is an ordinary result), and that neither the apply target nor the
/// cache-classified path captured at session creation was written to disk.
fn assertBlockedApplyNoWrite(
    allocator: std.mem.Allocator,
    io: Io,
    port: u16,
    id: i64,
    blocked_path: []const u8,
    expected_root: JsonValue,
    expected_key: []const u8,
    scenario_count: *usize,
) !void {
    // Pre-state: a regression that writes the blocked path must be observable, so
    // the target must not already exist before the call.
    try smoke.expectFileAbsent(io, blocked_path);

    const args = try std.fmt.allocPrint(
        allocator,
        "{{\"edits\":\"[{{\\\"file\\\":\\\"{s}\\\",\\\"content\\\":\\\"pub const blocked = true;\\\\n\\\"}}]\",\"apply\":true}}",
        .{blocked_path},
    );
    defer allocator.free(args);

    const result = try smoke.callHttpTool(allocator, io, port, id, "zigars_patch_session_apply", args);
    defer result.deinit(allocator);
    try smoke.expectToolIsError(io, result, false, "zigars_patch_session_apply blocked");

    const parsed = try std.json.parseFromSlice(JsonValue, allocator, result.json, .{});
    defer parsed.deinit();
    var it = expected_root.object.get(expected_key).?.object.iterator();
    while (it.next()) |entry| {
        const actual = valueAt(parsed.value, entry.key_ptr.*) orelse return error.AssertionFailed;
        try smoke.expectJsonEq(io, actual, entry.value_ptr.*, entry.key_ptr.*);
    }

    // Post-state: the blocked apply must not have reached disk. Also confirm the
    // cache-classified path referenced during session creation stayed unwritten.
    try smoke.expectFileAbsent(io, blocked_path);
    try smoke.expectFileAbsent(io, "zig-out/generated.zig");
    scenario_count.* += 1;
}

test "http transactional editing smoke exposes run entrypoint" {
    try std.testing.expect(@hasDecl(@This(), "run"));
}
