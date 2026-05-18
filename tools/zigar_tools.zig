const std = @import("std");
const builtin = @import("builtin");
const coverage = @import("coverage.zig");
const coverage_config = @import("coverage_config.zig");
const dist = @import("dist.zig");
const json_query = @import("json_query.zig");
const json_util = @import("json_util.zig");
const release_checks = @import("release_checks.zig");
const release_targets = @import("release_targets.zig");
const tool_index = @import("tool_index.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const JsonValue = std.json.Value;
const valueAt = json_query.valueAt;

test {
    _ = coverage;
    _ = dist;
    _ = json_query;
    _ = json_util;
    _ = release_checks;
    _ = release_targets;
    _ = tool_index;
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    var args_arena_state = std.heap.ArenaAllocator.init(allocator);
    defer args_arena_state.deinit();
    const args_arena = args_arena_state.allocator();
    const args = try init.minimal.args.toSlice(args_arena);

    if (args.len > 0) {
        const invoked = executableName(args[0]);
        if (std.mem.startsWith(u8, invoked, "fake-zwanzig")) return release_checks.fakeZwanzig(io, args[1..]);
        if (std.mem.startsWith(u8, invoked, "fake-zflame")) return release_checks.fakeZflame(io);
        if (std.mem.startsWith(u8, invoked, "fake-diff-folded")) return release_checks.fakeDiffFolded(io);
    }

    if (args.len < 2) {
        try usage(io);
        return error.InvalidArguments;
    }

    const cmd = args[1];
    if (std.mem.eql(u8, cmd, "version")) {
        try dist.printVersion(io);
    } else if (std.mem.eql(u8, cmd, "generate-tool-index")) {
        try tool_index.generate(allocator, io, args[2..]);
    } else if (std.mem.eql(u8, cmd, "check-json")) {
        try checkJson(allocator, io, args[2..]);
    } else if (std.mem.eql(u8, cmd, "http-smoke")) {
        try httpSmoke(allocator, io, args[2..]);
    } else if (std.mem.eql(u8, cmd, "stdio-fixtures")) {
        try stdioFixtures(allocator, io, args[0], args[2..]);
    } else if (std.mem.eql(u8, cmd, "coverage")) {
        try coverage.run(allocator, io, args[2..]);
    } else if (std.mem.eql(u8, cmd, "dist")) {
        try dist.buildArchives(allocator, io, args[2..]);
    } else if (std.mem.eql(u8, cmd, "dist-smoke")) {
        try dist.smoke(allocator, io, args[2..]);
    } else if (std.mem.eql(u8, cmd, "artifact-hygiene")) {
        try release_checks.artifactHygiene(allocator, io, args[2..]);
    } else {
        try usage(io);
        return error.InvalidArguments;
    }
}

fn usage(io: Io) !void {
    try stderrPrint(io,
        \\usage: zigar-tools <command> [options]
        \\
        \\commands:
        \\  version
        \\  generate-tool-index [--check]
        \\  check-json <path>...
        \\  http-smoke [--binary <path>] [--workspace <path>] [--expect <path>]
        \\  stdio-fixtures [--binary <path>] [--zig-path <path>]
        \\  coverage [--out-dir <path>] [--zig <path>] [--min-tests <count>] [--no-build] [--require-kcov] [--allow-kcov-failure]
        \\  dist --package <name> --exe <name> --binary <path>...
        \\  dist-smoke [--assets-dir <path>] [--version <version>]
        \\  artifact-hygiene
        \\
    , .{});
}

fn stdoutWrite(io: Io, bytes: []const u8) !void {
    try Io.File.stdout().writeStreamingAll(io, bytes);
}

fn stderrPrint(io: Io, comptime fmt: []const u8, args: anytype) !void {
    var buffer: [4096]u8 = undefined;
    var writer = Io.File.stderr().writer(io, &buffer);
    try writer.interface.print(fmt, args);
    try writer.interface.flush();
}

fn executableName(path: []const u8) []const u8 {
    var name = std.fs.path.basename(path);
    if (builtin.os.tag == .windows and std.mem.endsWith(u8, name, ".exe")) {
        name = name[0 .. name.len - 4];
    }
    return name;
}

fn readFileAlloc(allocator: Allocator, io: Io, path: []const u8, limit: usize) ![]u8 {
    return Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(limit));
}

