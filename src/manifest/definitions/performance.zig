const types = @import("../types.zig");

const fieldHint = types.fieldHint;
const schema = types.schema;
const schemaWithHints = types.schemaWithHints;
const tool = types.tool;
const group = types.ToolGroup.performance_workflows;

/// Risk policy reused by related tool definitions.
const artifact_risk = types.ToolRisk{ .writes_artifacts = true, .writes_require_apply = true, .preview_by_default = true };
/// Risk policy reused by related tool definitions.
const command_risk = types.ToolRisk{ .writes_artifacts = true, .writes_require_apply = true, .preview_by_default = true, .executes_project_code = true, .executes_user_command = true };
/// Risk policy reused by related tool definitions.
const backend_risk = types.ToolRisk{ .writes_artifacts = true, .writes_require_apply = true, .preview_by_default = true, .executes_backend = true, .executes_project_code = true, .executes_user_command = true };

/// Input schema reused by coverage input tool definitions.
const coverage_input_schema = schema(&.{
    .{ "coverage", "string", false },
    .{ "path", "string", false },
    .{ "content", "string", false },
    .{ "format", "string", false },
    .{ "limit", "integer", false },
});
/// Input schema reused by coverage artifact tool definitions.
const coverage_artifact_schema = schema(&.{
    .{ "coverage", "string", false },
    .{ "path", "string", false },
    .{ "content", "string", false },
    .{ "format", "string", false },
    .{ "baseline_id", "string", false },
    .{ "output", "string", false },
    .{ "apply", "boolean", false },
    .{ "limit", "integer", false },
});
/// Input schema reused by coverage merge tool definitions.
const coverage_merge_schema = schema(&.{
    .{ "current", "string", false },
    .{ "baseline", "string", false },
    .{ "left", "string", false },
    .{ "right", "string", false },
    .{ "output", "string", false },
    .{ "apply", "boolean", false },
    .{ "min_line_rate_bp", "integer", false },
    .{ "min_changed_line_rate_bp", "integer", false },
    .{ "changed_files", "string", false },
});
/// Input schema reused by coverage compare tool definitions.
const coverage_compare_schema = schema(&.{
    .{ "current", "string", false },
    .{ "baseline", "string", false },
    .{ "coverage", "string", false },
    .{ "min_line_rate_bp", "integer", false },
    .{ "min_changed_line_rate_bp", "integer", false },
    .{ "changed_files", "string", false },
});
/// Input schema reused by bench artifact tool definitions.
const bench_artifact_schema = schema(&.{
    .{ "command", "string", false },
    .{ "results", "string", false },
    .{ "current", "string", false },
    .{ "baseline", "string", false },
    .{ "baseline_id", "string", false },
    .{ "output", "string", false },
    .{ "apply", "boolean", false },
    .{ "timeout_ms", "integer", false },
    .{ "threshold_pct", "integer", false },
    .{ "limit", "integer", false },
});
/// Input schema reused by bench run tool definitions.
const bench_run_schema = schema(&.{
    .{ "command", "string", true },
    .{ "output", "string", false },
    .{ "apply", "boolean", false },
    .{ "timeout_ms", "integer", false },
});
/// Input schema for benchmark comparison evidence and threshold settings.
const bench_compare_schema = schema(&.{
    .{ "results", "string", false },
    .{ "current", "string", false },
    .{ "baseline", "string", false },
    .{ "threshold_pct", "integer", false },
    .{ "limit", "integer", false },
});
/// Input schema for profiler commands, profile content, and backend options.
const profiler_schema = schemaWithHints(&.{
    .{ "command", "string", false },
    .{ "path", "string", false },
    .{ "content", "string", false },
    .{ "output", "string", false },
    .{ "apply", "boolean", false },
    .{ "timeout_ms", "integer", false },
    .{ "samply_path", "string", false },
    .{ "tracy_capture_path", "string", false },
    .{ "probe_backend", "boolean", false },
    .{ "address", "string", false },
    .{ "port", "integer", false },
    .{ "seconds", "integer", false },
    .{ "limit", "integer", false },
}, &.{
    fieldHint("samply_path", .{ .description = "Optional samply executable path for this call only." }),
    fieldHint("tracy_capture_path", .{ .description = "Optional tracy-capture executable path for this call only." }),
    fieldHint("probe_backend", .{ .description = "Run a backend availability probe for this call.", .default_bool = false }),
});
/// Input schema for recording a Samply capture.
const samply_record_schema = schemaWithHints(&.{
    .{ "command", "string", true },
    .{ "output", "string", false },
    .{ "apply", "boolean", false },
    .{ "timeout_ms", "integer", false },
    .{ "samply_path", "string", false },
}, &.{
    fieldHint("samply_path", .{ .description = "Optional samply executable path for this call only." }),
});
/// Input schema for reading profiler evidence from content or workspace path.
const profile_input_schema = schema(&.{
    .{ "path", "string", false },
    .{ "content", "string", false },
    .{ "profile", "string", false },
    .{ "limit", "integer", false },
});
/// Input schema for registering an existing profiler artifact.
const profile_artifact_schema = schema(&.{
    .{ "path", "string", true },
    .{ "apply", "boolean", false },
});
/// Input schema for probing tracy-capture availability.
const tracy_probe_schema = schemaWithHints(&.{
    .{ "tracy_capture_path", "string", false },
    .{ "probe_backend", "boolean", false },
    .{ "timeout_ms", "integer", false },
}, &.{
    fieldHint("tracy_capture_path", .{ .description = "Optional tracy-capture executable path for this call only." }),
    fieldHint("probe_backend", .{ .description = "Run a backend availability probe for this call.", .default_bool = false }),
});
/// Input schema for generating Tracy instrumentation hints.
const tracy_hints_schema = schema(&.{
    .{ "profile", "string", false },
    .{ "bench", "string", false },
    .{ "limit", "integer", false },
});

