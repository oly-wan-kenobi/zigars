const std = @import("std");

const config_mod = @import("config.zig");
const logging = @import("../infra/observability/logging.zig");
const mcp_server = @import("../adapters/mcp/server.zig");
const runtime_mod = @import("runtime_state.zig");
const mcp_registration = @import("../adapters/mcp/registration.zig");
const mcp_prompts = @import("../adapters/mcp/prompts.zig");
const mcp_resources = @import("../adapters/mcp/resources.zig");
const runtime_ports_mod = @import("runtime_ports.zig");
const workspace_mod = @import("../infra/workspace/workspace.zig");
const LspClient = @import("../infra/zls/client.zig").LspClient;
const DocumentState = @import("../infra/zls/documents.zig").DocumentState;
const version = @import("../manifest/version.zig").string;
const ZlsProcess = @import("../infra/zls/process.zig").ZlsProcess;
const zls_session = @import("../infra/zls/session.zig");

const App = runtime_mod.App;

pub fn run(init: std.process.Init) !void {
    const allocator = init.gpa;

    var args_arena_state = std.heap.ArenaAllocator.init(allocator);
    defer args_arena_state.deinit();
    const args_arena = args_arena_state.allocator();
    const args = try init.minimal.args.toSlice(args_arena);

    var cfg = config_mod.parse(allocator, init.io, args) catch |err| switch (err) {
        error.HelpRequested => {
            try stderrPrint(init.io, "{s}", .{config_mod.usage()});
            return;
        },
        error.VersionRequested => {
            try stderrPrint(init.io, "zigar " ++ version ++ "\n", .{});
            return;
        },
        else => {
            try stderrPrint(init.io, "zigar: {s}\n\n{s}", .{ @errorName(err), config_mod.usage() });
            return err;
        },
    };
    const logger = logging.Logger.stderr(init.io);
    var cfg_owned = true;
    defer if (cfg_owned) cfg.deinit(allocator);

    var ws = try workspace_mod.Workspace.init(allocator, init.io, cfg.workspace, cfg.cache_dir);
    defer ws.deinit();

    var zls_proc: ?ZlsProcess = null;
    defer if (zls_proc) |*proc| proc.deinit();
    var lsp_client: ?LspClient = null;
    defer if (lsp_client) |*client| client.deinit();
    var doc_state: ?DocumentState = null;
    defer if (doc_state) |*docs_state| docs_state.deinit();

    var runtime = App{
        .allocator = allocator,
        .io = init.io,
        .logger = logger,
        .config = cfg,
        .workspace = ws,
        .zls_slots = .{
            .process = &zls_proc,
            .client = &lsp_client,
            .documents = &doc_state,
        },
    };
    cfg_owned = false;
    defer runtime.deinit();

    runtime.logger.info("main", "workspace: {s}", .{ws.root});
    zls_session.start(&runtime.zls, runtime.zls_slots, .{
        .allocator = runtime.allocator,
        .io = runtime.io,
        .workspace_root = runtime.workspace.root,
        .zls_path = runtime.config.zls_path,
        .zls_timeout_ms = runtime.config.zls_timeout_ms,
        .logger = runtime.logger,
        .observability = &runtime.observability,
    }) catch |err| {
        runtime.zls.status = @errorName(err);
        runtime.zls.last_failure = @errorName(err);
        runtime.observability.recordZlsStatus(runtime.zls.status, runtime.zls.last_failure, runtime.zls.restart_attempts);
        runtime.logger.warn("main", "zls disabled: {}", .{err});
    };
    if (runtime.zls.client != null) {
        runtime.logger.info("main", "zls session: {s}", .{runtime.zls.status});
    }

    var server = mcp_server.Server.init(allocator, .{
        .name = "zigar",
        .version = version,
        .title = "Zigar",
        .description = "Comprehensive deterministic MCP server for Zig application development.",
        .instructions = "Use zigar tools for Zig docs, build/test/check, formatting, static analysis, linting, profiling, and flamegraph workflows. Source writes require apply=true.",
    });
    defer server.deinit();

    server.enableLogging();
    try mcp_registration.registerTools(&server, &runtime, runtime_ports_mod.RuntimePorts, runtime_ports_mod.Options, recordMcpToolCall);
    var runtime_ports = runtime_ports_mod.RuntimePorts.init(&runtime, .{ .workspace_read_resolution = .input });
    try mcp_resources.registerResources(&server, &runtime_ports);
    try mcp_prompts.registerPrompts(&server, &runtime_ports);
    server.enableCompletions();
    server.enableResourceSubscriptions();
    server.enableTasks(&runtime.runtime_ux);

    switch (cfg.transport) {
        .stdio => try server.run(init.io, allocator, .stdio),
        .http => try server.run(init.io, allocator, .{ .http = .{ .host = cfg.host, .port = cfg.port } }),
    }
}

fn recordMcpToolCall(runtime: *App, name: []const u8, duration_ms: u64, is_error: bool) void {
    runtime.observability.recordToolCall(name, duration_ms, is_error);
}

fn stderrPrint(io: std.Io, comptime fmt: []const u8, args: anytype) !void {
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.File.stderr().writer(io, &buffer);
    try writer.interface.print(fmt, args);
    try writer.interface.flush();
}

test "bootstrap runtime wires runtime lifecycle types" {
    try std.testing.expect(@sizeOf(App) > 0);
    try std.testing.expect(@sizeOf(LspClient) > 0);
    try std.testing.expect(@sizeOf(DocumentState) > 0);
    try std.testing.expect(@sizeOf(ZlsProcess) > 0);
    try std.testing.expect(std.mem.indexOf(u8, config_mod.usage(), "zigar") != null);
}
