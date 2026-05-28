//! Bootstraps process-scoped dependencies and starts the selected MCP transport.
const std = @import("std");

const config_mod = @import("config.zig");
const audit = @import("../infra/observability/audit.zig");
const cli_adapter = @import("../adapters/cli/root.zig");
const command_mod = @import("../infra/process/command.zig");
const doctor_usecase = @import("../app/usecases/environment/doctor.zig");
const logging = @import("../infra/observability/logging.zig");
const mcp_server = @import("../adapters/mcp/server.zig");
const runtime_mod = @import("runtime_state.zig");
const mcp_registration = @import("../adapters/mcp/registration.zig");
const mcp_prompts = @import("../adapters/mcp/prompts.zig");
const mcp_resources = @import("../adapters/mcp/resources.zig");
const trust_usecase = @import("../app/usecases/environment/trust.zig");
const runtime_ports_mod = @import("runtime_ports.zig");
const workspace_mod = @import("../infra/workspace/workspace.zig");
const LspClient = @import("../infra/zls/client.zig").LspClient;
const DocumentState = @import("../infra/zls/documents.zig").DocumentState;
const version = @import("../manifest/version.zig").string;
const ZlsProcess = @import("../infra/zls/process.zig").ZlsProcess;
const zls_session = @import("../infra/zls/session.zig");

const App = runtime_mod.App;

/// Initializes runtime state and serves either explicit CLI mode or the default MCP transport.
pub fn run(init: std.process.Init) !cli_adapter.ExitCode {
    const allocator = init.gpa;
    var args_arena_state = std.heap.ArenaAllocator.init(allocator);
    defer args_arena_state.deinit();
    const args_arena = args_arena_state.allocator();
    const args = try init.minimal.args.toSlice(args_arena);
    if (cli_adapter.isInvocation(args)) return runCli(init, args);

    var startup = StartupTimeline.init(init.io);

    const config_started = startup.begin();
    var cfg = config_mod.parse(allocator, init.io, args) catch |err| return handleConfigParseError(init.io, err);
    startup.end("config_parse", config_started);
    const logger = logging.Logger.stderr(init.io);
    var cfg_owned = true;
    defer if (cfg_owned) cfg.deinit(allocator);

    const workspace_started = startup.begin();
    var ws = try workspace_mod.Workspace.init(allocator, init.io, cfg.workspace, cfg.cache_dir);
    startup.end("workspace_resolution", workspace_started);
    defer ws.deinit();

    // ZLS process/client/document state are infra-owned and must outlive app runtime references.
    var zls_proc: ?ZlsProcess = null;
    defer if (zls_proc) |*proc| proc.deinit();
    var lsp_client: ?LspClient = null;
    defer if (lsp_client) |*client| client.deinit();
    var doc_state: ?DocumentState = null;
    defer if (doc_state) |*docs_state| docs_state.deinit();

    // App captures shared runtime state; deinit closes caches/sessions in reverse dependency order.
    const runtime_started = startup.begin();
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
    startup.end("runtime_state_init", runtime_started);
    cfg_owned = false;
    defer runtime.deinit();
    startup.replay(&runtime.observability);

    var audit_writer: ?audit.Writer = null;
    defer if (audit_writer) |*writer| writer.deinit(allocator);
    if (runtime.config.audit_log_path) |audit_path| {
        const audit_started = startup.begin();
        const resolved_audit_path = try runtime.workspace.resolveOutput(audit_path);
        defer allocator.free(resolved_audit_path);
        if (runtime.config.audit_log_mode == .full) {
            try stderrPrint(init.io, "zigars: WARNING: --audit-log-mode full records raw MCP payloads, including user prompts and tool arguments. Use only for intentional local forensic debugging.\n", .{});
        }
        audit_writer = try audit.Writer.init(allocator, init.io, resolved_audit_path, runtime.config.audit_log_mode);
        runtime.observability.recordAuditEnabled(runtime.config.audit_log_mode.text(), audit_writer.?.path);
        startup.end("audit_log_setup", audit_started);
        runtime.observability.recordStartupPhase("audit_log_setup", startup.lastStartMs(), startup.lastDurationMs());
    }

    runtime.logger.info("main", "workspace: {s}", .{ws.root});
    const preflight_started = startup.begin();
    warnOnZigVersionPreflight(&runtime);
    startup.end("zig_version_preflight", preflight_started);
    runtime.observability.recordStartupPhase("zig_version_preflight", startup.lastStartMs(), startup.lastDurationMs());
    const zls_started = startup.begin();
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
    startup.end("zls_spawn_initialize", zls_started);
    runtime.observability.recordStartupPhase("zls_spawn_initialize", startup.lastStartMs(), startup.lastDurationMs());
    logZlsSession(runtime.logger, runtime.zls.client != null, runtime.zls.status);

    const server_started = startup.begin();
    var server = mcp_server.Server.init(allocator, .{
        .name = "zigars",
        .version = version,
        .title = "Zigars",
        .description = "Comprehensive deterministic MCP server for Zig application development.",
        .instructions = "Use zigars tools for Zig docs, build/test/check, formatting, static analysis, linting, profiling, and flamegraph workflows. Source writes require apply=true.",
        .trustManifestUri = trust_usecase.trust_manifest_uri,
    });
    defer server.deinit();
    server.setObservability(&runtime.observability);
    server.setStartupStart(startup.started_ns);
    if (audit_writer) |*writer| server.setAuditWriter(writer);
    startup.end("server_state_init", server_started);
    runtime.observability.recordStartupPhase("server_state_init", startup.lastStartMs(), startup.lastDurationMs());

    const registration_started = startup.begin();
    server.enableLogging();
    try mcp_registration.registerTools(&server, &runtime, runtime_ports_mod.RuntimePorts, runtime_ports_mod.Options, recordMcpToolCall);
    startup.end("manifest_tool_registration", registration_started);
    runtime.observability.recordStartupPhase("manifest_tool_registration", startup.lastStartMs(), startup.lastDurationMs());

    const resource_prompt_started = startup.begin();
    var runtime_ports = runtime_ports_mod.RuntimePorts.init(&runtime, .{ .workspace_read_resolution = .input });
    try mcp_resources.registerResources(&server, &runtime_ports);
    try mcp_prompts.registerPrompts(&server, &runtime_ports);
    startup.end("resource_prompt_registration", resource_prompt_started);
    runtime.observability.recordStartupPhase("resource_prompt_registration", startup.lastStartMs(), startup.lastDurationMs());

    const capability_started = startup.begin();
    server.enableCompletions();
    server.enableResourceSubscriptions();
    server.enableTasks(&runtime.runtime_ux);
    startup.end("server_ready", capability_started);
    runtime.observability.recordStartupPhase("server_ready", startup.lastStartMs(), startup.lastDurationMs());

    // Transport selection is the final bootstrap contract boundary before entering request serving.
    switch (cfg.transport) {
        .stdio => try server.run(init.io, allocator, .stdio),
        .http => try server.run(init.io, allocator, .{ .http = .{ .host = cfg.host, .port = cfg.port } }),
    }
    return .success;
}

