pub const coverage_model = @import("coverage_model.zig");
pub const benchmark_model = @import("benchmark_model.zig");

test {
    _ = coverage_model;
    _ = benchmark_model;
    _ = @import("coverage_model_tests.zig");
    _ = @import("benchmark_model_tests.zig");
}
