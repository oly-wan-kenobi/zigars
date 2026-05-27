const std = @import("std");

const lint_intelligence = @import("lint_intelligence.zig");
const fakes = @import("../../../testing/fakes/root.zig");

test "normalizes findings and compares consensus" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const text = "{\"findings\":[{\"rule\":\"lint.rule\",\"severity\":\"warning\",\"path\":\"src/main.zig\",\"line\":2,\"column\":3,\"message\":\"warn\"}]}";
    const zlint = try lint_intelligence.normalizeFindingsText(allocator, text, .zlint);
    const zwanzig = try lint_intelligence.normalizeFindingsText(allocator, text, .zwanzig);
    try std.testing.expectEqual(@as(usize, 1), zlint.array.items.len);
    const compared = try lint_intelligence.lintCompareValue(allocator, zlint.array, zwanzig.array);
    try std.testing.expectEqual(@as(i64, 1), compared.object.get("summary").?.object.get("consensus_count").?.integer);
}

test "lint gate blocks errors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const findings = try lint_intelligence.normalizeFindingsText(arena.allocator(), "[{\"rule\":\"r\",\"severity\":\"error\",\"path\":\"a.zig\",\"line\":1,\"message\":\"bad\"}]", .zlint);
    const gate = try lint_intelligence.lintGateValue(arena.allocator(), findings.array, "standard", false, 0);
    try std.testing.expect(!gate.object.get("passed").?.bool);
}

test "strict lint profile blocks warnings by default" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const findings = try lint_intelligence.normalizeFindingsText(arena.allocator(), "[{\"rule\":\"r\",\"severity\":\"warning\",\"path\":\"a.zig\",\"line\":1,\"message\":\"warn\"}]", .zlint);
    const defaults = lint_intelligence.lintProfileDefaults("strict");
    const gate = try lint_intelligence.lintGateValue(arena.allocator(), findings.array, "strict", defaults.allow_warnings, defaults.max_warnings);
    try std.testing.expect(!gate.object.get("passed").?.bool);
}

test "zlint rules fallback reflects help capabilities" {
    try std.testing.expect(!lint_intelligence.zlintHelpSupportsRules("Usage: zlint [options]\n--fix\n--print-ast <file>\n"));
    try std.testing.expect(lint_intelligence.zlintHelpSupportsRules("fake\n--rules --format json\n"));
}

test "zwanzig argv builders use supported typed flags" {
    const lint_argv = try lint_intelligence.buildZwanzigLintArgv(std.testing.allocator, .{
        .executable = "zwanzig",
        .format = .sarif,
        .path = "/workspace/src",
        .config = "/workspace/zwanzig.json",
        .rules_do = "empty-catch-engine",
        .rules_skip = "style",
        .extra = &.{"--verbose"},
    });
    defer std.testing.allocator.free(lint_argv);
    const expected = [_][]const u8{ "zwanzig", "--format", "sarif", "--config", "/workspace/zwanzig.json", "--do", "empty-catch-engine", "--skip", "style", "/workspace/src", "--verbose" };
    try std.testing.expectEqual(expected.len, lint_argv.len);
    for (expected, lint_argv) |expected_arg, actual_arg| try std.testing.expectEqualStrings(expected_arg, actual_arg);

    const graph_argv = try lint_intelligence.buildZwanzigGraphArgv(std.testing.allocator, .{
        .executable = "zwanzig",
        .mode = .cfg,
        .source_path = "/workspace/src/main.zig",
        .output_dir = "/workspace/.zigars-cache/graphs",
    });
    defer std.testing.allocator.free(graph_argv);
    try std.testing.expectEqualStrings("--dump-cfg", graph_argv[1]);
}

test "zlint diagnostics classifies command port timeout without MCP result assertions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var command_fake = fakes.FakeCommandRunner.init(std.testing.allocator);
    defer command_fake.deinit();
    var store_fake = fakes.FakeWorkspaceStore.init(std.testing.allocator);
    defer store_fake.deinit();
    var scanner_fake = fakes.FakeWorkspaceScanner.init(std.testing.allocator);
    defer scanner_fake.deinit();

    try store_fake.expectResolve(.{ .path = "src", .provenance = "static_analysis.zlint_path" }, "/workspace/src");
    try command_fake.expectRunError(.{
        .argv = &.{ "zlint-bin", "--format", "json", "/workspace/src" },
        .cwd = "/workspace",
        .timeout_ms = 10,
        .provenance = "static_analysis.zlint",
    }, error.Timeout);

    const value = try lint_intelligence.runZlintDiagnostics(arena.allocator(), .{
        .workspace = .{ .root = "/workspace" },
        .tool_paths = .{ .zlint = "zlint-bin" },
        .command_runner = command_fake.port(),
        .workspace_store = store_fake.port(),
        .workspace_scanner = scanner_fake.port(),
    }, .{
        .tool_name = "zig_zlint",
        .path = "src",
        .timeout_ms = 10,
    });

    try std.testing.expectEqualStrings("backend_error", value.object.get("kind").?.string);
    try std.testing.expectEqualStrings("zlint", value.object.get("backend").?.string);
    try std.testing.expectEqualStrings("timeout", value.object.get("error_kind").?.string);
    try store_fake.verify();
    try command_fake.verify();
}

