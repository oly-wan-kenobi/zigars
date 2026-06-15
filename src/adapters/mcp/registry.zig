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
    const output_schema_value = if (spec.output_schema) |output_schema|
        try schema_projection.buildOutputSchema(allocator, output_schema)
    else
        null;
    // The registered callback owns the ToolResult memory contract via deinit_result.
    try server.addTool(.{
        .name = spec.name,
        .description = spec.description,
        .title = spec.name,
        .inputSchema = schema_value,
        .outputSchema = output_schema_value,
        .schema_allocator = allocator,
        // Tools that spawn a subprocess/backend can run long enough to be worth
        // cancelling; dispatch them on a worker so the loop can honor
        // notifications/cancelled mid-run. Pure in-memory tools stay inline.
        .cancellable = manifest.riskFor(spec.id).executes_user_command or
            manifest.riskFor(spec.id).executes_project_code or
            manifest.riskFor(spec.id).executes_backend,
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
/// `record_call` is invoked on every exit path -- validation rejection, thrown
/// handler error, and success -- so latency and error counters never miss a
/// dispatch. Expected argument problems return an error-flagged ToolResult;
/// only unexpected failures propagate as a thrown error.
fn mcpHandler(
    comptime RuntimePtr: type,
    comptime spec: manifest.ToolMeta,
    comptime handler: ToolHandler(RuntimePtr),
    comptime record_call: anytype,
) *const fn (?*anyopaque, *mcp_server.Server, std.Io, std.mem.Allocator, ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return struct {
        /// Bridges the typed helper into the callback signature expected by the MCP adapter.
        fn call(user_data: ?*anyopaque, server: *mcp_server.Server, io: std.Io, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
            const runtime: RuntimePtr = @ptrCast(@alignCast(user_data orelse return tool_errors.result(allocator, .{
                .tool = spec.name,
                .operation = "dispatch_tool",
                .phase = "runtime_lookup",
                .code = "runtime_unavailable",
                .category = "server_state",
                .resolution = "Restart zigars; the MCP server registered this tool without attaching runtime state.",
            })));
            const started_ns = std.Io.Clock.now(.real, io).nanoseconds;
            if (try mcp_args.validateToolArgs(allocator, spec, args)) |validation_error| {
                record_call(runtime, spec.name, elapsedMs(io, started_ns), validation_error.is_error, server.active_correlation);
                return validation_error;
            }
            // Expose this call's protocol client and cancellation token on the
            // runtime for the handler's duration, then clear them. The defers
            // MUST sit at function scope (not inside the comptime `if` blocks):
            // a defer declared inside a block runs at that block's end, which
            // would revert the binding before `handler` runs and leave the
            // handler with a null token — defeating cancellation entirely.
            var protocol_adapter = mcp_server.ProtocolClientAdapter.init(server, io);
            if (comptime runtimeHasProtocolClient(RuntimePtr)) {
                runtime.protocol_client = protocol_adapter.port();
            }
            defer if (comptime runtimeHasProtocolClient(RuntimePtr)) {
                runtime.protocol_client = null;
            };
            if (comptime runtimeHasActiveCancellation(RuntimePtr)) {
                runtime.active_cancellation = server.currentCancellationToken();
            }
            defer if (comptime runtimeHasActiveCancellation(RuntimePtr)) {
                runtime.active_cancellation = null;
            };
            const result = handler(runtime, allocator, args) catch |err| {
                record_call(runtime, spec.name, elapsedMs(io, started_ns), true, server.active_correlation);
                return err;
            };
            record_call(runtime, spec.name, elapsedMs(io, started_ns), result.is_error, server.active_correlation);
            return result;
        }
    }.call;
}

/// Returns true when the registered runtime can accept a per-call MCP protocol
/// client port. Duck-typed on the field so test runtimes can opt out by omitting it.
fn runtimeHasProtocolClient(comptime RuntimePtr: type) bool {
    const info = @typeInfo(RuntimePtr);
    if (info != .pointer) return false;
    return @hasField(info.pointer.child, "protocol_client");
}

/// Returns true when the registered runtime accepts a per-call cancellation
/// token. Duck-typed on the field so test runtimes can opt out by omitting it.
fn runtimeHasActiveCancellation(comptime RuntimePtr: type) bool {
    const info = @typeInfo(RuntimePtr);
    if (info != .pointer) return false;
    return @hasField(info.pointer.child, "active_cancellation");
}

/// Returns non-negative elapsed wall time in milliseconds. The real clock is not
/// guaranteed monotonic, so a backward jump clamps to 0 instead of underflowing.
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
        /// Returns an MCP callback that invokes a typed tool adapter handler.
        fn handler(_: *Runtime, _: std.mem.Allocator, _: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
            return @as(mcp.tools.ToolError, error.ExecutionFailed);
        }

        /// Records whether a test handler invocation failed.
        fn record(runtime: *Runtime, _: []const u8, _: u64, is_error: bool, _: anytype) void {
            runtime.calls += 1;
            runtime.last_error = is_error;
        }
    };

    var runtime = Runtime{};
    const handler = mcpHandler(*Runtime, manifest.entries[0].meta, Stub.handler, Stub.record);
    var server = mcp_server.Server.init(std.testing.allocator, .{ .name = "test", .version = "1" });
    defer server.deinit();
    try std.testing.expectError(error.ExecutionFailed, handler(&runtime, &server, std.testing.io, std.testing.allocator, null));
    try std.testing.expectEqual(@as(usize, 1), runtime.calls);
    try std.testing.expect(runtime.last_error);
}
