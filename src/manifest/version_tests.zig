const std = @import("std");
const subject = @import("version.zig");
const string = subject.string;

test "version is injected by the build" {
    try @import("std").testing.expect(string.len > 0);
}
