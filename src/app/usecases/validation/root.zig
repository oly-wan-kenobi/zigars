//! Aggregates the validation use cases (validation workflows and project
//! intelligence) and wires their tests into one barrel.
pub const workflows = @import("workflows.zig");
pub const project_intelligence = @import("project_intelligence.zig");

test {
    _ = workflows;
    _ = project_intelligence;
    _ = @import("workflows_tests.zig");
    _ = @import("project_intelligence_tests.zig");
}
