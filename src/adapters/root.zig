//! Adapter entry points that bridge app/domain services to transport-facing surfaces.
pub const mcp = @import("mcp/root.zig");

test {
    _ = @import("../testing/mcp/adapters/root_tests.zig");
}
