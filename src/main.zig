//! Process entrypoint delegates all composition and runtime ownership to bootstrap runtime.
const std = @import("std");
const zigars = @import("zigars");
const bootstrap_runtime = zigars.bootstrap.runtime;
const version = zigars.manifest.version.string;

/// Program entry point that delegates to the configured bootstrap runner.
pub fn main(init: std.process.Init) !void {
    try bootstrap_runtime.run(init);
}

test {
    _ = @import("bootstrap/main_tests.zig");
}
