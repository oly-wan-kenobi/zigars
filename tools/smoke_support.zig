const std = @import("std");
const cli_io = @import("cli_io.zig");
const json_query = @import("json_query.zig");

const Io = std.Io;
const JsonValue = std.json.Value;
const jsonStringifyAlloc = cli_io.jsonStringifyAlloc;

pub const valueAt = json_query.valueAt;

pub fn nowNs(io: Io) i96 {
    return Io.Clock.now(.real, io).nanoseconds;
}

pub fn pickPort(io: Io) u16 {
    const ns = nowNs(io);
    const positive: u128 = @intCast(if (ns < 0) -ns else ns);
    return @intCast(41000 + (positive % 8000));
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

pub fn callHttpToolJson(allocator: std.mem.Allocator, io: Io, port: u16, id: i64, tool_name: []const u8, args_json: []const u8) ![]u8 {
    const body = try std.fmt.allocPrint(allocator,
        \\{{"jsonrpc":"2.0","id":{d},"method":"tools/call","params":{{"name":"{s}","arguments":{s}}}}}
    , .{ id, tool_name, args_json });
    defer allocator.free(body);

    const response = try rpc(allocator, io, port, body);
    defer allocator.free(response);
    const parsed = try std.json.parseFromSlice(JsonValue, allocator, response, .{});
    defer parsed.deinit();
    const result = parsed.value.object.get("result").?.object;
    if (result.get("structuredContent")) |structured| {
        return jsonStringifyAlloc(allocator, structured, .{ .whitespace = .minified });
    }
    const text = result.get("content").?.array.items[0].object.get("text").?.string;
    return allocator.dupe(u8, text);
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

fn stderrPrint(io: Io, comptime fmt: []const u8, args: anytype) !void {
    var buffer: [4096]u8 = undefined;
    var writer = Io.File.stderr().writer(io, &buffer);
    try writer.interface.print(fmt, args);
    try writer.interface.flush();
}
