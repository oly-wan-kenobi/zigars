//! Tool definitions for the `formatting_and_edits` group: zig fmt, fmt check,
//! content-patch preview, and ZLS-backed rename/code-action tools. Source-mutating
//! tools require apply=true. ZLS-backed tools carry mutates_lsp_state risk because
//! they synchronize a document into the ZLS session before making the request.
const types = @import("../types.zig");

const schema = types.schema;
const schemaWithHints = types.schemaWithHints;
const tool = types.tool;
const fieldHint = types.fieldHint;

/// Format a Zig file or caller-supplied buffer; writes source only when apply=true.
pub const zig_format = tool(.{
    .description = "Format a Zig file or supplied buffer. Returns preview by default; writes the source file only with apply=true.",
    .input_schema = schema(&.{ .{ "file", "string", true }, .{ "apply", "boolean", false }, .{ "content", "string", false }, .{ "timeout_ms", "integer", false } }),
    .read_only = false,
    .group = .formatting_and_edits,
    .risk = .{ .writes_source = true, .writes_artifacts = true, .writes_require_apply = true, .preview_by_default = true, .executes_backend = true },
    .plan = .{ .apply_gated_mutation = "Preview-first workspace mutation; writes only when apply=true and reports risk metadata before changes." },
});
/// Run `zig fmt --check` on a workspace file or directory.
pub const zig_format_check = tool(.{
    .description = "Run `zig fmt --check` on a workspace file or directory.",
    .input_schema = schema(&.{ .{ "path", "string", true }, .{ "timeout_ms", "integer", false } }),
    .read_only = true,
    .group = .formatting_and_edits,
    .risk = .{ .executes_backend = true },
    .plan = .{ .exact_command = .{ .required_path = &.{ "fmt", "--check" } } },
});
/// Preview a replacement-content patch with hashes and unified diff; writes only with apply=true.
pub const zig_patch_preview = tool(.{
    .description = "Preview a replacement-content patch with hashes and unified diff; writes only with apply=true.",
    .input_schema = schema(&.{ .{ "file", "string", true }, .{ "content", "string", true }, .{ "apply", "boolean", false } }),
    .read_only = false,
    .group = .formatting_and_edits,
    .risk = .{ .writes_source = true, .writes_require_apply = true, .preview_by_default = true },
    .plan = .{ .apply_gated_mutation = "Preview-first workspace mutation; writes only when apply=true and reports risk metadata before changes." },
});
/// Preview a ZLS workspace edit for a symbol rename.
pub const zig_rename = tool(.{
    .description = "Preview the ZLS workspace edit for a symbol rename. Does not write source files.",
    .input_schema = schema(&.{ .{ "file", "string", true }, .{ "content", "string", false }, .{ "line", "integer", true }, .{ "character", "integer", true }, .{ "new_name", "string", true } }),
    .read_only = true,
    .group = .formatting_and_edits,
    .risk = .{ .mutates_lsp_state = true, .executes_backend = true },
    .plan = .{ .zls_request = .{ .method = "textDocument/rename", .requires_document_sync = true, .required_capability = "renameProvider" } },
});
/// Get ZLS code actions for a range.
pub const zig_code_actions = tool(.{
    .description = "Get ZLS code actions for a range.",
    .input_schema = schema(&.{ .{ "file", "string", true }, .{ "content", "string", false }, .{ "start_line", "integer", true }, .{ "start_char", "integer", true }, .{ "end_line", "integer", true }, .{ "end_char", "integer", true } }),
    .read_only = true,
    .group = .formatting_and_edits,
    .risk = .{ .mutates_lsp_state = true, .executes_backend = true },
    .plan = .{ .zls_request = .{ .method = "textDocument/codeAction", .requires_document_sync = true, .required_capability = "codeActionProvider" } },
});
/// Preview one ZLS code action by index; despite "apply" in the name, does not write source files.
pub const zig_code_action_apply = tool(.{
    .description = "Preview one ZLS code action by index. Does not write source files.",
    .input_schema = schema(&.{ .{ "file", "string", true }, .{ "content", "string", false }, .{ "start_line", "integer", true }, .{ "start_char", "integer", true }, .{ "end_line", "integer", true }, .{ "end_char", "integer", true }, .{ "action_index", "integer", true } }),
    .read_only = true,
    .group = .formatting_and_edits,
    .risk = .{ .mutates_lsp_state = true, .executes_backend = true },
    .plan = .{ .zls_request = .{ .method = "textDocument/codeAction", .requires_document_sync = true, .required_capability = "codeActionProvider" } },
});
