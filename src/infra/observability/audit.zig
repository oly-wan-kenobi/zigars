//! Append-only JSONL audit writer for opt-in forensic operation.
const std = @import("std");
const Mutex = @import("../process/sync.zig").Mutex;
const ports = @import("../../app/ports.zig");

/// Audit payload retention mode.
pub const Mode = enum {
    metadata,
    redacted,
    full,

    /// Stable CLI/config text for this mode.
    pub fn text(self: Mode) []const u8 {
        return @tagName(self);
    }
};

/// Errors raised by audit configuration and writing.
pub const AuditError = error{
    InvalidAuditMode,
    InvalidAuditPath,
    AuditDisabled,
} || std.mem.Allocator.Error || std.Io.File.OpenError || std.Io.Dir.CreateDirPathError || std.Io.File.WritePositionalError || std.Io.File.LengthError;

/// Correlation snapshot supplied by the MCP adapter through the audit sink port.
pub const Correlation = ports.AuditCorrelation;

/// One audit event rendered as a single JSONL record; defined by the app audit
/// sink port so the MCP adapter constructs events without importing infra.
pub const Event = ports.AuditEvent;

/// Append-only audit log writer. The file path is resolved by bootstrap policy.
pub const Writer = struct {
    io: std.Io,
    file: ?std.Io.File = null,
    mode: Mode = .metadata,
    path: []const u8 = "",
    mutex: Mutex = .{},
    records_written: u64 = 0,

    /// Opens or creates the resolved audit file without truncating existing JSONL.
    pub fn init(allocator: std.mem.Allocator, io: std.Io, resolved_path: []const u8, mode: Mode) AuditError!Writer {
        if (resolved_path.len == 0) return error.InvalidAuditPath;
        const parent = std.fs.path.dirname(resolved_path) orelse return error.InvalidAuditPath;
        try std.Io.Dir.cwd().createDirPath(io, parent);
        const file = try std.Io.Dir.cwd().createFile(io, resolved_path, .{
            .read = true,
            .truncate = false,
        });
        errdefer file.close(io);
        const owned_path = try allocator.dupe(u8, resolved_path);
        return .{
            .io = io,
            .file = file,
            .mode = mode,
            .path = owned_path,
            .mutex = Mutex.init(io),
        };
    }

    /// Closes the audit file and releases the owned path.
    pub fn deinit(self: *Writer, allocator: std.mem.Allocator) void {
        if (self.file) |file| {
            file.close(self.io);
            self.file = null;
        }
        if (self.path.len > 0) {
            allocator.free(self.path);
            self.path = "";
        }
    }

    /// Appends one JSONL event.
    pub fn append(self: *Writer, allocator: std.mem.Allocator, event: Event) !void {
        const file = self.file orelse return error.AuditDisabled;
        var aw: std.Io.Writer.Allocating = .init(allocator);
        errdefer aw.deinit();
        try writeEvent(&aw.writer, allocator, self.io, self.mode, event);
        try aw.writer.writeByte('\n');
        const line = try aw.toOwnedSlice();
        defer allocator.free(line);

        self.mutex.lock();
        defer self.mutex.unlock();
        const offset = try file.length(self.io);
        try file.writePositionalAll(self.io, line, offset);
        self.records_written +|= 1;
    }

    /// Projects this writer as the app-side audit sink port. The adapter holds
    /// only the port and never imports this infra module.
    pub fn sink(self: *Writer) ports.AuditSink {
        return .{ .ptr = self, .vtable = &sink_vtable };
    }

    const sink_vtable: ports.AuditSink.VTable = .{ .append = sinkAppend };

    fn sinkAppend(ptr: *anyopaque, allocator: std.mem.Allocator, event: ports.AuditEvent) ports.AuditSink.AuditError!void {
        const self: *Writer = @ptrCast(@alignCast(ptr));
        self.append(allocator, event) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.AuditDisabled => error.AuditDisabled,
            else => error.WriteFailed,
        };
    }
};

/// Parses the CLI text for an audit log mode.
pub fn parseMode(value: []const u8) ?Mode {
    if (std.mem.eql(u8, value, "metadata")) return .metadata;
    if (std.mem.eql(u8, value, "redacted")) return .redacted;
    if (std.mem.eql(u8, value, "full")) return .full;
    return null;
}

