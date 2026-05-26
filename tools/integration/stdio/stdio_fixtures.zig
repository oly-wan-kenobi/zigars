const std = @import("std");
const builtin = @import("builtin");
const cli_io = @import("../../common/cli_io.zig");
const coverage_config = @import("../../coverage/coverage_config.zig");
const smoke = @import("../smoke_support.zig");
const stdio_core_fixtures = @import("stdio_core_fixtures.zig");
const stdio_environment_fixtures = @import("stdio_environment_fixtures.zig");
const stdio_runtime_ux_fixtures = @import("stdio_runtime_ux_fixtures.zig");
const stdio_validation_workflow_fixtures = @import("stdio_validation_workflow_fixtures.zig");
const Io = std.Io;
const JsonValue = std.json.Value;
const flagValue = cli_io.flagValue;
const jsonStringifyAlloc = cli_io.jsonStringifyAlloc;
const readFileAlloc = cli_io.readFileAlloc;
const stderrPrint = cli_io.stderrPrint;
const stdoutWrite = cli_io.stdoutWrite;
const unexpectedArgument = cli_io.unexpectedArgument;
const valueAt = smoke.valueAt;
const writeFile = cli_io.writeFile;

// Owns stdio protocol lifecycle fixtures and delegates larger tool families to
// sibling modules that share the same StdioClient boundary.

const StdioOptions = struct {
    binary: []const u8 = "zig-out/bin/zigar",
    zig_path: []const u8 = "zig",
    server_kcov_path: []const u8 = "kcov",
    server_kcov_dir: ?[]const u8 = null,
};

/// Runs end-to-end stdio fixtures against a temporary workspace.
pub fn run(allocator: std.mem.Allocator, io: Io, self_arg0: []const u8, args: []const []const u8) !void {
    var options: StdioOptions = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--binary")) {
            options.binary = try flagValue(args, &i, io, "stdio-fixtures", "--binary", "stdio-fixtures [--binary <path>] [--zig-path <path>]");
        } else if (std.mem.eql(u8, args[i], "--zig-path")) {
            options.zig_path = try flagValue(args, &i, io, "stdio-fixtures", "--zig-path", "stdio-fixtures [--binary <path>] [--zig-path <path>]");
        } else if (std.mem.eql(u8, args[i], "--server-kcov-path")) {
            options.server_kcov_path = try flagValue(args, &i, io, "stdio-fixtures", "--server-kcov-path", "stdio-fixtures [--binary <path>] [--zig-path <path>] [--server-kcov-path <path>] [--server-kcov-dir <path>]");
        } else if (std.mem.eql(u8, args[i], "--server-kcov-dir")) {
            options.server_kcov_dir = try flagValue(args, &i, io, "stdio-fixtures", "--server-kcov-dir", "stdio-fixtures [--binary <path>] [--zig-path <path>] [--server-kcov-path <path>] [--server-kcov-dir <path>]");
        } else {
            return unexpectedArgument(io, "stdio-fixtures", args[i], "stdio-fixtures [--binary <path>] [--zig-path <path>] [--server-kcov-path <path>] [--server-kcov-dir <path>]");
        }
    }

    const workspace = try makeFixtureWorkspace(allocator, io);
    defer {
        cleanupFixtureWorkspace(io, workspace);
        allocator.free(workspace);
    }

    try writeFixtureFiles(io, workspace);
    const tool_path = try smoke.absolutePath(allocator, io, self_arg0);
    defer allocator.free(tool_path);
    const fake_zwanzig = try installFakeBackend(allocator, io, workspace, tool_path, "fake-zwanzig");
    defer allocator.free(fake_zwanzig);
    const fake_zlint = try installFakeBackend(allocator, io, workspace, tool_path, "fake-zlint");
    defer allocator.free(fake_zlint);
    const fake_zflame = try installFakeBackend(allocator, io, workspace, tool_path, "fake-zflame");
    defer allocator.free(fake_zflame);
    const fake_diff = try installFakeBackend(allocator, io, workspace, tool_path, "fake-diff-folded");
    defer allocator.free(fake_diff);

    var server_argv = try stdioServerArgv(allocator, options, workspace, fake_zlint, fake_zwanzig, fake_zflame, fake_diff);
    defer server_argv.deinit(allocator);
    var child = try std.process.spawn(io, .{
        .argv = server_argv.items,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .ignore,
    });
    var child_done = false;
    defer if (!child_done) child.kill(io);

    var client = StdioClient{
        .allocator = allocator,
        .io = io,
        .child = &child,
        .next_id = 1,
        .tool_calls = 0,
    };
    try client.runFixture(workspace);
    const shutdown = try client.request("shutdown", null);
    defer allocator.free(shutdown);
    const term = try child.wait(io);
    child_done = true;
    if (!termOk(term)) return error.AssertionFailed;
    try stdoutWrite(io, "stdio fixtures ok\n");
}

