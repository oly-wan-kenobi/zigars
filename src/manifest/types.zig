const std = @import("std");
/// Schema helpers re-exported for manifest definition files.
pub const tooling = @import("tooling.zig");

/// User-facing grouping used for catalog navigation and keyword routing.
pub const ToolGroup = enum {
    discovery,
    agent_workflows,
    core_zig,
    formatting_and_edits,
    zls,
    docs,
    static_analysis,
    ci_artifacts,
    zwanzig,
    profiling,
    artifact_registry,
    observability,
    trust_safety,
    result_contracts,
    release_drift,
    environment_profiles,
    runtime_ux,
    release_intelligence,
    api_lifecycle,
    dependency_security,
    performance_workflows,
    runtime_diagnostics,
    public_rollout,
};

/// Evidence quality tier advertised for static-analysis tools.
pub const StaticAnalysisTier = enum {
    advisory_orientation,
    parser_backed,
    compiler_backed,
    zls_backed,
    zlint_backed,
    zwanzig_backed,
};

/// Side-effect capabilities used to derive MCP hints and safety policy.
pub const ToolRisk = struct {
    writes_source: bool = false,
    writes_artifacts: bool = false,
    writes_require_apply: bool = false,
    preview_by_default: bool = false,
    mutates_lsp_state: bool = false,
    executes_project_code: bool = false,
    executes_user_command: bool = false,
    executes_backend: bool = false,
};

/// Exact argv alternatives for commands that may accept an optional file.
pub const FileCommandPlan = struct {
    file_args: []const []const u8,
    fallback_args: []const []const u8,
};

/// Exact command shapes that can be planned without inspecting runtime input.
pub const CommandPlan = union(enum) {
    argv: []const []const u8,
    optional_file: FileCommandPlan,
    required_file: []const []const u8,
    required_path: []const []const u8,
};

/// ZLS request metadata, including sync and state-mutation requirements.
pub const ZlsPlan = struct {
    method: []const u8,
    requires_document_sync: bool = false,
    mutates_document_state: bool = false,
    required_capability: ?[]const u8 = null,
};

/// Planning contract for a tool, from exact argv to advisory-only analysis.
pub const PlanPolicy = union(enum) {
    exact_command: CommandPlan,
    dynamic_command: []const u8,
    zls_request: ZlsPlan,
    apply_gated_mutation: []const u8,
    workspace_artifact: []const u8,
    pure_analysis: []const u8,
    not_plannable: []const u8,
};

/// Source-of-truth declaration for one MCP tool in the manifest.
pub const ToolDefinition = struct {
    description: []const u8,
    input_schema: tooling.SchemaSpec = schema(&.{}),
    read_only: bool = true,
    group: ToolGroup,
    risk: ToolRisk = .{},
    plan: PlanPolicy,
    static_analysis_tier: ?StaticAnalysisTier = null,
};

/// Keywords attached to a tool group for discovery and client matching.
pub const GroupSpec = struct {
    group: ToolGroup,
    keywords: []const []const u8,
};

/// Builds a schema spec from comptime field triples.
pub fn schema(comptime fields: []const tooling.SchemaField) tooling.SchemaSpec {
    return tooling.schema(fields);
}

/// Builds a schema spec with per-field metadata overrides.
pub fn schemaWithHints(comptime fields: []const tooling.SchemaField, comptime field_hints: []const tooling.SchemaFieldHint) tooling.SchemaSpec {
    return tooling.schemaWithHints(fields, field_hints);
}

/// Creates a field-hint override for a named schema field.
pub fn fieldHint(comptime field_name: []const u8, comptime hint: tooling.FieldHint) tooling.SchemaFieldHint {
    return .{ .field_name = field_name, .hint = hint };
}

/// Marker helper that keeps tool definitions visually uniform.
pub fn tool(definition: ToolDefinition) ToolDefinition {
    return definition;
}
