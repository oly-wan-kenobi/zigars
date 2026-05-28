//! ZLS workflow helpers for document sync and workspace lifecycle operations.
const std = @import("std");

const app_context = @import("../../context.zig");
const ports = @import("../../ports.zig");

/// Diagnostic counts grouped by LSP severity.
const SeverityCounts = struct {
    total: usize = 0,
    errors: usize = 0,
    warnings: usize = 0,
    information: usize = 0,
    hints: usize = 0,
    unknown: usize = 0,

    /// Adds one LSP diagnostic severity to the aggregate.
    fn add(self: *SeverityCounts, severity: DiagnosticSeverity) void {
        self.total += 1;
        switch (severity) {
            .error_value => self.errors += 1,
            .warning => self.warnings += 1,
            .information => self.information += 1,
            .hint => self.hints += 1,
            .unknown => self.unknown += 1,
        }
    }

    /// Adds another grouped count into this aggregate.
    fn merge(self: *SeverityCounts, other: SeverityCounts) void {
        self.total += other.total;
        self.errors += other.errors;
        self.warnings += other.warnings;
        self.information += other.information;
        self.hints += other.hints;
        self.unknown += other.unknown;
    }
};

/// LSP diagnostic severity buckets.
const DiagnosticSeverity = enum {
    error_value,
    warning,
    information,
    hint,
    unknown,
};

/// Parsed diagnostic file summary and severity counters.
const ParsedDiagnosticFile = struct {
    value: std.json.Value,
    counts: SeverityCounts,
};

/// Serializes document sync fields into an allocator-owned JSON value; allocation failures propagate.
pub fn documentSyncValue(allocator: std.mem.Allocator, context: app_context.ZlsContext, tool_name: []const u8, file: []const u8, content: []const u8) !std.json.Value {
    const sync = try context.zls_gateway.sync(allocator, .{ .file = file, .content = content, .provenance = tool_name });
    defer sync.deinit(allocator);
    var obj = std.json.ObjectMap.empty;
    var obj_owned = true;
    defer if (obj_owned) obj.deinit(allocator);
    try obj.put(allocator, "uri", try ownedString(allocator, sync.uri));
    try obj.put(allocator, "version", .{ .integer = 0 });
    try obj.put(allocator, "open", .{ .bool = true });
    obj_owned = false;
    return .{ .object = obj };
}

/// Summarizes cached ZLS workspace diagnostics grouped by file and severity.
pub fn workspaceDiagnosticsValue(allocator: std.mem.Allocator, context: app_context.ZlsContext) !std.json.Value {
    const snapshot = try context.zls_gateway.diagnostics(allocator);
    defer snapshot.deinit(allocator);

    var files = std.json.Array.init(allocator);
    var totals = SeverityCounts{};
    var malformed_notifications: usize = 0;

    for (snapshot.messages) |message| {
        const parsed = parseDiagnosticFile(allocator, message) catch |err| switch (err) {
            error.MalformedDiagnostics => {
                malformed_notifications += 1;
                continue;
            },
            else => return err,
        };
        try files.append(parsed.value);
        totals.merge(parsed.counts);
    }

    var obj = std.json.ObjectMap.empty;
    var obj_owned = true;
    defer if (obj_owned) obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zig_diagnostics_workspace" });
    try obj.put(allocator, "files", .{ .array = files });
    try putSeverityCounts(allocator, &obj, totals);
    try obj.put(allocator, "malformed_notifications", .{ .integer = @intCast(malformed_notifications) });
    try obj.put(allocator, "cache", try diagnosticsCacheValue(allocator, snapshot.status));
    obj_owned = false;
    return .{ .object = obj };
}

/// Serializes document status fields into an allocator-owned JSON value; allocation failures propagate.
pub fn documentStatusValue(allocator: std.mem.Allocator, context: app_context.Context, file: []const u8) !std.json.Value {
    const workspace_store = try context.requireWorkspace();
    const resolved = try workspace_store.resolve(allocator, .{ .path = file, .provenance = "zls.document_status" });
    defer resolved.deinit(allocator);
    var obj = std.json.ObjectMap.empty;
    var obj_owned = true;
    defer if (obj_owned) obj.deinit(allocator);
    try obj.put(allocator, "file", try ownedString(allocator, file));
    try obj.put(allocator, "uri", try uriValue(allocator, resolved.path));
    try obj.put(allocator, "open", .{ .bool = context.zls_state.running });
    obj_owned = false;
    return .{ .object = obj };
}

