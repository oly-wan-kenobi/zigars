const types = @import("../types.zig");

const schema = types.schema;
const schemaWithHints = types.schemaWithHints;
const tool = types.tool;
const fieldHint = types.fieldHint;

const mode_hint = fieldHint("mode", .{ .description = "Result shape depth.", .default_string = "standard", .enum_values = &.{ "compact", "standard", "deep" } });
const command_hint = fieldHint("command", .{ .description = "Bounded Zig command to run.", .enum_values = &.{ "build", "build-test", "test", "check", "fmt-check" } });

pub const zigar_job_start = tool(.{
    .description = "Start a bounded zigar-managed Zig job and retain status, result, and event tails in process-local state.",
    .input_schema = schemaWithHints(&.{ .{ "command", "string", true }, .{ "file", "string", false }, .{ "args", "string", false }, .{ "timeout_ms", "integer", false }, .{ "mode", "string", false } }, &.{ command_hint, mode_hint }),
    .read_only = false,
    .group = .runtime_ux,
    .risk = .{ .executes_project_code = true, .executes_backend = true },
    .plan = .{ .dynamic_command = "Runs one allow-listed Zig command without a shell and stores bounded process-local job evidence." },
});

pub const zigar_job_status = tool(.{
    .description = "Read status and cancellation state for a zigar-managed job.",
    .input_schema = schema(&.{.{ "job_id", "string", true }}),
    .read_only = true,
    .group = .runtime_ux,
    .plan = .{ .pure_analysis = "Reads bounded process-local job state." },
});

pub const zigar_job_result = tool(.{
    .description = "Read the bounded result, output tails, and paginated events for a zigar-managed job.",
    .input_schema = schemaWithHints(&.{ .{ "job_id", "string", true }, .{ "cursor", "string", false }, .{ "limit", "integer", false }, .{ "mode", "string", false } }, &.{mode_hint}),
    .read_only = true,
    .group = .runtime_ux,
    .plan = .{ .pure_analysis = "Reads bounded process-local job result and event state." },
});

pub const zigar_job_cancel = tool(.{
    .description = "Request cancellation for a zigar-managed job and record the cancellation state.",
    .input_schema = schema(&.{ .{ "job_id", "string", true }, .{ "reason", "string", false } }),
    .read_only = false,
    .group = .runtime_ux,
    .plan = .{ .not_plannable = "Mutates process-local cancellation state; currently records cancellation for completed synchronous jobs." },
});

pub const zigar_cancel_status = tool(.{
    .description = "Read cancellation status for one job or all retained zigar-managed jobs.",
    .input_schema = schema(&.{.{ "job_id", "string", false }}),
    .read_only = true,
    .group = .runtime_ux,
    .plan = .{ .pure_analysis = "Reads process-local cancellation state." },
});

pub const zigar_run_stream = tool(.{
    .description = "Run an allow-listed Zig command and return bounded event records, output tails, and a retained job id.",
    .input_schema = schemaWithHints(&.{ .{ "command", "string", true }, .{ "file", "string", false }, .{ "args", "string", false }, .{ "timeout_ms", "integer", false }, .{ "mode", "string", false } }, &.{ command_hint, mode_hint }),
    .read_only = false,
    .group = .runtime_ux,
    .risk = .{ .executes_project_code = true, .executes_backend = true },
    .plan = .{ .dynamic_command = "Runs one allow-listed Zig command without a shell and returns bounded event evidence." },
});

pub const zigar_run_events = tool(.{
    .description = "Read paginated process-local run events across retained jobs or for one job.",
    .input_schema = schema(&.{ .{ "job_id", "string", false }, .{ "cursor", "string", false }, .{ "limit", "integer", false } }),
    .read_only = true,
    .group = .runtime_ux,
    .plan = .{ .pure_analysis = "Reads bounded process-local event state." },
});

pub const zigar_resource_query = tool(.{
    .description = "Query registered and dynamic zigar resources, including workspace file symbols, imports, and diagnostics.",
    .input_schema = schema(&.{ .{ "uri", "string", true }, .{ "cursor", "string", false }, .{ "limit", "integer", false }, .{ "mode", "string", false } }),
    .read_only = true,
    .group = .runtime_ux,
    .plan = .{ .pure_analysis = "Reads workspace-bound resources and process-local runtime state without mutating files." },
});

pub const zigar_resource_subscribe = tool(.{
    .description = "Create a process-local subscription record for a zigar resource URI.",
    .input_schema = schema(&.{.{ "uri", "string", true }}),
    .read_only = false,
    .group = .runtime_ux,
    .plan = .{ .not_plannable = "Mutates process-local subscription state only." },
});

pub const zigar_resource_unsubscribe = tool(.{
    .description = "Deactivate a process-local zigar resource subscription by subscription id or URI.",
    .input_schema = schema(&.{ .{ "subscription_id", "string", false }, .{ "uri", "string", false } }),
    .read_only = false,
    .group = .runtime_ux,
    .plan = .{ .not_plannable = "Mutates process-local subscription state only." },
});

pub const zigar_roots_sync = tool(.{
    .description = "Preview or apply client workspace roots to process-local zigar runtime state.",
    .input_schema = schema(&.{ .{ "roots", "string", false }, .{ "apply", "boolean", false } }),
    .read_only = false,
    .group = .runtime_ux,
    .risk = .{ .writes_require_apply = true, .preview_by_default = true },
    .plan = .{ .apply_gated_mutation = "Updates process-local workspace root selection only when apply=true." },
});

pub const zigar_workspace_map = tool(.{
    .description = "Return process-local workspace roots, selected root, and static workspace entry points.",
    .input_schema = schema(&.{}),
    .read_only = true,
    .group = .runtime_ux,
    .plan = .{ .pure_analysis = "Reads process-local roots and bounded workspace metadata." },
});

pub const zigar_workspace_select = tool(.{
    .description = "Preview or apply selected workspace root for process-local runtime guidance.",
    .input_schema = schema(&.{ .{ "workspace_id", "string", true }, .{ "apply", "boolean", false } }),
    .read_only = false,
    .group = .runtime_ux,
    .risk = .{ .writes_require_apply = true, .preview_by_default = true },
    .plan = .{ .apply_gated_mutation = "Updates process-local selected workspace only when apply=true." },
});

pub const zigar_agent_guide_v2 = tool(.{
    .description = "Return current agent guidance for using shipped zigar runtime, setup, analysis, and release tools.",
    .input_schema = schema(&.{ .{ "client", "string", false }, .{ "task", "string", false } }),
    .read_only = true,
    .group = .runtime_ux,
    .plan = .{ .pure_analysis = "Returns static shipped-capability guidance." },
});

pub const zigar_client_guide = tool(.{
    .description = "Return client-specific guidance for MCP roots, completions, resources, jobs, and prompts.",
    .input_schema = schema(&.{ .{ "client", "string", false }, .{ "task", "string", false } }),
    .read_only = true,
    .group = .runtime_ux,
    .plan = .{ .pure_analysis = "Returns static shipped-capability client guidance." },
});

pub const zigar_prompt_pack = tool(.{
    .description = "Return shipped zigar workflow prompt text and tool sequences.",
    .input_schema = schema(&.{.{ "workflow", "string", false }}),
    .read_only = true,
    .group = .runtime_ux,
    .plan = .{ .pure_analysis = "Returns static shipped workflow prompt guidance." },
});