fn writeEvent(writer: *std.Io.Writer, allocator: std.mem.Allocator, io: std.Io, mode: Mode, event: Event) !void {
    try writer.writeByte('{');
    var first = true;
    try fieldName(writer, &first, "schema_version");
    try writer.print("{d}", .{1});
    try fieldName(writer, &first, "ts_unix_ms");
    try writer.print("{d}", .{@divTrunc(std.Io.Clock.now(.real, io).nanoseconds, std.time.ns_per_ms)});
    try fieldName(writer, &first, "event");
    try jsonString(writer, event.event);
    try fieldName(writer, &first, "direction");
    try jsonString(writer, event.direction);
    try fieldName(writer, &first, "transport");
    try jsonString(writer, event.transport);
    try fieldName(writer, &first, "mcp_method");
    try optionalJsonString(writer, event.mcp_method);
    try fieldName(writer, &first, "mcp_request_id");
    try requestIdObject(writer, event.mcp_request_id_type, event.mcp_request_id_value);
    try fieldName(writer, &first, "correlation");
    if (event.correlation) |corr| try correlationObject(writer, corr) else try writer.writeAll("null");
    try fieldName(writer, &first, "tool_name");
    try optionalJsonString(writer, event.tool_name);
    try fieldName(writer, &first, "duration_ms");
    if (event.duration_ms) |duration| try writer.print("{d}", .{duration}) else try writer.writeAll("null");
    try fieldName(writer, &first, "ok");
    if (event.ok) |ok| try writer.writeAll(if (ok) "true" else "false") else try writer.writeAll("null");
    try fieldName(writer, &first, "is_error");
    try writer.writeAll(if (event.is_error) "true" else "false");
    var redaction_count: usize = 0;
    try fieldName(writer, &first, "payload");
    try payloadObject(writer, allocator, mode, event.payload orelse "", &redaction_count);
    try fieldName(writer, &first, "redactions");
    try redactionsArray(writer, mode, redaction_count);
    try writer.writeByte('}');
}

fn payloadObject(writer: *std.Io.Writer, allocator: std.mem.Allocator, mode: Mode, payload: []const u8, redaction_count: *usize) !void {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(payload, &digest, .{});
    const digest_hex = std.fmt.bytesToHex(digest, .lower);

    try writer.writeByte('{');
    var first = true;
    try fieldName(writer, &first, "mode");
    try jsonString(writer, mode.text());
    try fieldName(writer, &first, "sha256");
    try jsonString(writer, &digest_hex);
    try fieldName(writer, &first, "size");
    try writer.print("{d}", .{payload.len});
    switch (mode) {
        .metadata => {},
        .full => {
            try fieldName(writer, &first, "raw_json");
            try jsonString(writer, payload);
        },
        .redacted => {
            try fieldName(writer, &first, "redacted_json");
            var parsed = std.json.parseFromSlice(std.json.Value, allocator, payload, .{}) catch {
                try writer.writeAll("null");
                redaction_count.* += 1;
                try fieldName(writer, &first, "redacted_error");
                try jsonString(writer, "invalid_json_payload_not_recorded");
                try writer.writeByte('}');
                return;
            };
            defer parsed.deinit();
            try writeRedactedValue(writer, parsed.value, redaction_count);
        },
    }
    try writer.writeByte('}');
}

fn correlationObject(writer: *std.Io.Writer, corr: Correlation) !void {
    try writer.writeByte('{');
    var first = true;
    try fieldName(writer, &first, "schema_version");
    try writer.print("{d}", .{corr.schema_version});
    try fieldName(writer, &first, "mcp_request_id");
    try requestIdObject(writer, corr.mcp_request_id_type, corr.mcp_request_id_value);
    try fieldName(writer, &first, "mcp_method");
    try jsonString(writer, corr.mcp_method);
    try fieldName(writer, &first, "tool_name");
    try optionalJsonString(writer, corr.tool_name);
    try fieldName(writer, &first, "trace_id");
    try jsonString(writer, corr.trace_id);
    try fieldName(writer, &first, "span_id");
    try jsonString(writer, corr.span_id);
    try fieldName(writer, &first, "parent_span_id");
    try optionalJsonString(writer, corr.parent_span_id);
    try fieldName(writer, &first, "tool_call_id");
    try jsonString(writer, corr.tool_call_id);
    try writer.writeByte('}');
}

fn requestIdObject(writer: *std.Io.Writer, kind: []const u8, value: ?[]const u8) !void {
    try writer.writeByte('{');
    var first = true;
    try fieldName(writer, &first, "type");
    try jsonString(writer, kind);
    try fieldName(writer, &first, "value");
    try optionalJsonString(writer, value);
    try writer.writeByte('}');
}

