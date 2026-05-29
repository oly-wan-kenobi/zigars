const std = @import("std");
const cli_io = @import("../../common/cli_io.zig");
const smoke_assert = @import("smoke_assert.zig");

const Io = std.Io;
const JsonValue = std.json.Value;
const jsonStringifyAlloc = cli_io.jsonStringifyAlloc;
const stderrPrint = smoke_assert.stderrPrint;

/// A decoded `tools/call` result: the structured (or text-fallback) payload plus
/// the sibling `isError` flag from the MCP result envelope. The server reports
/// tool failures as a `result` with `isError:true` (not a JSON-RPC `error`), so
/// asserting `is_error` is the only way a fixture can catch a success/error
/// envelope flip while the structured `kind` payload is unchanged (MEDIUM-4).
pub const ToolCallResult = struct {
    json: []u8,
    is_error: bool,

    pub fn deinit(self: ToolCallResult, allocator: std.mem.Allocator) void {
        allocator.free(self.json);
    }
};

/// Issues a `tools/call` over HTTP and decodes the result envelope. Mirrors the
/// stdio client's guards (LOW-8): a JSON-RPC `error` envelope returns
/// `error.McpError` rather than panicking, and every previously-`.?` access on
/// the `result`/`content`/`text` chain fails with `error.AssertionFailed`
/// instead of an opaque unreachable.
pub fn callHttpTool(allocator: std.mem.Allocator, io: Io, port: u16, id: i64, tool_name: []const u8, args_json: []const u8) !ToolCallResult {
    const body = try std.fmt.allocPrint(allocator,
        \\{{"jsonrpc":"2.0","id":{d},"method":"tools/call","params":{{"name":"{s}","arguments":{s}}}}}
    , .{ id, tool_name, args_json });
    defer allocator.free(body);

    const response = try rpc(allocator, io, port, body);
    defer allocator.free(response);
    const parsed = try std.json.parseFromSlice(JsonValue, allocator, response, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.AssertionFailed;
    if (parsed.value.object.get("error")) |_| return error.McpError;
    const result_value = parsed.value.object.get("result") orelse return error.AssertionFailed;
    if (result_value != .object) return error.AssertionFailed;
    const result = result_value.object;

    const is_error = if (result.get("isError")) |flag| blk: {
        if (flag != .bool) return error.AssertionFailed;
        break :blk flag.bool;
    } else false;

    if (result.get("structuredContent")) |structured| {
        const json = try jsonStringifyAlloc(allocator, structured, .{ .whitespace = .minified });
        return .{ .json = json, .is_error = is_error };
    }
    const content = result.get("content") orelse return error.AssertionFailed;
    if (content != .array or content.array.items.len == 0) return error.AssertionFailed;
    const first = content.array.items[0];
    if (first != .object) return error.AssertionFailed;
    const text_value = first.object.get("text") orelse return error.AssertionFailed;
    if (text_value != .string) return error.AssertionFailed;
    const json = try allocator.dupe(u8, text_value.string);
    return .{ .json = json, .is_error = is_error };
}

/// Backwards-compatible wrapper that returns only the decoded payload. Callers
/// that need to assert the `isError` envelope flag should use `callHttpTool`.
pub fn callHttpToolJson(allocator: std.mem.Allocator, io: Io, port: u16, id: i64, tool_name: []const u8, args_json: []const u8) ![]u8 {
    const result = try callHttpTool(allocator, io, port, id, tool_name, args_json);
    return result.json;
}

/// Asserts the decoded `tools/call` result reports the expected `isError` flag,
/// emitting a diagnosable message on mismatch.
pub fn expectToolIsError(io: Io, result: ToolCallResult, expected: bool, label: []const u8) !void {
    if (result.is_error == expected) return;
    try stderrPrint(io, "{s}: expected isError={}, got isError={}\n", .{ label, expected, result.is_error });
    return error.AssertionFailed;
}

pub fn rpc(allocator: std.mem.Allocator, io: Io, port: u16, body: []const u8) ![]u8 {
    const address = try Io.net.IpAddress.parse("127.0.0.1", port);
    var stream = try address.connect(io, .{
        .mode = .stream,
        .protocol = .tcp,
        .timeout = .none,
    });
    defer stream.close(io);

    var writer_buffer: [4096]u8 = undefined;
    var writer = stream.writer(io, &writer_buffer);
    try writer.interface.print(
        "POST / HTTP/1.1\r\nHost: 127.0.0.1:{d}\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n",
        .{ port, body.len },
    );
    try writer.interface.writeAll(body);
    try writer.interface.flush();

    var reader_buffer: [4096]u8 = undefined;
    var reader = stream.reader(io, &reader_buffer);
    const response = try reader.interface.allocRemaining(allocator, .limited(8 * 1024 * 1024));
    defer allocator.free(response);

    const header_end = std.mem.indexOf(u8, response, "\r\n\r\n") orelse return error.InvalidHttpResponse;
    const header = response[0..header_end];
    const response_body = response[header_end + 4 ..];
    if (std.mem.indexOf(u8, header, " 200 ") == null) {
        try stderrPrint(io, "HTTP failure:\n{s}\n{s}\n", .{ header, response_body });
        return error.HttpFailure;
    }
    return allocator.dupe(u8, response_body);
}

pub fn rawHttp(allocator: std.mem.Allocator, io: Io, port: u16, request: []const u8) ![]u8 {
    const address = try Io.net.IpAddress.parse("127.0.0.1", port);
    var stream = try address.connect(io, .{
        .mode = .stream,
        .protocol = .tcp,
        .timeout = .none,
    });
    defer stream.close(io);

    var writer_buffer: [4096]u8 = undefined;
    var writer = stream.writer(io, &writer_buffer);
    try writer.interface.writeAll(request);
    try writer.interface.flush();
    stream.shutdown(io, .send) catch {};

    var reader_buffer: [4096]u8 = undefined;
    var reader = stream.reader(io, &reader_buffer);
    return reader.interface.allocRemaining(allocator, .limited(8 * 1024 * 1024));
}

pub fn assertRawHttpContains(allocator: std.mem.Allocator, io: Io, port: u16, request: []const u8, needle: []const u8, scenario_count: *usize) !void {
    const response = try rawHttp(allocator, io, port, request);
    defer allocator.free(response);
    if (std.mem.indexOf(u8, response, needle) == null) return error.AssertionFailed;
    scenario_count.* += 1;
}

pub fn assertHttpRpcContains(allocator: std.mem.Allocator, io: Io, port: u16, body: []const u8, needle: []const u8, scenario_count: *usize) !void {
    const response = try rpc(allocator, io, port, body);
    defer allocator.free(response);
    if (std.mem.indexOf(u8, response, needle) == null) return error.AssertionFailed;
    scenario_count.* += 1;
}
