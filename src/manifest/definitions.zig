pub const definitions = @import("all_definitions.zig").definitions;
pub const definition_groups = .{
    definitions,
    @import("definitions/phase6.zig"),
    @import("definitions/performance.zig"),
    @import("definitions/diagnostics.zig"),
    @import("definitions/adoption.zig"),
};

test "definition groups include base and extension groups" {
    try @import("std").testing.expect(definition_groups.len >= 5);
    try @import("std").testing.expect(@hasDecl(definition_groups[0], "zig_version"));
}