/// Executes explicit CLI mode as a one-shot JSON reporting surface over app use cases.
fn runCli(init: std.process.Init, args: []const []const u8) !cli_adapter.ExitCode {
    const allocator = init.gpa;
    const invocation = cli_adapter.parse(args) catch |err| {
        cli_adapter.writeParseDiagnostic(init.io, err) catch {};
        return cli_adapter.parseErrorExitCode(err);
    };

    var cfg = configFromCli(allocator, init.io, invocation) catch |err| {
        cli_adapter.stderrPrint(init.io, "zigars cli: invalid configuration: {s}\n", .{@errorName(err)}) catch {};
        return cliConfigExitCode(err);
    };
    var cfg_owned = true;
    defer if (cfg_owned) cfg.deinit(allocator);

    var ws = workspace_mod.Workspace.init(allocator, init.io, cfg.workspace, cfg.cache_dir) catch |err| {
        cli_adapter.stderrPrint(init.io, "zigars cli: workspace error: {s}\n", .{@errorName(err)}) catch {};
        return cliWorkspaceExitCode(err);
    };
    defer ws.deinit();

    var runtime = App{
        .allocator = allocator,
        .io = init.io,
        .logger = logging.Logger.disabled(),
        .config = cfg,
        .workspace = ws,
    };
    cfg_owned = false;
    defer runtime.deinit();

    var runtime_ports = runtime_ports_mod.RuntimePorts.init(&runtime, .{ .workspace_read_resolution = .input });
    var json_arena_state = std.heap.ArenaAllocator.init(allocator);
    defer json_arena_state.deinit();
    const json_allocator = json_arena_state.allocator();

    const value = cli_adapter.renderValue(json_allocator, runtime_ports.context(), invocation) catch |err| {
        cli_adapter.stderrPrint(init.io, "zigars cli: fatal internal error while rendering {s}: {s}\n", .{ invocation.command.label(), @errorName(err) }) catch {};
        return .fatal_internal;
    };
    const bytes = cli_adapter.stringifyAlloc(json_allocator, value) catch |err| {
        cli_adapter.stderrPrint(init.io, "zigars cli: fatal internal error while serializing {s}: {s}\n", .{ invocation.command.label(), @errorName(err) }) catch {};
        return .fatal_internal;
    };
    cli_adapter.stdoutWrite(init.io, bytes) catch |err| {
        cli_adapter.stderrPrint(init.io, "zigars cli: fatal internal error while writing stdout: {s}\n", .{@errorName(err)}) catch {};
        return .fatal_internal;
    };
    return .success;
}

