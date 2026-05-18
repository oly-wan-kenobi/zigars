const std = @import("std");
const LspTransport = @import("transport.zig").LspTransport;
const json_rpc = @import("../types/json_rpc.zig");
const Mutex = @import("../sync.zig").Mutex;

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
    pub const default_max_diagnostics_bytes: usize = 16 * 1024 * 1024;

    zls_stdin: ?std.Io.File,
    zls_stdout: ?std.Io.File,
    next_id: std.atomic.Value(i64) = std.atomic.Value(i64).init(1),
    pending: std.AutoHashMapUnmanaged(i64, *PendingRequest),
    pending_mutex: Mutex = .{},
    write_mutex: Mutex = .{},
    diagnostics: std.StringHashMapUnmanaged([]const u8),
    diagnostics_mutex: Mutex = .{},
    retained_diagnostics_bytes: usize = 0,
    max_diagnostics_bytes: usize = default_max_diagnostics_bytes,
    last_error: ?[]const u8 = null,
    last_error_mutex: Mutex = .{},
    reader_thread: ?std.Thread = null,
    allocator: std.mem.Allocator,
    io: std.Io,
    request_timeout_ms: i64 = 30_000,
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    stderr_thread: ?std.Thread = null,
    zls_stderr: ?std.Io.File = null,

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
            .diagnostics = .empty,
            .diagnostics_mutex = Mutex.init(io),
            .last_error_mutex = Mutex.init(io),
            .allocator = allocator,
            .io = io,
            .request_timeout_ms = @max(1, request_timeout_ms),
        };
    }

    /// Connect to ZLS pipes and start reader thread.
    pub fn connect(self: *LspClient, stdin: std.Io.File, stdout: std.Io.File, stderr: ?std.Io.File) !void {
        self.zls_stdin = stdin;
        self.zls_stdout = stdout;
        self.zls_stderr = stderr;
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
            \\","capabilities":{"textDocument":{"hover":{"contentFormat":["markdown","plaintext"]},"completion":{"completionItem":{"snippetSupport":false}},"signatureHelp":{"signatureInformation":{"documentationFormat":["markdown","plaintext"]}},"publishDiagnostics":{"relatedInformation":true}}}}}}
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

        pending.event.waitTimeout(self.io, .{ .duration = .{ .raw = std.Io.Duration.fromMilliseconds(self.request_timeout_ms), .clock = .awake } }) catch {
            self.setLastError("RequestTimeout") catch {};
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
                if (!self.running.load(.acquire)) return;
                log("LSP reader error: {}", .{err});
                self.setLastError(@errorName(err)) catch {};
                self.running.store(false, .release);
                self.signalAllPending();
                return;
            };
            if (msg == null) {
                self.setLastError("EndOfStream") catch {};
                self.running.store(false, .release);
                self.signalAllPending();
                return;
            }
            const data = msg.?;
            defer self.allocator.free(data);

            // Parse to check if it's a response (has "id") or notification (has "method")
            const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, data, .{}) catch {
                log("Failed to parse LSP message", .{});
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
                    self.storeDiagnostics(obj, data) catch |err| {
                        log("failed to store diagnostics: {}", .{err});
                    };
                }
            }
        }
    }

    fn storeDiagnostics(self: *LspClient, obj: std.json.ObjectMap, data: []const u8) !void {
        const params = switch (obj.get("params") orelse return) {
            .object => |o| o,
            else => return,
        };
        const uri = switch (params.get("uri") orelse return) {
            .string => |s| s,
            else => return,
        };

        const key = try self.allocator.dupe(u8, uri);
        errdefer self.allocator.free(key);
        const value = try self.allocator.dupe(u8, data);
        errdefer self.allocator.free(value);

        self.diagnostics_mutex.lock();
        defer self.diagnostics_mutex.unlock();

        if (self.diagnostics.fetchRemove(uri)) |old| {
            self.subtractDiagnosticsBytesLocked(old.value.len);
            self.allocator.free(old.key);
            self.allocator.free(old.value);
        }
        if (value.len > self.max_diagnostics_bytes) {
            self.allocator.free(key);
            self.allocator.free(value);
            return;
        }
        if (self.retained_diagnostics_bytes > self.max_diagnostics_bytes - value.len) {
            self.clearDiagnosticsLocked();
        }
        try self.diagnostics.put(self.allocator, key, value);
        self.retained_diagnostics_bytes += value.len;
    }

    pub fn getDiagnostics(self: *LspClient, allocator: std.mem.Allocator, uri: []const u8) !?[]const u8 {
        self.diagnostics_mutex.lock();
        defer self.diagnostics_mutex.unlock();
        const stored = self.diagnostics.get(uri) orelse return null;
        return try allocator.dupe(u8, stored);
    }

    pub fn diagnosticsSnapshot(self: *LspClient, allocator: std.mem.Allocator) ![]const []const u8 {
        self.diagnostics_mutex.lock();
        defer self.diagnostics_mutex.unlock();

        var list: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (list.items) |item| allocator.free(item);
            list.deinit(allocator);
        }
        var it = self.diagnostics.iterator();
        while (it.next()) |entry| {
            try list.append(allocator, try allocator.dupe(u8, entry.value_ptr.*));
        }
        return try list.toOwnedSlice(allocator);
    }

    pub const DiagnosticsStatus = struct {
        files: usize,
        retained_bytes: usize,
        max_bytes: usize,
    };

    pub fn diagnosticsStatus(self: *LspClient) DiagnosticsStatus {
        self.diagnostics_mutex.lock();
        defer self.diagnostics_mutex.unlock();
        return .{
            .files = self.diagnostics.count(),
            .retained_bytes = self.retained_diagnostics_bytes,
            .max_bytes = self.max_diagnostics_bytes,
        };
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
            const n = stderr.readStreaming(self.io, &.{&buf}) catch return;
            if (n == 0) return;
            log("ZLS stderr: {s}", .{buf[0..n]});
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
                self.setLastError("OutOfMemory") catch {};
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
        self.shutdown() catch {};
        self.running.store(false, .release);
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
    }

    pub fn shutdown(self: *LspClient) !void {
        if (self.zls_stdin == null or !self.running.load(.acquire)) return;
        const response = self.sendRequest(self.allocator, "shutdown", .{}) catch return;
        self.allocator.free(response);
        self.sendRawNotification(self.allocator, "exit") catch {};
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

        var diag_it = self.diagnostics.iterator();
        while (diag_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.diagnostics.deinit(self.allocator);
        self.diagnostics = .empty;
        self.retained_diagnostics_bytes = 0;

        if (self.last_error) |err| {
            self.allocator.free(err);
            self.last_error = null;
        }
    }

    fn log(comptime fmt: []const u8, args: anytype) void {
        std.debug.print("[zigar/lsp] " ++ fmt ++ "\n", args);
    }

    fn setLastError(self: *LspClient, value: []const u8) !void {
        self.last_error_mutex.lock();
        defer self.last_error_mutex.unlock();
        if (self.last_error) |old| self.allocator.free(old);
        self.last_error = try self.allocator.dupe(u8, value);
    }

    fn clearDiagnosticsLocked(self: *LspClient) void {
        var it = self.diagnostics.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.diagnostics.deinit(self.allocator);
        self.diagnostics = .empty;
        self.retained_diagnostics_bytes = 0;
    }

    fn subtractDiagnosticsBytesLocked(self: *LspClient, bytes: usize) void {
        if (bytes <= self.retained_diagnostics_bytes) {
            self.retained_diagnostics_bytes -= bytes;
        } else {
            self.retained_diagnostics_bytes = 0;
        }
    }
};

