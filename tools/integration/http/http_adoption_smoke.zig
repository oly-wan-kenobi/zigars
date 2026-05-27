const std = @import("std");
const smoke = @import("../smoke_support.zig");

const Io = std.Io;
const JsonValue = std.json.Value;
const valueAt = smoke.valueAt;

const evidence_arg = "{\\\"kind\\\":\\\"zigars_backend_conformance_report\\\",\\\"compatibility_matrix\\\":[{\\\"backend\\\":\\\"zflame\\\",\\\"status\\\":\\\"passed\\\"},{\\\"backend\\\":\\\"zls\\\",\\\"status\\\":\\\"failed\\\"}]}";

pub fn run(allocator: std.mem.Allocator, io: Io, port: u16, expected: JsonValue, scenario_count: *usize) !void {
    try assertToolPaths(allocator, io, port, 220, "zigars_adoption_pack", "{\"client\":\"codex\",\"transport\":\"stdio\",\"backend\":\"zflame\"}", expected, "adoption_pack_paths", scenario_count);
    try assertToolPaths(allocator, io, port, 221, "zigars_client_config_generate", "{\"client\":\"codex\",\"kind\":\"codex-toml\",\"output\":\".zigars-cache/adoption/http-codex.toml\",\"apply\":false}", expected, "client_config_paths", scenario_count);
    try assertToolPaths(allocator, io, port, 222, "zigars_smoke_plan", "{\"client\":\"generic\",\"backend\":\"zflame\",\"platform\":\"linux\",\"timeout_ms\":1000}", expected, "smoke_plan_paths", scenario_count);
    const conformance_args = try std.fmt.allocPrint(allocator, "{{\"backend\":\"all\",\"content\":\"{s}\"}}", .{evidence_arg});
    defer allocator.free(conformance_args);
    try assertToolPaths(allocator, io, port, 223, "zigars_conformance_report", conformance_args, expected, "conformance_report_paths", scenario_count);
    try assertToolPaths(allocator, io, port, 224, "zigars_smoke_plan", "{\"platform\":\"plan9\"}", expected, "smoke_plan_unsupported_paths", scenario_count);
}

fn assertToolPaths(
    allocator: std.mem.Allocator,
    io: Io,
    port: u16,
    id: i64,
    tool_name: []const u8,
    args_json: []const u8,
    expected_root: JsonValue,
    expected_key: []const u8,
    scenario_count: *usize,
) !void {
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

test "http adoption smoke exposes run entrypoint" {
    try std.testing.expect(@hasDecl(@This(), "run"));
}
