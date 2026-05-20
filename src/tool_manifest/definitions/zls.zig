const types = @import("../types.zig");

const schema = types.schema;
const schemaWithHints = types.schemaWithHints;
const tool = types.tool;
const handler = types.handler;
const fieldHint = types.fieldHint;

pub const zig_document_open = tool(.{
    .description = "Open or replace an in-memory Zig document in the ZLS session.",
    .input_schema = schema(&.{ .{ "file", "string", true }, .{ "content", "string", true } }),
    .read_only = false,
    .group = .zls,
    .risk = .{ .mutates_lsp_state = true, .executes_backend = true },
    .handler = handler(.edit_zls, "zigDocumentOpen"),
    .plan = .{ .zls_request = .{ .method = "textDocument/didOpen", .requires_document_sync = true, .mutates_document_state = true } },
});
pub const zig_document_change = tool(.{
    .description = "Replace an already-open in-memory Zig document in the ZLS session.",
    .input_schema = schema(&.{ .{ "file", "string", true }, .{ "content", "string", true } }),
    .read_only = false,
    .group = .zls,
    .risk = .{ .mutates_lsp_state = true, .executes_backend = true },
    .handler = handler(.edit_zls, "zigDocumentOpen"),
    .plan = .{ .zls_request = .{ .method = "textDocument/didChange", .requires_document_sync = true, .mutates_document_state = true } },
});
pub const zig_document_close = tool(.{
    .description = "Close a Zig document in the ZLS session.",
    .input_schema = schema(&.{.{ "file", "string", true }}),
    .read_only = false,
    .group = .zls,
    .risk = .{ .mutates_lsp_state = true, .executes_backend = true },
    .handler = handler(.edit_zls, "zigDocumentClose"),
    .plan = .{ .zls_request = .{ .method = "textDocument/didClose", .mutates_document_state = true } },
});
pub const zig_document_status = tool(.{
    .description = "Return tracked ZLS document version/hash/dirty metadata.",
    .input_schema = schema(&.{.{ "file", "string", true }}),
    .read_only = true,
    .group = .zls,
    .handler = handler(.edit_zls, "zigDocumentStatus"),
    .plan = .{ .pure_analysis = "Reads process-local ZLS document state without sending backend requests." },
});
pub const zig_diagnostics = tool(.{
    .description = "Open a Zig file in ZLS and return the latest publishDiagnostics notification when available, with ast-check fallback.",
    .input_schema = schema(&.{ .{ "file", "string", true }, .{ "content", "string", false }, .{ "wait_ms", "integer", false } }),
    .read_only = true,
    .group = .zls,
    .risk = .{ .mutates_lsp_state = true, .executes_backend = true },
    .handler = handler(.edit_zls_diagnostics, "zigDiagnostics"),
    .plan = .{ .zls_request = .{ .method = "textDocument/publishDiagnostics with ast-check fallback", .requires_document_sync = true } },
});
pub const zig_diagnostics_all = tool(.{
    .description = "Aggregate diagnostics from ZLS publish/pull diagnostics and `zig ast-check`.",
    .input_schema = schema(&.{ .{ "file", "string", true }, .{ "content", "string", false }, .{ "wait_ms", "integer", false }, .{ "timeout_ms", "integer", false } }),
    .read_only = true,
    .group = .zls,
    .risk = .{ .mutates_lsp_state = true, .executes_backend = true },
    .handler = handler(.edit_zls_diagnostics, "zigDiagnosticsAll"),
    .plan = .{ .zls_request = .{ .method = "textDocument/diagnostic plus ast-check fallback", .requires_document_sync = true } },
});
pub const zig_diagnostics_workspace = tool(.{
    .description = "Return cached workspace diagnostics grouped by file and severity.",
    .input_schema = schema(&.{}),
    .read_only = true,
    .group = .zls,
    .handler = handler(.edit_zls_diagnostics, "zigDiagnosticsWorkspace"),
    .plan = .{ .pure_analysis = "Reads cached workspace diagnostics collected from the active ZLS session." },
});
pub const zig_hover = tool(.{
    .description = "Get ZLS hover information for a Zig symbol.",
    .input_schema = schema(&.{ .{ "file", "string", true }, .{ "content", "string", false }, .{ "line", "integer", true }, .{ "character", "integer", true } }),
    .read_only = true,
    .group = .zls,
    .risk = .{ .mutates_lsp_state = true, .executes_backend = true },
    .handler = handler(.edit_zls, "zigHover"),
    .plan = .{ .zls_request = .{ .method = "textDocument/hover", .requires_document_sync = true, .required_capability = "hoverProvider" } },
});
pub const zig_definition = tool(.{
    .description = "Get ZLS definition location for a Zig symbol.",
    .input_schema = schema(&.{ .{ "file", "string", true }, .{ "content", "string", false }, .{ "line", "integer", true }, .{ "character", "integer", true } }),
    .read_only = true,
    .group = .zls,
    .risk = .{ .mutates_lsp_state = true, .executes_backend = true },
    .handler = handler(.edit_zls, "zigDefinition"),
    .plan = .{ .zls_request = .{ .method = "textDocument/definition", .requires_document_sync = true, .required_capability = "definitionProvider" } },
});
pub const zig_references = tool(.{
    .description = "Find ZLS references for a Zig symbol.",
    .input_schema = schema(&.{ .{ "file", "string", true }, .{ "content", "string", false }, .{ "line", "integer", true }, .{ "character", "integer", true }, .{ "include_declaration", "boolean", false } }),
    .read_only = true,
    .group = .zls,
    .risk = .{ .mutates_lsp_state = true, .executes_backend = true },
    .handler = handler(.edit_zls, "zigReferences"),
    .plan = .{ .zls_request = .{ .method = "textDocument/references", .requires_document_sync = true, .required_capability = "referencesProvider" } },
});
pub const zig_completion = tool(.{
    .description = "Get ZLS completions at a Zig source position.",
    .input_schema = schema(&.{ .{ "file", "string", true }, .{ "content", "string", false }, .{ "line", "integer", true }, .{ "character", "integer", true } }),
    .read_only = true,
    .group = .zls,
    .risk = .{ .mutates_lsp_state = true, .executes_backend = true },
    .handler = handler(.edit_zls, "zigCompletion"),
    .plan = .{ .zls_request = .{ .method = "textDocument/completion", .requires_document_sync = true, .required_capability = "completionProvider" } },
});
pub const zig_signature_help = tool(.{
    .description = "Get ZLS signature help at a Zig source position.",
    .input_schema = schema(&.{ .{ "file", "string", true }, .{ "content", "string", false }, .{ "line", "integer", true }, .{ "character", "integer", true } }),
    .read_only = true,
    .group = .zls,
    .risk = .{ .mutates_lsp_state = true, .executes_backend = true },
    .handler = handler(.edit_zls, "zigSignatureHelp"),
    .plan = .{ .zls_request = .{ .method = "textDocument/signatureHelp", .requires_document_sync = true, .required_capability = "signatureHelpProvider" } },
});
pub const zig_document_symbols = tool(.{
    .description = "List ZLS document symbols for a Zig source file.",
    .input_schema = schema(&.{ .{ "file", "string", true }, .{ "content", "string", false } }),
    .read_only = true,
    .group = .zls,
    .risk = .{ .mutates_lsp_state = true, .executes_backend = true },
    .handler = handler(.edit_zls, "zigDocumentSymbols"),
    .plan = .{ .zls_request = .{ .method = "textDocument/documentSymbol", .requires_document_sync = true, .required_capability = "documentSymbolProvider" } },
});
pub const zig_workspace_symbols = tool(.{
    .description = "Search ZLS workspace symbols matching a query.",
    .input_schema = schema(&.{ .{ "query", "string", true }, .{ "limit", "integer", false } }),
    .read_only = true,
    .group = .zls,
    .risk = .{ .executes_backend = true },
    .handler = handler(.edit_zls, "zigWorkspaceSymbols"),
    .plan = .{ .zls_request = .{ .method = "workspace/symbol", .required_capability = "workspaceSymbolProvider" } },
});
