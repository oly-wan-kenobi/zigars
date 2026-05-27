const types = @import("../types.zig");

const schema = types.schema;
const schemaWithHints = types.schemaWithHints;
const tool = types.tool;
const fieldHint = types.fieldHint;

/// Validation depth.
const validation_plan = "Risk-aware validation planning that inspects supplied diff/file facts and returns explicit runnable and skipped phases.";
const validation_run = "Executes allow-listed Zig validation command phases without a shell and optionally writes history only when apply=true.";
const validation_parse = "Parses captured or executed Zig build/test output into structured event, failure, and timing evidence.";
const workflow_state = "Reads or packages workspace-local workflow state without claiming unrun validation passed.";
const project_memory = "Preview-first workspace-local project memory; writes only when apply=true.";

/// Validation depth.
const mode_hint = fieldHint("mode", .{ .description = "Validation depth.", .default_string = "standard", .enum_values = &.{ "quick", "standard", "full" } });
/// Bounded Zig command to run when text is omitted.
const validation_command_hint = fieldHint("command", .{ .description = "Bounded Zig command to run when text is omitted.", .enum_values = &.{ "build", "build-test", "test", "check", "fmt-check" } });

/// Use the semantic index to map changed files, symbols, or diff text to affected importers, declarations, tests, public API, and recommended checks.
pub const zig_impact_semantic = tool(.{
    .description = "Use the semantic index to map changed files, symbols, or diff text to affected importers, declarations, tests, public API, and recommended checks.",
    .input_schema = schema(&.{ .{ "files", "string", false }, .{ "symbols", "string", false }, .{ "diff", "string", false }, .{ "limit", "integer", false }, .{ "refresh", "boolean", false } }),
    .read_only = true,
    .group = .static_analysis,
    .plan = .{ .pure_analysis = "Reads parser-backed semantic index evidence and returns advisory impact/test guidance without executing commands." },
    .static_analysis_tier = .parser_backed,
});

/// Select focused Zig test commands from semantic-index impact evidence, with explicit fallback and skipped-validation notes.
pub const zig_test_select_semantic = tool(.{
    .description = "Select focused Zig test commands from semantic-index impact evidence, with explicit fallback and skipped-validation notes.",
    .input_schema = schema(&.{ .{ "files", "string", false }, .{ "symbols", "string", false }, .{ "diff", "string", false }, .{ "limit", "integer", false }, .{ "refresh", "boolean", false } }),
    .read_only = true,
    .group = .static_analysis,
    .plan = .{ .pure_analysis = "Reads parser-backed semantic index evidence and recommends commands; it does not run selected tests." },
    .static_analysis_tier = .parser_backed,
});

/// Plan risk-aware validation phases from changed files, diff text, goal, mode, and semantic impact needs without mutating the environment.
pub const zigars_validation_plan = tool(.{
    .description = "Plan risk-aware validation phases from changed files, diff text, goal, mode, and semantic impact needs without mutating the environment.",
    .input_schema = schemaWithHints(&.{ .{ "changed_files", "string", false }, .{ "diff", "string", false }, .{ "goal", "string", false }, .{ "mode", "string", false }, .{ "include_semantic", "boolean", false } }, &.{mode_hint}),
    .read_only = true,
    .group = .agent_workflows,
    .plan = .{ .pure_analysis = validation_plan },
});

/// Execute a validation plan's allow-listed Zig command phases and return phase results, events, skipped reasons, history preview, and next action.
pub const zigars_validation_run = tool(.{
    .description = "Execute a validation plan's allow-listed Zig command phases and return phase results, events, skipped reasons, history preview, and next action.",
    .input_schema = schemaWithHints(&.{ .{ "changed_files", "string", false }, .{ "diff", "string", false }, .{ "goal", "string", false }, .{ "mode", "string", false }, .{ "include_semantic", "boolean", false }, .{ "stop_on_failure", "boolean", false }, .{ "apply", "boolean", false }, .{ "output", "string", false }, .{ "timeout_ms", "integer", false } }, &.{mode_hint}),
    .read_only = false,
    .group = .agent_workflows,
    .risk = .{ .writes_artifacts = true, .writes_require_apply = true, .preview_by_default = true, .executes_project_code = true, .executes_backend = true },
    .plan = .{ .dynamic_command = validation_run },
});

