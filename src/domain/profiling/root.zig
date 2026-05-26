//! Profiling-domain contracts for flamegraph rendering helpers.
pub const flamegraph = @import("flamegraph.zig");

test {
    _ = flamegraph;
    _ = @import("flamegraph_tests.zig");
}
