//! Workspace path-resolution policy: every user-provided path is classified as
//! source (direct edits allowed), generated, cache, vendor, or artifact before
//! any read or write is attempted.  The invariant is that apply-gated tools only
//! proceed when classify returns direct_edit_allowed = true.

const std = @import("std");

/// Classifies a workspace path and prescribes whether direct edits are allowed.
/// All fields are string literals with static lifetime; no allocation needed.
/// `direct_edit_allowed` is the primary gate: apply-gated tools must not write
/// to a path unless this is true.
pub const PathPolicy = struct {
    classification: []const u8,
    direct_edit_allowed: bool,
    /// Machine-readable reason token explaining the classification decision.
    reason: []const u8,
    /// Human-readable remediation route for non-editable paths.
    route: []const u8,
    /// Canonical source inputs for regenerating this path.
    sources: []const []const u8,
    /// Commands to regenerate or repair the classified path.
    commands: []const []const u8,
    /// Confidence in the heuristic: "high" or "medium".
    confidence: []const u8,
};

/// Classifies `path` by applying policy rules in priority order:
/// cache → zigars artifact → vendor → generated name → workspace skip → source.
/// The first matching rule wins; a path that matches none is treated as editable source.
/// Path matching is boundary-safe: "zig-out" does not accidentally match "zig-outbound".
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
    if (isZigarsArtifactPath(path)) return .{
        .classification = "generated_artifact",
        .direct_edit_allowed = false,
        .reason = "zigars_artifact_path",
        .route = "rerun the zigars tool that produced the artifact",
        .sources = &.{ ".zigars/profile.v2.json", "source files referenced by artifact provenance" },
        .commands = &.{ "zigars_artifact_index", "zigars_artifact_read" },
        .confidence = "high",
    };
    if (isVendorPath(path)) return .{
        .classification = "vendor",
        .direct_edit_allowed = false,
        .reason = "vendored_dependency_path",
        .route = "change dependency source, pin, or patch workflow rather than editing vendored output directly",
        .sources = &.{ "build.zig.zon", "build.zig", "dependency upstream" },
        .commands = &.{ "zig build", "zigars_patch_guard" },
        .confidence = "high",
    };
    if (isGeneratedName(path)) return .{
        .classification = "generated",
        .direct_edit_allowed = false,
        .reason = "generated_filename",
        .route = "edit generator inputs and rerun the generator",
        .sources = &.{ "tools", "src", "build.zig" },
        // tool-index.generated.md has its own dedicated regeneration command.
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
        .route = "direct edit allowed through apply-gated zigars tools",
        .sources = &.{"requested workspace path"},
        .commands = &.{"zigars_patch_session_validate"},
        .confidence = "high",
    };
}

/// Matches top-level cache/output directories that are always regeneration targets.
fn isCachePath(path: []const u8) bool {
    return startsPath(path, ".zig-cache") or startsPath(path, "zig-out") or startsPath(path, "coverage") or startsPath(path, "dist");
}

/// Identifies persisted artifact outputs owned by zigars tooling.
fn isZigarsArtifactPath(path: []const u8) bool {
    return startsPath(path, ".zigars-cache");
}

/// Captures common vendored dependency locations that should not be edited in place.
fn isVendorPath(path: []const u8) bool {
    return startsPath(path, "zig-pkg") or startsPath(path, "vendor") or startsPath(path, "third_party") or startsPath(path, "deps") or
        std.mem.indexOf(u8, path, "/vendor/") != null or std.mem.indexOf(u8, path, "/third_party/") != null or std.mem.indexOf(u8, path, "/deps/") != null;
}

/// Generated filename heuristics for files expected to be rewritten by tools.
fn isGeneratedName(path: []const u8) bool {
    return std.mem.endsWith(u8, path, ".generated.md") or
        std.mem.endsWith(u8, path, ".generated.zig") or
        std.mem.endsWith(u8, path, ".gen.zig") or
        std.mem.endsWith(u8, path, ".pb.zig") or
        std.mem.eql(u8, path, "docs/tool-index.generated.md");
}

/// Workspace-level skip policy shared with analysis for generated dependency trees.
fn skipWorkspacePath(path: []const u8) bool {
    // Normalize and constrain path handling here before any downstream filesystem action.
    return std.mem.startsWith(u8, path, ".zig-cache") or
        std.mem.startsWith(u8, path, ".zigars-cache") or
        std.mem.startsWith(u8, path, "zig-out") or
        std.mem.startsWith(u8, path, "zig-pkg") or
        std.mem.indexOf(u8, path, "/.zig-cache/") != null or
        std.mem.indexOf(u8, path, "/.zigars-cache/") != null or
        std.mem.indexOf(u8, path, "/zig-out/") != null or
        std.mem.indexOf(u8, path, "/zig-pkg/") != null;
}

/// Prefix match that only accepts path-boundary matches (not partial segments).
/// The '/' separator guard ensures "zig-out" does not match "zig-outbound".
fn startsPath(path: []const u8, prefix: []const u8) bool {
    return std.mem.eql(u8, path, prefix) or (std.mem.startsWith(u8, path, prefix) and path.len > prefix.len and path[prefix.len] == '/');
}