fn writeFile(io: Io, path: []const u8, bytes: []const u8) !void {
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes });
}

fn jsonStringifyAlloc(allocator: Allocator, value: JsonValue, options: std.json.Stringify.Options) ![]u8 {
    var aw: Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    try std.json.Stringify.value(value, options, &aw.writer);
    return try aw.toOwnedSlice();
}

fn parseJsonFile(allocator: Allocator, io: Io, path: []const u8) !std.json.Parsed(JsonValue) {
    const bytes = try readFileAlloc(allocator, io, path, 16 * 1024 * 1024);
    defer allocator.free(bytes);
    return try std.json.parseFromSlice(JsonValue, allocator, bytes, .{});
}

fn checkJson(allocator: Allocator, io: Io, args: []const []const u8) !void {
    if (args.len == 0) return error.InvalidArguments;
    for (args) |path| {
        const parsed = try parseJsonFile(allocator, io, path);
        parsed.deinit();
    }
}

const HttpSmokeOptions = struct {
    binary: []const u8 = "zig-out/bin/zigar",
    workspace: []const u8 = ".",
    expect: []const u8 = "tests/fixtures/http-smoke.expect.json",
};

fn httpSmoke(allocator: Allocator, io: Io, args: []const []const u8) !void {
    var options: HttpSmokeOptions = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--binary")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            options.binary = args[i];
        } else if (std.mem.eql(u8, args[i], "--workspace")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            options.workspace = args[i];
        } else if (std.mem.eql(u8, args[i], "--expect")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            options.expect = args[i];
        } else {
            return error.InvalidArguments;
        }
    }

    const expected = try parseJsonFile(allocator, io, options.expect);
    defer expected.deinit();

    const port = pickSmokePort(io);
    var scenarios: usize = 0;
    var port_buf: [16]u8 = undefined;
    const port_text = try std.fmt.bufPrint(&port_buf, "{d}", .{port});
    var child = try std.process.spawn(io, .{
        .argv = &.{ options.binary, "--workspace", options.workspace, "--transport", "http", "--host", "127.0.0.1", "--port", port_text, "--zls-path", "/definitely/missing/zls" },
        .stdout = .ignore,
        .stderr = .pipe,
    });
    defer child.kill(io);

    try waitForInitialize(allocator, io, port, &child);
    try assertRequiredTools(allocator, io, port, expected.value);
    scenarios += 1;

    try assertToolPaths(allocator, io, port, 3, "zigar_schema", "{}", expected.value, "schema_paths", &scenarios);
    try assertToolPaths(allocator, io, port, 4, "zigar_doctor", "{\"probe_backends\":false}", expected.value, "doctor_paths", &scenarios);
    {
        const doctor_json = try callToolJson(allocator, io, port, 40, "zigar_doctor", "{\"probe_backends\":false}");
        defer allocator.free(doctor_json);
        const parsed = try std.json.parseFromSlice(JsonValue, allocator, doctor_json, .{});
        defer parsed.deinit();
        const workspace = valueAt(parsed.value, "workspace").?.string;
        const abs_workspace = try absolutePath(allocator, io, options.workspace);
        defer allocator.free(abs_workspace);
        try expectStringEq(workspace, abs_workspace, "doctor.workspace");
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
    try assertToolPaths(allocator, io, port, 25, "zigar_validate_patch", "{\"mode\":\"quick\",\"changed_files\":\"src/main.zig\",\"stop_on_failure\":true}", expected.value, "validate_patch_paths", &scenarios);

    try assertMinimumCount(io, "http-smoke scenarios", scenarios, coverage_config.min_http_smoke_scenarios);
    try stdoutWrite(io, "http smoke ok\n");
}

fn nowNs(io: Io) i96 {
    return Io.Clock.now(.real, io).nanoseconds;
}

fn pickSmokePort(io: Io) u16 {
    const ns = nowNs(io);
    const positive: u128 = @intCast(if (ns < 0) -ns else ns);
    return @intCast(41000 + (positive % 20000));
}

