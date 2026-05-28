/// Core generated tool definitions used to derive ids and catalog entries.
pub const definitions = @import("all_definitions.zig").definitions;
/// Definition namespaces appended after the generated core set.
///
/// Order is part of the stable ToolId enum and registry projection; append new
/// groups instead of reordering existing entries unless a release explicitly
/// accepts catalog id churn.
pub const definition_groups = .{
    definitions,
    @import("definitions/phase6.zig"),
    @import("definitions/performance.zig"),
    @import("definitions/diagnostics.zig"),
    @import("definitions/adoption.zig"),
};
