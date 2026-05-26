pub const metrics = @import("metrics.zig");

const logging_tests = @import("logging_tests.zig");
const metrics_tests = @import("metrics_tests.zig");

test {
    _ = metrics;
    _ = logging_tests;
    _ = metrics_tests;
}
