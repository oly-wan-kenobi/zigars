const std = @import("std");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const percent_scale: u32 = 100;

pub const CoverageScope = enum { src, tools, ignored };

pub const CoverageStats = struct {
    covered_lines: u64 = 0,
    total_lines: u64 = 0,
    src_covered_lines: u64 = 0,
    src_total_lines: u64 = 0,
    tools_covered_lines: u64 = 0,
    tools_total_lines: u64 = 0,
    files: []CoverageFileStats = &.{},
    missing_files: []const []const u8 = &.{},

    pub fn deinit(self: *CoverageStats, allocator: Allocator) void {
        for (self.files) |*file| file.deinit(allocator);
        if (self.files.len > 0) allocator.free(self.files);
        for (self.missing_files) |path| allocator.free(path);
        if (self.missing_files.len > 0) allocator.free(self.missing_files);
    }

    pub fn lineRateBasisPoints(self: CoverageStats) ?u32 {
        return rateBasisPoints(self.covered_lines, self.total_lines);
    }

    pub fn srcLineRateBasisPoints(self: CoverageStats) ?u32 {
        return rateBasisPoints(self.src_covered_lines, self.src_total_lines);
    }

    pub fn toolsLineRateBasisPoints(self: CoverageStats) ?u32 {
        return rateBasisPoints(self.tools_covered_lines, self.tools_total_lines);
    }

    pub fn uncoveredLineCount(self: CoverageStats) u64 {
        var count: u64 = 0;
        for (self.files) |file| count += file.uncovered_lines.len;
        return count;
    }

    pub fn missingFileCount(self: CoverageStats) u64 {
        return self.missing_files.len;
    }
};

pub const CoverageFileStats = struct {
    path: []const u8,
    scope: CoverageScope,
    covered_lines: u64 = 0,
    total_lines: u64 = 0,
    uncovered_lines: []u32 = &.{},

    pub fn deinit(self: *CoverageFileStats, allocator: Allocator) void {
        allocator.free(self.path);
        if (self.uncovered_lines.len > 0) allocator.free(self.uncovered_lines);
    }

    pub fn lineRateBasisPoints(self: CoverageFileStats) ?u32 {
        return rateBasisPoints(self.covered_lines, self.total_lines);
    }
};

pub fn parseCobertura(allocator: Allocator, xml: []const u8) !CoverageStats {
    var stats: CoverageStats = .{};
    var files: std.ArrayList(CoverageFileStats) = .empty;
    var files_owned = true;
    defer if (files_owned) {
        for (files.items) |*file| file.deinit(allocator);
        files.deinit(allocator);
    };
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, xml, pos, "<class")) |class_start| {
        const tag_end = std.mem.indexOfScalarPos(u8, xml, class_start, '>') orelse return error.InvalidCoverageReport;
        const tag = xml[class_start .. tag_end + 1];
        const filename = attributeValue(tag, "filename") orelse {
            pos = tag_end + 1;
            continue;
        };
        const body_start = tag_end + 1;
        const class_end = std.mem.indexOfPos(u8, xml, body_start, "</class>") orelse body_start;
        const body = xml[body_start..class_end];
        const normalized = try normalizeCoveragePath(allocator, filename);
        defer if (normalized) |path| allocator.free(path);
        const path = normalized orelse {
            pos = class_end + "</class>".len;
            continue;
        };
        const scope = coverageScope(path);
        std.debug.assert(scope != .ignored);

        var file: CoverageFileStats = .{
            .path = try allocator.dupe(u8, path),
            .scope = scope,
        };
        var file_owned = true;
        defer if (file_owned) file.deinit(allocator);
        var uncovered: std.ArrayList(u32) = .empty;
        var uncovered_owned = true;
        defer if (uncovered_owned) uncovered.deinit(allocator);
        var line_pos: usize = 0;
        while (std.mem.indexOfPos(u8, body, line_pos, "<line")) |line_start| {
            const line_tag_end = std.mem.indexOfScalarPos(u8, body, line_start, '>') orelse return error.InvalidCoverageReport;
            const line_tag = body[line_start .. line_tag_end + 1];
            const hits_text = attributeValue(line_tag, "hits") orelse {
                line_pos = line_tag_end + 1;
                continue;
            };
            const number_text = attributeValue(line_tag, "number") orelse {
                line_pos = line_tag_end + 1;
                continue;
            };
            const covered = (std.fmt.parseInt(u64, hits_text, 10) catch 0) > 0;
            stats.total_lines += 1;
            if (covered) stats.covered_lines += 1;
            file.total_lines += 1;
            if (covered) {
                file.covered_lines += 1;
            } else {
                try uncovered.append(allocator, std.fmt.parseInt(u32, number_text, 10) catch 0);
            }
            switch (scope) {
                .src => {
                    stats.src_total_lines += 1;
                    if (covered) stats.src_covered_lines += 1;
                },
                .tools => {
                    stats.tools_total_lines += 1;
                    if (covered) stats.tools_covered_lines += 1;
                },
                .ignored => {},
            }
            line_pos = line_tag_end + 1;
        }
        file.uncovered_lines = try uncovered.toOwnedSlice(allocator);
        uncovered_owned = false;
        try files.append(allocator, file);
        file_owned = false;
        pos = if (class_end == body_start) body_start else class_end + "</class>".len;
    }
    stats.files = try files.toOwnedSlice(allocator);
    files_owned = false;
    return stats;
}

