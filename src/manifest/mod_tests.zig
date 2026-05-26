const std = @import("std");
const subject = @import("mod.zig");
const tooling = subject.tooling;
const tool_catalog_render = subject.tool_catalog_render;
const version = subject.version;
const ToolGroup = subject.ToolGroup;
const ToolRisk = subject.ToolRisk;
const StaticAnalysisTier = subject.StaticAnalysisTier;
const FileCommandPlan = subject.FileCommandPlan;
const CommandPlan = subject.CommandPlan;
const ZlsPlan = subject.ZlsPlan;
const PlanPolicy = subject.PlanPolicy;
const ToolDefinition = subject.ToolDefinition;
const GroupSpec = subject.GroupSpec;
const ToolId = subject.ToolId;
const ToolMeta = subject.ToolMeta;
const ToolEntry = subject.ToolEntry;
const definitions = subject.definitions;
const group_specs = subject.group_specs;
const entries = subject.entries;
const specs = subject.specs;
const entryFor = subject.entryFor;
const find = subject.find;
const findEntry = subject.findEntry;
const groupFor = subject.groupFor;
const groupName = subject.groupName;
const groupKeywords = subject.groupKeywords;
const riskFor = subject.riskFor;
const planFor = subject.planFor;
const staticAnalysisTierFor = subject.staticAnalysisTierFor;
const commandPlanFor = subject.commandPlanFor;
const planKind = subject.planKind;
const riskLevel = subject.riskLevel;
const riskValue = subject.riskValue;
const readOnlyHintFor = subject.readOnlyHintFor;
const idempotentHintFor = subject.idempotentHintFor;
const destructiveHintFor = subject.destructiveHintFor;

test "manifest declares one entry for each tool id" {
    try std.testing.expectEqual(@typeInfo(ToolId).@"enum".fields.len, entries.len);
    try std.testing.expectEqual(entries.len, specs.len);
}
test "tool names are unique" {
    for (specs, 0..) |left, left_index| {
        for (specs[left_index + 1 ..]) |right| {
            try std.testing.expect(!std.mem.eql(u8, left.name, right.name));
        }
    }
}
test "tool schemas use validator-supported JSON field types" {
    for (specs) |spec| {
        for (spec.input_schema.fields) |field| {
            try std.testing.expect(std.mem.eql(u8, field[1], "string") or
                std.mem.eql(u8, field[1], "boolean") or
                std.mem.eql(u8, field[1], "integer"));
        }
    }
}
test "tool planning policies expose exact command plans only for exact commands" {
    for (entries) |entry| {
        try std.testing.expect(planKind(entry.plan).len > 0);
        switch (entry.plan) {
            .exact_command => try std.testing.expect(commandPlanFor(entry.id) != null),
            else => try std.testing.expect(commandPlanFor(entry.id) == null),
        }
    }
}
test "static analysis product tools expose capability tiers" {
    for (entries) |entry| {
        if (entry.group == .static_analysis or entry.group == .zwanzig) {
            try std.testing.expect(entry.static_analysis_tier != null);
        } else {
            try std.testing.expect(entry.static_analysis_tier == null);
        }
    }
    try std.testing.expectEqual(StaticAnalysisTier.parser_backed, staticAnalysisTierFor(.zig_ast_decl_summary).?);
    try std.testing.expectEqual(StaticAnalysisTier.zlint_backed, staticAnalysisTierFor(.zig_zlint).?);
    try std.testing.expectEqual(StaticAnalysisTier.zwanzig_backed, staticAnalysisTierFor(.zig_lint).?);
}
test "risk metadata distinguishes read-only annotations from code execution" {
    try std.testing.expect(find("zig_profile_run").?.read_only);
    const profile_risk = riskFor(.zig_profile_run);
    try std.testing.expect(profile_risk.executes_user_command);
    try std.testing.expectEqualStrings("high", riskLevel(profile_risk));
    try std.testing.expect(!readOnlyHintFor(find("zig_profile_run").?));
    try std.testing.expect(!idempotentHintFor(find("zig_profile_run").?));

    const build_risk = riskFor(.zig_build);
    try std.testing.expect(build_risk.executes_project_code);
    try std.testing.expectEqualStrings("medium", riskLevel(build_risk));
    try std.testing.expect(!readOnlyHintFor(find("zig_build").?));
    try std.testing.expect(!idempotentHintFor(find("zig_build").?));

    const validation_risk = riskFor(.zigar_validate_patch);
    try std.testing.expect(validation_risk.executes_project_code);
    try std.testing.expect(validation_risk.writes_artifacts);

    const triage_risk = riskFor(.zig_test_failure_triage);
    try std.testing.expect(triage_risk.executes_project_code);

    const fmt = find("zig_format").?;
    try std.testing.expect(riskFor(.zig_format).writes_require_apply);
    try std.testing.expect(riskFor(.zig_format).writes_artifacts);
    try std.testing.expect(riskFor(.zig_format).mutates_lsp_state);
    try std.testing.expect(!destructiveHintFor(fmt));
    try std.testing.expect(!readOnlyHintFor(fmt));

    const hover = find("zig_hover").?;
    try std.testing.expect(hover.read_only);
    try std.testing.expect(riskFor(.zig_hover).mutates_lsp_state);
    try std.testing.expect(!readOnlyHintFor(hover));
    try std.testing.expect(!idempotentHintFor(hover));

    const code_actions = find("zig_code_actions").?;
    try std.testing.expect(code_actions.read_only);
    try std.testing.expect(riskFor(.zig_code_actions).mutates_lsp_state);
    try std.testing.expect(!readOnlyHintFor(code_actions));

    const matrix_risk = riskFor(.zig_matrix_check);
    try std.testing.expect(matrix_risk.executes_user_command);
    try std.testing.expectEqualStrings("high", riskLevel(matrix_risk));
    try std.testing.expect(!readOnlyHintFor(find("zig_matrix_check").?));

    try std.testing.expect(readOnlyHintFor(find("zig_version").?));
    try std.testing.expect(idempotentHintFor(find("zig_version").?));
}
test "manifest lookup returns null for unknown tools" {
    try std.testing.expect(find("missing_tool") == null);
    try std.testing.expect(findEntry("missing_tool") == null);
}
