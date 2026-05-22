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
