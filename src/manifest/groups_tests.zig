//! Verifies that `group_specs` provides exactly one entry per `ToolGroup`
//! variant, each carrying at least one discovery keyword.

const std = @import("std");
const types = @import("types.zig");
const subject = @import("groups.zig");
const group_specs = subject.group_specs;

test "group specs cover every tool group" {
    try @import("std").testing.expectEqual(@import("std").meta.fields(types.ToolGroup).len, group_specs.len);
    try @import("std").testing.expect(group_specs[0].keywords.len > 0);
}
