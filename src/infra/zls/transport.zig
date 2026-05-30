//! LSP transport framing: reads and writes Content-Length-delimited JSON-RPC
//! messages over a pair of Io.File handles (ZLS stdin/stdout).
//!
//! The Reader buffers reads to avoid per-byte syscalls while parsing headers,
//! then reads large bodies directly into the caller-provided allocation.
const std = @import("std");

/// LSP transport: Content-Length framed JSON-RPC.
/// Format: `Content-Length: N\r\n\r\n<N bytes of JSON>`
pub const LspTransport = struct {
    /// Buffered reader for LSP stdout. Persists between readMessage calls
    /// so that bytes read-ahead during header parsing aren't lost.
    pub const Reader = struct {
        file: std.Io.File,
        io: std.Io,
        buf: [8192]u8 = undefined,
        buf_start: usize = 0,
        buf_end: usize = 0,

        /// Creates a reader that borrows the file handle and preserves buffered bytes between messages.
        pub fn init(file: std.Io.File, io: std.Io) Reader {
            return .{ .file = file, .io = io };
        }

        /// Read one byte from the internal buffer, refilling from the file when empty.
        /// Returns null on EOF or connection reset (not an error).
        fn readByte(self: *Reader) !?u8 {
            // Keep this logic centralized so callers observe one consistent behavior path.
            if (self.buf_start >= self.buf_end) {
                const n = self.file.readStreaming(self.io, &.{&self.buf}) catch |err| switch (err) {
                    error.EndOfStream, error.ConnectionResetByPeer => return null,
                    else => return err,
                };
                if (n == 0) return null;
                self.buf_start = 0;
                self.buf_end = n;
            }
            const byte = self.buf[self.buf_start];
            self.buf_start += 1;
            return byte;
        }

        /// Fill `dest` exactly, draining the internal buffer first, then reading
        /// directly from the file. Returns false on EOF before `dest` is full.
        fn readExact(self: *Reader, dest: []u8) !bool {
            var pos: usize = 0;
            while (pos < dest.len) {
                // Drain buffered bytes first
                const buffered = self.buf_end - self.buf_start;
                if (buffered > 0) {
                    const to_copy = @min(buffered, dest.len - pos);
                    @memcpy(dest[pos..][0..to_copy], self.buf[self.buf_start..][0..to_copy]);
                    self.buf_start += to_copy;
                    pos += to_copy;
                } else {
                    // Buffer empty — read directly into destination for large bodies
                    const n = self.file.readStreaming(self.io, &.{dest[pos..]}) catch |err| switch (err) {
                        error.EndOfStream, error.ConnectionResetByPeer => return false,
                        else => return err,
                    };
                    if (n == 0) return false; // EOF
                    pos += n;
                }
            }
            return true;
        }

        /// Parse one LSP message from the stream.
        /// Returns an allocator-owned body slice, or null on clean EOF.
        /// Errors: HeaderTooLarge, MissingContentLength, MessageTooLarge, or IO error.
        /// 10 MiB body limit guards against malformed or hostile ZLS output.
        pub fn readMessage(self: *Reader, allocator: std.mem.Allocator) !?[]const u8 {
            var content_length: ?usize = null;
            var header_buf: [4096]u8 = undefined;
            var header_pos: usize = 0;

            // Read headers byte by byte (from internal buffer — not 1 syscall/byte)
            while (true) {
                const byte = (try self.readByte()) orelse return null;

                if (header_pos >= header_buf.len) return error.HeaderTooLarge;
                header_buf[header_pos] = byte;
                header_pos += 1;

                // Check for \r\n\r\n end of headers
                if (header_pos >= 4 and
                    header_buf[header_pos - 4] == '\r' and
                    header_buf[header_pos - 3] == '\n' and
                    header_buf[header_pos - 2] == '\r' and
                    header_buf[header_pos - 1] == '\n')
                {
                    break;
                }
            }

            // Parse Content-Length from headers
            const headers = header_buf[0..header_pos];
            var line_iter = std.mem.splitSequence(u8, headers, "\r\n");
            while (line_iter.next()) |line| {
                if (line.len == 0) continue;
                const prefix = "Content-Length: ";
                if (std.mem.startsWith(u8, line, prefix)) {
                    content_length = try std.fmt.parseInt(usize, line[prefix.len..], 10);
                }
            }

            const len = content_length orelse return error.MissingContentLength;
            if (len == 0) return error.MissingContentLength;
            if (len > 10 * 1024 * 1024) return error.MessageTooLarge;

            // Read exact body (drains internal buffer first, then reads directly)
            const body = try allocator.alloc(u8, len);
            var body_owned = true;
            defer if (body_owned) allocator.free(body);

            if (!try self.readExact(body)) return null;

            body_owned = false;
            return body;
        }
    };

    /// Frame `data` with a Content-Length header and write both to `file`.
    /// The header is rendered into a stack buffer; no heap allocation required.
    pub fn writeMessage(file: std.Io.File, io: std.Io, data: []const u8) !void {
        // Keep this logic centralized so callers observe one consistent behavior path.
        var header_buf: [64]u8 = undefined;
        var header_w: std.Io.Writer = .fixed(&header_buf);
        try header_w.print("Content-Length: {d}\r\n\r\n", .{data.len});
        const header = header_w.buffered();

        try file.writeStreamingAll(io, header);
        try file.writeStreamingAll(io, data);
    }

    /// One-shot readMessage for callers that do not retain a Reader between calls.
    /// Allocates a temporary Reader on the stack; buffered read-ahead is discarded after return.
    pub fn readMessage(file: std.Io.File, io: std.Io, allocator: std.mem.Allocator) !?[]const u8 {
        var reader = Reader.init(file, io);
        return reader.readMessage(allocator);
    }
};
