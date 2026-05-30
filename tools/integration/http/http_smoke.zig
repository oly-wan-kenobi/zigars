//! HTTP smoke entrypoint: spins up a short-lived zigars server, runs the full
//! HTTP transport assertion suite, and shuts it down cleanly. Transport-level
//! checks (method rejection, body size limits, malformed JSON, initialize
//! handshake, trust manifest URI) live here; per-tool-family result path checks
//! are delegated to focused sibling modules to keep this file readable.

const std = @import("std");
const cli_io = @import("../../common/cli_io.zig");
const coverage_config = @import("../../coverage/coverage_config.zig");
const http_smoke_tools_list = @import("http_smoke_tools_list.zig");
const http_tool_contract_smoke = @import("http_tool_contract_smoke.zig");
const runtime_ux_smoke = @import("http_runtime_ux_smoke.zig");
const smoke = @import("../smoke_support.zig");
const Io = std.Io;
const JsonValue = std.json.Value;
const flagValue = cli_io.flagValue;
const parseJsonFile = cli_io.parseJsonFile;
const stderrPrint = cli_io.stderrPrint;
const stdoutWrite = cli_io.stdoutWrite;
const unexpectedArgument = cli_io.unexpectedArgument;
const valueAt = smoke.valueAt;

/// Parsed options for the HTTP smoke driver.
/// Transport-level assertions live here; tool-result contract checks are
/// delegated to focused sibling modules so this entrypoint stays readable.
const HttpSmokeOptions = struct {
    binary: []const u8 = "zig-out/bin/zigars",
    workspace: []const u8 = ".",
    expect: []const u8 = "tests/fixtures/http-smoke.expect.json",
    server_kcov_path: []const u8 = "kcov",
    server_kcov_dir: ?[]const u8 = null,
};

