const std = @import("std");
const documents = @import("documents.zig");
const LspClient = @import("../lsp/client.zig").LspClient;
const LspTransport = @import("../lsp/transport.zig").LspTransport;

const DocumentState = documents.DocumentState;

fn tmpRoot(allocator: std.mem.Allocator, io: std.Io, tmp_sub_path: []const u8) ![]u8 {
    const rel_base = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", tmp_sub_path });
    defer allocator.free(rel_base);
    const base_z = try std.Io.Dir.cwd().realPathFileAlloc(io, rel_base, allocator);
    defer allocator.free(base_z);
    return try std.fs.path.join(allocator, &.{ base_z[0..], "root" });
}

test "DocumentState emits structured LSP lifecycle notifications" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;

    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var ds = DocumentState.init(alloc, "/tmp");
    defer ds.deinit();
    var client = LspClient.init(alloc, io);
    defer client.deinit();
    const pipe = try testPipe();
    defer pipe.read_end.close(io);
    client.zls_stdin = pipe.write_end;

    const uri = try ds.syncText(&client, "/tmp/main.zig", "const alpha = 1;\n", alloc);
    defer alloc.free(uri);
    const changed_uri = try ds.syncText(&client, "/tmp/main.zig", "const beta = 2;\n", alloc);
    defer alloc.free(changed_uri);
    try std.testing.expectEqualStrings(uri, changed_uri);
    try ds.closeDoc(&client, uri);
    pipe.write_end.close(io);
    client.zls_stdin = null;

    var reader = LspTransport.Reader.init(pipe.read_end, io);
    const open_msg = (try reader.readMessage(alloc)) orelse return error.TestUnexpectedResult;
    defer alloc.free(open_msg);
    const open = try std.json.parseFromSlice(std.json.Value, alloc, open_msg, .{});
    defer open.deinit();
    const open_obj = open.value.object;
    try std.testing.expectEqualStrings("textDocument/didOpen", open_obj.get("method").?.string);
    const open_doc = open_obj.get("params").?.object.get("textDocument").?.object;
    try std.testing.expectEqualStrings(uri, open_doc.get("uri").?.string);
    try std.testing.expectEqual(@as(i64, 1), open_doc.get("version").?.integer);
    try std.testing.expectEqualStrings("zig", open_doc.get("languageId").?.string);
    try std.testing.expectEqualStrings("const alpha = 1;\n", open_doc.get("text").?.string);

    const change_msg = (try reader.readMessage(alloc)) orelse return error.TestUnexpectedResult;
    defer alloc.free(change_msg);
    const change = try std.json.parseFromSlice(std.json.Value, alloc, change_msg, .{});
    defer change.deinit();
    const change_obj = change.value.object;
    try std.testing.expectEqualStrings("textDocument/didChange", change_obj.get("method").?.string);
    const change_params = change_obj.get("params").?.object;
    const change_doc = change_params.get("textDocument").?.object;
    try std.testing.expectEqualStrings(uri, change_doc.get("uri").?.string);
    try std.testing.expectEqual(@as(i64, 2), change_doc.get("version").?.integer);
    const changes = change_params.get("contentChanges").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), changes.len);
    try std.testing.expectEqualStrings("const beta = 2;\n", changes[0].object.get("text").?.string);

    const close_msg = (try reader.readMessage(alloc)) orelse return error.TestUnexpectedResult;
    defer alloc.free(close_msg);
    const close = try std.json.parseFromSlice(std.json.Value, alloc, close_msg, .{});
    defer close.deinit();
    const close_obj = close.value.object;
    try std.testing.expectEqualStrings("textDocument/didClose", close_obj.get("method").?.string);
    const close_doc = close_obj.get("params").?.object.get("textDocument").?.object;
    try std.testing.expectEqualStrings(uri, close_doc.get("uri").?.string);
    try std.testing.expect(try reader.readMessage(alloc) == null);
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

const TestPipe = struct { read_end: std.Io.File, write_end: std.Io.File };

fn testPipe() !TestPipe {
    switch (@import("builtin").os.tag) {
        .windows => return error.SkipZigTest,
        else => {
            const fds = try std.Io.Threaded.pipe2(.{});
            return .{
                .read_end = .{ .handle = fds[0], .flags = .{ .nonblocking = false } },
                .write_end = .{ .handle = fds[1], .flags = .{ .nonblocking = false } },
            };
        },
    }
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
