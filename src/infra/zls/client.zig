//! LSP client over ZLS: drives JSON-RPC request/response correlation and
//! retains publishDiagnostics notifications in a bounded in-memory cache.
//!
//! Lifecycle: init -> connect -> [send*] -> disconnect/deinit.
//! Reader and stderr background threads are joined in disconnect.
//! All errors are propagated to callers or recorded via rememberLastError;
//! no error is silently discarded.
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
        // Capture all required dependencies up front so later calls can stay predictable.
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

    /// Attach ZLS pipe handles and start the background reader (and optional stderr) threads.
    /// The caller transfers ownership of the file handles; disconnect closes them.
    pub fn connect(self: *LspClient, stdin: std.Io.File, stdout: std.Io.File, stderr: ?std.Io.File) !void {
        // Keep this logic centralized so callers observe one consistent behavior path.
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
    /// Returns allocator-owned response JSON body; caller frees.
    /// Errors: NotConnected, RequestTimeout, NoResponse, or write failure.
    pub fn sendRequest(self: *LspClient, allocator: std.mem.Allocator, method: []const u8, params: anytype) ![]const u8 {
        const id = self.next_id.fetchAdd(1, .monotonic);
        const msg = try json_rpc.writeRequest(allocator, .{ .integer = id }, method, params);
        defer allocator.free(msg);
        return self.sendRawRequest(allocator, id, msg);
    }

    /// Send an LSP request, emitting `$/cancelRequest` and returning error.Cancelled if the token fires.
    /// The cancel notification is best-effort; ZLS may still deliver the response.
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

    /// Send a notification with an empty params object `{}`.
    /// Use instead of sendNotification(.{}) when the spec requires an object,
    /// not an empty array, to avoid LSP server parse errors.
    pub fn sendRawNotification(self: *LspClient, allocator: std.mem.Allocator, method: []const u8) !void {
        // Keep this logic centralized so callers observe one consistent behavior path.
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

    /// Perform the LSP handshake: send `initialize` then `initialized`.
    /// `workspace_uri` is JSON-escaped inline; the response body is allocator-owned.
    /// Must be called once after connect and before any other requests.
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

    /// Send a pre-serialized LSP message and wait for the response using the configured timeout.
    fn sendRawRequest(self: *LspClient, allocator: std.mem.Allocator, id: i64, msg: []const u8) ![]const u8 {
        return self.sendRawRequestWithTimeout(allocator, id, msg, self.request_timeout_ms, "RequestTimeout");
    }

    /// Send a pre-serialized LSP message and wait up to `timeout_ms` milliseconds.
    /// `timeout_label` is stored as the last error when the deadline expires.
    fn sendRawRequestWithTimeout(self: *LspClient, allocator: std.mem.Allocator, id: i64, msg: []const u8, timeout_ms: i64, timeout_label: []const u8) ![]const u8 {
        return self.sendRawRequestWithCancellation(allocator, id, msg, timeout_ms, timeout_label, null);
    }

    /// Core send-and-wait: registers a pending slot, writes the message, then polls
    /// the event with 50 ms slices until the response arrives, the deadline passes,
    /// or the optional cancellation token fires.
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

    /// Emit `$/cancelRequest` for an in-flight request.
    /// Failures are logged at debug level and do not propagate;
    /// the caller is responsible for removing the pending slot on cancellation.
    fn sendCancelRequestNotification(self: *LspClient, id: i64) void {
        // Keep this logic centralized so callers observe one consistent behavior path.
        const stdin = self.zls_stdin orelse return;
        var aw: std.Io.Writer.Allocating = .init(self.allocator);
        defer aw.deinit();
        aw.writer.print(
            \\{{"jsonrpc":"2.0","method":"$/cancelRequest","params":{{"id":{d}}}}}
        , .{id}) catch |err| {
            self.logger.debug("lsp", "cancel notification render failed: {}", .{err});
            return;
        };
        const msg = aw.toOwnedSlice() catch |err| {
            self.logger.debug("lsp", "cancel notification allocation failed: {}", .{err});
            return;
        };
        defer self.allocator.free(msg);
        self.writeMessage(stdin, msg) catch |err| {
            self.logger.debug("lsp", "cancel notification failed: {}", .{err});
        };
    }

    /// Background thread entry point: reads framed LSP messages from ZLS stdout.
    /// Dispatches responses to waiting sendRequest callers and stores diagnostics
    /// notifications in the cache. Sets running=false and signals all pending slots
    /// on any unrecoverable read error or EOF so blocked callers unblock promptly.
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

    /// Returns an allocator-owned copy of the latest publishDiagnostics payload for `uri`, or null.
    pub fn getDiagnostics(self: *LspClient, allocator: std.mem.Allocator, uri: []const u8) !?[]const u8 {
        return self.diagnostics.get(allocator, uri);
    }

    /// Returns all retained diagnostics payloads sorted by insertion sequence.
    /// The slice and each element are allocator-owned; the caller frees both.
    pub fn diagnosticsSnapshot(self: *LspClient, allocator: std.mem.Allocator) ![]const []const u8 {
        return self.diagnostics.snapshot(allocator);
    }

    /// Returns diagnostics cache memory and eviction counters.
    pub fn diagnosticsStatus(self: *LspClient) DiagnosticsStatus {
        return self.diagnostics.status();
    }

    /// Returns an allocator-owned copy of the most recent error label, or null if none.
    /// The label names the failed operation (e.g. "RequestTimeout", "EndOfStream").
    pub fn lastError(self: *LspClient, allocator: std.mem.Allocator) !?[]const u8 {
        self.last_error_mutex.lock();
        defer self.last_error_mutex.unlock();
        const value = self.last_error orelse return null;
        return try allocator.dupe(u8, value);
    }

    /// Background thread entry point: drains ZLS stderr and forwards each chunk to the logger.
    /// Exits when the pipe is closed or an unrecoverable read error occurs.
    fn stderrLoop(self: *LspClient) void {
        // Keep this logic centralized so callers observe one consistent behavior path.
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

    /// Wake every waiting sendRequest caller so they can observe running=false.
    /// Called when ZLS crashes or the reader hits an unrecoverable error.
    fn signalAllPending(self: *LspClient) void {
        self.pending_mutex.lock();
        defer self.pending_mutex.unlock();
        var it = self.pending.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.event.set(self.io);
        }
    }

    /// Removes and returns the pending slot for `id`, or null if not found.
    /// The caller takes ownership and must destroy the returned pointer.
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

    /// Dupes `data` into the pending slot's response buffer and signals the waiter.
    /// If the dupe allocation fails the error is recorded and the event is still set
    /// so the waiter unblocks and can check for a null response.
    /// Caller must hold pending_mutex.
    fn storePendingResponseLocked(self: *LspClient, id: i64, data: []const u8) void {
        // Keep this logic centralized so callers observe one consistent behavior path.
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

    /// Write one Content-Length-framed JSON-RPC message under write_mutex.
    /// write_mutex is independent of pending_mutex; never hold both simultaneously.
    fn writeMessage(self: *LspClient, stdin: std.Io.File, msg: []const u8) !void {
        self.write_mutex.lock();
        defer self.write_mutex.unlock();
        try LspTransport.writeMessage(stdin, self.io, msg);
    }

    /// Graceful teardown: sends LSP shutdown using shutdown_timeout_ms, closes all
    /// pipes, and joins reader and stderr threads. Safe to call more than once.
    pub fn disconnect(self: *LspClient) void {
        // Keep this logic centralized so callers observe one consistent behavior path.
        self.closing.store(true, .release);
        self.shutdownWithTimeout(self.shutdown_timeout_ms) catch |err| {
            self.rememberLastError(if (err == error.RequestTimeout) "ShutdownTimeout" else @errorName(err));
        };
        self.running.store(false, .release);
        self.signalAllPending();
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

    /// Send LSP `shutdown` then `exit` using the full request timeout.
    /// For teardown prefer disconnect, which uses the shorter shutdown_timeout_ms.
    pub fn shutdown(self: *LspClient) !void {
        return self.shutdownWithTimeout(self.request_timeout_ms);
    }

    /// Send `shutdown` and `exit` within `timeout_ms` milliseconds.
    /// A broken pipe or EOF during `exit` is treated as benign because ZLS may
    /// have closed its end immediately after the shutdown response.
    fn shutdownWithTimeout(self: *LspClient, timeout_ms: i64) !void {
        // Keep this logic centralized so callers observe one consistent behavior path.
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
        // Translate internal outcomes into protocol-facing responses without leaking internal details.
        if (isBenignExitNotificationError(err)) {
            self.logger.debug("lsp", "exit notification skipped after shutdown response: {}", .{err});
            self.running.store(false, .release);
            return;
        }
        self.rememberLastError(@errorName(err));
        self.logger.warn("lsp", "failed to send exit notification: {}", .{err});
    }

    /// Disconnect, then free all pending response buffers, the diagnostics cache,
    /// and the last-error string. Must be called exactly once; do not use after.
    pub fn deinit(self: *LspClient) void {
        // Only release owned state here to avoid invalidating borrowed data.
        self.disconnect();
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

    /// Atomically replace the stored error label with an allocator-owned copy of `value`.
    fn setLastError(self: *LspClient, value: []const u8) !void {
        self.last_error_mutex.lock();
        defer self.last_error_mutex.unlock();
        if (self.last_error) |old| self.allocator.free(old);
        self.last_error = try self.allocator.dupe(u8, value);
    }

    /// Store an error label, logging a warning if the allocation itself fails.
    /// Used in contexts where propagating the error is not possible (void returns).
    fn rememberLastError(self: *LspClient, value: []const u8) void {
        self.setLastError(value) catch |err| {
            self.logger.warn("lsp", "failed to record last error `{s}`: {}", .{ value, err });
        };
    }
};

/// White-box accessors for internal-test files; not part of the public API.
pub const TestAccess = struct {
    pub const Pending = PendingRequest;

    pub fn setLastError(client: *LspClient, value: []const u8) !void {
        return client.setLastError(value);
    }

    pub fn storePendingResponseLocked(client: *LspClient, id: i64, data: []const u8) void {
        client.storePendingResponseLocked(id, data);
    }

    pub fn takePending(client: *LspClient, id: i64) ?*Pending {
        return client.takePending(id);
    }

    pub fn signalAllPending(client: *LspClient) void {
        client.signalAllPending();
    }

    pub fn handleExitNotificationError(client: *LspClient, err: anyerror) void {
        client.handleExitNotificationError(err);
    }

    pub fn shutdownWithTimeout(client: *LspClient, timeout_ms: i64) !void {
        return client.shutdownWithTimeout(timeout_ms);
    }

    pub fn benignExitNotificationError(err: anyerror) bool {
        return isBenignExitNotificationError(err);
    }
};

fn isBenignExitNotificationError(err: anyerror) bool {
    return err == error.BrokenPipe or err == error.EndOfStream or err == error.NotConnected;
}
