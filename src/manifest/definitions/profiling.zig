//! Tool definitions for the `profiling` group: workflow planning, user-command
//! execution, and zflame/diff-folded SVG rendering. zig_profile_run executes an
//! explicit user-supplied argv without a shell; zig_flamegraph and
//! zig_flamegraph_diff invoke configured optional backends (zflame, diff-folded)
//! and write workspace artifacts — both carry executes_backend risk. All write
//! paths use explicit output paths within the workspace sandbox.
const types = @import("../types.zig");

const schema = types.schema;
const schemaWithHints = types.schemaWithHints;
const tool = types.tool;
const fieldHint = types.fieldHint;
// Format names are sourced from backend_contracts to keep allowed values in sync
// with the zflame backend definition rather than duplicating them here.
const backend_contracts = @import("../../domain/zig/backend_contracts.zig");

/// Return structured external-capture plans and zflame rendering next steps without running profilers.
pub const zig_profile_plan = tool(.{
    .description = "Return structured external-capture plans and zflame rendering next steps without running profilers.",
    .input_schema = schemaWithHints(&.{ .{ "binary", "string", false }, .{ "platform", "string", false }, .{ "output_prefix", "string", false } }, &.{
        fieldHint("platform", .{ .description = "Requested platform override; omitted means use zigars' detected host platform." }),
        fieldHint("output_prefix", .{ .description = "Workspace-relative prefix used in suggested capture/render artifact paths.", .path_kind = "output_path" }),
    }),
    .read_only = true,
    .group = .profiling,
    .plan = .{ .pure_analysis = "Profiling workflow planner; returns structured external capture suggestions and rendering next steps without running profilers." },
});
/// Run an explicit user-provided profiler command in the workspace after splitting argv without a shell.
/// Apply-gated: without apply=true it previews the resolved argv and env policy
/// instead of executing. The child environment is scrubbed to an allowlist so
/// secrets in the server's environment never reach the agent-chosen command.
pub const zig_profile_run = tool(.{
    .description = "Run an explicit user-provided profiler command in the workspace after splitting argv without a shell. Previews unless apply=true; the child environment is scrubbed to a minimal allowlist.",
    .input_schema = schema(&.{ .{ "command", "string", true }, .{ "apply", "boolean", false }, .{ "timeout_ms", "integer", false } }),
    .read_only = false,
    .group = .profiling,
    .risk = .{ .writes_artifacts = true, .executes_project_code = true, .executes_user_command = true, .writes_require_apply = true, .preview_by_default = true },
    .plan = .{ .apply_gated_mutation = "Runs the explicit user profiler argv only when apply=true; otherwise previews the resolved argv and the environment allowlist without executing." },
});
/// Render captured profiler output to SVG through zflame with explicit format and auditable artifact metadata.
pub const zig_flamegraph = tool(.{
    .description = "Render captured profiler output to SVG through zflame with explicit format and auditable artifact metadata.",
    .input_schema = schemaWithHints(&.{ .{ "format", "string", true }, .{ "input", "string", true }, .{ "output", "string", true }, .{ "title", "string", false }, .{ "subtitle", "string", false }, .{ "colors", "string", false }, .{ "width", "integer", false }, .{ "min_width", "integer", false }, .{ "hash", "boolean", false } }, &.{
        fieldHint("format", .{ .description = "Explicit profiler input format passed to zflame.", .enum_values = backend_contracts.zflame_format_names[0..] }),
        fieldHint("colors", .{ .description = "zflame color palette passed as --colors=<palette>." }),
        fieldHint("width", .{ .description = "SVG width passed as --width=<pixels>.", .minimum = 1 }),
        fieldHint("min_width", .{ .description = "Minimum frame width passed as --min-width=<pixels>.", .minimum = 1 }),
    }),
    .read_only = false,
    .group = .profiling,
    .risk = .{ .writes_artifacts = true, .executes_backend = true },
    .plan = .{ .workspace_artifact = "Writes an explicit workspace-local artifact path and may use a configured backend; never writes source by default." },
});

/// Create an auditable differential folded stack through diff-folded, then render it through zflame recursive.
pub const zig_flamegraph_diff = tool(.{
    .description = "Create an auditable differential folded stack through diff-folded, then render it through zflame recursive.",
    .input_schema = schemaWithHints(&.{ .{ "before", "string", true }, .{ "after", "string", true }, .{ "output", "string", true }, .{ "intermediate", "string", false }, .{ "title", "string", false }, .{ "subtitle", "string", false }, .{ "colors", "string", false }, .{ "width", "integer", false }, .{ "min_width", "integer", false }, .{ "hash", "boolean", false } }, &.{
        fieldHint("intermediate", .{ .description = "Optional workspace-relative folded diff output path; defaults to .zigars-cache/profile/diff-<n>.folded.", .path_kind = "output_path" }),
        fieldHint("colors", .{ .description = "zflame color palette passed as --colors=<palette>." }),
        fieldHint("width", .{ .description = "SVG width passed as --width=<pixels>.", .minimum = 1 }),
        fieldHint("min_width", .{ .description = "Minimum frame width passed as --min-width=<pixels>.", .minimum = 1 }),
    }),
    .read_only = false,
    .group = .profiling,
    .risk = .{ .writes_artifacts = true, .executes_backend = true },
    .plan = .{ .workspace_artifact = "Writes an explicit workspace-local artifact path and may use a configured backend; never writes source by default." },
});
