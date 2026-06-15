//! Wires manifest-listed MCP tools, prompts, and resources into a server instance.
const mcp_server = @import("server.zig");
const handlers = @import("handlers.zig");
const manifest = @import("../../manifest/mod.zig");
const prompts = @import("prompts.zig");
const registry = @import("registry.zig");
const resources = @import("resources.zig");

/// Registers the manifest-listed tools admitted by `runtime.config.profile`
/// using compile-time handler resolution. The default `full` profile registers
/// every tool; a narrower profile skips tools whose group it excludes.
/// `runtime.allocator` backs the projected schemas, which the server retains
/// for its whole lifetime and frees in `Server.deinit`, so it must stay alive
/// until then. `record_call` is the per-invocation metrics hook threaded
/// through to each handler.
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
        // Registration-time profile filter: a tool whose group is excluded by
        // the active profile is never registered, so it is absent from both
        // tools/list and tools/call. The profile value is read at runtime, so
        // the gate is an ordinary runtime `if` (not comptime `continue`, which
        // is rejected inside an inline loop) and is observable to coverage.
        if (manifest.idInProfile(spec.id, runtime.config.profile)) {
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
}

/// Re-export for installing zigars MCP resources on a server.
pub const registerResources = resources.registerResources;
/// Re-export for installing zigars MCP prompts on a server.
pub const registerPrompts = prompts.registerPrompts;
