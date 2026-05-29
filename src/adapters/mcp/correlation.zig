//! Process-local MCP request correlation helpers.
const std = @import("std");
const mcp = @import("mcp");

const types = mcp.types;

/// Result `_meta` key carrying zigars request correlation metadata.
pub const meta_key = "dev.zigars/correlation";
pub const trace_id_len = 32;
pub const span_id_len = 16;
pub const tool_call_id_len = "zigars-tc-000000000000".len;

/// Normalized JSON-RPC request id. String and integer forms remain distinct.
pub const RequestId = struct {
    kind: Kind = .absent,
    integer: i64 = 0,
    string: []const u8 = "",
    integer_text: [32]u8 = undefined,
    integer_text_len: usize = 0,

    pub const Kind = enum {
        integer,
        string,
        absent,
    };

    /// Builds an absent id for notifications and parse failures.
    pub fn absent() RequestId {
        return .{};
    }

    /// Normalizes an optional MCP request id while preserving its type.
    pub fn fromOptional(id: ?types.RequestId) RequestId {
        const value = id orelse return absent();
        return from(value);
    }

    /// Normalizes a required MCP request id while preserving its type.
    pub fn from(id: types.RequestId) RequestId {
        return switch (id) {
            .integer => |value| blk: {
                var out: RequestId = .{
                    .kind = .integer,
                    .integer = value,
                };
                const text = std.fmt.bufPrint(&out.integer_text, "{d}", .{value}) catch unreachable;
                out.integer_text_len = text.len;
                break :blk out;
            },
            .string => |value| .{
                .kind = .string,
                .string = value,
            },
        };
    }

    /// Stable type label used in JSON metadata.
    pub fn typeName(self: RequestId) []const u8 {
        return switch (self.kind) {
            .integer => "integer",
            .string => "string",
            .absent => "null",
        };
    }

    /// String rendering used in metadata. Integer ids render as decimal text.
    pub fn valueString(self: *const RequestId) ?[]const u8 {
        return switch (self.kind) {
            .integer => self.integer_text[0..self.integer_text_len],
            .string => self.string,
            .absent => null,
        };
    }

    /// Compact request id for stderr diagnostics.
    pub fn compactValue(self: *const RequestId, buffer: *[64]u8) []const u8 {
        const value = self.valueString() orelse return "null";
        if (value.len <= buffer.len) return value;
        const prefix_len = buffer.len - 3;
        @memcpy(buffer[0..prefix_len], value[0..prefix_len]);
        @memcpy(buffer[prefix_len..buffer.len], "...");
        return buffer[0..];
    }
};