pub fn addMissingTrackedFiles(allocator: Allocator, io: Io, stats: *CoverageStats) !void {
    const tracked = try trackedCoverageFiles(allocator, io);
    defer {
        for (tracked) |path| allocator.free(path);
        allocator.free(tracked);
    }

    var missing: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (missing.items) |path| allocator.free(path);
        missing.deinit(allocator);
    }
    for (tracked) |path| {
        if (coverageFileIndex(stats.files, path) != null) continue;
        try missing.append(allocator, try allocator.dupe(u8, path));
    }
    stats.missing_files = try missing.toOwnedSlice(allocator);
}

fn trackedCoverageFiles(allocator: Allocator, io: Io) ![]const []const u8 {
    const result = try std.process.run(allocator, io, .{ .argv = &.{ "git", "ls-files", "src", "tools" } });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (!termOk(result.term)) return error.GitFailed;

    var files: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (files.items) |path| allocator.free(path);
        files.deinit(allocator);
    }
    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    while (lines.next()) |line| {
        const path = std.mem.trim(u8, line, " \t\r\n");
        if (!isTrackedCoverageFile(path)) continue;
        try files.append(allocator, try allocator.dupe(u8, path));
    }
    return try files.toOwnedSlice(allocator);
}

fn coverageFileIndex(files: []const CoverageFileStats, path: []const u8) ?usize {
    for (files, 0..) |file, i| {
        if (std.mem.eql(u8, file.path, path)) return i;
    }
    return null;
}

fn normalizeCoveragePath(allocator: Allocator, filename: []const u8) !?[]u8 {
    var normalized = try allocator.dupe(u8, filename);
    var normalized_owned = true;
    defer if (normalized_owned) allocator.free(normalized);
    for (normalized) |*byte| {
        if (byte.* == '\\') byte.* = '/';
    }
    if (std.mem.startsWith(u8, normalized, "src/") or std.mem.startsWith(u8, normalized, "tools/")) {
        normalized_owned = false;
        return normalized;
    }
    if (std.mem.indexOf(u8, normalized, "/src/")) |idx| {
        const path = try allocator.dupe(u8, normalized[idx + 1 ..]);
        allocator.free(normalized);
        normalized_owned = false;
        return path;
    }
    if (std.mem.indexOf(u8, normalized, "/tools/")) |idx| {
        const path = try allocator.dupe(u8, normalized[idx + 1 ..]);
        allocator.free(normalized);
        normalized_owned = false;
        return path;
    }
    allocator.free(normalized);
    normalized_owned = false;
    return null;
}

fn isTrackedCoverageFile(path: []const u8) bool {
    if (!std.mem.endsWith(u8, path, ".zig")) return false;
    return coverageScope(path) != .ignored and !isGeneratedCoveragePath(path);
}

fn isGeneratedCoveragePath(path: []const u8) bool {
    if (std.mem.eql(u8, path, "tools/fuzz_test_runner.zig")) return true;
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| {
        if (std.mem.eql(u8, part, ".zig-cache") or
            std.mem.eql(u8, part, "zig-out") or
            std.mem.eql(u8, part, "zig-pkg") or
            std.mem.eql(u8, part, "coverage") or
            std.mem.eql(u8, part, "dist"))
        {
            return true;
        }
    }
    return false;
}

fn coverageScope(filename: []const u8) CoverageScope {
    if (isScopePath(filename, "src")) return .src;
    if (isScopePath(filename, "tools")) return .tools;
    return .ignored;
}

fn isScopePath(filename: []const u8, scope: []const u8) bool {
    if (std.mem.eql(u8, filename, scope)) return true;
    if (std.mem.startsWith(u8, filename, scope) and filename.len > scope.len and isPathSep(filename[scope.len])) return true;
    const needle = if (std.mem.eql(u8, scope, "src")) "/src/" else "/tools/";
    return std.mem.indexOf(u8, filename, needle) != null;
}

fn isPathSep(byte: u8) bool {
    return byte == '/' or byte == '\\';
}

