pub const workflows = @import("workflows.zig");

test "runtime ux root imports workflows" {
    _ = workflows;
    _ = @import("workflows_tests.zig");
}
