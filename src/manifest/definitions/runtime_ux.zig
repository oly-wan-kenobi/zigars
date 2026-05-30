//! Tool definitions for the `runtime_ux` group: job lifecycle (start/status/
//! result/cancel), streaming runs, resource query/subscribe, workspace root
//! management, and agent/client guidance tools. All writes to process-local
//! state require no apply gate; workspace root mutations require apply=true.
const types = @import("../types.zig");

const schema = types.schema;
const schemaWithHints = types.schemaWithHints;
const tool = types.tool;
const fieldHint = types.fieldHint;

// Shared catalog hints reused across multiple tools to keep field-level
// documentation consistent without duplicating enum values inline.

/// Controls how much result data the tool returns; "compact" reduces token use.
const mode_hint = fieldHint("mode", .{ .description = "Result shape depth.", .default_string = "standard", .enum_values = &.{ "compact", "standard", "deep" } });
/// Allow-listed Zig subcommands that jobs and streaming runs may execute.
const command_hint = fieldHint("command", .{ .description = "Bounded Zig command to run.", .enum_values = &.{ "build", "build-test", "test", "check", "fmt-check" } });
/// Enables MCP completion for zigars resource URIs in supporting clients.
const resource_uri_hint = fieldHint("uri", .{ .description = "Registered or template-backed zigars resource URI.", .completion_source = .resource_uri });
/// Completion hint for the shipped prompt identifiers registered as MCP prompts.
const workflow_hint = fieldHint("workflow", .{ .description = "Shipped zigars workflow prompt identifier.", .enum_values = &.{ "zigars_compile_error_workflow", "zigars_test_workflow", "zigars_refactor_workflow", "zigars_api_change_workflow", "zigars_release_workflow", "zigars_perf_workflow" } });

/// Start a bounded zigars-managed Zig job and retain status, result, and event tails in process-local state.
pub const zigars_job_start = tool(.{
    .description = "Start a bounded zigars-managed Zig job and retain status, result, and event tails in process-local state.",
    .input_schema = schemaWithHints(&.{ .{ "command", "string", true }, .{ "file", "string", false }, .{ "args", "string", false }, .{ "timeout_ms", "integer", false }, .{ "mode", "string", false } }, &.{ command_hint, mode_hint }),
    .read_only = false,
    .group = .runtime_ux,
    .risk = .{ .executes_project_code = true, .executes_backend = true },
    .plan = .{ .dynamic_command = "Runs one allow-listed Zig command without a shell and stores bounded process-local job evidence." },
});

/// Read status and cancellation state for a zigars-managed job.
pub const zigars_job_status = tool(.{
    .description = "Read status and cancellation state for a zigars-managed job.",
    .input_schema = schema(&.{.{ "job_id", "string", true }}),
    .read_only = true,
    .group = .runtime_ux,
    .plan = .{ .pure_analysis = "Reads bounded process-local job state." },
});

/// Read the bounded result, output tails, and paginated events for a zigars-managed job.
pub const zigars_job_result = tool(.{
    .description = "Read the bounded result, output tails, and paginated events for a zigars-managed job.",
    .input_schema = schemaWithHints(&.{ .{ "job_id", "string", true }, .{ "cursor", "string", false }, .{ "limit", "integer", false }, .{ "mode", "string", false } }, &.{mode_hint}),
    .read_only = true,
    .group = .runtime_ux,
    .plan = .{ .pure_analysis = "Reads bounded process-local job result and event state." },
});

/// Request cancellation for a zigars-managed job and record the cancellation state.
pub const zigars_job_cancel = tool(.{
    .description = "Request cancellation for a zigars-managed job and record the cancellation state.",
    .input_schema = schema(&.{ .{ "job_id", "string", true }, .{ "reason", "string", false } }),
    .read_only = false,
    .group = .runtime_ux,
    .plan = .{ .not_plannable = "Mutates process-local cancellation state; currently records cancellation for completed synchronous jobs." },
});

/// Read cancellation status for one job or all retained zigars-managed jobs.
pub const zigars_cancel_status = tool(.{
    .description = "Read cancellation status for one job or all retained zigars-managed jobs.",
    .input_schema = schema(&.{.{ "job_id", "string", false }}),
    .read_only = true,
    .group = .runtime_ux,
    .plan = .{ .pure_analysis = "Reads process-local cancellation state." },
});

/// Run an allow-listed Zig command and return bounded event records, output tails, and a retained job id.
pub const zigars_run_stream = tool(.{
    .description = "Run an allow-listed Zig command and return bounded event records, output tails, and a retained job id.",
    .input_schema = schemaWithHints(&.{ .{ "command", "string", true }, .{ "file", "string", false }, .{ "args", "string", false }, .{ "timeout_ms", "integer", false }, .{ "mode", "string", false } }, &.{ command_hint, mode_hint }),
    .read_only = false,
    .group = .runtime_ux,
    .risk = .{ .executes_project_code = true, .executes_backend = true },
    .plan = .{ .dynamic_command = "Runs one allow-listed Zig command without a shell and returns bounded event evidence." },
});

