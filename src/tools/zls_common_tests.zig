const std = @import("std");
const zigar = @import("zigar");

const core = @import("shared_core.zig");
const zls_common = @import("zls_common.zig");

const App = core.App;
const json_result = zigar.json_result;

test "ZLS capability helpers map required LSP capabilities" {
    try std.testing.expectEqualStrings("hoverProvider", zls_common.zlsCapabilityName("textDocument/hover").?);
    try std.testing.expectEqualStrings("definitionProvider", zls_common.zlsCapabilityName("textDocument/definition").?);
    try std.testing.expectEqualStrings("referencesProvider", zls_common.zlsCapabilityName("textDocument/references").?);
    try std.testing.expectEqualStrings("completionProvider", zls_common.zlsCapabilityName("textDocument/completion").?);
    try std.testing.expectEqualStrings("signatureHelpProvider", zls_common.zlsCapabilityName("textDocument/signatureHelp").?);
    try std.testing.expectEqualStrings("documentSymbolProvider", zls_common.zlsCapabilityName("textDocument/documentSymbol").?);
    try std.testing.expectEqualStrings("documentFormattingProvider", zls_common.zlsCapabilityName("textDocument/formatting").?);
    try std.testing.expectEqualStrings("renameProvider", zls_common.zlsCapabilityName("textDocument/rename").?);
    try std.testing.expectEqualStrings("codeActionProvider", zls_common.zlsCapabilityName("textDocument/codeAction").?);
    try std.testing.expectEqualStrings("workspaceSymbolProvider", zls_common.zlsCapabilityName("workspace/symbol").?);
    try std.testing.expect(zls_common.zlsCapabilityName("workspace/executeCommand") == null);
}

test "ZLS capability state handles unavailable, unsupported, and advertised shapes" {
    var fake_client: zigar.lsp_client.LspClient = undefined;
    var app = testApp(std.testing.allocator);

    try expectCapabilityUnavailable(zls_common.zlsCapabilityState(&app, std.testing.allocator, "textDocument/hover"), "hoverProvider");
    try std.testing.expect(!zls_common.zlsSupportsCapability(&app, std.testing.allocator, "textDocument/hover"));
    try std.testing.expect(zls_common.zlsSupportsCapability(&app, std.testing.allocator, "workspace/executeCommand"));

    app.lsp_client = &fake_client;
    app.zls_initialize_response = "not-json";
    try expectCapabilityUnavailable(zls_common.zlsCapabilityState(&app, std.testing.allocator, "textDocument/hover"), "hoverProvider");

    app.zls_initialize_response = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}";
    try expectCapabilityUnavailable(zls_common.zlsCapabilityState(&app, std.testing.allocator, "textDocument/hover"), "hoverProvider");

    app.zls_initialize_response = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"capabilities\":{\"hoverProvider\":false}}}";
    try expectCapabilityUnsupported(zls_common.zlsCapabilityState(&app, std.testing.allocator, "textDocument/hover"), "hoverProvider");

    app.zls_initialize_response = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"capabilities\":{\"hoverProvider\":{},\"completionProvider\":[]}}}";
    try expectCapabilitySupported(zls_common.zlsCapabilityState(&app, std.testing.allocator, "textDocument/hover"));
    try expectCapabilitySupported(zls_common.zlsCapabilityState(&app, std.testing.allocator, "textDocument/completion"));
}

