//! Canonical manifest contract for tool metadata, risk flags, and planning policies.
const std = @import("std");

const types = @import("types.zig");
const aggregate = @import("aggregate.zig");
const groups_mod = @import("groups.zig");

pub const tooling = @import("tooling.zig");
pub const tool_catalog_render = @import("tool_catalog_render.zig");
pub const version = @import("version.zig");

pub const ToolGroup = types.ToolGroup;
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
const group_keywords = buildGroupKeywords();

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
    return group_keywords[@intFromEnum(group)];
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

/// Computes the external mutability hint from both declared read_only and risk capabilities.
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

fn buildGroupKeywords() [std.meta.fields(ToolGroup).len][]const []const u8 {
    var result: [std.meta.fields(ToolGroup).len][]const []const u8 = undefined;
    inline for (group_specs) |spec| result[@intFromEnum(spec.group)] = spec.keywords;
    return result;
}

test {
    _ = @import("all_tests.zig");
}
