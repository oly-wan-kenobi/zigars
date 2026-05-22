const std = @import("std");
const zigar = @import("zigar");

const json_result = zigar.json_result;
const lsp_client_mod = zigar.lsp_client;
const runtime_mod = zigar.runtime;
const workspace_mod = zigar.workspace;
const edit_zls = @import("edit_zls.zig");

test "zig_document_symbols falls back when ZLS is unavailable" {
    const allocator = std.testing.allocator;
    var workspace = try workspace_mod.Workspace.init(allocator, std.testing.io, ".", null);
    defer workspace.deinit();

    var app = runtime_mod.App{
        .allocator = allocator,
        .io = std.testing.io,
        .config = .{
            .workspace = workspace.root,
            .zls_path = "/missing/zls",
        },
        .workspace = workspace,
        .zls_status = "not started",
    };

    var args = std.json.ObjectMap.empty;
    defer args.deinit(allocator);
    try args.put(allocator, "file", .{ .string = "src/main.zig" });

    const result = try edit_zls.zigDocumentSymbols(&app, allocator, .{ .object = args });
    defer json_result.deinitToolResult(allocator, result);

    const obj = result.structuredContent.?.object;
    try std.testing.expectEqualStrings("zig_decl_summary", obj.get("kind").?.string);
    try std.testing.expectEqualStrings("advisory_orientation", obj.get("capability_tier").?.string);
}

test "zig_hover gateway adapter preserves unsupported capability result shape" {
    const allocator = std.testing.allocator;
    var workspace = try workspace_mod.Workspace.init(allocator, std.testing.io, ".", null);
    defer workspace.deinit();

    var client = lsp_client_mod.LspClient.init(allocator, std.testing.io);
    defer client.deinit();

    var app = runtime_mod.App{
        .allocator = allocator,
        .io = std.testing.io,
        .config = .{
            .workspace = workspace.root,
            .zls_path = "/missing/zls",
        },
        .workspace = workspace,
        .lsp_client = &client,
        .zls_initialize_response = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"capabilities\":{\"hoverProvider\":false}}}",
        .zls_status = "connected",
    };

    var args = std.json.ObjectMap.empty;
    defer args.deinit(allocator);
    try args.put(allocator, "file", .{ .string = "src/main.zig" });
    try args.put(allocator, "line", .{ .integer = 1 });
    try args.put(allocator, "character", .{ .integer = 2 });

    const result = try edit_zls.zigHover(&app, allocator, .{ .object = args });
    defer json_result.deinitToolResult(allocator, result);

    const obj = result.structuredContent.?.object;
    try std.testing.expectEqual(false, obj.get("ok").?.bool);
    try std.testing.expectEqualStrings("zls_unsupported_capability", obj.get("kind").?.string);
    try std.testing.expectEqualStrings("textDocument/hover", obj.get("method").?.string);
    try std.testing.expectEqualStrings("hoverProvider", obj.get("capability").?.string);
}

test "zig_hover gateway adapter reports ZLS unavailable before missing file" {
    const allocator = std.testing.allocator;
    var workspace = try workspace_mod.Workspace.init(allocator, std.testing.io, ".", null);
    defer workspace.deinit();

    var app = runtime_mod.App{
        .allocator = allocator,
        .io = std.testing.io,
        .config = .{
            .workspace = workspace.root,
            .zls_path = "/missing/zls",
        },
        .workspace = workspace,
        .zls_status = "startup failed",
        .zls_last_failure = "FileNotFound",
        .zls_restart_attempts = 2,
    };

    var args = std.json.ObjectMap.empty;
    defer args.deinit(allocator);

    const result = try edit_zls.zigHover(&app, allocator, .{ .object = args });
    defer json_result.deinitToolResult(allocator, result);

    const obj = result.structuredContent.?.object;
    try std.testing.expectEqual(false, obj.get("ok").?.bool);
    try std.testing.expectEqualStrings("backend_error", obj.get("kind").?.string);
    try std.testing.expectEqualStrings("zls", obj.get("backend").?.string);
    try std.testing.expectEqualStrings("unavailable", obj.get("error_kind").?.string);
    try std.testing.expectEqualStrings("/missing/zls", obj.get("configured_path").?.string);
    try std.testing.expectEqual(@as(i64, 2), obj.get("restart_attempts").?.integer);
    try std.testing.expectEqualStrings("FileNotFound", obj.get("last_failure").?.string);
}

test "zig_hover gateway adapter reports missing file after supported capability" {
    const allocator = std.testing.allocator;
    var workspace = try workspace_mod.Workspace.init(allocator, std.testing.io, ".", null);
    defer workspace.deinit();

    var client = lsp_client_mod.LspClient.init(allocator, std.testing.io);
    defer client.deinit();

    var app = runtime_mod.App{
        .allocator = allocator,
        .io = std.testing.io,
        .config = .{
            .workspace = workspace.root,
            .zls_path = "/missing/zls",
        },
        .workspace = workspace,
        .lsp_client = &client,
        .zls_initialize_response = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"capabilities\":{\"hoverProvider\":true}}}",
        .zls_status = "connected",
    };

    var args = std.json.ObjectMap.empty;
    defer args.deinit(allocator);

    const result = try edit_zls.zigHover(&app, allocator, .{ .object = args });
    defer json_result.deinitToolResult(allocator, result);

    const obj = result.structuredContent.?.object;
    try std.testing.expectEqual(false, obj.get("ok").?.bool);
    try std.testing.expectEqualStrings("argument_error", obj.get("kind").?.string);
    try std.testing.expectEqualStrings("textDocument/hover", obj.get("tool").?.string);
    try std.testing.expectEqualStrings("missing_required_argument", obj.get("code").?.string);
    try std.testing.expectEqualStrings("file", obj.get("field").?.string);
    try std.testing.expectEqualStrings("string", obj.get("expected").?.string);
}