test "buildExplainCommand covers supported command modes and argument errors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "src");
    try tmp.dir.writeFile(io, .{ .sub_path = "src/main.zig", .data = "pub fn main() void {}\n" });
    const workspace = try initTempWorkspace(allocator, io, tmp.sub_path[0..]);
    var app = testApp(allocator);
    app.io = io;
    app.workspace = workspace;
    app.config.workspace = workspace.root;
    app.config.zig_path = "zig";

    var check_args = std.json.ObjectMap.empty;
    try check_args.put(allocator, "command", .{ .string = "check" });
    try check_args.put(allocator, "file", .{ .string = "src/main.zig" });
    const check = try zls_common.buildExplainCommand(allocator, .{ .object = check_args }, &app);
    try std.testing.expectEqualStrings("check", check.mode);
    try std.testing.expectEqualStrings("ast-check", check.argv.items[1]);

    var test_args = std.json.ObjectMap.empty;
    try test_args.put(allocator, "command", .{ .string = "test" });
    try test_args.put(allocator, "file", .{ .string = "src/main.zig" });
    try test_args.put(allocator, "args", .{ .string = "--test-filter main" });
    const test_cmd = try zls_common.buildExplainCommand(allocator, .{ .object = test_args }, &app);
    try std.testing.expectEqualStrings("test", test_cmd.argv.items[1]);
    try std.testing.expectEqualStrings("--test-filter", test_cmd.argv.items[3]);

    var build_args = std.json.ObjectMap.empty;
    try build_args.put(allocator, "command", .{ .string = "build" });
    const build_cmd = try zls_common.buildExplainCommand(allocator, .{ .object = build_args }, &app);
    try std.testing.expectEqualStrings("build", build_cmd.argv.items[1]);

    var fmt_args = std.json.ObjectMap.empty;
    try fmt_args.put(allocator, "command", .{ .string = "fmt-check" });
    try fmt_args.put(allocator, "file", .{ .string = "." });
    const fmt_cmd = try zls_common.buildExplainCommand(allocator, .{ .object = fmt_args }, &app);
    try std.testing.expectEqualStrings("fmt", fmt_cmd.argv.items[1]);
    try std.testing.expectEqualStrings("--check", fmt_cmd.argv.items[2]);

    const default_cmd = try zls_common.buildExplainCommand(allocator, null, &app);
    try std.testing.expectEqualStrings("build-test", default_cmd.mode);
    try std.testing.expectEqualStrings("test", default_cmd.argv.items[2]);

    var unsupported_args = std.json.ObjectMap.empty;
    try unsupported_args.put(allocator, "command", .{ .string = "run" });
    try std.testing.expectError(error.UnsupportedCommand, zls_common.buildExplainCommand(allocator, .{ .object = unsupported_args }, &app));

    var missing_file_args = std.json.ObjectMap.empty;
    try missing_file_args.put(allocator, "command", .{ .string = "check" });
    try std.testing.expectError(error.MissingFile, zls_common.buildExplainCommand(allocator, .{ .object = missing_file_args }, &app));

    var invalid_extra_args = std.json.ObjectMap.empty;
    try invalid_extra_args.put(allocator, "command", .{ .string = "build" });
    try invalid_extra_args.put(allocator, "args", .{ .string = "'unterminated" });
    try std.testing.expectError(error.InvalidExtraArgs, zls_common.buildExplainCommand(allocator, .{ .object = invalid_extra_args }, &app));
}

