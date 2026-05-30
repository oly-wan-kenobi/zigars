//! Facade for the discovery use cases: re-exports the workflow module (doctor,
//! workspace/status read models, toolchain resolution, and command/tool
//! planning) and pulls its tests into the build. Membership only; no logic.
pub const workflows = @import("workflows.zig");

test {
    _ = workflows;
    _ = @import("workflows_tests.zig");
}
