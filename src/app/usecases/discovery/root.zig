pub const workflows = @import("workflows.zig");

test {
    _ = workflows;
    _ = @import("workflows_tests.zig");
}
