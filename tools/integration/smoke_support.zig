const std = @import("std");
const builtin = @import("builtin");
const cli_io = @import("../common/cli_io.zig");
const json_query = @import("../common/json_query.zig");

const Io = std.Io;
const JsonValue = std.json.Value;
const jsonStringifyAlloc = cli_io.jsonStringifyAlloc;

pub const valueAt = json_query.valueAt;

/// Loopback-only smoke port search window. Bounded so concurrent runs converge
/// quickly while staying clear of well-known service ports.
pub const port_base: u16 = 41000;
pub const port_window: u16 = 8000;

pub fn nowNs(io: Io) i96 {
    return Io.Clock.now(.real, io).nanoseconds;
}

/// Process-stable identifier used to seed deterministic port selection. Unlike a
/// wall-clock reading it is fixed for the run and differs between concurrent
/// processes, so two smoke runs do not derive the same starting port (LOW-9).
fn currentProcessId() u32 {
    return switch (builtin.os.tag) {
        .windows => std.os.windows.GetCurrentProcessId(),
        .wasi => 1,
        else => @bitCast(@as(i32, @truncate(std.posix.system.getpid()))),
    };
}

/// Returns the n-th deterministic candidate port in the loopback search window.
/// The starting offset is derived from the process id (LOW-9: no wall-clock
/// derivation), and successive attempts walk the window so a lingering socket on
/// one port is skipped on the next attempt.
pub fn candidatePort(attempt: u16) u16 {
    const seed: u32 = currentProcessId();
    const offset: u32 = (seed +% attempt) % port_window;
    return port_base + @as(u16, @intCast(offset));
}

/// Reserves a currently-free loopback port by binding it in this process and
/// immediately releasing it, so the returned port is verified free at selection
/// time rather than guessed from the wall clock (LOW-9). The bind also proves the
/// port is not held by a lingering socket from a previous run. The returned port
/// is handed to the child server, which rebinds it; callers should still treat a
/// failed child startup as a signal to retry with a fresh port to absorb the
/// (small) bind/rebind race.
pub fn reserveLoopbackPort(io: Io) !u16 {
    const max_attempts: u16 = 64;
    var attempt: u16 = 0;
    while (attempt < max_attempts) : (attempt += 1) {
        const port = candidatePort(attempt);
        const address = Io.net.IpAddress.parse("127.0.0.1", port) catch continue;
        var listener = Io.net.IpAddress.listen(&address, io, .{}) catch |err| switch (err) {
            error.AddressInUse, error.AddressUnavailable => continue,
            else => return err,
        };
        listener.deinit(io);
        return port;
    }
    return error.NoFreePort;
}

/// Retained for callers that only need a deterministic candidate without a live
/// bind probe; prefer `reserveLoopbackPort`.
pub fn pickPort(io: Io) u16 {
    return reserveLoopbackPort(io) catch candidatePort(0);
}

pub fn absolutePath(allocator: std.mem.Allocator, io: Io, path: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(path)) return std.fs.path.resolve(allocator, &.{path});
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = try std.process.currentPath(io, &cwd_buf);
    return std.fs.path.resolve(allocator, &.{ cwd_buf[0..cwd_len], path });
}

pub fn findTool(tools: []JsonValue, name: []const u8) ?JsonValue {
    for (tools) |tool| {
        if (std.mem.eql(u8, tool.object.get("name").?.string, name)) return tool;
    }
    return null;
}

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

pub fn expectJsonEq(io: Io, actual: JsonValue, expected: JsonValue, path: []const u8) !void {
    switch (expected) {
        .string => |s| if (actual != .string or !std.mem.eql(u8, actual.string, s)) {
            try stderrPrint(io, "assertion failed at {s}: expected string {s}\n", .{ path, s });
            return error.AssertionFailed;
        },
        .bool => |b| if (actual != .bool or actual.bool != b) {
            try stderrPrint(io, "assertion failed at {s}: expected bool {}\n", .{ path, b });
            return error.AssertionFailed;
        },
        .integer => |n| if (actual != .integer or actual.integer != n) {
            try stderrPrint(io, "assertion failed at {s}: expected integer {d}\n", .{ path, n });
            return error.AssertionFailed;
        },
        else => return error.UnsupportedExpectation,
    }
}

/// Asserts a workspace-relative path does not exist on disk. Used to verify that
/// a blocked or sandbox-rejected apply leaves nothing behind (MEDIUM-5): the HTTP
/// server's workspace is the process cwd, so the same relative path the tool was
/// asked to write is checked here against the real filesystem rather than relying
/// on the tool's self-reported `applied:false`.
pub fn expectFileAbsent(io: Io, rel: []const u8) !void {
    Io.Dir.cwd().access(io, rel, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    try stderrPrint(io, "expected no file written at {s}, but it exists on disk\n", .{rel});
    return error.AssertionFailed;
}

pub fn expectStringEq(io: Io, actual: []const u8, expected: []const u8, label: []const u8) !void {
    if (!std.mem.eql(u8, actual, expected)) {
        try stderrPrint(io, "{s}: expected `{s}`, got `{s}`\n", .{ label, expected, actual });
        return error.AssertionFailed;
    }
}

pub fn assertMinimumCount(io: Io, label: []const u8, actual: usize, expected: usize) !void {
    if (actual >= expected) return;
    try stderrPrint(io, "{s}: expected at least {d}, got {d}\n", .{ label, expected, actual });
    return error.AssertionFailed;
}

pub fn assertHttpRpcContains(allocator: std.mem.Allocator, io: Io, port: u16, body: []const u8, needle: []const u8, scenario_count: *usize) !void {
    const response = try rpc(allocator, io, port, body);
    defer allocator.free(response);
    if (std.mem.indexOf(u8, response, needle) == null) return error.AssertionFailed;
    scenario_count.* += 1;
}

fn stderrPrint(io: Io, comptime fmt: []const u8, args: anytype) !void {
    var buffer: [4096]u8 = undefined;
    var writer = Io.File.stderr().writer(io, &buffer);
    try writer.interface.print(fmt, args);
    try writer.interface.flush();
}

test "findTool locates JSON tool entries by name" {
    var obj: std.json.ObjectMap = .empty;
    defer obj.deinit(std.testing.allocator);
    try obj.put(std.testing.allocator, "name", .{ .string = "zig_check" });
    var tools = [_]JsonValue{.{ .object = obj }};
    try std.testing.expect(findTool(&tools, "zig_check") != null);
    try std.testing.expect(findTool(&tools, "zig_missing") == null);
}
