pub const flamegraph = @import("flamegraph.zig");

test {
    _ = flamegraph;
    _ = @import("flamegraph_tests.zig");
}
