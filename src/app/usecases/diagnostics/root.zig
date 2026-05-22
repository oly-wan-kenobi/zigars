pub const crash_evidence = @import("crash_evidence.zig");

test {
    _ = crash_evidence;
    _ = @import("crash_evidence_tests.zig");
}
