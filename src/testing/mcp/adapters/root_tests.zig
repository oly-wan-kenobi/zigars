const mcp_root = @import("../../../adapters/root.zig").mcp;

test "adapters root exposes MCP adapter package" {
    _ = mcp_root;
}
