const std = @import("std");
const subject = @import("profiling.zig");
const zig_profile_plan = subject.zig_profile_plan;
const zig_profile_run = subject.zig_profile_run;
const zig_flamegraph = subject.zig_flamegraph;
const zig_flamegraph_diff = subject.zig_flamegraph_diff;

test "profiling definitions expose profile metadata" {
    try @import("std").testing.expect(zig_profile_plan.description.len > 0);
}
