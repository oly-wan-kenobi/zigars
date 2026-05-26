const types = @import("../types.zig");

const schema = types.schema;
const schemaWithHints = types.schemaWithHints;
const tool = types.tool;
const fieldHint = types.fieldHint;

const patch_session = "Preview-first transactional edit session; source writes require apply=true and matching preimage evidence.";
const generated_policy = "Workspace path policy for generated, cache, derived, and vendored files.";
const refactor_preview = "Preview-first refactor mutation; writes only when apply=true and returns per-file diffs and identities.";

/// Write changes only when true.
const apply_hint = fieldHint("apply", .{ .description = "Write changes only when true.", .default_bool = false });
/// Validation depth.
const mode_hint = fieldHint("mode", .{ .description = "Validation depth.", .default_string = "standard", .enum_values = &.{ "quick", "standard", "full" } });

/// Create a patch-session identity with current file preimages, generated-file policy, and next action guidance.
pub const zigar_patch_session_create = tool(.{
    .description = "Create a patch-session identity with current file preimages, generated-file policy, and next action guidance.",
    .input_schema = schema(&.{ .{ "goal", "string", false }, .{ "files", "string", false }, .{ "patch", "string", false }, .{ "edits", "string", false } }),
    .read_only = true,
    .group = .agent_workflows,
    .plan = .{ .pure_analysis = "Captures workspace file identity and edit policy without writing source or running validation." },
});

/// Preview a multi-file replacement patch session with preimage hashes, generated-file policy, and unified diffs.
pub const zigar_patch_session_preview = tool(.{
    .description = "Preview a multi-file replacement patch session with preimage hashes, generated-file policy, and unified diffs.",
    .input_schema = schema(&.{ .{ "goal", "string", false }, .{ "session_id", "string", false }, .{ "edits", "string", true } }),
    .read_only = true,
    .group = .formatting_and_edits,
    .plan = .{ .pure_analysis = patch_session },
});

/// Apply a previewed multi-file patch session only when expected preimages still match.
pub const zigar_patch_session_apply = tool(.{
    .description = "Apply a previewed multi-file patch session only when expected preimages still match.",
    .input_schema = schemaWithHints(&.{ .{ "goal", "string", false }, .{ "session_id", "string", false }, .{ "edits", "string", true }, .{ "expected_preimages", "string", false }, .{ "apply", "boolean", false } }, &.{apply_hint}),
    .read_only = false,
    .group = .formatting_and_edits,
    .risk = .{ .writes_source = true, .writes_artifacts = true, .writes_require_apply = true, .preview_by_default = true },
    .plan = .{ .apply_gated_mutation = patch_session },
});

/// Run validation for a patch session or supplied changed files and return explicit skipped/failed phases.
pub const zigar_patch_session_validate = tool(.{
    .description = "Run validation for a patch session or supplied changed files and return explicit skipped/failed phases.",
    .input_schema = schemaWithHints(&.{ .{ "session_id", "string", false }, .{ "changed_files", "string", false }, .{ "diff", "string", false }, .{ "edits", "string", false }, .{ "goal", "string", false }, .{ "mode", "string", false }, .{ "include_semantic", "boolean", false }, .{ "stop_on_failure", "boolean", false }, .{ "apply", "boolean", false }, .{ "output", "string", false }, .{ "timeout_ms", "integer", false } }, &.{ mode_hint, apply_hint }),
    .read_only = false,
    .group = .agent_workflows,
    .risk = .{ .writes_artifacts = true, .writes_require_apply = true, .preview_by_default = true, .executes_project_code = true, .executes_backend = true },
    .plan = .{ .dynamic_command = "Delegates to the validation workflow with session-derived changed files when edits are supplied." },
});

/// Preview or revert only files from a recorded zigar patch session whose current hashes still match the session output.
pub const zigar_patch_session_revert = tool(.{
    .description = "Preview or revert only files from a recorded zigar patch session whose current hashes still match the session output.",
    .input_schema = schemaWithHints(&.{ .{ "session_id", "string", true }, .{ "history", "string", false }, .{ "history_path", "string", false }, .{ "apply", "boolean", false } }, &.{apply_hint}),
    .read_only = false,
    .group = .formatting_and_edits,
    .risk = .{ .writes_source = true, .writes_require_apply = true, .preview_by_default = true },
    .plan = .{ .apply_gated_mutation = "Rollback is limited to recorded session files and refuses current-hash mismatches." },
});

/// Classify a workspace path as source, generated, cache, artifact, or vendor and explain the evidence.
pub const zig_generated_file_trace = tool(.{
    .description = "Classify a workspace path as source, generated, cache, artifact, or vendor and explain the evidence.",
    .input_schema = schema(&.{.{ "path", "string", true }}),
    .read_only = true,
    .group = .trust_safety,
    .plan = .{ .pure_analysis = generated_policy },
});