/// Runs the HTTP smoke suite against a short-lived local zigars server.
pub fn run(allocator: std.mem.Allocator, io: Io, args: []const []const u8) !void {
    var options: HttpSmokeOptions = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--binary")) {
            options.binary = try flagValue(args, &i, io, "http-smoke", "--binary", "http-smoke [--binary <path>] [--workspace <path>] [--expect <path>]");
        } else if (std.mem.eql(u8, args[i], "--workspace")) {
            options.workspace = try flagValue(args, &i, io, "http-smoke", "--workspace", "http-smoke [--binary <path>] [--workspace <path>] [--expect <path>]");
        } else if (std.mem.eql(u8, args[i], "--expect")) {
            options.expect = try flagValue(args, &i, io, "http-smoke", "--expect", "http-smoke [--binary <path>] [--workspace <path>] [--expect <path>]");
        } else if (std.mem.eql(u8, args[i], "--server-kcov-path")) {
            options.server_kcov_path = try flagValue(args, &i, io, "http-smoke", "--server-kcov-path", "http-smoke [--binary <path>] [--workspace <path>] [--expect <path>] [--server-kcov-path <path>] [--server-kcov-dir <path>]");
        } else if (std.mem.eql(u8, args[i], "--server-kcov-dir")) {
            options.server_kcov_dir = try flagValue(args, &i, io, "http-smoke", "--server-kcov-dir", "http-smoke [--binary <path>] [--workspace <path>] [--expect <path>] [--server-kcov-path <path>] [--server-kcov-dir <path>]");
        } else {
            return unexpectedArgument(io, "http-smoke", args[i], "http-smoke [--binary <path>] [--workspace <path>] [--expect <path>] [--server-kcov-path <path>] [--server-kcov-dir <path>]");
        }
    }

    const expected = try parseJsonFile(allocator, io, options.expect);
    defer expected.deinit();

    var scenarios: usize = 0;
    // Reserve a verified-free loopback port (LOW-9): the port is derived
    // deterministically from the process id rather than the wall clock, and is
    // bind-checked at selection time so a lingering socket from a previous run is
    // skipped instead of flaking. A bounded spawn retry absorbs the residual
    // bind/rebind race between releasing the probe socket and the child binding.
    const started = try startHttpServer(allocator, io, options);
    const port = started.port;
    var child = started.child;
    var child_done = false;
    defer if (!child_done) child.kill(io);
    try http_smoke_tools_list.assertRequiredTools(allocator, io, port, expected.value);
    scenarios += 1;
    try smoke.assertHttpRpcContains(allocator, io, port, "{\"jsonrpc\":\"2.0\",\"id\":42,\"method\":\"resources/read\",\"params\":{\"uri\":\"zigars://trust/manifest\"}}", "zigars_trust_manifest", &scenarios);
    try smoke.assertRawHttpContains(
        allocator,
        io,
        port,
        "GET / HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n",
        "405",
        &scenarios,
    );
    try smoke.assertRawHttpContains(
        allocator,
        io,
        port,
        "POST / HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n",
        "Content-Length required",
        &scenarios,
    );
    try smoke.assertRawHttpContains(
        allocator,
        io,
        port,
        "POST / HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
        "Empty JSON-RPC payload",
        &scenarios,
    );
    try smoke.assertRawHttpContains(
        allocator,
        io,
        port,
        "POST / HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 4194305\r\nConnection: close\r\n\r\n",
        "Request body too large",
        &scenarios,
    );
    try smoke.assertRawHttpContains(
        allocator,
        io,
        port,
        "POST / HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 8\r\nConnection: close\r\n\r\n{}",
        "Failed to read request body",
        &scenarios,
    );
    try smoke.assertRawHttpContains(
        allocator,
        io,
        port,
        "POST / HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\nContent-Length: 66\r\nConnection: close\r\n\r\n{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\",\"params\":{}}",
        "204",
        &scenarios,
    );
    try smoke.assertRawHttpContains(
        allocator,
        io,
        port,
        "POST / HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\nContent-Length: 120\r\nConnection: close\r\n\r\n{\"jsonrpc\":\"2.0\",\"method\":\"notifications/cancelled\",\"params\":{\"requestId\":999999,\"reason\":\"http smoke unknown request\"}}",
        "204",
        &scenarios,
    );
    {
        const malformed = try smoke.rawHttp(allocator, io, port, "not http\r\n\r\n");
        defer allocator.free(malformed);
        scenarios += 1;
    }
    try smoke.assertHttpRpcContains(allocator, io, port, "{ bad json", "\"code\":-32700", &scenarios);

    try http_tool_contract_smoke.assertToolPaths(allocator, io, port, 3, "zigars_schema", "{}", expected.value, "schema_paths", &scenarios);
    try http_tool_contract_smoke.assertToolPaths(allocator, io, port, 4, "zigars_doctor", "{\"probe_backends\":false}", expected.value, "doctor_paths", &scenarios);
    try http_tool_contract_smoke.assertToolPaths(allocator, io, port, 41, "zigars_backend_catalog", "{}", expected.value, "backend_catalog_paths", &scenarios);
    {
        const doctor_json = try smoke.callHttpToolJson(allocator, io, port, 40, "zigars_doctor", "{\"probe_backends\":false}");
        defer allocator.free(doctor_json);
        const parsed = try std.json.parseFromSlice(JsonValue, allocator, doctor_json, .{});
        defer parsed.deinit();
        const workspace = valueAt(parsed.value, "workspace").?.string;
        const abs_workspace = try smoke.absolutePath(allocator, io, options.workspace);
        defer allocator.free(abs_workspace);
        try smoke.expectStringEq(io, workspace, abs_workspace, "doctor.workspace");
    }
    scenarios += 1;
    try http_tool_contract_smoke.runStaticAnalysisAssertions(allocator, io, port, expected.value, &scenarios);
    try @import("http_validation_workflow_smoke.zig").run(allocator, io, port, expected.value, &scenarios);
    try @import("http_transactional_editing_smoke.zig").run(allocator, io, port, expected.value, &scenarios);
    try @import("http_phase6_smoke.zig").run(allocator, io, port, expected.value, &scenarios);
    try @import("http_performance_smoke.zig").run(allocator, io, port, expected.value, &scenarios);
    try @import("http_diagnostics_smoke.zig").run(allocator, io, port, expected.value, &scenarios);
    try @import("http_adoption_smoke.zig").run(allocator, io, port, expected.value, &scenarios);
    try http_tool_contract_smoke.runWorkflowAssertions(allocator, io, port, expected.value, &scenarios);
    try runtime_ux_smoke.run(allocator, io, port, expected.value, &scenarios);

    try smoke.assertMinimumCount(io, "http-smoke scenarios", scenarios, coverage_config.min_http_smoke_scenarios);
    try shutdownHttpServer(allocator, io, port, &child, &child_done);
    try stdoutWrite(io, "http smoke ok\n");
}

