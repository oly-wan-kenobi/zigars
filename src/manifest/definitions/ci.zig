const types = @import("../types.zig");

const schema = types.schema;
const schemaWithHints = types.schemaWithHints;
const tool = types.tool;
const fieldHint = types.fieldHint;

/// Convert diagnostics/check output into CI annotation records.
pub const zig_ci_annotations = tool(.{
    .description = "Convert diagnostics/check output into CI annotation records.",
    .input_schema = schema(&.{ .{ "file", "string", true }, .{ "timeout_ms", "integer", false } }),
    .read_only = true,
    .group = .ci_artifacts,
    .risk = .{ .executes_backend = true },
    .plan = .{ .dynamic_command = "Backend-backed workflow whose exact argv depends on runtime arguments, workspace state, or configured helper paths." },
});
/// Run Zig tests and return a command-level JUnit XML artifact with raw output metadata.
pub const zig_junit = tool(.{
    .description = "Run Zig tests and return a command-level JUnit XML artifact with raw output metadata.",
    .input_schema = schema(&.{ .{ "file", "string", false }, .{ "filter", "string", false }, .{ "args", "string", false }, .{ "timeout_ms", "integer", false } }),
    .read_only = true,
    .group = .ci_artifacts,
    .risk = .{ .writes_artifacts = true, .executes_project_code = true, .executes_backend = true },
    .plan = .{ .dynamic_command = "Backend-backed workflow whose exact argv depends on runtime arguments, workspace state, or configured helper paths." },
});
/// Run build/test checks across configured Zig binaries with direct per-entry status fields.
pub const zig_matrix_check = tool(.{
    .description = "Run build/test checks across configured Zig binaries with direct per-entry status fields.",
    .input_schema = schema(&.{ .{ "zig_paths", "string", false }, .{ "args", "string", false }, .{ "timeout_ms", "integer", false } }),
    .read_only = true,
    .group = .ci_artifacts,
    .risk = .{ .writes_artifacts = true, .executes_project_code = true, .executes_user_command = true, .executes_backend = true },
    .plan = .{ .dynamic_command = "Backend-backed workflow whose exact argv depends on runtime arguments, workspace state, or configured helper paths." },
});