test "zlsSetupErrorResult maps setup failures to stable tool contracts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try initTempWorkspace(allocator, io, tmp.sub_path[0..]);
    var app = testApp(allocator);
    app.io = io;
    app.workspace = workspace;
    app.config.workspace = workspace.root;
    app.zls_status = "startup failed";
    app.zls_last_failure = "FileNotFound";

    const missing = try zls_common.zlsSetupErrorResult(&app, std.testing.allocator, "zig_hover", null, error.MissingFile);
    defer json_result.deinitToolResult(std.testing.allocator, missing);
    try std.testing.expectEqualStrings("argument_error", missing.structuredContent.?.object.get("kind").?.string);
    try std.testing.expectEqualStrings("missing_required_argument", missing.structuredContent.?.object.get("code").?.string);

    const outside = try zls_common.zlsSetupErrorResult(&app, std.testing.allocator, "zig_hover", "../outside.zig", error.PathOutsideWorkspace);
    defer json_result.deinitToolResult(std.testing.allocator, outside);
    try std.testing.expectEqualStrings("workspace_path_error", outside.structuredContent.?.object.get("kind").?.string);
    try std.testing.expectEqualStrings("path_outside_workspace", outside.structuredContent.?.object.get("code").?.string);

    const unavailable = try zls_common.zlsSetupErrorResult(&app, std.testing.allocator, "zig_hover", "src/main.zig", error.NotConnected);
    defer json_result.deinitToolResult(std.testing.allocator, unavailable);
    try std.testing.expectEqualStrings("backend_error", unavailable.structuredContent.?.object.get("kind").?.string);
    try std.testing.expectEqualStrings("unavailable", unavailable.structuredContent.?.object.get("error_kind").?.string);

    const too_large = try zls_common.zlsSetupErrorResult(&app, std.testing.allocator, "zig_hover", "src/main.zig", error.DocumentTooLarge);
    defer json_result.deinitToolResult(std.testing.allocator, too_large);
    try std.testing.expectEqualStrings("document_too_large", too_large.structuredContent.?.object.get("code").?.string);

    const too_many = try zls_common.zlsSetupErrorResult(&app, std.testing.allocator, "zig_hover", "src/main.zig", error.OpenDocumentLimitExceeded);
    defer json_result.deinitToolResult(std.testing.allocator, too_many);
    try std.testing.expectEqualStrings("open_document_limit_exceeded", too_many.structuredContent.?.object.get("code").?.string);

    const backend = try zls_common.zlsSetupErrorResult(&app, std.testing.allocator, "zig_hover", "src/main.zig", error.Timeout);
    defer json_result.deinitToolResult(std.testing.allocator, backend);
    try std.testing.expectEqualStrings("backend_error", backend.structuredContent.?.object.get("kind").?.string);
    try std.testing.expectEqualStrings("timeout", backend.structuredContent.?.object.get("error_kind").?.string);
}

test "lsp result and structured helpers preserve diagnostics and backend errors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = try zls_common.lspResultJson(allocator, "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"answer\":42}}");
    try std.testing.expect(std.mem.indexOf(u8, result, "\"answer\": 42") != null);

    const err = try zls_common.lspResultJson(allocator, "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-1,\"message\":\"bad\"}}");
    try std.testing.expect(std.mem.indexOf(u8, err, "\"message\": \"bad\"") != null);

    const raw = try zls_common.lspResultJson(allocator, "[]");
    try std.testing.expectEqualStrings("[]", raw);

    const diagnostic_response =
        \\{"jsonrpc":"2.0","id":2,"result":{"uri":"file:///tmp/main.zig","diagnostics":[
        \\{"severity":2,"message":"unused local constant","range":{"start":{"line":4,"character":8}}},
        \\{"severity":1,"message":"expected type u32, found i32","range":{"start":{"line":6,"character":2}}},
        \\{"severity":3,"message":"style hint"},
        \\5
        \\]}}
    ;
    const structured = try zls_common.lspStructuredValue(allocator, "textDocument/diagnostic", diagnostic_response);
    const obj = structured.object;
    try std.testing.expect(obj.get("ok").?.bool);
    const diagnostics = obj.get("diagnostics").?.object;
    try std.testing.expectEqual(@as(i64, 3), diagnostics.get("finding_count").?.integer);
    try std.testing.expectEqual(@as(i64, 1), diagnostics.get("error_count").?.integer);
    try std.testing.expectEqual(@as(i64, 1), diagnostics.get("warning_count").?.integer);
    try std.testing.expectEqualStrings("expected type u32, found i32", diagnostics.get("primary").?.object.get("message").?.string);
    try std.testing.expectEqualStrings("type_mismatch", diagnostics.get("category").?.string);
    try std.testing.expect(diagnostics.get("next_actions").?.array.items.len == 2);

    const error_value = try zls_common.lspStructuredValue(allocator, "textDocument/hover", "{\"jsonrpc\":\"2.0\",\"id\":3,\"error\":{\"code\":-32603,\"message\":\"backend\"}}");
    try std.testing.expect(!error_value.object.get("ok").?.bool);
    try std.testing.expectEqualStrings("backend", error_value.object.get("error").?.object.get("message").?.string);

    const non_object = try zls_common.lspStructuredValue(allocator, "textDocument/hover", "[]");
    try std.testing.expect(!non_object.object.get("ok").?.bool);
    try std.testing.expectEqualStrings("textDocument/hover", non_object.object.get("method").?.string);
}

