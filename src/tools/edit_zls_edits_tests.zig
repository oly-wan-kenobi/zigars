const std = @import("std");
const zigar = @import("zigar");

const common = @import("common.zig");
const edit_edits = @import("edit_zls_edits.zig");

const App = common.App;
const ZlsDocument = common.ZlsDocument;
const uri_util = zigar.uri;
const json_result = zigar.json_result;

test "workspaceEditFileValueForDocument previews primary file against ZLS source text" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;

    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "root");
    try tmp.dir.writeFile(io, .{ .sub_path = "root/main.zig", .data = "const disk = true;\n" });

    const rel_base = try std.fs.path.join(alloc, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer alloc.free(rel_base);
    const base_z = try std.Io.Dir.cwd().realPathFileAlloc(io, rel_base, alloc);
    defer alloc.free(base_z);
    const root = try std.fs.path.join(alloc, &.{ base_z[0..], "root" });
    defer alloc.free(root);
    var workspace = try zigar.workspace.Workspace.init(alloc, io, root, null, false);
    defer workspace.deinit();
    var app = App{
        .allocator = alloc,
        .io = io,
        .config = undefined,
        .workspace = workspace,
    };

    const abs = try std.fs.path.join(alloc, &.{ root, "main.zig" });
    defer alloc.free(abs);
    var doc = ZlsDocument{
        .uri = try uri_util.pathToUri(alloc, abs),
        .rel_path = try alloc.dupe(u8, "main.zig"),
        .source = try alloc.dupe(u8, "const unsaved = true;\n"),
        .source_kind = .provided_content,
        .content_matches_disk = false,
    };
    defer doc.deinit(alloc);

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc,
        \\[{"range":{"start":{"line":0,"character":6},"end":{"line":0,"character":13}},"newText":"saved"}]
    , .{});
    defer parsed.deinit();
    const value = try edit_edits.workspaceEditFileValueForDocument(&app, alloc, doc.uri, parsed.value, false, doc);
    defer json_result.deinitOwnedValue(alloc, value);

    const obj = switch (value) {
        .object => |o| o,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings("provided_content", obj.get("source_kind").?.string);
    const diff = obj.get("diff").?.string;
    try std.testing.expect(std.mem.indexOf(u8, diff, "-const unsaved = true;") != null);
    try std.testing.expect(std.mem.indexOf(u8, diff, "+const saved = true;") != null);
    try std.testing.expect(std.mem.indexOf(u8, diff, "disk") == null);
}
