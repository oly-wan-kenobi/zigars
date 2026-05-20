const std = @import("std");
const LspTransport = @import("transport.zig").LspTransport;
const diagnostics_cache = @import("diagnostics_cache.zig");
const json_rpc = @import("../types/json_rpc.zig");
const logging = @import("../logging.zig");
const Mutex = @import("../sync.zig").Mutex;

pub const DiagnosticsCache = diagnostics_cache.DiagnosticsCache;
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
    pub const default_max_diagnostics_bytes: usize = DiagnosticsCache.default_max_bytes;
    pub const default_shutdown_timeout_ms: i64 = 500;

    zls_stdin: ?std.Io.File,
    zls_stdout: ?std.Io.File,
    next_id: std.atomic.Value(i64) = std.atomic.Value(i64).init(1),
    pending: std.AutoHashMapUnmanaged(i64, *PendingRequest),
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

    pub fn init(allocator: std.mem.Allocator, io: std.Io) LspClient {
        return initWithTimeout(allocator, io, 30_000);
    }

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

    fn sendRawRequestWithTimeout(self: *LspClient, allocator: std.mem.Allocator, id: i64, msg: []const u8, timeout_ms: i64, timeout_label: []const u8) ![]const u8 {
        const stdin = self.zls_stdin orelse return error.NotConnected;

        const pending = try self.allocator.create(PendingRequest);
        pending.* = .{ .allocator = self.allocator };
        {
            self.pending_mutex.lock();
            defer self.pending_mutex.unlock();
            try self.pending.put(self.allocator, id, pending);
        }

        errdefer self.removePending(id);

        try self.writeMessage(stdin, msg);

        pending.event.waitTimeout(self.io, .{ .duration = .{ .raw = std.Io.Duration.fromMilliseconds(@max(1, timeout_ms)), .clock = .awake } }) catch {
            self.rememberLastError(timeout_label);
            self.removePending(id);
            return error.RequestTimeout;
        };

        const removed = self.takePending(id) orelse return error.NoResponse;
        defer self.allocator.destroy(removed);
        const response = removed.response orelse {
            return error.NoResponse;
        };

        defer self.allocator.free(response);
        return try allocator.dupe(u8, response);
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

    pub fn getDiagnostics(self: *LspClient, allocator: std.mem.Allocator, uri: []const u8) !?[]const u8 {
        return self.diagnostics.get(allocator, uri);
    }

    pub fn diagnosticsSnapshot(self: *LspClient, allocator: std.mem.Allocator) ![]const []const u8 {
        return self.diagnostics.snapshot(allocator);
    }

    pub fn diagnosticsStatus(self: *LspClient) DiagnosticsStatus {
        return self.diagnostics.status();
    }

    pub fn lastError(self: *LspClient, allocator: std.mem.Allocator) !?[]const u8 {
        self.last_error_mutex.lock();
        defer self.last_error_mutex.unlock();
        const value = self.last_error orelse return null;
        return try allocator.dupe(u8, value);
    }

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

    fn takePending(self: *LspClient, id: i64) ?*PendingRequest {
        self.pending_mutex.lock();
        defer self.pending_mutex.unlock();
        const removed = self.pending.fetchRemove(id) orelse return null;
        return removed.value;
    }

    fn removePending(self: *LspClient, id: i64) void {
        const pending = self.takePending(id) orelse return;
        if (pending.response) |response| self.allocator.free(response);
        self.allocator.destroy(pending);
    }

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

    fn writeMessage(self: *LspClient, stdin: std.Io.File, msg: []const u8) !void {
        self.write_mutex.lock();
        defer self.write_mutex.unlock();
        try LspTransport.writeMessage(stdin, self.io, msg);
    }

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

    pub fn shutdown(self: *LspClient) !void {
        return self.shutdownWithTimeout(self.request_timeout_ms);
    }

    fn shutdownWithTimeout(self: *LspClient, timeout_ms: i64) !void {
        if (self.zls_stdin == null or !self.running.load(.acquire)) return;
        const id = self.next_id.fetchAdd(1, .monotonic);
        const msg = try json_rpc.writeRequest(self.allocator, .{ .integer = id }, "shutdown", .{});
        defer self.allocator.free(msg);
        const response = try self.sendRawRequestWithTimeout(self.allocator, id, msg, timeout_ms, "ShutdownTimeout");
        self.allocator.free(response);
        self.sendRawNotification(self.allocator, "exit") catch |err| {
            if (isBenignExitNotificationError(err)) {
                self.logger.debug("lsp", "exit notification skipped after shutdown response: {}", .{err});
                self.running.store(false, .release);
                return;
            }
            self.rememberLastError(@errorName(err));
            self.logger.warn("lsp", "failed to send exit notification: {}", .{err});
        };
        self.running.store(false, .release);
    }

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

    fn setLastError(self: *LspClient, value: []const u8) !void {
        self.last_error_mutex.lock();
        defer self.last_error_mutex.unlock();
        if (self.last_error) |old| self.allocator.free(old);
        self.last_error = try self.allocator.dupe(u8, value);
    }

    fn rememberLastError(self: *LspClient, value: []const u8) void {
        self.setLastError(value) catch |err| {
            self.logger.warn("lsp", "failed to record last error `{s}`: {}", .{ value, err });
        };
    }
};

fn isBenignExitNotificationError(err: anyerror) bool {
    return err == error.BrokenPipe or err == error.EndOfStream or err == error.NotConnected;
}

// ── Tests ──

fn testIo() std.Io {
    var threaded: std.Io.Threaded = .init(std.heap.smp_allocator, .{});
    return threaded.io();
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

test "closed exit notification is benign after shutdown response" {
    try std.testing.expect(isBenignExitNotificationError(error.BrokenPipe));
    try std.testing.expect(isBenignExitNotificationError(error.EndOfStream));
    try std.testing.expect(isBenignExitNotificationError(error.NotConnected));
    try std.testing.expect(!isBenignExitNotificationError(error.RequestTimeout));
}
