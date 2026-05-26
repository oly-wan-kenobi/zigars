const std = @import("std");
const subject = @import("zls.zig");
const zig_document_open = subject.zig_document_open;
const zig_document_change = subject.zig_document_change;
const zig_document_close = subject.zig_document_close;
const zig_document_status = subject.zig_document_status;
const zig_diagnostics = subject.zig_diagnostics;
const zig_diagnostics_all = subject.zig_diagnostics_all;
const zig_diagnostics_workspace = subject.zig_diagnostics_workspace;
const zig_hover = subject.zig_hover;
const zig_definition = subject.zig_definition;
const zig_references = subject.zig_references;
const zig_completion = subject.zig_completion;
const zig_signature_help = subject.zig_signature_help;
const zig_document_symbols = subject.zig_document_symbols;
const zig_workspace_symbols = subject.zig_workspace_symbols;

test "zls definitions expose document metadata" {
    try @import("std").testing.expect(zig_document_open.description.len > 0);
}
