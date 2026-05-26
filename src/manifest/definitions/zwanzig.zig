const types = @import("../types.zig");

const schema = types.schema;
const schemaWithHints = types.schemaWithHints;
const tool = types.tool;
const fieldHint = types.fieldHint;
const backend_contracts = @import("../../domain/zig/backend_contracts.zig");

/// Run zwanzig as optional Zig static-analysis backend with JSON output by default.
pub const zig_lint = tool(.{
    .description = "Run zwanzig as optional Zig static-analysis backend with JSON output by default.",
    .input_schema = schema(&.{ .{ "path", "string", false }, .{ "rules_do", "string", false }, .{ "rules_skip", "string", false }, .{ "config", "string", false }, .{ "args", "string", false } }),
    .read_only = true,
    .group = .zwanzig,
    .risk = .{ .executes_backend = true },
    .plan = .{ .dynamic_command = "Backend-backed workflow whose exact argv depends on runtime arguments, workspace state, or configured helper paths." },
    .static_analysis_tier = .zwanzig_backed,
});
/// Run optional zwanzig-backed static analysis with SARIF output.
pub const zig_lint_sarif = tool(.{
    .description = "Run optional zwanzig-backed static analysis with SARIF output.",
    .input_schema = schema(&.{ .{ "path", "string", false }, .{ "rules_do", "string", false }, .{ "rules_skip", "string", false }, .{ "config", "string", false }, .{ "args", "string", false } }),
    .read_only = true,
    .group = .zwanzig,
    .risk = .{ .executes_backend = true },
    .plan = .{ .dynamic_command = "Backend-backed workflow whose exact argv depends on runtime arguments, workspace state, or configured helper paths." },
    .static_analysis_tier = .zwanzig_backed,
});
/// List optional zwanzig-backed lint/static-analysis rules when the backend is installed.
pub const zig_lint_rules = tool(.{
    .description = "List optional zwanzig-backed lint/static-analysis rules when the backend is installed.",
    .input_schema = schema(&.{}),
    .read_only = true,
    .group = .zwanzig,
    .risk = .{ .executes_backend = true },
    .plan = .{ .dynamic_command = "Backend-backed workflow whose exact argv depends on runtime arguments, workspace state, or configured helper paths." },
    .static_analysis_tier = .zwanzig_backed,
});
/// Run an optional zwanzig-backed graph dump mode, writing DOT files under an explicit workspace output directory.
pub const zig_analysis_graphs = tool(.{
    .description = "Run an optional zwanzig-backed graph dump mode, writing DOT files under an explicit workspace output directory.",
    .input_schema = schemaWithHints(&.{ .{ "mode", "string", true }, .{ "path", "string", true }, .{ "output", "string", true }, .{ "args", "string", false } }, &.{
        fieldHint("mode", .{ .description = "zwanzig graph dump mode.", .enum_values = backend_contracts.zwanzig_graph_mode_names[0..] }),
        fieldHint("output", .{ .description = "Workspace-relative graph output directory.", .path_kind = "output_path" }),
    }),
    .read_only = false,
    .group = .zwanzig,
    .risk = .{ .writes_artifacts = true, .executes_backend = true },
    .plan = .{ .workspace_artifact = "Writes an explicit workspace-local artifact path and may use a configured backend; never writes source by default." },
    .static_analysis_tier = .zwanzig_backed,
});
