//! Comptime aggregation of all tool definitions into stable id enums and metadata tables.
//!
//! Iterates `definition_groups` from `definitions.zig` in declaration order,
//! validates each entry against the manifest invariants, and materializes the
//! `ToolId` enum, `entries` table, and `specs` slice consumed by adapters and
//! catalog renderers. Group ordering is a stable public contract: append new
//! groups; never reorder existing ones.

const std = @import("std");

const definitions_mod = @import("definitions.zig");
const types = @import("types.zig");

/// Flattened definition namespace re-exported from `definitions.zig`; the
/// source-of-truth for all tool field values consumed by the aggregation loop.
pub const definitions = definitions_mod.definitions;
const definition_groups = definitions_mod.definition_groups;
const definition_count = countDefinitions();

/// Exhaustive enum of every registered tool, generated from declaration names
/// in `definition_groups`. Integer tag values match the entry index in
/// `entries`, so `@intFromEnum(id)` is a direct table lookup.
pub const ToolId = buildToolId();

/// Public metadata exported to adapter registration surfaces.
/// Contains schema and read-only annotation but excludes routing, risk, and
/// planning policy; callers that need those should use `ToolEntry` directly.
pub const ToolMeta = struct {
    id: ToolId,
    name: []const u8,
    description: []const u8,
    input_schema: types.tooling.SchemaSpec,
    output_schema: ?types.tooling.OutputSchemaSpec,
    read_only: bool,
};

/// Full manifest entry consumed by the MCP adapter dispatcher and catalog
/// renderers. Combines `ToolMeta` with risk flags, planning policy, and
/// static-analysis tier so routing decisions can inspect all dimensions.
pub const ToolEntry = struct {
    id: ToolId,
    name: []const u8,
    meta: ToolMeta,
    group: types.ToolGroup,
    risk: types.ToolRisk,
    plan: types.PlanPolicy,
    static_analysis_tier: ?types.StaticAnalysisTier,
};

/// Ordered table of all registered tool entries. Declaration order matches
/// `ToolId` integer values; index with `@intFromEnum(id)` for O(1) lookup.
pub const entries = buildEntries();
/// Metadata-only projection of `entries`; passed to adapter registration
/// when risk and planning policy are not needed by the caller.
pub const specs = buildSpecs();

