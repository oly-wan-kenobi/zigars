const std = @import("std");
const documents = @import("documents.zig");
const LspClient = @import("../lsp/client.zig").LspClient;
const LspTransport = @import("../lsp/transport.zig").LspTransport;
const uri_util = @import("../types/uri.zig");

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
test "DocumentState init and deinit" {
    const alloc = std.testing.allocator;
    var ds = DocumentState.init(alloc, "/tmp/workspace");
    defer ds.deinit();

    try std.testing.expectEqualStrings("/tmp/workspace", ds.workspace_path);
    try std.testing.expectEqual(@as(u32, 0), ds.open_docs.count());
}

test "DocumentState double deinit on empty is safe" {
    const alloc = std.testing.allocator;
    var ds = DocumentState.init(alloc, "/tmp");
    ds.deinit();
    // Re-init to avoid use-after-free on implicit deinit
    ds = DocumentState.init(alloc, "/tmp");
    ds.deinit();
}

test "DocumentState removes new sync entry when didOpen fails" {
    const alloc = std.testing.allocator;
    var ds = DocumentState.init(alloc, "/tmp");
    defer ds.deinit();
    var client = LspClient.init(alloc, std.testing.io);
    defer client.deinit();

    try std.testing.expectError(error.NotConnected, ds.syncText(&client, "/tmp/new.zig", "pub fn main() void {}\n", alloc));
    try std.testing.expectEqual(@as(u32, 0), ds.open_docs.count());
}

test "DocumentState rejects oversized unsaved content before LSP write" {
    const alloc = std.testing.allocator;
    var ds = DocumentState.init(alloc, "/tmp");
    defer ds.deinit();
    ds.max_document_bytes = 4;
    var client = LspClient.init(alloc, std.testing.io);
    defer client.deinit();

    try std.testing.expectError(error.DocumentTooLarge, ds.syncText(&client, "/tmp/new.zig", "const too_big = true;\n", alloc));
    try std.testing.expectEqual(@as(u32, 0), ds.open_docs.count());
    try std.testing.expectEqual(@as(usize, 0), ds.retained_content_bytes);
}

test "DocumentState enforces open document budget" {
    const alloc = std.testing.allocator;
    var ds = DocumentState.init(alloc, "/tmp");
    defer ds.deinit();
    ds.max_open_documents = 0;
    var client = LspClient.init(alloc, std.testing.io);
    defer client.deinit();

    try std.testing.expectError(error.OpenDocumentLimitExceeded, ds.syncText(&client, "/tmp/new.zig", "const x = 1;\n", alloc));
    try std.testing.expectEqual(@as(u32, 0), ds.open_docs.count());
    try std.testing.expectEqual(@as(usize, 0), ds.retained_content_bytes);
}

test "DocumentState enforces retained content budget for new sync documents" {
    const alloc = std.testing.allocator;
    var ds = DocumentState.init(alloc, "/tmp");
    defer ds.deinit();
    ds.max_retained_content_bytes = 4;
    var client = LspClient.init(alloc, std.testing.io);
    defer client.deinit();

    try std.testing.expectError(error.RetainedContentLimitExceeded, ds.syncText(&client, "/tmp/new.zig", "const x = 1;\n", alloc));
    try std.testing.expectEqual(@as(u32, 0), ds.open_docs.count());
    try std.testing.expectEqual(@as(usize, 0), ds.retained_content_bytes);
}

test "DocumentState enforces retained content budget for replacements" {
    const alloc = std.testing.allocator;
    var ds = DocumentState.init(alloc, "/tmp");
    defer ds.deinit();
    ds.max_retained_content_bytes = 5;
    var client = LspClient.init(alloc, std.testing.io);
    defer client.deinit();

    const uri = try alloc.dupe(u8, "file:///tmp/main.zig");
    const content = try alloc.dupe(u8, "abc");
    ds.retained_content_bytes = content.len;
    try ds.open_docs.put(alloc, uri, .{
        .version = 3,
        .content_hash = std.hash.Wyhash.hash(0, content),
        .dirty = true,
        .content = content,
    });

    try std.testing.expectError(error.RetainedContentLimitExceeded, ds.syncText(&client, "/tmp/main.zig", "abcdef", alloc));
    const info = ds.open_docs.get("file:///tmp/main.zig") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(i64, 3), info.version);
    try std.testing.expectEqualStrings("abc", info.content.?);
    try std.testing.expectEqual(@as(usize, 3), ds.retained_content_bytes);
}