fn absolutePath(allocator: Allocator, io: Io, path: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(path)) return std.fs.path.resolve(allocator, &.{path});
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = try std.process.currentPath(io, &cwd_buf);
    return std.fs.path.resolve(allocator, &.{ cwd_buf[0..cwd_len], path });
}

fn waitForInitialize(allocator: Allocator, io: Io, port: u16, child: *std.process.Child) !void {
    const deadline = nowNs(io) + 10 * std.time.ns_per_s;
    while (true) {
        const init_response = rpc(allocator, io, port,
            \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"zigar-smoke","version":"0"}}}
        ) catch |err| {
            if (nowNs(io) > deadline) {
                if (child.stderr) |stderr| {
                    var reader_buffer: [4096]u8 = undefined;
                    var reader = stderr.reader(io, &reader_buffer);
                    const stderr_text = reader.interface.allocRemaining(allocator, .limited(64 * 1024)) catch "";
                    defer if (stderr_text.len > 0) allocator.free(stderr_text);
                    try stderrPrint(io, "initialize timed out ({s}); stderr:\n{s}\n", .{ @errorName(err), stderr_text });
                }
                return err;
            }
            Io.Timeout.sleep(.{ .duration = .{ .raw = Io.Duration.fromMilliseconds(100), .clock = .awake } }, io) catch {};
            continue;
        };
        defer allocator.free(init_response);
        const parsed = try std.json.parseFromSlice(JsonValue, allocator, init_response, .{});
        defer parsed.deinit();
        const name = valueAt(parsed.value, "result.serverInfo.name").?.string;
        try expectStringEq(name, "zigar", "initialize serverInfo.name");
        return;
    }
}

fn assertRequiredTools(allocator: Allocator, io: Io, port: u16, expected: JsonValue) !void {
    const tools_response = try rpc(allocator, io, port, "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\"}");
    defer allocator.free(tools_response);
    const parsed = try std.json.parseFromSlice(JsonValue, allocator, tools_response, .{});
    defer parsed.deinit();
    const tools = valueAt(parsed.value, "result.tools").?.array.items;
    for (expected.object.get("required_tools").?.array.items) |required| {
        var found = false;
        for (tools) |tool| {
            if (std.mem.eql(u8, tool.object.get("name").?.string, required.string)) {
                found = true;
                break;
            }
        }
        if (!found) {
            try stderrPrint(io, "missing tool: {s}\n", .{required.string});
            return error.AssertionFailed;
        }
    }
    try assertToolsListSchemas(io, tools, expected);
}

fn assertToolsListSchemas(io: Io, tools: []JsonValue, expected: JsonValue) !void {
    const expected_schemas = expected.object.get("tools_list_schema_paths") orelse return;
    var tool_it = expected_schemas.object.iterator();
    while (tool_it.next()) |tool_entry| {
        const tool = findTool(tools, tool_entry.key_ptr.*) orelse {
            try stderrPrint(io, "missing tool schema target: {s}\n", .{tool_entry.key_ptr.*});
            return error.AssertionFailed;
        };
        var path_it = tool_entry.value_ptr.object.iterator();
        while (path_it.next()) |path_entry| {
            const actual = valueAt(tool, path_entry.key_ptr.*) orelse {
                try stderrPrint(io, "{s}: missing tools/list schema path {s}\n", .{ tool_entry.key_ptr.*, path_entry.key_ptr.* });
                return error.AssertionFailed;
            };
            try expectJsonEq(io, actual, path_entry.value_ptr.*, path_entry.key_ptr.*);
        }
    }
}

fn findTool(tools: []JsonValue, name: []const u8) ?JsonValue {
    for (tools) |tool| {
        if (std.mem.eql(u8, tool.object.get("name").?.string, name)) return tool;
    }
    return null;
}

fn assertToolPaths(
    allocator: Allocator,
    io: Io,
    port: u16,
    id: i64,
    tool_name: []const u8,
    args_json: []const u8,
    expected_root: JsonValue,
    expected_key: []const u8,
    scenario_count: *usize,
) !void {
    const tool_json = try callToolJson(allocator, io, port, id, tool_name, args_json);
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
        try expectJsonEq(io, actual, entry.value_ptr.*, entry.key_ptr.*);
    }
    scenario_count.* += 1;
}

