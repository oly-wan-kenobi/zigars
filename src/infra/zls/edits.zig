const std = @import("std");

const TextEdit = struct {
    start: usize,
    end: usize,
    new_text: []const u8,
};

const DecodedUtf8 = struct {
    scalar: u32,
    len: usize,
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
    var lines_owned = true;
    defer if (lines_owned) lines.deinit(allocator);
    var it = std.mem.splitScalar(u8, text_value, '\n');
    while (it.next()) |line| try lines.append(allocator, line);
    const owned = try lines.toOwnedSlice(allocator);
    lines_owned = false;
    return owned;
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
    var out_owned = true;
    defer if (out_owned) out.deinit();
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
    const diff = try out.toOwnedSlice();
    out_owned = false;
    return diff;
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
    var out_owned = true;
    defer if (out_owned) out.deinit();
    var cursor: usize = 0;
    for (edits.items) |edit| {
        if (edit.start < cursor or edit.end > source.len) return error.InvalidTextEdit;
        try out.writer.writeAll(source[cursor..edit.start]);
        try out.writer.writeAll(edit.new_text);
        cursor = edit.end;
    }
    try out.writer.writeAll(source[cursor..]);
    const updated = try out.toOwnedSlice();
    out_owned = false;
    return updated;
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

    return lspPositionToByteOffset(source, line, character);
}

/// Convert an LSP position to a byte offset.
///
/// Lines are delimited by '\n'. For CRLF files, the '\r' remains part of the
/// preceding line and counts as one UTF-16 code unit, matching prior behavior.
pub fn lspPositionToByteOffset(source: []const u8, line: usize, utf16_character: usize) !usize {
    var current_line: usize = 0;
    var line_utf16_units: usize = 0;
    var found_offset: ?usize = null;
    var i: usize = 0;
    while (i < source.len) {
        if (current_line == line and line_utf16_units == utf16_character and found_offset == null) {
            found_offset = i;
        }
        if (source[i] == '\n') {
            current_line += 1;
            line_utf16_units = 0;
            i += 1;
            continue;
        }

        const decoded = try decodeUtf8At(source, i);
        if (current_line == line) {
            const units = utf16CodeUnitCount(decoded.scalar);
            if (line_utf16_units < utf16_character and utf16_character < line_utf16_units + units) {
                return error.InvalidTextEdit;
            }
            line_utf16_units += units;
        }
        i += decoded.len;
    }
    if (current_line == line and line_utf16_units == utf16_character and found_offset == null) {
        found_offset = source.len;
    }
    return found_offset orelse error.InvalidTextEdit;
}

fn utf16CodeUnitCount(scalar: u32) usize {
    return if (scalar > 0xffff) 2 else 1;
}

fn decodeUtf8At(source: []const u8, offset: usize) !DecodedUtf8 {
    const first = source[offset];
    if (first < 0x80) return .{ .scalar = first, .len = 1 };

    if (first < 0xc2) return error.InvalidTextEdit;
    if (first < 0xe0) {
        if (source.len - offset < 2) return error.InvalidTextEdit;
        const second = source[offset + 1];
        if (!isContinuation(second)) return error.InvalidTextEdit;
        return .{
            .scalar = (@as(u32, first & 0x1f) << 6) | @as(u32, second & 0x3f),
            .len = 2,
        };
    }

    if (first < 0xf0) {
        if (source.len - offset < 3) return error.InvalidTextEdit;
        const second = source[offset + 1];
        const third = source[offset + 2];
        if (!isContinuation(second) or !isContinuation(third)) return error.InvalidTextEdit;
        if (first == 0xe0 and second < 0xa0) return error.InvalidTextEdit;
        if (first == 0xed and second >= 0xa0) return error.InvalidTextEdit;
        return .{
            .scalar = (@as(u32, first & 0x0f) << 12) | (@as(u32, second & 0x3f) << 6) | @as(u32, third & 0x3f),
            .len = 3,
        };
    }

    if (first < 0xf5) {
        if (source.len - offset < 4) return error.InvalidTextEdit;
        const second = source[offset + 1];
        const third = source[offset + 2];
        const fourth = source[offset + 3];
        if (!isContinuation(second) or !isContinuation(third) or !isContinuation(fourth)) return error.InvalidTextEdit;
        if (first == 0xf0 and second < 0x90) return error.InvalidTextEdit;
        if (first == 0xf4 and second >= 0x90) return error.InvalidTextEdit;
        return .{
            .scalar = (@as(u32, first & 0x07) << 18) | (@as(u32, second & 0x3f) << 12) | (@as(u32, third & 0x3f) << 6) | @as(u32, fourth & 0x3f),
            .len = 4,
        };
    }

    return error.InvalidTextEdit;
}

fn isContinuation(byte: u8) bool {
    return (byte & 0xc0) == 0x80;
}

fn expectApplyTextEdits(source: []const u8, edits_json: []const u8, expected: []const u8) !void {
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, edits_json, .{});
    defer parsed.deinit();
    const updated = try applyTextEdits(std.testing.allocator, source, parsed.value);
    defer std.testing.allocator.free(updated);
    try std.testing.expectEqualStrings(expected, updated);
}

fn expectApplyTextEditsError(source: []const u8, edits_json: []const u8) !void {
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, edits_json, .{});
    defer parsed.deinit();
    try std.testing.expectError(error.InvalidTextEdit, applyTextEdits(std.testing.allocator, source, parsed.value));
}

