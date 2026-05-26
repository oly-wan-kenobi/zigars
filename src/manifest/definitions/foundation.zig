const types = @import("../types.zig");

const schema = types.schema;
const schemaWithHints = types.schemaWithHints;
const tool = types.tool;
const fieldHint = types.fieldHint;

const mode_hint = fieldHint("mode", .{ .description = "Result shape depth.", .default_string = "standard", .enum_values = &.{ "compact", "standard", "deep" } });

pub const zigar_artifact_index = tool(.{
    .description = "Index registered and scanned workspace artifacts with hashes, provenance, and explicit scan limits.",
    .input_schema = schemaWithHints(&.{ .{ "path", "string", false }, .{ "limit", "integer", false }, .{ "include_hashes", "boolean", false }, .{ "mode", "string", false } }, &.{
        .{ .field_name = "include_hashes", .hint = .{ .description = "Compute bounded sha256 hashes for scanned artifacts.", .default_bool = true } },
        mode_hint,
    }),
    .read_only = true,
    .group = .artifact_registry,
    .plan = .{ .pure_analysis = "Reads bounded artifact registry metadata and generated artifact files inside the workspace." },
});
pub const zigar_artifact_read = tool(.{
    .description = "Read a bounded workspace artifact with sha256 identity and result-shape omission metadata.",
    .input_schema = schemaWithHints(&.{ .{ "path", "string", true }, .{ "max_bytes", "integer", false }, .{ "mode", "string", false } }, &.{mode_hint}),
    .read_only = true,
    .group = .artifact_registry,
    .plan = .{ .pure_analysis = "Reads one workspace-bound artifact path without executing backends or mutating state." },
});
pub const zigar_artifact_prune = tool(.{
    .description = "Preview or apply pruning of stale artifact registry entries without deleting artifact files.",
    .input_schema = schemaWithHints(&.{ .{ "apply", "boolean", false }, .{ "mode", "string", false } }, &.{mode_hint}),
    .read_only = false,
    .group = .artifact_registry,
    .risk = .{ .writes_artifacts = true, .writes_require_apply = true, .preview_by_default = true },
    .plan = .{ .apply_gated_mutation = "Prunes .zigar-cache artifact registry metadata only when apply=true; preview includes preimage identity." },
});

pub const zigar_metrics_v2 = tool(.{
    .description = "Return v2 runtime metrics, backend health history, ZLS timeline, and tool latency counters.",
    .input_schema = schema(&.{}),
    .read_only = true,
    .group = .observability,
    .plan = .{ .pure_analysis = "Reads in-memory runtime counters and bounded observability rings." },
});
pub const zigar_backend_health_history = tool(.{
    .description = "Return bounded backend probe history and current probe cache state.",
    .input_schema = schema(&.{}),
    .read_only = true,
    .group = .observability,
    .plan = .{ .pure_analysis = "Reads in-memory backend probe observations without probing backends." },
});
pub const zigar_zls_timeline = tool(.{
    .description = "Return bounded ZLS status transition history for the current zigar process.",
    .input_schema = schema(&.{}),
    .read_only = true,
    .group = .observability,
    .plan = .{ .pure_analysis = "Reads in-memory ZLS status observations without sending LSP requests." },
});
pub const zigar_tool_latency = tool(.{
    .description = "Return per-tool handler latency and error counters for the current zigar process.",
    .input_schema = schema(&.{}),
    .read_only = true,
    .group = .observability,
    .plan = .{ .pure_analysis = "Reads in-memory tool dispatch counters." },
});

pub const zigar_trust_report = tool(.{
    .description = "Summarize zigar path policy, backend identities, risk metadata, dependency hashes, and optional clean-tree evidence.",
    .input_schema = schema(&.{ .{ "include_clean_tree", "boolean", false }, .{ "timeout_ms", "integer", false } }),
    .read_only = true,
    .group = .trust_safety,
    .risk = .{ .executes_backend = true },
    .plan = .{ .dynamic_command = "Optionally runs git status for clean-tree evidence; otherwise reads runtime and manifest metadata." },
});
pub const zigar_command_provenance = tool(.{
    .description = "Report manifest-backed command, backend, ZLS, artifact, and mutation provenance for one tool or all tools.",
    .input_schema = schema(&.{.{ "tool", "string", false }}),
    .read_only = true,
    .group = .trust_safety,
    .plan = .{ .pure_analysis = "Reads compiled tool manifest planning and risk metadata." },
});
pub const zigar_risk_audit = tool(.{
    .description = "Audit registered tool risk metadata, apply gates, backend execution, project-code execution, and user commands.",
    .input_schema = schema(&.{.{ "include_none", "boolean", false }}),
    .read_only = true,
    .group = .trust_safety,
    .plan = .{ .pure_analysis = "Reads compiled tool manifest risk metadata." },
});
pub const zigar_clean_tree_gate = tool(.{
    .description = "Run a bounded git status clean-tree gate and classify generated or vendored changes.",
    .input_schema = schema(&.{.{ "timeout_ms", "integer", false }}),
    .read_only = true,
    .group = .trust_safety,
    .risk = .{ .executes_backend = true },
    .plan = .{ .dynamic_command = "Runs git status --porcelain in the configured workspace with a bounded timeout." },
});

pub const zigar_result_shape = tool(.{
    .description = "Describe compact, standard, and deep zigar result-shape contracts with explicit omission metadata.",
    .input_schema = schemaWithHints(&.{.{ "mode", "string", false }}, &.{mode_hint}),
    .read_only = true,
    .group = .result_contracts,
    .plan = .{ .pure_analysis = "Returns static result-shape policy." },
});
pub const zigar_output_budget_plan = tool(.{
    .description = "Plan a result-shape output budget for a tool, including stable field and omission priorities.",
    .input_schema = schemaWithHints(&.{ .{ "mode", "string", false }, .{ "token_budget", "integer", false }, .{ "tool", "string", false } }, &.{mode_hint}),
    .read_only = true,
    .group = .result_contracts,
    .plan = .{ .pure_analysis = "Returns static output-budget policy; token counts are planning estimates." },
});

pub const zigar_docs_drift_check = tool(.{
    .description = "Check product docs for public contract markers and generated tool-index coverage.",
    .input_schema = schemaWithHints(&.{.{ "mode", "string", false }}, &.{mode_hint}),
    .read_only = true,
    .group = .release_drift,
    .plan = .{ .pure_analysis = "Reads bounded product documentation files in the workspace." },
});
pub const zigar_release_claim_check = tool(.{
    .description = "Scan public docs for release-claim overstatements and evidence-label drift.",
    .input_schema = schemaWithHints(&.{.{ "mode", "string", false }}, &.{mode_hint}),
    .read_only = true,
    .group = .release_drift,
    .plan = .{ .pure_analysis = "Reads bounded product documentation files and checks conservative claim tokens." },
});
pub const zigar_tool_index_check = tool(.{
    .description = "Check that the generated tool index mentions every registered tool.",
    .input_schema = schemaWithHints(&.{.{ "mode", "string", false }}, &.{mode_hint}),
    .read_only = true,
    .group = .release_drift,
    .plan = .{ .pure_analysis = "Compares compiled tool manifest entries to docs/tool-index.generated.md." },
});

test "foundation definitions expose artifact metadata" {
    try @import("std").testing.expect(zigar_artifact_index.description.len > 0);
}