/// Full request-scoped correlation state.
pub const Context = struct {
    request_id: RequestId,
    mcp_method: []const u8,
    tool_name: ?[]const u8 = null,
    trace_id: [trace_id_len]u8,
    span_id: [span_id_len]u8,
    parent_span_id: ?[]const u8 = null,
    tool_call_id: [tool_call_id_len]u8,

    /// Creates correlation ids from a process-local sequence.
    pub fn init(sequence: u64, request_id: RequestId, mcp_method: []const u8, tool_name: ?[]const u8) Context {
        var out: Context = .{
            .request_id = request_id,
            .mcp_method = mcp_method,
            .tool_name = tool_name,
            .trace_id = undefined,
            .span_id = undefined,
            .tool_call_id = undefined,
        };
        writeLowerHexFixed(out.trace_id[0..], sequence);
        writeLowerHexFixed(out.span_id[0..], sequence);
        writeToolCallId(out.tool_call_id[0..], sequence);
        return out;
    }

    /// Records the tool name once tools/call parameters have been parsed.
    pub fn setToolName(self: *Context, tool_name: []const u8) void {
        self.tool_name = tool_name;
    }

    /// Returns the 32-character lowercase trace id.
    pub fn traceId(self: *const Context) []const u8 {
        return self.trace_id[0..];
    }

    /// Returns the 16-character lowercase span id.
    pub fn spanId(self: *const Context) []const u8 {
        return self.span_id[0..];
    }

    /// Returns the generated tool-call id.
    pub fn toolCallId(self: *const Context) []const u8 {
        return self.tool_call_id[0..];
    }

    /// Short trace suffix for compact stderr diagnostics.
    pub fn compactTrace(self: *const Context) []const u8 {
        return self.trace_id[trace_id_len - 8 .. trace_id_len];
    }

    /// Builds the value that should be stored as MCP result `_meta`.
    pub fn metaValue(self: *const Context, allocator: std.mem.Allocator) !std.json.Value {
        var correlation_obj: std.json.ObjectMap = .empty;
        var correlation_owned = true;
        errdefer if (correlation_owned) deinitMetaValue(allocator, .{ .object = correlation_obj });

        try correlation_obj.put(allocator, "schema_version", .{ .integer = 1 });
        try correlation_obj.put(allocator, "mcp_request_id", try requestIdValue(allocator, &self.request_id));
        try correlation_obj.put(allocator, "mcp_method", .{ .string = self.mcp_method });
        try correlation_obj.put(allocator, "tool_name", if (self.tool_name) |name| .{ .string = name } else .null);
        try correlation_obj.put(allocator, "trace_id", .{ .string = self.traceId() });
        try correlation_obj.put(allocator, "span_id", .{ .string = self.spanId() });
        try correlation_obj.put(allocator, "parent_span_id", if (self.parent_span_id) |span| .{ .string = span } else .null);
        try correlation_obj.put(allocator, "tool_call_id", .{ .string = self.toolCallId() });

        var meta_obj: std.json.ObjectMap = .empty;
        var meta_owned = true;
        errdefer if (meta_owned) deinitMetaValue(allocator, .{ .object = meta_obj });

        try meta_obj.put(allocator, meta_key, .{ .object = correlation_obj });
        correlation_owned = false;
        meta_owned = false;
        return .{ .object = meta_obj };
    }

    /// Inserts `_meta` into a JSON-RPC result object.
    pub fn putMeta(self: *const Context, allocator: std.mem.Allocator, result: *std.json.ObjectMap) !void {
        const meta = try self.metaValue(allocator);
        errdefer deinitMetaValue(allocator, meta);
        try result.put(allocator, "_meta", meta);
    }

    /// Formats a compact request correlation prefix for stderr diagnostics into
    /// `prefix_buffer`. `request_id_buffer` backs the compact request-id slice.
    /// Adapter-local so the MCP server logs correlation without importing infra.
    pub fn formatLogPrefix(self: *const Context, prefix_buffer: []u8, request_id_buffer: *[64]u8) []const u8 {
        const request_id = self.request_id.compactValue(request_id_buffer);
        const trace = self.compactTrace();
        if (self.tool_name) |tool_name| {
            return std.fmt.bufPrint(prefix_buffer, "trace={s} req={s} method={s} tool={s}", .{
                trace,
                request_id,
                self.mcp_method,
                tool_name,
            }) catch "trace=unavailable req=unavailable method=unavailable";
        }
        return std.fmt.bufPrint(prefix_buffer, "trace={s} req={s} method={s}", .{
            trace,
            request_id,
            self.mcp_method,
        }) catch "trace=unavailable req=unavailable method=unavailable";
    }
};

/// Monotonic process-local correlation generator.
pub const Generator = struct {
    next_sequence: u64 = 0,

    /// Returns a new correlation context. Ids are process-local and not persisted.
    pub fn next(self: *Generator, request_id: RequestId, mcp_method: []const u8, tool_name: ?[]const u8) Context {
        self.next_sequence +%= 1;
        if (self.next_sequence == 0) self.next_sequence = 1;
        return Context.init(self.next_sequence, request_id, mcp_method, tool_name);
    }
};

