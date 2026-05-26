const std = @import("std");

const backend_contracts = @import("backend_contracts.zig");

test "zwanzig graph modes map to supported upstream flags" {
    try std.testing.expectEqualStrings("--dump-cfg", backend_contracts.ZwanzigGraphMode.cfg.flag());
    try std.testing.expectEqualStrings("--dump-exploded-graph", backend_contracts.ZwanzigGraphMode.exploded_graph.flag());
    try std.testing.expectEqualStrings("--dump-annotated-cfg", backend_contracts.ZwanzigGraphMode.annotated_cfg.flag());
    try std.testing.expectEqualStrings("--dump-path-trace", backend_contracts.ZwanzigGraphMode.path_trace.flag());
    try std.testing.expect(backend_contracts.parseZwanzigGraphMode("--dot") == null);
}

test "zflame contract requires explicit supported formats" {
    for (backend_contracts.zflame_format_names) |name| try std.testing.expect(backend_contracts.parseZflameFormat(name) != null);
    try std.testing.expect(backend_contracts.parseZflameFormat("guess") == null);
}

test "optional backend identities expose stable path flags and probes" {
    try std.testing.expectEqualStrings("zwanzig", backend_contracts.BackendId.zwanzig.name());
    try std.testing.expectEqualStrings("--diff-folded-path", backend_contracts.BackendId.diff_folded.pathFlag());
    try std.testing.expectEqualStrings("--help", backend_contracts.probeArgv(.zflame)[1]);
}

test "capability contracts cover optional backend handlers" {
    const expected = [_][]const u8{ "zig_lint", "zig_lint_sarif", "zig_lint_rules", "zig_analysis_graphs", "zig_flamegraph", "zig_flamegraph_diff" };
    for (expected) |tool_name| {
        const contract = backend_contracts.capabilityFor(tool_name) orelse return error.MissingContract;
        try std.testing.expect(contract.argv_shape.len > 0);
    }
    try std.testing.expect(backend_contracts.capabilityFor("missing_backend_tool") == null);
}
