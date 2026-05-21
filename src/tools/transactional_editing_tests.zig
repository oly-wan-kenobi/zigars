const std = @import("std");
const zigar = @import("zigar");

const transactional = @import("transactional_editing.zig");

const App = @import("common.zig").App;
const json_result = zigar.json_result;

test "patch session apply records preimages and revert restores own change" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;

    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "root/src");
    try tmp.dir.writeFile(io, .{ .sub_path = "root/src/main.zig", .data = "pub fn main() void {}\n" });

    var app = try testApp(alloc, io, tmp.sub_path[0..]);
    defer deinitTestApp(&app);

    const edits =
        \\[{"file":"src/main.zig","content":"pub fn main() void {\n    _ = 1;\n}\n"}]
    ;
    var preview_args = std.json.ObjectMap.empty;
    defer preview_args.deinit(alloc);
    try preview_args.put(alloc, "edits", .{ .string = edits });
    const preview = try transactional.zigarPatchSessionPreview(&app, alloc, .{ .object = preview_args });
    defer json_result.deinitToolResult(alloc, preview);
    const preview_obj = preview.structuredContent.?.object;
    const session_id = preview_obj.get("session_id").?.string;
    const expected = try json_result.serializeAlloc(alloc, preview_obj.get("expected_preimages").?);
    defer alloc.free(expected);

    var apply_args = std.json.ObjectMap.empty;
    defer apply_args.deinit(alloc);
    try apply_args.put(alloc, "session_id", .{ .string = session_id });
    try apply_args.put(alloc, "edits", .{ .string = edits });
    try apply_args.put(alloc, "expected_preimages", .{ .string = expected });
    try apply_args.put(alloc, "apply", .{ .bool = true });
    const applied = try transactional.zigarPatchSessionApply(&app, alloc, .{ .object = apply_args });
    defer json_result.deinitToolResult(alloc, applied);
    try std.testing.expect(applied.structuredContent.?.object.get("applied").?.bool);

    const changed = try app.workspace.readFileAlloc(io, "src/main.zig", 1024);
    defer alloc.free(changed);
    try std.testing.expect(std.mem.indexOf(u8, changed, "_ = 1") != null);

    var revert_args = std.json.ObjectMap.empty;
    defer revert_args.deinit(alloc);
    try revert_args.put(alloc, "session_id", .{ .string = session_id });
    try revert_args.put(alloc, "apply", .{ .bool = true });
    const reverted = try transactional.zigarPatchSessionRevert(&app, alloc, .{ .object = revert_args });
    defer json_result.deinitToolResult(alloc, reverted);
    try std.testing.expect(reverted.structuredContent.?.object.get("applied").?.bool);

    const restored = try app.workspace.readFileAlloc(io, "src/main.zig", 1024);
    defer alloc.free(restored);
    try std.testing.expectEqualStrings("pub fn main() void {}\n", restored);
}

test "patch session apply rejects stale expected preimage" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;

    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "root/src");
    try tmp.dir.writeFile(io, .{ .sub_path = "root/src/main.zig", .data = "const value = 1;\n" });

    var app = try testApp(alloc, io, tmp.sub_path[0..]);
    defer deinitTestApp(&app);

    const edits =
        \\[{"file":"src/main.zig","content":"const value = 2;\n"}]
    ;
    var preview_args = std.json.ObjectMap.empty;
    defer preview_args.deinit(alloc);
    try preview_args.put(alloc, "edits", .{ .string = edits });
    const preview = try transactional.zigarPatchSessionPreview(&app, alloc, .{ .object = preview_args });
    defer json_result.deinitToolResult(alloc, preview);
    const expected = try json_result.serializeAlloc(alloc, preview.structuredContent.?.object.get("expected_preimages").?);
    defer alloc.free(expected);

    try app.workspace.writeFile(io, "src/main.zig", "const value = 99;\n");

    var apply_args = std.json.ObjectMap.empty;
    defer apply_args.deinit(alloc);
    try apply_args.put(alloc, "edits", .{ .string = edits });
    try apply_args.put(alloc, "expected_preimages", .{ .string = expected });
    try apply_args.put(alloc, "apply", .{ .bool = true });
    const applied = try transactional.zigarPatchSessionApply(&app, alloc, .{ .object = apply_args });
    defer json_result.deinitToolResult(alloc, applied);
    try std.testing.expect(!applied.structuredContent.?.object.get("applied").?.bool);
    try std.testing.expect(!applied.structuredContent.?.object.get("safe_to_apply").?.bool);

    const current = try app.workspace.readFileAlloc(io, "src/main.zig", 1024);
    defer alloc.free(current);
    try std.testing.expectEqualStrings("const value = 99;\n", current);
}

