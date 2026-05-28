//! Normalizes fake optional-backend invocation forms for release tooling.
const std = @import("std");

const cli_io = @import("../common/cli_io.zig");
const release_checks = @import("release_checks.zig");

const Io = std.Io;

pub const Backend = enum {
    zwanzig,
    zlint,
    zflame,
    diff_folded,
};

pub const Invocation = struct {
    backend: Backend,
    args: []const []const u8,
};

pub fn detect(args: []const []const u8) ?Invocation {
    if (args.len > 0) {
        const invoked = cli_io.executableName(args[0]);
        if (fromExecutable(invoked)) |backend| {
            return .{ .backend = backend, .args = args[1..] };
        }
    }
    if (args.len > 1) {
        if (fromCommand(args[1])) |backend| {
            return .{ .backend = backend, .args = args[2..] };
        }
    }
    return null;
}

pub fn run(io: Io, backend: Backend, args: []const []const u8) !void {
    return switch (backend) {
        .zwanzig => release_checks.fakeZwanzig(io, args),
        .zlint => release_checks.fakeZlint(io, args),
        .zflame => release_checks.fakeZflame(io, args),
        .diff_folded => release_checks.fakeDiffFolded(io, args),
    };
}

fn fromExecutable(name: []const u8) ?Backend {
    if (std.mem.startsWith(u8, name, "fake-zwanzig")) return .zwanzig;
    if (std.mem.startsWith(u8, name, "fake-zlint")) return .zlint;
    if (std.mem.startsWith(u8, name, "fake-zflame")) return .zflame;
    if (std.mem.startsWith(u8, name, "fake-diff-folded")) return .diff_folded;
    return null;
}

fn fromCommand(name: []const u8) ?Backend {
    if (std.mem.eql(u8, name, "fake-zwanzig")) return .zwanzig;
    if (std.mem.eql(u8, name, "fake-zlint")) return .zlint;
    if (std.mem.eql(u8, name, "fake-zflame")) return .zflame;
    if (std.mem.eql(u8, name, "fake-diff-folded")) return .diff_folded;
    return null;
}

test "detect normalizes executable and subcommand forms" {
    const executable = detect(&.{ "/tmp/fake-zlint", "--json" }).?;
    try std.testing.expectEqual(Backend.zlint, executable.backend);
    try std.testing.expectEqual(@as(usize, 1), executable.args.len);
    try std.testing.expectEqualStrings("--json", executable.args[0]);

    const subcommand = detect(&.{ "zigars-tools", "fake-diff-folded", "--svg" }).?;
    try std.testing.expectEqual(Backend.diff_folded, subcommand.backend);
    try std.testing.expectEqual(@as(usize, 1), subcommand.args.len);
    try std.testing.expectEqualStrings("--svg", subcommand.args[0]);

    try std.testing.expect(detect(&.{ "zigars-tools", "artifact-hygiene" }) == null);
}