test "LSP diagnostics insight helpers handle empty values and error detection" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const empty = try zls_common.lspDiagnosticsInsightsValue(allocator, .null);
    try std.testing.expectEqual(@as(i64, 0), empty.object.get("finding_count").?.integer);
    try std.testing.expectEqualStrings("none", (try zls_common.lspDiagnosticsInsightsValue(allocator, .{ .object = std.json.ObjectMap.empty })).object.get("category").?.string);

    try std.testing.expect(zls_common.lspHasError(allocator, "not-json"));
    try std.testing.expect(zls_common.lspHasError(allocator, "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"message\":\"bad\"}}"));
    try std.testing.expect(!zls_common.lspHasError(allocator, "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":null}"));
}

test "workspace format command is appended once when format targets exist" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "src");
    try tmp.dir.writeFile(io, .{ .sub_path = "build.zig", .data = "pub fn build(b: *std.Build) void { _ = b; }\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "build.zig.zon", .data = ".{}\n" });
    const workspace = try initTempWorkspace(allocator, io, tmp.sub_path[0..]);
    var app = testApp(allocator);
    app.io = io;
    app.workspace = workspace;
    app.config.workspace = workspace.root;

    var commands = std.json.Array.init(allocator);
    try zls_common.appendWorkspaceFormatCheckCommand(allocator, &app, &commands);
    try zls_common.appendWorkspaceFormatCheckCommand(allocator, &app, &commands);
    try zls_common.appendUniqueCommand(allocator, &commands, "zig build test");
    try zls_common.appendUniqueCommand(allocator, &commands, "zig build test");

    try std.testing.expectEqual(@as(usize, 2), commands.items.len);
    try std.testing.expect(std.mem.indexOf(u8, commands.items[0].string, "zig fmt --check") != null);
    try std.testing.expect(std.mem.indexOf(u8, commands.items[0].string, "build.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, commands.items[0].string, "src") != null);
}

fn initTempWorkspace(allocator: std.mem.Allocator, io: std.Io, tmp_sub_path: []const u8) !zigar.workspace.Workspace {
    const rel_root = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", tmp_sub_path });
    const root = try std.Io.Dir.cwd().realPathFileAlloc(io, rel_root, allocator);
    return zigar.workspace.Workspace.init(allocator, io, root, null);
}

fn testApp(allocator: std.mem.Allocator) App {
    return .{
        .allocator = allocator,
        .io = std.testing.io,
        .config = .{
            .workspace = "/tmp/zigar-test",
            .zls_path = "/missing/zls",
        },
        .workspace = undefined,
    };
}

fn expectCapabilityUnavailable(state: zls_common.ZlsCapabilityState, expected: []const u8) !void {
    switch (state) {
        .unavailable => |capability| try std.testing.expectEqualStrings(expected, capability),
        else => return error.UnexpectedCapabilityState,
    }
}

fn expectCapabilityUnsupported(state: zls_common.ZlsCapabilityState, expected: []const u8) !void {
    switch (state) {
        .unsupported => |capability| try std.testing.expectEqualStrings(expected, capability),
        else => return error.UnexpectedCapabilityState,
    }
}

fn expectCapabilitySupported(state: zls_common.ZlsCapabilityState) !void {
    switch (state) {
        .supported => {},
        else => return error.UnexpectedCapabilityState,
    }
}