/// Copies the provided string into allocator-owned storage.
fn ownedString(allocator: std.mem.Allocator, text: []const u8) !std.json.Value {
    return .{ .string = try allocator.dupe(u8, text) };
}

/// Parses one cached publishDiagnostics notification into a per-file summary.
fn parseDiagnosticFile(allocator: std.mem.Allocator, message: []const u8) !ParsedDiagnosticFile {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, message, .{}) catch return error.MalformedDiagnostics;
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |object| object,
        else => return error.MalformedDiagnostics,
    };
    const params = switch (root.get("params") orelse .null) {
        .object => |object| object,
        else => return error.MalformedDiagnostics,
    };
    const uri = switch (params.get("uri") orelse .null) {
        .string => |value| value,
        else => return error.MalformedDiagnostics,
    };
    const diagnostics = switch (params.get("diagnostics") orelse .null) {
        .array => |array| array,
        else => return error.MalformedDiagnostics,
    };

    var counts = SeverityCounts{};
    for (diagnostics.items) |diagnostic| counts.add(diagnosticSeverity(diagnostic));

    var obj = std.json.ObjectMap.empty;
    var obj_owned = true;
    defer if (obj_owned) obj.deinit(allocator);
    try obj.put(allocator, "uri", try ownedString(allocator, uri));
    try putSeverityCounts(allocator, &obj, counts);
    obj_owned = false;
    return .{ .value = .{ .object = obj }, .counts = counts };
}

/// Reads the LSP diagnostic severity field, falling back to an unknown bucket.
fn diagnosticSeverity(diagnostic: std.json.Value) DiagnosticSeverity {
    const obj = switch (diagnostic) {
        .object => |object| object,
        else => return .unknown,
    };
    const raw = switch (obj.get("severity") orelse .null) {
        .integer => |value| value,
        .number_string => |value| std.fmt.parseInt(i64, value, 10) catch return .unknown,
        else => return .unknown,
    };
    return switch (raw) {
        1 => .error_value,
        2 => .warning,
        3 => .information,
        4 => .hint,
        else => .unknown,
    };
}

/// Writes severity counter fields into an existing JSON object.
fn putSeverityCounts(allocator: std.mem.Allocator, obj: *std.json.ObjectMap, counts: SeverityCounts) !void {
    try obj.put(allocator, "total", .{ .integer = @intCast(counts.total) });
    try obj.put(allocator, "errors", .{ .integer = @intCast(counts.errors) });
    try obj.put(allocator, "warnings", .{ .integer = @intCast(counts.warnings) });
    try obj.put(allocator, "information", .{ .integer = @intCast(counts.information) });
    try obj.put(allocator, "hints", .{ .integer = @intCast(counts.hints) });
    try obj.put(allocator, "unknown", .{ .integer = @intCast(counts.unknown) });
}

/// Serializes diagnostics cache retention counters.
fn diagnosticsCacheValue(allocator: std.mem.Allocator, status: ports.ZlsDiagnosticsStatus) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    var obj_owned = true;
    defer if (obj_owned) obj.deinit(allocator);
    try obj.put(allocator, "files", .{ .integer = @intCast(status.files) });
    try obj.put(allocator, "retained_bytes", .{ .integer = @intCast(status.retained_bytes) });
    try obj.put(allocator, "max_bytes", .{ .integer = @intCast(status.max_bytes) });
    try obj.put(allocator, "evicted_files", .{ .integer = @intCast(status.evicted_files) });
    try obj.put(allocator, "evicted_bytes", .{ .integer = @intCast(status.evicted_bytes) });
    try obj.put(allocator, "dropped_oversized", .{ .integer = @intCast(status.dropped_oversized) });
    obj_owned = false;
    return .{ .object = obj };
}

/// Serializes uri fields into an allocator-owned JSON value; allocation failures propagate.
fn uriValue(allocator: std.mem.Allocator, path: []const u8) !std.json.Value {
    var out = std.ArrayList(u8).empty;
    try out.appendSlice(allocator, "file://");
    try out.appendSlice(allocator, path);
    return .{ .string = try out.toOwnedSlice(allocator) };
}