// ── Tests ──

fn testIo() std.Io {
    var threaded: std.Io.Threaded = .init(std.heap.smp_allocator, .{});
    return threaded.io();
}

test "LspClient init creates disconnected client" {
    const alloc = std.testing.allocator;
    const io = testIo();
    var client = LspClient.init(alloc, io);
    defer client.deinit();

    try std.testing.expect(client.zls_stdin == null);
    try std.testing.expect(client.zls_stdout == null);
    try std.testing.expect(client.reader_thread == null);
    try std.testing.expect(client.running.load(.acquire) == false);
}

test "sendRequest returns NotConnected when disconnected" {
    const alloc = std.testing.allocator;
    const io = testIo();
    var client = LspClient.init(alloc, io);
    defer client.deinit();

    try std.testing.expectError(error.NotConnected, client.sendRequest(alloc, "textDocument/hover", .{}));
}

test "sendNotification returns NotConnected when disconnected" {
    const alloc = std.testing.allocator;
    const io = testIo();
    var client = LspClient.init(alloc, io);
    defer client.deinit();

    try std.testing.expectError(error.NotConnected, client.sendNotification(alloc, "textDocument/didOpen", .{}));
}

test "sendRawNotification returns NotConnected when disconnected" {
    const alloc = std.testing.allocator;
    const io = testIo();
    var client = LspClient.init(alloc, io);
    defer client.deinit();

    try std.testing.expectError(error.NotConnected, client.sendRawNotification(alloc, "initialized"));
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

test "sendRequest records RequestTimeout when ZLS does not respond" {
    const alloc = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const to_server = try testPipe();
    defer to_server.read_end.close(io);

    var client = LspClient.initWithTimeout(alloc, io, 1);
    client.zls_stdin = to_server.write_end;
    client.running.store(true, .release);
    defer {
        if (client.zls_stdin) |stdin| {
            stdin.close(io);
            client.zls_stdin = null;
        }
        client.running.store(false, .release);
        client.deinit();
    }

    try std.testing.expectError(error.RequestTimeout, client.sendRequest(alloc, "textDocument/hover", .{}));
    const last = (try client.lastError(alloc)).?;
    defer alloc.free(last);
    try std.testing.expectEqualStrings("RequestTimeout", last);
}

test "sendRequest removes pending entry after timeout" {
    const alloc = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const to_server = try testPipe();
    defer to_server.read_end.close(io);

    var client = LspClient.initWithTimeout(alloc, io, 1);
    client.zls_stdin = to_server.write_end;
    client.running.store(true, .release);
    defer {
        if (client.zls_stdin) |stdin| {
            stdin.close(io);
            client.zls_stdin = null;
        }
        client.running.store(false, .release);
        client.deinit();
    }

    try std.testing.expectError(error.RequestTimeout, client.sendRequest(alloc, "textDocument/hover", .{}));
    try std.testing.expectEqual(@as(u32, 0), client.pending.count());
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

test "LspClient bounds retained diagnostics cache" {
    const alloc = std.testing.allocator;
    const io = testIo();
    var client = LspClient.init(alloc, io);
    defer client.deinit();

    const first =
        \\{"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///tmp/a.zig","diagnostics":[]}}
    ;
    const second =
        \\{"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///tmp/b.zig","diagnostics":[]}}
    ;
    client.max_diagnostics_bytes = first.len + 8;

    const parsed_first = try std.json.parseFromSlice(std.json.Value, alloc, first, .{});
    defer parsed_first.deinit();
    const first_obj = switch (parsed_first.value) {
        .object => |o| o,
        else => return error.TestUnexpectedResult,
    };
    try client.storeDiagnostics(first_obj, first);
    try std.testing.expectEqual(@as(usize, 1), client.diagnosticsStatus().files);
    try std.testing.expectEqual(first.len, client.diagnosticsStatus().retained_bytes);

    const parsed_second = try std.json.parseFromSlice(std.json.Value, alloc, second, .{});
    defer parsed_second.deinit();
    const second_obj = switch (parsed_second.value) {
        .object => |o| o,
        else => return error.TestUnexpectedResult,
    };
    try client.storeDiagnostics(second_obj, second);
    try std.testing.expectEqual(@as(usize, 1), client.diagnosticsStatus().files);
    try std.testing.expectEqual(second.len, client.diagnosticsStatus().retained_bytes);
    try std.testing.expect((try client.getDiagnostics(alloc, "file:///tmp/a.zig")) == null);
    const stored_second = (try client.getDiagnostics(alloc, "file:///tmp/b.zig")) orelse return error.TestUnexpectedResult;
    defer alloc.free(stored_second);
    try std.testing.expectEqualStrings(second, stored_second);

    client.max_diagnostics_bytes = second.len - 1;
    try client.storeDiagnostics(second_obj, second);
    try std.testing.expectEqual(@as(usize, 0), client.diagnosticsStatus().files);
    try std.testing.expectEqual(@as(usize, 0), client.diagnosticsStatus().retained_bytes);
}