/// Reuses the server config parser for shared CLI process configuration.
fn configFromCli(allocator: std.mem.Allocator, io: std.Io, invocation: cli_adapter.Invocation) !config_mod.Config {
    var config_args: std.ArrayList([]const u8) = .empty;
    defer config_args.deinit(allocator);
    try cli_adapter.appendConfigArgs(allocator, &config_args, invocation);
    return config_mod.parse(allocator, io, config_args.items);
}

fn cliConfigExitCode(err: anyerror) cli_adapter.ExitCode {
    return switch (err) {
        error.MissingValue,
        error.UnknownArgument,
        error.InvalidPort,
        error.InvalidTimeout,
        error.InvalidTransport,
        error.InvalidAuditLogMode,
        error.InvalidAuditLogPath,
        error.UnsafeHttpHost,
        => .invalid_args,
        else => .fatal_internal,
    };
}

fn cliWorkspaceExitCode(err: anyerror) cli_adapter.ExitCode {
    return switch (err) {
        error.OutOfMemory => .fatal_internal,
        else => .workspace_error,
    };
}

const StartupTimeline = struct {
    io: std.Io,
    started_ns: i128,
    phases: [16]Phase = [_]Phase{.{}} ** 16,
    phase_count: usize = 0,
    last_start_ms: u64 = 0,
    last_duration_ms: u64 = 0,

    const Phase = struct {
        name: []const u8 = "",
        start_ms: u64 = 0,
        duration_ms: u64 = 0,
    };

    fn init(io: std.Io) StartupTimeline {
        return .{
            .io = io,
            .started_ns = monotonicNowNs(io),
        };
    }

    fn begin(self: *StartupTimeline) i128 {
        return monotonicNowNs(self.io);
    }

    fn end(self: *StartupTimeline, name: []const u8, phase_started_ns: i128) void {
        const now_ns = monotonicNowNs(self.io);
        const phase = Phase{
            .name = name,
            .start_ms = elapsedMs(self.started_ns, phase_started_ns),
            .duration_ms = elapsedMs(phase_started_ns, now_ns),
        };
        self.last_start_ms = phase.start_ms;
        self.last_duration_ms = phase.duration_ms;
        if (self.phase_count < self.phases.len) {
            self.phases[self.phase_count] = phase;
            self.phase_count += 1;
        }
    }

    fn replay(self: *const StartupTimeline, state: anytype) void {
        for (self.phases[0..self.phase_count]) |phase| {
            state.recordStartupPhase(phase.name, phase.start_ms, phase.duration_ms);
        }
    }

    fn lastStartMs(self: *const StartupTimeline) u64 {
        return self.last_start_ms;
    }

    fn lastDurationMs(self: *const StartupTimeline) u64 {
        return self.last_duration_ms;
    }
};

fn monotonicNowNs(io: std.Io) i128 {
    return std.Io.Clock.now(.awake, io).nanoseconds;
}

fn elapsedMs(start_ns: i128, end_ns: i128) u64 {
    if (end_ns <= start_ns) return 0;
    const milliseconds = @divTrunc(end_ns - start_ns, std.time.ns_per_ms);
    return std.math.cast(u64, milliseconds) orelse std.math.maxInt(u64);
}

/// Emits a startup warning when the configured Zig cannot satisfy build.zig.zon.
fn warnOnZigVersionPreflight(runtime: *App) void {
    const build_zon = runtime.workspace.readFileAlloc(runtime.io, "build.zig.zon", 256 * 1024) catch |err| switch (err) {
        error.FileNotFound, error.PathOutsideWorkspace, error.EmptyPath => return,
        else => {
            runtime.logger.warn("main", "zig_version_preflight unavailable: could not read build.zig.zon ({s})", .{@errorName(err)});
            return;
        },
    };
    defer runtime.allocator.free(build_zon);
    const required_minimum = doctor_usecase.minimumZigVersionFromBuildZon(build_zon) orelse return;

    const result = command_mod.runWithOutputLimit(
        runtime.allocator,
        runtime.io,
        runtime.workspace.root,
        &.{ runtime.config.zig_path, "version" },
        @min(runtime.config.timeout_ms, 5000),
        64 * 1024,
        64 * 1024,
    ) catch |err| {
        const preflight = doctor_usecase.zigVersionPreflight(runtime.allocator, .{
            .zig_path = runtime.config.zig_path,
            .required_minimum = required_minimum,
            .unavailable_reason = @errorName(err),
        }) catch return;
        defer preflight.deinit(runtime.allocator);
        runtime.logger.warn("main", "zig_version_preflight {s}: {s}", .{ preflight.status, preflight.resolution });
        return;
    };
    defer result.deinit(runtime.allocator);

    const stderr_reason = std.mem.trim(u8, if (result.stderr.len > 0) result.stderr else termName(result.term), " \t\r\n");
    const preflight = doctor_usecase.zigVersionPreflight(runtime.allocator, .{
        .zig_path = runtime.config.zig_path,
        .observed_version = std.mem.trim(u8, result.stdout, " \t\r\n"),
        .required_minimum = required_minimum,
        .unavailable_reason = if (result.succeeded()) null else stderr_reason,
    }) catch return;
    defer preflight.deinit(runtime.allocator);
    const should_warn = if (preflight.ok) |ok| !ok else true;
    if (should_warn) {
        runtime.logger.warn("main", "zig_version_preflight {s}: {s}", .{ preflight.status, preflight.resolution });
    }
}

