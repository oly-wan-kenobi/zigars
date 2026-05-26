const std = @import("std");

pub const PathPolicy = struct {
    classification: []const u8,
    direct_edit_allowed: bool,
    reason: []const u8,
    route: []const u8,
    sources: []const []const u8,
    commands: []const []const u8,
    confidence: []const u8,
};

pub fn classify(path: []const u8) PathPolicy {
    if (isCachePath(path)) return .{
        .classification = "cache",
        .direct_edit_allowed = false,
        .reason = "cache_path",
        .route = "edit source inputs and regenerate cache output",
        .sources = &.{ "build.zig", "build.zig.zon", "src" },
        .commands = &.{ "zig build", "zig build test" },
        .confidence = "high",
    };
    if (isZigarArtifactPath(path)) return .{
        .classification = "generated_artifact",
        .direct_edit_allowed = false,
        .reason = "zigar_artifact_path",
        .route = "rerun the zigar tool that produced the artifact",
        .sources = &.{ ".zigar/profile.v2.json", "source files referenced by artifact provenance" },
        .commands = &.{ "zigar_artifact_index", "zigar_artifact_read" },
        .confidence = "high",
    };
    if (isVendorPath(path)) return .{
        .classification = "vendor",
        .direct_edit_allowed = false,
        .reason = "vendored_dependency_path",
        .route = "change dependency source, pin, or patch workflow rather than editing vendored output directly",
        .sources = &.{ "build.zig.zon", "build.zig", "dependency upstream" },
        .commands = &.{ "zig build", "zigar_patch_guard" },
        .confidence = "high",
    };
    if (isGeneratedName(path)) return .{
        .classification = "generated",
        .direct_edit_allowed = false,
        .reason = "generated_filename",
        .route = "edit generator inputs and rerun the generator",
        .sources = &.{ "tools", "src", "build.zig" },
        .commands = if (std.mem.eql(u8, path, "docs/tool-index.generated.md")) &.{ "zig build tool-index", "zig build docs-check" } else &.{"zig build"},
        .confidence = "medium",
    };
    if (skipWorkspacePath(path)) return .{
        .classification = "generated_or_vendored",
        .direct_edit_allowed = false,
        .reason = "workspace_skip_policy",
        .route = "edit source inputs and regenerate",
        .sources = &.{ "src", "build.zig", "build.zig.zon" },
        .commands = &.{"zig build"},
        .confidence = "high",
    };
    return .{
        .classification = "source",
        .direct_edit_allowed = true,
        .reason = "workspace_source_path",
        .route = "direct edit allowed through apply-gated zigar tools",
        .sources = &.{"requested workspace path"},
        .commands = &.{"zigar_patch_session_validate"},
        .confidence = "high",
    };
}

fn isCachePath(path: []const u8) bool {
    return startsPath(path, ".zig-cache") or startsPath(path, "zig-out") or startsPath(path, "coverage") or startsPath(path, "dist");
}

fn isZigarArtifactPath(path: []const u8) bool {
    return startsPath(path, ".zigar-cache");
}

fn isVendorPath(path: []const u8) bool {
    return startsPath(path, "zig-pkg") or startsPath(path, "vendor") or startsPath(path, "third_party") or startsPath(path, "deps") or
        std.mem.indexOf(u8, path, "/vendor/") != null or std.mem.indexOf(u8, path, "/third_party/") != null or std.mem.indexOf(u8, path, "/deps/") != null;
}

fn isGeneratedName(path: []const u8) bool {
    return std.mem.endsWith(u8, path, ".generated.md") or
        std.mem.endsWith(u8, path, ".generated.zig") or
        std.mem.endsWith(u8, path, ".gen.zig") or
        std.mem.endsWith(u8, path, ".pb.zig") or
        std.mem.eql(u8, path, "docs/tool-index.generated.md");
}

fn skipWorkspacePath(path: []const u8) bool {
    return std.mem.startsWith(u8, path, ".zig-cache") or
        std.mem.startsWith(u8, path, ".zigar-cache") or
        std.mem.startsWith(u8, path, "zig-out") or
        std.mem.startsWith(u8, path, "zig-pkg") or
        std.mem.indexOf(u8, path, "/.zig-cache/") != null or
        std.mem.indexOf(u8, path, "/.zigar-cache/") != null or
        std.mem.indexOf(u8, path, "/zig-out/") != null or
        std.mem.indexOf(u8, path, "/zig-pkg/") != null;
}

fn startsPath(path: []const u8, prefix: []const u8) bool {
    return std.mem.eql(u8, path, prefix) or (std.mem.startsWith(u8, path, prefix) and path.len > prefix.len and path[prefix.len] == '/');
}

test "classifies direct source paths as editable" {
    const policy = classify("src/main.zig");
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
        .{ .path = ".zigar-cache/patch-sessions/history.jsonl", .classification = "generated_artifact", .reason = "zigar_artifact_path" },
        .{ .path = "third_party/lib/file.zig", .classification = "vendor", .reason = "vendored_dependency_path" },
        .{ .path = "docs/tool-index.generated.md", .classification = "generated", .reason = "generated_filename" },
        .{ .path = "nested/zig-out/file", .classification = "generated_or_vendored", .reason = "workspace_skip_policy" },
    };
    for (cases) |case| {
        const policy = classify(case.path);
        try std.testing.expectEqualStrings(case.classification, policy.classification);
        try std.testing.expectEqualStrings(case.reason, policy.reason);
        try std.testing.expect(!policy.direct_edit_allowed);
    }
}
