//! Facade for the artifact use cases: re-exports the registry workflow module
//! and pulls its tests into the build. Membership only; no logic.
pub const registry = @import("registry.zig");

test {
    _ = registry;
    _ = @import("registry_tests.zig");
}
