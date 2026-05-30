//! LSP type vocabulary for ZLS communication.
//! Contains the subset of LSP 3.x types used by this server for document sync,
//! hover, diagnostics, completion, code actions, and workspace symbols.
//! Numeric kind codes follow the LSP specification numbering exactly.
const std = @import("std");

/// LSP Position (0-based line and character).
pub const Position = struct {
    line: u32,
    character: u32,
};

/// LSP Range.
pub const Range = struct {
    start: Position,
    end: Position,
};

/// LSP Location.
pub const Location = struct {
    uri: []const u8,
    range: Range,
};

/// LSP TextDocumentIdentifier.
pub const TextDocumentIdentifier = struct {
    uri: []const u8,
};

/// LSP TextDocumentPositionParams.
pub const TextDocumentPositionParams = struct {
    textDocument: TextDocumentIdentifier,
    position: Position,
};

/// LSP TextDocumentItem (for didOpen).
pub const TextDocumentItem = struct {
    uri: []const u8,
    languageId: []const u8,
    version: i64,
    text: []const u8,
};

/// LSP VersionedTextDocumentIdentifier.
pub const VersionedTextDocumentIdentifier = struct {
    uri: []const u8,
    version: i64,
};

/// LSP DidOpenTextDocumentParams.
pub const DidOpenTextDocumentParams = struct {
    textDocument: TextDocumentItem,
};

/// LSP DidCloseTextDocumentParams.
pub const DidCloseTextDocumentParams = struct {
    textDocument: TextDocumentIdentifier,
};

/// LSP Diagnostic.
pub const Diagnostic = struct {
    range: Range,
    severity: ?u32 = null,
    code: ?std.json.Value = null,
    source: ?[]const u8 = null,
    message: []const u8,
};

/// LSP PublishDiagnosticsParams (received from ZLS as a notification).
pub const PublishDiagnosticsParams = struct {
    uri: []const u8,
    diagnostics: []const Diagnostic,
};

/// LSP Hover result.
pub const Hover = struct {
    contents: HoverContents,
    range: ?Range = null,
};

/// Hover contents accepted by LSP: either MarkupContent or a plain string.
pub const HoverContents = union(enum) {
    markup: MarkupContent,
    string: []const u8,

    /// Parses the two hover content shapes ZLS can return.
    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !HoverContents {
        // Hover contents can be a string or a MarkupContent object.
        const token = try source.peekNextTokenType();
        return switch (token) {
            .string => .{ .string = try std.json.innerParse([]const u8, allocator, source, options) },
            .object_begin => .{ .markup = try std.json.innerParse(MarkupContent, allocator, source, options) },
            else => error.UnexpectedToken,
        };
    }

    /// Writes the original hover content shape back to JSON.
    pub fn jsonStringify(self: HoverContents, jw: anytype) !void {
        switch (self) {
            .markup => |m| try jw.write(m),
            .string => |s| try jw.write(s),
        }
    }

    /// Returns the displayable hover text regardless of source shape.
    pub fn text(self: HoverContents) []const u8 {
        return switch (self) {
            .markup => |m| m.value,
            .string => |s| s,
        };
    }
};

/// Marked-up hover payload returned by ZLS.
pub const MarkupContent = struct {
    kind: []const u8 = "markdown",
    value: []const u8,
};

/// LSP CompletionItem.
pub const CompletionItem = struct {
    label: []const u8,
    kind: ?u32 = null,
    detail: ?[]const u8 = null,
    documentation: ?std.json.Value = null,
    insertText: ?[]const u8 = null,
};

/// LSP CompletionList.
pub const CompletionList = struct {
    isIncomplete: bool = false,
    items: []const CompletionItem,
};

/// LSP DocumentSymbol.
pub const DocumentSymbol = struct {
    name: []const u8,
    kind: u32,
    range: Range,
    selectionRange: Range,
    detail: ?[]const u8 = null,
    children: ?[]const DocumentSymbol = null,
};

