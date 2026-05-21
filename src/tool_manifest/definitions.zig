pub const definitions = @import("all_definitions.zig").definitions;
pub const definition_groups = .{
    definitions,
    @import("definitions/phase6.zig"),
    @import("definitions/performance.zig"),
    @import("definitions/diagnostics.zig"),
};
