pub const workflows = @import("workflows.zig");
pub const project_intelligence = @import("project_intelligence.zig");

test {
    _ = workflows;
    _ = project_intelligence;
    _ = @import("workflows_tests.zig");
    _ = @import("project_intelligence_tests.zig");
}
