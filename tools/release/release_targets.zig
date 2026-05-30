//! Canonical release target table: the set of platforms for which zigars
//! publishes pre-built binaries.  The `all` array drives both the build
//! system cross-compilation step and the dist/smoke packaging checks.
const builtin = @import("builtin");
const std = @import("std");

/// One cross-compilation release target.  `triple` is the Zig target triple;
/// `package_name` becomes the archive directory and file base name;
/// `exe_name` is the binary name inside the archive (`.exe` on Windows).
pub const Target = struct {
    triple: []const u8,
    package_name: []const u8,
    exe_name: []const u8 = "zigars",
};

pub const all = [_]Target{
    .{ .triple = "x86_64-linux-gnu", .package_name = "zigars-x86_64-linux-gnu" },
    .{ .triple = "aarch64-linux-gnu", .package_name = "zigars-aarch64-linux-gnu" },
    .{ .triple = "x86_64-linux-musl", .package_name = "zigars-x86_64-linux-musl" },
    .{ .triple = "aarch64-linux-musl", .package_name = "zigars-aarch64-linux-musl" },
    .{ .triple = "x86_64-macos", .package_name = "zigars-x86_64-macos" },
    .{ .triple = "aarch64-macos", .package_name = "zigars-aarch64-macos" },
    .{ .triple = "x86_64-windows-gnu", .package_name = "zigars-x86_64-windows-gnu", .exe_name = "zigars.exe" },
    .{ .triple = "aarch64-windows-gnu", .package_name = "zigars-aarch64-windows-gnu", .exe_name = "zigars.exe" },
};

/// Returns the index into `all` whose `package_name` matches `name` exactly,
/// or `null` if no target has that name.
pub fn indexByPackageName(name: []const u8) ?usize {
    for (all, 0..) |target, i| {
        if (std.mem.eql(u8, target.package_name, name)) return i;
    }
    return null;
}

/// Returns the release target that matches the current host OS and CPU arch,
/// or `null` for unsupported platforms.  On Linux, musl is preferred because
/// it is the default npm/runtime archive and exercises the most common user path.
pub fn native() ?Target {
    return switch (builtin.os.tag) {
        // Prefer musl for Linux host smoke because it is the npm/default runtime archive.
        .linux => switch (builtin.cpu.arch) {
            .x86_64 => all[2],
            .aarch64 => all[3],
            else => null,
        },
        .macos => switch (builtin.cpu.arch) {
            .x86_64 => all[4],
            .aarch64 => all[5],
            else => null,
        },
        .windows => switch (builtin.cpu.arch) {
            .x86_64 => all[6],
            .aarch64 => all[7],
            else => null,
        },
        else => null,
    };
}

test "release targets stay unique and ordered for publishing" {
    const expected = [_]Target{
        .{ .triple = "x86_64-linux-gnu", .package_name = "zigars-x86_64-linux-gnu" },
        .{ .triple = "aarch64-linux-gnu", .package_name = "zigars-aarch64-linux-gnu" },
        .{ .triple = "x86_64-linux-musl", .package_name = "zigars-x86_64-linux-musl" },
        .{ .triple = "aarch64-linux-musl", .package_name = "zigars-aarch64-linux-musl" },
        .{ .triple = "x86_64-macos", .package_name = "zigars-x86_64-macos" },
        .{ .triple = "aarch64-macos", .package_name = "zigars-aarch64-macos" },
        .{ .triple = "x86_64-windows-gnu", .package_name = "zigars-x86_64-windows-gnu", .exe_name = "zigars.exe" },
        .{ .triple = "aarch64-windows-gnu", .package_name = "zigars-aarch64-windows-gnu", .exe_name = "zigars.exe" },
    };

    try std.testing.expectEqual(expected.len, all.len);
    for (all, 0..) |target, i| {
        try std.testing.expectEqualStrings(expected[i].triple, target.triple);
        try std.testing.expectEqualStrings(expected[i].package_name, target.package_name);
        try std.testing.expectEqualStrings(expected[i].exe_name, target.exe_name);
        try std.testing.expect(std.mem.startsWith(u8, target.package_name, "zigars-"));
        try std.testing.expectEqual(i, indexByPackageName(target.package_name).?);
        for (all[0..i]) |previous| {
            try std.testing.expect(!std.mem.eql(u8, previous.triple, target.triple));
            try std.testing.expect(!std.mem.eql(u8, previous.package_name, target.package_name));
        }
    }
    try std.testing.expectEqualStrings("zigars.exe", all[6].exe_name);
    try std.testing.expectEqualStrings("zigars.exe", all[7].exe_name);
    try std.testing.expect(indexByPackageName("missing-target") == null);
}