fn stdioServerArgv(
    allocator: std.mem.Allocator,
    options: StdioOptions,
    workspace: []const u8,
    fake_zlint: []const u8,
    fake_zwanzig: []const u8,
    fake_zflame: []const u8,
    fake_diff: []const u8,
) !std.ArrayList([]const u8) {
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
        workspace,
        "--transport",
        "stdio",
        "--zig-path",
        options.zig_path,
        "--zls-path",
        "/definitely/missing/zls",
        "--zlint-path",
        fake_zlint,
        "--zwanzig-path",
        fake_zwanzig,
        "--zflame-path",
        fake_zflame,
        "--diff-folded-path",
        fake_diff,
        "--timeout-ms",
        "10000",
    });
    return argv;
}

fn termOk(term: std.process.Child.Term) bool {
    return switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
}

fn makeFixtureWorkspace(allocator: std.mem.Allocator, io: Io) ![]u8 {
    const ns = smoke.nowNs(io);
    const path = try std.fmt.allocPrint(allocator, ".zig-cache/zigar-fixtures-{d}", .{ns});
    errdefer allocator.free(path);
    try Io.Dir.cwd().createDirPath(io, path);
    return path;
}

fn cleanupFixtureWorkspace(io: Io, rel: []const u8) void {
    Io.Dir.cwd().deleteTree(io, rel) catch |err| stderrPrint(io, "stdio-fixtures: failed to remove temporary workspace {s}: {s}\n", .{ rel, @errorName(err) }) catch return;
}

fn writeFixtureFiles(io: Io, workspace: []const u8) !void {
    var src_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const src_dir = try std.fmt.bufPrint(&src_path_buf, "{s}/src", .{workspace});
    try Io.Dir.cwd().createDirPath(io, src_dir);
    try writeJoinedFile(io, workspace, "src/main.zig", "pub fn main() void {const x=1;_ = x;}\n");
    try writeJoinedFile(io, workspace, "src/bad.zig", "pub fn bad() void { const x = ; _ = x; }\n");
    try writeJoinedFile(io, workspace, "src/tests.zig", "const std = @import(\"std\");\npub const Fixture = struct { pub fn run() void {} };\ntest \"fixture works\" { _ = std.testing; }\n");
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
fn installFakeBackend(allocator: std.mem.Allocator, io: Io, workspace: []const u8, tool_path: []const u8, name: []const u8) ![]u8 {
    const suffix = if (builtin.os.tag == .windows) ".exe" else "";
    const rel = try std.fmt.allocPrint(allocator, "{s}/bin/{s}{s}", .{ workspace, name, suffix });
    defer allocator.free(rel);
    const abs = try smoke.absolutePath(allocator, io, rel);
    errdefer allocator.free(abs);
    if (builtin.os.tag == .windows) {
        try Io.Dir.copyFileAbsolute(tool_path, abs, io, .{ .permissions = .executable_file, .make_path = true, .replace = true });
    } else {
        const script = try std.fmt.allocPrint(allocator, "#!/bin/sh\nexec \"{s}\" {s} \"$@\"\n", .{ tool_path, name });
        defer allocator.free(script);
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = abs, .data = script, .flags = .{ .permissions = .executable_file } });
    }
    return abs;
}

