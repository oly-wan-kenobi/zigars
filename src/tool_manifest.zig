const std = @import("std");

const types = @import("tool_manifest/types.zig");
const aggregate = @import("tool_manifest/aggregate.zig");
const groups_mod = @import("tool_manifest/groups.zig");

pub const ToolHandler = types.ToolHandler;
pub const ToolGroup = types.ToolGroup;
pub const HandlerModule = types.HandlerModule;
pub const HandlerRef = types.HandlerRef;
pub const ToolRisk = types.ToolRisk;
pub const StaticAnalysisTier = types.StaticAnalysisTier;
pub const FileCommandPlan = types.FileCommandPlan;
pub const CommandPlan = types.CommandPlan;
pub const ZlsPlan = types.ZlsPlan;
pub const PlanPolicy = types.PlanPolicy;
pub const ToolDefinition = types.ToolDefinition;
pub const GroupSpec = types.GroupSpec;

pub const ToolId = aggregate.ToolId;
pub const ToolMeta = aggregate.ToolMeta;
pub const ToolEntry = aggregate.ToolEntry;
pub const definitions = aggregate.definitions;
pub const group_specs = groups_mod.group_specs;

pub const entries = aggregate.entries;
pub const specs = aggregate.specs;

pub fn entryFor(id: ToolId) ToolEntry {
    return entries[@intFromEnum(id)];
}

pub fn find(name: []const u8) ?ToolMeta {
    for (entries) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry.meta;
    }
    return null;
}

pub fn findEntry(name: []const u8) ?ToolEntry {
    for (entries) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry;
    }
    return null;
}

pub fn groupFor(id: ToolId) ToolGroup {
    return entryFor(id).group;
}

pub fn groupName(group: ToolGroup) []const u8 {
    return @tagName(group);
}

pub fn groupKeywords(group: ToolGroup) []const []const u8 {
    inline for (group_specs) |spec| {
        if (spec.group == group) return spec.keywords;
    }
    unreachable;
}

pub fn riskFor(id: ToolId) ToolRisk {
    return entryFor(id).risk;
}

pub fn planFor(id: ToolId) PlanPolicy {
    return entryFor(id).plan;
}

pub fn staticAnalysisTierFor(id: ToolId) ?StaticAnalysisTier {
    return entryFor(id).static_analysis_tier;
}

pub fn commandPlanFor(id: ToolId) ?CommandPlan {
    return switch (planFor(id)) {
        .exact_command => |plan| plan,
        else => null,
    };
}

pub fn planKind(plan: PlanPolicy) []const u8 {
    return switch (plan) {
        .exact_command => "exact_command",
        .dynamic_command => "dynamic_command",
        .zls_request => "zls_request",
        .apply_gated_mutation => "apply_gated_mutation",
        .workspace_artifact => "workspace_artifact",
        .pure_analysis => "pure_analysis",
        .not_plannable => "not_plannable",
    };
}

pub fn riskLevel(risk: ToolRisk) []const u8 {
    if (risk.writes_source or risk.executes_user_command) return "high";
    if (risk.executes_project_code or risk.writes_artifacts) return "medium";
    if (risk.mutates_lsp_state or risk.executes_backend) return "low";
    return "none";
}

pub fn riskValue(allocator: std.mem.Allocator, spec: ToolMeta) !std.json.Value {
    const risk_value = riskFor(spec.id);
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "level", .{ .string = riskLevel(risk_value) });
    try obj.put(allocator, "mcp_read_only_hint", .{ .bool = readOnlyHintFor(spec) });
    try obj.put(allocator, "writes_source", .{ .bool = risk_value.writes_source });
    try obj.put(allocator, "writes_artifacts", .{ .bool = risk_value.writes_artifacts });
    try obj.put(allocator, "writes_require_apply", .{ .bool = risk_value.writes_require_apply });
    try obj.put(allocator, "preview_by_default", .{ .bool = risk_value.preview_by_default });
    try obj.put(allocator, "mutates_lsp_state", .{ .bool = risk_value.mutates_lsp_state });
    try obj.put(allocator, "executes_project_code", .{ .bool = risk_value.executes_project_code });
    try obj.put(allocator, "executes_user_command", .{ .bool = risk_value.executes_user_command });
    try obj.put(allocator, "executes_backend", .{ .bool = risk_value.executes_backend });
    return .{ .object = obj };
}

pub fn readOnlyHintFor(spec: ToolMeta) bool {
    const risk_value = riskFor(spec.id);
    return spec.read_only and
        !risk_value.writes_source and
        !risk_value.writes_artifacts and
        !risk_value.mutates_lsp_state and
        !risk_value.executes_project_code and
        !risk_value.executes_user_command;
}

pub fn idempotentHintFor(spec: ToolMeta) bool {
    const risk_value = riskFor(spec.id);
    return readOnlyHintFor(spec) and
        !risk_value.writes_source and
        !risk_value.writes_artifacts and
        !risk_value.mutates_lsp_state and
        !risk_value.executes_project_code and
        !risk_value.executes_user_command;
}

pub fn destructiveHintFor(spec: ToolMeta) bool {
    const risk_value = riskFor(spec.id);
    if (risk_value.writes_require_apply and risk_value.preview_by_default) return false;
    return !spec.read_only;
}

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
