//! Pins the path classification policy: source paths are editable; cache,
//! artifact, vendor, and generated paths are blocked with the correct reason token.

const std = @import("std");

const path_policy = @import("path_policy.zig");

test "classifies direct source paths as editable" {
    const policy = path_policy.classify("src/main.zig");
    try std.testing.expectEqualStrings("source", policy.classification);
    try std.testing.expect(policy.direct_edit_allowed);
    try std.testing.expectEqualStrings("workspace_source_path", policy.reason);
}

test "classifies generated cache artifact and vendor paths as blocked" {
    const cases = [_]struct {
        path: []const u8,
        classification: []const u8,
        reason: []const u8,
    }{
        .{ .path = ".zig-cache/o/hash/file", .classification = "cache", .reason = "cache_path" },
        .{ .path = ".zigars-cache/patch-sessions/history.jsonl", .classification = "generated_artifact", .reason = "zigars_artifact_path" },
        .{ .path = "third_party/lib/file.zig", .classification = "vendor", .reason = "vendored_dependency_path" },
        .{ .path = "docs/tool-index.generated.md", .classification = "generated", .reason = "generated_filename" },
        .{ .path = "nested/zig-out/file", .classification = "generated_or_vendored", .reason = "workspace_skip_policy" },
    };
    for (cases) |case| {
        const policy = path_policy.classify(case.path);
        try std.testing.expectEqualStrings(case.classification, policy.classification);
        try std.testing.expectEqualStrings(case.reason, policy.reason);
        try std.testing.expect(!policy.direct_edit_allowed);
    }
}
