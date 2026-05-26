//! Editing-domain APIs for patch sessions and workspace path policy decisions.
pub const patch_session = @import("patch_session.zig");
pub const path_policy = @import("path_policy.zig");

test {
    _ = patch_session;
    _ = path_policy;
    _ = @import("patch_session_tests.zig");
    _ = @import("path_policy_tests.zig");
}