fn redactionsArray(writer: *std.Io.Writer, mode: Mode, redaction_count: usize) !void {
    try writer.writeByte('[');
    if (mode == .metadata) {
        try jsonString(writer, "payload_omitted_metadata_only");
    } else if (mode == .redacted and redaction_count > 0) {
        try jsonString(writer, "secret_like_json_fields");
    }
    try writer.writeByte(']');
}

fn writeRedactedValue(writer: *std.Io.Writer, value: std.json.Value, redaction_count: *usize) !void {
    switch (value) {
        .object => |object| {
            try writer.writeByte('{');
            var first = true;
            var it = object.iterator();
            while (it.next()) |entry| {
                try fieldName(writer, &first, entry.key_ptr.*);
                if (isSensitiveKey(entry.key_ptr.*)) {
                    redaction_count.* += 1;
                    try jsonString(writer, "[REDACTED]");
                } else {
                    try writeRedactedValue(writer, entry.value_ptr.*, redaction_count);
                }
            }
            try writer.writeByte('}');
        },
        .array => |array| {
            try writer.writeByte('[');
            for (array.items, 0..) |item, index| {
                if (index > 0) try writer.writeByte(',');
                try writeRedactedValue(writer, item, redaction_count);
            }
            try writer.writeByte(']');
        },
        else => try std.json.Stringify.value(value, .{ .whitespace = .minified }, writer),
    }
}

fn fieldName(writer: *std.Io.Writer, first: *bool, name: []const u8) !void {
    if (!first.*) try writer.writeByte(',');
    first.* = false;
    try jsonString(writer, name);
    try writer.writeByte(':');
}

fn optionalJsonString(writer: *std.Io.Writer, value: ?[]const u8) !void {
    if (value) |text| try jsonString(writer, text) else try writer.writeAll("null");
}

fn jsonString(writer: *std.Io.Writer, value: []const u8) !void {
    try std.json.Stringify.value(value, .{ .whitespace = .minified }, writer);
}

fn isSensitiveKey(key: []const u8) bool {
    const sensitive = [_][]const u8{
        "authorization",
        "proxy-authorization",
        "cookie",
        "set-cookie",
        "password",
        "passwd",
        "secret",
        "token",
        "access_token",
        "refresh_token",
        "api_key",
        "apikey",
        "api-key",
        "x-api-key",
    };
    for (sensitive) |needle| {
        if (std.ascii.eqlIgnoreCase(key, needle)) return true;
    }
    return containsIgnoreCase(key, "secret") or
        containsIgnoreCase(key, "token") or
        containsIgnoreCase(key, "password") or
        containsIgnoreCase(key, "api_key") or
        containsIgnoreCase(key, "apikey");
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (haystack.len < needle.len) return false;
    var index: usize = 0;
    while (index + needle.len <= haystack.len) : (index += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[index .. index + needle.len], needle)) return true;
    }
    return false;
}

test "audit mode parser accepts only supported values" {
    try std.testing.expectEqual(Mode.metadata, parseMode("metadata").?);
    try std.testing.expectEqual(Mode.redacted, parseMode("redacted").?);
    try std.testing.expectEqual(Mode.full, parseMode("full").?);
    try std.testing.expect(parseMode("raw") == null);
}

test "audit JSONL modes omit redact or retain payloads intentionally" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const payload =
        \\{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"Authorization":"Bearer token","safe":"ok"}}
    ;

    inline for (.{ Mode.metadata, Mode.redacted, Mode.full }) |mode| {
        var aw: std.Io.Writer.Allocating = .init(allocator);
        try writeEvent(&aw.writer, allocator, std.testing.io, mode, .{
            .event = "request",
            .direction = "inbound",
            .transport = "stdio",
            .mcp_method = "tools/call",
            .mcp_request_id_type = "integer",
            .mcp_request_id_value = "1",
            .payload = payload,
        });
        const line = try aw.toOwnedSlice();
        try std.testing.expect(std.mem.indexOf(u8, line, "\"sha256\"") != null);
        if (mode == .metadata) {
            try std.testing.expect(std.mem.indexOf(u8, line, "Bearer token") == null);
            try std.testing.expect(std.mem.indexOf(u8, line, "payload_omitted_metadata_only") != null);
        } else if (mode == .redacted) {
            try std.testing.expect(std.mem.indexOf(u8, line, "Bearer token") == null);
            try std.testing.expect(std.mem.indexOf(u8, line, "[REDACTED]") != null);
        } else {
            try std.testing.expect(std.mem.indexOf(u8, line, "Bearer token") != null);
        }
    }
}
