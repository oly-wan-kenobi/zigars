pub const flamegraph = @import("flamegraph.zig");
pub const flamegraph_diff = @import("flamegraph_diff.zig");
pub const plan = @import("plan.zig");
pub const render = @import("render.zig");
pub const run = @import("run.zig");

test {
    _ = flamegraph;
    _ = flamegraph_diff;
    _ = plan;
    _ = render;
    _ = run;
    _ = @import("flamegraph_diff_tests.zig");
    _ = @import("flamegraph_tests.zig");
    _ = @import("plan_tests.zig");
    _ = @import("render_tests.zig");
}
