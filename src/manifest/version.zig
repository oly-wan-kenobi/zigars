const build_options = @import("zigar_build_options");

pub const string = build_options.version;

test "version is injected by the build" {
    try @import("std").testing.expect(string.len > 0);
}
