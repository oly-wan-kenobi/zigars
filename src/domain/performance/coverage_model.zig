const std = @import("std");

/// Normalized coverage totals for one source file.
pub const CoverageFile = struct {
    path: []const u8,
    total: usize,
    covered: usize,
};

/// Owned coverage report parsed from LCOV or JSON evidence.
pub const CoverageSet = struct {
    files: std.ArrayList(CoverageFile) = .empty,
    total: usize = 0,
    covered: usize = 0,
    source_kind: []const u8 = "content",

    /// Frees owned file paths and backing storage.
    pub fn deinit(self: *CoverageSet, allocator: std.mem.Allocator) void {
        for (self.files.items) |file| allocator.free(file.path);
        self.files.deinit(allocator);
    }
};

/// Aggregate coverage for changed files that exist in a report.
pub const ChangedCoverage = struct {
    total: usize = 0,
    covered: usize = 0,
    count: usize = 0,
};

/// Parses coverage evidence, using format hints and content sniffing.
pub fn parse(allocator: std.mem.Allocator, bytes: []const u8, source_kind: []const u8, format: []const u8) !CoverageSet {
    const trimmed = std.mem.trim(u8, bytes, " \t\r\n");
    if (trimmed.len == 0) return error.InvalidCoverageEvidence;
    if (std.mem.eql(u8, format, "lcov") or std.mem.startsWith(u8, trimmed, "TN:") or std.mem.indexOf(u8, trimmed, "\nSF:") != null or std.mem.startsWith(u8, trimmed, "SF:")) {
        return parseLcov(allocator, trimmed, source_kind);
    }
    if (trimmed[0] == '{' or trimmed[0] == '[') return parseJson(allocator, trimmed, source_kind);
    return parseLcov(allocator, trimmed, source_kind);
}

/// Merges two reports, coalescing files by exact path.
pub fn merge(allocator: std.mem.Allocator, left: CoverageSet, right: CoverageSet) !CoverageSet {
    var merged = CoverageSet{ .source_kind = "merged" };
    var merged_owned = true;
    defer if (merged_owned) merged.deinit(allocator);
    for (left.files.items) |file| try appendFile(allocator, &merged, file.path, file.total, file.covered);
    for (right.files.items) |file| try appendFile(allocator, &merged, file.path, file.total, file.covered);
    merged_owned = false;
    return merged;
}

/// Converts covered/total counts to basis points.
pub fn rateBp(covered: usize, total: usize) usize {
    if (total == 0) return 0;
    return @intCast(@divTrunc(covered * 10000, total));
}

/// Totals coverage for the supplied changed-file paths only.
pub fn changedCoverage(set: CoverageSet, changed_files: []const []const u8) ChangedCoverage {
    var out: ChangedCoverage = .{};
    for (changed_files) |path| {
        if (findFile(set, path)) |file| {
            out.total += file.total;
            out.covered += file.covered;
            out.count += 1;
        }
    }
    return out;
}

/// Finds a normalized file entry by exact path without allocating.
pub fn findFile(set: CoverageSet, path: []const u8) ?CoverageFile {
    for (set.files.items) |file| if (std.mem.eql(u8, file.path, path)) return file;
    return null;
}

/// Parses LCOV text into an owned coverage set; allocation failures are returned.
fn parseLcov(allocator: std.mem.Allocator, bytes: []const u8, source_kind: []const u8) !CoverageSet {
    var set = CoverageSet{ .source_kind = source_kind };
    var set_owned = true;
    defer if (set_owned) set.deinit(allocator);
    var current_path: ?[]const u8 = null;
    var total: usize = 0;
    var covered: usize = 0;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (std.mem.startsWith(u8, line, "SF:")) {
            if (current_path) |path| try appendFile(allocator, &set, path, total, covered);
            current_path = line["SF:".len..];
            total = 0;
            covered = 0;
        } else if (std.mem.startsWith(u8, line, "DA:")) {
            total += 1;
            const payload = line["DA:".len..];
            if (std.mem.indexOfScalar(u8, payload, ',')) |comma| {
                const hits_text = std.mem.trim(u8, payload[comma + 1 ..], " \t");
                const hits = std.fmt.parseInt(i64, hits_text, 10) catch 0;
                if (hits > 0) covered += 1;
            }
        } else if (std.mem.eql(u8, line, "end_of_record")) {
            if (current_path) |path| try appendFile(allocator, &set, path, total, covered);
            current_path = null;
            total = 0;
            covered = 0;
        }
    }
    if (current_path) |path| try appendFile(allocator, &set, path, total, covered);
    if (set.files.items.len == 0) return error.InvalidCoverageEvidence;
    set_owned = false;
    return set;
}

