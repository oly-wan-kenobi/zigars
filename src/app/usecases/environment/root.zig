//! Aggregates the environment use-case modules (adoption, backend catalog,
//! trust reporting, and the profile/backend workflows) and pulls their tests
//! into the build so the subsystem is exercised as a unit.
pub const adoption = @import("adoption.zig");
pub const backend_catalog = @import("backend_catalog.zig");
pub const trust = @import("trust.zig");
pub const workflows = @import("workflows.zig");

const backend_catalog_tests = @import("backend_catalog_tests.zig");
const doctor_tests = @import("doctor_tests.zig");

test {
    _ = adoption;
    _ = backend_catalog;
    _ = trust;
    _ = workflows;
    _ = backend_catalog_tests;
    _ = doctor_tests;
}
