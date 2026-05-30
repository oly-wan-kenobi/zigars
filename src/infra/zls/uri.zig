//! URI helpers for the ZLS LSP layer.
//! Provides percent-encoding/decoding between file-system paths and file:// URIs,
//! and workspace-relative path resolution. Caller owns all returned slices.
const std = @import("std");

/// Converts a file-system path to a percent-encoded file:// URI.
/// Caller owns the returned slice. Absolute paths produce file:///absolute/path;
/// the slash directly following the authority prefix is part of the path encoding.
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

/// Decodes a file:// URI back to a file-system path.
/// Returns InvalidUri if the prefix is absent or a percent sequence is malformed.
/// Caller owns the returned slice.
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

/// Resolves a path against the workspace root.
/// If `relative` is already absolute it is duped and returned unchanged;
/// otherwise it is joined to `workspace`. Caller owns the returned slice.
pub fn resolvePath(allocator: std.mem.Allocator, workspace: []const u8, relative: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(relative)) {
        return allocator.dupe(u8, relative);
    }
    return std.fs.path.join(allocator, &.{ workspace, relative });
}

/// Strips the file:// prefix from a URI for display purposes. Does not percent-decode.
/// Returns the input unchanged when the prefix is absent.
pub fn stripFilePrefix(uri: []const u8) []const u8 {
    return if (std.mem.startsWith(u8, uri, "file://")) uri[7..] else uri;
}

/// Reports whether a byte must be percent-encoded in a file:// URI.
/// Unreserved characters (RFC 3986 §2.3) plus '/' and ':' are safe unencoded.
fn needsEncoding(c: u8) bool {
    return switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '-', '.', '_', '~', '/', ':' => false,
        else => true,
    };
}

/// Returns the uppercase hexadecimal digit for a four-bit nibble (RFC 3986 §2.1 recommends uppercase).
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