/// LSP SymbolInformation (from workspace/symbol).
pub const SymbolInformation = struct {
    name: []const u8,
    kind: u32,
    location: Location,
    containerName: ?[]const u8 = null,
};

/// LSP WorkspaceEdit.
/// `changes` maps document URIs to arrays of TextEdit; kept as raw JSON
/// because the uri-keyed map shape is awkward to parse into a typed struct.
pub const WorkspaceEdit = struct {
    changes: ?std.json.Value = null, // uri -> TextEdit[]
    documentChanges: ?std.json.Value = null,
};

/// LSP TextEdit.
pub const TextEdit = struct {
    range: Range,
    newText: []const u8,
};

/// LSP SignatureHelp.
pub const SignatureHelp = struct {
    signatures: []const SignatureInformation,
    activeSignature: ?u32 = null,
    activeParameter: ?u32 = null,
};

/// Signature help entry with borrowed label and optional documentation.
pub const SignatureInformation = struct {
    label: []const u8,
    documentation: ?std.json.Value = null,
    parameters: ?[]const ParameterInformation = null,
};

/// Function parameter label and optional documentation from signature help.
/// `label` is either a plain string name or a [startOffset, endOffset] pair into
/// the containing SignatureInformation label; kept as raw JSON to handle both shapes.
pub const ParameterInformation = struct {
    label: std.json.Value, // string or [number, number]
    documentation: ?std.json.Value = null,
};

/// LSP CodeAction.
pub const CodeAction = struct {
    title: []const u8,
    kind: ?[]const u8 = null,
    edit: ?WorkspaceEdit = null,
    command: ?Command = null,
};

/// Code action command payload with optional JSON arguments.
pub const Command = struct {
    title: []const u8,
    command: []const u8,
    arguments: ?std.json.Value = null,
};

/// Maps an LSP symbol kind number to a human-readable name, returning "Unknown"
/// for any value not defined in the LSP 3.x specification.
pub fn symbolKindName(kind: u32) []const u8 {
    return switch (kind) {
        1 => "File",
        2 => "Module",
        3 => "Namespace",
        4 => "Package",
        5 => "Class",
        6 => "Method",
        7 => "Property",
        8 => "Field",
        9 => "Constructor",
        10 => "Enum",
        11 => "Interface",
        12 => "Function",
        13 => "Variable",
        14 => "Constant",
        15 => "String",
        16 => "Number",
        17 => "Boolean",
        18 => "Array",
        19 => "Object",
        20 => "Key",
        21 => "Null",
        22 => "EnumMember",
        23 => "Struct",
        24 => "Event",
        25 => "Operator",
        26 => "TypeParameter",
        else => "Unknown",
    };
}

/// Maps an LSP diagnostic severity number (1–4) to its name; null and unknowns return "Unknown".
pub fn severityName(severity: ?u32) []const u8 {
    return switch (severity orelse 0) {
        1 => "Error",
        2 => "Warning",
        3 => "Information",
        4 => "Hint",
        else => "Unknown",
    };
}

/// Maps an LSP completion item kind number (1–25) to its name; null and unknowns return "Unknown".
pub fn completionKindName(kind: ?u32) []const u8 {
    return switch (kind orelse 0) {
        1 => "Text",
        2 => "Method",
        3 => "Function",
        4 => "Constructor",
        5 => "Field",
        6 => "Variable",
        7 => "Class",
        8 => "Interface",
        9 => "Module",
        10 => "Property",
        11 => "Unit",
        12 => "Value",
        13 => "Enum",
        14 => "Keyword",
        15 => "Snippet",
        16 => "Color",
        17 => "File",
        18 => "Reference",
        19 => "Folder",
        20 => "EnumMember",
        21 => "Constant",
        22 => "Struct",
        23 => "Event",
        24 => "Operator",
        25 => "TypeParameter",
        else => "Unknown",
    };
}
