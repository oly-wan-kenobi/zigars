const types = @import("../types.zig");

const schema = types.schema;
const schemaWithHints = types.schemaWithHints;
const tool = types.tool;
const fieldHint = types.fieldHint;

/// Return a compact deterministic Zig project context pack for agent orientation.
pub const zigars_context_pack = tool(.{
    .description = "Return a compact deterministic Zig project context pack for agent orientation.",
    .input_schema = schemaWithHints(&.{ .{ "mode", "string", false }, .{ "token_budget", "integer", false }, .{ "include", "string", false } }, &.{
        fieldHint("mode", .{ .description = "Context-pack depth.", .default_string = "standard", .enum_values = &.{ "tiny", "standard", "deep" } }),
    }),
    .read_only = true,
    .group = .agent_workflows,
    .plan = .{ .pure_analysis = "Agent-orientation snapshot; reads workspace files and manifest metadata without executing tools." },
});
/// Route a Zig development goal to the next deterministic zigars tool calls.
pub const zigars_next_action = tool(.{
    .description = "Route a Zig development goal to the next deterministic zigars tool calls.",
    .input_schema = schema(&.{ .{ "goal", "string", true }, .{ "changed_files", "string", false }, .{ "last_error", "string", false } }),
    .read_only = true,
    .group = .agent_workflows,
    .plan = .{ .pure_analysis = "Goal router; returns deterministic next tool suggestions without executing tools." },
});
/// Return compact client-specific instructions for using zigars efficiently.
pub const zigars_agent_guide = tool(.{
    .description = "Return compact Codex/Claude/Gemini/Hermes/generic instructions for using zigars efficiently.",
    .input_schema = schemaWithHints(&.{ .{ "client", "string", false }, .{ "task", "string", false } }, &.{
        fieldHint("client", .{ .description = "Agent/client profile.", .default_string = "generic", .enum_values = &.{ "codex", "claude", "gemini", "hermes", "generic" } }),
    }),
    .read_only = true,
    .group = .agent_workflows,
    .plan = .{ .pure_analysis = "Client guidance lookup; returns deterministic instructions without executing tools." },
});
/// Run an agent-friendly changed-file validation loop and return structured blockers.
pub const zigars_validate_patch = tool(.{
    .description = "Run an agent-friendly changed-file validation loop and return structured blockers.",
    .input_schema = schemaWithHints(&.{ .{ "mode", "string", false }, .{ "changed_files", "string", false }, .{ "stop_on_failure", "boolean", false }, .{ "timeout_ms", "integer", false } }, &.{
        fieldHint("mode", .{ .description = "Validation depth.", .default_string = "standard", .enum_values = &.{ "quick", "standard", "full" } }),
    }),
    .read_only = true,
    .group = .agent_workflows,
    .risk = .{ .writes_artifacts = true, .executes_project_code = true, .executes_backend = true },
    .plan = .{ .dynamic_command = "Backend-backed workflow whose exact argv depends on runtime arguments, workspace state, or configured helper paths." },
});
/// Fuse compiler/test output, primary failure data, impact hints, and suggested zigars tools.
pub const zigars_failure_fusion = tool(.{
    .description = "Fuse compiler/test output, primary failure data, impact hints, and suggested zigars tools.",
    .input_schema = schemaWithHints(&.{ .{ "text", "string", false }, .{ "command", "string", false }, .{ "file", "string", false }, .{ "args", "string", false }, .{ "timeout_ms", "integer", false }, .{ "summarize", "boolean", false } }, &.{
        fieldHint("command", .{ .description = "Focused Zig command mode.", .enum_values = &.{ "check", "test", "build", "build-test", "fmt-check" } }),
        fieldHint("summarize", .{ .description = "When true and the client supports MCP sampling, request a client-generated summary alongside deterministic evidence.", .default_bool = false }),
    }),
    .read_only = true,
    .group = .agent_workflows,
    .risk = .{ .writes_artifacts = true, .executes_project_code = true, .executes_backend = true },
    .plan = .{ .dynamic_command = "Backend-backed workflow whose exact argv depends on runtime arguments, workspace state, or configured helper paths." },
});
/// Analyze affected imports, tests, public API, and validation commands for files or symbols.
pub const zigars_impact = tool(.{
    .description = "Analyze affected imports, tests, public API, and validation commands for files or symbols.",
    .input_schema = schema(&.{ .{ "files", "string", false }, .{ "symbols", "string", false }, .{ "limit", "integer", false } }),
    .read_only = true,
    .group = .agent_workflows,
    .plan = .{ .pure_analysis = "Static workspace analysis; reads project files and returns deterministic guidance without executing backends." },
});
/// Read or explicitly write a workspace-local deterministic zigars project profile.
pub const zigars_project_profile = tool(.{
    .description = "Read or explicitly write a workspace-local deterministic zigars project profile.",
    .input_schema = schema(&.{ .{ "apply", "boolean", false }, .{ "content", "string", false } }),
    .read_only = false,
    .group = .agent_workflows,
    .risk = .{ .writes_artifacts = true, .writes_require_apply = true, .preview_by_default = true },
    .plan = .{ .apply_gated_mutation = "Preview-first workspace mutation; writes only when apply=true and reports risk metadata before changes." },
});
/// Validate proposed patch/file paths against zigars workspace and generated-path safety rules.
pub const zigars_patch_guard = tool(.{
    .description = "Validate proposed patch/file paths against zigars workspace and generated-path safety rules.",
    .input_schema = schema(&.{ .{ "files", "string", false }, .{ "patch", "string", false } }),
    .read_only = true,
    .group = .agent_workflows,
    .plan = .{ .pure_analysis = "Workspace safety check; validates paths and patch text without applying changes." },
});
