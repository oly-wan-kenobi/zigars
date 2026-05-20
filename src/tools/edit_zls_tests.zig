const std = @import("std");
const zigar = @import("zigar");

const json_result = zigar.json_result;
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