fn callToolJson(allocator: Allocator, io: Io, port: u16, id: i64, tool_name: []const u8, args_json: []const u8) ![]u8 {
    const body = try std.fmt.allocPrint(allocator,
        \\{{"jsonrpc":"2.0","id":{d},"method":"tools/call","params":{{"name":"{s}","arguments":{s}}}}}
    , .{ id, tool_name, args_json });
    defer allocator.free(body);

    const response = try rpc(allocator, io, port, body);
    defer allocator.free(response);
    const parsed = try std.json.parseFromSlice(JsonValue, allocator, response, .{});
    defer parsed.deinit();
    const result = parsed.value.object.get("result").?.object;
    if (result.get("structuredContent")) |structured| {
        return jsonStringifyAlloc(allocator, structured, .{ .whitespace = .minified });
    }
    const text = result.get("content").?.array.items[0].object.get("text").?.string;
    return allocator.dupe(u8, text);
}

fn rpc(allocator: Allocator, io: Io, port: u16, body: []const u8) ![]u8 {
    const address = try Io.net.IpAddress.parse("127.0.0.1", port);
    var stream = try address.connect(io, .{
        .mode = .stream,
        .protocol = .tcp,
        .timeout = .none,
    });
    defer stream.close(io);

    var writer_buffer: [4096]u8 = undefined;
    var writer = stream.writer(io, &writer_buffer);
    try writer.interface.print(
        "POST / HTTP/1.1\r\nHost: 127.0.0.1:{d}\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n",
        .{ port, body.len },
    );
    try writer.interface.writeAll(body);
    try writer.interface.flush();

    var reader_buffer: [4096]u8 = undefined;
    var reader = stream.reader(io, &reader_buffer);
    const response = try reader.interface.allocRemaining(allocator, .limited(8 * 1024 * 1024));
    defer allocator.free(response);

    const header_end = std.mem.indexOf(u8, response, "\r\n\r\n") orelse return error.InvalidHttpResponse;
    const header = response[0..header_end];
    const response_body = response[header_end + 4 ..];
    if (std.mem.indexOf(u8, header, " 200 ") == null) {
        try stderrPrint(io, "HTTP failure:\n{s}\n{s}\n", .{ header, response_body });
        return error.HttpFailure;
    }
    return allocator.dupe(u8, response_body);
}

fn expectJsonEq(io: Io, actual: JsonValue, expected: JsonValue, path: []const u8) !void {
    switch (expected) {
        .string => |s| if (actual != .string or !std.mem.eql(u8, actual.string, s)) {
            try stderrPrint(io, "assertion failed at {s}: expected string {s}\n", .{ path, s });
            return error.AssertionFailed;
        },
        .bool => |b| if (actual != .bool or actual.bool != b) {
            try stderrPrint(io, "assertion failed at {s}: expected bool {}\n", .{ path, b });
            return error.AssertionFailed;
        },
        .integer => |n| if (actual != .integer or actual.integer != n) {
            try stderrPrint(io, "assertion failed at {s}: expected integer {d}\n", .{ path, n });
            return error.AssertionFailed;
        },
        else => return error.UnsupportedExpectation,
    }
}

fn expectStringEq(actual: []const u8, expected: []const u8, label: []const u8) !void {
    if (!std.mem.eql(u8, actual, expected)) {
        std.debug.print("{s}: expected `{s}`, got `{s}`\n", .{ label, expected, actual });
        return error.AssertionFailed;
    }
}

const StdioOptions = struct {
    binary: []const u8 = "zig-out/bin/zigar",
    zig_path: []const u8 = "zig",
};

