const std = @import("std");
const builtin = @import("builtin");
const cli_io = @import("cli_io.zig");
const coverage_config = @import("coverage_config.zig");
const smoke = @import("smoke_support.zig");

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

const StdioOptions = struct {
    binary: []const u8 = "zig-out/bin/zigar",
    zig_path: []const u8 = "zig",
};

pub fn run(allocator: std.mem.Allocator, io: Io, self_arg0: []const u8, args: []const []const u8) !void {
    var options: StdioOptions = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--binary")) {
            options.binary = try flagValue(args, &i, io, "stdio-fixtures", "--binary", "stdio-fixtures [--binary <path>] [--zig-path <path>]");
        } else if (std.mem.eql(u8, args[i], "--zig-path")) {
            options.zig_path = try flagValue(args, &i, io, "stdio-fixtures", "--zig-path", "stdio-fixtures [--binary <path>] [--zig-path <path>]");
        } else {
            return unexpectedArgument(io, "stdio-fixtures", args[i], "stdio-fixtures [--binary <path>] [--zig-path <path>]");
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
    try Io.Dir.copyFileAbsolute(tool_path, abs, io, .{ .permissions = .executable_file, .make_path = true, .replace = true });
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
        try self.expectTool(tools, "zig_test_select");
        try self.expectTool(tools, "zig_ast_decl_summary");
        try self.expectTool(tools, "zig_lang_ref_search");

        const source = try std.fmt.allocPrint(self.allocator, "{s}/src/main.zig", .{workspace});
        defer self.allocator.free(source);
        const before = try readFileAlloc(self.allocator, self.io, source, 1024 * 1024);
        defer self.allocator.free(before);

        const workspace_info = try self.callTool("zigar_workspace_info", "{}");
        defer self.allocator.free(workspace_info);
        if (std.mem.indexOf(u8, workspace_info, "\"diff_folded\"") == null) return error.AssertionFailed;

        const profile_plan = try self.callTool("zig_profile_plan", "{\"binary\":\"zig-out/bin/fixture\",\"platform\":\"linux\"}");
        defer self.allocator.free(profile_plan);
        try self.expectPathString(profile_plan, "kind", "zig_profile_plan");

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

        const patch = try self.callTool("zig_patch_preview", "{\"file\":\"src/main.zig\",\"content\":\"pub fn main() void {\\n    const x = 2;\\n    _ = x;\\n}\\n\"}");
        defer self.allocator.free(patch);
        try self.expectPathJson(patch, "applied", .{ .bool = false });
        if (std.mem.indexOf(u8, patch, "-    const x = 1;") == null) return error.AssertionFailed;

        const compile_index = try self.callTool("zig_compile_error_index", "{\"text\":\"src/main.zig:1:2: error: fixture failure\\n\"}");
        defer self.allocator.free(compile_index);
        try self.expectPathJson(compile_index, "summary.error_count", .{ .integer = 1 });

        const context = try self.callTool("zigar_context_pack", "{\"mode\":\"tiny\"}");
        defer self.allocator.free(context);
        try self.expectPathString(context, "kind", "zigar_context_pack");
        try self.expectPathJson(context, "workspace.zls_running", .{ .bool = false });

        const langref = try self.callTool("zig_lang_ref_search", "{\"query\":\"defer\",\"limit\":1}");
        defer self.allocator.free(langref);
        try self.expectPathString(langref, "kind", "zig_lang_ref_search");
        if (std.mem.indexOf(u8, langref, "Language reference search source:") == null) return error.AssertionFailed;
        if (std.mem.indexOf(u8, langref, "wasm/main.zig") != null) return error.AssertionFailed;

        const next_action = try self.callTool("zigar_next_action", "{\"goal\":\"fix compile error\",\"changed_files\":\"src/main.zig\"}");
        defer self.allocator.free(next_action);
        try self.expectPathString(next_action, "recommended_steps.0.tool", "zig_compile_error_index");

        const guard = try self.callTool("zigar_patch_guard", "{\"files\":\"src/main.zig zig-out/generated.zig\"}");
        defer self.allocator.free(guard);
        try self.expectPathJson(guard, "safe", .{ .bool = false });

        const api_diff = try self.callTool("zig_public_api_diff", "{\"before\":\"pub fn oldName() void {}\\n\",\"after\":\"pub fn newName() void {}\\n\"}");
        defer self.allocator.free(api_diff);
        try self.expectPathJson(api_diff, "breaking_change_risk", .{ .bool = true });
        try self.expectPathString(api_diff, "capability_tier", "advisory_orientation");

        const ast_decls = try self.callTool("zig_ast_decl_summary", "{\"file\":\"src/tests.zig\"}");
        defer self.allocator.free(ast_decls);
        try self.expectPathString(ast_decls, "capability_tier", "parser_backed");
        if (std.mem.indexOf(u8, ast_decls, "Fixture") == null) return error.AssertionFailed;

        const validate = try self.callTool("zigar_validate_patch", "{\"mode\":\"quick\",\"changed_files\":\"src/main.zig\"}");
        defer self.allocator.free(validate);
        try self.expectPathString(validate, "kind", "zigar_validate_patch");

        const lint = try self.callTool("zig_lint", "{\"path\":\"src\",\"config\":\"src/main.zig\",\"rules_do\":\"fake-rule\",\"rules_skip\":\"style\",\"args\":\"--verbose\"}");
        defer self.allocator.free(lint);
        try self.expectPathJson(lint, "ok", .{ .bool = true });
        try self.expectPathString(lint, "capability_tier", "zwanzig_backed");
        if (std.mem.indexOf(u8, lint, "diagnostics") == null) return error.AssertionFailed;

        const sarif = try self.callTool("zig_lint_sarif", "{\"path\":\"src\",\"rules_do\":\"fake-rule\"}");
        defer self.allocator.free(sarif);
        try self.expectPathJson(sarif, "ok", .{ .bool = true });
        if (std.mem.indexOf(u8, sarif, "fake-zwanzig") == null or std.mem.indexOf(u8, sarif, "--format") == null) return error.AssertionFailed;

        const rules = try self.callTool("zig_lint_rules", "{}");
        defer self.allocator.free(rules);
        if (std.mem.indexOf(u8, rules, "--dump-cfg") == null) return error.AssertionFailed;

        const graph = try self.callTool("zig_analysis_graphs", "{\"mode\":\"cfg\",\"path\":\"src/main.zig\",\"output\":\"graphs/cfg\"}");
        defer self.allocator.free(graph);
        try self.expectPathString(graph, "kind", "zig_analysis_graphs");
        try self.expectPathString(graph, "mode", "cfg");
        try expectFileStartsWith(self.allocator, self.io, workspace, "graphs/cfg/fake-cfg.dot", "digraph");

        const flame = try self.callTool("zig_flamegraph", "{\"format\":\"recursive\",\"input\":\"stacks.folded\",\"output\":\"profile.svg\",\"title\":\"fixture\"}");
        defer self.allocator.free(flame);
        try self.expectPathString(flame, "kind", "zig_flamegraph");
        try expectFileStartsWith(self.allocator, self.io, workspace, "profile.svg", "<svg");

        const diff = try self.callTool("zig_flamegraph_diff", "{\"before\":\"before.folded\",\"after\":\"after.folded\",\"output\":\"diff.svg\",\"title\":\"diff fixture\"}");
        defer self.allocator.free(diff);
        try self.expectPathString(diff, "kind", "zig_flamegraph_diff");
        try expectFileStartsWith(self.allocator, self.io, workspace, "diff.svg", "<svg");
        try smoke.assertMinimumCount(self.io, "stdio-fixtures tool calls", self.tool_calls, coverage_config.min_stdio_fixture_tool_calls);
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
        if (smoke.findTool(tools, name) != null) return;
        return error.AssertionFailed;
    }

    fn expectPathString(self: *StdioClient, json: []const u8, path: []const u8, expected: []const u8) !void {
        try self.expectPathJson(json, path, .{ .string = expected });
    }

    fn expectPathJson(self: *StdioClient, json: []const u8, path: []const u8, expected: JsonValue) !void {
        const parsed = try std.json.parseFromSlice(JsonValue, self.allocator, json, .{});
        defer parsed.deinit();
        const value = valueAt(parsed.value, path) orelse return error.AssertionFailed;
        try smoke.expectJsonEq(self.io, value, expected, path);
    }
};

fn joinedRead(allocator: std.mem.Allocator, io: Io, workspace: []const u8, rel: []const u8) ![]u8 {
    const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ workspace, rel });
    defer allocator.free(path);
    return readFileAlloc(allocator, io, path, 1024 * 1024);
}

fn expectFileStartsWith(allocator: std.mem.Allocator, io: Io, workspace: []const u8, rel: []const u8, prefix: []const u8) !void {
    const bytes = try joinedRead(allocator, io, workspace, rel);
    defer allocator.free(bytes);
    if (!std.mem.startsWith(u8, bytes, prefix)) return error.AssertionFailed;
}
