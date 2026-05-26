pub const crash_evidence = @import("crash_evidence.zig");
pub const workflows = @import("workflows.zig");

test {
    _ = crash_evidence;
    _ = workflows;
    _ = @import("crash_evidence_tests.zig");
}
