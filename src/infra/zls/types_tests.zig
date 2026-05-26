const std = @import("std");
const types = @import("types.zig");

const Position = types.Position;
const Range = types.Range;
const Location = types.Location;
const CompletionItem = types.CompletionItem;
const Diagnostic = types.Diagnostic;
const DocumentSymbol = types.DocumentSymbol;
const HoverContents = types.HoverContents;
const symbolKindName = types.symbolKindName;
const severityName = types.severityName;
const completionKindName = types.completionKindName;

test "symbolKindName known kinds" {
    try std.testing.expectEqualStrings("File", symbolKindName(1));
    try std.testing.expectEqualStrings("Function", symbolKindName(12));
    try std.testing.expectEqualStrings("Struct", symbolKindName(23));
    try std.testing.expectEqualStrings("Constant", symbolKindName(14));
    try std.testing.expectEqualStrings("Field", symbolKindName(8));
    try std.testing.expectEqualStrings("EnumMember", symbolKindName(22));
    try std.testing.expectEqualStrings("Variable", symbolKindName(13));
}

test "symbolKindName unknown kind" {
    try std.testing.expectEqualStrings("Unknown", symbolKindName(0));
    try std.testing.expectEqualStrings("Unknown", symbolKindName(99));
    try std.testing.expectEqualStrings("Unknown", symbolKindName(255));
}

test "severityName known severities" {
    try std.testing.expectEqualStrings("Error", severityName(1));
    try std.testing.expectEqualStrings("Warning", severityName(2));
    try std.testing.expectEqualStrings("Information", severityName(3));
    try std.testing.expectEqualStrings("Hint", severityName(4));
}

test "severityName null and unknown" {
    try std.testing.expectEqualStrings("Unknown", severityName(null));
    try std.testing.expectEqualStrings("Unknown", severityName(0));
    try std.testing.expectEqualStrings("Unknown", severityName(100));
}

test "HoverContents text from markup" {
    const hc = HoverContents{ .markup = .{ .value = "fn main() void" } };
    try std.testing.expectEqualStrings("fn main() void", hc.text());
}

test "HoverContents text from string" {
    const hc = HoverContents{ .string = "some hover text" };
    try std.testing.expectEqualStrings("some hover text", hc.text());
}

test "HoverContents markup JSON roundtrip" {
    const alloc = std.testing.allocator;
    const input = "{\"kind\":\"markdown\",\"value\":\"hello world\"}";
    const parsed = try std.json.parseFromSlice(HoverContents, alloc, input, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("hello world", parsed.value.text());
}

test "HoverContents string JSON roundtrip" {
    const alloc = std.testing.allocator;
    const input = "\"plain hover\"";
    const parsed = try std.json.parseFromSlice(HoverContents, alloc, input, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("plain hover", parsed.value.text());
}

test "Position and Range structs" {
    const pos = Position{ .line = 10, .character = 5 };
    try std.testing.expectEqual(@as(u32, 10), pos.line);
    try std.testing.expectEqual(@as(u32, 5), pos.character);

    const range = Range{
        .start = .{ .line = 1, .character = 0 },
        .end = .{ .line = 1, .character = 20 },
    };
    try std.testing.expectEqual(@as(u32, 1), range.start.line);
    try std.testing.expectEqual(@as(u32, 20), range.end.character);
}

test "Location JSON parse" {
    const alloc = std.testing.allocator;
    const input = "{\"uri\":\"file:///test.zig\",\"range\":{\"start\":{\"line\":5,\"character\":10},\"end\":{\"line\":5,\"character\":20}}}";
    const parsed = try std.json.parseFromSlice(Location, alloc, input, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("file:///test.zig", parsed.value.uri);
    try std.testing.expectEqual(@as(u32, 5), parsed.value.range.start.line);
    try std.testing.expectEqual(@as(u32, 10), parsed.value.range.start.character);
}

test "CompletionItem JSON parse" {
    const alloc = std.testing.allocator;
    const input = "{\"label\":\"println\",\"kind\":3,\"detail\":\"fn println(...) void\"}";
    const parsed = try std.json.parseFromSlice(CompletionItem, alloc, input, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("println", parsed.value.label);
    try std.testing.expectEqual(@as(u32, 3), parsed.value.kind.?);
    try std.testing.expectEqualStrings("fn println(...) void", parsed.value.detail.?);
}

test "CompletionItem minimal JSON parse" {
    const alloc = std.testing.allocator;
    const input = "{\"label\":\"x\"}";
    const parsed = try std.json.parseFromSlice(CompletionItem, alloc, input, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("x", parsed.value.label);
    try std.testing.expect(parsed.value.kind == null);
    try std.testing.expect(parsed.value.detail == null);
}

test "Diagnostic JSON parse" {
    const alloc = std.testing.allocator;
    const input =
        \\{"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":5}},"severity":1,"message":"error here"}
    ;
    const parsed = try std.json.parseFromSlice(Diagnostic, alloc, input, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(u32, 1), parsed.value.severity.?);
    try std.testing.expectEqualStrings("error here", parsed.value.message);
}

test "DocumentSymbol with children JSON parse" {
    const alloc = std.testing.allocator;
    const input =
        \\{"name":"Foo","kind":23,"range":{"start":{"line":0,"character":0},"end":{"line":10,"character":0}},"selectionRange":{"start":{"line":0,"character":0},"end":{"line":0,"character":3}},"children":[{"name":"bar","kind":12,"range":{"start":{"line":1,"character":0},"end":{"line":3,"character":0}},"selectionRange":{"start":{"line":1,"character":0},"end":{"line":1,"character":3}}}]}
    ;
    const parsed = try std.json.parseFromSlice(DocumentSymbol, alloc, input, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("Foo", parsed.value.name);
    try std.testing.expectEqual(@as(u32, 23), parsed.value.kind);
    try std.testing.expectEqual(@as(usize, 1), parsed.value.children.?.len);
    try std.testing.expectEqualStrings("bar", parsed.value.children.?[0].name);
}

test "completionKindName coverage" {
    try std.testing.expectEqualStrings("Text", completionKindName(1));
    try std.testing.expectEqualStrings("Function", completionKindName(3));
    try std.testing.expectEqualStrings("Struct", completionKindName(22));
    try std.testing.expectEqualStrings("Keyword", completionKindName(14));
    try std.testing.expectEqualStrings("Unknown", completionKindName(null));
    try std.testing.expectEqualStrings("Unknown", completionKindName(0));
    try std.testing.expectEqualStrings("Unknown", completionKindName(99));
}
