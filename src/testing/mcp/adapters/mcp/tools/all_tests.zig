//! Aggregates all MCP tool projection fixture suites into a single test
//! binary: discovery, project intelligence, release, result shape, and
//! runtime metrics adapters.

test {
    _ = @import("discovery_tests.zig");
    _ = @import("project_intelligence_tests.zig");
    _ = @import("release_tests.zig");
    _ = @import("result_shape_tests.zig");
    _ = @import("runtime_metrics_tests.zig");
}
