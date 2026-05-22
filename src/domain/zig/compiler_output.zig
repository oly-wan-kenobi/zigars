const std = @import("std");

pub const CompilerLine = struct {
    severity: []const u8,
    path: ?[]const u8 = null,
    line: ?i64 = null,
    column: ?i64 = null,
    message: []const u8,
    raw: []const u8,
};

pub fn parseCompilerLine(line: []const u8) ?CompilerLine {
    if (parseLocatedCompilerLine(line, "error")) |parsed| return parsed;
    if (parseLocatedCompilerLine(line, "warning")) |parsed| return parsed;
    if (parseLocatedCompilerLine(line, "note")) |parsed| return parsed;
    if (std.mem.startsWith(u8, line, "error: ")) return .{ .severity = "error", .message = line["error: ".len..], .raw = line };
    if (std.mem.startsWith(u8, line, "warning: ")) return .{ .severity = "warning", .message = line["warning: ".len..], .raw = line };
    if (std.mem.startsWith(u8, line, "note: ")) return .{ .severity = "note", .message = line["note: ".len..], .raw = line };
    return null;
}

pub fn parseLocatedCompilerLine(line: []const u8, severity: []const u8) ?CompilerLine {
    var token_buf: [16]u8 = undefined;
    const token = std.fmt.bufPrint(&token_buf, ": {s}: ", .{severity}) catch return null;
    const severity_pos = std.mem.indexOf(u8, line, token) orelse return null;
    const prefix = line[0..severity_pos];
    const message = line[severity_pos + token.len ..];
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

pub fn classifyDiagnosticMessage(message: []const u8) []const u8 {
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

test "parseCompilerLine extracts located Zig diagnostics" {
    const parsed = parseCompilerLine("src/main.zig:7:11: error: expected type 'u8', found 'u16'").?;

    try std.testing.expectEqualStrings("error", parsed.severity);
    try std.testing.expectEqualStrings("src/main.zig", parsed.path.?);
    try std.testing.expectEqual(@as(i64, 7), parsed.line.?);
    try std.testing.expectEqual(@as(i64, 11), parsed.column.?);
    try std.testing.expectEqualStrings("expected type 'u8', found 'u16'", parsed.message);
    try std.testing.expectEqualStrings("type_mismatch", classifyDiagnosticMessage(parsed.message));
}

test "parseCompilerLine handles global diagnostics and ignores ordinary lines" {
    const global = parseCompilerLine("error: unable to load 'missing.zig'").?;

    try std.testing.expectEqualStrings("error", global.severity);
    try std.testing.expect(global.path == null);
    try std.testing.expectEqualStrings("missing_file_or_import", classifyDiagnosticMessage(global.message));
    try std.testing.expect(parseCompilerLine("Build Summary: 1/1 steps succeeded") == null);
}
