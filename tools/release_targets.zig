const builtin = @import("builtin");
const std = @import("std");

pub const Target = struct {
    triple: []const u8,
    package_name: []const u8,
    exe_name: []const u8 = "zigar",
};

pub const all = [_]Target{
    .{ .triple = "x86_64-linux-musl", .package_name = "zigar-x86_64-linux-musl" },
    .{ .triple = "aarch64-linux-musl", .package_name = "zigar-aarch64-linux-musl" },
    .{ .triple = "x86_64-macos", .package_name = "zigar-x86_64-macos" },
    .{ .triple = "aarch64-macos", .package_name = "zigar-aarch64-macos" },
    .{ .triple = "x86_64-windows", .package_name = "zigar-x86_64-windows", .exe_name = "zigar.exe" },
};

pub fn indexByPackageName(name: []const u8) ?usize {
    for (all, 0..) |target, i| {
        if (std.mem.eql(u8, target.package_name, name)) return i;
    }
    return null;
}

pub fn native() ?Target {
    return switch (builtin.os.tag) {
        .linux => switch (builtin.cpu.arch) {
            .x86_64 => all[0],
            .aarch64 => all[1],
            else => null,
        },
        .macos => switch (builtin.cpu.arch) {
            .x86_64 => all[2],
            .aarch64 => all[3],
            else => null,
        },
        .windows => switch (builtin.cpu.arch) {
            .x86_64 => all[4],
            else => null,
        },
        else => null,
    };
}

test "release targets stay unique and ordered for publishing" {
    try std.testing.expectEqual(@as(usize, 5), all.len);
    for (all, 0..) |target, i| {
        try std.testing.expect(std.mem.startsWith(u8, target.package_name, "zigar-"));
        try std.testing.expectEqual(i, indexByPackageName(target.package_name).?);
        for (all[0..i]) |previous| {
            try std.testing.expect(!std.mem.eql(u8, previous.triple, target.triple));
            try std.testing.expect(!std.mem.eql(u8, previous.package_name, target.package_name));
        }
    }
    try std.testing.expectEqualStrings("zigar.exe", all[4].exe_name);
    try std.testing.expect(indexByPackageName("missing-target") == null);
}
