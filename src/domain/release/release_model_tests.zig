const std = @import("std");

const release_model = @import("release_model.zig");

test "release plan classifies missing evidence without claiming skipped checks passed" {
    var plan = try release_model.buildReleasePlan(std.testing.allocator, &.{
        .{ .name = "validation", .text = " tests passed ", .verify_with = "zig build test" },
        .{ .name = "ci", .text = null, .verify_with = "zig_ci_ingest" },
    });
    defer plan.deinit(std.testing.allocator);

    try std.testing.expect(plan.release_blocked);
    try std.testing.expect(plan.checks.items[0].observed);
    try std.testing.expectEqualStrings("observed", plan.checks.items[0].status);
    try std.testing.expectEqualStrings("tests passed", plan.checks.items[0].summary.?);
    try std.testing.expect(!plan.checks.items[1].observed);
    try std.testing.expectEqualStrings("missing", plan.checks.items[1].status);
}

test "semver suggestion is conservative over supplied textual evidence" {
    try std.testing.expectEqual(release_model.SemverBump.major, release_model.suggestSemver("{\"breaking_change_risk\":true}", "", "").bump);
    try std.testing.expectEqual(release_model.SemverBump.minor, release_model.suggestSemver("", "Added docs capability", "").bump);
    try std.testing.expectEqual(release_model.SemverBump.patch, release_model.suggestSemver("", "Fixed typo", "").bump);
}

test "release notes draft omits empty sections and preserves review requirement" {
    var draft = try release_model.draftReleaseNotes(std.testing.allocator, "1.0.0", &.{
        .{ .title = "Changes", .text = "Added release tooling." },
        .{ .title = "Security", .text = "   " },
    });
    defer draft.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), draft.sections.items.len);
    try std.testing.expectEqualStrings("Changes", draft.sections.items[0].title);
    try std.testing.expect(std.mem.indexOf(u8, draft.markdown, "# 1.0.0") != null);
    try std.testing.expect(draft.requires_review);
}

test "release notes draft truncates long bodies and renders empty drafts" {
    const allocator = std.testing.allocator;
    const long_body = try allocator.alloc(u8, 1305);
    defer allocator.free(long_body);
    @memset(long_body, 'x');

    var long_draft = try release_model.draftReleaseNotes(allocator, null, &.{
        .{ .title = "Changes", .text = long_body },
    });
    defer long_draft.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1203), long_draft.sections.items[0].body.len);
    try std.testing.expect(std.mem.endsWith(u8, long_draft.sections.items[0].body, "..."));
    try std.testing.expect(std.mem.indexOf(u8, long_draft.markdown, "# next") != null);

    var empty_draft = try release_model.draftReleaseNotes(allocator, null, &.{});
    defer empty_draft.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, empty_draft.markdown, "_No release evidence was supplied._") != null);
}

test "evidence pack records pointer presence without executing release gates" {
    var pack = try release_model.buildEvidencePack(std.testing.allocator, &.{
        .{ .name = "validation", .text = "" },
        .{ .name = "ci", .text = "workflow run 42" },
    });
    defer pack.deinit(std.testing.allocator);

    try std.testing.expect(pack.ready_for_release_review);
    try std.testing.expectEqual(@as(usize, 2), pack.evidence.items.len);
    try std.testing.expect(!pack.evidence.items[0].provided);
    try std.testing.expect(pack.evidence.items[1].provided);
    try std.testing.expectEqualStrings("workflow run 42", pack.evidence.items[1].summary.?);
}

test "release model allocation failure cleanup is bounded" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, releasePlanWithAllocator, .{});
    try std.testing.checkAllAllocationFailures(std.testing.allocator, releaseNotesWithAllocator, .{});
    try std.testing.checkAllAllocationFailures(std.testing.allocator, evidencePackWithAllocator, .{});
}

fn releasePlanWithAllocator(allocator: std.mem.Allocator) !void {
    var plan = try release_model.buildReleasePlan(allocator, &.{
        .{ .name = "validation", .text = "tests passed", .verify_with = "zig build test" },
        .{ .name = "ci", .text = null, .verify_with = "zig_ci_ingest" },
    });
    defer plan.deinit(allocator);
}

fn releaseNotesWithAllocator(allocator: std.mem.Allocator) !void {
    var draft = try release_model.draftReleaseNotes(allocator, "1.0.0", &.{
        .{ .title = "Changes", .text = "Added release tooling." },
        .{ .title = "Fixes", .text = "Reduced flaky coverage evidence." },
    });
    defer draft.deinit(allocator);
}

fn evidencePackWithAllocator(allocator: std.mem.Allocator) !void {
    var pack = try release_model.buildEvidencePack(allocator, &.{
        .{ .name = "validation", .text = "zig build test" },
        .{ .name = "ci", .text = "workflow run 42" },
    });
    defer pack.deinit(allocator);
}