test "zlint diagnostics success can render SARIF from normalized findings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var command_fake = fakes.FakeCommandRunner.init(std.testing.allocator);
    defer command_fake.deinit();
    var store_fake = fakes.FakeWorkspaceStore.init(std.testing.allocator);
    defer store_fake.deinit();
    var scanner_fake = fakes.FakeWorkspaceScanner.init(std.testing.allocator);
    defer scanner_fake.deinit();

    try store_fake.expectResolve(.{ .path = "src/main.zig", .provenance = "static_analysis.zlint_path" }, "/workspace/src/main.zig");
    try command_fake.expectRun(.{
        .argv = &.{ "zlint-bin", "--format", "json", "/workspace/src/main.zig" },
        .cwd = "/workspace",
        .timeout_ms = 999,
        .provenance = "static_analysis.zlint",
    }, .{
        .stdout =
        \\{"diagnostics":[{"rule_id":"no-empty-catch","level":"error","location":{"path":"src/main.zig","line":5,"column":9},"detail":"empty catch"}]}
        ,
        .duration_ms = 12,
    });

    const value = try lint_intelligence.runZlintDiagnostics(arena.allocator(), .{
        .workspace = .{ .root = "/workspace" },
        .tool_paths = .{ .zlint = "zlint-bin" },
        .command_runner = command_fake.port(),
        .workspace_store = store_fake.port(),
        .workspace_scanner = scanner_fake.port(),
    }, .{
        .tool_name = "zig_zlint_sarif",
        .path = "src/main.zig",
        .timeout_ms = 999,
        .sarif = true,
    });

    try std.testing.expectEqualStrings("zig_zlint_sarif", value.object.get("kind").?.string);
    const run = value.object.get("sarif").?.object.get("runs").?.array.items[0].object;
    const result = run.get("results").?.array.items[0].object;
    try std.testing.expectEqualStrings("no-empty-catch", result.get("ruleId").?.string);
    try std.testing.expectEqualStrings("error", result.get("level").?.string);
    try store_fake.verify();
    try command_fake.verify();
}

test "zwanzig lint use case resolves inputs and executes through command port" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var command_fake = fakes.FakeCommandRunner.init(std.testing.allocator);
    defer command_fake.deinit();
    var store_fake = fakes.FakeWorkspaceStore.init(std.testing.allocator);
    defer store_fake.deinit();
    var scanner_fake = fakes.FakeWorkspaceScanner.init(std.testing.allocator);
    defer scanner_fake.deinit();

    try store_fake.expectResolve(.{ .path = "zwanzig.toml", .provenance = "static_analysis.zwanzig_config" }, "/workspace/zwanzig.toml");
    try store_fake.expectResolve(.{ .path = "src", .provenance = "static_analysis.zwanzig_path" }, "/workspace/src");
    try command_fake.expectRun(.{
        .argv = &.{ "zwanzig-bin", "--format", "json", "--config", "/workspace/zwanzig.toml", "--do", "rule-a", "--skip", "style", "/workspace/src", "--json-lines" },
        .cwd = "/workspace",
        .timeout_ms = 777,
        .provenance = "static_analysis.zwanzig",
    }, .{
        .stdout = "{\"findings\":[]}\n",
        .duration_ms = 4,
    });

    const value = try lint_intelligence.runZwanzigLint(arena.allocator(), .{
        .workspace = .{ .root = "/workspace" },
        .tool_paths = .{ .zwanzig = "zwanzig-bin" },
        .timeouts = .{ .command_ms = 30_000 },
        .command_runner = command_fake.port(),
        .workspace_store = store_fake.port(),
        .workspace_scanner = scanner_fake.port(),
    }, .{
        .tool_name = "zig_lint",
        .format = .json,
        .path = "src",
        .config = "zwanzig.toml",
        .rules_do = "rule-a",
        .rules_skip = "style",
        .extra = &.{"--json-lines"},
        .timeout_ms = 777,
    });

    try std.testing.expectEqualStrings("zwanzig", value.object.get("backend").?.string);
    try std.testing.expectEqualStrings("zig_lint", value.object.get("tool").?.string);
    try std.testing.expect(value.object.get("ok").?.bool);
    const argv = value.object.get("argv").?.array.items;
    try std.testing.expectEqualStrings("--do", argv[5].string);
    try std.testing.expectEqualStrings("rule-a", argv[6].string);
    try store_fake.verify();
    try command_fake.verify();
}

