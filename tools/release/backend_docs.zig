//! Release gate: optional backend documentation contract.
//! Confirms that docs/backends.md contains the required evidence vocabulary
//! and does not contain stale CLI fragments that would mislead integrators.
const std = @import("std");

const Io = std.Io;
const Allocator = std.mem.Allocator;

/// Reads `docs/backends.md` and checks that required evidence terms are present
/// and stale flag spellings are absent.  Errors from missing required needles
/// and stale tokens are both reported to stderr; the function returns `false`
/// without returning an error so the caller can aggregate multiple failures.
/// Allocation is fully freed before returning.
pub fn checkOptionalBackendContracts(allocator: Allocator, io: Io) !bool {
    const path = "docs/backends.md";
    const bytes = readFileAlloc(allocator, io, path, 1024 * 1024) catch |err| {
        try stderrPrint(io, "backend-contract check could not read {s}: {s}\n", .{ path, @errorName(err) });
        return false;
    };
    defer allocator.free(bytes);
    var ok = true;
    const required = [_][]const u8{
        "--dump-cfg",
        "--dump-exploded-graph",
        "--dump-annotated-cfg",
        "--dump-path-trace",
        "zflame recursive",
        "--title=<title>",
        "--colors=<palette>",
        "diff-folded --output=",
        "--zlint-path",
        "zlint --format json",
        "zlint --print-ast",
        "zlint --format json (--fix|--fix-dangerously)",
        "zlint --rules --format json",
        "ZIGARS_ZLINT_PATH",
        "zig_profile_plan",
        "zigars_backend_guidance",
        "capture semantics",
        "artifact metadata",
        "Release Readiness",
        "backend compatibility matrix",
        "ZLS Conformance",
        "tools/release/real_backend_pins.json",
        ".github/scripts/setup-real-backends.sh",
        "Repo-pinned release validation",
    };
    for (required) |needle| {
        if (std.mem.indexOf(u8, bytes, needle) == null) {
            try stderrPrint(io, "backend-contract check missing `{s}` in {s}\n", .{ needle, path });
            ok = false;
        }
    }
    // Stale fragments were removed when the backend CLI was updated; their
    // presence means the docs page was not refreshed alongside the change.
    const stale = [_][]const u8{
        "zflame guess",
        "--palette",
        "diff-folded before.folded after.folded >",
    };
    for (stale) |needle| {
        if (std.mem.indexOf(u8, bytes, needle) != null) {
            try stderrPrint(io, "backend-contract check found stale `{s}` in {s}\n", .{ needle, path });
            ok = false;
        }
    }
    return ok;
}

/// Reads a repository-relative file with a byte limit.
fn readFileAlloc(allocator: Allocator, io: Io, path: []const u8, max_bytes: usize) ![]u8 {
    return Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_bytes));
}

/// Writes a formatted diagnostic to stderr.
fn stderrPrint(io: Io, comptime fmt: []const u8, args: anytype) !void {
    var buffer: [4096]u8 = undefined;
    var writer = Io.File.stderr().writer(io, &buffer);
    try writer.interface.print(fmt, args);
    try writer.interface.flush();
}

test "backend docs checker exposes public contract entrypoint" {
    try std.testing.expect(@hasDecl(@This(), "checkOptionalBackendContracts"));
}
