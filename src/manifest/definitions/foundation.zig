//! Tool definitions for the foundation groups: artifact registry lifecycle
//! (index, read, prune, session view), runtime observability (metrics, backend
//! health history, ZLS timeline, tool latency), trust/safety auditing (trust
//! report, command provenance, risk audit, clean-tree gate), result-shape
//! contracts, and release-drift checks. Only artifact_prune mutates state and
//! requires apply=true; all others are pure-analysis or bounded reads.
const types = @import("../types.zig");

const schema = types.schema;
const schemaWithHints = types.schemaWithHints;
const outputSchema = types.outputSchema;
const tool = types.tool;
const fieldHint = types.fieldHint;

/// Shared field hint for result shape depth across foundation tools.
const mode_hint = fieldHint("mode", .{ .description = "Result shape depth.", .default_string = "standard", .enum_values = &.{ "compact", "standard", "deep" } });

/// Index registered and scanned workspace artifacts with hashes, provenance, and explicit scan limits.
pub const zigars_artifact_index = tool(.{
    .description = "Index registered and scanned workspace artifacts with hashes, provenance, and explicit scan limits.",
    .input_schema = schemaWithHints(&.{ .{ "path", "string", false }, .{ "limit", "integer", false }, .{ "include_hashes", "boolean", false }, .{ "mode", "string", false } }, &.{
        .{ .field_name = "include_hashes", .hint = .{ .description = "Compute bounded sha256 hashes for scanned artifacts.", .default_bool = true } },
        mode_hint,
    }),
    .read_only = true,
    .group = .artifact_registry,
    .plan = .{ .pure_analysis = "Reads bounded artifact registry metadata and generated artifact files inside the workspace." },
});
/// Read a bounded workspace artifact with sha256 identity and result-shape omission metadata.
pub const zigars_artifact_read = tool(.{
    .description = "Read a bounded workspace artifact with sha256 identity and result-shape omission metadata.",
    .input_schema = schemaWithHints(&.{ .{ "path", "string", true }, .{ "max_bytes", "integer", false }, .{ "mode", "string", false } }, &.{mode_hint}),
    .output_schema = outputSchema(.artifact),
    .read_only = true,
    .group = .artifact_registry,
    .plan = .{ .pure_analysis = "Reads one workspace-bound artifact path without executing backends or mutating state." },
});
/// Inspect a bounded shared workflow session JSONL file without changing lifecycle state.
pub const zigars_session_view = tool(.{
    .description = "Inspect a bounded shared workflow session JSONL file without changing lifecycle state.",
    .input_schema = schemaWithHints(&.{ .{ "kind", "string", true }, .{ "id", "string", true } }, &.{
        fieldHint("kind", .{ .description = "Session kind token, such as dependency_migration or bench_regression_gate." }),
        fieldHint("id", .{ .description = "Session id token returned by the workflow that created the session." }),
    }),
    .read_only = true,
    .group = .artifact_registry,
    .plan = .{ .pure_analysis = "Reads .zigars-cache/sessions/<kind>/<id>.jsonl through workspace-bound cache paths and does not perform resume, close, cancel, cleanup, or mutation." },
});
/// Preview or apply pruning of stale artifact registry entries without deleting artifact files.
pub const zigars_artifact_prune = tool(.{
    .description = "Preview or apply pruning of stale artifact registry entries without deleting artifact files.",
    .input_schema = schemaWithHints(&.{ .{ "apply", "boolean", false }, .{ "mode", "string", false } }, &.{mode_hint}),
    .output_schema = outputSchema(.patch_session),
    .read_only = false,
    .group = .artifact_registry,
    .risk = .{ .writes_artifacts = true, .writes_require_apply = true, .preview_by_default = true },
    .plan = .{ .apply_gated_mutation = "Prunes .zigars-cache artifact registry metadata only when apply=true; preview includes preimage identity." },
});

/// Return v2 runtime metrics, backend health history, ZLS timeline, and tool latency counters.
pub const zigars_metrics_v2 = tool(.{
    .description = "Return v2 runtime metrics, backend health history, ZLS timeline, and tool latency counters.",
    .input_schema = schema(&.{}),
    .read_only = true,
    .group = .observability,
    .plan = .{ .pure_analysis = "Reads in-memory runtime counters and bounded observability rings." },
});
/// Return bounded backend probe history and current probe cache state.
pub const zigars_backend_health_history = tool(.{
    .description = "Return bounded backend probe history and current probe cache state.",
    .input_schema = schema(&.{}),
    .read_only = true,
    .group = .observability,
    .plan = .{ .pure_analysis = "Reads in-memory backend probe observations without probing backends." },
});
/// Return bounded ZLS status transition history for the current zigars process.
pub const zigars_zls_timeline = tool(.{
    .description = "Return bounded ZLS status transition history for the current zigars process.",
    .input_schema = schema(&.{}),
    .read_only = true,
    .group = .observability,
    .plan = .{ .pure_analysis = "Reads in-memory ZLS status observations without sending LSP requests." },
});
/// Return per-tool handler latency and error counters for the current zigars process.
pub const zigars_tool_latency = tool(.{
    .description = "Return per-tool handler latency and error counters for the current zigars process.",
    .input_schema = schema(&.{}),
    .read_only = true,
    .group = .observability,
    .plan = .{ .pure_analysis = "Reads in-memory tool dispatch counters." },
});