/// Builds the server argv slice, prepending kcov when `options.server_kcov_dir`
/// is set. The ZLS and zlint paths are intentionally set to nonexistent paths so
/// optional backends do not interfere with transport-level smoke assertions.
/// Caller owns the returned `ArrayList` and must free it.
fn httpServerArgv(allocator: std.mem.Allocator, options: HttpSmokeOptions, port_text: []const u8) !std.ArrayList([]const u8) {
    // Keep this logic centralized so callers observe one consistent behavior path.
    var argv: std.ArrayList([]const u8) = .empty;
    errdefer argv.deinit(allocator);
    if (options.server_kcov_dir) |dir| {
        try argv.appendSlice(allocator, &.{
            options.server_kcov_path,
            "--clean",
            "--include-path=" ++ coverage_config.kcov_include_path,
            "--exclude-path=" ++ coverage_config.kcov_exclude_path,
            coverage_config.kcov_exclude_line_arg,
            coverage_config.kcov_exclude_region_arg,
            dir,
        });
    }
    try argv.appendSlice(allocator, &.{
        options.binary,
        "--workspace",
        options.workspace,
        "--transport",
        "http",
        "--host",
        "127.0.0.1",
        "--port",
        port_text,
        "--zls-path",
        "/definitely/missing/zls",
        "--zlint-path",
        "/definitely/missing/zlint",
    });
    return argv;
}

/// Sends a JSON-RPC shutdown request, waits for the child to exit cleanly, and
/// sets `child_done` so the deferred `kill` is skipped. Returns
/// `error.AssertionFailed` if the shutdown response contains an error field or
/// the child exits with a non-zero status.
fn shutdownHttpServer(allocator: std.mem.Allocator, io: Io, port: u16, child: *std.process.Child, child_done: *bool) !void {
    // Keep this logic centralized so callers observe one consistent behavior path.
    const response = try smoke.rpc(allocator, io, port,
        \\{"jsonrpc":"2.0","id":99999,"method":"shutdown"}
    );
    defer allocator.free(response);
    const parsed = try std.json.parseFromSlice(JsonValue, allocator, response, .{});
    defer parsed.deinit();
    if (parsed.value.object.get("error") != null) return error.AssertionFailed;
    const term = try child.wait(io);
    child_done.* = true;
    if (!termOk(term)) return error.AssertionFailed;
}

/// Returns true only for a clean zero-exit; signals and non-zero codes are
/// treated as unexpected failures.
fn termOk(term: std.process.Child.Term) bool {
    return switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
}
/// A spawned HTTP server bound to a verified-free loopback port.
const StartedServer = struct {
    child: std.process.Child,
    port: u16,
};

