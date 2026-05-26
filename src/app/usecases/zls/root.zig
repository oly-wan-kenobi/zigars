pub const code_intel = @import("code_intel.zig");
pub const workflows = @import("workflows.zig");

test {
    _ = code_intel;
    _ = workflows;
    _ = @import("code_intel_tests.zig");
}
