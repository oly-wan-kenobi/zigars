const types = @import("../types.zig");

const schema = types.schema;
const schemaWithHints = types.schemaWithHints;
const tool = types.tool;
const fieldHint = types.fieldHint;
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
pub const zig_profile_run = tool(.{
    .description = "Run an explicit user-provided profiler command in the workspace after splitting argv without a shell.",
    .input_schema = schema(&.{ .{ "command", "string", true }, .{ "timeout_ms", "integer", false } }),
    .read_only = false,
    .group = .profiling,
    .risk = .{ .writes_artifacts = true, .executes_project_code = true, .executes_user_command = true },
    .plan = .{ .dynamic_command = "Backend-backed workflow whose exact argv depends on runtime arguments, workspace state, or configured helper paths." },
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
