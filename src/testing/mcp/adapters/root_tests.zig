//! Smoke test confirming the adapters root module exposes the MCP sub-package.
//! Fails at compile time if the export is removed or renamed.

const mcp_root = @import("../../../adapters/root.zig").mcp;

test "adapters root exposes MCP adapter package" {
    _ = mcp_root;
}
