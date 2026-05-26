const std = @import("std");
const smoke = @import("smoke_support.zig");

const Io = std.Io;
const JsonValue = std.json.Value;
const valueAt = smoke.valueAt;

pub fn run(allocator: std.mem.Allocator, io: Io, port: u16, expected: JsonValue, scenario_count: *usize) !void {
    try assertToolPaths(allocator, io, port, 118, "zigar_patch_session_create", "{\"goal\":\"fixture edit\",\"files\":\"src/main.zig zig-out/generated.zig\"}", expected, "patch_session_create_paths", scenario_count);
    try assertToolPaths(allocator, io, port, 119, "zigar_patch_session_preview", "{\"edits\":\"[{\\\"file\\\":\\\"tests/fixtures/static-analysis/usingnamespace.zig\\\",\\\"content\\\":\\\"const std = @import(\\\\\\\"std\\\\\\\");\\\\n\\\\nusingnamespace std;\\\\n// fixture preview\\\\n\\\"}]\"}", expected, "patch_session_preview_paths", scenario_count);
    try assertToolPaths(allocator, io, port, 120, "zigar_patch_session_apply", "{\"edits\":\"[{\\\"file\\\":\\\"zig-out/blocked.zig\\\",\\\"content\\\":\\\"pub const blocked = true;\\\\n\\\"}]\",\"apply\":true}", expected, "patch_session_apply_blocked_paths", scenario_count);
    try assertToolPaths(allocator, io, port, 121, "zigar_patch_session_validate", "{\"session_id\":\"fixture\",\"changed_files\":\"notes.txt\",\"mode\":\"quick\",\"apply\":false}", expected, "patch_session_validate_paths", scenario_count);
    try assertToolPaths(allocator, io, port, 122, "zigar_patch_session_revert", "{\"session_id\":\"fixture\",\"history\":\"{\\\"session_id\\\":\\\"fixture\\\",\\\"files\\\":[]}\",\"apply\":false}", expected, "patch_session_revert_paths", scenario_count);
    try assertToolPaths(allocator, io, port, 123, "zig_generated_file_trace", "{\"path\":\"docs/tool-index.generated.md\"}", expected, "generated_file_trace_paths", scenario_count);
    try assertToolPaths(allocator, io, port, 124, "zigar_edit_policy_check", "{\"files\":\"src/main.zig zig-out/generated.zig\"}", expected, "edit_policy_check_paths", scenario_count);
    try assertToolPaths(allocator, io, port, 125, "zigar_generated_route", "{\"path\":\"docs/tool-index.generated.md\",\"goal\":\"update tool docs\"}", expected, "generated_route_paths", scenario_count);
    try assertToolPaths(allocator, io, port, 126, "zig_organize_imports", "{\"file\":\"tests/fixtures/static-analysis/tricky.zig\",\"apply\":false}", expected, "organize_imports_paths", scenario_count);
    try assertToolPaths(allocator, io, port, 127, "zig_update_imports", "{\"file\":\"tests/fixtures/static-analysis/tricky.zig\",\"old_import\":\"math.zig\",\"new_import\":\"math2.zig\",\"apply\":false}", expected, "update_imports_paths", scenario_count);
    try assertToolPaths(allocator, io, port, 128, "zig_move_decl", "{\"source_file\":\"tests/fixtures/static-analysis/tricky.zig\",\"target_file\":\"tests/fixtures/static-analysis/usingnamespace.zig\",\"name\":\"LocalErrors\",\"apply\":false}", expected, "move_decl_paths", scenario_count);
    try assertToolPaths(allocator, io, port, 129, "zig_extract_decl", "{\"file\":\"tests/fixtures/static-analysis/tricky.zig\",\"target_file\":\"tests/fixtures/static-analysis/usingnamespace.zig\",\"start_line\":25,\"end_line\":27,\"apply\":false}", expected, "extract_decl_paths", scenario_count);
    try assertToolPaths(allocator, io, port, 130, "zig_code_action_batch", "{\"file\":\"src/main.zig\",\"start_line\":1,\"start_char\":1,\"end_line\":1,\"end_char\":1,\"action_indices\":\"0\",\"apply\":false}", expected, "code_action_batch_paths", scenario_count);
}

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

test "http transactional editing smoke exposes run entrypoint" {
    try std.testing.expect(@hasDecl(@This(), "run"));
}
