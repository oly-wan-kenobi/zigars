const std = @import("std");

const patch_session = @import("patch_session.zig");

test "file identity hashes existing bytes and matches expected preimages" {
    var identity = try patch_session.identityFromBytes(std.testing.allocator, true, "abc");
    defer identity.deinit(std.testing.allocator);
    try std.testing.expect(identity.exists);
    try std.testing.expectEqual(@as(usize, 3), identity.bytes);
    try std.testing.expect(identity.sha256 != null);

    const expected = [_]patch_session.ExpectedPreimage{.{ .file = "src/main.zig", .identity = identity }};
    try std.testing.expect(patch_session.expectedMatches(&expected, "src/main.zig", identity));
    try std.testing.expect(!patch_session.expectedMatches(&expected, "src/other.zig", identity));
}

test "missing identity only matches missing expected identity" {
    const missing = try patch_session.identityFromBytes(std.testing.allocator, false, "");
    var existing = try patch_session.identityFromBytes(std.testing.allocator, true, "");
    defer existing.deinit(std.testing.allocator);

    const expected = [_]patch_session.ExpectedPreimage{.{ .file = "new.zig", .identity = missing }};
    try std.testing.expect(patch_session.expectedMatches(&expected, "new.zig", missing));
    try std.testing.expect(!patch_session.expectedMatches(&expected, "new.zig", existing));
}

test "session artifact paths are stable and sanitized" {
    const path = try patch_session.preimageArtifactPath(std.testing.allocator, "session-1234", 1, "src/main file.zig");
    defer std.testing.allocator.free(path);
    try std.testing.expectEqualStrings(".zigar-cache/patch-sessions/session-1234/1-src_main_file.zig.preimage", path);
}

test "unified diff preserves existing public line markers" {
    const diff = try patch_session.unifiedDiff(std.testing.allocator, "src/main.zig", "const a = 1;\n", "const a = 2;\n");
    defer std.testing.allocator.free(diff);
    try std.testing.expect(std.mem.indexOf(u8, diff, "-const a = 1;") != null);
    try std.testing.expect(std.mem.indexOf(u8, diff, "+const a = 2;") != null);
}
