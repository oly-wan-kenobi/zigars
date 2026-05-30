//! Re-exports the process subsystem: subprocess execution (command),
//! CommandRunner port adapter (command_runner), and synchronization helpers
//! (sync). Import this module to access all process primitives at once.
pub const command_runner = @import("command_runner.zig");
pub const command = @import("command.zig");
pub const sync = @import("sync.zig");

const command_runner_tests = @import("command_runner_tests.zig");
const command_tests = @import("command_tests.zig");
const sync_tests = @import("sync_tests.zig");

test {
    _ = command_runner;
    _ = command;
    _ = sync;
    _ = command_runner_tests;
    _ = command_tests;
    _ = sync_tests;
}
