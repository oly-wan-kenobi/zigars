const std = @import("std");
const mcp = @import("mcp");
const zigar = @import("zigar");

const config_mod = zigar.config;
const logging = zigar.logging;
const runtime_mod = zigar.runtime;
const workspace_mod = zigar.workspace;
const zls_session = zigar.zls_session;
const server_mod = @import("server.zig");

const version = zigar.version.string;
const App = runtime_mod.App;
const LspClient = zigar.lsp_client.LspClient;
const DocumentState = zigar.document_state.DocumentState;
const ZlsProcess = zigar.zls_process.ZlsProcess;

pub fn main(init: std.process.Init) !void {
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

    var ws = try workspace_mod.Workspace.init(allocator, init.io, cfg.workspace, cfg.cache_dir, cfg.strict_workspace);
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
        .zls_process_slot = &zls_proc,
        .lsp_client_slot = &lsp_client,
        .doc_state_slot = &doc_state,
    };
    cfg_owned = false;
    defer runtime.deinit();

    runtime.logger.info("main", "workspace: {s}", .{ws.root});
    zls_session.start(&runtime, &zls_proc, &lsp_client, &doc_state) catch |err| {
        runtime.zls_status = @errorName(err);
        runtime.zls_last_failure = @errorName(err);
        runtime.logger.warn("main", "zls disabled: {}", .{err});
    };
    if (runtime.lsp_client != null) {
        runtime.logger.info("main", "zls session: {s}", .{runtime.zls_status});
    }

    var server = mcp.Server.init(allocator, .{
        .name = "zigar",
        .version = version,
        .title = "Zigar",
        .description = "Comprehensive deterministic MCP server for Zig application development.",
        .instructions = "Use zigar tools for Zig docs, build/test/check, formatting, static analysis, linting, profiling, and flamegraph workflows. Source writes require apply=true.",
    });
    defer server.deinit();

    server.enableLogging();
    server.enableTasks();
    try server_mod.registerTools(&server, &runtime);
    try server_mod.registerResources(&server, &runtime);
    try server_mod.registerPrompts(&server, &runtime);

    switch (cfg.transport) {
        .stdio => try server.run(init.io, allocator, .stdio),
        .http => try server.run(init.io, allocator, .{ .http = .{ .host = cfg.host, .port = cfg.port } }),
    }
}

fn stderrPrint(io: std.Io, comptime fmt: []const u8, args: anytype) !void {
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.File.stderr().writer(io, &buffer);
    try writer.interface.print(fmt, args);
    try writer.interface.flush();
}

test "executable embeds package version" {
    try std.testing.expect(version.len > 0);
    try std.testing.expect(std.mem.indexOfScalar(u8, version, '.') != null);
}

test "executable module links runtime lifecycle types" {
    try std.testing.expect(@sizeOf(App) > 0);
    try std.testing.expect(@sizeOf(LspClient) > 0);
    try std.testing.expect(@sizeOf(DocumentState) > 0);
    try std.testing.expect(@sizeOf(ZlsProcess) > 0);
}

test "executable usage names the command" {
    try std.testing.expect(std.mem.indexOf(u8, config_mod.usage(), "zigar") != null);
}

test {
    _ = @import("tools/edit_zls_edits_tests.zig");
    _ = @import("tools/zls_document.zig");
}