/// Parses JSON evidence into owned model data; invalid shape and allocation failures are returned.
fn parseJson(allocator: std.mem.Allocator, bytes: []const u8, source_kind: []const u8) !CoverageSet {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer parsed.deinit();
    const root = if (parsed.value == .object and parsed.value.object.get("files") != null) parsed.value else coverageRoot(parsed.value);
    var set = CoverageSet{ .source_kind = source_kind };
    var set_owned = true;
    defer if (set_owned) set.deinit(allocator);
    switch (root) {
        .object => |obj| {
            if (obj.get("files")) |files| try parseFilesArray(allocator, &set, files);
            if (set.files.items.len == 0) {
                if (obj.get("coverage")) |coverage| {
                    const nested = coverageRoot(coverage);
                    if (nested == .object) if (nested.object.get("files")) |files| try parseFilesArray(allocator, &set, files);
                }
            }
        },
        .array => try parseFilesArray(allocator, &set, root),
        else => return error.InvalidCoverageEvidence,
    }
    if (set.files.items.len == 0) return error.InvalidCoverageEvidence;
    set_owned = false;
    return set;
}

/// Selects the coverage array root from known JSON evidence shapes.
fn coverageRoot(value: std.json.Value) std.json.Value {
    if (value == .object) {
        if (value.object.get("coverage")) |coverage| return coverage;
        if (value.object.get("baseline")) |baseline| return coverageRoot(baseline);
    }
    return value;
}

/// Appends coverage file entries from a JSON files array; allocation failures are returned.
fn parseFilesArray(allocator: std.mem.Allocator, set: *CoverageSet, value: std.json.Value) !void {
    if (value != .array) return error.InvalidCoverageEvidence;
    for (value.array.items) |item| {
        if (item != .object) continue;
        const path = stringField(item.object, "path") orelse stringField(item.object, "file") orelse continue;
        const total = intField(item.object, "total_lines") orelse intField(item.object, "total") orelse 0;
        const covered = intField(item.object, "covered_lines") orelse intField(item.object, "covered") orelse 0;
        try appendFile(allocator, set, path, @intCast(@max(0, total)), @intCast(@max(0, covered)));
    }
}

/// Appends an owned coverage file entry, merging duplicate paths in place.
fn appendFile(allocator: std.mem.Allocator, set: *CoverageSet, path: []const u8, total: usize, covered: usize) !void {
    if (path.len == 0) return;
    for (set.files.items) |*existing| {
        if (std.mem.eql(u8, existing.path, path)) {
            existing.total += total;
            existing.covered += @min(covered, total);
            set.total += total;
            set.covered += @min(covered, total);
            return;
        }
    }
    try set.files.append(allocator, .{
        .path = try allocator.dupe(u8, path),
        .total = total,
        .covered = @min(covered, total),
    });
    set.total += total;
    set.covered += @min(covered, total);
}

/// Reads an integer field from a JSON object when it has integer shape.
fn intField(obj: std.json.ObjectMap, name: []const u8) ?i64 {
    const value = obj.get(name) orelse return null;
    return switch (value) {
        .integer => |i| i,
        .float => |f| @intFromFloat(f),
        .number_string => |s| std.fmt.parseInt(i64, s, 10) catch null,
        else => null,
    };
}

/// Reads a string field from a JSON object without taking ownership.
fn stringField(obj: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const value = obj.get(name) orelse return null;
    return switch (value) {
        .string => |s| s,
        else => null,
    };
}

test "coverage model integer fields accept float and number string values" {
    var obj = std.json.ObjectMap.empty;
    defer obj.deinit(std.testing.allocator);
    try obj.put(std.testing.allocator, "float", .{ .float = 7.9 });
    try obj.put(std.testing.allocator, "number_string", .{ .number_string = "42" });
    try obj.put(std.testing.allocator, "bad", .{ .string = "nope" });
    try std.testing.expectEqual(@as(i64, 7), intField(obj, "float").?);
    try std.testing.expectEqual(@as(i64, 42), intField(obj, "number_string").?);
    try std.testing.expect(intField(obj, "bad") == null);
}
