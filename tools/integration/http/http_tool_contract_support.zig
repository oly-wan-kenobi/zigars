//! Shared HTTP tool-result contract assertion helpers. Each tool-family scenario
//! module imports these so call order and request IDs stay co-located with the
//! expectations they enforce. Logs missing paths to stderr for diagnosability.

const std = @import("std");
const cli_io = @import("../../common/cli_io.zig");
const smoke = @import("../smoke_support.zig");

const Io = std.Io;
const JsonValue = std.json.Value;
const stderrPrint = cli_io.stderrPrint;
const valueAt = smoke.valueAt;

// Shared helpers for the HTTP tool-result contract fixtures. Each tool-family
// scenario list lives in its own module and reuses these assertions so call
// order and IDs stay close to the expectations they enforce.

/// Asserts fixture-owned JSON paths for one tool call.
pub fn assertToolPaths(
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
    // Normalize and constrain path handling here before any downstream filesystem action.
    const tool_json = try smoke.callHttpToolJson(allocator, io, port, id, tool_name, args_json);
    defer allocator.free(tool_json);
    const parsed = try std.json.parseFromSlice(JsonValue, allocator, tool_json, .{});
    defer parsed.deinit();
    const expected_paths = expected_root.object.get(expected_key).?.object;
    var it = expected_paths.iterator();
    while (it.next()) |entry| {
        const actual = valueAt(parsed.value, entry.key_ptr.*) orelse {
            try stderrPrint(io, "{s}: missing path {s}\n", .{ tool_name, entry.key_ptr.* });
            return error.AssertionFailed;
        };
        try smoke.expectJsonEq(io, actual, entry.value_ptr.*, entry.key_ptr.*);
    }
    scenario_count.* += 1;
}

/// Like `assertToolPaths`, but also asserts the MCP `isError` envelope flag for
/// error-path fixtures (MEDIUM-4). Decodes the result through `callHttpTool`,
/// which guards the JSON-RPC `error` envelope and fails cleanly on malformed
/// results instead of panicking (LOW-8).
pub fn assertToolPathsIsError(
    allocator: std.mem.Allocator,
    io: Io,
    port: u16,
    id: i64,
    tool_name: []const u8,
    args_json: []const u8,
    expected_root: JsonValue,
    expected_key: []const u8,
    expect_is_error: bool,
    scenario_count: *usize,
) !void {
    // Preserve a single error-shaping path so callers receive consistent metadata.
    const result = try smoke.callHttpTool(allocator, io, port, id, tool_name, args_json);
    defer result.deinit(allocator);
    try smoke.expectToolIsError(io, result, expect_is_error, tool_name);
    const parsed = try std.json.parseFromSlice(JsonValue, allocator, result.json, .{});
    defer parsed.deinit();
    const expected_paths = expected_root.object.get(expected_key).?.object;
    var it = expected_paths.iterator();
    while (it.next()) |entry| {
        const actual = valueAt(parsed.value, entry.key_ptr.*) orelse {
            try stderrPrint(io, "{s}: missing path {s}\n", .{ tool_name, entry.key_ptr.* });
            return error.AssertionFailed;
        };
        try smoke.expectJsonEq(io, actual, entry.value_ptr.*, entry.key_ptr.*);
    }
    scenario_count.* += 1;
}