fn stdioFixtures(allocator: Allocator, io: Io, self_arg0: []const u8, args: []const []const u8) !void {
    var options: StdioOptions = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--binary")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            options.binary = args[i];
        } else if (std.mem.eql(u8, args[i], "--zig-path")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            options.zig_path = args[i];
        } else {
            return error.InvalidArguments;
        }
    }

    const workspace = try makeFixtureWorkspace(allocator, io);
    defer {
        const rel = workspace;
        Io.Dir.cwd().deleteTree(io, rel) catch {};
        allocator.free(workspace);
    }

    try writeFixtureFiles(io, workspace);
    const tool_path = try absolutePath(allocator, io, self_arg0);
    defer allocator.free(tool_path);
    const fake_zwanzig = try installFakeBackend(allocator, io, workspace, tool_path, "fake-zwanzig");
    defer allocator.free(fake_zwanzig);
    const fake_zflame = try installFakeBackend(allocator, io, workspace, tool_path, "fake-zflame");
    defer allocator.free(fake_zflame);
    const fake_diff = try installFakeBackend(allocator, io, workspace, tool_path, "fake-diff-folded");
    defer allocator.free(fake_diff);

    var child = try std.process.spawn(io, .{
        .argv = &.{
            options.binary,
            "--workspace",
            workspace,
            "--transport",
            "stdio",
            "--zig-path",
            options.zig_path,
            "--zls-path",
            "/definitely/missing/zls",
            "--zwanzig-path",
            fake_zwanzig,
            "--zflame-path",
            fake_zflame,
            "--diff-folded-path",
            fake_diff,
            "--timeout-ms",
            "10000",
        },
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    defer child.kill(io);

    var client = StdioClient{
        .allocator = allocator,
        .io = io,
        .child = &child,
        .next_id = 1,
        .tool_calls = 0,
    };
    try client.runFixture(workspace);
    try stdoutWrite(io, "stdio fixtures ok\n");
}

fn makeFixtureWorkspace(allocator: Allocator, io: Io) ![]u8 {
    const ns = nowNs(io);
    const path = try std.fmt.allocPrint(allocator, ".zig-cache/zigar-fixtures-{d}", .{ns});
    errdefer allocator.free(path);
    try Io.Dir.cwd().createDirPath(io, path);
    return path;
}

fn writeFixtureFiles(io: Io, workspace: []const u8) !void {
    var src_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const src_dir = try std.fmt.bufPrint(&src_path_buf, "{s}/src", .{workspace});
    try Io.Dir.cwd().createDirPath(io, src_dir);
    try writeJoinedFile(io, workspace, "src/main.zig", "pub fn main() void {const x=1;_ = x;}\n");
    try writeJoinedFile(io, workspace, "stacks.folded", "main;work 7\n");
    try writeJoinedFile(io, workspace, "before.folded", "main;old 3\n");
    try writeJoinedFile(io, workspace, "after.folded", "main;new 5\n");
    var bin_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const bin_dir = try std.fmt.bufPrint(&bin_path_buf, "{s}/bin", .{workspace});
    try Io.Dir.cwd().createDirPath(io, bin_dir);
}

fn writeJoinedFile(io: Io, workspace: []const u8, rel: []const u8, data: []const u8) !void {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ workspace, rel });
    try writeFile(io, path, data);
}

fn installFakeBackend(allocator: Allocator, io: Io, workspace: []const u8, tool_path: []const u8, name: []const u8) ![]u8 {
    const suffix = if (builtin.os.tag == .windows) ".exe" else "";
    const rel = try std.fmt.allocPrint(allocator, "{s}/bin/{s}{s}", .{ workspace, name, suffix });
    defer allocator.free(rel);
    const abs = try absolutePath(allocator, io, rel);
    errdefer allocator.free(abs);
    try Io.Dir.copyFileAbsolute(tool_path, abs, io, .{ .replace = true, .make_path = true });
    return abs;
}

