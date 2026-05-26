//! Shared MCP tool-registration plumbing: schema projection, arg validation, and error mapping.
const std = @import("std");
const mcp = @import("mcp");

const mcp_args = @import("args.zig");
const json_result = @import("result.zig");
const mcp_server = @import("server.zig");
const schema_projection = @import("schema.zig");
const tool_errors = @import("errors.zig");
const manifest = @import("../../manifest/mod.zig");

/// Runtime-bound tool callback signature used by registered MCP handlers.
pub fn ToolHandler(comptime RuntimePtr: type) type {
    return *const fn (RuntimePtr, std.mem.Allocator, ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult;
}

/// Re-exported argument validator used by registry tests and handlers.
pub const validateToolArgs = mcp_args.validateToolArgs;

/// Registers one manifest tool with schema, annotations, validation, and metrics.
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
    // The registered callback owns the ToolResult memory contract via deinit_result.
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

/// Wraps adapter handlers with runtime lookup, arg validation, and call recording.
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

test "mcp handler records thrown handler failures" {
    const Runtime = struct {
        calls: usize = 0,
        last_error: bool = false,
    };
    const Stub = struct {
        fn handler(_: *Runtime, _: std.mem.Allocator, _: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
            return @as(mcp.tools.ToolError, error.ExecutionFailed);
        }

        fn record(runtime: *Runtime, _: []const u8, _: u64, is_error: bool) void {
            runtime.calls += 1;
            runtime.last_error = is_error;
        }
    };

    var runtime = Runtime{};
    const handler = mcpHandler(*Runtime, manifest.entries[0].meta, Stub.handler, Stub.record);
    try std.testing.expectError(error.ExecutionFailed, handler(&runtime, std.testing.io, std.testing.allocator, null));
    try std.testing.expectEqual(@as(usize, 1), runtime.calls);
    try std.testing.expect(runtime.last_error);
}
