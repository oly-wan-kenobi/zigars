const types = @import("../types.zig");

const schema = types.schema;
const schemaWithHints = types.schemaWithHints;
const tool = types.tool;
const fieldHint = types.fieldHint;

/// Open or replace an in-memory Zig document in the ZLS session.
pub const zig_document_open = tool(.{
    .description = "Open or replace an in-memory Zig document in the ZLS session.",
    .input_schema = schema(&.{ .{ "file", "string", true }, .{ "content", "string", true } }),
    .read_only = false,
    .group = .zls,
    .risk = .{ .mutates_lsp_state = true, .executes_backend = true },
    .plan = .{ .zls_request = .{ .method = "textDocument/didOpen", .requires_document_sync = true, .mutates_document_state = true } },
});
/// Replace an already-open in-memory Zig document in the ZLS session.
pub const zig_document_change = tool(.{
    .description = "Replace an already-open in-memory Zig document in the ZLS session.",
    .input_schema = schema(&.{ .{ "file", "string", true }, .{ "content", "string", true } }),
    .read_only = false,
    .group = .zls,
    .risk = .{ .mutates_lsp_state = true, .executes_backend = true },
    .plan = .{ .zls_request = .{ .method = "textDocument/didChange", .requires_document_sync = true, .mutates_document_state = true } },
});
/// Report a Zig document close in stateless gateway mode.
pub const zig_document_close = tool(.{
    .description = "Report a Zig document close in stateless gateway mode. This is an idempotent no-op; later ZLS requests resync documents as needed.",
    .input_schema = schema(&.{.{ "file", "string", true }}),
    .read_only = true,
    .group = .zls,
    .plan = .{ .pure_analysis = "Returns the stateless document-close acknowledgement without sending a ZLS notification." },
});
/// Return tracked ZLS document version/hash/dirty metadata.
pub const zig_document_status = tool(.{
    .description = "Return tracked ZLS document version/hash/dirty metadata.",
    .input_schema = schema(&.{.{ "file", "string", true }}),
    .read_only = true,
    .group = .zls,
    .plan = .{ .pure_analysis = "Reads process-local ZLS document state without sending backend requests." },
});
/// Open a Zig file in ZLS and return the latest publishDiagnostics notification when available, with ast-check fallback.
pub const zig_diagnostics = tool(.{
    .description = "Open a Zig file in ZLS and return the latest publishDiagnostics notification when available, with ast-check fallback.",
    .input_schema = schema(&.{ .{ "file", "string", true }, .{ "content", "string", false } }),
    .read_only = true,
    .group = .zls,
    .risk = .{ .mutates_lsp_state = true, .executes_backend = true },
    .plan = .{ .zls_request = .{ .method = "textDocument/diagnostic", .requires_document_sync = true } },
});
/// Return diagnostics for one file using the same ZLS/ast-check fallback path as `zig_diagnostics`.
pub const zig_diagnostics_all = tool(.{
    .description = "Return diagnostics for one file using the same ZLS/ast-check fallback path as `zig_diagnostics`.",
    .input_schema = schema(&.{ .{ "file", "string", true }, .{ "content", "string", false } }),
    .read_only = true,
    .group = .zls,
    .risk = .{ .mutates_lsp_state = true, .executes_backend = true },
    .plan = .{ .zls_request = .{ .method = "textDocument/diagnostic", .requires_document_sync = true } },
});
/// Return cached workspace diagnostics grouped by file and severity.
pub const zig_diagnostics_workspace = tool(.{
    .description = "Return cached workspace diagnostics grouped by file and severity.",
    .input_schema = schema(&.{}),
    .read_only = true,
    .group = .zls,
    .plan = .{ .pure_analysis = "Reads cached workspace diagnostics collected from the active ZLS session." },
});
/// Get ZLS hover information for a Zig symbol.
pub const zig_hover = tool(.{
    .description = "Get ZLS hover information for a Zig symbol.",
    .input_schema = schema(&.{ .{ "file", "string", true }, .{ "content", "string", false }, .{ "line", "integer", true }, .{ "character", "integer", true } }),
    .read_only = true,
    .group = .zls,
    .risk = .{ .mutates_lsp_state = true, .executes_backend = true },
    .plan = .{ .zls_request = .{ .method = "textDocument/hover", .requires_document_sync = true, .required_capability = "hoverProvider" } },
});
/// Get ZLS definition location for a Zig symbol.
pub const zig_definition = tool(.{
    .description = "Get ZLS definition location for a Zig symbol.",
    .input_schema = schema(&.{ .{ "file", "string", true }, .{ "content", "string", false }, .{ "line", "integer", true }, .{ "character", "integer", true } }),
    .read_only = true,
    .group = .zls,
    .risk = .{ .mutates_lsp_state = true, .executes_backend = true },
    .plan = .{ .zls_request = .{ .method = "textDocument/definition", .requires_document_sync = true, .required_capability = "definitionProvider" } },
});
/// Find ZLS references for a Zig symbol.
pub const zig_references = tool(.{
    .description = "Find ZLS references for a Zig symbol.",
    .input_schema = schema(&.{ .{ "file", "string", true }, .{ "content", "string", false }, .{ "line", "integer", true }, .{ "character", "integer", true }, .{ "include_declaration", "boolean", false } }),
    .read_only = true,
    .group = .zls,
    .risk = .{ .mutates_lsp_state = true, .executes_backend = true },
    .plan = .{ .zls_request = .{ .method = "textDocument/references", .requires_document_sync = true, .required_capability = "referencesProvider" } },
});
/// Get ZLS completions at a Zig source position.
pub const zig_completion = tool(.{
    .description = "Get ZLS completions at a Zig source position.",
    .input_schema = schema(&.{ .{ "file", "string", true }, .{ "content", "string", false }, .{ "line", "integer", true }, .{ "character", "integer", true } }),
    .read_only = true,
    .group = .zls,
    .risk = .{ .mutates_lsp_state = true, .executes_backend = true },
    .plan = .{ .zls_request = .{ .method = "textDocument/completion", .requires_document_sync = true, .required_capability = "completionProvider" } },
});
/// Get ZLS signature help at a Zig source position.
pub const zig_signature_help = tool(.{
    .description = "Get ZLS signature help at a Zig source position.",
    .input_schema = schema(&.{ .{ "file", "string", true }, .{ "content", "string", false }, .{ "line", "integer", true }, .{ "character", "integer", true } }),
    .read_only = true,
    .group = .zls,
    .risk = .{ .mutates_lsp_state = true, .executes_backend = true },
    .plan = .{ .zls_request = .{ .method = "textDocument/signatureHelp", .requires_document_sync = true, .required_capability = "signatureHelpProvider" } },
});
/// List ZLS document symbols for a Zig source file.
pub const zig_document_symbols = tool(.{
    .description = "List ZLS document symbols for a Zig source file.",
    .input_schema = schema(&.{ .{ "file", "string", true }, .{ "content", "string", false } }),
    .read_only = true,
    .group = .zls,
    .risk = .{ .mutates_lsp_state = true, .executes_backend = true },
    .plan = .{ .zls_request = .{ .method = "textDocument/documentSymbol", .requires_document_sync = true, .required_capability = "documentSymbolProvider" } },
});
/// Search ZLS workspace symbols matching a query.
pub const zig_workspace_symbols = tool(.{
    .description = "Search ZLS workspace symbols matching a query.",
    .input_schema = schema(&.{ .{ "query", "string", true }, .{ "limit", "integer", false } }),
    .read_only = true,
    .group = .zls,
    .risk = .{ .executes_backend = true },
    .plan = .{ .zls_request = .{ .method = "workspace/symbol", .required_capability = "workspaceSymbolProvider" } },
});
