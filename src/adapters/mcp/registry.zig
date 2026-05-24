const std = @import("std");
const mcp = @import("mcp");

const mcp_args = @import("args.zig");
const json_result = @import("result.zig");
const mcp_server = @import("server.zig");
const schema_projection = @import("schema.zig");
const tool_errors = @import("errors.zig");
const manifest = @import("../../manifest/mod.zig");

pub fn ToolHandler(comptime RuntimePtr: type) type {
    return *const fn (RuntimePtr, std.mem.Allocator, ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult;
}

pub const validateToolArgs = mcp_args.validateToolArgs;

pub fn addTool(
    server: *mcp_server.Server,
    allocator: std.mem.Allocator,
    runtime: anytype,
    comptime spec: manifest.ToolMeta,
    comptime handler: ToolHandler(@TypeOf(runtime)),
    comptime record_call: anytype,
) !void {
    const RuntimePtr = @TypeOf(runtime);
    const schema_value = try schema_projection.buildInputSchema(allocator, spec.input_schema);
    try server.addTool(.{
        .name = spec.name,
        .description = spec.description,
        .title = spec.name,
        .inputSchema = schema_value,
        .annotations = .{
            .readOnlyHint = manifest.readOnlyHintFor(spec),
            .idempotentHint = manifest.idempotentHintFor(spec),
            .destructiveHint = manifest.destructiveHintFor(spec),
            .openWorldHint = false,
        },
        .handler = mcpHandler(RuntimePtr, spec, handler, record_call),
        .deinit_result = json_result.deinitToolResult,
        .user_data = runtime,
    });
}

fn mcpHandler(
    comptime RuntimePtr: type,
    comptime spec: manifest.ToolMeta,
    comptime handler: ToolHandler(RuntimePtr),
    comptime record_call: anytype,
) *const fn (?*anyopaque, std.Io, std.mem.Allocator, ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return struct {
        fn call(user_data: ?*anyopaque, io: std.Io, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
            const runtime: RuntimePtr = @ptrCast(@alignCast(user_data orelse return tool_errors.result(allocator, .{
                .tool = spec.name,
                .operation = "dispatch_tool",
                .phase = "runtime_lookup",
                .code = "runtime_unavailable",
                .category = "server_state",
                .resolution = "Restart zigar; the MCP server registered this tool without attaching runtime state.",
            })));
            const started_ns = std.Io.Clock.now(.real, io).nanoseconds;
            if (try mcp_args.validateToolArgs(allocator, spec, args)) |validation_error| {
                record_call(runtime, spec.name, elapsedMs(io, started_ns), validation_error.is_error);
                return validation_error;
            }
            const result = handler(runtime, allocator, args) catch |err| {
                record_call(runtime, spec.name, elapsedMs(io, started_ns), true);
                return err;
            };
            record_call(runtime, spec.name, elapsedMs(io, started_ns), result.is_error);
            return result;
        }
    }.call;
}

fn elapsedMs(io: std.Io, started_ns: anytype) u64 {
    const duration_ns = std.Io.Clock.now(.real, io).nanoseconds - started_ns;
    if (duration_ns <= 0) return 0;
    return @intCast(@divTrunc(duration_ns, std.time.ns_per_ms));
}
