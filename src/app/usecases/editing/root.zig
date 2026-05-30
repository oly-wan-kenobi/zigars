//! Editing usecases aggregator: re-exports the source-mutating patch-session
//! and editing workflow modules and pulls their test suites into the build.
pub const patch_sessions = @import("patch_sessions.zig");
pub const workflows = @import("workflows.zig");

test {
    _ = patch_sessions;
    _ = workflows;
    _ = @import("patch_sessions_tests.zig");
}