test "DocumentState tracks retained content bytes" {
    const alloc = std.testing.allocator;
    var ds = DocumentState.init(alloc, "/tmp");
    defer ds.deinit();

    const uri = try alloc.dupe(u8, "file:///tmp/main.zig");
    const content = try alloc.dupe(u8, "const unsaved = true;\n");
    ds.retained_content_bytes = content.len;
    try ds.open_docs.put(alloc, uri, .{
        .version = 1,
        .content_hash = std.hash.Wyhash.hash(0, content),
        .dirty = true,
        .content = content,
    });

    const status = ds.statusForUri("file:///tmp/main.zig") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(content.len, status.content_bytes);
    try std.testing.expectEqual(content.len, status.retained_content_bytes);
    try std.testing.expectEqual(DocumentState.default_max_retained_content_bytes, status.max_retained_content_bytes);
    try std.testing.expectEqual(@as(usize, 1), status.open_documents);
}

test "DocumentState disk sync does not retain clean disk content" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;

    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var ds = DocumentState.initWithIo(alloc, "/tmp", io);
    defer ds.deinit();
    var client = LspClient.init(alloc, io);
    defer client.deinit();
    const pipe = try testPipe();
    defer pipe.read_end.close(io);
    client.zls_stdin = pipe.write_end;

    const uri = try ds.syncDiskText(&client, "/tmp/main.zig", "const disk = true;\n", alloc);
    defer alloc.free(uri);
    pipe.write_end.close(io);
    client.zls_stdin = null;

    const status = ds.statusForUri(uri) orelse return error.TestUnexpectedResult;
    try std.testing.expect(!status.dirty);
    try std.testing.expectEqual(@as(usize, 0), status.content_bytes);
    try std.testing.expectEqual(@as(usize, 0), status.retained_content_bytes);
}

test "DocumentState rolls back existing sync entry when didChange fails" {
    const alloc = std.testing.allocator;
    var ds = DocumentState.init(alloc, "/tmp");
    defer ds.deinit();
    var client = LspClient.init(alloc, std.testing.io);
    defer client.deinit();

    const uri = try alloc.dupe(u8, "file:///tmp/main.zig");
    try ds.open_docs.put(alloc, uri, .{ .version = 3, .content_hash = 111, .dirty = false });

    try std.testing.expectError(error.NotConnected, ds.syncText(&client, "/tmp/main.zig", "const changed = true;\n", alloc));
    const info = ds.open_docs.get("file:///tmp/main.zig") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(i64, 3), info.version);
    try std.testing.expectEqual(@as(u64, 111), info.content_hash);
    try std.testing.expect(!info.dirty);
}

test "DocumentState public status omits retained content" {
    const alloc = std.testing.allocator;
    var ds = DocumentState.init(alloc, "/tmp");
    defer ds.deinit();

    const uri = try alloc.dupe(u8, "file:///tmp/main.zig");
    const content = try alloc.dupe(u8, "const unsaved = true;\n");
    try ds.open_docs.put(alloc, uri, .{
        .version = 9,
        .content_hash = std.hash.Wyhash.hash(0, content),
        .dirty = true,
        .content = content,
    });

    const status = ds.statusForUri("file:///tmp/main.zig") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(i64, 9), status.version);
    try std.testing.expect(status.dirty);
    try std.testing.expect(!@hasField(@TypeOf(status), "content"));
}

