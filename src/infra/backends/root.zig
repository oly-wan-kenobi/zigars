//! Public surface of the infra/backends subsystem.  Exports the catalog
//! renderer, backend definitions shim, probe port implementation, and
//! static analysis cache.  All backends are optional; the probe layer maps
//! missing or failing executables to unavailable without propagating errors.
pub const catalog = @import("catalog.zig");
pub const definitions = @import("definitions.zig");
pub const probe = @import("probe.zig");
pub const static_cache = @import("static_cache.zig");

const catalog_tests = @import("catalog_tests.zig");
const definitions_tests = @import("definitions_tests.zig");
const probe_tests = @import("probe_tests.zig");
const static_cache_tests = @import("static_cache_tests.zig");

test {
    _ = catalog;
    _ = definitions;
    _ = probe;
    _ = static_cache;
    _ = catalog_tests;
    _ = definitions_tests;
    _ = probe_tests;
    _ = static_cache_tests;
}
