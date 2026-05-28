const std = @import("std");
const LspTransport = @import("transport.zig").LspTransport;
const diagnostics_cache = @import("diagnostics_cache.zig");
const cancellation = @import("cancellation");
const json_rpc = @import("json_rpc.zig");
const logging = @import("../observability/logging.zig");
const Mutex = @import("../process/sync.zig").Mutex;

/// Public diagnostics cache type owned by LSP clients.
pub const DiagnosticsCache = diagnostics_cache.DiagnosticsCache;
/// Snapshot type for diagnostics cache memory and eviction counters.
pub const DiagnosticsStatus = DiagnosticsCache.Status;

/// Pending request waiting for a response from ZLS.
const PendingRequest = struct {
    response: ?[]const u8 = null,
    event: std.Io.Event = .unset,
    allocator: std.mem.Allocator,
};

/// LSP Client: manages request/response correlation with the ZLS child process.
///
/// Architecture:
/// - Main thread calls sendRequest() which blocks until reader thread delivers the response.
/// - Reader thread runs readerLoop() reading ZLS stdout and dispatching responses/notifications.
pub const LspClient = struct {
    /// Default retained diagnostic notification budget.
    pub const default_max_diagnostics_bytes: usize = DiagnosticsCache.default_max_bytes;
    /// Default short timeout for graceful shutdown requests.
    pub const default_shutdown_timeout_ms: i64 = 500;

    zls_stdin: ?std.Io.File,
    zls_stdout: ?std.Io.File,
    next_id: std.atomic.Value(i64) = std.atomic.Value(i64).init(1),
    pending: std.AutoHashMapUnmanaged(i64, *PendingRequest),
    // Lock ordering: request tracking may take pending_mutex before
    // last_error_mutex on response-allocation failure. write_mutex is kept
    // independent and must not be held while acquiring either state mutex.
    pending_mutex: Mutex = .{},
    write_mutex: Mutex = .{},
    diagnostics: DiagnosticsCache,
    last_error: ?[]const u8 = null,
    last_error_mutex: Mutex = .{},
    reader_thread: ?std.Thread = null,
    allocator: std.mem.Allocator,
    io: std.Io,
    request_timeout_ms: i64 = 30_000,
    shutdown_timeout_ms: i64 = default_shutdown_timeout_ms,
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    closing: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    stderr_thread: ?std.Thread = null,
    zls_stderr: ?std.Io.File = null,
    logger: logging.Logger = .disabled(),

    /// Initializes a disconnected client with the default request timeout.
    pub fn init(allocator: std.mem.Allocator, io: std.Io) LspClient {
        return initWithTimeout(allocator, io, 30_000);
    }

    /// Initializes a disconnected client and clamps timeout to at least one millisecond.
    pub fn initWithTimeout(allocator: std.mem.Allocator, io: std.Io, request_timeout_ms: i64) LspClient {
        return .{
            .zls_stdin = null,
            .zls_stdout = null,
            .pending = .empty,
            .pending_mutex = Mutex.init(io),
            .write_mutex = Mutex.init(io),
            .diagnostics = DiagnosticsCache.init(allocator, io, default_max_diagnostics_bytes),
            .last_error_mutex = Mutex.init(io),
            .allocator = allocator,
            .io = io,
            .request_timeout_ms = @max(1, request_timeout_ms),
            .shutdown_timeout_ms = default_shutdown_timeout_ms,
            .logger = logging.Logger.stderr(io),
        };
    }

    /// Replaces the logger used by background reader and stderr threads.
    pub fn setLogger(self: *LspClient, logger: logging.Logger) void {
        self.logger = logger;
    }

    /// Connect to ZLS pipes and start reader thread.
    pub fn connect(self: *LspClient, stdin: std.Io.File, stdout: std.Io.File, stderr: ?std.Io.File) !void {
        self.zls_stdin = stdin;
        self.zls_stdout = stdout;
        self.zls_stderr = stderr;
        self.closing.store(false, .release);
        self.running.store(true, .release);

        self.reader_thread = try std.Thread.spawn(.{}, readerLoop, .{self});

        if (stderr) |_| {
            self.stderr_thread = try std.Thread.spawn(.{}, stderrLoop, .{self});
        }
    }

    /// Send an LSP request and block until the response arrives.
    /// Returns owned response JSON body, or error on timeout/failure.
    pub fn sendRequest(self: *LspClient, allocator: std.mem.Allocator, method: []const u8, params: anytype) ![]const u8 {
        const id = self.next_id.fetchAdd(1, .monotonic);
        const msg = try json_rpc.writeRequest(allocator, .{ .integer = id }, method, params);
        defer allocator.free(msg);
        return self.sendRawRequest(allocator, id, msg);
    }

    /// Send an LSP request and cooperatively emit `$/cancelRequest` if the token is cancelled while waiting.
    pub fn sendRequestCancellable(self: *LspClient, allocator: std.mem.Allocator, method: []const u8, params: anytype, token: cancellation.Token) ![]const u8 {
        if (token.isCancelled()) return error.Cancelled;
        const id = self.next_id.fetchAdd(1, .monotonic);
        const msg = try json_rpc.writeRequest(allocator, .{ .integer = id }, method, params);
        defer allocator.free(msg);
        return self.sendRawRequestWithCancellation(allocator, id, msg, self.request_timeout_ms, "RequestTimeout", token);
    }

    /// Reports whether the client has live pipes and has not observed reader failure.
    pub fn isRunning(self: *LspClient) bool {
        return self.running.load(.acquire) and self.zls_stdin != null and self.zls_stdout != null;
    }

    /// Send an LSP notification (no response expected).
    pub fn sendNotification(self: *LspClient, allocator: std.mem.Allocator, method: []const u8, params: anytype) !void {
        const stdin = self.zls_stdin orelse return error.NotConnected;
        const msg = try json_rpc.writeNotification(allocator, method, params);
        defer allocator.free(msg);
        try self.writeMessage(stdin, msg);
    }

    /// Send a notification with empty params object (avoids [] vs {} serialization issue).
    pub fn sendRawNotification(self: *LspClient, allocator: std.mem.Allocator, method: []const u8) !void {
        const stdin = self.zls_stdin orelse return error.NotConnected;
        var aw: std.Io.Writer.Allocating = .init(allocator);
        defer aw.deinit();
        try aw.writer.print(
            \\{{"jsonrpc":"2.0","method":"{s}","params":{{}}}}
        , .{method});
        const msg = try aw.toOwnedSlice();
        defer allocator.free(msg);
        try self.writeMessage(stdin, msg);
    }

    /// Send LSP initialize request and initialized notification.
    pub fn initialize(self: *LspClient, allocator: std.mem.Allocator, workspace_uri: []const u8) ![]const u8 {
        const id = self.next_id.fetchAdd(1, .monotonic);

        // Build the full request with raw JSON params for precise control
        var aw: std.Io.Writer.Allocating = .init(allocator);
        defer aw.deinit();
        try aw.writer.print(
            \\{{"jsonrpc":"2.0","id":{d},"method":"initialize","params":{{"processId":null,"rootUri":"
        , .{id});
        for (workspace_uri) |c| {
            switch (c) {
                '"' => try aw.writer.writeAll("\\\""),
                '\\' => try aw.writer.writeAll("\\\\"),
                else => try aw.writer.writeByte(c),
            }
        }
        try aw.writer.writeAll(
            \\","capabilities":{"textDocument":{"hover":{"contentFormat":["markdown","plaintext"]},"completion":{"completionItem":{"snippetSupport":false}},"signatureHelp":{"signatureInformation":{"documentationFormat":["markdown","plaintext"]}},"publishDiagnostics":{"relatedInformation":true}}}}}
        );
        const msg = try aw.toOwnedSlice();
        defer allocator.free(msg);

        const response = try self.sendRawRequest(allocator, id, msg);

        // Send initialized notification (must send empty object {}, not [])
        try self.sendRawNotification(allocator, "initialized");

        return response;
    }

    /// Send a pre-serialized LSP request message and wait for the response.
    fn sendRawRequest(self: *LspClient, allocator: std.mem.Allocator, id: i64, msg: []const u8) ![]const u8 {
        return self.sendRawRequestWithTimeout(allocator, id, msg, self.request_timeout_ms, "RequestTimeout");
    }

    /// Sends an LSP request and waits for its response before the deadline.
    fn sendRawRequestWithTimeout(self: *LspClient, allocator: std.mem.Allocator, id: i64, msg: []const u8, timeout_ms: i64, timeout_label: []const u8) ![]const u8 {
        return self.sendRawRequestWithCancellation(allocator, id, msg, timeout_ms, timeout_label, null);
    }

    /// Sends an LSP request and waits for its response, polling a cancellation token when present.
    fn sendRawRequestWithCancellation(self: *LspClient, allocator: std.mem.Allocator, id: i64, msg: []const u8, timeout_ms: i64, timeout_label: []const u8, token: ?cancellation.Token) ![]const u8 {
        const stdin = self.zls_stdin orelse return error.NotConnected;

        const pending = try self.allocator.create(PendingRequest);
        pending.* = .{ .allocator = self.allocator };
        // Register the pending request before writing so the reader thread can
        // attach a fast response without racing the sender.
        {
            self.pending_mutex.lock();
            defer self.pending_mutex.unlock();
            try self.pending.put(self.allocator, id, pending);
        }

        errdefer self.removePending(id);

        try self.writeMessage(stdin, msg);

        const started_ns = std.Io.Clock.now(.awake, self.io).nanoseconds;
        while (true) {
            if (token) |value| {
                if (value.isCancelled()) {
                    self.sendCancelRequestNotification(id);
                    self.removePending(id);
                    return error.Cancelled;
                }
            }
            const now_ns = std.Io.Clock.now(.awake, self.io).nanoseconds;
            const elapsed_ms: i64 = @intCast(@divTrunc(@max(0, now_ns - started_ns), std.time.ns_per_ms));
            if (elapsed_ms >= timeout_ms) {
                self.rememberLastError(timeout_label);
                self.removePending(id);
                return error.RequestTimeout;
            }
            const remaining_ms = timeout_ms - elapsed_ms;
            const wait_ms = @max(1, @min(remaining_ms, 50));
            pending.event.waitTimeout(self.io, .{ .duration = .{ .raw = std.Io.Duration.fromMilliseconds(wait_ms), .clock = .awake } }) catch |err| switch (err) {
                error.Timeout => continue,
                else => {
                    self.rememberLastError(timeout_label);
                    self.removePending(id);
                    return error.RequestTimeout;
                },
            };
            break;
        }

        const removed = self.takePending(id) orelse return error.NoResponse;
        defer self.allocator.destroy(removed);
        const response = removed.response orelse {
            return error.NoResponse;
        };

        defer self.allocator.free(response);
        return try allocator.dupe(u8, response);
    }

    /// Best-effort LSP cancellation notification for an already-sent request.
    fn sendCancelRequestNotification(self: *LspClient, id: i64) void {
        const stdin = self.zls_stdin orelse return;
        var aw: std.Io.Writer.Allocating = .init(self.allocator);
        defer aw.deinit();
        aw.writer.print(
            \\{{"jsonrpc":"2.0","method":"$/cancelRequest","params":{{"id":{d}}}}}
        , .{id}) catch return;
        const msg = aw.toOwnedSlice() catch return;
        defer self.allocator.free(msg);
        self.writeMessage(stdin, msg) catch |err| {
            self.logger.debug("lsp", "cancel notification failed: {}", .{err});
        };
    }

    /// Background thread: reads LSP messages from ZLS stdout, dispatches responses.
    fn readerLoop(self: *LspClient) void {
        const stdout = self.zls_stdout orelse return;
        var reader = LspTransport.Reader.init(stdout, self.io);

        while (self.running.load(.acquire)) {
            const msg = reader.readMessage(self.allocator) catch |err| {
                if (!self.running.load(.acquire) or self.closing.load(.acquire)) return;
                self.logger.warn("lsp", "reader error: {}", .{err});
                self.rememberLastError(@errorName(err));
                self.running.store(false, .release);
                self.signalAllPending();
                return;
            };
            if (msg == null) {
                if (self.closing.load(.acquire)) return;
                self.rememberLastError("EndOfStream");
                self.running.store(false, .release);
                self.signalAllPending();
                return;
            }
            const data = msg.?;
            defer self.allocator.free(data);

            // Parse to check if it's a response (has "id") or notification (has "method")
            const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, data, .{}) catch {
                self.logger.warn("lsp", "failed to parse LSP message", .{});
                continue;
            };
            defer parsed.deinit();

            const obj = switch (parsed.value) {
                .object => |o| o,
                else => continue,
            };

            if (obj.get("id")) |id_val| {
                // Response — find pending request
                const id: i64 = switch (id_val) {
                    .integer => |i| i,
                    else => continue,
                };

                self.pending_mutex.lock();
                defer self.pending_mutex.unlock();
                self.storePendingResponseLocked(id, data);
            } else if (obj.get("method")) |method_val| {
                const method = switch (method_val) {
                    .string => |s| s,
                    else => continue,
                };
                if (std.mem.eql(u8, method, "textDocument/publishDiagnostics")) {
                    self.diagnostics.storeNotification(obj, data) catch |err| {
                        self.logger.warn("lsp", "failed to store diagnostics: {}", .{err});
                    };
                }
            }
        }
    }

    /// Returns an owned cached publishDiagnostics message for a URI, when present.
    pub fn getDiagnostics(self: *LspClient, allocator: std.mem.Allocator, uri: []const u8) !?[]const u8 {
        return self.diagnostics.get(allocator, uri);
    }

    /// Returns owned cached diagnostics messages in receipt order.
    pub fn diagnosticsSnapshot(self: *LspClient, allocator: std.mem.Allocator) ![]const []const u8 {
        return self.diagnostics.snapshot(allocator);
    }

    /// Returns diagnostics cache memory and eviction counters.
    pub fn diagnosticsStatus(self: *LspClient) DiagnosticsStatus {
        return self.diagnostics.status();
    }

    /// Returns an owned copy of the last reader/shutdown error label.
    pub fn lastError(self: *LspClient, allocator: std.mem.Allocator) !?[]const u8 {
        self.last_error_mutex.lock();
        defer self.last_error_mutex.unlock();
        const value = self.last_error orelse return null;
        return try allocator.dupe(u8, value);
    }

    /// Continuously records ZLS stderr output until the process exits.
    fn stderrLoop(self: *LspClient) void {
        const stderr = self.zls_stderr orelse return;
        var buf: [4096]u8 = undefined;
        while (true) {
            const n = stderr.readStreaming(self.io, &.{&buf}) catch |err| {
                self.logger.debug("lsp", "ZLS stderr reader stopped: {}", .{err});
                return;
            };
            if (n == 0) return;
            self.logger.debug("lsp", "ZLS stderr: {s}", .{buf[0..n]});
        }
    }

    /// Signal all pending requests (e.g., when ZLS crashes).
    fn signalAllPending(self: *LspClient) void {
        self.pending_mutex.lock();
        defer self.pending_mutex.unlock();
        var it = self.pending.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.event.set(self.io);
        }
    }

    /// Takes ownership of a pending request slot by ID.
    fn takePending(self: *LspClient, id: i64) ?*PendingRequest {
        self.pending_mutex.lock();
        defer self.pending_mutex.unlock();
        const removed = self.pending.fetchRemove(id) orelse return null;
        return removed.value;
    }

    /// Removes a pending request without taking its response.
    fn removePending(self: *LspClient, id: i64) void {
        const pending = self.takePending(id) orelse return;
        if (pending.response) |response| self.allocator.free(response);
        self.allocator.destroy(pending);
    }

    /// Stores a response into a pending request while the client mutex is held.
    fn storePendingResponseLocked(self: *LspClient, id: i64, data: []const u8) void {
        if (self.pending.get(id)) |p| {
            if (p.response) |old| {
                self.allocator.free(old);
                p.response = null;
            }
            p.response = self.allocator.dupe(u8, data) catch blk: {
                self.rememberLastError("OutOfMemory");
                break :blk null;
            };
            p.event.set(self.io);
        }
    }

    /// Writes one framed JSON-RPC message to the ZLS process.
    fn writeMessage(self: *LspClient, stdin: std.Io.File, msg: []const u8) !void {
        self.write_mutex.lock();
        defer self.write_mutex.unlock();
        try LspTransport.writeMessage(stdin, self.io, msg);
    }

    /// Gracefully shuts down when possible, closes pipes, and joins reader threads.
    pub fn disconnect(self: *LspClient) void {
        self.closing.store(true, .release);
        self.shutdownWithTimeout(self.shutdown_timeout_ms) catch |err| {
            self.rememberLastError(if (err == error.RequestTimeout) "ShutdownTimeout" else @errorName(err));
        };
        self.running.store(false, .release);
        self.signalAllPending();
        // Close all pipes to signal ZLS to exit and unblock reader threads
        if (self.zls_stdin) |stdin| {
            stdin.close(self.io);
            self.zls_stdin = null;
        }
        if (self.zls_stdout) |stdout| {
            stdout.close(self.io);
            self.zls_stdout = null;
        }
        if (self.zls_stderr) |se| {
            se.close(self.io);
            self.zls_stderr = null;
        }
        // Now safe to join — readers will see EOF from closed pipes
        if (self.reader_thread) |t| {
            t.join();
            self.reader_thread = null;
        }
        if (self.stderr_thread) |t| {
            t.join();
            self.stderr_thread = null;
        }
        self.closing.store(false, .release);
    }

    /// Sends LSP shutdown followed by exit using the request timeout.
    pub fn shutdown(self: *LspClient) !void {
        return self.shutdownWithTimeout(self.request_timeout_ms);
    }

    /// Attempts graceful ZLS shutdown before force cleanup.
    fn shutdownWithTimeout(self: *LspClient, timeout_ms: i64) !void {
        if (self.zls_stdin == null or !self.running.load(.acquire)) return;
        const id = self.next_id.fetchAdd(1, .monotonic);
        const msg = try json_rpc.writeRequest(self.allocator, .{ .integer = id }, "shutdown", .{});
        defer self.allocator.free(msg);
        const response = try self.sendRawRequestWithTimeout(self.allocator, id, msg, timeout_ms, "ShutdownTimeout");
        self.allocator.free(response);
        self.sendRawNotification(self.allocator, "exit") catch |err| {
            self.handleExitNotificationError(err);
            return;
        };
        self.running.store(false, .release);
    }

    /// Classifies exit-notification errors and records unexpected failures.
    fn handleExitNotificationError(self: *LspClient, err: anyerror) void {
        if (isBenignExitNotificationError(err)) {
            self.logger.debug("lsp", "exit notification skipped after shutdown response: {}", .{err});
            self.running.store(false, .release);
            return;
        }
        self.rememberLastError(@errorName(err));
        self.logger.warn("lsp", "failed to send exit notification: {}", .{err});
    }

    /// Disconnects and frees pending responses, diagnostics, and last-error text.
    pub fn deinit(self: *LspClient) void {
        self.disconnect();
        // Free any remaining pending requests
        var it = self.pending.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.*.response) |r| {
                self.allocator.free(r);
            }
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.pending.deinit(self.allocator);

        self.diagnostics.deinit();

        if (self.last_error) |err| {
            self.allocator.free(err);
            self.last_error = null;
        }
    }

    /// Stores the latest client error for later diagnostics.
    fn setLastError(self: *LspClient, value: []const u8) !void {
        self.last_error_mutex.lock();
        defer self.last_error_mutex.unlock();
        if (self.last_error) |old| self.allocator.free(old);
        self.last_error = try self.allocator.dupe(u8, value);
    }

    /// Persists an error message in allocator-owned client state.
    fn rememberLastError(self: *LspClient, value: []const u8) void {
        self.setLastError(value) catch |err| {
            self.logger.warn("lsp", "failed to record last error `{s}`: {}", .{ value, err });
        };
    }
};

/// Reports whether an exit-notification failure can be ignored during shutdown.
fn isBenignExitNotificationError(err: anyerror) bool {
    return err == error.BrokenPipe or err == error.EndOfStream or err == error.NotConnected;
}

// ── Tests ──

/// Creates a threaded IO handle for tests that need file and condition support.
fn testIo() std.Io {
    var threaded: std.Io.Threaded = .init(std.heap.smp_allocator, .{});
    return threaded.io();
}

/// Creates paired file handles for scripted transport tests.
fn testPipe() !struct { read_end: std.Io.File, write_end: std.Io.File } {
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

test "initWithTimeout clamps timeout and lastError returns owned copy" {
    const alloc = std.testing.allocator;
    const io = testIo();
    var client = LspClient.initWithTimeout(alloc, io, 0);
    defer client.deinit();

    try std.testing.expectEqual(@as(i64, 1), client.request_timeout_ms);
    try client.setLastError("RequestTimeout");
    const first = (try client.lastError(alloc)).?;
    defer alloc.free(first);
    try std.testing.expectEqualStrings("RequestTimeout", first);

    try client.setLastError("EndOfStream");
    const second = (try client.lastError(alloc)).?;
    defer alloc.free(second);
    try std.testing.expectEqualStrings("EndOfStream", second);
    try std.testing.expectEqualStrings("RequestTimeout", first);
}

test "duplicate LSP response replaces pending response buffer" {
    const alloc = std.testing.allocator;
    const io = testIo();
    var client = LspClient.init(alloc, io);
    defer client.deinit();

    const pending = try alloc.create(PendingRequest);
    pending.* = .{ .allocator = alloc };
    try client.pending.put(alloc, 7, pending);

    client.pending_mutex.lock();
    client.storePendingResponseLocked(7, "{\"id\":7,\"result\":\"first\"}");
    client.storePendingResponseLocked(7, "{\"id\":7,\"result\":\"second\"}");
    client.pending_mutex.unlock();

    const removed = client.takePending(7) orelse return error.TestUnexpectedResult;
    defer alloc.destroy(removed);
    defer if (removed.response) |response| alloc.free(response);
    try std.testing.expect(std.mem.indexOf(u8, removed.response.?, "second") != null);
}

test "setLogger swaps logger and disabled sink remains quiet" {
    const alloc = std.testing.allocator;
    const io = testIo();
    var client = LspClient.init(alloc, io);
    defer client.deinit();

    client.setLogger(logging.Logger.disabled());
    client.logger.warn("lsp", "ignored", .{});
}

test "storePendingResponseLocked handles allocation failure and signals waiter" {
    const alloc = std.testing.allocator;
    const io = testIo();
    var client = LspClient.init(alloc, io);
    defer {
        client.allocator = alloc;
        client.deinit();
    }
    client.setLogger(logging.Logger.disabled());

    const pending = try alloc.create(PendingRequest);
    pending.* = .{ .allocator = alloc };
    try client.pending.put(alloc, 11, pending);

    var failing = std.testing.FailingAllocator.init(alloc, .{ .fail_index = 0 });
    client.allocator = failing.allocator();

    client.pending_mutex.lock();
    client.storePendingResponseLocked(11, "{\"jsonrpc\":\"2.0\",\"id\":11,\"result\":true}");
    client.pending_mutex.unlock();

    client.allocator = alloc;
    try std.testing.expect(pending.response == null);
    try pending.event.waitTimeout(io, .{ .duration = .{ .raw = std.Io.Duration.fromMilliseconds(1), .clock = .awake } });
}

test "signalAllPending wakes every outstanding request" {
    const alloc = std.testing.allocator;
    const io = testIo();
    var client = LspClient.init(alloc, io);
    defer client.deinit();

    const pending = try alloc.create(PendingRequest);
    pending.* = .{ .allocator = alloc };
    try client.pending.put(alloc, 21, pending);

    client.signalAllPending();
    try pending.event.waitTimeout(io, .{ .duration = .{ .raw = std.Io.Duration.fromMilliseconds(1), .clock = .awake } });
}

test "exit notification error handler classifies benign and hard failures" {
    const alloc = std.testing.allocator;
    const io = testIo();
    var client = LspClient.init(alloc, io);
    defer client.deinit();
    client.setLogger(logging.Logger.disabled());

    client.running.store(true, .release);
    client.handleExitNotificationError(error.NotConnected);
    try std.testing.expect(!client.running.load(.acquire));
    try std.testing.expect(try client.lastError(alloc) == null);

    client.running.store(true, .release);
    client.handleExitNotificationError(error.AccessDenied);
    try std.testing.expect(client.running.load(.acquire));
    const last = (try client.lastError(alloc)).?;
    defer alloc.free(last);
    try std.testing.expectEqualStrings("AccessDenied", last);
}

test "shutdown treats missing exit pipe as benign after response" {
    const alloc = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const to_server = try testPipe();

    var client = LspClient.init(alloc, io);
    defer client.deinit();
    client.setLogger(logging.Logger.disabled());
    client.zls_stdin = to_server.write_end;
    client.running.store(true, .release);

    // Responder fixture state shared by the scripted transport.
    const Responder = struct {
        fn run(c: *LspClient, read_end: std.Io.File, thread_io: std.Io) void {
            defer read_end.close(thread_io);
            var reader = LspTransport.Reader.init(read_end, thread_io);
            const maybe_msg = reader.readMessage(std.heap.smp_allocator) catch |err| return c.rememberLastError(@errorName(err));
            if (maybe_msg) |msg| std.heap.smp_allocator.free(msg);

            c.pending_mutex.lock();
            defer c.pending_mutex.unlock();
            const pending = c.pending.get(1) orelse return;
            pending.response = c.allocator.dupe(u8, "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":null}") catch |err| return c.rememberLastError(@errorName(err));
            if (c.zls_stdin) |stdin| {
                stdin.close(thread_io);
                c.zls_stdin = null;
            }
            pending.event.set(thread_io);
        }
    };

    const responder = try std.Thread.spawn(.{}, Responder.run, .{ &client, to_server.read_end, io });
    try client.shutdownWithTimeout(1000);
    responder.join();

    try std.testing.expect(!client.running.load(.acquire));
    try std.testing.expect(client.zls_stdin == null);
}

test "deinit releases pending response buffers" {
    const alloc = std.testing.allocator;
    const io = testIo();
    var client = LspClient.init(alloc, io);

    const pending = try alloc.create(PendingRequest);
    pending.* = .{
        .allocator = alloc,
        .response = try alloc.dupe(u8, "{\"jsonrpc\":\"2.0\",\"id\":31,\"result\":null}"),
    };
    try client.pending.put(alloc, 31, pending);

    client.deinit();
}

test "closed exit notification is benign after shutdown response" {
    try std.testing.expect(isBenignExitNotificationError(error.BrokenPipe));
    try std.testing.expect(isBenignExitNotificationError(error.EndOfStream));
    try std.testing.expect(isBenignExitNotificationError(error.NotConnected));
    try std.testing.expect(!isBenignExitNotificationError(error.RequestTimeout));
}