const StdioClient = struct {
    allocator: std.mem.Allocator,
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
            try smoke.expectStringEq(self.io, valueAt(parsed.value, "serverInfo.name").?.string, "zigar", "stdio initialize serverInfo.name");
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
        try self.expectTool(tools, "zigar_project_profile_v2");
        try self.expectTool(tools, "zigar_env_pack");
        try self.expectTool(tools, "zigar_backend_conformance");
        try self.expectTool(tools, "zigar_job_start");
        try self.expectTool(tools, "zigar_run_stream");
        try self.expectTool(tools, "zigar_resource_query");
        try self.expectTool(tools, "zigar_workspace_map");
        try self.expectTool(tools, "zigar_prompt_pack");
        try self.expectTool(tools, "zig_test_select");
        try self.expectTool(tools, "zig_ast_decl_summary");
        try self.expectTool(tools, "zig_lang_ref_search");
        try self.expectTool(tools, "zig_zlint");
        try self.expectTool(tools, "zig_zlint_fix");
        try self.expectTool(tools, "zig_debug_plan");
        try self.expectTool(tools, "zig_fuzz_plan");
        try self.expectTool(tools, "zig_binary_size");
        try self.expectTool(tools, "zig_flash_plan");
        try self.expectTool(tools, "zigar_adoption_pack");
        try self.expectTool(tools, "zigar_client_config_generate");
        try self.expectTool(tools, "zigar_smoke_plan");
        try self.expectTool(tools, "zigar_conformance_report");

        const resources = try self.request("resources/list", null);
        defer self.allocator.free(resources);
        if (std.mem.indexOf(u8, resources, "zigar://workspace") == null) return error.AssertionFailed;
        if (std.mem.indexOf(u8, resources, "zigar://tools/schema") == null) return error.AssertionFailed;

        const resource_read = try self.request("resources/read", "{\"uri\":\"zigar://workspace\"}");
        defer self.allocator.free(resource_read);
        if (std.mem.indexOf(u8, resource_read, workspace) == null) return error.AssertionFailed;

        const prompts = try self.request("prompts/list", null);
        defer self.allocator.free(prompts);
        if (std.mem.indexOf(u8, prompts, "zigar_profile_workflow") == null) return error.AssertionFailed;
        const prompt = try self.request("prompts/get", "{\"name\":\"zigar_profile_workflow\",\"arguments\":{}}");
        defer self.allocator.free(prompt);
        if (std.mem.indexOf(u8, prompt, "zig_profile_plan") == null) return error.AssertionFailed;

        const source = try std.fmt.allocPrint(self.allocator, "{s}/src/main.zig", .{workspace});
        defer self.allocator.free(source);
        const before = try readFileAlloc(self.allocator, self.io, source, 1024 * 1024);
        defer self.allocator.free(before);

        const workspace_info = try self.callTool("zigar_workspace_info", "{}");
        defer self.allocator.free(workspace_info);
        if (std.mem.indexOf(u8, workspace_info, "\"diff_folded\"") == null) return error.AssertionFailed;

        try stdio_environment_fixtures.run(self);
        try stdio_runtime_ux_fixtures.run(self);
        try @import("stdio_adoption_fixtures.zig").run(self);

        const preview = try self.callTool("zig_format", "{\"file\":\"src/main.zig\",\"apply\":false}");
        defer self.allocator.free(preview);
        try self.expectPathJson(preview, "applied", .{ .bool = false });
        const after_preview = try readFileAlloc(self.allocator, self.io, source, 1024 * 1024);
        defer self.allocator.free(after_preview);
        try smoke.expectStringEq(self.io, after_preview, before, "zig_format preview source unchanged");
        if (std.mem.indexOf(u8, preview, "const x = 1;") == null) return error.AssertionFailed;

        const applied = try self.callTool("zig_format", "{\"file\":\"src/main.zig\",\"apply\":true}");
        defer self.allocator.free(applied);
        try self.expectPathJson(applied, "ok", .{ .bool = true });
        const formatted = try readFileAlloc(self.allocator, self.io, source, 1024 * 1024);
        defer self.allocator.free(formatted);
        if (std.mem.indexOf(u8, formatted, "const x = 1;") == null) return error.AssertionFailed;

        const format_check = try self.callTool("zig_format_check", "{\"path\":\"src/main.zig\"}");
        defer self.allocator.free(format_check);
        try self.expectPathJson(format_check, "ok", .{ .bool = true });

        const patch = try self.callTool("zig_patch_preview", "{\"file\":\"src/main.zig\",\"content\":\"pub fn main() void {\\n    const x = 2;\\n    _ = x;\\n}\\n\"}");
        defer self.allocator.free(patch);
        try self.expectPathJson(patch, "applied", .{ .bool = false });
        if (std.mem.indexOf(u8, patch, "-    const x = 1;") == null) return error.AssertionFailed;

        const context = try self.callTool("zigar_context_pack", "{\"mode\":\"tiny\"}");
        defer self.allocator.free(context);
        try self.expectPathString(context, "kind", "zigar_context_pack");
        try self.expectPathJson(context, "workspace.zls_running", .{ .bool = false });

        const validate = try self.callTool("zigar_validate_patch", "{\"mode\":\"quick\",\"changed_files\":\"src/main.zig\"}");
        defer self.allocator.free(validate);
        try self.expectPathString(validate, "kind", "zigar_validate_patch");
        try self.expectPathString(validate, "workflow_contract.verification", "rerun failed phase or run zigar_validate_patch mode=full");
        try stdio_validation_workflow_fixtures.run(self);
        try @import("stdio_transactional_editing_fixtures.zig").run(self, workspace);

        try stdio_core_fixtures.run(self, workspace);
        try smoke.assertMinimumCount(self.io, "stdio-fixtures tool calls", self.tool_calls, coverage_config.min_stdio_fixture_tool_calls);
    }

    pub fn request(self: *StdioClient, method: []const u8, params: ?[]const u8) ![]u8 {
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

    pub fn callTool(self: *StdioClient, name: []const u8, args_json: []const u8) ![]u8 {
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
        if (smoke.findTool(tools, name) != null) return;
        return error.AssertionFailed;
    }

    pub fn expectPathString(self: *StdioClient, json: []const u8, path: []const u8, expected: []const u8) !void {
        try self.expectPathJson(json, path, .{ .string = expected });
    }

    pub fn expectPathJson(self: *StdioClient, json: []const u8, path: []const u8, expected: JsonValue) !void {
        const parsed = try std.json.parseFromSlice(JsonValue, self.allocator, json, .{});
        defer parsed.deinit();
        const value = valueAt(parsed.value, path) orelse return error.AssertionFailed;
        try smoke.expectJsonEq(self.io, value, expected, path);
    }

    pub fn expectZlsUnavailable(self: *StdioClient, name: []const u8, args_json: []const u8) !void {
        const result = try self.callTool(name, args_json);
        defer self.allocator.free(result);
        const parsed = try std.json.parseFromSlice(JsonValue, self.allocator, result, .{});
        defer parsed.deinit();
        if (valueAt(parsed.value, "backend")) |backend| {
            if (backend == .string and std.mem.eql(u8, backend.string, "zls")) return;
        }
        if (valueAt(parsed.value, "ok")) |ok| {
            if (ok == .bool and !ok.bool) return;
        }
        return error.AssertionFailed;
    }
};

test "stdio fixtures command exposes run entrypoint" {
    try std.testing.expect(@hasDecl(@This(), "run"));
}
