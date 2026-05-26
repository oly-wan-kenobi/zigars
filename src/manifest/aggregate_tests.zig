const std = @import("std");
const subject = @import("aggregate.zig");
const definitions = subject.definitions;
const ToolId = subject.ToolId;
const ToolMeta = subject.ToolMeta;
const ToolEntry = subject.ToolEntry;
const entries = subject.entries;
const specs = subject.specs;

test "aggregate builds stable entries and specs" {
    try std.testing.expect(entries.len > 0);
    try std.testing.expectEqual(entries.len, specs.len);
    try std.testing.expectEqualStrings(entries[0].name, specs[0].name);
}
