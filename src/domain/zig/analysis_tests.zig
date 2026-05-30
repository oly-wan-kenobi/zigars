//! Fixture-driven tests for analysis.zig: parser-backed source summaries,
//! malformed-source partial results, heuristic advisory scanners, and the
//! workspace path-skip policy.
const std = @import("std");

const analysis = @import("analysis.zig");

test "parser-backed source summary covers static-analysis fixture" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const summary = try analysis.parseSourceSummary(arena.allocator(), "fixture.zig", @embedFile("fixtures/static_analysis_tricky.fixture"));
    try std.testing.expectEqual(analysis.ParseStatus.ok, summary.parse.status);
    try std.testing.expect(!summary.parse.partial_result);
    try std.testing.expect(hasDeclaration(summary.declarations, "Outer"));
    try std.testing.expect(hasDeclaration(summary.declarations, "nested"));
    try std.testing.expect(hasDeclaration(summary.declarations, "LocalErrors"));
    try std.testing.expect(hasImport(summary.imports, "std", "std"));
    try std.testing.expect(hasImport(summary.imports, "math.zig", "math_alias"));
    try std.testing.expect(hasTest(summary.tests, "outer works"));
    try std.testing.expect(hasTest(summary.tests, "escaped \"quote\" text"));
    try std.testing.expect(!hasDeclaration(summary.declarations, "Missing"));
    try std.testing.expect(!hasImport(summary.imports, "std", "wrong_alias"));
    try std.testing.expect(!hasImportValue(summary.imports, "missing.zig"));
    try std.testing.expect(!hasTest(summary.tests, "missing"));
}

test "parser-backed source summary marks malformed fixtures partial" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const malformed = try analysis.parseSourceSummary(arena.allocator(), "malformed.zig", @embedFile("fixtures/static_analysis_malformed.fixture"));
    try std.testing.expectEqual(analysis.ParseStatus.syntax_errors, malformed.parse.status);
    try std.testing.expect(malformed.parse.partial_result);
    try std.testing.expect(!malformed.parse.result_complete);
    try std.testing.expect(malformed.parse.parse_error_count > 0);
    try std.testing.expect(hasImportValue(malformed.imports, "std"));

    const sample = try analysis.parseSourceSummary(arena.allocator(), "usingnamespace.zig", @embedFile("fixtures/static_analysis_usingnamespace.fixture"));
    try std.testing.expectEqual(analysis.ParseStatus.syntax_errors, sample.parse.status);
    try std.testing.expect(hasImport(sample.imports, "std", "std"));
}

test "heuristic summaries preserve advisory source policy" {
    const text =
        \\pub fn main() void {}
        \\const Hidden = struct {};
        \\const std = @import("std");
    ;
    const summary = try analysis.declarationSummaryText(std.testing.allocator, "x.zig", text);
    defer std.testing.allocator.free(summary);
    try std.testing.expect(std.mem.indexOf(u8, summary, "Capability tier: advisory_orientation") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "pub fn main") != null);

    const allocations = try analysis.allocationSummaryText(std.testing.allocator, "x.zig", "var list: std.ArrayList(u8) = .empty;\n");
    defer std.testing.allocator.free(allocations);
    try std.testing.expect(std.mem.indexOf(u8, allocations, "ArrayList") != null);
}

test "workspace skip policy remains cache and artifact oriented" {
    try std.testing.expect(analysis.skipWorkspacePath(".zig-cache/o/file.zig"));
    try std.testing.expect(analysis.skipWorkspacePath(".zigars-cache/profile/out.zig"));
    try std.testing.expect(analysis.skipWorkspacePath("zig-out/bin/main.zig"));
    try std.testing.expect(analysis.skipWorkspacePath("zig-pkg/mcp/src/server.zig"));
    try std.testing.expect(!analysis.skipWorkspacePath("src/main.zig"));
}

// KCOV_EXCL_START
/// Test helper: returns whether declaration evidence contains a named declaration.
fn hasDeclaration(items: []const analysis.Declaration, name: []const u8) bool {
    for (items) |item| {
        if (item.name) |actual| if (std.mem.eql(u8, actual, name)) return true;
    }
    return false;
}

/// Test helper: returns whether import evidence contains the expected import and alias.
fn hasImport(items: []const analysis.Import, import_name: []const u8, alias: []const u8) bool {
    for (items) |item| {
        if (!std.mem.eql(u8, item.import, import_name)) continue;
        if (item.alias) |actual| if (std.mem.eql(u8, actual, alias)) return true;
    }
    return false;
}

/// Test helper: returns whether import evidence contains the expected import path.
fn hasImportValue(items: []const analysis.Import, value: []const u8) bool {
    for (items) |item| {
        if (std.mem.eql(u8, item.import, value)) return true;
    }
    return false;
}

/// Test helper: returns whether test evidence contains a named test declaration.
fn hasTest(items: []const analysis.TestDecl, name: []const u8) bool {
    for (items) |item| {
        if (item.name) |actual| if (std.mem.eql(u8, actual, name)) return true;
    }
    return false;
}
// KCOV_EXCL_STOP
