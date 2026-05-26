const std = @import("std");
const edits = @import("edits.zig");

const lspPositionToByteOffset = edits.lspPositionToByteOffset;
const applyTextEdits = edits.applyTextEdits;
const unifiedDiff = edits.unifiedDiff;

fn expectApplyTextEditsError(source: []const u8, edits_json: []const u8) !void {
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, edits_json, .{});
    defer parsed.deinit();
    try std.testing.expectError(error.InvalidTextEdit, applyTextEdits(std.testing.allocator, source, parsed.value));
}

fn expectApplyTextEdits(source: []const u8, edits_json: []const u8, expected: []const u8) !void {
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, edits_json, .{});
    defer parsed.deinit();
    const updated = try applyTextEdits(std.testing.allocator, source, parsed.value);
    defer std.testing.allocator.free(updated);
    try std.testing.expectEqualStrings(expected, updated);
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
