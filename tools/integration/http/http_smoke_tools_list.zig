const std = @import("std");
const cli_io = @import("../../common/cli_io.zig");
const smoke = @import("../smoke_support.zig");

const Io = std.Io;
const JsonValue = std.json.Value;
const stderrPrint = cli_io.stderrPrint;
const valueAt = smoke.valueAt;

// `tools/list` validation for the HTTP smoke suite: required-tool presence and
// the per-tool schema-path assertions. Kept separate from the transport-level
// entrypoint so `http_smoke.zig` stays focused on request/response checks.

pub fn assertRequiredTools(allocator: std.mem.Allocator, io: Io, port: u16, expected: JsonValue) !void {
    const tools_response = try smoke.rpc(allocator, io, port, "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\"}");
    defer allocator.free(tools_response);
    const parsed = try std.json.parseFromSlice(JsonValue, allocator, tools_response, .{});
    defer parsed.deinit();
    const tools = valueAt(parsed.value, "result.tools").?.array.items;
    for (expected.object.get("required_tools").?.array.items) |required| {
        if (smoke.findTool(tools, required.string) != null) continue;
        try stderrPrint(io, "missing tool: {s}\n", .{required.string});
        return error.AssertionFailed;
    }
    try assertToolsListSchemas(io, tools, expected);
}

fn assertToolsListSchemas(io: Io, tools: []JsonValue, expected: JsonValue) !void {
    const expected_schemas = expected.object.get("tools_list_schema_paths") orelse return;
    var tool_it = expected_schemas.object.iterator();
    while (tool_it.next()) |tool_entry| {
        const tool = smoke.findTool(tools, tool_entry.key_ptr.*) orelse {
            try stderrPrint(io, "missing tool schema target: {s}\n", .{tool_entry.key_ptr.*});
            return error.AssertionFailed;
        };
        var path_it = tool_entry.value_ptr.object.iterator();
        while (path_it.next()) |path_entry| {
            const actual = valueAt(tool, path_entry.key_ptr.*) orelse {
                try stderrPrint(io, "{s}: missing tools/list schema path {s}\n", .{ tool_entry.key_ptr.*, path_entry.key_ptr.* });
                return error.AssertionFailed;
            };
            try smoke.expectJsonEq(io, actual, path_entry.value_ptr.*, path_entry.key_ptr.*);
        }
    }
}
