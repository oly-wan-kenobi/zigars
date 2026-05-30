//! Dispatch layer for fake optional-backend invocations used by release tooling.
//! Two calling conventions are accepted: the backend name in argv[0] (direct
//! symlink/wrapper invocation) or as a subcommand in argv[1] (dispatched
//! through zigars-tools).  Both collapse to the same `Backend` tag.
const std = @import("std");

const cli_io = @import("../common/cli_io.zig");
const release_checks = @import("release_checks.zig");

const Io = std.Io;

/// The optional backend being faked; controls which conformance fixture runs.
pub const Backend = enum {
    zwanzig,
    zlint,
    zflame,
    diff_folded,
};

/// A resolved backend invocation: the `backend` tag identifies which fake to
/// run and `args` is the remaining argument slice after the backend name was
/// consumed.  `args` is a sub-slice of the original `args` passed to `detect`.
pub const Invocation = struct {
    backend: Backend,
    args: []const []const u8,
};

/// Parses `args` and returns an `Invocation` if the first or second argument
/// identifies a fake backend; returns `null` otherwise.  Does not allocate.
pub fn detect(args: []const []const u8) ?Invocation {
    // Keep this logic centralized so callers observe one consistent behavior path.
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

/// Runs the fake backend fixture for `backend`, forwarding `args` (already
/// stripped of the backend name).  Delegates to the corresponding function in
/// `release_checks` which is re-exported from `fake_backends`.
pub fn run(io: Io, backend: Backend, args: []const []const u8) !void {
    return switch (backend) {
        .zwanzig => release_checks.fakeZwanzig(io, args),
        .zlint => release_checks.fakeZlint(io, args),
        .zflame => release_checks.fakeZflame(io, args),
        .diff_folded => release_checks.fakeDiffFolded(io, args),
    };
}

/// Matches a basename (no directory) against known fake-backend executable prefixes.
/// Uses prefix matching so a versioned or platform-suffixed name still resolves.
fn fromExecutable(name: []const u8) ?Backend {
    if (std.mem.startsWith(u8, name, "fake-zwanzig")) return .zwanzig;
    if (std.mem.startsWith(u8, name, "fake-zlint")) return .zlint;
    if (std.mem.startsWith(u8, name, "fake-zflame")) return .zflame;
    if (std.mem.startsWith(u8, name, "fake-diff-folded")) return .diff_folded;
    return null;
}

/// Matches `name` exactly against the subcommand forms used when dispatched
/// through zigars-tools (e.g. `fake-zlint`).
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
