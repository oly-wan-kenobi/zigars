const std = @import("std");

/// Canonical evidence sources used in JSON findings payloads.
pub const Source = enum {
    heuristic,
    parser,
    zls,
    compiler,
    zlint,
    zwanzig,
    consensus,
    disagreement,
    profile,
};

/// Confidence enum used by this domain model.
pub const Confidence = enum {
    low,
    medium,
    high,
};

/// Returns the serialized token used in evidence objects.
pub fn sourceName(source: Source) []const u8 {
    return @tagName(source);
}

/// Returns the serialized confidence token used in evidence objects.
pub fn confidenceName(confidence: Confidence) []const u8 {
    return @tagName(confidence);
}

/// Duplicates bytes into allocator-owned JSON string storage.
pub fn ownedString(allocator: std.mem.Allocator, value: []const u8) !std.json.Value {
    return .{ .string = try allocator.dupe(u8, value) };
}

/// Frees JSON values produced by this module; object keys are borrowed field names.
pub fn deinitOwnedValue(allocator: std.mem.Allocator, value: std.json.Value) void {
    switch (value) {
        .string => |text| allocator.free(text),
        .array => |array| {
            var mutable = array;
            for (mutable.items) |item| deinitOwnedValue(allocator, item);
            mutable.deinit();
        },
        .object => |object| {
            var mutable = object;
            var it = mutable.iterator();
            while (it.next()) |entry| deinitOwnedValue(allocator, entry.value_ptr.*);
            mutable.deinit(allocator);
        },
        else => {},
    }
}

/// Inserts a value into an object, freeing the value if the object allocation fails.
fn putOwned(allocator: std.mem.Allocator, obj: *std.json.ObjectMap, key: []const u8, value: std.json.Value) !void {
    errdefer deinitOwnedValue(allocator, value);
    try obj.put(allocator, key, value);
}

/// Appends a value into an array, freeing the value if the append allocation fails.
fn appendOwned(allocator: std.mem.Allocator, array: *std.json.Array, value: std.json.Value) !void {
    errdefer deinitOwnedValue(allocator, value);
    try array.append(value);
}

/// Builds an owned JSON string array from borrowed string slices.
pub fn stringArrayValue(allocator: std.mem.Allocator, values: []const []const u8) !std.json.Value {
    var array = std.json.Array.init(allocator);
    var array_owned = true;
    defer if (array_owned) deinitOwnedValue(allocator, .{ .array = array });
    for (values) |value| try appendOwned(allocator, &array, try ownedString(allocator, value));
    array_owned = false;
    return .{ .array = array };
}

/// Encodes source enums as owned JSON string arrays.
pub fn sourceArrayValue(allocator: std.mem.Allocator, sources: []const Source) !std.json.Value {
    var array = std.json.Array.init(allocator);
    var array_owned = true;
    defer if (array_owned) deinitOwnedValue(allocator, .{ .array = array });
    for (sources) |source| try appendOwned(allocator, &array, try ownedString(allocator, sourceName(source)));
    array_owned = false;
    return .{ .array = array };
}

/// Normalizes location coordinates to 1-based minima for external tools.
pub fn locationValue(allocator: std.mem.Allocator, file: []const u8, line: usize, column: usize) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    var obj_owned = true;
    defer if (obj_owned) deinitOwnedValue(allocator, .{ .object = obj });
    try putOwned(allocator, &obj, "file", try ownedString(allocator, file));
    try putOwned(allocator, &obj, "line", .{ .integer = @intCast(@max(line, 1)) });
    try putOwned(allocator, &obj, "column", .{ .integer = @intCast(@max(column, 1)) });
    obj_owned = false;
    return .{ .object = obj };
}

/// Builds a JSON evidence object; allocation failures are returned.
pub fn evidenceValue(
    allocator: std.mem.Allocator,
    source: Source,
    confidence: Confidence,
    detail: []const u8,
    verify_with: []const []const u8,
) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    var obj_owned = true;
    defer if (obj_owned) deinitOwnedValue(allocator, .{ .object = obj });
    try putOwned(allocator, &obj, "source", try ownedString(allocator, sourceName(source)));
    try putOwned(allocator, &obj, "confidence", try ownedString(allocator, confidenceName(confidence)));
    try putOwned(allocator, &obj, "detail", try ownedString(allocator, detail));
    try putOwned(allocator, &obj, "verify_with", try stringArrayValue(allocator, verify_with));
    obj_owned = false;
    return .{ .object = obj };
}