test "zlint rules use command capability probe before fetching catalog" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var command_fake = fakes.FakeCommandRunner.init(std.testing.allocator);
    defer command_fake.deinit();
    var store_fake = fakes.FakeWorkspaceStore.init(std.testing.allocator);
    defer store_fake.deinit();
    var scanner_fake = fakes.FakeWorkspaceScanner.init(std.testing.allocator);
    defer scanner_fake.deinit();

    try command_fake.expectRun(.{
        .argv = &.{ "zlint-bin", "--help" },
        .cwd = "/workspace",
        .timeout_ms = 222,
        .provenance = "static_analysis.zlint_rules_help",
    }, .{
        .stdout = "usage: zlint --format json --rules --fix --print-ast\n",
    });
    try command_fake.expectRun(.{
        .argv = &.{ "zlint-bin", "--rules", "--format", "json" },
        .cwd = "/workspace",
        .timeout_ms = 222,
        .provenance = "static_analysis.zlint_rules",
    }, .{
        .stdout =
        \\{"rules":[{"id":"no-empty-catch","severity":"warning","category":"style","description":"avoid empty catch"}]}
        ,
    });

    const value = try lint_intelligence.runZlintRules(arena.allocator(), .{
        .workspace = .{ .root = "/workspace" },
        .tool_paths = .{ .zlint = "zlint-bin" },
        .command_runner = command_fake.port(),
        .workspace_store = store_fake.port(),
        .workspace_scanner = scanner_fake.port(),
    }, .{ .timeout_ms = 222 });

    try std.testing.expectEqualStrings("zig_zlint_rules", value.object.get("kind").?.string);
    try std.testing.expectEqual(@as(i64, 1), value.object.get("rule_count").?.integer);
    const rule = value.object.get("rules").?.array.items[0].object;
    try std.testing.expectEqualStrings("no-empty-catch", rule.get("id").?.string);
    try std.testing.expectEqualStrings("zlint", rule.get("source").?.string);
    try command_fake.verify();
    try store_fake.verify();
}

test "zlint rules report unavailable capability from help text" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var command_fake = fakes.FakeCommandRunner.init(std.testing.allocator);
    defer command_fake.deinit();
    var store_fake = fakes.FakeWorkspaceStore.init(std.testing.allocator);
    defer store_fake.deinit();
    var scanner_fake = fakes.FakeWorkspaceScanner.init(std.testing.allocator);
    defer scanner_fake.deinit();

    try command_fake.expectRun(.{
        .argv = &.{ "zlint-bin", "--help" },
        .cwd = "/workspace",
        .timeout_ms = 50,
        .provenance = "static_analysis.zlint_rules_help",
    }, .{
        .stdout = "usage: zlint --format json --fix --print-ast\n",
    });

    const value = try lint_intelligence.runZlintRules(arena.allocator(), .{
        .workspace = .{ .root = "/workspace" },
        .tool_paths = .{ .zlint = "zlint-bin" },
        .command_runner = command_fake.port(),
        .workspace_store = store_fake.port(),
        .workspace_scanner = scanner_fake.port(),
    }, .{ .timeout_ms = 50 });

    try std.testing.expect(value.object.get("ok").?.bool);
    try std.testing.expect(!value.object.get("rules_available").?.bool);
    try std.testing.expect(value.object.get("capabilities").?.object.get("format_json").?.bool);
    try std.testing.expect(!value.object.get("capabilities").?.object.get("rules").?.bool);
    try command_fake.verify();
    try store_fake.verify();
}

