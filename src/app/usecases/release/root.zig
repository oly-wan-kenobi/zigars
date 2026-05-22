pub const release_intelligence = @import("release_intelligence.zig");

test {
    _ = release_intelligence;
    _ = @import("release_intelligence_tests.zig");
}
