const types = @import("../types.zig");

const schema = types.schema;
const schemaWithHints = types.schemaWithHints;
const tool = types.tool;
const fieldHint = types.fieldHint;

pub const zig_format = tool(.{
    .description = "Format a Zig file. Returns preview by default; writes only with apply=true.",
    .input_schema = schema(&.{ .{ "file", "string", true }, .{ "apply", "boolean", false }, .{ "content", "string", false } }),
    .read_only = false,
    .group = .formatting_and_edits,
    .risk = .{ .writes_source = true, .writes_artifacts = true, .writes_require_apply = true, .preview_by_default = true, .mutates_lsp_state = true, .executes_backend = true },
    .plan = .{ .apply_gated_mutation = "Preview-first workspace mutation; writes only when apply=true and reports risk metadata before changes." },
});
pub const zig_format_check = tool(.{
    .description = "Run `zig fmt --check` on a workspace file or directory.",
    .input_schema = schema(&.{ .{ "path", "string", true }, .{ "timeout_ms", "integer", false } }),
    .read_only = true,
    .group = .formatting_and_edits,
    .risk = .{ .executes_backend = true },
    .plan = .{ .exact_command = .{ .required_path = &.{ "fmt", "--check" } } },
});
pub const zig_patch_preview = tool(.{
    .description = "Preview a replacement-content patch with hashes and unified diff; writes only with apply=true.",
    .input_schema = schema(&.{ .{ "file", "string", true }, .{ "content", "string", true }, .{ "apply", "boolean", false } }),
    .read_only = false,
    .group = .formatting_and_edits,
    .risk = .{ .writes_source = true, .writes_require_apply = true, .preview_by_default = true },
    .plan = .{ .apply_gated_mutation = "Preview-first workspace mutation; writes only when apply=true and reports risk metadata before changes." },
});
pub const zig_rename = tool(.{
    .description = "Request a ZLS workspace edit for a symbol rename. Returns preview by default; writes only with apply=true.",
    .input_schema = schema(&.{ .{ "file", "string", true }, .{ "content", "string", false }, .{ "line", "integer", true }, .{ "character", "integer", true }, .{ "new_name", "string", true }, .{ "apply", "boolean", false } }),
    .read_only = false,
    .group = .formatting_and_edits,
    .risk = .{ .writes_source = true, .writes_require_apply = true, .preview_by_default = true, .mutates_lsp_state = true, .executes_backend = true },
    .plan = .{ .apply_gated_mutation = "Preview-first workspace mutation; writes only when apply=true and reports risk metadata before changes." },
});
pub const zig_code_actions = tool(.{
    .description = "Get ZLS code actions for a range.",
    .input_schema = schema(&.{ .{ "file", "string", true }, .{ "content", "string", false }, .{ "start_line", "integer", true }, .{ "start_char", "integer", true }, .{ "end_line", "integer", true }, .{ "end_char", "integer", true } }),
    .read_only = true,
    .group = .formatting_and_edits,
    .risk = .{ .mutates_lsp_state = true, .executes_backend = true },
    .plan = .{ .zls_request = .{ .method = "textDocument/codeAction", .requires_document_sync = true, .required_capability = "codeActionProvider" } },
});
pub const zig_code_action_apply = tool(.{
    .description = "Preview or apply one ZLS code action by index. Writes only with apply=true.",
    .input_schema = schema(&.{ .{ "file", "string", true }, .{ "content", "string", false }, .{ "start_line", "integer", true }, .{ "start_char", "integer", true }, .{ "end_line", "integer", true }, .{ "end_char", "integer", true }, .{ "action_index", "integer", true }, .{ "apply", "boolean", false } }),
    .read_only = false,
    .group = .formatting_and_edits,
    .risk = .{ .writes_source = true, .writes_require_apply = true, .preview_by_default = true, .mutates_lsp_state = true, .executes_backend = true },
    .plan = .{ .apply_gated_mutation = "Preview-first workspace mutation; writes only when apply=true and reports risk metadata before changes." },
});

test "formatting definitions expose formatter metadata" {
    try @import("std").testing.expect(zig_format.description.len > 0);
}
