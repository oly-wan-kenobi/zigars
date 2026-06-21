//! Generic JSON, string, and command helpers shared across the
//! project-intelligence use cases. Extracted from project_intelligence.zig so
//! its feature clusters can share these utilities without circular imports.
//! Pure leaf helpers: they depend only on std and the effect-free `ports`
//! value types, never on app context, workflows, or other use-case modules.
const std = @import("std");
const ports = @import("../../../ports.zig");

/// Serializes argv owned fields into an allocator-owned JSON value; allocation failures propagate.
pub fn argvOwnedValue(allocator: std.mem.Allocator, argv: []const []const u8) !std.json.Value {
    var array = std.json.Array.init(allocator);
    for (argv) |arg| try array.append(try ownedString(allocator, arg));
    return .{ .array = array };
}

/// Serializes command term fields into an allocator-owned JSON value; allocation failures propagate.
pub fn commandTermValue(allocator: std.mem.Allocator, term: ports.CommandTerm) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = term.name() });
    if (term.exitCode()) |code| try obj.put(allocator, "code", .{ .integer = code });
    return .{ .object = obj };
}

/// Carries safe text data across use case and port boundaries.
pub const SafeText = struct {
    text: []const u8,
    invalid_utf8: bool,
    encoding: []const u8,
    byte_count: usize,
};

/// Copies bounded text into allocator-owned storage for result payloads.
pub fn safeTextAlloc(allocator: std.mem.Allocator, bytes: []const u8) !SafeText {
    // Keep this logic centralized so callers observe one consistent behavior path.
    if (std.unicode.utf8ValidateSlice(bytes)) {
        return .{
            .text = try allocator.dupe(u8, bytes),
            .invalid_utf8 = false,
            .encoding = "utf-8",
            .byte_count = bytes.len,
        };
    }
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var index: usize = 0;
    while (index < bytes.len) {
        const len = std.unicode.utf8ByteSequenceLength(bytes[index]) catch {
            try out.appendSlice(allocator, &std.unicode.replacement_character_utf8);
            index += 1;
            continue;
        };
        if (index + len <= bytes.len and std.unicode.utf8ValidateSlice(bytes[index .. index + len])) {
            try out.appendSlice(allocator, bytes[index .. index + len]);
            index += len;
        } else {
            try out.appendSlice(allocator, &std.unicode.replacement_character_utf8);
            index += 1;
        }
    }
    return .{
        .text = try out.toOwnedSlice(allocator),
        .invalid_utf8 = true,
        .encoding = "utf-8-lossy",
        .byte_count = bytes.len,
    };
}

/// Implements put stream fields workflow logic using caller-owned inputs.
pub fn putStreamFields(allocator: std.mem.Allocator, obj: *std.json.ObjectMap, name: []const u8, safe: SafeText) !void {
    try obj.put(allocator, name, .{ .string = safe.text });
    try obj.put(allocator, try std.fmt.allocPrint(allocator, "{s}_invalid_utf8", .{name}), .{ .bool = safe.invalid_utf8 });
    try obj.put(allocator, try std.fmt.allocPrint(allocator, "{s}_encoding", .{name}), .{ .string = safe.encoding });
    try obj.put(allocator, try std.fmt.allocPrint(allocator, "{s}_byte_count", .{name}), .{ .integer = @intCast(safe.byte_count) });
}

/// Classifies command failures into stable result categories.
pub fn commandErrorKind(err: anyerror) []const u8 {
    // Keep this logic centralized so callers observe one consistent behavior path.
    return switch (err) {
        error.Timeout, error.RequestTimeout => "timeout",
        error.StreamTooLong, error.OutputLimitExceeded => "output_limit",
        error.FileNotFound, error.NotFound => "executable_not_found",
        error.AccessDenied, error.PermissionDenied => "permission",
        error.EndOfStream, error.BrokenPipe, error.Unavailable, error.NoResponse => "unavailable",
        error.PathOutsideWorkspace, error.EmptyPath => "workspace_path",
        else => "execution",
    };
}

/// Serializes backend error fields into an allocator-owned JSON value; allocation failures propagate.
pub fn backendErrorValue(allocator: std.mem.Allocator, backend_name: []const u8, operation: []const u8, err: anyerror, resolution: []const u8) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "backend_error" });
    try obj.put(allocator, "ok", .{ .bool = false });
    try obj.put(allocator, "backend", .{ .string = backend_name });
    try obj.put(allocator, "operation", .{ .string = operation });
    try obj.put(allocator, "error", .{ .string = @errorName(err) });
    try obj.put(allocator, "error_kind", .{ .string = commandErrorKind(err) });
    try obj.put(allocator, "resolution", .{ .string = resolution });
    return .{ .object = obj };
}

/// Reports whether output limit error matches the caller-provided data.
pub fn isOutputLimitError(err: anyerror) bool {
    return err == error.StreamTooLong or err == error.OutputLimitExceeded;
}

