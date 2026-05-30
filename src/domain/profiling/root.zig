//! Profiling-domain contracts for flamegraph rendering helpers.
//! Re-exports flamegraph; no logic lives here.
pub const flamegraph = @import("flamegraph.zig");

test {
    _ = flamegraph;
    _ = @import("flamegraph_tests.zig");
}
