const std = @import("std");
const zigar = @import("zigar");

const analysis = zigar.analysis;

test "parser-backed scans cover tricky Zig syntax fixture" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source = try readFixture(allocator, "tests/fixtures/static-analysis/tricky.zig");

    const decls = try analysis.astDeclSummaryJson(allocator, "fixture.zig", source);
    try std.testing.expectEqualStrings("parser_backed", decls.object.get("capability_tier").?.string);
    try std.testing.expectEqualStrings("high", decls.object.get("confidence").?.string);
    try std.testing.expectEqualStrings("ok", decls.object.get("parse_status").?.string);
    try std.testing.expect(!decls.object.get("partial_result").?.bool);
    try std.testing.expect(decls.object.get("cross_check").?.object.get("verify_with").?.array.items.len > 0);
    try std.testing.expectEqual(@as(i64, 0), decls.object.get("parse_error_count").?.integer);
    const decl_items = decls.object.get("declarations").?.array.items;
    try std.testing.expect(arrayHasStringField(decl_items, "name", "Outer"));
    try std.testing.expect(arrayHasStringField(decl_items, "name", "Inner"));
    try std.testing.expect(arrayHasStringField(decl_items, "name", "Namespace"));
    try std.testing.expect(arrayHasStringField(decl_items, "name", "ReExported"));
    try std.testing.expect(arrayHasStringField(decl_items, "name", "nested"));
    try std.testing.expect(arrayHasStringField(decl_items, "name", "generic"));
    try std.testing.expect(arrayHasStringField(decl_items, "name", "LocalErrors"));
    try std.testing.expect(arrayHasStringField(decl_items, "name", "inferredFailure"));
    try std.testing.expect(arrayHasStringField(decl_items, "name", "explicitFailure"));
    try std.testing.expect(arrayHasStringField(decl_items, "name", "Generated"));
    try std.testing.expect(arrayHasStringField(decl_items, "name", "run"));
    try std.testing.expect(arrayStringFieldContainsForName(decl_items, "generic", "signature", "comptime T: type"));
    try std.testing.expect(arrayStringFieldContainsForName(decl_items, "LocalErrors", "signature", "error{"));
    try std.testing.expect(!arrayHasStringField(decl_items, "name", "commented"));

    const imports = try analysis.astImportsJson(allocator, "fixture.zig", source);
    const import_items = imports.object.get("imports").?.array.items;
    try std.testing.expectEqualStrings("parser_backed", imports.object.get("capability_tier").?.string);
    try std.testing.expectEqualStrings("ok", imports.object.get("parse_status").?.string);
    try std.testing.expect(imports.object.get("cross_check").?.object.get("verify_with").?.array.items.len > 0);
    try std.testing.expect(arrayHasStringField(import_items, "import", "std"));
    try std.testing.expect(arrayHasStringField(import_items, "import", "math.zig"));
    try std.testing.expect(arrayHasStringField(import_items, "import", "dep/nested.zig"));
    try std.testing.expect(arrayHasStringField(import_items, "import", "nested.zig"));
    try std.testing.expect(arrayHasStringFields(import_items, "import", "std", "alias", "std"));
    try std.testing.expect(arrayHasStringFields(import_items, "import", "math.zig", "alias", "math_alias"));
    try std.testing.expect(arrayHasStringFields(import_items, "import", "dep/nested.zig", "alias", "nested_alias"));
    try std.testing.expect(arrayHasStringFields(import_items, "import", "nested.zig", "alias", "nested_import"));
    try std.testing.expect(!arrayHasStringField(import_items, "import", "fake.zig"));
    try std.testing.expect(!arrayHasStringField(import_items, "import", "commented.zig"));

    const tests = try analysis.astTestsJson(allocator, "fixture.zig", source);
    const test_items = tests.object.get("tests").?.array.items;
    try std.testing.expectEqualStrings("parser_backed", tests.object.get("capability_tier").?.string);
    try std.testing.expectEqualStrings("ok", tests.object.get("parse_status").?.string);
    try std.testing.expect(tests.object.get("cross_check").?.object.get("verify_with").?.array.items.len > 0);
    try std.testing.expect(arrayHasStringField(test_items, "name", "outer works"));
    try std.testing.expect(arrayHasStringField(test_items, "name", "nested \"escaped\" text"));
    try std.testing.expect(arrayHasStringField(test_items, "name", "escaped \"quote\" text"));
    try std.testing.expect(arrayHasStringField(test_items, "name", "named"));
}

test "parser-backed scans mark malformed syntax as partial" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source = try readFixture(allocator, "tests/fixtures/static-analysis/malformed.zig");

    const decls = try analysis.astDeclSummaryJson(allocator, "malformed.zig", source);
    try expectPartialParse(decls);

    const imports = try analysis.astImportsJson(allocator, "malformed.zig", source);
    try expectPartialParse(imports);
    try std.testing.expect(arrayHasStringField(imports.object.get("imports").?.array.items, "import", "std"));

    const tests = try analysis.astTestsJson(allocator, "malformed.zig", source);
    try expectPartialParse(tests);
}

test "parser-backed scans mark legacy usingnamespace syntax as partial" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source = try readFixture(allocator, "tests/fixtures/static-analysis/legacy-usingnamespace.zig");

    const imports = try analysis.astImportsJson(allocator, "legacy-usingnamespace.zig", source);
    try expectPartialParse(imports);
    try std.testing.expect(arrayHasStringFields(imports.object.get("imports").?.array.items, "import", "std", "alias", "std"));
}

fn expectPartialParse(value: std.json.Value) !void {
    try std.testing.expectEqualStrings("syntax_errors", value.object.get("parse_status").?.string);
    try std.testing.expect(value.object.get("partial_result").?.bool);
    try std.testing.expect(!value.object.get("result_complete").?.bool);
    try std.testing.expect(value.object.get("parse_error_count").?.integer > 0);
}

fn readFixture(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(128 * 1024));
}

fn arrayHasStringField(items: []const std.json.Value, field: []const u8, expected: []const u8) bool {
    for (items) |item| {
        const obj = switch (item) {
            .object => |o| o,
            else => continue,
        };
        const actual = switch (obj.get(field) orelse .null) {
            .string => |s| s,
            else => continue,
        };
        if (std.mem.eql(u8, actual, expected)) return true;
    }
    return false;
}

fn arrayHasStringFields(items: []const std.json.Value, first_field: []const u8, first_expected: []const u8, second_field: []const u8, second_expected: []const u8) bool {
    for (items) |item| {
        const obj = switch (item) {
            .object => |o| o,
            else => continue,
        };
        const first_actual = switch (obj.get(first_field) orelse .null) {
            .string => |s| s,
            else => continue,
        };
        const second_actual = switch (obj.get(second_field) orelse .null) {
            .string => |s| s,
            else => continue,
        };
        if (std.mem.eql(u8, first_actual, first_expected) and std.mem.eql(u8, second_actual, second_expected)) return true;
    }
    return false;
}

fn arrayStringFieldContainsForName(items: []const std.json.Value, name: []const u8, field: []const u8, needle: []const u8) bool {
    for (items) |item| {
        const obj = switch (item) {
            .object => |o| o,
            else => continue,
        };
        const actual_name = switch (obj.get("name") orelse .null) {
            .string => |s| s,
            else => continue,
        };
        if (!std.mem.eql(u8, actual_name, name)) continue;
        const actual = switch (obj.get(field) orelse .null) {
            .string => |s| s,
            else => continue,
        };
        if (std.mem.indexOf(u8, actual, needle) != null) return true;
    }
    return false;
}
