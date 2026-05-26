const std = @import("std");

const definitions_mod = @import("definitions.zig");
const types = @import("types.zig");

/// Raw definition namespace consumed by compile-time aggregation.
pub const definitions = definitions_mod.definitions;
const definition_groups = definitions_mod.definition_groups;
const definition_count = countDefinitions();

/// Exhaustive tool id enum generated from declaration names in definition groups.
pub const ToolId = buildToolId();

/// Public metadata exported to callers that do not need policy internals.
pub const ToolMeta = struct {
    id: ToolId,
    name: []const u8,
    description: []const u8,
    input_schema: types.tooling.SchemaSpec,
    read_only: bool,
};

/// Full manifest entry including routing, risk, and planning policy.
pub const ToolEntry = struct {
    id: ToolId,
    name: []const u8,
    meta: ToolMeta,
    group: types.ToolGroup,
    risk: types.ToolRisk,
    plan: types.PlanPolicy,
    static_analysis_tier: ?types.StaticAnalysisTier,
};

/// Stable manifest entries ordered by declaration group iteration.
pub const entries = buildEntries();
/// Metadata-only view of entries for schema registration surfaces.
pub const specs = buildSpecs();

/// Materializes definition declarations into runtime metadata tables at comptime.
fn buildEntries() [definition_count]ToolEntry {
    var result: [definition_count]ToolEntry = undefined;
    comptime var index: usize = 0;
    inline for (definition_groups) |group| {
        inline for (std.meta.declarations(group)) |decl| {
            const entry_index = index;
            index += 1;
            const id = @field(ToolId, decl.name);
            const definition = @field(group, decl.name);
            const meta = ToolMeta{
                .id = id,
                .name = decl.name,
                .description = definition.description,
                .input_schema = definition.input_schema,
                .read_only = definition.read_only,
            };
            result[entry_index] = .{
                .id = id,
                .name = decl.name,
                .meta = meta,
                .group = definition.group,
                .risk = definition.risk,
                .plan = definition.plan,
                .static_analysis_tier = definition.static_analysis_tier,
            };
        }
    }
    return result;
}

/// Projects the full entry table into the public metadata table.
fn buildSpecs() [definition_count]ToolMeta {
    var result: [definition_count]ToolMeta = undefined;
    inline for (entries, 0..) |entry, index| result[index] = entry.meta;
    return result;
}

/// Counts declarations across all manifest definition groups.
fn countDefinitions() comptime_int {
    comptime var count: usize = 0;
    inline for (definition_groups) |group| count += std.meta.declarations(group).len;
    return count;
}

/// Builds the enum tags from manifest declaration names.
fn buildToolId() type {
    const IntTag = std.math.IntFittingRange(0, definition_count -| 1);
    comptime var names: [definition_count][]const u8 = undefined;
    comptime var values: [definition_count]IntTag = undefined;
    comptime var index: usize = 0;
    inline for (definition_groups) |group| {
        inline for (std.meta.declarations(group)) |decl| {
            names[index] = decl.name;
            values[index] = @intCast(index);
            index += 1;
        }
    }
    return @Enum(IntTag, .exhaustive, &names, &values);
}
