//! Aggregates the performance use cases (coverage evidence, benchmark evidence, and
//! the CLI-facing workflow handlers) and pulls in their unit tests.
pub const coverage = @import("coverage.zig");
pub const benchmark = @import("benchmark.zig");
pub const workflows = @import("workflows.zig");

test {
    _ = coverage;
    _ = benchmark;
    _ = workflows;
    _ = @import("coverage_tests.zig");
    _ = @import("benchmark_tests.zig");
}