const StdioClient = struct {
    allocator: Allocator,
    io: Io,
    child: *std.process.Child,
    next_id: i64,
    tool_calls: usize,

    fn runFixture(self: *StdioClient, workspace: []const u8) !void {
        const init = try self.request("initialize", "{\"protocolVersion\":\"2025-06-18\",\"capabilities\":{},\"clientInfo\":{\"name\":\"zigar-stdio-fixtures\",\"version\":\"0\"}}");
        defer self.allocator.free(init);
        {
            const parsed = try std.json.parseFromSlice(JsonValue, self.allocator, init, .{});
            defer parsed.deinit();
            try expectStringEq(valueAt(parsed.value, "serverInfo.name").?.string, "zigar", "stdio initialize serverInfo.name");
        }
        try self.notify("notifications/initialized", null);

        const tools = try self.request("tools/list", null);
        defer self.allocator.free(tools);
        try self.expectTool(tools, "zig_format");
        try self.expectTool(tools, "zig_flamegraph");
        try self.expectTool(tools, "zig_toolchain_resolve");
        try self.expectTool(tools, "zig_patch_preview");
        try self.expectTool(tools, "zigar_context_pack");
        try self.expectTool(tools, "zigar_validate_patch");
        try self.expectTool(tools, "zig_test_select");
        try self.expectToolPathString(tools, "zig_format", "inputSchema.properties.file.type", "string");
        try self.expectToolPathString(tools, "zig_format", "inputSchema.properties.file.x-zigar-path-kind", "input_file");
        try self.expectToolPathBool(tools, "zig_format", "inputSchema.properties.apply.default", false);
        try self.expectToolPathString(tools, "zig_format", "inputSchema.required.0", "file");

        const source = try std.fmt.allocPrint(self.allocator, "{s}/src/main.zig", .{workspace});
        defer self.allocator.free(source);
        const before = try readFileAlloc(self.allocator, self.io, source, 1024 * 1024);
        defer self.allocator.free(before);

        const preview = try self.callTool("zig_format", "{\"file\":\"src/main.zig\",\"apply\":false}");
        defer self.allocator.free(preview);
        try self.expectPathBool(preview, "applied", false);
        const after_preview = try readFileAlloc(self.allocator, self.io, source, 1024 * 1024);
        defer self.allocator.free(after_preview);
        try expectStringEq(after_preview, before, "zig_format preview source unchanged");
        if (std.mem.indexOf(u8, preview, "const x = 1;") == null) return error.AssertionFailed;

        const applied = try self.callTool("zig_format", "{\"file\":\"src/main.zig\",\"apply\":true}");
        defer self.allocator.free(applied);
        try self.expectPathBool(applied, "ok", true);
        const formatted = try readFileAlloc(self.allocator, self.io, source, 1024 * 1024);
        defer self.allocator.free(formatted);
        if (std.mem.indexOf(u8, formatted, "const x = 1;") == null) return error.AssertionFailed;

        const patch = try self.callTool("zig_patch_preview", "{\"file\":\"src/main.zig\",\"content\":\"pub fn main() void {\\n    const x = 2;\\n    _ = x;\\n}\\n\"}");
        defer self.allocator.free(patch);
        try self.expectPathBool(patch, "applied", false);
        if (std.mem.indexOf(u8, patch, "-    const x = 1;") == null) return error.AssertionFailed;

        const compile_index = try self.callTool("zig_compile_error_index", "{\"text\":\"src/main.zig:1:2: error: fixture failure\\n\"}");
        defer self.allocator.free(compile_index);
        try self.expectPathInt(compile_index, "summary.error_count", 1);

        const context = try self.callTool("zigar_context_pack", "{\"mode\":\"tiny\"}");
        defer self.allocator.free(context);
        try self.expectPathString(context, "kind", "zigar_context_pack");
        try self.expectPathBool(context, "workspace.zls_running", false);

        const next_action = try self.callTool("zigar_next_action", "{\"goal\":\"fix compile error\",\"changed_files\":\"src/main.zig\"}");
        defer self.allocator.free(next_action);
        try self.expectPathString(next_action, "recommended_steps.0.tool", "zig_compile_error_index");

        const guard = try self.callTool("zigar_patch_guard", "{\"files\":\"src/main.zig zig-out/generated.zig\"}");
        defer self.allocator.free(guard);
        try self.expectPathBool(guard, "safe", false);

        const api_diff = try self.callTool("zig_public_api_diff", "{\"before\":\"pub fn oldName() void {}\\n\",\"after\":\"pub fn newName() void {}\\n\"}");
        defer self.allocator.free(api_diff);
        try self.expectPathBool(api_diff, "breaking_change_risk", true);

        const validate = try self.callTool("zigar_validate_patch", "{\"mode\":\"quick\",\"changed_files\":\"src/main.zig\"}");
        defer self.allocator.free(validate);
        try self.expectPathString(validate, "kind", "zigar_validate_patch");

        const sarif = try self.callTool("zig_lint_sarif", "{\"path\":\"src\",\"rules_do\":\"fake-rule\"}");
        defer self.allocator.free(sarif);
        try self.expectPathBool(sarif, "ok", true);
        if (std.mem.indexOf(u8, sarif, "fake-zwanzig") == null or std.mem.indexOf(u8, sarif, "--format") == null) return error.AssertionFailed;

        const flame = try self.callTool("zig_flamegraph", "{\"format\":\"recursive\",\"input\":\"stacks.folded\",\"output\":\"profile.svg\",\"title\":\"fixture\"}");
        defer self.allocator.free(flame);
        try self.expectPathString(flame, "kind", "zig_flamegraph");
        try expectFileStartsWith(self.allocator, self.io, workspace, "profile.svg", "<svg");

        const diff = try self.callTool("zig_flamegraph_diff", "{\"before\":\"before.folded\",\"after\":\"after.folded\",\"output\":\"diff.svg\",\"title\":\"diff fixture\"}");
        defer self.allocator.free(diff);
        try self.expectPathString(diff, "kind", "zig_flamegraph");
        try expectFileStartsWith(self.allocator, self.io, workspace, "diff.svg", "<svg");
        const folded = try joinedRead(self.allocator, self.io, workspace, ".zigar-cache/profile/diff-0.folded");
        defer self.allocator.free(folded);
        try expectStringEq(std.mem.trim(u8, folded, " \t\r\n"), "main;delta 2", "diff folded output");
        try assertMinimumCount(self.io, "stdio-fixtures tool calls", self.tool_calls, coverage_config.min_stdio_fixture_tool_calls);
    }

    fn request(self: *StdioClient, method: []const u8, params: ?[]const u8) ![]u8 {
        const id = self.next_id;
        self.next_id += 1;
        const payload = if (params) |p|
            try std.fmt.allocPrint(self.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"{s}\",\"params\":{s}}}\n", .{ id, method, p })
        else
            try std.fmt.allocPrint(self.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"{s}\"}}\n", .{ id, method });
        defer self.allocator.free(payload);
        try self.write(payload);
        while (true) {
            const line = try self.readLine();
            defer self.allocator.free(line);
            const parsed = try std.json.parseFromSlice(JsonValue, self.allocator, line, .{});
            defer parsed.deinit();
            const response_id = parsed.value.object.get("id") orelse continue;
            if (response_id == .integer and response_id.integer == id) {
                if (parsed.value.object.get("error")) |_| return error.McpError;
                const result = parsed.value.object.get("result").?;
                return jsonStringifyAlloc(self.allocator, result, .{ .whitespace = .minified });
            }
        }
    }

    fn notify(self: *StdioClient, method: []const u8, params: ?[]const u8) !void {
        const payload = if (params) |p|
            try std.fmt.allocPrint(self.allocator, "{{\"jsonrpc\":\"2.0\",\"method\":\"{s}\",\"params\":{s}}}\n", .{ method, p })
        else
            try std.fmt.allocPrint(self.allocator, "{{\"jsonrpc\":\"2.0\",\"method\":\"{s}\"}}\n", .{method});
        defer self.allocator.free(payload);
        try self.write(payload);
    }

    fn callTool(self: *StdioClient, name: []const u8, args_json: []const u8) ![]u8 {
        const params = try std.fmt.allocPrint(self.allocator, "{{\"name\":\"{s}\",\"arguments\":{s}}}", .{ name, args_json });
        defer self.allocator.free(params);
        self.tool_calls += 1;
        const result_json = try self.request("tools/call", params);
        defer self.allocator.free(result_json);
        const parsed = try std.json.parseFromSlice(JsonValue, self.allocator, result_json, .{});
        defer parsed.deinit();
        const result = parsed.value;
        if (result.object.get("structuredContent")) |structured| {
            return jsonStringifyAlloc(self.allocator, structured, .{ .whitespace = .minified });
        }
        const text = result.object.get("content").?.array.items[0].object.get("text").?.string;
        return self.allocator.dupe(u8, text);
    }

    fn write(self: *StdioClient, bytes: []const u8) !void {
        const stdin = self.child.stdin orelse return error.MissingPipe;
        try stdin.writeStreamingAll(self.io, bytes);
    }

    fn readLine(self: *StdioClient) ![]u8 {
        const stdout = self.child.stdout orelse return error.MissingPipe;
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(self.allocator);
        var byte: [1]u8 = undefined;
        while (true) {
            const n = stdout.readStreaming(self.io, &.{&byte}) catch |err| switch (err) {
                error.EndOfStream => return error.EndOfStream,
                else => |e| return e,
            };
            if (n == 0) continue;
            if (byte[0] == '\n') break;
            if (byte[0] != '\r') try out.append(self.allocator, byte[0]);
        }
        return out.toOwnedSlice(self.allocator);
    }

    fn expectTool(self: *StdioClient, tools_json: []const u8, name: []const u8) !void {
        const parsed = try std.json.parseFromSlice(JsonValue, self.allocator, tools_json, .{});
        defer parsed.deinit();
        const tools = parsed.value.object.get("tools").?.array.items;
        for (tools) |tool| {
            if (std.mem.eql(u8, tool.object.get("name").?.string, name)) return;
        }
        return error.AssertionFailed;
    }

    fn expectToolPathString(self: *StdioClient, tools_json: []const u8, name: []const u8, path: []const u8, expected: []const u8) !void {
        const parsed = try std.json.parseFromSlice(JsonValue, self.allocator, tools_json, .{});
        defer parsed.deinit();
        const tool = findTool(parsed.value.object.get("tools").?.array.items, name) orelse return error.AssertionFailed;
        const value = valueAt(tool, path) orelse return error.AssertionFailed;
        if (value != .string or !std.mem.eql(u8, value.string, expected)) return error.AssertionFailed;
    }

    fn expectToolPathBool(self: *StdioClient, tools_json: []const u8, name: []const u8, path: []const u8, expected: bool) !void {
        const parsed = try std.json.parseFromSlice(JsonValue, self.allocator, tools_json, .{});
        defer parsed.deinit();
        const tool = findTool(parsed.value.object.get("tools").?.array.items, name) orelse return error.AssertionFailed;
        const value = valueAt(tool, path) orelse return error.AssertionFailed;
        if (value != .bool or value.bool != expected) return error.AssertionFailed;
    }

    fn expectPathBool(self: *StdioClient, json: []const u8, path: []const u8, expected: bool) !void {
        const parsed = try std.json.parseFromSlice(JsonValue, self.allocator, json, .{});
        defer parsed.deinit();
        const value = valueAt(parsed.value, path) orelse return error.AssertionFailed;
        if (value != .bool or value.bool != expected) return error.AssertionFailed;
    }

    fn expectPathInt(self: *StdioClient, json: []const u8, path: []const u8, expected: i64) !void {
        const parsed = try std.json.parseFromSlice(JsonValue, self.allocator, json, .{});
        defer parsed.deinit();
        const value = valueAt(parsed.value, path) orelse return error.AssertionFailed;
        if (value != .integer or value.integer != expected) return error.AssertionFailed;
    }

    fn expectPathString(self: *StdioClient, json: []const u8, path: []const u8, expected: []const u8) !void {
        const parsed = try std.json.parseFromSlice(JsonValue, self.allocator, json, .{});
        defer parsed.deinit();
        const value = valueAt(parsed.value, path) orelse return error.AssertionFailed;
        if (value != .string or !std.mem.eql(u8, value.string, expected)) return error.AssertionFailed;
    }
};

fn assertMinimumCount(io: Io, label: []const u8, actual: usize, expected: usize) !void {
    if (actual >= expected) return;
    try stderrPrint(io, "{s}: expected at least {d}, got {d}\n", .{ label, expected, actual });
    return error.AssertionFailed;
}

fn joinedRead(allocator: Allocator, io: Io, workspace: []const u8, rel: []const u8) ![]u8 {
    const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ workspace, rel });
    defer allocator.free(path);
    return readFileAlloc(allocator, io, path, 1024 * 1024);
}

fn expectFileStartsWith(allocator: Allocator, io: Io, workspace: []const u8, rel: []const u8, prefix: []const u8) !void {
    const bytes = try joinedRead(allocator, io, workspace, rel);
    defer allocator.free(bytes);
    if (!std.mem.startsWith(u8, bytes, prefix)) return error.AssertionFailed;
}

test "json util escapes JSON control characters" {
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try json_util.writeString(&out.writer, "a\"b\\c\n\t\x1b");
    try std.testing.expectEqualStrings("\"a\\\"b\\\\c\\n\\t\\u001b\"", out.written());
}
