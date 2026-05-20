const std = @import("std");
const documents = @import("documents.zig");
const LspClient = @import("../lsp/client.zig").LspClient;

const DocumentState = documents.DocumentState;

fn tmpRoot(allocator: std.mem.Allocator, io: std.Io, tmp_sub_path: []const u8) ![]u8 {
    const rel_base = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", tmp_sub_path });
    defer allocator.free(rel_base);
    const base_z = try std.Io.Dir.cwd().realPathFileAlloc(io, rel_base, allocator);
    defer allocator.free(base_z);
    return try std.fs.path.join(allocator, &.{ base_z[0..], "root" });
}

test "DocumentState ensureOpen enforces open document budget" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;

    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "root");
    try tmp.dir.writeFile(io, .{ .sub_path = "root/main.zig", .data = "const disk = true;\n" });
    const root = try tmpRoot(alloc, io, tmp.sub_path[0..]);
    defer alloc.free(root);

    var ds = DocumentState.initWithIo(alloc, root, io);
    defer ds.deinit();
    ds.max_open_documents = 0;
    var client = LspClient.init(alloc, io);
    defer client.deinit();

    try std.testing.expectError(error.OpenDocumentLimitExceeded, ds.ensureOpen(&client, "main.zig", alloc));
    try std.testing.expectEqual(@as(u32, 0), ds.open_docs.count());
    try std.testing.expectEqual(@as(usize, 0), ds.retained_content_bytes);
}

test "DocumentState ensureOpen enforces disk document byte budget" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;

    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "root");
    try tmp.dir.writeFile(io, .{ .sub_path = "root/main.zig", .data = "const too_big = true;\n" });
    const root = try tmpRoot(alloc, io, tmp.sub_path[0..]);
    defer alloc.free(root);

    var ds = DocumentState.initWithIo(alloc, root, io);
    defer ds.deinit();
    ds.max_document_bytes = 4;
    var client = LspClient.init(alloc, io);
    defer client.deinit();

    try std.testing.expectError(error.DocumentTooLarge, ds.ensureOpen(&client, "main.zig", alloc));
    try std.testing.expectEqual(@as(u32, 0), ds.open_docs.count());
    try std.testing.expectEqual(@as(usize, 0), ds.retained_content_bytes);
}