fn attributeValue(tag: []const u8, name: []const u8) ?[]const u8 {
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, tag, pos, name)) |idx| {
        const before_ok = idx == 0 or std.ascii.isWhitespace(tag[idx - 1]) or tag[idx - 1] == '<';
        const after = idx + name.len;
        if (before_ok and after < tag.len and tag[after] == '=') {
            if (after + 1 >= tag.len) return null;
            const quote = tag[after + 1];
            if (quote != '"' and quote != '\'') return null;
            const value_start = after + 2;
            const value_end = std.mem.indexOfScalarPos(u8, tag, value_start, quote) orelse return null;
            return tag[value_start..value_end];
        }
        pos = after;
    }
    return null;
}

fn rateBasisPoints(covered: u64, total: u64) ?u32 {
    if (total == 0) return null;
    return @intCast((covered * 100 * percent_scale) / total);
}

fn termOk(term: std.process.Child.Term) bool {
    return switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
}

test "parseCobertura counts src and tools lines" {
    const xml =
        \\<?xml version="1.0" ?>
        \\<coverage>
        \\  <packages>
        \\    <class filename="src/root.zig">
        \\      <lines>
        \\        <line number="1" hits="1"/>
        \\        <line number="2" hits="0"/>
        \\      </lines>
        \\    </class>
        \\    <class filename="/repo/tools/coverage.zig">
        \\      <lines>
        \\        <line number="1" hits="3"/>
        \\      </lines>
        \\    </class>
        \\    <class filename="zig-pkg/mcp.zig">
        \\      <lines>
        \\        <line number="1" hits="1"/>
        \\      </lines>
        \\    </class>
        \\  </packages>
        \\</coverage>
    ;
    var stats = try parseCobertura(std.testing.allocator, xml);
    defer stats.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 2), stats.covered_lines);
    try std.testing.expectEqual(@as(u64, 3), stats.total_lines);
    try std.testing.expectEqual(@as(u64, 1), stats.src_covered_lines);
    try std.testing.expectEqual(@as(u64, 2), stats.src_total_lines);
    try std.testing.expectEqual(@as(u32, 6666), stats.lineRateBasisPoints().?);
    try std.testing.expectEqual(@as(u32, 5000), stats.srcLineRateBasisPoints().?);
    try std.testing.expectEqual(@as(u32, 10000), stats.toolsLineRateBasisPoints().?);
    try std.testing.expectEqual(@as(usize, 2), stats.files.len);
    try std.testing.expectEqualStrings("src/root.zig", stats.files[0].path);
    try std.testing.expectEqual(@as(usize, 1), stats.files[0].uncovered_lines.len);
    try std.testing.expectEqual(@as(u32, 2), stats.files[0].uncovered_lines[0]);
    try std.testing.expectEqualStrings("tools/coverage.zig", stats.files[1].path);
}

test "parseCobertura skips classes and lines missing required attributes" {
    const xml =
        \\<coverage>
        \\  <class name="missing filename">
        \\    <lines><line number="1" hits="1"/></lines>
        \\  </class>
        \\  <class filename="/repo/src/extra.zig">
        \\    <lines>
        \\      <line hits="1"/>
        \\      <line number="5"/>
        \\      <line number="6" hits="0"/>
        \\    </lines>
        \\  </class>
        \\  <class filename="vendor/generated.zig">
        \\    <lines><line number="1" hits="1"/></lines>
        \\  </class>
        \\</coverage>
    ;
    var stats = try parseCobertura(std.testing.allocator, xml);
    defer stats.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 1), stats.total_lines);
    try std.testing.expectEqual(@as(u64, 0), stats.covered_lines);
    try std.testing.expectEqualStrings("src/extra.zig", stats.files[0].path);
    try std.testing.expectEqual(@as(u32, 6), stats.files[0].uncovered_lines[0]);
}

test "parseCobertura releases parsed files when a later class is malformed" {
    const xml =
        \\<coverage>
        \\  <class filename="src/ok.zig">
        \\    <lines><line number="1" hits="1"/></lines>
        \\  </class>
        \\  <class filename="src/bad.zig">
        \\    <lines><line number="2" hits="0"
        \\  </class>
        \\</coverage>
    ;
    try std.testing.expectError(error.InvalidCoverageReport, parseCobertura(std.testing.allocator, xml));
}

test "coverage path and attribute helpers handle backslashes and prefix collisions" {
    const normalized = try normalizeCoveragePath(std.testing.allocator, "C:\\repo\\tools\\coverage.zig");
    defer if (normalized) |path| std.testing.allocator.free(path);
    try std.testing.expectEqualStrings("tools/coverage.zig", normalized.?);
    try std.testing.expect(!isTrackedCoverageFile("tools/fuzz_test_runner.zig"));
    try std.testing.expect(!isTrackedCoverageFile("zig-out/test.zig"));
    try std.testing.expect(isTrackedCoverageFile("tools/coverage.zig"));
    try std.testing.expectEqualStrings("src/root.zig", attributeValue("<class otherfilename=\"x\" filename=\"src/root.zig\">", "filename").?);
    try std.testing.expect(attributeValue("<line number=1 hits=\"1\"/>", "number") == null);
}
