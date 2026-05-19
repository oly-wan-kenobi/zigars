const std = @import("std");
const LspClient = @import("../lsp/client.zig").LspClient;
const LspTransport = @import("../lsp/transport.zig").LspTransport;
const logging = @import("../logging.zig");
const lsp_types = @import("../lsp/types.zig");
const uri_util = @import("../types/uri.zig");
const Mutex = @import("../sync.zig").Mutex;

/// Tracks which documents are open in the LSP session.
/// Sends didOpen/didClose notifications as needed.
pub const DocumentState = struct {
    pub const default_max_document_bytes: usize = 10 * 1024 * 1024;
    pub const default_max_retained_content_bytes: usize = 64 * 1024 * 1024;
    pub const default_max_open_documents: usize = 256;

    open_docs: std.StringHashMapUnmanaged(DocInfo),
    allocator: std.mem.Allocator,
    workspace_path: []const u8,
    io: ?std.Io = null,
    logger: logging.Logger = .disabled(),
    mutex: Mutex = .{},
    retained_content_bytes: usize = 0,
    max_document_bytes: usize = default_max_document_bytes,
    max_retained_content_bytes: usize = default_max_retained_content_bytes,
    max_open_documents: usize = default_max_open_documents,
    last_reopen: ReopenSummary = .{},

    pub const DocInfo = struct {
        version: i64,
        content_hash: u64,
        dirty: bool,
        content: ?[]u8 = null,
    };

    pub const DocStatus = struct {
        version: i64,
        content_hash: u64,
        dirty: bool,
        content_bytes: usize,
        retained_content_bytes: usize,
        open_documents: usize,
        max_document_bytes: usize,
        max_retained_content_bytes: usize,
        max_open_documents: usize,
        last_reopen: ReopenSummary,
    };

    pub const Summary = struct {
        open_documents: usize,
        dirty_documents: usize,
        retained_content_bytes: usize,
        max_document_bytes: usize,
        max_retained_content_bytes: usize,
        max_open_documents: usize,
        last_reopen: ReopenSummary,
    };

    pub const ReopenSummary = struct {
        attempted: usize = 0,
        succeeded: usize = 0,
        skipped: usize = 0,
        failed: usize = 0,
    };

    pub fn init(allocator: std.mem.Allocator, workspace_path: []const u8) DocumentState {
        return .{
            .open_docs = .empty,
            .allocator = allocator,
            .workspace_path = workspace_path,
            .logger = .disabled(),
        };
    }

    pub fn initWithIo(allocator: std.mem.Allocator, workspace_path: []const u8, io: std.Io) DocumentState {
        return .{
            .open_docs = .empty,
            .allocator = allocator,
            .workspace_path = workspace_path,
            .io = io,
            .logger = logging.Logger.stderr(io),
            .mutex = Mutex.init(io),
        };
    }

    pub fn setLogger(self: *DocumentState, logger: logging.Logger) void {
        self.logger = logger;
    }

    /// Ensure a file is open in ZLS. Reads file content and sends didOpen if not already open.
    /// `file_path` can be relative (resolved against workspace) or absolute.
    /// Returns a URI allocated with `ret_allocator` (caller must free).
    pub fn ensureOpen(self: *DocumentState, lsp_client: *LspClient, file_path: []const u8, ret_allocator: std.mem.Allocator) ![]const u8 {
        const abs_path = try uri_util.resolvePath(self.allocator, self.workspace_path, file_path);
        defer self.allocator.free(abs_path);

        const file_uri = try uri_util.pathToUri(self.allocator, abs_path);
        defer self.allocator.free(file_uri);

        // Fast path: check under lock, return immediately if already open
        {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.open_docs.get(file_uri)) |_| {
                return try ret_allocator.dupe(u8, file_uri);
            }
        }

        // Slow path: read file content outside the lock (no mutex held during I/O)
        const io = self.io orelse return error.FileReadError;
        const content = std.Io.Dir.cwd().readFileAlloc(io, abs_path, self.allocator, std.Io.Limit.limited(10 * 1024 * 1024)) catch |err| {
            return switch (err) {
                error.FileNotFound => error.FileNotFound,
                else => error.FileReadError,
            };
        };
        defer self.allocator.free(content);

        // Re-acquire lock, double-check, then reserve the open document.
        {
            self.mutex.lock();
            defer self.mutex.unlock();

            // Double-check: another thread may have opened it while we were reading
            if (self.open_docs.get(file_uri)) |_| {
                return try ret_allocator.dupe(u8, file_uri);
            }

            const stored_uri = try self.allocator.dupe(u8, file_uri);
            errdefer self.allocator.free(stored_uri);
            try self.open_docs.put(self.allocator, stored_uri, .{
                .version = 1,
                .content_hash = std.hash.Wyhash.hash(0, content),
                .dirty = false,
                .content = null,
            });
        }

        // Send didOpen without holding the document mutex.
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();

        lsp_client.sendNotification(arena.allocator(), "textDocument/didOpen", lsp_types.DidOpenTextDocumentParams{
            .textDocument = .{
                .uri = file_uri,
                .languageId = "zig",
                .version = 1,
                .text = content,
            },
        }) catch |err| {
            self.removeReserved(file_uri);
            return err;
        };

        return try ret_allocator.dupe(u8, file_uri);
    }

    /// Open or replace an in-memory document in ZLS.
    /// This is used by MCP clients that want diagnostics/hover/code actions for
    /// unsaved text while still keeping all paths scoped to the workspace.
    pub fn syncText(self: *DocumentState, lsp_client: *LspClient, file_path: []const u8, content: []const u8, ret_allocator: std.mem.Allocator) ![]const u8 {
        return self.syncTextInternal(lsp_client, file_path, content, ret_allocator, true);
    }

    /// Open or replace a document in ZLS using the current disk text without
    /// retaining that text as an unsaved buffer.
    pub fn syncDiskText(self: *DocumentState, lsp_client: *LspClient, file_path: []const u8, content: []const u8, ret_allocator: std.mem.Allocator) ![]const u8 {
        return self.syncTextInternal(lsp_client, file_path, content, ret_allocator, false);
    }

    fn syncTextInternal(self: *DocumentState, lsp_client: *LspClient, file_path: []const u8, content: []const u8, ret_allocator: std.mem.Allocator, retain_content: bool) ![]const u8 {
        if (content.len > self.max_document_bytes) return error.DocumentTooLarge;

        const abs_path = try uri_util.resolvePath(self.allocator, self.workspace_path, file_path);
        defer self.allocator.free(abs_path);

        const file_uri = try uri_util.pathToUri(self.allocator, abs_path);
        defer self.allocator.free(file_uri);

        const Notification = struct {
            method: []const u8,
            version: i64,
            did_open: bool,
            previous: ?DocInfo = null,
        };
        const stored_content: ?[]u8 = if (retain_content) try self.allocator.dupe(u8, content) else null;
        var content_moved = false;
        errdefer if (!content_moved) {
            if (stored_content) |retained| self.allocator.free(retained);
        };
        const retained_len: usize = if (retain_content) content.len else 0;
        const notification: Notification = blk: {
            self.mutex.lock();
            defer self.mutex.unlock();
            break :blk if (self.open_docs.getPtr(file_uri)) |info| existing: {
                const previous = info.*;
                const next_retained = retainedBytesAfterReplace(self.retained_content_bytes, contentLen(previous), retained_len) orelse return error.RetainedContentLimitExceeded;
                if (next_retained > self.max_retained_content_bytes) return error.RetainedContentLimitExceeded;
                self.retained_content_bytes = next_retained;
                info.version += 1;
                info.content_hash = std.hash.Wyhash.hash(0, content);
                info.dirty = retain_content;
                info.content = stored_content;
                if (stored_content != null) content_moved = true;
                break :existing Notification{ .method = "textDocument/didChange", .version = info.version, .did_open = false, .previous = previous };
            } else new_doc: {
                if (self.open_docs.count() >= self.max_open_documents) return error.OpenDocumentLimitExceeded;
                const next_retained = retainedBytesAfterReplace(self.retained_content_bytes, 0, retained_len) orelse return error.RetainedContentLimitExceeded;
                if (next_retained > self.max_retained_content_bytes) return error.RetainedContentLimitExceeded;
                const stored_uri = try self.allocator.dupe(u8, file_uri);
                errdefer self.allocator.free(stored_uri);
                try self.open_docs.put(self.allocator, stored_uri, .{
                    .version = 1,
                    .content_hash = std.hash.Wyhash.hash(0, content),
                    .dirty = retain_content,
                    .content = stored_content,
                });
                self.retained_content_bytes = next_retained;
                if (stored_content != null) content_moved = true;
                break :new_doc Notification{ .method = "textDocument/didOpen", .version = 1, .did_open = true };
            };
        };

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        if (!notification.did_open) {
            const Change = struct { text: []const u8 };
            const Params = struct {
                textDocument: lsp_types.VersionedTextDocumentIdentifier,
                contentChanges: []const Change,
            };
            const changes = [_]Change{.{ .text = content }};
            lsp_client.sendNotification(arena.allocator(), notification.method, Params{
                .textDocument = .{ .uri = file_uri, .version = notification.version },
                .contentChanges = &changes,
            }) catch |err| {
                if (notification.previous) |previous| self.restoreDoc(file_uri, previous);
                return err;
            };
            if (notification.previous) |previous| {
                if (previous.content) |previous_content| self.allocator.free(previous_content);
            }
        } else {
            lsp_client.sendNotification(arena.allocator(), notification.method, lsp_types.DidOpenTextDocumentParams{
                .textDocument = .{
                    .uri = file_uri,
                    .languageId = "zig",
                    .version = notification.version,
                    .text = content,
                },
            }) catch |err| {
                if (notification.did_open) self.removeReserved(file_uri);
                return err;
            };
        }

        return try ret_allocator.dupe(u8, file_uri);
    }

    pub fn versionForUri(self: *DocumentState, file_uri: []const u8) ?i64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.open_docs.get(file_uri)) |info| return info.version;
        return null;
    }

    pub fn statusForUri(self: *DocumentState, file_uri: []const u8) ?DocStatus {
        self.mutex.lock();
        defer self.mutex.unlock();
        const info = self.open_docs.get(file_uri) orelse return null;
        return .{
            .version = info.version,
            .content_hash = info.content_hash,
            .dirty = info.dirty,
            .content_bytes = contentLen(info),
            .retained_content_bytes = self.retained_content_bytes,
            .open_documents = self.open_docs.count(),
            .max_document_bytes = self.max_document_bytes,
            .max_retained_content_bytes = self.max_retained_content_bytes,
            .max_open_documents = self.max_open_documents,
            .last_reopen = self.last_reopen,
        };
    }

    pub fn summary(self: *DocumentState) Summary {
        self.mutex.lock();
        defer self.mutex.unlock();
        var dirty_documents: usize = 0;
        var it = self.open_docs.valueIterator();
        while (it.next()) |info| {
            if (info.dirty) dirty_documents += 1;
        }
        return .{
            .open_documents = self.open_docs.count(),
            .dirty_documents = dirty_documents,
            .retained_content_bytes = self.retained_content_bytes,
            .max_document_bytes = self.max_document_bytes,
            .max_retained_content_bytes = self.max_retained_content_bytes,
            .max_open_documents = self.max_open_documents,
            .last_reopen = self.last_reopen,
        };
    }

    /// Close a document in ZLS.
    pub fn closeDoc(self: *DocumentState, lsp_client: *LspClient, file_uri: []const u8) !void {
        self.mutex.lock();
        const removed = self.open_docs.fetchRemove(file_uri);
        if (removed) |kv| self.retained_content_bytes -= contentLen(kv.value);
        self.mutex.unlock();

        if (removed) |kv| {
            defer self.allocator.free(kv.key);
            defer if (kv.value.content) |content| self.allocator.free(content);

            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            lsp_client.sendNotification(arena.allocator(), "textDocument/didClose", lsp_types.DidCloseTextDocumentParams{
                .textDocument = .{ .uri = file_uri },
            }) catch |err| {
                self.logger.warn("docs", "didClose notification failed: {}", .{err});
            };
        }
    }

    /// Reopen all tracked documents in a new ZLS session (after reconnect).
    pub fn reopenAll(self: *DocumentState, lsp_client: *LspClient) ReopenSummary {
        const ReopenDoc = struct {
            uri: []u8,
            version: i64,
            content: ?[]u8,
        };
        var reopen_summary: ReopenSummary = .{};
        var docs: std.ArrayList(ReopenDoc) = .empty;
        defer {
            for (docs.items) |doc| {
                self.allocator.free(doc.uri);
                if (doc.content) |content| self.allocator.free(content);
            }
            docs.deinit(self.allocator);
        }

        self.mutex.lock();
        var it = self.open_docs.iterator();
        while (it.next()) |entry| {
            const uri = self.allocator.dupe(u8, entry.key_ptr.*) catch {
                reopen_summary.skipped += 1;
                continue;
            };
            const content = if (entry.value_ptr.content) |stored|
                self.allocator.dupe(u8, stored) catch {
                    self.allocator.free(uri);
                    reopen_summary.skipped += 1;
                    continue;
                }
            else
                null;
            docs.append(self.allocator, .{ .uri = uri, .version = entry.value_ptr.version, .content = content }) catch {
                self.allocator.free(uri);
                if (content) |bytes| self.allocator.free(bytes);
                reopen_summary.skipped += 1;
                continue;
            };
        }
        self.mutex.unlock();

        for (docs.items) |doc| {
            reopen_summary.attempted += 1;
            const path = uri_util.uriToPath(self.allocator, doc.uri) catch {
                self.logger.warn("docs", "failed to decode {s} for reopen", .{doc.uri});
                reopen_summary.failed += 1;
                continue;
            };
            defer self.allocator.free(path);

            var disk_content: ?[]u8 = null;
            defer if (disk_content) |content| self.allocator.free(content);
            const content = doc.content orelse blk: {
                const io = self.io orelse continue;
                disk_content = std.Io.Dir.cwd().readFileAlloc(io, path, self.allocator, std.Io.Limit.limited(10 * 1024 * 1024)) catch {
                    self.logger.warn("docs", "failed to re-read {s} for reopen", .{path});
                    reopen_summary.failed += 1;
                    continue;
                };
                break :blk disk_content.?;
            };

            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();

            lsp_client.sendNotification(arena.allocator(), "textDocument/didOpen", lsp_types.DidOpenTextDocumentParams{
                .textDocument = .{
                    .uri = doc.uri,
                    .languageId = "zig",
                    .version = doc.version,
                    .text = content,
                },
            }) catch |err| {
                self.logger.warn("docs", "failed to reopen {s}: {}", .{ path, err });
                reopen_summary.failed += 1;
                continue;
            };
            reopen_summary.succeeded += 1;
        }
        self.mutex.lock();
        self.last_reopen = reopen_summary;
        self.mutex.unlock();
        return reopen_summary;
    }

    fn removeReserved(self: *DocumentState, file_uri: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.open_docs.fetchRemove(file_uri)) |kv| {
            self.allocator.free(kv.key);
            self.retained_content_bytes -= contentLen(kv.value);
            if (kv.value.content) |content| self.allocator.free(content);
        }
    }

    fn restoreDoc(self: *DocumentState, file_uri: []const u8, info: DocInfo) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.open_docs.getPtr(file_uri)) |current| {
            self.retained_content_bytes = self.retained_content_bytes - contentLen(current.*) + contentLen(info);
            if (current.content) |content| {
                if (info.content == null or content.ptr != info.content.?.ptr) self.allocator.free(content);
            }
            current.* = info;
        }
    }

    pub fn deinit(self: *DocumentState) void {
        var it = self.open_docs.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            if (entry.value_ptr.content) |content| self.allocator.free(content);
        }
        self.open_docs.deinit(self.allocator);
        self.retained_content_bytes = 0;
    }
};

fn contentLen(info: DocumentState.DocInfo) usize {
    return if (info.content) |content| content.len else 0;
}

fn retainedBytesAfterReplace(retained: usize, old_len: usize, new_len: usize) ?usize {
    if (old_len > retained) return null;
    return std.math.add(usize, retained - old_len, new_len) catch null;
}

// ── Tests ──

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

test "DocumentState removes reserved document entries" {
    const alloc = std.testing.allocator;
    var ds = DocumentState.init(alloc, "/tmp");
    defer ds.deinit();

    const uri = try alloc.dupe(u8, "file:///tmp/main.zig");
    try ds.open_docs.put(alloc, uri, .{ .version = 1, .content_hash = 1, .dirty = false });
    ds.removeReserved("file:///tmp/main.zig");

    try std.testing.expectEqual(@as(u32, 0), ds.open_docs.count());
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
