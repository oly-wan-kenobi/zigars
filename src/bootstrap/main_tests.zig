//! Pins that the binary embeds a non-empty semver version string from the manifest.
const std = @import("std");
const version = @import("zigars").manifest.version.string;

test "executable embeds package version" {
    try std.testing.expect(version.len > 0);
    try std.testing.expect(std.mem.indexOfScalar(u8, version, '.') != null);
}
