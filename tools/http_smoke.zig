const std = @import("std");
const cli_io = @import("cli_io.zig");
const coverage_config = @import("coverage_config.zig");
const runtime_ux_smoke = @import("http_runtime_ux_smoke.zig");
const smoke = @import("smoke_support.zig");
const Io = std.Io;
const JsonValue = std.json.Value;
const flagValue = cli_io.flagValue;
const parseJsonFile = cli_io.parseJsonFile;
const stderrPrint = cli_io.stderrPrint;
const stdoutWrite = cli_io.stdoutWrite;
const unexpectedArgument = cli_io.unexpectedArgument;
const valueAt = smoke.valueAt;
const HttpSmokeOptions = struct {
    binary: []const u8 = "zig-out/bin/zigar",
    workspace: []const u8 = ".",
    expect: []const u8 = "tests/fixtures/http-smoke.expect.json",
    server_kcov_path: []const u8 = "kcov",
    server_kcov_dir: ?[]const u8 = null,
};

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

    const port = smoke.pickPort(io);
    var scenarios: usize = 0;
    var port_buf: [16]u8 = undefined;
    const port_text = try std.fmt.bufPrint(&port_buf, "{d}", .{port});
    var server_argv = try httpServerArgv(allocator, options, port_text);
    defer server_argv.deinit(allocator);
    var child = try std.process.spawn(io, .{
        .argv = server_argv.items,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    var child_done = false;
    defer if (!child_done) child.kill(io);

    try waitForInitialize(allocator, io, port, &child);
    try assertRequiredTools(allocator, io, port, expected.value);
    scenarios += 1;
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
    {
        const malformed = try smoke.rawHttp(allocator, io, port, "not http\r\n\r\n");
        defer allocator.free(malformed);
        scenarios += 1;
    }
    try smoke.assertHttpRpcContains(allocator, io, port, "{ bad json", "\"code\":-32700", &scenarios);

    try assertToolPaths(allocator, io, port, 3, "zigar_schema", "{}", expected.value, "schema_paths", &scenarios);
    try assertToolPaths(allocator, io, port, 4, "zigar_doctor", "{\"probe_backends\":false}", expected.value, "doctor_paths", &scenarios);
    try assertToolPaths(allocator, io, port, 41, "zigar_backend_catalog", "{}", expected.value, "backend_catalog_paths", &scenarios);
    {
        const doctor_json = try smoke.callHttpToolJson(allocator, io, port, 40, "zigar_doctor", "{\"probe_backends\":false}");
        defer allocator.free(doctor_json);
        const parsed = try std.json.parseFromSlice(JsonValue, allocator, doctor_json, .{});
        defer parsed.deinit();
        const workspace = valueAt(parsed.value, "workspace").?.string;
        const abs_workspace = try smoke.absolutePath(allocator, io, options.workspace);
        defer allocator.free(abs_workspace);
        try smoke.expectStringEq(io, workspace, abs_workspace, "doctor.workspace");
    }
    scenarios += 1;
    try assertToolPaths(allocator, io, port, 5, "zig_check", "{\"file\":42}", expected.value, "argument_error_paths", &scenarios);
    try assertToolPaths(allocator, io, port, 26, "zig_format", "{\"file\":\"missing.zig\"}", expected.value, "format_missing_file_paths", &scenarios);
    try assertToolPaths(allocator, io, port, 6, "zig_compile_error_index", "{\"text\":\"src/main.zig:1:2: error: fixture failure\\nsrc/main.zig:1:2: note: fixture note\\n\"}", expected.value, "compile_error_index_paths", &scenarios);
    try assertToolPaths(allocator, io, port, 7, "zig_target_matrix_plan", "{\"targets\":\"native wasm32-freestanding\",\"steps\":\"build\"}", expected.value, "target_matrix_paths", &scenarios);
    try assertToolPaths(allocator, io, port, 8, "zig_toolchain_resolve", "{\"probe_managers\":false}", expected.value, "toolchain_paths", &scenarios);
    try assertToolPaths(allocator, io, port, 9, "zig_dependency_inspect", "{}", expected.value, "dependency_paths", &scenarios);
    try assertToolPaths(allocator, io, port, 10, "zig_build_options", "{}", expected.value, "build_options_paths", &scenarios);
    try assertToolPaths(allocator, io, port, 11, "zig_changed_files_plan", "{}", expected.value, "changed_files_plan_paths", &scenarios);
    try assertToolPaths(allocator, io, port, 12, "zig_test_failure_triage", "{\"text\":\"1/1 test.foo...FAIL (TestExpectedEqual)\\nexpected 1, found 2\\n\"}", expected.value, "test_failure_triage_paths", &scenarios);
    try assertToolPaths(allocator, io, port, 13, "zig_workspace_symbol_cache", "{\"query\":\"main\",\"limit\":20}", expected.value, "workspace_symbol_cache_paths", &scenarios);
    try assertToolPaths(allocator, io, port, 80, "zig_semantic_index_build", "{\"limit\":20}", expected.value, "semantic_index_paths", &scenarios);
    try assertToolPaths(allocator, io, port, 81, "zig_semantic_index_status", "{}", expected.value, "semantic_index_status_paths", &scenarios);
    try assertToolPaths(allocator, io, port, 82, "zig_semantic_index_refresh", "{\"limit\":20}", expected.value, "semantic_index_refresh_paths", &scenarios);
    try assertToolPaths(allocator, io, port, 83, "zig_semantic_query", "{\"query\":\"main\",\"limit\":5}", expected.value, "semantic_query_paths", &scenarios);
    try assertToolPaths(allocator, io, port, 84, "zig_semantic_refs", "{\"symbol\":\"main\",\"limit\":5}", expected.value, "semantic_refs_paths", &scenarios);
    try assertToolPaths(allocator, io, port, 85, "zig_semantic_decl", "{\"symbol\":\"main\",\"limit\":5}", expected.value, "semantic_decl_paths", &scenarios);
    try assertToolPaths(allocator, io, port, 86, "zig_semantic_callers", "{\"symbol\":\"main\",\"limit\":5}", expected.value, "semantic_callers_paths", &scenarios);
    try assertToolPaths(allocator, io, port, 87, "zig_static_fusion", "{\"query\":\"main\",\"limit\":5}", expected.value, "static_fusion_paths", &scenarios);
    try assertToolPaths(allocator, io, port, 88, "zig_code_index_export", "{\"apply\":false,\"limit\":20}", expected.value, "code_index_export_paths", &scenarios);
    try assertToolPaths(allocator, io, port, 89, "zig_scip_export", "{\"apply\":false,\"limit\":20}", expected.value, "scip_export_paths", &scenarios);
    try assertToolPaths(allocator, io, port, 90, "zig_zlint", "{\"path\":\"src\"}", expected.value, "zlint_unavailable_paths", &scenarios);
    try assertToolPaths(allocator, io, port, 91, "zig_zlint_sarif", "{\"path\":\"src\"}", expected.value, "zlint_sarif_unavailable_paths", &scenarios);
    try assertToolPaths(allocator, io, port, 92, "zig_zlint_rules", "{}", expected.value, "zlint_rules_unavailable_paths", &scenarios);
    try assertToolPaths(allocator, io, port, 93, "zig_zlint_fix", "{\"path\":\"src\",\"apply\":false}", expected.value, "zlint_fix_preview_paths", &scenarios);
    try assertToolPaths(allocator, io, port, 94, "zig_lint_compare", "{\"zlint_findings\":\"[]\",\"zwanzig_findings\":\"[]\"}", expected.value, "lint_compare_paths", &scenarios);
    try assertToolPaths(allocator, io, port, 95, "zig_lint_profile", "{}", expected.value, "lint_profile_paths", &scenarios);
    try assertToolPaths(allocator, io, port, 96, "zig_lint_gate", "{\"findings\":\"[]\"}", expected.value, "lint_gate_paths", &scenarios);
    try assertToolPaths(allocator, io, port, 97, "zig_lint_fix_plan", "{\"findings\":\"[]\"}", expected.value, "lint_fix_plan_paths", &scenarios);
    try assertToolPaths(allocator, io, port, 98, "zig_lint_baseline", "{\"findings\":\"[]\",\"apply\":false}", expected.value, "lint_baseline_paths", &scenarios);
    try assertToolPaths(allocator, io, port, 99, "zig_lint_suppressions", "{\"findings\":\"[]\"}", expected.value, "lint_suppressions_paths", &scenarios);
    try assertToolPaths(allocator, io, port, 100, "zig_lint_trend", "{\"before\":\"[]\",\"after\":\"[]\"}", expected.value, "lint_trend_paths", &scenarios);
    try @import("http_validation_workflow_smoke.zig").run(allocator, io, port, expected.value, &scenarios);
    try @import("http_transactional_editing_smoke.zig").run(allocator, io, port, expected.value, &scenarios);
    try @import("http_phase6_smoke.zig").run(allocator, io, port, expected.value, &scenarios);
    try @import("http_performance_smoke.zig").run(allocator, io, port, expected.value, &scenarios);
    try @import("http_diagnostics_smoke.zig").run(allocator, io, port, expected.value, &scenarios);
    try @import("http_adoption_smoke.zig").run(allocator, io, port, expected.value, &scenarios);
    try assertToolPaths(allocator, io, port, 14, "zig_package_cache_doctor", "{\"timeout_ms\":1000}", expected.value, "package_cache_doctor_paths", &scenarios);
    try assertToolPaths(allocator, io, port, 15, "zigar_context_pack", "{\"mode\":\"tiny\"}", expected.value, "context_pack_paths", &scenarios);
    try assertToolPaths(allocator, io, port, 16, "zigar_next_action", "{\"goal\":\"fix failing tests\",\"changed_files\":\"src/main.zig\"}", expected.value, "next_action_paths", &scenarios);
    try assertToolPaths(allocator, io, port, 17, "zigar_agent_guide", "{\"client\":\"codex\",\"task\":\"patch\"}", expected.value, "agent_guide_paths", &scenarios);
    try assertToolPaths(allocator, io, port, 18, "zigar_patch_guard", "{\"files\":\"src/main.zig zig-out/bin/zigar\"}", expected.value, "patch_guard_paths", &scenarios);
    try assertToolPaths(allocator, io, port, 19, "zigar_failure_fusion", "{\"text\":\"src/main.zig:1:2: error: fixture failure\\n1/1 test.foo...FAIL\\n\"}", expected.value, "failure_fusion_paths", &scenarios);
    try assertToolPaths(allocator, io, port, 20, "zigar_impact", "{\"files\":\"src/main.zig\",\"symbols\":\"main\",\"limit\":20}", expected.value, "impact_paths", &scenarios);
    try assertToolPaths(allocator, io, port, 21, "zig_test_map", "{\"limit\":20}", expected.value, "test_map_paths", &scenarios);
    try assertToolPaths(allocator, io, port, 22, "zig_test_select", "{\"files\":\"src/main.zig\",\"symbols\":\"main\",\"limit\":20}", expected.value, "test_select_paths", &scenarios);
    try assertToolPaths(allocator, io, port, 23, "zig_public_api_diff", "{\"before\":\"pub fn oldName() void {}\\n\",\"after\":\"pub fn newName() void {}\\n\"}", expected.value, "public_api_diff_paths", &scenarios);
    try assertToolPaths(allocator, io, port, 24, "zigar_project_profile", "{}", expected.value, "project_profile_paths", &scenarios);
    try assertToolPaths(allocator, io, port, 57, "zigar_project_profile_v2", "{}", expected.value, "project_profile_v2_paths", &scenarios);
    try assertToolPaths(allocator, io, port, 58, "zigar_profile_bootstrap", "{}", expected.value, "profile_bootstrap_paths", &scenarios);
    try assertToolPaths(allocator, io, port, 59, "zigar_env_pack", "{\"probe_backends\":false,\"include_hashes\":false}", expected.value, "env_pack_paths", &scenarios);
    try assertToolPaths(allocator, io, port, 60, "zigar_zvm_install_plan", "{\"version\":\"0.16.0\"}", expected.value, "zvm_install_plan_paths", &scenarios);
    try assertToolPaths(allocator, io, port, 61, "zig_zls_match_check", "{\"probe_backends\":false}", expected.value, "zig_zls_match_paths", &scenarios);
    try assertToolPaths(allocator, io, port, 62, "zig_toolchain_pin", "{\"apply\":false,\"zig_version\":\"0.16.0\",\"zls_version\":\"0.16.0\"}", expected.value, "toolchain_pin_paths", &scenarios);
    try assertToolPaths(allocator, io, port, 63, "zigar_backend_install_plan", "{\"backend\":\"zflame\",\"manager\":\"manual\"}", expected.value, "backend_install_plan_paths", &scenarios);
    try assertToolPaths(allocator, io, port, 64, "zigar_dev_env_generate", "{\"kind\":\"mise\",\"apply\":false}", expected.value, "dev_env_generate_paths", &scenarios);
    try assertToolPaths(allocator, io, port, 65, "zigar_backend_conformance", "{\"backend\":\"zflame\",\"probe_backends\":false}", expected.value, "backend_conformance_paths", &scenarios);
    try assertToolPaths(allocator, io, port, 66, "zigar_backend_evidence_pack", "{\"apply\":false}", expected.value, "backend_evidence_pack_paths", &scenarios);
    try assertToolPaths(allocator, io, port, 25, "zigar_validate_patch", "{\"mode\":\"quick\",\"changed_files\":\"src/main.zig\",\"stop_on_failure\":true}", expected.value, "validate_patch_paths", &scenarios);
    try assertToolPaths(allocator, io, port, 50, "zigar_result_shape", "{\"mode\":\"compact\"}", expected.value, "result_shape_paths", &scenarios);
    try assertToolPaths(allocator, io, port, 51, "zigar_output_budget_plan", "{\"mode\":\"deep\",\"token_budget\":12,\"tool\":\"zig_check\"}", expected.value, "output_budget_paths", &scenarios);
    try assertToolPaths(allocator, io, port, 52, "zigar_metrics_v2", "{}", expected.value, "metrics_v2_paths", &scenarios);
    try assertToolPaths(allocator, io, port, 53, "zigar_command_provenance", "{\"tool\":\"zigar_artifact_prune\"}", expected.value, "command_provenance_paths", &scenarios);
    try assertToolPaths(allocator, io, port, 54, "zigar_risk_audit", "{\"include_none\":false}", expected.value, "risk_audit_paths", &scenarios);
    try assertToolPaths(allocator, io, port, 55, "zigar_docs_drift_check", "{\"mode\":\"compact\"}", expected.value, "docs_drift_paths", &scenarios);
    try assertToolPaths(allocator, io, port, 56, "zigar_artifact_index", "{\"include_hashes\":false,\"limit\":1,\"mode\":\"compact\"}", expected.value, "artifact_index_paths", &scenarios);
    try runtime_ux_smoke.run(allocator, io, port, expected.value, &scenarios);

    try smoke.assertMinimumCount(io, "http-smoke scenarios", scenarios, coverage_config.min_http_smoke_scenarios);
    try shutdownHttpServer(allocator, io, port, &child, &child_done);
    try stdoutWrite(io, "http smoke ok\n");
}

fn httpServerArgv(allocator: std.mem.Allocator, options: HttpSmokeOptions, port_text: []const u8) !std.ArrayList([]const u8) {
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

fn shutdownHttpServer(allocator: std.mem.Allocator, io: Io, port: u16, child: *std.process.Child, child_done: *bool) !void {
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

fn termOk(term: std.process.Child.Term) bool {
    return switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
}
fn waitForInitialize(allocator: std.mem.Allocator, io: Io, port: u16, child: *std.process.Child) !void {
    const deadline = smoke.nowNs(io) + 30 * std.time.ns_per_s;
    while (true) {
        const init_response = smoke.rpc(allocator, io, port,
            \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"zigar-smoke","version":"0"}}}
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
        try smoke.expectStringEq(io, name, "zigar", "initialize serverInfo.name");
        return;
    }
}

fn assertRequiredTools(allocator: std.mem.Allocator, io: Io, port: u16, expected: JsonValue) !void {
    const tools_response = try smoke.rpc(allocator, io, port, "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\"}");
    defer allocator.free(tools_response);
    const parsed = try std.json.parseFromSlice(JsonValue, allocator, tools_response, .{});
    defer parsed.deinit();
    const tools = valueAt(parsed.value, "result.tools").?.array.items;
    for (expected.object.get("required_tools").?.array.items) |required| {
        if (smoke.findTool(tools, required.string) != null) continue;
        try stderrPrint(io, "missing tool: {s}\n", .{required.string});
        return error.AssertionFailed;
    }
    try assertToolsListSchemas(io, tools, expected);
}

fn assertToolsListSchemas(io: Io, tools: []JsonValue, expected: JsonValue) !void {
    const expected_schemas = expected.object.get("tools_list_schema_paths") orelse return;
    var tool_it = expected_schemas.object.iterator();
    while (tool_it.next()) |tool_entry| {
        const tool = smoke.findTool(tools, tool_entry.key_ptr.*) orelse {
            try stderrPrint(io, "missing tool schema target: {s}\n", .{tool_entry.key_ptr.*});
            return error.AssertionFailed;
        };
        var path_it = tool_entry.value_ptr.object.iterator();
        while (path_it.next()) |path_entry| {
            const actual = valueAt(tool, path_entry.key_ptr.*) orelse {
                try stderrPrint(io, "{s}: missing tools/list schema path {s}\n", .{ tool_entry.key_ptr.*, path_entry.key_ptr.* });
                return error.AssertionFailed;
            };
            try smoke.expectJsonEq(io, actual, path_entry.value_ptr.*, path_entry.key_ptr.*);
        }
    }
}

fn assertToolPaths(
    allocator: std.mem.Allocator,
    io: Io,
    port: u16,
    id: i64,
    tool_name: []const u8,
    args_json: []const u8,
    expected_root: JsonValue,
    expected_key: []const u8,
    scenario_count: *usize,
) !void {
    const tool_json = try smoke.callHttpToolJson(allocator, io, port, id, tool_name, args_json);
    defer allocator.free(tool_json);
    const parsed = try std.json.parseFromSlice(JsonValue, allocator, tool_json, .{});
    defer parsed.deinit();
    const expected_paths = expected_root.object.get(expected_key).?.object;
    var it = expected_paths.iterator();
    while (it.next()) |entry| {
        const actual = valueAt(parsed.value, entry.key_ptr.*) orelse {
            try stderrPrint(io, "{s}: missing path {s}\n", .{ tool_name, entry.key_ptr.* });
            return error.AssertionFailed;
        };
        try smoke.expectJsonEq(io, actual, entry.value_ptr.*, entry.key_ptr.*);
    }
    scenario_count.* += 1;
}

test "http smoke command exposes run entrypoint" {
    try std.testing.expect(@hasDecl(@This(), "run"));
}