/// Iterates `definition_groups` in declaration order and produces the
/// compile-time `entries` table. Also invokes `validateDefinition` on each
/// tool, which raises `@compileError` for policy violations.
fn buildEntries() [definition_count]ToolEntry {
    // validateDefinition scans each apply-gated schema for an `apply` boolean
    // via comptime string compares; raise the eval branch budget so the
    // cumulative comptime work across every definition stays in bounds.
    @setEvalBranchQuota(10_000);
    var result: [definition_count]ToolEntry = undefined;
    comptime var index: usize = 0;
    inline for (definition_groups) |group| {
        inline for (std.meta.declarations(group)) |decl| {
            const entry_index = index;
            index += 1;
            const id = @field(ToolId, decl.name);
            const definition = @field(group, decl.name);
            comptime validateDefinition(decl.name, definition);
            const meta = ToolMeta{
                .id = id,
                .name = decl.name,
                .description = definition.description,
                .input_schema = definition.input_schema,
                .output_schema = definition.output_schema,
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

/// Validates one tool definition against the manifest invariant rules, raising
/// `@compileError` on violation. Called for every entry inside `buildEntries`.
///
/// Key invariants enforced here:
/// - Source-writing tools must set `writes_require_apply` and `preview_by_default`.
/// - Raw `read_only` must not coexist with `writes_source` or `executes_user_command`.
/// - Apply-gated tools must declare an `apply: boolean` schema field.
/// - Plan policy must agree with the corresponding risk flags.
/// - Static-analysis tools must declare a capability tier; others must not.
fn validateDefinition(comptime name: []const u8, comptime definition: types.ToolDefinition) void {
    if (definition.risk.writes_source and !definition.risk.writes_require_apply) {
        @compileError(name ++ ": source-writing tools must require apply=true");
    }
    if (definition.risk.writes_source and !definition.risk.preview_by_default) {
        @compileError(name ++ ": source-writing tools must preview by default");
    }
    // The raw `read_only` field is internal source-of-truth, not the MCP hint
    // (`readOnlyHintFor` derives the external value from risk flags). Keep the raw
    // field internally consistent for the two capabilities that unambiguously make
    // a tool non-read-only at the source level: writing source, and executing a
    // caller-supplied command. Reject those combinations at comptime rather than
    // relying on the derived hint to paper over the contradiction.
    //
    // SCOPE NOTE: the review's Finding 4 also lists `writes_artifacts`,
    // `mutates_lsp_state`, and `executes_project_code`. Those are deliberately NOT
    // guarded here. The manifest sets raw `read_only = true` on ~24 tools that
    // carry one of those flags (e.g. `zig_hover`/`zig_code_actions` mutate LSP
    // document state, `zig_build`/`zig_test` execute project code and write build
    // artifacts) and existing tests assert that raw value. The MCP surface is
    // already correct because `readOnlyHintFor` ANDs in all five `!`-flags.
    // Widening this guard to those three capabilities would require flipping 24
    // declarations across files outside this change's scope and contradict the
    // tested raw-field convention, so it is reported as a follow-up rather than
    // applied here.
    if (definition.read_only and definition.risk.writes_source) {
        @compileError(name ++ ": source-writing tools cannot be read-only");
    }
    if (definition.read_only and definition.risk.executes_user_command) {
        @compileError(name ++ ": user-command-executing tools cannot be read-only");
    }
    // Apply-gate invariant must bind to the wire contract, not just the risk
    // flag: if a tool advertises `writes_require_apply` it must accept an `apply`
    // boolean in its input schema, otherwise the runtime gate is unreachable from
    // the client. Scan the declared schema for an `apply: boolean` field.
    //
    // Note on `writes_artifacts`: it is deliberately NOT forced to be
    // apply-gated. `zig_matrix_check` writes build/test artifacts as an
    // intentional side effect of running configured binaries and ships ungated;
    // forcing an apply gate there would break that intended behavior. Only
    // `writes_source` and explicit `writes_require_apply` carry the apply
    // contract.
    if (definition.risk.writes_require_apply and !schemaHasApplyBoolean(definition.input_schema)) {
        @compileError(name ++ ": apply-gated tools must declare an `apply` boolean input field");
    }
    switch (definition.plan) {
        .apply_gated_mutation => {
            if (!definition.risk.writes_require_apply or !definition.risk.preview_by_default) {
                @compileError(name ++ ": apply-gated mutations must advertise apply-required preview behavior");
            }
        },
        .workspace_artifact => {
            if (!definition.risk.writes_artifacts) {
                @compileError(name ++ ": workspace artifact plans must advertise artifact writes");
            }
        },
        .zls_request => |plan| {
            if (plan.mutates_document_state and !definition.risk.mutates_lsp_state) {
                @compileError(name ++ ": mutating ZLS requests must advertise LSP state mutation");
            }
        },
        else => {},
    }
    const needs_static_tier = definition.group == .static_analysis or definition.group == .zwanzig;
    if (needs_static_tier and definition.static_analysis_tier == null) {
        @compileError(name ++ ": static-analysis tools must declare a capability tier");
    }
    if (!needs_static_tier and definition.static_analysis_tier != null) {
        @compileError(name ++ ": only static-analysis tools may declare a capability tier");
    }
}

/// Returns whether a schema declares an `apply: boolean` field.
///
/// `SchemaField` is the tuple `(name, json_type, required)`. The apply gate
/// is only reachable from a client when the schema explicitly exposes a field
/// named `"apply"` typed `"boolean"`; any other type (string, integer) does
/// not satisfy the contract.
fn schemaHasApplyBoolean(comptime input_schema: types.tooling.SchemaSpec) bool {
    inline for (input_schema.fields) |field| {
        if (std.mem.eql(u8, field[0], "apply") and std.mem.eql(u8, field[1], "boolean")) return true;
    }
    return false;
}

/// Strips risk and plan fields from `entries`, producing the `ToolMeta`-only
/// slice passed to schema registration surfaces.
fn buildSpecs() [definition_count]ToolMeta {
    var result: [definition_count]ToolMeta = undefined;
    inline for (entries, 0..) |entry, index| result[index] = entry.meta;
    return result;
}

/// Returns the total number of tool declarations across all definition groups;
/// used to size the comptime arrays before iterating.
fn countDefinitions() comptime_int {
    comptime var count: usize = 0;
    inline for (definition_groups) |group| count += std.meta.declarations(group).len;
    return count;
}

/// Produces the `ToolId` enum type, one tag per declaration in declaration
/// order. The integer tag matches the corresponding `entries` index, so casts
/// between the two are always safe at comptime and at runtime.
fn buildToolId() type {
    // Use the smallest integer type that fits the tool count to avoid padding.
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
