pub const app_context = @import("app_context.zig");
pub const config = @import("config.zig");
pub const manifest_catalog = @import("manifest_catalog.zig");
pub const runtime = @import("runtime.zig");
pub const runtime_state = @import("runtime_state.zig");
pub const runtime_ports = @import("runtime_ports.zig");

const app_context_tests = @import("app_context_tests.zig");
const config_tests = @import("config_tests.zig");
const manifest_catalog_tests = @import("manifest_catalog_tests.zig");
const runtime_tests = @import("runtime_tests.zig");
const runtime_ports_tests = @import("runtime_ports_tests.zig");

test {
    _ = app_context;
    _ = config;
    _ = manifest_catalog;
    _ = runtime;
    _ = runtime_state;
    _ = runtime_ports;
    _ = app_context_tests;
    _ = config_tests;
    _ = manifest_catalog_tests;
    _ = runtime_tests;
    _ = runtime_ports_tests;
}
