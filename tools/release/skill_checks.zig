//! Release gate: skill tool-reference contract.
//! Shipped `@zigars/skills` guidance names zigars tools by id. This module
//! confirms every backtick-quoted `zig_*`/`zigars_*` tool id in a SKILL.md
//! resolves to a registered manifest tool, so a renamed or removed tool can
//! never leave skill guidance pointing agents at a tool that no longer exists.
//! The orchestrator in release_checks.zig runs it as part of artifact-hygiene.
const std = @import("std");
const zigars = @import("zigars");

const Io = std.Io;
const Allocator = std.mem.Allocator;

/// Walks every shipped SKILL.md and fails when a backtick-quoted tool-id-shaped
/// token does not resolve to a registered manifest tool. Tokens with spaces,
/// dots, or other shapes (commands, file names, prose) are ignored, keeping the
/// check focused on genuine tool-id references.
pub fn checkSkillToolReferences(allocator: Allocator, io: Io) !bool {
    const skills_root = "packages/@zigars/skills/skills";
    var dir = Io.Dir.cwd().openDir(io, skills_root, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return true,
        else => {
            try stderrPrint(io, "skill drift check could not open {s}: {s}\n", .{ skills_root, @errorName(err) });
            return false;
        },
    };
    defer dir.close(io);
    var walker = try dir.walk(allocator);
    defer walker.deinit();

    var ok = true;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, "SKILL.md")) continue;
        const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ skills_root, entry.path });
        defer allocator.free(path);
        // The walker yields native separators; normalize for stable diagnostics.
        std.mem.replaceScalar(u8, path, '\\', '/');
        const bytes = readFileAlloc(allocator, io, path, 1024 * 1024) catch |err| {
            try stderrPrint(io, "skill drift check could not read {s}: {s}\n", .{ path, @errorName(err) });
            ok = false;
            continue;
        };
        defer allocator.free(bytes);
        ok = (try checkSkillBytes(io, path, bytes)) and ok;
    }
    return ok;
}

/// Scans one SKILL.md body for backtick-quoted tool-id tokens and reports any
/// that are not registered in the manifest.
fn checkSkillBytes(io: Io, path: []const u8, bytes: []const u8) !bool {
    var ok = true;
    var index: usize = 0;
    while (std.mem.indexOfScalarPos(u8, bytes, index, '`')) |open| {
        const close = std.mem.indexOfScalarPos(u8, bytes, open + 1, '`') orelse break;
        const token = bytes[open + 1 .. close];
        index = close + 1;
        if (tokenIsToolShape(token) and zigars.manifest.find(token) == null) {
            try stderrPrint(io, "skill {s} references unknown tool id `{s}`\n", .{ path, token });
            ok = false;
        }
    }
    return ok;
}

/// True when `token` has the `zig_`/`zigars_` tool-id grammar (lower-case ASCII,
/// digits, and underscores only), so it is meant to name a tool rather than a
/// command, file path, or prose fragment.
fn tokenIsToolShape(token: []const u8) bool {
    if (!std.mem.startsWith(u8, token, "zig_") and !std.mem.startsWith(u8, token, "zigars_")) return false;
    for (token) |c| {
        if (!std.ascii.isLower(c) and !std.ascii.isDigit(c) and c != '_') return false;
    }
    return true;
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

test "tokenIsToolShape accepts tool ids and rejects prose" {
    try std.testing.expect(tokenIsToolShape("zig_build"));
    try std.testing.expect(tokenIsToolShape("zigars_context_pack"));
    try std.testing.expect(!tokenIsToolShape("zls_definition"));
    try std.testing.expect(!tokenIsToolShape("zig build test"));
    try std.testing.expect(!tokenIsToolShape("build.zig.zon"));
    try std.testing.expect(!tokenIsToolShape("output_format=json"));
}