/// Frees JSON containers allocated by `metaValue`; string values are borrowed.
pub fn deinitMetaValue(allocator: std.mem.Allocator, value: std.json.Value) void {
    switch (value) {
        .array => |array| {
            var mutable = array;
            for (mutable.items) |item| deinitMetaValue(allocator, item);
            mutable.deinit();
        },
        .object => |object| {
            var mutable = object;
            var it = mutable.iterator();
            while (it.next()) |entry| deinitMetaValue(allocator, entry.value_ptr.*);
            mutable.deinit(allocator);
        },
        else => {},
    }
}

fn requestIdValue(allocator: std.mem.Allocator, request_id: *const RequestId) !std.json.Value {
    var obj: std.json.ObjectMap = .empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "type", .{ .string = request_id.typeName() });
    try obj.put(allocator, "value", if (request_id.valueString()) |value| .{ .string = value } else .null);
    return .{ .object = obj };
}

fn writeLowerHexFixed(out: []u8, value: u64) void {
    @memset(out, '0');
    var remaining = value;
    var index = out.len;
    while (index > 0 and remaining > 0) {
        index -= 1;
        const digit: u8 = @intCast(remaining & 0xf);
        out[index] = if (digit < 10) '0' + digit else 'a' + (digit - 10);
        remaining >>= 4;
    }
}

fn writeToolCallId(out: []u8, sequence: u64) void {
    const prefix = "zigars-tc-";
    @memcpy(out[0..prefix.len], prefix);
    var digits = out[prefix.len..];
    @memset(digits, '0');
    var remaining = sequence;
    var index = digits.len;
    while (index > 0 and remaining > 0) {
        index -= 1;
        digits[index] = '0' + @as(u8, @intCast(remaining % 10));
        remaining /= 10;
    }
}

fn expectLowerHex(value: []const u8) !void {
    for (value) |char| {
        try std.testing.expect((char >= '0' and char <= '9') or (char >= 'a' and char <= 'f'));
    }
}

test "correlation model preserves integer request ids" {
    const request_id = RequestId.from(.{ .integer = 42 });
    try std.testing.expectEqual(RequestId.Kind.integer, request_id.kind);
    try std.testing.expectEqual(@as(i64, 42), request_id.integer);
    try std.testing.expectEqualStrings("integer", request_id.typeName());
    try std.testing.expectEqualStrings("42", request_id.valueString().?);
}

test "correlation model preserves string request ids" {
    const request_id = RequestId.from(.{ .string = "abc-123" });
    try std.testing.expectEqual(RequestId.Kind.string, request_id.kind);
    try std.testing.expectEqualStrings("string", request_id.typeName());
    try std.testing.expectEqualStrings("abc-123", request_id.valueString().?);
}

test "correlation model represents notifications with absent ids" {
    const request_id = RequestId.absent();
    try std.testing.expectEqual(RequestId.Kind.absent, request_id.kind);
    try std.testing.expectEqualStrings("null", request_id.typeName());
    try std.testing.expect(request_id.valueString() == null);
}

test "correlation model generates tool call ids and MCP result metadata" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var generator: Generator = .{};
    var context = generator.next(RequestId.from(.{ .integer = 7 }), "tools/call", null);
    context.setToolName("zig_build");

    try std.testing.expectEqual(@as(usize, trace_id_len), context.traceId().len);
    try std.testing.expectEqual(@as(usize, span_id_len), context.spanId().len);
    try expectLowerHex(context.traceId());
    try expectLowerHex(context.spanId());
    try std.testing.expectEqualStrings("zigars-tc-000000000001", context.toolCallId());

    const meta = try context.metaValue(arena.allocator());
    const correlation = meta.object.get(meta_key).?.object;
    try std.testing.expectEqual(@as(i64, 1), correlation.get("schema_version").?.integer);
    try std.testing.expectEqualStrings("tools/call", correlation.get("mcp_method").?.string);
    try std.testing.expectEqualStrings("zig_build", correlation.get("tool_name").?.string);
    const id = correlation.get("mcp_request_id").?.object;
    try std.testing.expectEqualStrings("integer", id.get("type").?.string);
    try std.testing.expectEqualStrings("7", id.get("value").?.string);
}
