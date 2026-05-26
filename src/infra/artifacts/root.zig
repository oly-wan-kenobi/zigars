pub const registry_store = @import("registry_store.zig");

const registry_store_tests = @import("registry_store_tests.zig");
const registry_tests = @import("registry_tests.zig");

test {
    _ = registry_store;
    _ = registry_store_tests;
    _ = registry_tests;
}
