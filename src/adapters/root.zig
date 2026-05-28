//! Adapter entry points that bridge app/domain services to transport-facing surfaces.
pub const cli = @import("cli/root.zig");
pub const mcp = @import("mcp/root.zig");

test {
    _ = cli;
    _ = @import("../testing/mcp/adapters/root_tests.zig");
}
