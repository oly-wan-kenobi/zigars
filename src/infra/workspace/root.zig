//! Re-exports the workspace subsystem: sandbox path resolution, filesystem
//! store, and directory scanner. Import this module to access all workspace
//! primitives from a single entry point.
pub const filesystem = @import("filesystem.zig");
pub const scanner = @import("scanner.zig");
pub const workspace = @import("workspace.zig");

const filesystem_tests = @import("filesystem_tests.zig");
const scanner_tests = @import("scanner_tests.zig");
const workspace_tests = @import("workspace_tests.zig");

test {
    _ = filesystem;
    _ = scanner;
    _ = workspace;
    _ = filesystem_tests;
    _ = scanner_tests;
    _ = workspace_tests;
}
