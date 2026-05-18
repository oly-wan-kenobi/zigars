const std = @import("std");

const TextEdit = struct {
    start: usize,
    end: usize,
    new_text: []const u8,
};

pub fn textEditCount(value: std.json.Value) usize {
    return switch (value) {
        .array => |a| a.items.len,
        else => 0,
    };
}

pub fn hashHex(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{x:0>16}", .{std.hash.Wyhash.hash(0, bytes)});
}

fn collectLines(allocator: std.mem.Allocator, text_value: []const u8) ![][]const u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    errdefer lines.deinit(allocator);
    var it = std.mem.splitScalar(u8, text_value, '\n');
    while (it.next()) |line| try lines.append(allocator, line);
    return lines.toOwnedSlice(allocator);
}

pub fn unifiedDiff(allocator: std.mem.Allocator, path: []const u8, before: []const u8, after: []const u8) ![]u8 {
    if (std.mem.eql(u8, before, after)) return allocator.dupe(u8, "");

    const before_lines = try collectLines(allocator, before);
    defer allocator.free(before_lines);
    const after_lines = try collectLines(allocator, after);
    defer allocator.free(after_lines);

    var prefix: usize = 0;
    while (prefix < before_lines.len and prefix < after_lines.len and std.mem.eql(u8, before_lines[prefix], after_lines[prefix])) : (prefix += 1) {}

    var suffix: usize = 0;
    while (suffix < before_lines.len - prefix and suffix < after_lines.len - prefix) : (suffix += 1) {
        const old_idx = before_lines.len - suffix - 1;
        const new_idx = after_lines.len - suffix - 1;
        if (!std.mem.eql(u8, before_lines[old_idx], after_lines[new_idx])) break;
    }

    const old_change_end = before_lines.len - suffix;
    const new_change_end = after_lines.len - suffix;
    const context_before = @min(prefix, 3);
    const context_after = @min(suffix, 3);
    const old_hunk_start = prefix - context_before;
    const new_hunk_start = prefix - context_before;
    const old_hunk_end = @min(before_lines.len, old_change_end + context_after);
    const new_hunk_end = @min(after_lines.len, new_change_end + context_after);
    const old_count = old_hunk_end - old_hunk_start;
    const new_count = new_hunk_end - new_hunk_start;

    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try out.writer.print("--- a/{s}\n+++ b/{s}\n@@ -{d},{d} +{d},{d} @@\n", .{
        path,
        path,
        old_hunk_start + 1,
        old_count,
        new_hunk_start + 1,
        new_count,
    });
    var i: usize = old_hunk_start;
    while (i < prefix) : (i += 1) {
        try out.writer.print(" {s}\n", .{before_lines[i]});
    }
    i = prefix;
    while (i < old_change_end) : (i += 1) {
        try out.writer.print("-{s}\n", .{before_lines[i]});
    }
    i = prefix;
    while (i < new_change_end) : (i += 1) {
        try out.writer.print("+{s}\n", .{after_lines[i]});
    }
    i = old_change_end;
    while (i < old_hunk_end) : (i += 1) {
        try out.writer.print(" {s}\n", .{before_lines[i]});
    }
    return try out.toOwnedSlice();
}

pub fn applyTextEdits(allocator: std.mem.Allocator, source: []const u8, edits_value: std.json.Value) ![]u8 {
    const edits_json = switch (edits_value) {
        .array => |a| a,
        else => return allocator.dupe(u8, source),
    };
    if (edits_json.items.len == 0) return allocator.dupe(u8, source);

    var edits: std.ArrayList(TextEdit) = .empty;
    defer edits.deinit(allocator);
    for (edits_json.items) |item| {
        const obj = switch (item) {
            .object => |o| o,
            else => continue,
        };
        const range = switch (obj.get("range") orelse .null) {
            .object => |o| o,
            else => continue,
        };
        const start = try positionOffset(source, range.get("start") orelse .null);
        const end = try positionOffset(source, range.get("end") orelse .null);
        const new_text = switch (obj.get("newText") orelse .null) {
            .string => |s| s,
            else => "",
        };
        if (end < start) return error.InvalidTextEdit;
        try edits.append(allocator, .{ .start = start, .end = end, .new_text = new_text });
    }

    std.mem.sort(TextEdit, edits.items, {}, struct {
        fn lessThan(_: void, a: TextEdit, b: TextEdit) bool {
            return a.start < b.start;
        }
    }.lessThan);

    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    var cursor: usize = 0;
    for (edits.items) |edit| {
        if (edit.start < cursor or edit.end > source.len) return error.InvalidTextEdit;
        try out.writer.writeAll(source[cursor..edit.start]);
        try out.writer.writeAll(edit.new_text);
        cursor = edit.end;
    }
    try out.writer.writeAll(source[cursor..]);
    return try out.toOwnedSlice();
}

fn positionOffset(source: []const u8, position: std.json.Value) !usize {
    const obj = switch (position) {
        .object => |o| o,
        else => return error.InvalidTextEdit,
    };
    const line: usize = switch (obj.get("line") orelse .null) {
        .integer => |i| if (i >= 0) @intCast(i) else return error.InvalidTextEdit,
        else => return error.InvalidTextEdit,
    };
    const character: usize = switch (obj.get("character") orelse .null) {
        .integer => |i| if (i >= 0) @intCast(i) else return error.InvalidTextEdit,
        else => return error.InvalidTextEdit,
    };

    var current_line: usize = 0;
    var line_start: usize = 0;
    var i: usize = 0;
    while (i < source.len and current_line < line) : (i += 1) {
        if (source[i] == '\n') {
            current_line += 1;
            line_start = i + 1;
        }
    }
    if (current_line != line) return error.InvalidTextEdit;

    var offset = line_start;
    var chars_seen: usize = 0;
    while (offset < source.len and source[offset] != '\n' and chars_seen < character) : (offset += 1) {
        chars_seen += 1;
    }
    if (chars_seen != character) return error.InvalidTextEdit;
    return offset;
}

test "applyTextEdits rejects overlapping edits" {
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator,
        \\[
        \\  {"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":2}},"newText":"x"},
        \\  {"range":{"start":{"line":0,"character":1},"end":{"line":0,"character":3}},"newText":"y"}
        \\]
    , .{});
    defer parsed.deinit();

    try std.testing.expectError(error.InvalidTextEdit, applyTextEdits(std.testing.allocator, "abc\n", parsed.value));
}

test "unifiedDiff emits hunk header and focused edits" {
    const diff = try unifiedDiff(std.testing.allocator, "src/main.zig", "a\nb\nc\n", "a\nx\nc\n");
    defer std.testing.allocator.free(diff);

    try std.testing.expect(std.mem.indexOf(u8, diff, "--- a/src/main.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, diff, "@@ -1,") != null);
    try std.testing.expect(std.mem.indexOf(u8, diff, "-b\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, diff, "+x\n") != null);
}
