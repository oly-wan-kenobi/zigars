pub const registry = @import("registry.zig");

test {
    _ = registry;
    _ = @import("registry_tests.zig");
}
