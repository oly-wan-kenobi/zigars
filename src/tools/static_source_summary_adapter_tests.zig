const std = @import("std");
const mcp = @import("mcp");
const zigar = @import("zigar");

const adapter = @import("static_source_summary_adapter.zig");
const common = @import("common.zig");

const App = common.App;
const json_result = zigar.json_result;

test "static source summary adapter keeps structured argument and workspace errors stable" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try initTempWorkspace(allocator, io, tmp.sub_path[0..]);
    var app = testApp(allocator, io, workspace);

    const missing = try adapter.zigDeclSummary(&app, std.testing.allocator, null);
    defer json_result.deinitToolResult(std.testing.allocator, missing);
    try expectErrorKind(missing, "argument_error", "missing_required_argument");

    const outside = try adapter.zigDeclSummary(&app, std.testing.allocator, argsWithFile(allocator, "../outside.zig"));
    defer json_result.deinitToolResult(std.testing.allocator, outside);
    try expectErrorKind(outside, "workspace_path_error", "path_outside_workspace");

    const unreadable = try adapter.zigDeclSummary(&app, std.testing.allocator, argsWithFile(allocator, "missing.zig"));
    defer json_result.deinitToolResult(std.testing.allocator, unreadable);
    try expectErrorKind(unreadable, "tool_error", "read_failed");
    try std.testing.expectEqualStrings("missing.zig", unreadable.structuredContent.?.object.get("file").?.string);
}

fn initTempWorkspace(allocator: std.mem.Allocator, io: std.Io, tmp_sub_path: []const u8) !zigar.workspace.Workspace {
    const rel_root = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", tmp_sub_path });
    const root = try std.Io.Dir.cwd().realPathFileAlloc(io, rel_root, allocator);
    return zigar.workspace.Workspace.init(allocator, io, root, null);
}

fn testApp(allocator: std.mem.Allocator, io: std.Io, workspace: zigar.workspace.Workspace) App {
    return .{
        .allocator = allocator,
        .io = io,
        .config = .{
            .workspace = workspace.root,
            .zig_path = "zig",
        },
        .workspace = workspace,
    };
}

fn argsWithFile(allocator: std.mem.Allocator, file: []const u8) std.json.Value {
    var args = std.json.ObjectMap.empty;
    args.put(allocator, "file", .{ .string = file }) catch unreachable;
    return .{ .object = args };
}

fn expectErrorKind(result: mcp.tools.ToolResult, kind: []const u8, code: []const u8) !void {
    try std.testing.expect(result.is_error);
    const obj = result.structuredContent.?.object;
    try std.testing.expectEqualStrings(kind, obj.get("kind").?.string);
    try std.testing.expectEqualStrings(code, obj.get("code").?.string);
}
