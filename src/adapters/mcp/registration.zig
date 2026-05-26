//! Wires manifest-listed MCP tools, prompts, and resources into a server instance.
const mcp_server = @import("server.zig");
const handlers = @import("handlers.zig");
const manifest = @import("../../manifest/mod.zig");
const prompts = @import("prompts.zig");
const registry = @import("registry.zig");
const resources = @import("resources.zig");

/// Registers every manifest-listed tool using compile-time handler resolution.
pub fn registerTools(
    server: *mcp_server.Server,
    runtime: anytype,
    comptime RuntimePorts: type,
    comptime RuntimePortOptions: type,
    comptime record_call: anytype,
) !void {
    // High branch quota is required because this is an inline compile-time dispatch table.
    @setEvalBranchQuota(3000);
    inline for (manifest.specs) |spec| {
        try registry.addTool(
            server,
            runtime.allocator,
            runtime,
            spec,
            handlers.handlerFor(spec.id, @TypeOf(runtime), RuntimePorts, RuntimePortOptions),
            record_call,
        );
    }
}

/// Re-export for installing zigar MCP resources on a server.
pub const registerResources = resources.registerResources;
/// Re-export for installing zigar MCP prompts on a server.
pub const registerPrompts = prompts.registerPrompts;