test "zlint fix preview resolves config and path without executing backend" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var store_fake = fakes.FakeWorkspaceStore.init(std.testing.allocator);
    defer store_fake.deinit();
    var scanner_fake = fakes.FakeWorkspaceScanner.init(std.testing.allocator);
    defer scanner_fake.deinit();

    try store_fake.expectResolve(.{ .path = "zlint.json", .provenance = "static_analysis.zlint_fix_config" }, "/workspace/zlint.json");
    try store_fake.expectResolve(.{ .path = "src", .provenance = "static_analysis.zlint_fix_path" }, "/workspace/src");

    const value = try lint_intelligence.runZlintFix(arena.allocator(), .{
        .workspace = .{ .root = "/workspace" },
        .tool_paths = .{ .zlint = "zlint-bin" },
        .workspace_store = store_fake.port(),
        .workspace_scanner = scanner_fake.port(),
    }, .{
        .path = "src",
        .config = "zlint.json",
        .rules = "no-empty-catch",
        .extra = &.{"--explain"},
        .dangerous = true,
        .apply = false,
    });

    try std.testing.expectEqualStrings("zig_zlint_fix", value.object.get("kind").?.string);
    try std.testing.expect(!value.object.get("apply").?.bool);
    try std.testing.expect(value.object.get("requires_apply").?.bool);
    try std.testing.expect(value.object.get("dangerous").?.bool);
    const argv = value.object.get("argv").?.array.items;
    try std.testing.expectEqualStrings("--fix-dangerously", argv[3].string);
    try std.testing.expectEqualStrings("--config", argv[4].string);
    try std.testing.expectEqualStrings("/workspace/zlint.json", argv[5].string);
    try std.testing.expectEqualStrings("/workspace/src", argv[8].string);
    try std.testing.expectEqualStrings("--explain", argv[9].string);
    try store_fake.verify();
}

test "zlint fix apply executes backend and returns post-fix findings summary" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var command_fake = fakes.FakeCommandRunner.init(std.testing.allocator);
    defer command_fake.deinit();
    var store_fake = fakes.FakeWorkspaceStore.init(std.testing.allocator);
    defer store_fake.deinit();
    var scanner_fake = fakes.FakeWorkspaceScanner.init(std.testing.allocator);
    defer scanner_fake.deinit();

    try store_fake.expectResolve(.{ .path = "src", .provenance = "static_analysis.zlint_fix_path" }, "/workspace/src");
    try command_fake.expectRun(.{
        .argv = &.{ "zlint-bin", "--format", "json", "--fix", "/workspace/src" },
        .cwd = "/workspace",
        .timeout_ms = 10_000,
        .provenance = "static_analysis.zlint_fix",
    }, .{
        .stdout = "{\"findings\":[]}\n",
        .stderr = "fixed 1 file\n",
    });

    const value = try lint_intelligence.runZlintFix(arena.allocator(), .{
        .workspace = .{ .root = "/workspace" },
        .tool_paths = .{ .zlint = "zlint-bin" },
        .command_runner = command_fake.port(),
        .workspace_store = store_fake.port(),
        .workspace_scanner = scanner_fake.port(),
    }, .{
        .path = "src",
        .apply = true,
        .timeout_ms = 10_000,
    });

    try std.testing.expect(value.object.get("applied").?.bool);
    try std.testing.expect(!value.object.get("dangerous").?.bool);
    try std.testing.expectEqual(@as(usize, 0), value.object.get("findings_after_fix").?.array.items.len);
    try std.testing.expectEqual(@as(i64, 0), value.object.get("summary").?.object.get("error_count").?.integer);
    try store_fake.verify();
    try command_fake.verify();
}

test "zwanzig rules command returns compiler insight metadata on failure" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var command_fake = fakes.FakeCommandRunner.init(std.testing.allocator);
    defer command_fake.deinit();
    var store_fake = fakes.FakeWorkspaceStore.init(std.testing.allocator);
    defer store_fake.deinit();
    var scanner_fake = fakes.FakeWorkspaceScanner.init(std.testing.allocator);
    defer scanner_fake.deinit();

    try command_fake.expectRun(.{
        .argv = &.{ "zwanzig-bin", "--help" },
        .cwd = "/workspace",
        .timeout_ms = 1,
        .provenance = "static_analysis.zwanzig",
    }, .{
        .exit_code = 2,
        .term = .{ .exited = 2 },
        .stderr = "src/main.zig:4:7: error: unable to load 'missing.zig'\nsrc/main.zig:4:7: note: imported here\n",
        .duration_ms = 3,
        .stderr_truncated = true,
    });

    const value = try lint_intelligence.runZwanzigRules(arena.allocator(), .{
        .workspace = .{ .root = "/workspace" },
        .tool_paths = .{ .zwanzig = "zwanzig-bin" },
        .timeouts = .{ .command_ms = 30_000 },
        .command_runner = command_fake.port(),
        .workspace_store = store_fake.port(),
        .workspace_scanner = scanner_fake.port(),
    }, 1);

    try std.testing.expect(!value.object.get("ok").?.bool);
    try std.testing.expect(value.object.get("output_limit_exceeded").?.bool);
    const diagnostics = value.object.get("diagnostics").?.object;
    try std.testing.expectEqual(@as(i64, 1), diagnostics.get("error_count").?.integer);
    try std.testing.expectEqualStrings("missing_file_or_import", diagnostics.get("category").?.string);
    try std.testing.expectEqualStrings("zwanzig", value.object.get("backend").?.string);
    try command_fake.verify();
    try store_fake.verify();
}

