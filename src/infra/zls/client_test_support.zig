const std = @import("std");
const LspTransport = @import("transport.zig").LspTransport;

/// Paired file handles used to script in-process LSP transport tests.
pub const TestPipe = struct { read_end: std.Io.File, write_end: std.Io.File };

/// Creates paired file handles for scripted transport tests.
pub fn testPipe() !TestPipe {
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

/// Threaded fake ZLS process that reads requests and writes scripted responses.
pub const FakeZls = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    read_end: std.Io.File,
    write_end: std.Io.File,

    /// Executes queued work and returns owned results or the first failure.
    pub fn run(self: *FakeZls) void {
        defer self.read_end.close(self.io);
        defer self.write_end.close(self.io);
        var reader = LspTransport.Reader.init(self.read_end, self.io);
        while (true) {
            const body = reader.readMessage(self.allocator) catch return;
            const msg = body orelse return;
            defer self.allocator.free(msg);

            const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, msg, .{}) catch return;
            defer parsed.deinit();
            const obj = switch (parsed.value) {
                .object => |o| o,
                else => return,
            };
            const id = if (obj.get("id")) |value| switch (value) {
                .integer => |i| i,
                else => null,
            } else null;
            const method = if (obj.get("method")) |value| switch (value) {
                .string => |s| s,
                else => "",
            } else "";

            if (id != null and id.? == 1 and std.mem.eql(u8, method, "initialize")) {
                self.writeResponse(1, "{\"capabilities\":{\"hoverProvider\":true}}") catch return;
                self.writeRaw(
                    \\{"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///tmp/fake.zig","diagnostics":[{"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":1}},"severity":2,"source":"fake-zls","message":"fake warning"}]}}
                ) catch return;
            } else if (id != null and id.? == 2) {
                self.writeResponse(2, "{\"contents\":{\"kind\":\"markdown\",\"value\":\"fake hover\"}}") catch return;
            } else if (id != null and id.? == 3) {
                self.writeResponse(3, "null") catch return;
            } else if (std.mem.eql(u8, method, "exit")) {
                return;
            }
        }
    }

    /// Writes one scripted JSON-RPC response to the test pipe.
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

    /// Writes raw bytes to the scripted ZLS output stream.
    fn writeRaw(self: *FakeZls, body: []const u8) !void {
        try LspTransport.writeMessage(self.write_end, self.io, body);
    }
};
