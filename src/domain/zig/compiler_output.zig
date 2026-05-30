//! Zig compiler output parsing: line-level diagnostic normalization and coarse
//! triage classification. All functions operate on borrowed slices; no
//! allocation occurs and returned fields borrow from the input line.
const std = @import("std");

/// Normalized view of one compiler or test-runner diagnostic line.
///
/// All slice fields borrow from the original input; no allocation is performed.
/// `path`, `line`, and `column` are null for global diagnostics such as
/// `error: unable to load 'missing.zig'` that carry no file location.
/// `raw` always equals the full original input line.
pub const CompilerLine = struct {
    severity: []const u8,
    path: ?[]const u8 = null,
    line: ?i64 = null,
    column: ?i64 = null,
    message: []const u8,
    raw: []const u8,
};

/// Tries each known severity in order and returns the first match, or null for
/// non-diagnostic lines such as build summaries.
///
/// Precedence: located `error` > located `warning` > located `note` > global
/// `error: ` > global `warning: ` > global `note: `.
pub fn parseCompilerLine(line: []const u8) ?CompilerLine {
    // Normalize input here so downstream paths can rely on validated shape.
    if (parseLocatedCompilerLine(line, "error")) |parsed| return parsed;
    if (parseLocatedCompilerLine(line, "warning")) |parsed| return parsed;
    if (parseLocatedCompilerLine(line, "note")) |parsed| return parsed;
    if (std.mem.startsWith(u8, line, "error: ")) return .{ .severity = "error", .message = line["error: ".len..], .raw = line };
    if (std.mem.startsWith(u8, line, "warning: ")) return .{ .severity = "warning", .message = line["warning: ".len..], .raw = line };
    if (std.mem.startsWith(u8, line, "note: ")) return .{ .severity = "note", .message = line["note: ".len..], .raw = line };
    return null;
}

/// Parses `path:line:column: severity: message` diagnostics for one severity.
///
/// Returns a result with null path/line/column when the prefix before `: severity: `
/// does not parse as `path:N:M`; this gracefully handles Windows absolute paths
/// (`C:\...`) or non-numeric column/line fields by degrading rather than failing.
pub fn parseLocatedCompilerLine(line: []const u8, severity: []const u8) ?CompilerLine {
    var token_buf: [16]u8 = undefined;
    const token = std.fmt.bufPrint(&token_buf, ": {s}: ", .{severity}) catch return null;
    const severity_pos = std.mem.indexOf(u8, line, token) orelse return null;
    const prefix = line[0..severity_pos];
    const message = line[severity_pos + token.len ..];
    // Walk back from the severity marker to extract column, then line number.
    // lastIndexOfScalar is used so paths containing colons (e.g. Windows drives)
    // are handled by the parseInt fallback rather than a hard failure.
    const col_sep = std.mem.lastIndexOfScalar(u8, prefix, ':') orelse return .{ .severity = severity, .message = message, .raw = line };
    const line_prefix = prefix[0..col_sep];
    const line_sep = std.mem.lastIndexOfScalar(u8, line_prefix, ':') orelse return .{ .severity = severity, .message = message, .raw = line };
    const line_no = std.fmt.parseInt(i64, line_prefix[line_sep + 1 ..], 10) catch return .{ .severity = severity, .message = message, .raw = line };
    const col_no = std.fmt.parseInt(i64, prefix[col_sep + 1 ..], 10) catch return .{ .severity = severity, .message = message, .raw = line };
    return .{
        .severity = severity,
        .path = line_prefix[0..line_sep],
        .line = line_no,
        .column = col_no,
        .message = message,
        .raw = line,
    };
}

/// Classifies a compiler diagnostic message into a coarse triage category.
///
/// Categories are stable tokens used in structured MCP results. The function
/// applies heuristics in order of specificity; `compiler_error` is the catch-all
/// when no keyword matches. Returns a borrowed static string literal.
pub fn classifyDiagnosticMessage(message: []const u8) []const u8 {
    // Keep this logic centralized so callers observe one consistent behavior path.
    if (std.mem.indexOf(u8, message, "expected type") != null) return "type_mismatch";
    if (std.mem.indexOf(u8, message, "expected ") != null and std.mem.indexOf(u8, message, "found ") != null) return "syntax_or_type_mismatch";
    if (std.mem.indexOf(u8, message, "expected ") != null) return "syntax_error";
    if (std.mem.indexOf(u8, message, "use of undeclared identifier") != null) return "undeclared_identifier";
    if (std.mem.indexOf(u8, message, "no field named") != null) return "missing_field";
    if (std.mem.indexOf(u8, message, "unable to load") != null or std.mem.indexOf(u8, message, "FileNotFound") != null) return "missing_file_or_import";
    if (std.mem.indexOf(u8, message, "unused") != null) return "unused_code";
    if (std.mem.indexOf(u8, message, "invalid token") != null) return "syntax_error";
    return "compiler_error";
}