/// Builds a JSON finding object with optional location evidence; allocation failures are returned.
pub fn findingValue(
    allocator: std.mem.Allocator,
    source: Source,
    rule: []const u8,
    severity: []const u8,
    file: []const u8,
    line: usize,
    column: usize,
    message: []const u8,
    confidence: Confidence,
) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    var obj_owned = true;
    defer if (obj_owned) deinitOwnedValue(allocator, .{ .object = obj });
    try putOwned(allocator, &obj, "source", try ownedString(allocator, sourceName(source)));
    try putOwned(allocator, &obj, "rule", try ownedString(allocator, rule));
    try putOwned(allocator, &obj, "severity", try ownedString(allocator, severity));
    try putOwned(allocator, &obj, "location", try locationValue(allocator, file, line, column));
    try putOwned(allocator, &obj, "message", try ownedString(allocator, message));
    try putOwned(allocator, &obj, "confidence", try ownedString(allocator, confidenceName(confidence)));
    try putOwned(allocator, &obj, "recommended_cross_check", try stringArrayValue(allocator, &.{ "zig_lint_compare", "zig build test" }));
    obj_owned = false;
    return .{ .object = obj };
}

/// Builds a severity-count summary from finding JSON objects; allocation failures are returned.
pub fn summaryValue(allocator: std.mem.Allocator, findings: std.json.Array) !std.json.Value {
    var errors: usize = 0;
    var warnings: usize = 0;
    var infos: usize = 0;
    // Tolerate partial/malformed entries so mixed-source evidence still summarizes.
    for (findings.items) |finding| {
        const obj = switch (finding) {
            .object => |o| o,
            else => continue,
        };
        const severity = switch (obj.get("severity") orelse .null) {
            .string => |s| s,
            else => continue,
        };
        if (std.ascii.eqlIgnoreCase(severity, "error")) {
            errors += 1;
        } else if (std.ascii.eqlIgnoreCase(severity, "warning") or std.ascii.eqlIgnoreCase(severity, "warn")) {
            warnings += 1;
        } else {
            infos += 1;
        }
    }
    var obj = std.json.ObjectMap.empty;
    var obj_owned = true;
    defer if (obj_owned) deinitOwnedValue(allocator, .{ .object = obj });
    try putOwned(allocator, &obj, "finding_count", .{ .integer = @intCast(findings.items.len) });
    try putOwned(allocator, &obj, "error_count", .{ .integer = @intCast(errors) });
    try putOwned(allocator, &obj, "warning_count", .{ .integer = @intCast(warnings) });
    try putOwned(allocator, &obj, "info_count", .{ .integer = @intCast(infos) });
    obj_owned = false;
    return .{ .object = obj };
}

/// Creates a deterministic fingerprint key for cross-tool finding de-duplication.
pub fn fingerprintValue(allocator: std.mem.Allocator, finding: std.json.Value) !std.json.Value {
    const obj = switch (finding) {
        .object => |o| o,
        else => return ownedString(allocator, "unknown"),
    };
    const source = stringField(obj, "source") orelse "unknown";
    const rule = stringField(obj, "rule") orelse "unknown";
    const message = stringField(obj, "message") orelse "";
    const location = switch (obj.get("location") orelse .null) {
        .object => |o| o,
        else => std.json.ObjectMap.empty,
    };
    const file = stringField(location, "file") orelse "unknown";
    const line = integerField(location, "line") orelse 0;
    return .{ .string = try std.fmt.allocPrint(allocator, "{s}:{s}:{s}:{d}:{s}", .{ source, rule, file, line, message }) };
}

/// Reads a string field from a JSON object without taking ownership.
pub fn stringField(obj: std.json.ObjectMap, field: []const u8) ?[]const u8 {
    return switch (obj.get(field) orelse .null) {
        .string => |s| s,
        else => null,
    };
}

/// Reads an integer field from a JSON object when it has integer shape.
pub fn integerField(obj: std.json.ObjectMap, field: []const u8) ?i64 {
    return switch (obj.get(field) orelse .null) {
        .integer => |i| i,
        .number_string => |s| std.fmt.parseInt(i64, s, 10) catch null,
        else => null,
    };
}
