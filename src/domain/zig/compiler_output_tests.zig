//! Unit tests for compiler_output.zig: located diagnostic parsing, global
//! diagnostic fallback, non-diagnostic line rejection, and triage classification.
const std = @import("std");

const compiler_output = @import("compiler_output.zig");

test "parseCompilerLine extracts located Zig diagnostics" {
    const parsed = compiler_output.parseCompilerLine("src/main.zig:7:11: error: expected type 'u8', found 'u16'").?;

    try std.testing.expectEqualStrings("error", parsed.severity);
    try std.testing.expectEqualStrings("src/main.zig", parsed.path.?);
    try std.testing.expectEqual(@as(i64, 7), parsed.line.?);
    try std.testing.expectEqual(@as(i64, 11), parsed.column.?);
    try std.testing.expectEqualStrings("expected type 'u8', found 'u16'", parsed.message);
    try std.testing.expectEqualStrings("type_mismatch", compiler_output.classifyDiagnosticMessage(parsed.message));
}

test "parseCompilerLine handles global diagnostics and ignores ordinary lines" {
    const global = compiler_output.parseCompilerLine("error: unable to load 'missing.zig'").?;

    try std.testing.expectEqualStrings("error", global.severity);
    try std.testing.expect(global.path == null);
    try std.testing.expectEqualStrings("missing_file_or_import", compiler_output.classifyDiagnosticMessage(global.message));
    try std.testing.expect(compiler_output.parseCompilerLine("Build Summary: 1/1 steps succeeded") == null);
}
