pub const core = @import("core/root.zig");
pub const profiling = @import("profiling/root.zig");
pub const validation = @import("validation/root.zig");
pub const editing = @import("editing/root.zig");
pub const static_analysis = @import("static_analysis/root.zig");
pub const zls = @import("zls/root.zig");
pub const diagnostics = @import("diagnostics/root.zig");
pub const performance = @import("performance/root.zig");
pub const release = @import("release/root.zig");

test {
    _ = core;
    _ = profiling;
    _ = validation;
    _ = editing;
    _ = static_analysis;
    _ = zls;
    _ = diagnostics;
    _ = performance;
    _ = release;
}
