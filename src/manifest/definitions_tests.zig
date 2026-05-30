//! Pins the definitions facade contract: the base group is present and
//! the total group count satisfies the minimum expected by the aggregation
//! pipeline.

const std = @import("std");
const subject = @import("definitions.zig");
const definitions = subject.definitions;
const definition_groups = subject.definition_groups;

test "definition groups include base and extension groups" {
    try @import("std").testing.expect(definition_groups.len >= 5);
    try @import("std").testing.expect(@hasDecl(definition_groups[0], "zig_version"));
}
