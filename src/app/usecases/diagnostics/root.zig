//! Aggregates the diagnostics use-case modules (crash-evidence fusion and the
//! debugger/memory/fuzz/cross-target workflows) and pulls their tests into the
//! build so the subsystem is exercised as a unit.
pub const crash_evidence = @import("crash_evidence.zig");
pub const workflows = @import("workflows.zig");

test {
    _ = crash_evidence;
    _ = workflows;
    _ = @import("crash_evidence_tests.zig");
}
