//! Domain-level facades and shared value helpers used by higher layers.
pub const profiling = @import("profiling/root.zig");
pub const editing = @import("editing/root.zig");
pub const zig = @import("zig/root.zig");
pub const diagnostics = @import("diagnostics/root.zig");
pub const performance = @import("performance/root.zig");
pub const release = @import("release/root.zig");
pub const trust = @import("trust.zig");

test {
    _ = profiling;
    _ = editing;
    _ = zig;
    _ = diagnostics;
    _ = performance;
    _ = release;
    _ = trust;
    _ = @import("evidence_tests.zig");
    _ = @import("trust_tests.zig");
}
