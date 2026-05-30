//! Facade for the observability use cases: re-exports the metrics-aggregation
//! workflow module and pulls its tests into the build. Membership only; no logic.
pub const workflows = @import("workflows.zig");

const workflows_tests = @import("workflows_tests.zig");

test {
    _ = workflows;
    _ = workflows_tests;
}
