const std = @import("std");
const uri_mod = @import("uri.zig");

const pathToUri = uri_mod.pathToUri;
const uriToPath = uri_mod.uriToPath;
const resolvePath = uri_mod.resolvePath;

test "path to uri round trip" {
    const allocator = std.testing.allocator;
    const path = "/home/user/project/src/main.zig";
    const uri = try pathToUri(allocator, path);
    defer allocator.free(uri);
    try std.testing.expectEqualStrings("file:///home/user/project/src/main.zig", uri);

    const back = try uriToPath(allocator, uri);
    defer allocator.free(back);
    try std.testing.expectEqualStrings(path, back);
}

test "pathToUri encodes special characters" {
    const allocator = std.testing.allocator;
    const path = "/home/user/my file#1.zig";
    const uri = try pathToUri(allocator, path);
    defer allocator.free(uri);
    try std.testing.expect(std.mem.indexOf(u8, uri, "%20") != null);
    try std.testing.expect(std.mem.indexOf(u8, uri, "%23") != null);
    try std.testing.expect(std.mem.startsWith(u8, uri, "file:///"));
}

test "uriToPath rejects non-file URIs" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.InvalidUri, uriToPath(allocator, "http://example.com"));
    try std.testing.expectError(error.InvalidUri, uriToPath(allocator, "ftp://files/a.zig"));
    try std.testing.expectError(error.InvalidUri, uriToPath(allocator, ""));
}

test "uriToPath invalid percent encoding" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.InvalidUri, uriToPath(allocator, "file:///a%ZZb"));
    try std.testing.expectError(error.InvalidUri, uriToPath(allocator, "file:///a%GGb"));
}

test "uriToPath decodes lowercase percent escapes" {
    const allocator = std.testing.allocator;
    const path = try uriToPath(allocator, "file:///tmp/a%2fb.zig");
    defer allocator.free(path);
    try std.testing.expectEqualStrings("/tmp/a/b.zig", path);
}

test "pathToUri preserves allowed chars" {
    const allocator = std.testing.allocator;
    const path = "/usr/local/bin/zls-0.16.0";
    const uri = try pathToUri(allocator, path);
    defer allocator.free(uri);
    try std.testing.expectEqualStrings("file:///usr/local/bin/zls-0.16.0", uri);
}

test "round trip with all printable ASCII" {
    const allocator = std.testing.allocator;
    const path = "/test/hello world!@$&()+=[];,";
    const uri = try pathToUri(allocator, path);
    defer allocator.free(uri);
    const back = try uriToPath(allocator, uri);
    defer allocator.free(back);
    try std.testing.expectEqualStrings(path, back);
}

test "resolvePath absolute path returned as-is" {
    const allocator = std.testing.allocator;
    const result = try resolvePath(allocator, "/workspace", "/absolute/path.zig");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("/absolute/path.zig", result);
}

test "resolvePath joins relative to workspace" {
    const allocator = std.testing.allocator;
    const result = try resolvePath(allocator, "/workspace", "src/main.zig");
    defer allocator.free(result);
    const expected = try std.fs.path.join(allocator, &.{ "/workspace", "src/main.zig" });
    defer allocator.free(expected);
    try std.testing.expectEqualStrings(expected, result);
}

test "uri with spaces" {
    const allocator = std.testing.allocator;
    const path = "/home/user/my project/file.zig";
    const uri = try pathToUri(allocator, path);
    defer allocator.free(uri);
    try std.testing.expect(std.mem.indexOf(u8, uri, "%20") != null);

    const back = try uriToPath(allocator, uri);
    defer allocator.free(back);
    try std.testing.expectEqualStrings(path, back);
}