test "generated route classifies generated tool index as non-editable" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "root/docs");

    var app = try testApp(alloc, io, tmp.sub_path[0..]);
    defer deinitTestApp(&app);

    var args = std.json.ObjectMap.empty;
    defer args.deinit(alloc);
    try args.put(alloc, "path", .{ .string = "docs/tool-index.generated.md" });
    const result = try transactional.zigGeneratedFileTrace(&app, alloc, .{ .object = args });
    defer json_result.deinitToolResult(alloc, result);
    const policy = result.structuredContent.?.object.get("policy").?.object;
    try std.testing.expectEqualStrings("generated", policy.get("classification").?.string);
    try std.testing.expect(!policy.get("direct_edit_allowed").?.bool);
}

test "organize imports previews sorted unique top-level imports" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;

    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "root/src");
    try tmp.dir.writeFile(io, .{ .sub_path = "root/src/main.zig", .data = "const z = @import(\"z.zig\");\nconst a = @import(\"a.zig\");\nconst z = @import(\"z.zig\");\npub fn main() void {}\n" });

    var app = try testApp(alloc, io, tmp.sub_path[0..]);
    defer deinitTestApp(&app);

    var args = std.json.ObjectMap.empty;
    defer args.deinit(alloc);
    try args.put(alloc, "file", .{ .string = "src/main.zig" });
    const result = try transactional.zigOrganizeImports(&app, alloc, .{ .object = args });
    defer json_result.deinitToolResult(alloc, result);
    const diff = result.structuredContent.?.object.get("files").?.array.items[0].object.get("diff").?.string;
    try std.testing.expect(std.mem.indexOf(u8, diff, "-const z = @import(\"z.zig\");") != null);
}

test "move declaration previews source removal and target append" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;

    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "root/src");
    try tmp.dir.writeFile(io, .{ .sub_path = "root/src/a.zig", .data = "pub fn moved() void {}\npub fn kept() void {}\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "root/src/b.zig", .data = "const std = @import(\"std\");\n" });

    var app = try testApp(alloc, io, tmp.sub_path[0..]);
    defer deinitTestApp(&app);

    var args = std.json.ObjectMap.empty;
    defer args.deinit(alloc);
    try args.put(alloc, "source_file", .{ .string = "src/a.zig" });
    try args.put(alloc, "target_file", .{ .string = "src/b.zig" });
    try args.put(alloc, "name", .{ .string = "moved" });
    const result = try transactional.zigMoveDecl(&app, alloc, .{ .object = args });
    defer json_result.deinitToolResult(alloc, result);
    const files = result.structuredContent.?.object.get("files").?.array.items;
    try std.testing.expect(std.mem.indexOf(u8, files[0].object.get("diff").?.string, "-pub fn moved() void {}") != null);
    try std.testing.expect(std.mem.indexOf(u8, files[1].object.get("diff").?.string, "+pub fn moved() void {}") != null);
}

fn testApp(alloc: std.mem.Allocator, io: std.Io, tmp_sub_path: []const u8) !App {
    const rel_base = try std.fs.path.join(alloc, &.{ ".zig-cache", "tmp", tmp_sub_path });
    defer alloc.free(rel_base);
    const base = try std.Io.Dir.cwd().realPathFileAlloc(io, rel_base, alloc);
    defer alloc.free(base);
    const root = try std.fs.path.join(alloc, &.{ base, "root" });
    defer alloc.free(root);
    var workspace = try zigar.workspace.Workspace.init(alloc, io, root, null);
    errdefer workspace.deinit();
    return .{
        .allocator = alloc,
        .io = io,
        .config = try testConfig(alloc, workspace.root),
        .workspace = workspace,
    };
}

fn deinitTestApp(app: *App) void {
    app.config.deinit(app.allocator);
    app.workspace.deinit();
}

fn testConfig(alloc: std.mem.Allocator, root: []const u8) !zigar.config.Config {
    return .{
        .workspace = try alloc.dupe(u8, root),
        .zig_path = try alloc.dupe(u8, "zig"),
        .zls_path = try alloc.dupe(u8, "zls"),
        .zlint_path = try alloc.dupe(u8, "zlint"),
        .zwanzig_path = try alloc.dupe(u8, "zwanzig"),
        .zflame_path = try alloc.dupe(u8, "zflame"),
        .diff_folded_path = try alloc.dupe(u8, "diff-folded"),
        .host = try alloc.dupe(u8, "127.0.0.1"),
    };
}
