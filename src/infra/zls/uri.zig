const std = @import("std");

/// Convert a file system path to a file:// URI.
/// Caller owns the returned memory.
pub fn pathToUri(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    // file:///absolute/path
    const prefix = "file://";
    var len: usize = prefix.len;

    // Count encoded length
    for (path) |c| {
        len += if (needsEncoding(c)) @as(usize, 3) else 1;
    }

    const buf = try allocator.alloc(u8, len);
    errdefer allocator.free(buf);

    @memcpy(buf[0..prefix.len], prefix);
    var pos: usize = prefix.len;
    for (path) |c| {
        if (needsEncoding(c)) {
            buf[pos] = '%';
            buf[pos + 1] = hexDigit(c >> 4);
            buf[pos + 2] = hexDigit(c & 0xf);
            pos += 3;
        } else {
            buf[pos] = c;
            pos += 1;
        }
    }
    return buf;
}

/// Convert a file:// URI back to a file system path.
/// Caller owns the returned memory.
pub fn uriToPath(allocator: std.mem.Allocator, uri: []const u8) ![]const u8 {
    const prefix = "file://";
    if (!std.mem.startsWith(u8, uri, prefix)) {
        return error.InvalidUri;
    }

    const encoded = uri[prefix.len..];
    // Count decoded length
    var len: usize = 0;
    var i: usize = 0;
    while (i < encoded.len) {
        if (encoded[i] == '%' and i + 2 < encoded.len) {
            len += 1;
            i += 3;
        } else {
            len += 1;
            i += 1;
        }
    }

    const buf = try allocator.alloc(u8, len);
    errdefer allocator.free(buf);

    var pos: usize = 0;
    i = 0;
    while (i < encoded.len) {
        if (encoded[i] == '%' and i + 2 < encoded.len) {
            const hi = unhex(encoded[i + 1]) orelse return error.InvalidUri;
            const lo = unhex(encoded[i + 2]) orelse return error.InvalidUri;
            buf[pos] = (@as(u8, hi) << 4) | @as(u8, lo);
            pos += 1;
            i += 3;
        } else {
            buf[pos] = encoded[i];
            pos += 1;
            i += 1;
        }
    }
    return buf[0..pos];
}

/// Make an absolute path from workspace root and relative path.
/// Caller owns returned memory.
pub fn resolvePath(allocator: std.mem.Allocator, workspace: []const u8, relative: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(relative)) {
        return allocator.dupe(u8, relative);
    }
    return std.fs.path.join(allocator, &.{ workspace, relative });
}

/// Strip `file://` prefix from a URI for display. Does not percent-decode.
pub fn stripFilePrefix(uri: []const u8) []const u8 {
    return if (std.mem.startsWith(u8, uri, "file://")) uri[7..] else uri;
}

/// Reports whether a URI byte must be percent-encoded.
fn needsEncoding(c: u8) bool {
    return switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '-', '.', '_', '~', '/', ':' => false,
        else => true,
    };
}

/// Returns the lowercase hexadecimal digit for a four-bit value.
fn hexDigit(v: u8) u8 {
    return "0123456789ABCDEF"[v & 0xf];
}

/// Decodes one ASCII hexadecimal digit.
fn unhex(c: u8) ?u4 {
    return switch (c) {
        '0'...'9' => @intCast(c - '0'),
        'a'...'f' => @intCast(c - 'a' + 10),
        'A'...'F' => @intCast(c - 'A' + 10),
        else => null,
    };
}