/// Read paginated process-local run events across retained jobs or for one job.
pub const zigars_run_events = tool(.{
    .description = "Read paginated process-local run events across retained jobs or for one job.",
    .input_schema = schema(&.{ .{ "job_id", "string", false }, .{ "cursor", "string", false }, .{ "limit", "integer", false } }),
    .read_only = true,
    .group = .runtime_ux,
    .plan = .{ .pure_analysis = "Reads bounded process-local event state." },
});

/// Query registered and dynamic zigars resources, including workspace file symbols, imports, and diagnostics.
pub const zigars_resource_query = tool(.{
    .description = "Query registered and dynamic zigars resources, including workspace file symbols, imports, and diagnostics.",
    .input_schema = schemaWithHints(&.{ .{ "uri", "string", true }, .{ "cursor", "string", false }, .{ "limit", "integer", false }, .{ "mode", "string", false } }, &.{ resource_uri_hint, mode_hint }),
    .read_only = true,
    .group = .runtime_ux,
    .plan = .{ .pure_analysis = "Reads workspace-bound resources and process-local runtime state without mutating files." },
});

/// Create a process-local subscription record for a zigars resource URI.
pub const zigars_resource_subscribe = tool(.{
    .description = "Create a process-local subscription record for a zigars resource URI.",
    .input_schema = schemaWithHints(&.{.{ "uri", "string", true }}, &.{resource_uri_hint}),
    .read_only = false,
    .group = .runtime_ux,
    .plan = .{ .not_plannable = "Mutates process-local subscription state only." },
});

/// Deactivate a process-local zigars resource subscription by subscription id or URI.
pub const zigars_resource_unsubscribe = tool(.{
    .description = "Deactivate a process-local zigars resource subscription by subscription id or URI.",
    .input_schema = schemaWithHints(&.{ .{ "subscription_id", "string", false }, .{ "uri", "string", false } }, &.{resource_uri_hint}),
    .read_only = false,
    .group = .runtime_ux,
    .plan = .{ .not_plannable = "Mutates process-local subscription state only." },
});

/// Preview or apply client workspace roots to process-local zigars runtime state.
pub const zigars_roots_sync = tool(.{
    .description = "Preview or apply client workspace roots to process-local zigars runtime state.",
    .input_schema = schema(&.{ .{ "roots", "string", false }, .{ "apply", "boolean", false } }),
    .read_only = false,
    .group = .runtime_ux,
    .risk = .{ .writes_require_apply = true, .preview_by_default = true },
    .plan = .{ .apply_gated_mutation = "Updates process-local workspace root selection only when apply=true." },
});

/// Return process-local workspace roots, selected root, and static workspace entry points.
pub const zigars_workspace_map = tool(.{
    .description = "Return process-local workspace roots, selected root, and static workspace entry points.",
    .input_schema = schema(&.{}),
    .read_only = true,
    .group = .runtime_ux,
    .plan = .{ .pure_analysis = "Reads process-local roots and bounded workspace metadata." },
});

/// Preview or apply selected workspace root for process-local runtime guidance.
pub const zigars_workspace_select = tool(.{
    .description = "Preview or apply selected workspace root for process-local runtime guidance.",
    .input_schema = schema(&.{ .{ "workspace_id", "string", true }, .{ "apply", "boolean", false } }),
    .read_only = false,
    .group = .runtime_ux,
    .risk = .{ .writes_require_apply = true, .preview_by_default = true },
    .plan = .{ .apply_gated_mutation = "Updates process-local selected workspace only when apply=true." },
});

/// Return current agent guidance for using shipped zigars runtime, setup, analysis, and release tools.
pub const zigars_agent_guide_v2 = tool(.{
    .description = "Return current agent guidance for using shipped zigars runtime, setup, analysis, and release tools.",
    .input_schema = schema(&.{ .{ "client", "string", false }, .{ "task", "string", false } }),
    .read_only = true,
    .group = .runtime_ux,
    .plan = .{ .pure_analysis = "Returns static shipped-capability guidance." },
});

/// Return client-specific guidance for MCP roots, completions, resources, jobs, and prompts.
pub const zigars_client_guide = tool(.{
    .description = "Return client-specific guidance for MCP roots, completions, resources, jobs, and prompts.",
    .input_schema = schema(&.{ .{ "client", "string", false }, .{ "task", "string", false } }),
    .read_only = true,
    .group = .runtime_ux,
    .plan = .{ .pure_analysis = "Returns static shipped-capability client guidance." },
});

/// Return shipped zigars workflow prompt text and tool sequences.
pub const zigars_prompt_pack = tool(.{
    .description = "Return shipped zigars workflow prompt text and tool sequences.",
    .input_schema = schemaWithHints(&.{.{ "workflow", "string", false }}, &.{workflow_hint}),
    .read_only = true,
    .group = .runtime_ux,
    .plan = .{ .pure_analysis = "Returns static shipped workflow prompt guidance." },
});
