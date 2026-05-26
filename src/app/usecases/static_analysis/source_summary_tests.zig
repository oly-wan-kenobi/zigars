const std = @import("std");

const app_context = @import("../../context.zig");
const source_summary = @import("source_summary.zig");
const scanner_fake = @import("../../../testing/fakes/workspace_scanner.zig");
const workspace_fake = @import("../../../testing/fakes/workspace_store.zig");

test "source text summaries are typed use-case calls over domain analysis" {
    const text =
        \\pub fn main() void {}
        \\const Hidden = struct {};
        \\const std = @import("std");
    ;
    const output = try source_summary.textSummary(std.testing.allocator, .decl_summary, .{
        .file = "src/main.zig",
        .contents = text,
    });
    defer std.testing.allocator.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "Capability tier: advisory_orientation") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "pub fn main") != null);
}

test "source text summary variants preserve advisory wording" {
    const text =
        \\pub const Alloc = std.ArrayList(u8);
        \\const LocalError = error{Bad};
        \\fn hidden() !void { return error.Bad; }
    ;
    inline for (.{ .allocations, .error_sets, .public_api, .dead_decl_candidates }) |kind| {
        const output = try source_summary.textSummary(std.testing.allocator, kind, .{
            .file = "src/main.zig",
            .contents = text,
        });
        defer std.testing.allocator.free(output);
        try std.testing.expect(std.mem.indexOf(u8, output, "Capability tier: advisory_orientation") != null);
    }
}

test "readParserSummary reads through workspace port and preserves parser evidence" {
    var fake = workspace_fake.FakeWorkspaceStore.init(std.testing.allocator);
    defer fake.deinit();
    var scanner = scanner_fake.FakeWorkspaceScanner.init(std.testing.allocator);
    defer scanner.deinit();
    try fake.expectRead(.{
        .path = "src/main.zig",
        .max_bytes = source_summary.default_source_read_limit,
        .provenance = source_summary.provenance,
    }, "const std = @import(\"std\");\ntest \"works\" {}\n");

    const ctx = app_context.StaticAnalysisContext{
        .workspace = .{ .root = "/workspace", .cache_root = "/workspace/.zigar-cache" },
        .workspace_store = fake.port(),
        .workspace_scanner = scanner.port(),
    };

    const result = try source_summary.readParserSummary(std.testing.allocator, ctx, .{ .file = "src/main.zig" });
    defer result.deinit(std.testing.allocator);
    try fake.verify();

    try std.testing.expectEqual(@as(usize, 1), result.imports.len);
    try std.testing.expectEqualStrings("std", result.imports[0].import);
    try std.testing.expectEqual(@as(usize, 1), result.tests.len);
    try std.testing.expectEqualStrings("works", result.tests[0].name.?);
}

test "readParserSummary rejects generated cache paths before workspace read" {
    var fake = workspace_fake.FakeWorkspaceStore.init(std.testing.allocator);
    defer fake.deinit();
    var scanner = scanner_fake.FakeWorkspaceScanner.init(std.testing.allocator);
    defer scanner.deinit();
    const ctx = app_context.StaticAnalysisContext{
        .workspace = .{ .root = "/workspace", .cache_root = "/workspace/.zigar-cache" },
        .workspace_store = fake.port(),
        .workspace_scanner = scanner.port(),
    };

    try std.testing.expectError(error.SkippedWorkspacePath, source_summary.readParserSummary(std.testing.allocator, ctx, .{ .file = ".zig-cache/o/generated.zig" }));
    try fake.verify();
    try std.testing.expectEqual(@as(usize, 0), fake.readCalls().len);
}
