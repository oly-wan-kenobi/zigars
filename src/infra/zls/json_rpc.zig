const std = @import("std");

/// JSON-RPC 2.0 request ID — can be integer, string, or null.
pub const RequestId = union(enum) {
    integer: i64,
    string: []const u8,
    none,

    /// Parses JSON into allocator-owned values using the JSON-RPC allocator contract.
    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !RequestId {
        _ = allocator;
        _ = options;
        const token = try source.next();
        return switch (token) {
            .number => |n| .{ .integer = std.fmt.parseInt(i64, n, 10) catch return .{ .string = n } },
            .string, .allocated_string => |s| .{ .string = s },
            .null => .none,
            else => error.UnexpectedToken,
        };
    }

    /// Serializes JSON-RPC payloads with allocator-owned output.
    pub fn jsonStringify(self: RequestId, jw: anytype) !void {
        switch (self) {
            .integer => |i| try jw.write(i),
            .string => |s| try jw.write(s),
            .none => try jw.write(null),
        }
    }

    /// Compares JSON-RPC identifiers by tag and payload.
    pub fn eql(a: RequestId, b: RequestId) bool {
        return switch (a) {
            .integer => |ai| switch (b) {
                .integer => |bi| ai == bi,
                else => false,
            },
            .string => |as_| switch (b) {
                .string => |bs| std.mem.eql(u8, as_, bs),
                else => false,
            },
            .none => switch (b) {
                .none => true,
                else => false,
            },
        };
    }
};

/// Raw JSON-RPC message parsed from the wire. We keep `params`/`result`/`error`
/// as raw JSON slices so each handler can parse them with the right types.
pub const Message = struct {
    jsonrpc: []const u8 = "2.0",
    id: ?RequestId = null,
    method: ?[]const u8 = null,
    params: ?std.json.Value = null,
    result: ?std.json.Value = null,
    @"error": ?ErrorObject = null,
};

/// JSON-RPC error payload with optional structured data owned by the message.
pub const ErrorObject = struct {
    code: i64,
    message: []const u8,
    data: ?std.json.Value = null,
};

/// Standard JSON-RPC error codes.
pub const ErrorCode = struct {
    pub const parse_error: i64 = -32700;
    pub const invalid_request: i64 = -32600;
    pub const method_not_found: i64 = -32601;
    pub const invalid_params: i64 = -32602;
    pub const internal_error: i64 = -32603;
    // MCP/LSP custom
    pub const server_not_initialized: i64 = -32002;
    pub const request_timeout: i64 = -32001;
    pub const zls_not_running: i64 = -32000;
};

/// Write a JSON-RPC response with the given ID and result value.
pub fn writeResponse(allocator: std.mem.Allocator, id: RequestId, result: anytype) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    var aw_owned = true;
    defer if (aw_owned) aw.deinit();
    var jw: std.json.Stringify = .{
        .writer = &aw.writer,
        .options = .{},
    };
    try jw.beginObject();
    try jw.objectField("jsonrpc");
    try jw.write("2.0");
    try jw.objectField("id");
    try RequestId.jsonStringify(id, &jw);
    try jw.objectField("result");
    try jw.write(result);
    try jw.endObject();
    const bytes = try aw.toOwnedSlice();
    aw_owned = false;
    return bytes;
}

/// Write a JSON-RPC error response.
pub fn writeError(allocator: std.mem.Allocator, id: ?RequestId, code: i64, message: []const u8) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    var aw_owned = true;
    defer if (aw_owned) aw.deinit();
    var jw: std.json.Stringify = .{
        .writer = &aw.writer,
        .options = .{},
    };
    try jw.beginObject();
    try jw.objectField("jsonrpc");
    try jw.write("2.0");
    try jw.objectField("id");
    if (id) |rid| {
        try rid.jsonStringify(&jw);
    } else {
        try jw.write(null);
    }
    try jw.objectField("error");
    try jw.beginObject();
    try jw.objectField("code");
    try jw.write(code);
    try jw.objectField("message");
    try jw.write(message);
    try jw.endObject();
    try jw.endObject();
    const bytes = try aw.toOwnedSlice();
    aw_owned = false;
    return bytes;
}

/// Write a JSON-RPC notification (no id).
pub fn writeNotification(allocator: std.mem.Allocator, method: []const u8, params: anytype) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    var aw_owned = true;
    defer if (aw_owned) aw.deinit();
    var jw: std.json.Stringify = .{
        .writer = &aw.writer,
        .options = .{},
    };
    try jw.beginObject();
    try jw.objectField("jsonrpc");
    try jw.write("2.0");
    try jw.objectField("method");
    try jw.write(method);
    try jw.objectField("params");
    try jw.write(params);
    try jw.endObject();
    const bytes = try aw.toOwnedSlice();
    aw_owned = false;
    return bytes;
}

/// Write a JSON-RPC request (with id).
pub fn writeRequest(allocator: std.mem.Allocator, id: RequestId, method: []const u8, params: anytype) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    var aw_owned = true;
    defer if (aw_owned) aw.deinit();
    var jw: std.json.Stringify = .{
        .writer = &aw.writer,
        .options = .{},
    };
    try jw.beginObject();
    try jw.objectField("jsonrpc");
    try jw.write("2.0");
    try jw.objectField("id");
    try RequestId.jsonStringify(id, &jw);
    try jw.objectField("method");
    try jw.write(method);
    try jw.objectField("params");
    try jw.write(params);
    try jw.endObject();
    const bytes = try aw.toOwnedSlice();
    aw_owned = false;
    return bytes;
}