test "DocumentState summary reports aggregate state without content" {
    const alloc = std.testing.allocator;
    var ds = DocumentState.init(alloc, "/tmp");
    defer ds.deinit();

    const dirty_uri = try alloc.dupe(u8, "file:///tmp/dirty.zig");
    const dirty_content = try alloc.dupe(u8, "const dirty = true;\n");
    const clean_uri = try alloc.dupe(u8, "file:///tmp/clean.zig");
    ds.retained_content_bytes = dirty_content.len;
    ds.last_reopen = .{ .attempted = 2, .succeeded = 1, .skipped = 0, .failed = 1 };
    try ds.open_docs.put(alloc, dirty_uri, .{
        .version = 1,
        .content_hash = std.hash.Wyhash.hash(0, dirty_content),
        .dirty = true,
        .content = dirty_content,
    });
    try ds.open_docs.put(alloc, clean_uri, .{
        .version = 1,
        .content_hash = 1,
        .dirty = false,
        .content = null,
    });

    const summary = ds.summary();
    try std.testing.expectEqual(@as(usize, 2), summary.open_documents);
    try std.testing.expectEqual(@as(usize, 1), summary.dirty_documents);
    try std.testing.expectEqual(dirty_content.len, summary.retained_content_bytes);
    try std.testing.expectEqual(@as(usize, 2), summary.last_reopen.attempted);
    try std.testing.expectEqual(@as(usize, 1), summary.last_reopen.failed);
    try std.testing.expect(!@hasField(@TypeOf(summary), "content"));
}

test "DocumentState reopens retained unsaved content" {
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
    const abs = try std.fs.path.join(alloc, &.{ root, "main.zig" });
    defer alloc.free(abs);
    const uri = try uri_util.pathToUri(alloc, abs);
    errdefer alloc.free(uri);
    const unsaved = try alloc.dupe(u8, "const unsaved = true;\n");
    errdefer alloc.free(unsaved);

    var ds = DocumentState.initWithIo(alloc, root, io);
    defer ds.deinit();
    try ds.open_docs.put(alloc, uri, .{
        .version = 7,
        .content_hash = std.hash.Wyhash.hash(0, unsaved),
        .dirty = true,
        .content = unsaved,
    });

    const pipe = try testPipe();
    defer pipe.read_end.close(io);
    var client = LspClient.init(alloc, io);
    defer client.deinit();
    client.zls_stdin = pipe.write_end;

    const summary = ds.reopenAll(&client);
    try std.testing.expectEqual(@as(usize, 1), summary.attempted);
    try std.testing.expectEqual(@as(usize, 1), summary.succeeded);
    try std.testing.expectEqual(@as(usize, 0), summary.failed);
    pipe.write_end.close(io);
    client.zls_stdin = null;

    var reader = LspTransport.Reader.init(pipe.read_end, io);
    const msg = (try reader.readMessage(alloc)) orelse return error.TestUnexpectedResult;
    defer alloc.free(msg);
    try std.testing.expect(std.mem.indexOf(u8, msg, "unsaved") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "disk") == null);
}

test "DocumentState reopens disk content from percent-encoded uri" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;

    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "root/dir with spaces");
    try tmp.dir.writeFile(io, .{ .sub_path = "root/dir with spaces/main file.zig", .data = "const disk_with_spaces = true;\n" });

    const rel_base = try std.fs.path.join(alloc, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer alloc.free(rel_base);
    const base_z = try std.Io.Dir.cwd().realPathFileAlloc(io, rel_base, alloc);
    defer alloc.free(base_z);
    const root = try std.fs.path.join(alloc, &.{ base_z[0..], "root" });
    defer alloc.free(root);
    const abs = try std.fs.path.join(alloc, &.{ root, "dir with spaces", "main file.zig" });
    defer alloc.free(abs);
    const uri = try uri_util.pathToUri(alloc, abs);
    errdefer alloc.free(uri);
    try std.testing.expect(std.mem.indexOf(u8, uri, "%20") != null);

    var ds = DocumentState.initWithIo(alloc, root, io);
    defer ds.deinit();
    try ds.open_docs.put(alloc, uri, .{
        .version = 3,
        .content_hash = 0,
        .dirty = false,
        .content = null,
    });

    const pipe = try testPipe();
    defer pipe.read_end.close(io);
    var client = LspClient.init(alloc, io);
    defer client.deinit();
    client.zls_stdin = pipe.write_end;

    const summary = ds.reopenAll(&client);
    try std.testing.expectEqual(@as(usize, 1), summary.attempted);
    try std.testing.expectEqual(@as(usize, 1), summary.succeeded);
    try std.testing.expectEqual(@as(usize, 0), summary.failed);
    pipe.write_end.close(io);
    client.zls_stdin = null;

    var reader = LspTransport.Reader.init(pipe.read_end, io);
    const msg = (try reader.readMessage(alloc)) orelse return error.TestUnexpectedResult;
    defer alloc.free(msg);
    try std.testing.expect(std.mem.indexOf(u8, msg, "disk_with_spaces") != null);
}