test "lspPositionToByteOffset maps UTF-16 code units" {
    const e = "\xc3\xa9";
    const euro = "\xe2\x82\xac";
    const grin = "\xf0\x9f\x98\x80";
    try std.testing.expectEqual(@as(usize, 2), try lspPositionToByteOffset(e ++ "a", 0, 1));
    try std.testing.expectEqual(@as(usize, 3), try lspPositionToByteOffset(euro ++ "a", 0, 1));

    const mixed = "a" ++ e ++ grin ++ "b\nx";
    try std.testing.expectEqual(@as(usize, 0), try lspPositionToByteOffset(mixed, 0, 0));
    try std.testing.expectEqual(@as(usize, 1), try lspPositionToByteOffset(mixed, 0, 1));
    try std.testing.expectEqual(@as(usize, 3), try lspPositionToByteOffset(mixed, 0, 2));
    try std.testing.expectError(error.InvalidTextEdit, lspPositionToByteOffset(mixed, 0, 3));
    try std.testing.expectEqual(@as(usize, 7), try lspPositionToByteOffset(mixed, 0, 4));
    try std.testing.expectEqual(@as(usize, 8), try lspPositionToByteOffset(mixed, 0, 5));
    try std.testing.expectEqual(@as(usize, 9), try lspPositionToByteOffset(mixed, 1, 0));
}

test "lspPositionToByteOffset rejects invalid source and positions" {
    const grin = "\xf0\x9f\x98\x80";
    try std.testing.expectError(error.InvalidTextEdit, lspPositionToByteOffset("abc", 1, 0));
    try std.testing.expectError(error.InvalidTextEdit, lspPositionToByteOffset("\xc3\xa9", 0, 2));
    try std.testing.expectError(error.InvalidTextEdit, lspPositionToByteOffset(grin, 0, 1));
    try std.testing.expectError(error.InvalidTextEdit, lspPositionToByteOffset("ok\xff", 0, 0));
    try std.testing.expectError(error.InvalidTextEdit, lspPositionToByteOffset("\xe2\x82", 0, 0));
    try std.testing.expectError(error.InvalidTextEdit, lspPositionToByteOffset("\xe2A\xac", 0, 0));
    try std.testing.expectError(error.InvalidTextEdit, lspPositionToByteOffset("\xe2\x82A", 0, 0));
    try std.testing.expectError(error.InvalidTextEdit, lspPositionToByteOffset("\xe0\x80\x80", 0, 0));
    try std.testing.expectError(error.InvalidTextEdit, lspPositionToByteOffset("\xed\xa0\x80", 0, 0));
}

test "applyTextEdits keeps ASCII behavior" {
    try expectApplyTextEdits("abcdef\n",
        \\[{"range":{"start":{"line":0,"character":2},"end":{"line":0,"character":4}},"newText":"XY"}]
    , "abXYef\n");
}

test "applyTextEdits uses UTF-16 offsets for BMP text" {
    const e = "\xc3\xa9";
    try expectApplyTextEdits(e ++ "abc\n",
        \\[{"range":{"start":{"line":0,"character":1},"end":{"line":0,"character":2}},"newText":"A"}]
    , e ++ "Abc\n");
}

test "applyTextEdits uses UTF-16 offsets for astral text" {
    const grin = "\xf0\x9f\x98\x80";
    try expectApplyTextEdits(grin ++ "abc\n",
        \\[{"range":{"start":{"line":0,"character":2},"end":{"line":0,"character":3}},"newText":"A"}]
    , grin ++ "Abc\n");
}

test "applyTextEdits supports end-of-line and multi-line UTF-16 edits" {
    const e = "\xc3\xa9";
    const grin = "\xf0\x9f\x98\x80";
    try expectApplyTextEdits(e ++ grin ++ "\n",
        \\[{"range":{"start":{"line":0,"character":3},"end":{"line":0,"character":3}},"newText":"!"}]
    , e ++ grin ++ "!\n");

    try expectApplyTextEdits(e ++ "\nabc\n" ++ grin ++ "def\n",
        \\[{"range":{"start":{"line":1,"character":1},"end":{"line":2,"character":2}},"newText":"X"}]
    , e ++ "\naXdef\n");
}

test "applyTextEdits accepts non-ASCII replacement text" {
    try expectApplyTextEdits("abc\n",
        \\[{"range":{"start":{"line":0,"character":1},"end":{"line":0,"character":2}},"newText":"caf\u00e9"}]
    , "acaf\xc3\xa9c\n");
}

test "applyTextEdits rejects UTF-16 invalid positions" {
    const grin = "\xf0\x9f\x98\x80";
    try expectApplyTextEditsError(grin ++ "abc\n",
        \\[{"range":{"start":{"line":0,"character":1},"end":{"line":0,"character":1}},"newText":"x"}]
    );
    try expectApplyTextEditsError("abc\n",
        \\[{"range":{"start":{"line":-1,"character":0},"end":{"line":0,"character":0}},"newText":"x"}]
    );
    try expectApplyTextEditsError("abc\n",
        \\[{"range":{"start":{"line":0,"character":-1},"end":{"line":0,"character":0}},"newText":"x"}]
    );
    try expectApplyTextEditsError("ok\xff",
        \\[{"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":0}},"newText":"x"}]
    );
}

test "applyTextEdits rejects overlapping UTF-16 edits" {
    const e = "\xc3\xa9";
    try expectApplyTextEditsError(e ++ "abcd\n",
        \\[
        \\  {"range":{"start":{"line":0,"character":1},"end":{"line":0,"character":3}},"newText":"x"},
        \\  {"range":{"start":{"line":0,"character":2},"end":{"line":0,"character":4}},"newText":"y"}
        \\]
    );
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
