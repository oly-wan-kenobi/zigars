pub const source_summary = @import("source_summary.zig");
pub const lint_intelligence = @import("lint_intelligence.zig");
pub const semantic_index = @import("semantic_index.zig");
pub const workspace_scans = @import("workspace_scans.zig");
pub const project_values = @import("project_values.zig");
pub const agent_ergonomics = @import("agent_ergonomics.zig");
pub const developer_pain = @import("developer_pain.zig");
pub const layout_probes = @import("layout_probes.zig");

test {
    _ = source_summary;
    _ = lint_intelligence;
    _ = semantic_index;
    _ = workspace_scans;
    _ = project_values;
    _ = agent_ergonomics;
    _ = developer_pain;
    _ = layout_probes;
    _ = @import("lint_intelligence_tests.zig");
    _ = @import("source_summary_tests.zig");
    _ = @import("semantic_index_tests.zig");
    _ = @import("workspace_scans_tests.zig");
    _ = @import("project_values_tests.zig");
}
