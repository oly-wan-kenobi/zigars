const types = @import("../types.zig");

const schema = types.schema;
const schemaWithHints = types.schemaWithHints;
const tool = types.tool;
const fieldHint = types.fieldHint;

pub const zigar_capabilities = tool(.{
    .description = "Return a compact zigar tool/capability index with search keywords, including fmt, formatter, formatting, and zig fmt.",
    .input_schema = schema(&.{}),
    .read_only = true,
    .group = .discovery,
    .plan = .{ .pure_analysis = "Manifest/catalog lookup; does not execute backends or mutate workspace state." },
});
pub const zigar_tool_index = tool(.{
    .description = "Return a compact searchable zigar tool index with aliases for fmt, formatter, formatting, zig fmt, docs, ZLS, lint, and profiling.",
    .input_schema = schema(&.{}),
    .read_only = true,
    .group = .discovery,
    .plan = .{ .pure_analysis = "Manifest/catalog lookup; does not execute backends or mutate workspace state." },
});
pub const zigar_schema = tool(.{
    .description = "Return zigar's compact tool catalog and schema-discovery hints.",
    .input_schema = schema(&.{}),
    .read_only = true,
    .group = .discovery,
    .plan = .{ .pure_analysis = "Manifest/catalog lookup; does not execute backends or mutate workspace state." },
});
pub const zigar_backend_catalog = tool(.{
    .description = "Return packaged setup metadata for Zig, ZLS, zwanzig, zflame, and diff-folded backends.",
    .input_schema = schema(&.{
        .{ "include_configured_paths", "boolean", false },
    }),
    .read_only = true,
    .group = .discovery,
    .plan = .{ .pure_analysis = "Backend setup catalog lookup; does not execute tools or mutate workspace state." },
});
pub const zigar_doctor = tool(.{
    .description = "Diagnose common zigar MCP configuration, workspace, backend, and transport problems.",
    .input_schema = schema(&.{ .{ "probe_backends", "boolean", false }, .{ "timeout_ms", "integer", false } }),
    .read_only = true,
    .group = .discovery,
    .risk = .{ .executes_backend = true },
    .plan = .{ .dynamic_command = "Backend-backed workflow whose exact argv depends on runtime arguments, workspace state, or configured helper paths." },
});
pub const zigar_workspace_info = tool(.{
    .description = "Return workspace and configured backend paths.",
    .input_schema = schema(&.{}),
    .read_only = true,
    .group = .discovery,
    .plan = .{ .pure_analysis = "Manifest/catalog lookup; does not execute backends or mutate workspace state." },
});
pub const zigar_metrics = tool(.{
    .description = "Return zigar process counters and backend health.",
    .input_schema = schema(&.{}),
    .read_only = true,
    .group = .discovery,
    .plan = .{ .pure_analysis = "Manifest/catalog lookup; does not execute backends or mutate workspace state." },
});
pub const zigar_http_status = tool(.{
    .description = "Report HTTP transport support and configured endpoint.",
    .input_schema = schema(&.{}),
    .read_only = true,
    .group = .discovery,
    .plan = .{ .pure_analysis = "Manifest/catalog lookup; does not execute backends or mutate workspace state." },
});
pub const zig_command_plan = tool(.{
    .description = "Preview the exact argv/cwd/timeout for a deterministic zigar command workflow; use zig_tool_plan for non-command-backed tools.",
    .input_schema = schema(&.{ .{ "tool", "string", true }, .{ "file", "string", false }, .{ "path", "string", false }, .{ "args", "string", false }, .{ "timeout_ms", "integer", false } }),
    .read_only = true,
    .group = .discovery,
    .plan = .{ .pure_analysis = "Returns exact argv plans only for command-backed tools; reports known non-command tools as unsupported instead of executing." },
});
pub const zig_tool_plan = tool(.{
    .description = "Return manifest-derived planning support for any registered zigar tool, including exact commands, dynamic backends, ZLS requests, and pure analysis tools.",
    .input_schema = schema(&.{ .{ "tool", "string", true }, .{ "file", "string", false }, .{ "path", "string", false }, .{ "input", "string", false }, .{ "output", "string", false }, .{ "command", "string", false }, .{ "args", "string", false }, .{ "timeout_ms", "integer", false } }),
    .read_only = true,
    .group = .discovery,
    .plan = .{ .pure_analysis = "Returns manifest-derived planning metadata; does not execute commands or mutate workspace state." },
});
pub const zig_toolchain_resolve = tool(.{
    .description = "Detect active Zig/ZLS versions, project version hints, and installed Zig version managers.",
    .input_schema = schema(&.{ .{ "probe_managers", "boolean", false }, .{ "timeout_ms", "integer", false } }),
    .read_only = true,
    .group = .discovery,
    .risk = .{ .executes_backend = true },
    .plan = .{ .dynamic_command = "Backend-backed workflow whose exact argv depends on runtime arguments, workspace state, or configured helper paths." },
});

test "discovery definitions expose capability metadata" {
    try @import("std").testing.expect(zigar_capabilities.description.len > 0);
}