/// Parse captured Zig build output or run a bounded Zig build command and return structured build/test/diagnostic event records.
pub const zig_build_events = tool(.{
    .description = "Parse captured Zig build output or run a bounded Zig build command and return structured build/test/diagnostic event records.",
    .input_schema = schemaWithHints(&.{ .{ "text", "string", false }, .{ "command", "string", false }, .{ "file", "string", false }, .{ "args", "string", false }, .{ "timeout_ms", "integer", false } }, &.{validation_command_hint}),
    .read_only = false,
    .group = .agent_workflows,
    .risk = .{ .executes_project_code = true, .executes_backend = true },
    .plan = .{ .dynamic_command = validation_parse },
});

/// Parse captured Zig test output or run a bounded Zig test command and return structured test, failure, diagnostic, and timing records.
pub const zig_test_events = tool(.{
    .description = "Parse captured Zig test output or run a bounded Zig test command and return structured test, failure, diagnostic, and timing records.",
    .input_schema = schemaWithHints(&.{ .{ "text", "string", false }, .{ "command", "string", false }, .{ "file", "string", false }, .{ "filter", "string", false }, .{ "args", "string", false }, .{ "timeout_ms", "integer", false } }, &.{validation_command_hint}),
    .read_only = false,
    .group = .agent_workflows,
    .risk = .{ .executes_project_code = true, .executes_backend = true },
    .plan = .{ .dynamic_command = validation_parse },
});

/// Extract best-effort test timing records from captured Zig test output.
pub const zig_test_timing = tool(.{
    .description = "Extract best-effort test timing records from captured Zig test output.",
    .input_schema = schema(&.{.{ "text", "string", true }}),
    .read_only = true,
    .group = .agent_workflows,
    .plan = .{ .pure_analysis = validation_parse },
});

/// Read validation history records and summarize last run, last good run, recurring failures, slow phases, and history limitations.
pub const zigars_validation_history = tool(.{
    .description = "Read validation history records and summarize last run, last good run, recurring failures, slow phases, and history limitations.",
    .input_schema = schema(&.{ .{ "history", "string", false }, .{ "path", "string", false }, .{ "limit", "integer", false } }),
    .read_only = true,
    .group = .agent_workflows,
    .plan = .{ .pure_analysis = workflow_state },
});

/// Summarize recurring test/failure fingerprints from retained validation records with explicit confidence limits.
pub const zig_test_flake_history = tool(.{
    .description = "Summarize recurring test/failure fingerprints from retained validation records with explicit confidence limits.",
    .input_schema = schema(&.{ .{ "history", "string", false }, .{ "path", "string", false }, .{ "limit", "integer", false } }),
    .read_only = true,
    .group = .agent_workflows,
    .plan = .{ .pure_analysis = workflow_state },
});

/// Group recurring validation failures from retained history records for agent triage.
pub const zig_failure_history = tool(.{
    .description = "Group recurring validation failures from retained history records for agent triage.",
    .input_schema = schema(&.{ .{ "history", "string", false }, .{ "path", "string", false }, .{ "limit", "integer", false } }),
    .read_only = true,
    .group = .agent_workflows,
    .plan = .{ .pure_analysis = workflow_state },
});