/// Spawns the HTTP server on a verified-free loopback port (LOW-9). The port is
/// derived deterministically from the process id rather than the wall clock, and
/// `reserveLoopbackPort` bind-checks it so a lingering socket from a previous run
/// is skipped at selection time. Should the freshly released probe port be taken
/// by another process before the child rebinds (a narrow race surfacing as the
/// child exiting and `waitForInitialize` timing out), the whole spawn is retried
/// on a new port. The terminal attempt keeps the original 30s diagnostic wait so
/// a genuine startup failure still surfaces the child's stderr.
fn startHttpServer(allocator: std.mem.Allocator, io: Io, options: HttpSmokeOptions) !StartedServer {
    const max_attempts: usize = 3;
    var attempt: usize = 0;
    while (true) : (attempt += 1) {
        const last_attempt = attempt + 1 >= max_attempts;
        const port = try smoke.reserveLoopbackPort(io);
        var port_buf: [16]u8 = undefined;
        const port_text = try std.fmt.bufPrint(&port_buf, "{d}", .{port});
        var server_argv = try httpServerArgv(allocator, options, port_text);
        defer server_argv.deinit(allocator);
        var child = try std.process.spawn(io, .{
            .argv = server_argv.items,
            .stdout = .ignore,
            .stderr = .ignore,
        });
        // Run the full initialize handshake + assertions (serverInfo, trust
        // manifest URI). On a non-terminal attempt a startup failure (e.g. the
        // child lost the rebind race) is absorbed by retrying on a new port; the
        // terminal attempt propagates the diagnostic error.
        if (waitForInitialize(allocator, io, port, &child)) |_| {
            return .{ .child = child, .port = port };
        } else |err| {
            child.kill(io);
            if (last_attempt) return err;
        }
    }
}

/// Polls the server with an initialize request until it responds or the 30-second
/// deadline expires. On timeout it kills the child, drains stderr (up to 64 KiB),
/// and logs it before returning the original connection error. A retry sleep
/// failure is also logged and propagated; the sleep error is intentionally visible
/// rather than silently discarded.
fn waitForInitialize(allocator: std.mem.Allocator, io: Io, port: u16, child: *std.process.Child) !void {
    const deadline = smoke.nowNs(io) + 30 * std.time.ns_per_s;
    while (true) {
        const init_response = smoke.rpc(allocator, io, port,
            \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"zigars-smoke","version":"0"}}}
        ) catch |err| {
            if (smoke.nowNs(io) > deadline) {
                const stderr_file = child.stderr;
                child.stderr = null;
                child.kill(io);
                if (stderr_file) |stderr| {
                    defer stderr.close(io);
                    var reader_buffer: [4096]u8 = undefined;
                    var reader = stderr.reader(io, &reader_buffer);
                    const stderr_text = reader.interface.allocRemaining(allocator, .limited(64 * 1024)) catch |read_err| {
                        try stderrPrint(io, "initialize timed out after 30s ({s}); stderr could not be read after terminating child: {s}\n", .{ @errorName(err), @errorName(read_err) });
                        return err;
                    };
                    defer allocator.free(stderr_text);
                    try stderrPrint(io, "initialize timed out after 30s ({s}); stderr:\n{s}\n", .{ @errorName(err), stderr_text });
                } else {
                    try stderrPrint(io, "initialize timed out after 30s ({s}); child was terminated before returning the failure\n", .{@errorName(err)});
                }
                return err;
            }
            Io.Timeout.sleep(.{ .duration = .{ .raw = Io.Duration.fromMilliseconds(100), .clock = .awake } }, io) catch |sleep_err| {
                try stderrPrint(io, "initialize retry sleep failed: {s}\n", .{@errorName(sleep_err)});
                return sleep_err;
            };
            continue;
        };
        defer allocator.free(init_response);
        const parsed = try std.json.parseFromSlice(JsonValue, allocator, init_response, .{});
        defer parsed.deinit();
        const name = valueAt(parsed.value, "result.serverInfo.name").?.string;
        try smoke.expectStringEq(io, name, "zigars", "initialize serverInfo.name");
        const trust_uri = valueAt(parsed.value, "result.zigars.trust_manifest.uri").?.string;
        try smoke.expectStringEq(io, trust_uri, "zigars://trust/manifest", "initialize trust manifest URI");
        return;
    }
}

test "http smoke command exposes run entrypoint" {
    try std.testing.expect(@hasDecl(@This(), "run"));
}
