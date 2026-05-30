//! Pins the release-intelligence contracts: the plan keeps its seven required
//! evidence checks in order, draft notes apply public section labels, and the
//! evidence pack preserves its seven provided/absent pointer slots.
const std = @import("std");

const release_intelligence = @import("release_intelligence.zig");

test "release plan use case keeps required evidence checklist ordering" {
    var result = try release_intelligence.plan(std.testing.allocator, .{
        .validation = "ok",
        .ci = "ok",
        .api = "ok",
        .docs = "ok",
        .dependencies = "ok",
        .security = "ok",
        .changelog = "ok",
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.release_blocked);
    try std.testing.expectEqual(@as(usize, 7), result.checks.items.len);
    try std.testing.expectEqualStrings("validation", result.checks.items[0].name);
    try std.testing.expectEqualStrings("release notes review", result.checks.items[6].verify_with);
}

test "release notes use case applies public section labels" {
    var draft = try release_intelligence.draftNotes(std.testing.allocator, .{
        .version = "2.0.0",
        .changes = "New release flow.",
        .security = "Reviewed scanner limitations.",
    });
    defer draft.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), draft.sections.items.len);
    try std.testing.expectEqualStrings("Changes", draft.sections.items[0].title);
    try std.testing.expectEqualStrings("Security", draft.sections.items[1].title);
    try std.testing.expect(std.mem.indexOf(u8, draft.markdown, "Reviewed scanner limitations.") != null);
}

test "evidence pack use case preserves seven public pointer slots" {
    var pack = try release_intelligence.evidencePack(std.testing.allocator, .{
        .validation = "zig build test passed",
    });
    defer pack.deinit(std.testing.allocator);

    try std.testing.expect(pack.ready_for_release_review);
    try std.testing.expectEqual(@as(usize, 7), pack.evidence.items.len);
    try std.testing.expect(pack.evidence.items[0].provided);
    try std.testing.expect(!pack.evidence.items[6].provided);
}
