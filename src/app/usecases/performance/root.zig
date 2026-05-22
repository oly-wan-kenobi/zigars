pub const coverage = @import("coverage.zig");
pub const benchmark = @import("benchmark.zig");

test {
    _ = coverage;
    _ = benchmark;
    _ = @import("coverage_tests.zig");
    _ = @import("benchmark_tests.zig");
}
