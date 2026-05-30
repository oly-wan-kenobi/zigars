//! Facade that assembles the full `definition_groups` tuple consumed by the
//! aggregation pipeline. The base set comes from `all_definitions.zig`;
//! extension groups are appended here in stable order.
//!
//! `definition_groups` order is a public contract: the `ToolId` enum integer
//! values derive from it. Append new groups; never reorder existing entries.

/// Base tool definition namespace, aliased from `all_definitions.zig`.
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