/// Reports whether timeout error matches the caller-provided data.
pub fn isTimeoutError(err: anyerror) bool {
    return err == error.Timeout or err == error.RequestTimeout;
}

/// Reports whether `value` is present in `list` (exact string equality).
pub fn stringListContains(list: []const []const u8, value: []const u8) bool {
    for (list) |item| {
        if (std.mem.eql(u8, item, value)) return true;
    }
    return false;
}

/// Releases string list allocations; callers must not reuse freed items.
pub fn freeStringList(allocator: std.mem.Allocator, list: []const []const u8) void {
    for (list) |item| allocator.free(item);
}

/// Extracts json array len data from JSON input without taking ownership of borrowed values.
pub fn jsonArrayLen(value: std.json.Value) usize {
    return switch (value) {
        .array => |a| a.items.len,
        else => 0,
    };
}

/// Extracts bool field data from JSON input without taking ownership of borrowed values.
pub fn boolField(obj: std.json.ObjectMap, field: []const u8) ?bool {
    return switch (obj.get(field) orelse .null) {
        .bool => |b| b,
        else => null,
    };
}

/// Extracts string field data from JSON input without taking ownership of borrowed values.
pub fn stringField(obj: std.json.ObjectMap, field: []const u8) ?[]const u8 {
    return switch (obj.get(field) orelse .null) {
        .string => |s| s,
        else => null,
    };
}

/// Extracts integer field data from JSON input without taking ownership of borrowed values.
pub fn integerField(obj: std.json.ObjectMap, field: []const u8) ?i64 {
    return switch (obj.get(field) orelse .null) {
        .integer => |i| i,
        .number_string => |s| std.fmt.parseInt(i64, s, 10) catch null,
        else => null,
    };
}

/// Copies the provided string into allocator-owned storage.
pub fn ownedString(allocator: std.mem.Allocator, value: []const u8) !std.json.Value {
    return .{ .string = try allocator.dupe(u8, value) };
}

/// Serializes string array fields into an allocator-owned JSON value; allocation failures propagate.
pub fn stringArrayValue(allocator: std.mem.Allocator, values: []const []const u8) !std.json.Value {
    var array = std.json.Array.init(allocator);
    for (values) |value| try array.append(try ownedString(allocator, value));
    return .{ .array = array };
}

/// Serializes clone fields into an allocator-owned JSON value; allocation failures propagate.
pub fn cloneValue(allocator: std.mem.Allocator, value: std.json.Value) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
    return switch (value) {
        .null => .null,
        .bool => |b| .{ .bool = b },
        .integer => |i| .{ .integer = i },
        .float => |f| .{ .float = f },
        .number_string => |s| .{ .number_string = try allocator.dupe(u8, s) },
        .string => |s| .{ .string = try allocator.dupe(u8, s) },
        .array => |array| blk: {
            var cloned = std.json.Array.init(allocator);
            for (array.items) |item| try cloned.append(try cloneValue(allocator, item));
            break :blk .{ .array = cloned };
        },
        .object => |object| blk: {
            var cloned = std.json.ObjectMap.empty;
            var it = object.iterator();
            while (it.next()) |entry| {
                const key = try allocator.dupe(u8, entry.key_ptr.*);
                try cloned.put(allocator, key, try cloneValue(allocator, entry.value_ptr.*));
            }
            break :blk .{ .object = cloned };
        },
    };
}

/// Serializes serialize fields into an allocator-owned JSON value; allocation failures propagate.
pub fn serializeValue(allocator: std.mem.Allocator, value: std.json.Value) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try std.json.Stringify.value(value, .{}, &out.writer);
    return out.toOwnedSlice();
}

/// Extracts json line for record data from JSON input without taking ownership of borrowed values.
pub fn jsonLineForRecord(allocator: std.mem.Allocator, value: std.json.Value) ![]const u8 {
    return serializeValue(allocator, value);
}

/// Computes a lowercase SHA-256 hex digest in allocator-owned storage.
pub fn sha256Hex(allocator: std.mem.Allocator, data: []const u8) ![]const u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    return allocator.dupe(u8, &hex);
}

/// Reports whether `contents` references `target` by basename or full path.
pub fn importsTarget(contents: []const u8, target: []const u8) bool {
    const base = std.fs.path.basename(target);
    return std.mem.indexOf(u8, contents, base) != null or std.mem.indexOf(u8, contents, target) != null;
}

/// Reports whether file stem matches the caller-provided data.
pub fn referencesFileStem(contents: []const u8, target: []const u8) bool {
    const base = std.fs.path.basename(target);
    const dot = std.mem.lastIndexOfScalar(u8, base, '.') orelse base.len;
    if (dot == 0) return false;
    return std.mem.indexOf(u8, contents, base[0..dot]) != null;
}

/// Reports whether like test file matches the caller-provided data.
pub fn looksLikeTestFile(path: []const u8) bool {
    return std.mem.indexOf(u8, path, "test") != null or std.mem.endsWith(u8, path, "_test.zig");
}
