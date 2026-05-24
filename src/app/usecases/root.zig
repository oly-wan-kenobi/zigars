pub const core = @import("core/root.zig");
pub const artifacts = @import("artifacts/root.zig");
pub const profiling = @import("profiling/root.zig");
pub const validation = @import("validation/root.zig");
pub const editing = @import("editing/root.zig");
pub const static_analysis = @import("static_analysis/root.zig");
pub const zls = @import("zls/root.zig");
pub const diagnostics = @import("diagnostics/root.zig");
pub const discovery = @import("discovery/root.zig");
pub const environment = @import("environment/root.zig");
pub const performance = @import("performance/root.zig");
pub const release = @import("release/root.zig");
pub const runtime_ux = @import("runtime_ux/root.zig");
pub const observability = @import("observability/root.zig");
pub const usecase_support = @import("usecase_support.zig");

test {
    _ = core;
    _ = artifacts;
    _ = profiling;
    _ = validation;
    _ = editing;
    _ = static_analysis;
    _ = zls;
    _ = diagnostics;
    _ = discovery;
    _ = environment;
    _ = performance;
    _ = release;
    _ = runtime_ux;
    _ = observability;
    _ = usecase_support;
}
