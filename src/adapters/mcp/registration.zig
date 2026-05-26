const mcp_server = @import("server.zig");
const handlers = @import("handlers.zig");
const manifest = @import("../../manifest/mod.zig");
const prompts = @import("prompts.zig");
const registry = @import("registry.zig");
const resources = @import("resources.zig");

pub fn registerTools(
    server: *mcp_server.Server,
    runtime: anytype,
    comptime RuntimePorts: type,
    comptime RuntimePortOptions: type,
    comptime record_call: anytype,
) !void {
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

pub const registerResources = resources.registerResources;
pub const registerPrompts = prompts.registerPrompts;
