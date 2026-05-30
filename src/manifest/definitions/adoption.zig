//! Tool definitions for the `public_rollout` group: adoption evidence packs,
//! client configuration generation, smoke planning, and conformance reporting.
//! Source-mutating tools (config generate, conformance report) require apply=true
//! and write only workspace-bound output paths.
const types = @import("../types.zig");

const fieldHint = types.fieldHint;
const schemaWithHints = types.schemaWithHints;
const tool = types.tool;
const group = types.ToolGroup.public_rollout;

/// Risk profile shared by tools that write provenance-tracked artifacts.
/// preview_by_default keeps agents in read-only mode until apply=true is set.
const artifact_risk = types.ToolRisk{ .writes_artifacts = true, .writes_require_apply = true, .preview_by_default = true };

/// Input schema for zigars_adoption_pack: all fields are optional filters that
/// narrow which client, transport, backend, and pack depth the evidence targets.
const adoption_schema = schemaWithHints(&.{
    .{ "client", "string", false },
    .{ "transport", "string", false },
    .{ "backend", "string", false },
    .{ "mode", "string", false },
}, &.{
    fieldHint("client", .{ .description = "Client identity.", .default_string = "generic", .enum_values = &.{ "generic", "codex", "claude", "gemini", "hermes" } }),
    fieldHint("transport", .{ .description = "Transport identity.", .default_string = "stdio", .enum_values = &.{ "stdio", "http" } }),
    fieldHint("backend", .{ .description = "Backend scope.", .default_string = "all", .enum_values = &.{ "all", "zig", "zls", "zlint", "zwanzig", "zflame", "diff-folded", "diff_folded" } }),
    fieldHint("mode", .{ .description = "Pack depth.", .default_string = "standard", .enum_values = &.{ "compact", "standard", "deep" } }),
});

/// Input schema for zigars_client_config_generate: client/transport select the
/// target profile; kind chooses the config format; output and apply gate the
/// write path; server_path is embedded verbatim into the generated config.
const config_schema = schemaWithHints(&.{
    .{ "client", "string", false },
    .{ "transport", "string", false },
    .{ "kind", "string", false },
    .{ "output", "string", false },
    .{ "server_path", "string", false },
    .{ "apply", "boolean", false },
}, &.{
    fieldHint("client", .{ .description = "Client identity.", .default_string = "generic", .enum_values = &.{ "generic", "codex", "claude", "gemini", "hermes" } }),
    fieldHint("transport", .{ .description = "Transport identity.", .default_string = "stdio", .enum_values = &.{ "stdio", "http" } }),
    fieldHint("kind", .{ .description = "Generated config kind.", .default_string = "mcp-json", .enum_values = &.{ "mcp-json", "codex-toml", "claude-json", "gemini-json", "markdown" } }),
    fieldHint("output", .{ .description = "Workspace-relative generated config path.", .path_kind = "output_path" }),
    fieldHint("server_path", .{ .description = "zigars server executable path to place in the generated client config." }),
    fieldHint("apply", .{ .description = "Write and register the generated config artifact.", .default_bool = false }),
});

/// Input schema for zigars_smoke_plan: identifies the target client, transport,
/// backend, and platform. timeout_ms is the caller's budget hint, not a
/// server-side limit — the tool builds a plan rather than executing checks.
const smoke_schema = schemaWithHints(&.{
    .{ "client", "string", false },
    .{ "transport", "string", false },
    .{ "backend", "string", false },
    .{ "platform", "string", false },
    .{ "timeout_ms", "integer", false },
}, &.{
    fieldHint("client", .{ .description = "Client identity.", .default_string = "generic", .enum_values = &.{ "generic", "codex", "claude", "gemini", "hermes" } }),
    fieldHint("transport", .{ .description = "Transport identity.", .default_string = "stdio", .enum_values = &.{ "stdio", "http" } }),
    fieldHint("backend", .{ .description = "Backend scope.", .default_string = "all", .enum_values = &.{ "all", "zig", "zls", "zlint", "zwanzig", "zflame", "diff-folded", "diff_folded" } }),
    fieldHint("platform", .{ .description = "Smoke target platform such as native, linux, wasm, or cross-target.", .default_string = "native" }),
    fieldHint("timeout_ms", .{ .description = "Caller smoke timeout budget in milliseconds.", .minimum = 1 }),
});

/// Input schema for zigars_conformance_report: evidence is supplied as a file
/// path or inline JSON; backend scopes the claim filter; output and apply gate
/// the artifact write. Exactly one of input/content should be provided.
const report_schema = schemaWithHints(&.{
    .{ "input", "string", false },
    .{ "content", "string", false },
    .{ "backend", "string", false },
    .{ "output", "string", false },
    .{ "apply", "boolean", false },
}, &.{
    fieldHint("input", .{ .description = "Workspace-relative conformance evidence JSON path.", .path_kind = "input_file" }),
    fieldHint("content", .{ .description = "Inline conformance evidence JSON." }),
    fieldHint("backend", .{ .description = "Backend scope.", .default_string = "all", .enum_values = &.{ "all", "zig", "zls", "zlint", "zwanzig", "zflame", "diff-folded", "diff_folded" } }),
    fieldHint("output", .{ .description = "Workspace-relative report artifact path.", .path_kind = "output_path" }),
    fieldHint("apply", .{ .description = "Write and register the generated conformance report artifact.", .default_bool = false }),
});

/// Build a read-only adoption evidence pack for configuring clients and validating zigars in a workspace.
pub const zigars_adoption_pack = tool(.{ .description = "Build a read-only adoption evidence pack for configuring clients and validating zigars in a workspace.", .input_schema = adoption_schema, .group = group, .plan = .{ .pure_analysis = "Packages existing workspace, catalog, backend, smoke, and public-claim evidence without probing or mutating setup." } });
/// Preview or write a provenance-tracked MCP client configuration for zigars.
pub const zigars_client_config_generate = tool(.{ .description = "Preview or write a provenance-tracked MCP client configuration for zigars.", .input_schema = config_schema, .read_only = false, .group = group, .risk = artifact_risk, .plan = .{ .apply_gated_mutation = "Writes generated client config artifacts only with apply=true and workspace-bound output paths." } });
/// Return a client, transport, platform, and backend-aware smoke plan for zigars adoption.
pub const zigars_smoke_plan = tool(.{ .description = "Return a client, transport, platform, and backend-aware smoke plan for zigars adoption.", .input_schema = smoke_schema, .group = group, .plan = .{ .pure_analysis = "Builds a smoke scenario plan from static catalog and workspace configuration without running checks." } });
/// Ingest zigars conformance evidence and produce a conservative public-claim report.
pub const zigars_conformance_report = tool(.{ .description = "Ingest zigars conformance evidence and produce a conservative public-claim report.", .input_schema = report_schema, .read_only = false, .group = group, .risk = artifact_risk, .plan = .{ .apply_gated_mutation = "Reads supplied conformance evidence and writes a report artifact only with apply=true." } });
