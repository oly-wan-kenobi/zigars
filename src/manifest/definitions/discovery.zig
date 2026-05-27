const types = @import("../types.zig");

const schema = types.schema;
const schemaWithHints = types.schemaWithHints;
const tool = types.tool;
const fieldHint = types.fieldHint;

/// Return a compact zigars tool/capability index with search keywords, including fmt, formatter, formatting, and zig fmt.
pub const zigars_capabilities = tool(.{
    .description = "Return a compact zigars tool/capability index with search keywords, including fmt, formatter, formatting, and zig fmt.",
    .input_schema = schema(&.{}),
    .read_only = true,
    .group = .discovery,
    .plan = .{ .pure_analysis = "Manifest/catalog lookup; does not execute backends or mutate workspace state." },
});
/// Return a compact searchable zigars tool index with aliases for fmt, formatter, formatting, zig fmt, docs, ZLS, lint, and profiling.
pub const zigars_tool_index = tool(.{
    .description = "Return a compact searchable zigars tool index with aliases for fmt, formatter, formatting, zig fmt, docs, ZLS, lint, and profiling.",
    .input_schema = schema(&.{}),
    .read_only = true,
    .group = .discovery,
    .plan = .{ .pure_analysis = "Manifest/catalog lookup; does not execute backends or mutate workspace state." },
});
/// Return zigars' compact tool catalog and schema-discovery hints.
pub const zigars_schema = tool(.{
    .description = "Return zigars' compact tool catalog and schema-discovery hints.",
    .input_schema = schema(&.{}),
    .read_only = true,
    .group = .discovery,
    .plan = .{ .pure_analysis = "Manifest/catalog lookup; does not execute backends or mutate workspace state." },
});
/// Return packaged setup metadata for Zig, ZLS, zwanzig, zflame, and diff-folded backends.
pub const zigars_backend_catalog = tool(.{
    .description = "Return packaged setup metadata for Zig, ZLS, zwanzig, zflame, and diff-folded backends.",
    .input_schema = schema(&.{
        .{ "include_configured_paths", "boolean", false },
    }),
    .read_only = true,
    .group = .discovery,
    .plan = .{ .pure_analysis = "Backend setup catalog lookup; does not execute tools or mutate workspace state." },
});
/// Diagnose common zigars MCP configuration, workspace, backend, and transport problems.
pub const zigars_doctor = tool(.{
    .description = "Diagnose common zigars MCP configuration, workspace, backend, and transport problems.",
    .input_schema = schema(&.{ .{ "probe_backends", "boolean", false }, .{ "timeout_ms", "integer", false } }),
    .read_only = true,
    .group = .discovery,
    .risk = .{ .executes_backend = true },
    .plan = .{ .dynamic_command = "Backend-backed workflow whose exact argv depends on runtime arguments, workspace state, or configured helper paths." },
});
/// Return workspace and configured backend paths.
pub const zigars_workspace_info = tool(.{
    .description = "Return workspace and configured backend paths.",
    .input_schema = schema(&.{}),
    .read_only = true,
    .group = .discovery,
    .plan = .{ .pure_analysis = "Manifest/catalog lookup; does not execute backends or mutate workspace state." },
});
/// Return zigars process counters and backend health.
pub const zigars_metrics = tool(.{
    .description = "Return zigars process counters and backend health.",
    .input_schema = schema(&.{}),
    .read_only = true,
    .group = .discovery,
    .plan = .{ .pure_analysis = "Manifest/catalog lookup; does not execute backends or mutate workspace state." },
});
/// Report HTTP transport support and configured endpoint.
pub const zigars_http_status = tool(.{
    .description = "Report HTTP transport support and configured endpoint.",
    .input_schema = schema(&.{}),
    .read_only = true,
    .group = .discovery,
    .plan = .{ .pure_analysis = "Manifest/catalog lookup; does not execute backends or mutate workspace state." },
});
/// Preview the exact argv/cwd/timeout for a deterministic zigars command workflow; use zig_tool_plan for non-command-backed tools.
pub const zig_command_plan = tool(.{
    .description = "Preview the exact argv/cwd/timeout for a deterministic zigars command workflow; use zig_tool_plan for non-command-backed tools.",
    .input_schema = schema(&.{ .{ "tool", "string", true }, .{ "file", "string", false }, .{ "path", "string", false }, .{ "args", "string", false }, .{ "timeout_ms", "integer", false } }),
    .read_only = true,
    .group = .discovery,
    .plan = .{ .pure_analysis = "Returns exact argv plans only for command-backed tools; reports known non-command tools as unsupported instead of executing." },
});
/// Return manifest-derived planning support for any registered zigars tool, including exact commands, dynamic backends, ZLS requests, and pure analysis tools.
pub const zig_tool_plan = tool(.{
    .description = "Return manifest-derived planning support for any registered zigars tool, including exact commands, dynamic backends, ZLS requests, and pure analysis tools.",
    .input_schema = schema(&.{ .{ "tool", "string", true }, .{ "file", "string", false }, .{ "path", "string", false }, .{ "input", "string", false }, .{ "output", "string", false }, .{ "command", "string", false }, .{ "args", "string", false }, .{ "timeout_ms", "integer", false } }),
    .read_only = true,
    .group = .discovery,
    .plan = .{ .pure_analysis = "Returns manifest-derived planning metadata; does not execute commands or mutate workspace state." },
});
/// Detect active Zig/ZLS versions, project version hints, and installed Zig version managers.
pub const zig_toolchain_resolve = tool(.{
    .description = "Detect active Zig/ZLS versions, project version hints, and installed Zig version managers.",
    .input_schema = schema(&.{ .{ "probe_managers", "boolean", false }, .{ "timeout_ms", "integer", false } }),
    .read_only = true,
    .group = .discovery,
    .risk = .{ .executes_backend = true },
    .plan = .{ .dynamic_command = "Backend-backed workflow whose exact argv depends on runtime arguments, workspace state, or configured helper paths." },
});