/// Run a caller-supplied coverage command and optionally write a coverage run artifact.
pub const zig_coverage_run = tool(.{ .description = "Run a caller-supplied coverage command and optionally write a coverage run artifact.", .input_schema = schema(&.{ .{ "command", "string", true }, .{ "output", "string", false }, .{ "apply", "boolean", false }, .{ "timeout_ms", "integer", false }, .{ "target", "string", false }, .{ "coverage_backend", "string", false }, .{ "coverage_artifacts", "string", false } }), .read_only = false, .group = group, .risk = command_risk, .plan = .{ .apply_gated_mutation = "Runs a user command and writes a provenance-tracked coverage run artifact only with apply=true." } });
/// Map LCOV or zigar coverage evidence into normalized file and line-rate records.
pub const zig_coverage_map = tool(.{ .description = "Map LCOV or zigar coverage evidence into normalized file and line-rate records.", .input_schema = coverage_input_schema, .group = group, .plan = .{ .pure_analysis = "Parses supplied coverage content or a workspace coverage file." } });
/// Merge two coverage evidence maps into one normalized coverage map.
pub const zig_coverage_merge = tool(.{ .description = "Merge two coverage evidence maps into one normalized coverage map.", .input_schema = coverage_merge_schema, .read_only = false, .group = group, .risk = artifact_risk, .plan = .{ .apply_gated_mutation = "Writes merged coverage artifacts only with apply=true." } });
/// Compare current coverage against a baseline and report rate deltas.
pub const zig_coverage_diff = tool(.{ .description = "Compare current coverage against a baseline and report rate deltas.", .input_schema = coverage_compare_schema, .group = group, .plan = .{ .pure_analysis = "Compares supplied coverage evidence without running tests." } });
/// Create or preview a coverage baseline artifact with identity metadata.
pub const zig_coverage_baseline = tool(.{ .description = "Create or preview a coverage baseline artifact with identity metadata.", .input_schema = coverage_artifact_schema, .read_only = false, .group = group, .risk = artifact_risk, .plan = .{ .apply_gated_mutation = "Writes coverage baseline artifacts only with apply=true." } });
/// Evaluate line-rate and changed-file coverage budgets from normalized coverage evidence.
pub const zig_coverage_budget_check = tool(.{ .description = "Evaluate line-rate and changed-file coverage budgets from normalized coverage evidence.", .input_schema = coverage_compare_schema, .group = group, .plan = .{ .pure_analysis = "Checks supplied coverage evidence against caller thresholds." } });
/// Discover likely benchmark suites and runnable commands in the workspace.
pub const zig_bench_discover = tool(.{ .description = "Discover likely benchmark suites and runnable commands in the workspace.", .input_schema = schema(&.{.{ "limit", "integer", false }}), .group = group, .plan = .{ .pure_analysis = "Scans workspace files for benchmark conventions." } });
/// Run or preview a benchmark command and normalize timing output.
pub const zig_bench_run = tool(.{ .description = "Run or preview a benchmark command and normalize timing output.", .input_schema = bench_run_schema, .read_only = false, .group = group, .risk = command_risk, .plan = .{ .apply_gated_mutation = "Runs a user benchmark command and writes results only with apply=true." } });
/// Create or preview a benchmark baseline artifact.
pub const zig_bench_baseline = tool(.{ .description = "Create or preview a benchmark baseline artifact.", .input_schema = bench_artifact_schema, .read_only = false, .group = group, .risk = artifact_risk, .plan = .{ .apply_gated_mutation = "Writes benchmark baselines only with apply=true." } });
/// Inspect benchmark baseline or history artifacts.
pub const zig_benchmark_history = tool(.{ .description = "Inspect benchmark baseline or history artifacts.", .input_schema = schema(&.{ .{ "path", "string", false }, .{ "limit", "integer", false } }), .group = group, .plan = .{ .pure_analysis = "Reads benchmark history from workspace artifacts." } });
/// Compare current benchmark results to a baseline and classify regressions.
pub const zig_bench_compare = tool(.{ .description = "Compare current benchmark results to a baseline and classify regressions.", .input_schema = bench_compare_schema, .group = group, .plan = .{ .pure_analysis = "Compares supplied benchmark evidence without running commands." } });
/// Gate benchmark comparison evidence and optionally persist a one-shot session result.
pub const zig_bench_regression_gate = tool(.{ .description = "Gate benchmark comparison evidence and optionally persist a one-shot session result.", .input_schema = schema(&.{ .{ "current", "string", true }, .{ "baseline", "string", true }, .{ "threshold_pct", "integer", false }, .{ "session_id", "string", false }, .{ "apply", "boolean", false } }), .output_schema = types.outputSchema(.patch_session), .read_only = false, .group = group, .risk = artifact_risk, .plan = .{ .workspace_artifact = "Compares supplied benchmark evidence and writes a cache-local session snapshot only with apply=true." } });
/// Evaluate benchmark comparison evidence against a regression budget.
pub const zig_perf_budget_check = tool(.{ .description = "Evaluate benchmark comparison evidence against a regression budget.", .input_schema = schema(&.{ .{ "comparison", "string", false }, .{ "results", "string", false }, .{ "max_regression_pct", "integer", false } }), .group = group, .plan = .{ .pure_analysis = "Checks supplied performance evidence against caller thresholds." } });
/// Plan focused profiling when benchmark comparison evidence indicates regressions.
pub const zig_profile_regression = tool(.{ .description = "Plan focused profiling when benchmark comparison evidence indicates regressions.", .input_schema = schema(&.{ .{ "comparison", "string", false }, .{ "backend", "string", false }, .{ "command", "string", false }, .{ "threshold_pct", "integer", false } }), .group = group, .plan = .{ .pure_analysis = "Builds a profiling plan from supplied regression evidence." } });
/// Record or preview a Samply profile capture with explicit unavailable-tool behavior.
pub const zig_samply_record = tool(.{ .description = "Record or preview a Samply profile capture with explicit unavailable-tool behavior.", .input_schema = samply_record_schema, .read_only = false, .group = group, .risk = backend_risk, .plan = .{ .apply_gated_mutation = "Runs samply and writes profile artifacts only with apply=true." } });
/// Summarize Samply or Firefox-profile JSON evidence.
pub const zig_samply_summary = tool(.{ .description = "Summarize Samply or Firefox-profile JSON evidence.", .input_schema = profile_input_schema, .group = group, .plan = .{ .pure_analysis = "Summarizes supplied profile evidence without invoking a viewer." } });
/// Import profile JSON into a normalized Samply profile artifact.
pub const zig_samply_import = tool(.{ .description = "Import profile JSON into a normalized Samply-compatible artifact.", .input_schema = profiler_schema, .read_only = false, .group = group, .risk = artifact_risk, .plan = .{ .apply_gated_mutation = "Writes imported profile artifacts only with apply=true." } });
/// Describe and optionally register a Samply profile artifact.
pub const zig_samply_artifact = tool(.{ .description = "Describe and optionally register a Samply profile artifact.", .input_schema = profile_artifact_schema, .read_only = false, .group = group, .risk = artifact_risk, .plan = .{ .apply_gated_mutation = "Registers profile artifacts only with apply=true." } });
/// Return a safe plan for opening a profile artifact in an external viewer.
pub const zig_profile_open = tool(.{ .description = "Return a safe plan for opening a profile artifact in an external viewer.", .input_schema = schema(&.{ .{ "path", "string", true }, .{ "viewer", "string", false } }), .group = group, .plan = .{ .pure_analysis = "Reports viewer instructions without launching applications." } });
/// Plan Tracy instrumentation and capture prerequisites for the current workspace.
pub const zig_tracy_plan = tool(.{ .description = "Plan Tracy instrumentation and capture prerequisites for the current workspace.", .input_schema = schema(&.{.{ "limit", "integer", false }}), .group = group, .plan = .{ .pure_analysis = "Scans workspace files for Tracy setup signals." } });
/// Probe Tracy capture backend availability with explicit not-probed and unavailable states.
pub const zig_tracy_probe = tool(.{ .description = "Probe Tracy capture backend availability with explicit not-probed and unavailable states.", .input_schema = tracy_probe_schema, .group = group, .risk = .{ .executes_backend = true }, .plan = .{ .dynamic_command = "Optionally runs tracy-capture --help when probe_backend=true." } });
/// Capture or preview a Tracy trace artifact.
pub const zig_tracy_capture = tool(.{ .description = "Capture or preview a Tracy trace artifact.", .input_schema = profiler_schema, .read_only = false, .group = group, .risk = backend_risk, .plan = .{ .apply_gated_mutation = "Runs tracy-capture and writes traces only with apply=true." } });
/// Describe and optionally register Tracy trace artifacts.
pub const zig_tracy_artifacts = tool(.{ .description = "Describe and optionally register Tracy trace artifacts.", .input_schema = profile_artifact_schema, .read_only = false, .group = group, .risk = artifact_risk, .plan = .{ .apply_gated_mutation = "Registers Tracy trace artifacts only with apply=true." } });
/// Generate Tracy instrumentation hints from static signals and performance evidence.
pub const zig_tracy_hints = tool(.{ .description = "Generate Tracy instrumentation hints from static signals and performance evidence.", .input_schema = tracy_hints_schema, .group = group, .plan = .{ .pure_analysis = "Produces instrumentation hints without modifying source." } });
/// Build or preview a performance evidence bundle from supplied coverage, benchmark, and profiler evidence.
pub const zig_perf_evidence_pack = tool(.{ .description = "Build or preview a performance evidence bundle from supplied coverage, benchmark, and profiler evidence.", .input_schema = schema(&.{ .{ "coverage", "string", false }, .{ "benchmarks", "string", false }, .{ "samply", "string", false }, .{ "tracy", "string", false }, .{ "flamegraph", "string", false }, .{ "validation", "string", false }, .{ "output", "string", false }, .{ "apply", "boolean", false } }), .read_only = false, .group = group, .risk = artifact_risk, .plan = .{ .apply_gated_mutation = "Writes performance evidence bundles only with apply=true." } });
