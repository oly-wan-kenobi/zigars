const std = @import("std");
const zigar = @import("zigar");
const bootstrap_runtime = zigar.bootstrap.runtime;
const version = zigar.manifest.version.string;

pub fn main(init: std.process.Init) !void {
    try bootstrap_runtime.run(init);
}

test {
    _ = @import("bootstrap/main_tests.zig");
}
