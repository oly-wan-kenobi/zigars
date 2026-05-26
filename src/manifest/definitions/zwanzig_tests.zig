const std = @import("std");
const subject = @import("zwanzig.zig");
const zig_lint = subject.zig_lint;
const zig_lint_sarif = subject.zig_lint_sarif;
const zig_lint_rules = subject.zig_lint_rules;
const zig_analysis_graphs = subject.zig_analysis_graphs;

test "zwanzig definitions expose lint metadata" {
    try @import("std").testing.expect(zig_lint.description.len > 0);
}