/// Check file or patch paths against generated/vendor edit policy before broad edits.
pub const zigar_edit_policy_check = tool(.{
    .description = "Check file or patch paths against generated/vendor edit policy before broad edits.",
    .input_schema = schema(&.{ .{ "files", "string", false }, .{ "patch", "string", false } }),
    .read_only = true,
    .group = .trust_safety,
    .plan = .{ .pure_analysis = generated_policy },
});

/// Route a generated, cache, artifact, or vendored path to likely source files and regeneration commands.
pub const zigar_generated_route = tool(.{
    .description = "Route a generated, cache, artifact, or vendored path to likely source files and regeneration commands.",
    .input_schema = schema(&.{ .{ "path", "string", true }, .{ "goal", "string", false } }),
    .read_only = true,
    .group = .trust_safety,
    .plan = .{ .pure_analysis = generated_policy },
});

/// Preview or apply a heuristic top-level declaration move between Zig files with per-file diffs.
pub const zig_move_decl = tool(.{
    .description = "Preview or apply a heuristic top-level declaration move between Zig files with per-file diffs.",
    .input_schema = schemaWithHints(&.{ .{ "source_file", "string", true }, .{ "target_file", "string", true }, .{ "name", "string", true }, .{ "apply", "boolean", false } }, &.{apply_hint}),
    .read_only = false,
    .group = .formatting_and_edits,
    .risk = .{ .writes_source = true, .writes_require_apply = true, .preview_by_default = true },
    .plan = .{ .apply_gated_mutation = refactor_preview },
});

/// Preview or apply a text-range declaration extraction from one Zig file to another.
pub const zig_extract_decl = tool(.{
    .description = "Preview or apply a text-range declaration extraction from one Zig file to another.",
    .input_schema = schemaWithHints(&.{ .{ "file", "string", true }, .{ "target_file", "string", true }, .{ "start_line", "integer", true }, .{ "end_line", "integer", true }, .{ "apply", "boolean", false } }, &.{apply_hint}),
    .read_only = false,
    .group = .formatting_and_edits,
    .risk = .{ .writes_source = true, .writes_require_apply = true, .preview_by_default = true },
    .plan = .{ .apply_gated_mutation = refactor_preview },
});

/// Preview or apply exact @import path replacements across one or more Zig files.
pub const zig_update_imports = tool(.{
    .description = "Preview or apply exact @import path replacements across one or more Zig files.",
    .input_schema = schemaWithHints(&.{ .{ "file", "string", false }, .{ "files", "string", false }, .{ "old_import", "string", true }, .{ "new_import", "string", true }, .{ "apply", "boolean", false } }, &.{apply_hint}),
    .read_only = false,
    .group = .formatting_and_edits,
    .risk = .{ .writes_source = true, .writes_require_apply = true, .preview_by_default = true },
    .plan = .{ .apply_gated_mutation = refactor_preview },
});

/// Preview or apply sorting and deduplication for top-level Zig @import declarations.
pub const zig_organize_imports = tool(.{
    .description = "Preview or apply sorting and deduplication for top-level Zig @import declarations.",
    .input_schema = schemaWithHints(&.{ .{ "file", "string", true }, .{ "apply", "boolean", false } }, &.{apply_hint}),
    .read_only = false,
    .group = .formatting_and_edits,
    .risk = .{ .writes_source = true, .writes_require_apply = true, .preview_by_default = true },
    .plan = .{ .apply_gated_mutation = refactor_preview },
});

/// Inspect batch ZLS code-action support and return structured unavailable or unsupported state when transaction-safe batching is not available.
pub const zig_code_action_batch = tool(.{
    .description = "Inspect batch ZLS code-action support and return structured unavailable or unsupported state when transaction-safe batching is not available.",
    .input_schema = schemaWithHints(&.{ .{ "file", "string", true }, .{ "content", "string", false }, .{ "start_line", "integer", true }, .{ "start_char", "integer", true }, .{ "end_line", "integer", true }, .{ "end_char", "integer", true }, .{ "action_indices", "string", true }, .{ "apply", "boolean", false } }, &.{apply_hint}),
    .read_only = false,
    .group = .formatting_and_edits,
    .risk = .{ .writes_source = true, .writes_require_apply = true, .preview_by_default = true, .mutates_lsp_state = true, .executes_backend = true },
    .plan = .{ .apply_gated_mutation = "ZLS-backed code-action batching; returns unavailable or unsupported-state results instead of guessing." },
});
