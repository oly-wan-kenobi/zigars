const std = @import("std");
const LspClient = @import("client.zig").LspClient;
const LspTransport = @import("transport.zig").LspTransport;
const logging = @import("../observability/logging.zig");
const lsp_types = @import("types.zig");
const uri_util = @import("uri.zig");
const Mutex = @import("../process/sync.zig").Mutex;

/// Tracks which documents are open in the LSP session.
/// Sends didOpen/didClose notifications as needed.
pub const DocumentState = struct {
    /// Maximum bytes read or retained for one document.
    pub const default_max_document_bytes: usize = 10 * 1024 * 1024;
    /// Maximum retained bytes across unsaved in-memory documents.
    pub const default_max_retained_content_bytes: usize = 64 * 1024 * 1024;
    /// Maximum number of open documents tracked in one LSP session.
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

    /// Metadata retained for a document currently open in ZLS.
    pub const DocInfo = struct {
        version: i64,
        content_hash: u64,
        dirty: bool,
        content: ?[]u8 = null,
    };

    /// Detailed status for a single open document.
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

    /// Aggregate status for all open documents.
    pub const Summary = struct {
        open_documents: usize,
        dirty_documents: usize,
        retained_content_bytes: usize,
        max_document_bytes: usize,
        max_retained_content_bytes: usize,
        max_open_documents: usize,
        last_reopen: ReopenSummary,
    };

    /// Counts outcomes from replaying tracked documents into a new ZLS session.
    pub const ReopenSummary = struct {
        attempted: usize = 0,
        succeeded: usize = 0,
        skipped: usize = 0,
        failed: usize = 0,
    };

    /// Initializes state without filesystem I/O; disk-backed open calls will fail.
    pub fn init(allocator: std.mem.Allocator, workspace_path: []const u8) DocumentState {
        return .{
            .open_docs = .empty,
            .allocator = allocator,
            .workspace_path = workspace_path,
            .logger = .disabled(),
        };
    }

    /// Initializes state with filesystem I/O for reading disk documents.
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

    /// Replaces the logger used for best-effort notification failures.
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
            if (self.open_docs.count() >= self.max_open_documents) return error.OpenDocumentLimitExceeded;
        }

        // Slow path: read file content outside the lock (no mutex held during I/O)
        const content = try self.readDiskDocument(abs_path);
        defer self.allocator.free(content);

        // Re-acquire lock, double-check, then reserve the open document.
        {
            self.mutex.lock();
            defer self.mutex.unlock();

            // Double-check: another thread may have opened it while we were reading
            if (self.open_docs.get(file_uri)) |_| {
                return try ret_allocator.dupe(u8, file_uri);
            }
            if (self.open_docs.count() >= self.max_open_documents) return error.OpenDocumentLimitExceeded;

            try self.open_docs.ensureUnusedCapacity(self.allocator, 1);
            const stored_uri = try self.allocator.dupe(u8, file_uri);
            self.open_docs.putAssumeCapacity(stored_uri, .{
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
                try self.open_docs.ensureUnusedCapacity(self.allocator, 1);
                const stored_uri = try self.allocator.dupe(u8, file_uri);
                self.open_docs.putAssumeCapacity(stored_uri, .{
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

    /// Returns the tracked LSP document version for an open URI.
    pub fn versionForUri(self: *DocumentState, file_uri: []const u8) ?i64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.open_docs.get(file_uri)) |info| return info.version;
        return null;
    }

    /// Returns status for an open URI without transferring ownership.
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

    /// Returns aggregate document counts and byte limits.
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
                disk_content = self.readDiskDocument(path) catch |err| {
                    self.logger.warn("docs", "failed to re-read {s} for reopen: {}", .{ path, err });
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

    fn readDiskDocument(self: *DocumentState, path: []const u8) ![]u8 {
        const io = self.io orelse return error.FileReadError;
        return std.Io.Dir.cwd().readFileAlloc(io, path, self.allocator, std.Io.Limit.limited(self.max_document_bytes)) catch |err| {
            return switch (err) {
                error.FileNotFound => error.FileNotFound,
                error.StreamTooLong => error.DocumentTooLarge,
                else => error.FileReadError,
            };
        };
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

    /// Frees all tracked URI keys and retained in-memory document content.
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

test "DocumentState removes reserved document entries" {
    const alloc = std.testing.allocator;
    var ds = DocumentState.init(alloc, "/tmp");
    defer ds.deinit();

    const uri = try alloc.dupe(u8, "file:///tmp/main.zig");
    try ds.open_docs.put(alloc, uri, .{ .version = 1, .content_hash = 1, .dirty = false });
    ds.removeReserved("file:///tmp/main.zig");

    try std.testing.expectEqual(@as(u32, 0), ds.open_docs.count());
}
