//! Facade for the session use cases: re-exports the shared envelope and viewer
//! modules and pulls their tests into the build. Membership only; no logic.
pub const envelope = @import("envelope.zig");
pub const viewer = @import("viewer.zig");

test {
    _ = envelope;
    _ = viewer;
}