test "reader EOF stops LSP client and records EndOfStream" {
    const alloc = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const to_server = try testPipe();
    const from_server = try testPipe();
    defer to_server.read_end.close(io);

    var client = LspClient.init(alloc, io);
    defer client.deinit();
    try client.connect(to_server.write_end, from_server.read_end, null);
    from_server.write_end.close(io);

    std.Io.Timeout.sleep(.{ .duration = .{ .raw = std.Io.Duration.fromMilliseconds(20), .clock = .awake } }, io) catch {};
    try std.testing.expect(!client.isRunning());
    const last = (try client.lastError(alloc)).?;
    defer alloc.free(last);
    try std.testing.expectEqualStrings("EndOfStream", last);
}

test "disconnect on already disconnected client is safe" {
    const alloc = std.testing.allocator;
    const io = testIo();
    var client = LspClient.init(alloc, io);
    defer client.deinit();

    // Should not crash
    client.disconnect();
    client.disconnect();
}

const TestPipe = struct { read_end: std.Io.File, write_end: std.Io.File };

fn testPipe() !TestPipe {
    var fds: [2]std.c.fd_t = undefined;
    if (std.c.pipe(&fds) != 0) return error.SystemResources;
    return .{
        .read_end = .{ .handle = fds[0], .flags = .{ .nonblocking = false } },
        .write_end = .{ .handle = fds[1], .flags = .{ .nonblocking = false } },
    };
}