/// Stable process termination label for startup preflight diagnostics.
fn termName(term: std.process.Child.Term) []const u8 {
    return switch (term) {
        .exited => "exited",
        .signal => "signal",
        .stopped => "stopped",
        .unknown => "unknown",
    };
}

/// MCP tool callbacks update runtime observability counters without crossing into app use-case logic.
fn recordMcpToolCall(runtime: *App, name: []const u8, duration_ms: u64, is_error: bool, correlation: anytype) void {
    if (correlation) |context| {
        runtime.observability.recordToolCallWithCorrelation(name, duration_ms, is_error, .{
            .mcp_request_id_type = context.request_id.typeName(),
            .mcp_request_id_value = context.request_id.valueString(),
            .trace_id = context.traceId(),
            .span_id = context.spanId(),
            .parent_span_id = context.parent_span_id,
            .tool_call_id = context.toolCallId(),
        });
        return;
    }
    runtime.observability.recordToolCall(name, duration_ms, is_error);
}

/// Config parse exits are normalized at the process boundary so transports never start on invalid startup state.
fn handleConfigParseError(io: std.Io, err: anyerror) !cli_adapter.ExitCode {
    switch (err) {
        error.HelpRequested => {
            try stderrPrint(io, "{s}", .{config_mod.usage()});
            return .success;
        },
        error.VersionRequested => {
            try stderrPrint(io, "zigars " ++ version ++ "\n", .{});
            return .success;
        },
        else => {
            try stderrPrint(io, "zigars: {s}\n\n{s}", .{ @errorName(err), config_mod.usage() });
            return err;
        },
    }
}

/// Runtime logs only successful ZLS session state to avoid duplicate "disabled" logs from startup failures.
fn logZlsSession(logger: logging.Logger, client_present: bool, status: []const u8) void {
    if (client_present) {
        logger.info("main", "zls session: {s}", .{status});
    }
}

/// Writes directly to stderr so startup diagnostics remain visible before server logging is fully active.
fn stderrPrint(io: std.Io, comptime fmt: []const u8, args: anytype) !void {
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.File.stderr().writer(io, &buffer);
    try writer.interface.print(fmt, args);
    try writer.interface.flush();
}

test "bootstrap runtime handles config parse exits" {
    try std.testing.expectEqual(cli_adapter.ExitCode.success, try handleConfigParseError(std.testing.io, error.HelpRequested));
    try std.testing.expectEqual(cli_adapter.ExitCode.success, try handleConfigParseError(std.testing.io, error.VersionRequested));
    try std.testing.expectError(error.UnknownArgument, handleConfigParseError(std.testing.io, error.UnknownArgument));
}

test "bootstrap cli maps configuration and workspace failures to stable exit codes" {
    try std.testing.expectEqual(cli_adapter.ExitCode.invalid_args, cliConfigExitCode(error.InvalidTimeout));
    try std.testing.expectEqual(cli_adapter.ExitCode.fatal_internal, cliConfigExitCode(error.OutOfMemory));
    try std.testing.expectEqual(cli_adapter.ExitCode.workspace_error, cliWorkspaceExitCode(error.PathOutsideWorkspace));
    try std.testing.expectEqual(cli_adapter.ExitCode.workspace_error, cliWorkspaceExitCode(error.FileNotFound));
    try std.testing.expectEqual(cli_adapter.ExitCode.fatal_internal, cliWorkspaceExitCode(error.OutOfMemory));
}

test "bootstrap runtime zls session logging helper is side-effect safe when disabled" {
    logZlsSession(logging.Logger.disabled(), false, "disabled");
    logZlsSession(logging.Logger.disabled(), true, "connected");
}

test "bootstrap runtime stderr printer flushes formatted text" {
    try stderrPrint(std.testing.io, "zigars runtime stderr smoke {d}\n", .{@as(u8, 1)});
}
