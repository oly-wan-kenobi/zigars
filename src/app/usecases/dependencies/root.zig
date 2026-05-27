//! Dependency lifecycle usecases for build.zig.zon parsing, preview/apply
//! mutation, registry orientation, and migration session envelopes.
pub const workflows = @import("workflows.zig");

test {
    _ = workflows;
    _ = @import("workflows_tests.zig");
}
