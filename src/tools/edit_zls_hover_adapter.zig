const std = @import("std");
const mcp = @import("mcp");
const zigar = @import("zigar");

const app_context = zigar.app.context;
const app_ports = zigar.app.ports;
const bootstrap_app_context = zigar.bootstrap.app_context;
const code_intel_usecase = zigar.app.usecases.zls.code_intel;
const infra_zls_gateway = zigar.infra.zls.gateway;
const common = @import("common.zig");

const App = common.App;
const argInt = common.argInt;
const argString = common.argString;
const backendErrorResult = common.backendErrorResult;
const lspStructuredTool = common.lspStructuredTool;
const missingArgumentResult = common.missingArgumentResult;
const toolErrorFromError = common.toolErrorFromError;
const unsupportedCapability = common.unsupportedCapability;
const zlsSetupErrorResult = common.zlsSetupErrorResult;
const zlsUnavailable = common.zlsUnavailable;

pub fn zigHover(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const method = "textDocument/hover";
    var runtime_gateway = infra_zls_gateway.RuntimeGateway{ .app = a };
    const zls_ctx = zlsContext(a, runtime_gateway.port()) catch |err| return toolErrorFromError(allocator, .{
        .tool = method,
        .operation = method,
        .phase = "build_app_context",
        .code = "zls_context_unavailable",
        .category = "configuration",
        .resolution = "The ZLS code-intelligence use case requires a ZLS gateway port from the runtime bridge.",
    }, err);

    var outcome = try code_intel_usecase.position(allocator, zls_ctx, .{
        .method = method,
        .file = argString(args, "file"),
        .content = argString(args, "content"),
        .line = argInt(args, "line", 0),
        .character = argInt(args, "character", 0),
    });
    defer outcome.deinit(allocator);

    return switch (outcome) {
        .ok => |response| lspStructuredTool(allocator, response.method, response.payload),
        .err => |failure| failureResult(a, allocator, method, argString(args, "file"), failure),
    };
}

fn zlsContext(a: *App, gateway: app_ports.ZlsGateway) app_context.ContextError!app_context.ZlsContext {
    const ctx = bootstrap_app_context.fromRuntime(a, .{ .zls_gateway = gateway });
    return ctx.zls();
}

fn failureResult(a: *App, allocator: std.mem.Allocator, method: []const u8, file: ?[]const u8, failure: code_intel_usecase.Failure) mcp.tools.ToolError!mcp.tools.ToolResult {
    return switch (failure) {
        .unavailable => zlsUnavailable(a, allocator),
        .unsupported_capability => |capability| unsupportedCapability(allocator, method, capability),
        .missing_file => missingArgumentResult(allocator, method, "file", "string"),
        .sync_failed => |port_failure| syncFailureResult(a, allocator, method, file, port_failure.err),
        .request_failed => |port_failure| backendErrorResult(allocator, "zls", method, port_failure.err, "ZLS request failed; check zigar_workspace_info and zigar_doctor for session status"),
    };
}

fn syncFailureResult(a: *App, allocator: std.mem.Allocator, method: []const u8, file: ?[]const u8, err: app_ports.PortError) mcp.tools.ToolError!mcp.tools.ToolResult {
    return switch (err) {
        error.Unavailable => zlsUnavailable(a, allocator),
        error.PathOutsideWorkspace, error.EmptyPath, error.DocumentTooLarge, error.OpenDocumentLimitExceeded, error.RetainedContentLimitExceeded => zlsSetupErrorResult(a, allocator, method, file, err),
        else => backendErrorResult(allocator, "zls", method, err, "confirm --zls-path points to a compatible ZLS binary and retry; command-backed Zig tools remain available without ZLS"),
    };
}
