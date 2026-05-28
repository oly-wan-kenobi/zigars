//! Process entrypoint delegates all composition and runtime ownership to bootstrap runtime.
const std = @import("std");
const zigars = @import("zigars");
const bootstrap_runtime = zigars.bootstrap.runtime;
const version = zigars.manifest.version.string;

/// Program entry point that delegates to the configured bootstrap runner.
pub fn main(init: std.process.Init) !void {
    const exit_code = try bootstrap_runtime.run(init);
    if (exit_code != .success) std.process.exit(@intFromEnum(exit_code));
}

test {
    _ = @import("bootstrap/main_tests.zig");
}
