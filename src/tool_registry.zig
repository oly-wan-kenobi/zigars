const std = @import("std");
const mcp = @import("mcp");

const mcp_args = @import("adapters/mcp/args.zig");
const json_result = @import("json_result.zig");
const mcp_server = @import("mcp_server.zig");
const runtime_mod = @import("runtime.zig");
const tool_errors = @import("tool_errors.zig");
const tool_metadata = @import("tool_metadata.zig");
const tooling = @import("tooling.zig");

const App = runtime_mod.App;

pub const ToolHandler = tool_metadata.ToolHandler;
pub const validateToolArgs = mcp_args.validateToolArgs;

pub fn addTool(
    server: *mcp_server.Server,
    allocator: std.mem.Allocator,
    runtime: *App,
    comptime spec: tool_metadata.ToolMeta,
    comptime handler: ToolHandler,
) !void {
    const schema_value = try tooling.buildInputSchema(allocator, spec.input_schema);
    try server.addTool(.{
        .name = spec.name,
        .description = spec.description,
        .title = spec.name,
        .inputSchema = schema_value,
        .annotations = .{
            .readOnlyHint = tool_metadata.readOnlyHintFor(spec),
            .idempotentHint = tool_metadata.idempotentHintFor(spec),
            .destructiveHint = tool_metadata.destructiveHintFor(spec),
            .openWorldHint = false,
        },
        .handler = mcpHandler(spec, handler),
        .deinit_result = json_result.deinitToolResult,
        .user_data = runtime,
    });
}

fn mcpHandler(comptime spec: tool_metadata.ToolMeta, comptime handler: ToolHandler) *const fn (?*anyopaque, std.Io, std.mem.Allocator, ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return struct {
        fn call(user_data: ?*anyopaque, io: std.Io, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
            const runtime: *App = @ptrCast(@alignCast(user_data orelse return tool_errors.result(allocator, .{
                .tool = spec.name,
                .operation = "dispatch_tool",
                .phase = "runtime_lookup",
                .code = "runtime_unavailable",
                .category = "server_state",
                .resolution = "Restart zigar; the MCP server registered this tool without attaching runtime state.",
            })));
            const started_ns = std.Io.Clock.now(.real, io).nanoseconds;
            if (try mcp_args.validateToolArgs(allocator, spec, args)) |validation_error| {
                runtime.observability.recordToolCall(spec.name, elapsedMs(io, started_ns), validation_error.is_error);
                return validation_error;
            }
            const result = handler(runtime, allocator, args) catch |err| {
                runtime.observability.recordToolCall(spec.name, elapsedMs(io, started_ns), true);
                return err;
            };
            runtime.observability.recordToolCall(spec.name, elapsedMs(io, started_ns), result.is_error);
            return result;
        }
    }.call;
}

fn elapsedMs(io: std.Io, started_ns: anytype) u64 {
    const duration_ns = std.Io.Clock.now(.real, io).nanoseconds - started_ns;
    if (duration_ns <= 0) return 0;
    return @intCast(@divTrunc(duration_ns, std.time.ns_per_ms));
}