test "lint value helpers partition findings through typed comparison keys" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const zlint = try lint_intelligence.normalizeFindingsText(allocator,
        \\{"findings":[
        \\{"rule":"format-rule","severity":"warning","path":"src/a.zig","line":1,"column":1,"message":"format this"},
        \\{"rule":"panic-rule","severity":"error","path":"src/b.zig","line":2,"column":3,"message":"panic"},
        \\{"rule":"manual-rule","severity":"info","path":"src/c.zig","line":3,"column":5,"message":"review manually"}
        \\]}
    , .zlint);
    const zwanzig = try lint_intelligence.normalizeFindingsText(allocator,
        \\{"results":[
        \\{"rule":"format-rule","severity":"error","path":"src/a.zig","line":1,"column":1,"message":"format mismatch"},
        \\{"rule":"extra-rule","severity":"warning","path":"src/d.zig","line":4,"column":1,"message":"new warning"}
        \\]}
    , .zwanzig);

    const compared = try lint_intelligence.lintCompareValue(allocator, zlint.array, zwanzig.array);
    try std.testing.expectEqual(@as(i64, 1), compared.object.get("summary").?.object.get("disagreement_count").?.integer);
    try std.testing.expectEqual(@as(usize, 2), compared.object.get("zlint_only").?.array.items.len);
    try std.testing.expectEqual(@as(usize, 1), compared.object.get("zwanzig_only").?.array.items.len);

    const profile = try lint_intelligence.lintProfileValue(allocator, "standard");
    try std.testing.expectEqualStrings("standard", profile.object.get("selected").?.string);
    try std.testing.expectEqual(@as(usize, 3), profile.object.get("profiles").?.array.items.len);

    const gate = try lint_intelligence.lintGateValue(allocator, zlint.array, "standard", false, 0);
    try std.testing.expect(!gate.object.get("passed").?.bool);
    try std.testing.expectEqual(@as(usize, 2), gate.object.get("blocking_findings").?.array.items.len);

    const plan = try lint_intelligence.fixPlanValue(allocator, zlint.array);
    try std.testing.expectEqual(@as(usize, 1), plan.object.get("safe").?.array.items.len);
    try std.testing.expectEqual(@as(usize, 1), plan.object.get("risky").?.array.items.len);
    try std.testing.expectEqual(@as(usize, 1), plan.object.get("manual").?.array.items.len);

    const baseline = try lint_intelligence.baselineValue(allocator, zlint.array, zwanzig.array);
    try std.testing.expectEqual(@as(usize, 2), baseline.object.get("new_findings").?.array.items.len);
    try std.testing.expectEqual(@as(usize, 1), baseline.object.get("accepted_findings").?.array.items.len);
    try std.testing.expectEqual(@as(usize, 1), baseline.object.get("resolved_findings").?.array.items.len);

    const suppressions = try lint_intelligence.suppressionsValue(allocator, zlint.array,
        \\{"findings":[{"rule":"format-rule","severity":"warning","path":"src/a.zig","line":1,"message":"known"},{"rule":"old-rule","severity":"warning","path":"src/old.zig","line":9,"message":"gone"}]}
    );
    try std.testing.expectEqual(@as(usize, 1), suppressions.object.get("suppressed").?.array.items.len);
    try std.testing.expectEqual(@as(usize, 2), suppressions.object.get("active").?.array.items.len);
    try std.testing.expectEqual(@as(usize, 1), suppressions.object.get("stale_suppressions").?.array.items.len);

    const trend = try lint_intelligence.trendValue(allocator, zwanzig.array, zlint.array);
    try std.testing.expectEqual(@as(usize, 2), trend.object.get("new_findings").?.array.items.len);
    try std.testing.expectEqual(@as(usize, 1), trend.object.get("persistent_findings").?.array.items.len);
    try std.testing.expectEqual(@as(usize, 1), trend.object.get("resolved_findings").?.array.items.len);
}
