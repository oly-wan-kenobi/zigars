pub const ci_evidence = @import("ci_evidence.zig");
pub const docs_index = @import("docs_index.zig");
pub const drift = @import("drift.zig");
pub const release_intelligence = @import("release_intelligence.zig");
pub const workflows = @import("workflows.zig");

test {
    _ = ci_evidence;
    _ = docs_index;
    _ = drift;
    _ = release_intelligence;
    _ = workflows;
    _ = @import("ci_evidence_tests.zig");
    _ = @import("docs_index_tests.zig");
    _ = @import("release_intelligence_tests.zig");
}
