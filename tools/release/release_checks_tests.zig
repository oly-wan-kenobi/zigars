//! Pure-Zig-tree gate tests, split out of release_checks.zig to keep that
//! orchestrator module within its line budget. release_checks.zig references
//! this file via a `test` import so these run under `zig build test`.
const std = @import("std");
const release_checks = @import("release_checks.zig");

const Io = std.Io;

test "pure-Zig tree gate rejects a planted .py and passes when absent" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    // Distinct scratch root under cwd so it cannot collide with a real tree.
    const root = ".zigars-purezig-gate-test";
    const nested = root ++ "/nested/pkg";
    // Start clean even if a prior aborted run left the scratch behind.
    Io.Dir.cwd().deleteTree(io, root) catch {};
    defer Io.Dir.cwd().deleteTree(io, root) catch {};

    try Io.Dir.cwd().createDirPath(io, nested);
    // A non-Python file must never trip the gate.
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = root ++ "/keep.zig", .data = "const x = 1;\n" });

    // Absent .py: gate passes.
    try std.testing.expect(try release_checks.checkNoExtensionInTree(allocator, io, root, ".py"));

    // Plant a .py one directory deep: gate must fail (negative path).
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = nested ++ "/intruder.py", .data = "print('nope')\n" });
    try std.testing.expect(!(try release_checks.checkNoExtensionInTree(allocator, io, root, ".py")));

    // Remove the .py again: gate passes once more.
    try Io.Dir.cwd().deleteFile(io, nested ++ "/intruder.py");
    try std.testing.expect(try release_checks.checkNoExtensionInTree(allocator, io, root, ".py"));
}

test "pure-Zig tree gate silently passes a missing root" {
    // A scoped root that does not exist is a documented no-op (FileNotFound => true).
    try std.testing.expect(try release_checks.checkNoExtensionInTree(std.testing.allocator, std.testing.io, ".zigars-nonexistent-root-xyz", ".py"));
}