/// Capture current goal, changed files, validation status, profile state, workspace metadata, and recommended next action for handoff.
pub const zigars_session_snapshot = tool(.{
    .description = "Capture current goal, changed files, validation status, profile state, workspace metadata, and recommended next action for handoff.",
    .input_schema = schema(&.{ .{ "goal", "string", false }, .{ "changed_files", "string", false }, .{ "diff", "string", false }, .{ "validation", "string", false }, .{ "last_error", "string", false } }),
    .read_only = true,
    .group = .agent_workflows,
    .plan = .{ .pure_analysis = workflow_state },
});

/// Package a portable handoff snapshot with recommended next zigars workflow steps and limitations.
pub const zigars_handoff_pack = tool(.{
    .description = "Package a portable handoff snapshot with recommended next zigars workflow steps and limitations.",
    .input_schema = schema(&.{ .{ "goal", "string", false }, .{ "changed_files", "string", false }, .{ "diff", "string", false }, .{ "validation", "string", false }, .{ "last_error", "string", false } }),
    .read_only = true,
    .group = .agent_workflows,
    .plan = .{ .pure_analysis = workflow_state },
});

/// Preview or append a workspace-local structured decision record for project memory under an explicit apply gate.
pub const zigars_decision_record = tool(.{
    .description = "Preview or append a workspace-local structured decision record for project memory under an explicit apply gate.",
    .input_schema = schema(&.{ .{ "title", "string", true }, .{ "decision", "string", true }, .{ "rationale", "string", false }, .{ "category", "string", false }, .{ "path", "string", false }, .{ "apply", "boolean", false } }),
    .read_only = false,
    .group = .agent_workflows,
    .risk = .{ .writes_artifacts = true, .writes_require_apply = true, .preview_by_default = true },
    .plan = .{ .workspace_artifact = project_memory },
});

/// Read workspace-local structured project notes with optional query/category filtering.
pub const zigars_project_notes = tool(.{
    .description = "Read workspace-local structured project notes with optional query/category filtering.",
    .input_schema = schema(&.{ .{ "content", "string", false }, .{ "path", "string", false }, .{ "query", "string", false }, .{ "category", "string", false }, .{ "limit", "integer", false } }),
    .read_only = true,
    .group = .agent_workflows,
    .plan = .{ .pure_analysis = workflow_state },
});

/// Read project memory plus built-in zigars project policies such as generated-path, validation, and apply-gate rules.
pub const zigars_project_memory = tool(.{
    .description = "Read project memory plus built-in zigars project policies such as generated-path, validation, and apply-gate rules.",
    .input_schema = schema(&.{ .{ "content", "string", false }, .{ "path", "string", false }, .{ "query", "string", false }, .{ "category", "string", false }, .{ "limit", "integer", false } }),
    .read_only = true,
    .group = .agent_workflows,
    .plan = .{ .pure_analysis = workflow_state },
});

/// Match a goal, error, or diff to zigars tools using manifest capabilities, confidence, risk, and alternatives.
pub const zigars_capability_match = tool(.{
    .description = "Match a goal, error, or diff to zigars tools using manifest capabilities, confidence, risk, and alternatives.",
    .input_schema = schema(&.{ .{ "goal", "string", false }, .{ "error", "string", false }, .{ "diff", "string", false }, .{ "limit", "integer", false } }),
    .read_only = true,
    .group = .agent_workflows,
    .plan = .{ .pure_analysis = "Reads the typed zigars manifest and returns ranked tool matches without executing tools." },
});

/// Plan a deterministic sequence of zigars tools for a goal, error, diff, or changed files, with stop conditions and execution-risk markers.
pub const zigars_tool_sequence_plan = tool(.{
    .description = "Plan a deterministic sequence of zigars tools for a goal, error, diff, or changed files, with stop conditions and execution-risk markers.",
    .input_schema = schema(&.{ .{ "goal", "string", false }, .{ "error", "string", false }, .{ "diff", "string", false }, .{ "changed_files", "string", false } }),
    .read_only = true,
    .group = .agent_workflows,
    .plan = .{ .pure_analysis = "Reads goal text and manifest workflow policy to recommend a tool sequence without executing tools." },
});
