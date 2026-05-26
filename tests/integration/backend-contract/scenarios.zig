const std = @import("std");

pub const Scenario = struct {
    name: []const u8,
    backends: []const []const u8,
    tool: []const u8,
    evidence: []const []const u8,
};

pub const all = [_]Scenario{
    .{ .name = "zls_document_symbols", .backends = &.{"zls"}, .tool = "zig_document_symbols", .evidence = &.{ "textDocument/documentSymbol", "PublicThing or main" } },
    .{ .name = "zlint_diagnostics_json", .backends = &.{"zlint"}, .tool = "zig_zlint", .evidence = &.{ "--format", "json", "zlint" } },
    .{ .name = "zlint_sarif", .backends = &.{"zlint"}, .tool = "zig_zlint_sarif", .evidence = &.{ "SARIF", "zlint" } },
    .{ .name = "zlint_rules", .backends = &.{"zlint"}, .tool = "zig_zlint_rules", .evidence = &.{ "rule metadata or capability fallback", "zlint" } },
    .{ .name = "zlint_fix_preview", .backends = &.{"zlint"}, .tool = "zig_zlint_fix", .evidence = &.{ "--fix", "apply gate", "zlint" } },
    .{ .name = "zwanzig_lint_json", .backends = &.{"zwanzig"}, .tool = "zig_lint", .evidence = &.{ "--format", "json", "zwanzig" } },
    .{ .name = "zwanzig_lint_sarif", .backends = &.{"zwanzig"}, .tool = "zig_lint_sarif", .evidence = &.{ "--format", "sarif", "zwanzig" } },
    .{ .name = "zwanzig_lint_rules", .backends = &.{"zwanzig"}, .tool = "zig_lint_rules", .evidence = &.{ "zwanzig", "help/rules" } },
    .{ .name = "zwanzig_analysis_graphs_cfg", .backends = &.{"zwanzig"}, .tool = "zig_analysis_graphs", .evidence = &.{ "zig_analysis_graphs", "DOT" } },
    .{ .name = "zflame_recursive_folded_svg", .backends = &.{"zflame"}, .tool = "zig_flamegraph", .evidence = &.{ "zflame", "recursive", "structural SVG" } },
    .{ .name = "diff_folded_recursive_svg_intermediate", .backends = &.{ "diff_folded", "zflame" }, .tool = "zig_flamegraph_diff", .evidence = &.{ "diff-folded", "intermediate metadata", "structural SVG" } },
};

pub fn find(name: []const u8) ?Scenario {
    for (all) |scenario| {
        if (std.mem.eql(u8, scenario.name, name)) return scenario;
    }
    return null;
}

test "backend contract scenario manifest is unique and complete enough for drift checks" {
    try std.testing.expectEqual(@as(usize, 11), all.len);
    for (all, 0..) |scenario, index| {
        try std.testing.expect(scenario.name.len > 0);
        try std.testing.expect(scenario.backends.len > 0);
        try std.testing.expect(scenario.tool.len > 0);
        try std.testing.expect(scenario.evidence.len > 0);
        try std.testing.expect(find(scenario.name) != null);
        for (all[index + 1 ..]) |other| {
            try std.testing.expect(!std.mem.eql(u8, scenario.name, other.name));
        }
    }
    try std.testing.expect(find("missing_backend_contract_scenario") == null);
}
