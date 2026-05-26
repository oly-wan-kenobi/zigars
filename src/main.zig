const std = @import("std");
const zigar = @import("zigar");
const bootstrap_runtime = zigar.bootstrap.runtime;
const version = zigar.manifest.version.string;

pub fn main(init: std.process.Init) !void {
    try bootstrap_runtime.run(init);
}

test "executable embeds package version" {
    try std.testing.expect(version.len > 0);
    try std.testing.expect(std.mem.indexOfScalar(u8, version, '.') != null);
}
