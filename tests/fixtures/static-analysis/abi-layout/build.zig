const std = @import("std");

pub fn build(_: *std.Build) void {
    @compileError("sentinel: zig build --help executed this fixture build.zig");
}
