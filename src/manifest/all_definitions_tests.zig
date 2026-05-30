//! Smoke-tests that the `all_definitions` namespace exposes valid tool
//! metadata for a representative selection of tools from different groups.

const std = @import("std");
const subject = @import("all_definitions.zig");
const definitions = subject.definitions;

test "all definitions expose core tool metadata" {
    try @import("std").testing.expect(definitions.zig_version.description.len > 0);
    try @import("std").testing.expect(definitions.zigars_capabilities.read_only);
}
