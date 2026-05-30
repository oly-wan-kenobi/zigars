//! Core usecases aggregator: exposes the Zig command workflows and pulls the
//! command-output and command workflow test suites into the build.
pub const zig_commands = @import("zig_commands.zig");
const command_output_tests = @import("command_output_tests.zig");
const zig_commands_tests = @import("zig_commands_tests.zig");

test {
    _ = command_output_tests;
    _ = zig_commands;
    _ = zig_commands_tests;
}
