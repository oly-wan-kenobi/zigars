//! Aggregator for the runtime-UX usecase area: process-local jobs, run events,
//! MCP resource queries, and workspace-roots guidance.
pub const workflows = @import("workflows.zig");

test "runtime ux root imports workflows" {
    _ = workflows;
    _ = @import("workflows_tests.zig");
}
