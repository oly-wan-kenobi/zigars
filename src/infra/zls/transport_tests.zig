//! Tests for LspTransport framing: write path, Reader buffering across message
//! boundaries, error cases (missing/zero Content-Length, truncated body), and
//! large body handling that spans the internal read-ahead buffer.
const std = @import("std");
const transport = @import("transport.zig");

const LspTransport = transport.LspTransport;

/// Builds a bounded in-memory I/O fixture for tests.
fn testIo() std.Io {
    var threaded: std.Io.Threaded = .init(std.heap.smp_allocator, .{});
    return threaded.io();
}

/// Creates paired file handles for scripted transport tests.
fn testPipe() !struct { read_end: std.Io.File, write_end: std.Io.File } {
    // Keep this logic centralized so callers observe one consistent behavior path.
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

/// Reads all available bytes from a test pipe.
fn readPipeAll(file: std.Io.File, io: std.Io, buf: []u8) ![]const u8 {
    // Keep this logic centralized so callers observe one consistent behavior path.
    var total: usize = 0;
    while (total < buf.len) {
        const n = file.readStreaming(io, &.{buf[total..]}) catch |err| switch (err) {
            error.EndOfStream, error.ConnectionResetByPeer => return buf[0..total],
            else => |e| return e,
        };
        if (n == 0) break;
        total += n;
    }
    return buf[0..total];
}

test "writeMessage adds Content-Length framing" {
    const io = testIo();
    const p = try testPipe();
    defer p.read_end.close(io);

    try LspTransport.writeMessage(p.write_end, io, "hello");
    p.write_end.close(io);

    var buf: [64]u8 = undefined;
    const data = try readPipeAll(p.read_end, io, &buf);
    try std.testing.expectEqualStrings("Content-Length: 5\r\n\r\nhello", data);
}

test "writeMessage empty body" {
    const io = testIo();
    const p = try testPipe();
    defer p.read_end.close(io);

    try LspTransport.writeMessage(p.write_end, io, "");
    p.write_end.close(io);

    var buf: [64]u8 = undefined;
    const data = try readPipeAll(p.read_end, io, &buf);
    try std.testing.expectEqualStrings("Content-Length: 0\r\n\r\n", data);
}

test "readPipeAll returns when caller buffer fills" {
    const io = testIo();
    const p = try testPipe();
    defer p.read_end.close(io);
    defer p.write_end.close(io);

    try p.write_end.writeStreamingAll(io, "abcd");
    var buf: [4]u8 = undefined;
    const data = try readPipeAll(p.read_end, io, &buf);
    try std.testing.expectEqualStrings("abcd", data);
}

test "Reader parses single message" {
    const alloc = std.testing.allocator;
    const io = testIo();
    const p = try testPipe();
    defer p.read_end.close(io);

    try LspTransport.writeMessage(p.write_end, io, "{\"ok\":true}");
    p.write_end.close(io);

    var reader = LspTransport.Reader.init(p.read_end, io);
    const msg = (try reader.readMessage(alloc)).?;
    defer alloc.free(msg);
    try std.testing.expectEqualStrings("{\"ok\":true}", msg);
}

test "Reader parses multiple sequential messages" {
    const alloc = std.testing.allocator;
    const io = testIo();
    const p = try testPipe();
    defer p.read_end.close(io);

    try LspTransport.writeMessage(p.write_end, io, "msg1");
    try LspTransport.writeMessage(p.write_end, io, "msg2");
    try LspTransport.writeMessage(p.write_end, io, "msg3");
    p.write_end.close(io);

    var reader = LspTransport.Reader.init(p.read_end, io);

    const m1 = (try reader.readMessage(alloc)).?;
    defer alloc.free(m1);
    try std.testing.expectEqualStrings("msg1", m1);

    const m2 = (try reader.readMessage(alloc)).?;
    defer alloc.free(m2);
    try std.testing.expectEqualStrings("msg2", m2);

    const m3 = (try reader.readMessage(alloc)).?;
    defer alloc.free(m3);
    try std.testing.expectEqualStrings("msg3", m3);

    try std.testing.expect(try reader.readMessage(alloc) == null);
}

test "Reader parses a body larger than the buffered header read-ahead" {
    const alloc = std.testing.allocator;
    const io = testIo();
    const p = try testPipe();
    defer p.read_end.close(io);

    const body = try alloc.alloc(u8, 9000);
    defer alloc.free(body);
    @memset(body, 'x');
    try LspTransport.writeMessage(p.write_end, io, body);
    p.write_end.close(io);

    var reader = LspTransport.Reader.init(p.read_end, io);
    const msg = (try reader.readMessage(alloc)).?;
    defer alloc.free(msg);
    try std.testing.expectEqual(body.len, msg.len);
    try std.testing.expectEqual(@as(u8, 'x'), msg[8999]);
}

test "Reader returns null on empty pipe" {
    const alloc = std.testing.allocator;
    const io = testIo();
    const p = try testPipe();
    defer p.read_end.close(io);
    p.write_end.close(io);

    var reader = LspTransport.Reader.init(p.read_end, io);
    try std.testing.expect(try reader.readMessage(alloc) == null);
}

test "Reader returns error on missing Content-Length" {
    const alloc = std.testing.allocator;
    const io = testIo();
    const p = try testPipe();
    defer p.read_end.close(io);

    try p.write_end.writeStreamingAll(io, "Bad-Header: 5\r\n\r\nhello");
    p.write_end.close(io);

    var reader = LspTransport.Reader.init(p.read_end, io);
    try std.testing.expectError(error.MissingContentLength, reader.readMessage(alloc));
}

test "Reader returns error on zero Content-Length" {
    const alloc = std.testing.allocator;
    const io = testIo();
    const p = try testPipe();
    defer p.read_end.close(io);

    try p.write_end.writeStreamingAll(io, "Content-Length: 0\r\n\r\n");
    p.write_end.close(io);

    var reader = LspTransport.Reader.init(p.read_end, io);
    try std.testing.expectError(error.MissingContentLength, reader.readMessage(alloc));
}

test "Reader returns null for truncated message bodies" {
    const alloc = std.testing.allocator;
    const io = testIo();
    const p = try testPipe();
    defer p.read_end.close(io);

    try p.write_end.writeStreamingAll(io, "Content-Length: 5\r\n\r\nhi");
    p.write_end.close(io);

    var reader = LspTransport.Reader.init(p.read_end, io);
    try std.testing.expect(try reader.readMessage(alloc) == null);
}