/// Summarize zigars path policy, backend identities, risk metadata, dependency hashes, and optional clean-tree evidence.
pub const zigars_trust_report = tool(.{
    .description = "Summarize zigars path policy, backend identities, risk metadata, dependency hashes, and optional clean-tree evidence.",
    .input_schema = schema(&.{ .{ "include_clean_tree", "boolean", false }, .{ "timeout_ms", "integer", false } }),
    .read_only = true,
    .group = .trust_safety,
    .risk = .{ .executes_backend = true },
    .plan = .{ .dynamic_command = "Optionally runs git status for clean-tree evidence; otherwise reads runtime and manifest metadata." },
});
/// Report manifest-backed command, backend, ZLS, artifact, and mutation provenance for one tool or all tools.
pub const zigars_command_provenance = tool(.{
    .description = "Report manifest-backed command, backend, ZLS, artifact, and mutation provenance for one tool or all tools.",
    .input_schema = schema(&.{.{ "tool", "string", false }}),
    .read_only = true,
    .group = .trust_safety,
    .plan = .{ .pure_analysis = "Reads compiled tool manifest planning and risk metadata." },
});
/// Audit registered tool risk metadata, apply gates, backend execution, project-code execution, and user commands.
pub const zigars_risk_audit = tool(.{
    .description = "Audit registered tool risk metadata, apply gates, backend execution, project-code execution, and user commands.",
    .input_schema = schema(&.{.{ "include_none", "boolean", false }}),
    .read_only = true,
    .group = .trust_safety,
    .plan = .{ .pure_analysis = "Reads compiled tool manifest risk metadata." },
});
/// Run a bounded git status clean-tree gate and classify generated or vendored changes.
pub const zigars_clean_tree_gate = tool(.{
    .description = "Run a bounded git status clean-tree gate and classify generated or vendored changes.",
    .input_schema = schema(&.{.{ "timeout_ms", "integer", false }}),
    .read_only = true,
    .group = .trust_safety,
    .risk = .{ .executes_backend = true },
    .plan = .{ .dynamic_command = "Runs git status --porcelain in the configured workspace with a bounded timeout." },
});

/// Describe compact, standard, and deep zigars result-shape contracts with explicit omission metadata.
pub const zigars_result_shape = tool(.{
    .description = "Describe compact, standard, and deep zigars result-shape contracts with explicit omission metadata.",
    .input_schema = schemaWithHints(&.{.{ "mode", "string", false }}, &.{mode_hint}),
    .read_only = true,
    .group = .result_contracts,
    .plan = .{ .pure_analysis = "Returns static result-shape policy." },
});
/// Plan a result-shape output budget for a tool, including stable field and omission priorities.
pub const zigars_output_budget_plan = tool(.{
    .description = "Plan a result-shape output budget for a tool, including stable field and omission priorities.",
    .input_schema = schemaWithHints(&.{ .{ "mode", "string", false }, .{ "token_budget", "integer", false }, .{ "tool", "string", false } }, &.{mode_hint}),
    .read_only = true,
    .group = .result_contracts,
    .plan = .{ .pure_analysis = "Returns static output-budget policy; token counts are planning estimates." },
});

/// Check product docs for public contract markers and generated tool-index coverage.
pub const zigars_docs_drift_check = tool(.{
    .description = "Check product docs for public contract markers and generated tool-index coverage.",
    .input_schema = schemaWithHints(&.{.{ "mode", "string", false }}, &.{mode_hint}),
    .read_only = true,
    .group = .release_drift,
    .plan = .{ .pure_analysis = "Reads bounded product documentation files in the workspace." },
});
/// Scan public docs for release-claim overstatements and evidence-label drift.
pub const zigars_release_claim_check = tool(.{
    .description = "Scan public docs for release-claim overstatements and evidence-label drift.",
    .input_schema = schemaWithHints(&.{.{ "mode", "string", false }}, &.{mode_hint}),
    .read_only = true,
    .group = .release_drift,
    .plan = .{ .pure_analysis = "Reads bounded product documentation files and checks conservative claim tokens." },
});
/// Check that the generated tool index mentions every registered tool.
pub const zigars_tool_index_check = tool(.{
    .description = "Check that the generated tool index mentions every registered tool.",
    .input_schema = schemaWithHints(&.{.{ "mode", "string", false }}, &.{mode_hint}),
    .read_only = true,
    .group = .release_drift,
    .plan = .{ .pure_analysis = "Compares compiled tool manifest entries to docs/tool-index.generated.md." },
});
