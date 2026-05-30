//! Schema vocabulary for manifest tool definitions: groups, risk flags,
//! planning policies, and the canonical ToolDefinition shape.
//! Definition files import this module and never import tooling.zig directly.
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
/// All flags default to false (read-only, no side effects).
/// Combinations are evaluated by `riskLevel`, `readOnlyHintFor`, and `destructiveHintFor`
/// in mod.zig; changing a flag here may affect the computed MCP annotations.
pub const ToolRisk = struct {
    /// Tool modifies tracked source files in the workspace.
    writes_source: bool = false,
    /// Tool writes non-source artifacts (zig-out, coverage, etc.).
    writes_artifacts: bool = false,
    /// Source/artifact writes require apply=true; without it the tool previews only.
    writes_require_apply: bool = false,
    /// Tool defaults to preview mode even when apply=true is not required.
    preview_by_default: bool = false,
    /// Tool issues LSP requests that alter ZLS document state.
    mutates_lsp_state: bool = false,
    /// Tool spawns the project's own build or test binary.
    executes_project_code: bool = false,
    /// Tool runs an arbitrary user-supplied command; highest trust boundary.
    executes_user_command: bool = false,
    /// Tool invokes an optional backend (zls, zlint, zwanzig, zflame, etc.).
    executes_backend: bool = false,
};

/// Exact argv alternatives for commands that may accept an optional file.
pub const FileCommandPlan = struct {
    file_args: []const []const u8,
    fallback_args: []const []const u8,
};

/// Exact command shapes that can be planned without inspecting runtime input.
pub const CommandPlan = union(enum) {
    /// Fixed argv; no file or path argument is accepted.
    argv: []const []const u8,
    /// Two argv forms: one with a file argument, one without.
    optional_file: FileCommandPlan,
    /// Single argv template where a required file argument is appended.
    required_file: []const []const u8,
    /// Single argv template where a required path argument is appended.
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
    /// Argv is fully known at definition time; planners may pre-fill it.
    exact_command: CommandPlan,
    /// Argv is runtime-determined; payload is a human-readable reason.
    dynamic_command: []const u8,
    /// Dispatched as an LSP protocol request; no subprocess argv.
    zls_request: ZlsPlan,
    /// Mutation is gated behind apply=true; planners must prompt before invoking.
    apply_gated_mutation: []const u8,
    /// Produces a workspace artifact without mutating tracked source.
    workspace_artifact: []const u8,
    /// Read-only analysis; no commands or artifacts produced.
    pure_analysis: []const u8,
    /// Cannot be pre-planned; planners should treat the tool as opaque.
    not_plannable: []const u8,
};

/// Source-of-truth declaration for one MCP tool in the manifest.
/// Fields must remain consistent with the corresponding entry in tool_catalog.json
/// and the aggregate module that derives ToolEntry from this shape.
pub const ToolDefinition = struct {
    /// Human-readable tool description surfaced in tools/list responses.
    description: []const u8,
    /// MCP input schema; defaults to an empty schema (no arguments).
    input_schema: tooling.SchemaSpec = schema(&.{}),
    /// Optional output schema family used by tools/list outputSchema projection.
    output_schema: ?tooling.OutputSchemaSpec = null,
    /// True when the tool never writes source, artifacts, or LSP state.
    /// Validated at startup; inconsistency with risk flags is a compile-time error.
    read_only: bool = true,
    /// Navigation group shown in catalog output and used for keyword routing.
    group: ToolGroup,
    /// Capability flags for MCP hint derivation and safety policy.
    risk: ToolRisk = .{},
    /// Planner contract describing how the tool is invoked.
    plan: PlanPolicy,
    /// Evidence quality tier; required for static_analysis and zwanzig groups, null otherwise.
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

/// Builds a shared output schema declaration.
pub fn outputSchema(shape: tooling.OutputSchemaShape) tooling.OutputSchemaSpec {
    return tooling.outputSchema(shape);
}

/// Creates a field-hint override for a named schema field.
pub fn fieldHint(comptime field_name: []const u8, comptime hint: tooling.FieldHint) tooling.SchemaFieldHint {
    return .{ .field_name = field_name, .hint = hint };
}

/// Marker helper that keeps tool definitions visually uniform.
/// Acts as a no-op pass-through so definition files read as `tool(.{ ... })`
/// rather than a bare struct literal, making the list scannable.
pub fn tool(definition: ToolDefinition) ToolDefinition {
    return definition;
}
