//! Release gate: public claim documentation integrity.
//! Verifies that README.md and docs/tools.md use the evidence-label vocabulary
//! and that neither file contains overstatement tokens that would mislead
//! users about the basis for a claimed capability.
const std = @import("std");

const Io = std.Io;
const Allocator = std.mem.Allocator;

/// Checks required evidence-label terms in README.md and docs/tools.md, then
/// scans each `overclaim_tokens` path for forbidden overstatement fragments.
/// Failures are reported to stderr; `false` is returned to allow the caller
/// to collect all failures before aborting the release check.
pub fn checkPublicClaimDocs(allocator: Allocator, io: Io) !bool {
    var ok = true;
    ok = (try checkDocNeedles(allocator, io, "README.md", &.{
        "Public feature claims use evidence labels",
        "command-backed tools",
        "LSP-backed tools",
        "heuristic/advisory tools",
        "Real\noptional-backend support is claimed only from a release evidence artifact",
        "claim clean A only from\na clean-tree `Release Readiness` evidence package",
    })) and ok;
    ok = (try checkDocNeedles(allocator, io, "docs/tools.md", &.{
        "## Evidence Labels",
        "Command-backed",
        "LSP-backed",
        "Parser-backed",
        "Source-scan-backed",
        "Heuristic/advisory",
        "External-backend-backed",
        "Curated fallback",
        "Real conformance artifact",
    })) and ok;
    ok = (try checkOverclaimTokens(allocator, io)) and ok;
    return ok;
}

fn checkDocNeedles(allocator: Allocator, io: Io, path: []const u8, needles: []const []const u8) !bool {
    const bytes = readFileAlloc(allocator, io, path, 8 * 1024 * 1024) catch |err| {
        try stderrPrint(io, "public-claim docs check could not read {s}: {s}\n", .{ path, @errorName(err) });
        return false;
    };
    defer allocator.free(bytes);
    var ok = true;
    for (needles) |needle| {
        if (std.mem.indexOf(u8, bytes, needle) == null) {
            try stderrPrint(io, "public-claim docs check missing `{s}` in {s}\n", .{ needle, path });
            ok = false;
        }
    }
    return ok;
}

/// A forbidden overstatement entry: `token` must be absent from `path`;
/// `replacement` is the preferred phrasing shown in the diagnostic.
const OverclaimToken = struct {
    path: []const u8,
    token: []const u8,
    replacement: []const u8,
};

const overclaim_tokens = [_]OverclaimToken{
    .{ .path = "README.md", .token = "top notch", .replacement = "use an evidence label and cite the release gate" },
    .{ .path = "README.md", .token = "production-grade", .replacement = "state the tested maturity and release evidence" },
    .{ .path = "README.md", .token = "fully supports", .replacement = "name the supported scenario and evidence type" },
    .{ .path = "README.md", .token = "complete Zig docs", .replacement = "say installed docs/source scan/curated fallback" },
    .{ .path = "README.md", .token = "semantic proof", .replacement = "say parser-backed, command-backed, or heuristic/advisory" },
    .{ .path = "docs/tools.md", .token = "semantic proof", .replacement = "say parser-backed, command-backed, or heuristic/advisory" },
    .{ .path = "docs/maturity.md", .token = "top notch", .replacement = "use the maturity rubric and evidence table" },
    .{ .path = "docs/backends.md", .token = "fully supports", .replacement = "cite the generated compatibility matrix" },
};

fn checkOverclaimTokens(allocator: Allocator, io: Io) !bool {
    var ok = true;
    for (overclaim_tokens) |rule| {
        const bytes = readFileAlloc(allocator, io, rule.path, 1024 * 1024) catch |err| {
            try stderrPrint(io, "public-claim check could not read {s}: {s}\n", .{ rule.path, @errorName(err) });
            ok = false;
            continue;
        };
        defer allocator.free(bytes);
        if (std.mem.indexOf(u8, bytes, rule.token) != null) {
            try stderrPrint(io, "public-claim overstatement in {s}: `{s}` ({s})\n", .{ rule.path, rule.token, rule.replacement });
            ok = false;
        }
    }
    return ok;
}

fn readFileAlloc(allocator: Allocator, io: Io, path: []const u8, max_bytes: usize) ![]u8 {
    return Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_bytes));
}

fn stderrPrint(io: Io, comptime fmt: []const u8, args: anytype) !void {
    var buffer: [4096]u8 = undefined;
    var writer = Io.File.stderr().writer(io, &buffer);
    try writer.interface.print(fmt, args);
    try writer.interface.flush();
}

test "public claims checker exposes docs check entrypoint" {
    try std.testing.expect(@hasDecl(@This(), "checkPublicClaimDocs"));
}