const FakeZls = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    read_end: std.Io.File,
    write_end: std.Io.File,

    fn run(self: *FakeZls) void {
        defer self.read_end.close(self.io);
        defer self.write_end.close(self.io);
        var reader = LspTransport.Reader.init(self.read_end, self.io);
        while (true) {
            const body = reader.readMessage(self.allocator) catch return;
            const msg = body orelse return;
            defer self.allocator.free(msg);

            if (std.mem.indexOf(u8, msg, "\"id\":1") != null) {
                self.writeResponse(1, "{\"capabilities\":{\"hoverProvider\":true}}") catch return;
                self.writeRaw(
                    \\{"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///tmp/fake.zig","diagnostics":[{"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":1}},"severity":2,"source":"fake-zls","message":"fake warning"}]}}
                ) catch return;
            } else if (std.mem.indexOf(u8, msg, "\"id\":2") != null) {
                self.writeResponse(2, "{\"contents\":{\"kind\":\"markdown\",\"value\":\"fake hover\"}}") catch return;
            } else if (std.mem.indexOf(u8, msg, "\"id\":3") != null) {
                self.writeResponse(3, "null") catch return;
                return;
            }
        }
    }

    fn writeResponse(self: *FakeZls, id: i64, result_json: []const u8) !void {
        var aw: std.Io.Writer.Allocating = .init(self.allocator);
        defer aw.deinit();
        try aw.writer.print(
            \\{{"jsonrpc":"2.0","id":{d},"result":{s}}}
        , .{ id, result_json });
        const body = try aw.toOwnedSlice();
        defer self.allocator.free(body);
        try self.writeRaw(body);
    }

    fn writeRaw(self: *FakeZls, body: []const u8) !void {
        try LspTransport.writeMessage(self.write_end, self.io, body);
    }
};

test "LspClient fake ZLS hover and diagnostics roundtrip" {
    const alloc = std.testing.allocator;
    var client_threaded: std.Io.Threaded = .init(std.heap.smp_allocator, .{});
    defer client_threaded.deinit();
    var fake_threaded: std.Io.Threaded = .init(std.heap.smp_allocator, .{});
    defer fake_threaded.deinit();
    const client_io = client_threaded.io();
    const fake_io = fake_threaded.io();
    const to_server = try testPipe();
    const from_server = try testPipe();

    var fake = FakeZls{
        .allocator = std.heap.smp_allocator,
        .io = fake_io,
        .read_end = to_server.read_end,
        .write_end = from_server.write_end,
    };
    const fake_thread = try std.Thread.spawn(.{}, FakeZls.run, .{&fake});

    var client = LspClient.init(alloc, client_io);
    defer client.deinit();
    try client.connect(to_server.write_end, from_server.read_end, null);

    const init_response = try client.initialize(alloc, "file:///tmp");
    defer alloc.free(init_response);
    try std.testing.expect(std.mem.indexOf(u8, init_response, "hoverProvider") != null);

    try client.sendNotification(alloc, "textDocument/didOpen", .{
        .textDocument = .{
            .uri = "file:///tmp/fake.zig",
            .languageId = "zig",
            .version = 1,
            .text = "const x = 1;\n",
        },
    });

    const hover_response = try client.sendRequest(alloc, "textDocument/hover", .{
        .textDocument = .{ .uri = "file:///tmp/fake.zig" },
        .position = .{ .line = 0, .character = 6 },
    });
    defer alloc.free(hover_response);
    try std.testing.expect(std.mem.indexOf(u8, hover_response, "fake hover") != null);

    const diagnostics = try client.getDiagnostics(alloc, "file:///tmp/fake.zig");
    try std.testing.expect(diagnostics != null);
    defer alloc.free(diagnostics.?);
    try std.testing.expect(std.mem.indexOf(u8, diagnostics.?, "fake warning") != null);

    try client.shutdown();
    fake_thread.join();
}
