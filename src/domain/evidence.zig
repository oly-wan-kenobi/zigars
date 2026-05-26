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

/// Builds an owned JSON string array from borrowed string slices.
pub fn stringArrayValue(allocator: std.mem.Allocator, values: []const []const u8) !std.json.Value {
    var array = std.json.Array.init(allocator);
    var array_owned = true;
    defer if (array_owned) array.deinit();
    for (values) |value| try array.append(try ownedString(allocator, value));
    array_owned = false;
    return .{ .array = array };
}

/// Encodes source enums as JSON string arrays without extra allocations.
pub fn sourceArrayValue(allocator: std.mem.Allocator, sources: []const Source) !std.json.Value {
    var array = std.json.Array.init(allocator);
    errdefer array.deinit();
    for (sources) |source| try array.append(.{ .string = sourceName(source) });
    return .{ .array = array };
}

/// Normalizes location coordinates to 1-based minima for external tools.
pub fn locationValue(allocator: std.mem.Allocator, file: []const u8, line: usize, column: usize) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    var obj_owned = true;
    defer if (obj_owned) obj.deinit(allocator);
    try obj.put(allocator, "file", try ownedString(allocator, file));
    try obj.put(allocator, "line", .{ .integer = @intCast(@max(line, 1)) });
    try obj.put(allocator, "column", .{ .integer = @intCast(@max(column, 1)) });
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
    defer if (obj_owned) obj.deinit(allocator);
    try obj.put(allocator, "source", .{ .string = sourceName(source) });
    try obj.put(allocator, "confidence", .{ .string = confidenceName(confidence) });
    try obj.put(allocator, "detail", try ownedString(allocator, detail));
    try obj.put(allocator, "verify_with", try stringArrayValue(allocator, verify_with));
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
    defer if (obj_owned) obj.deinit(allocator);
    try obj.put(allocator, "source", .{ .string = sourceName(source) });
    try obj.put(allocator, "rule", try ownedString(allocator, rule));
    try obj.put(allocator, "severity", try ownedString(allocator, severity));
    try obj.put(allocator, "location", try locationValue(allocator, file, line, column));
    try obj.put(allocator, "message", try ownedString(allocator, message));
    try obj.put(allocator, "confidence", .{ .string = confidenceName(confidence) });
    try obj.put(allocator, "recommended_cross_check", try stringArrayValue(allocator, &.{ "zig_lint_compare", "zig build test" }));
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
    defer if (obj_owned) obj.deinit(allocator);
    try obj.put(allocator, "finding_count", .{ .integer = @intCast(findings.items.len) });
    try obj.put(allocator, "error_count", .{ .integer = @intCast(errors) });
    try obj.put(allocator, "warning_count", .{ .integer = @intCast(warnings) });
    try obj.put(allocator, "info_count", .{ .integer = @intCast(infos) });
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
