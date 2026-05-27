//! Release decision helpers for plan completeness, semver, and changelog evidence wiring.
const std = @import("std");

const release_model = @import("../../../domain/release/release_model.zig");

/// Carries release plan request data across use case and port boundaries.
pub const ReleasePlanRequest = struct {
    validation: ?[]const u8 = null,
    ci: ?[]const u8 = null,
    api: ?[]const u8 = null,
    docs: ?[]const u8 = null,
    dependencies: ?[]const u8 = null,
    security: ?[]const u8 = null,
    changelog: ?[]const u8 = null,
};

/// Carries semver request data across use case and port boundaries.
pub const SemverRequest = struct {
    api_diff: []const u8 = "",
    changelog: []const u8 = "",
    release_notes: []const u8 = "",
};

/// Carries release notes request data across use case and port boundaries.
pub const ReleaseNotesRequest = struct {
    version: ?[]const u8 = null,
    changes: ?[]const u8 = null,
    api_diff: ?[]const u8 = null,
    validation: ?[]const u8 = null,
    ci: ?[]const u8 = null,
    dependencies: ?[]const u8 = null,
    security: ?[]const u8 = null,
};

/// Carries evidence pack request data across use case and port boundaries.
pub const EvidencePackRequest = struct {
    validation: ?[]const u8 = null,
    ci: ?[]const u8 = null,
    api: ?[]const u8 = null,
    docs: ?[]const u8 = null,
    dependencies: ?[]const u8 = null,
    security: ?[]const u8 = null,
    artifacts: ?[]const u8 = null,
};

/// Shared release plan result type used by this workflow module.
pub const ReleasePlan = release_model.ReleasePlan;
/// Shared evidence check result type used by this workflow module.
pub const EvidenceCheck = release_model.EvidenceCheck;
/// Shared semver suggestion result type used by this workflow module.
pub const SemverSuggestion = release_model.SemverSuggestion;
/// Shared release notes draft result type used by this workflow module.
pub const ReleaseNotesDraft = release_model.ReleaseNotesDraft;
/// Shared release note section result type used by this workflow module.
pub const ReleaseNoteSection = release_model.ReleaseNoteSection;
/// Shared evidence pack result type used by this workflow module.
pub const EvidencePack = release_model.EvidencePack;
/// Shared evidence pointer result type used by this workflow module.
pub const EvidencePointer = release_model.EvidencePointer;

/// Implements plan workflow logic using caller-owned inputs.
pub fn plan(allocator: std.mem.Allocator, request: ReleasePlanRequest) !ReleasePlan {
    return release_model.buildReleasePlan(allocator, &.{
        .{ .name = "validation", .text = request.validation, .verify_with = "zigars_validation_run or zig build test" },
        .{ .name = "ci", .text = request.ci, .verify_with = "zig_ci_ingest plus local repro plan" },
        .{ .name = "api", .text = request.api, .verify_with = "zig_api_check or zig_api_diff_baseline" },
        .{ .name = "docs", .text = request.docs, .verify_with = "zig build docs-check and snippet checks" },
        .{ .name = "dependencies", .text = request.dependencies, .verify_with = "zig_dependency_fetch_check and lock audit" },
        .{ .name = "security", .text = request.security, .verify_with = "zig_dependency_security_report" },
        .{ .name = "changelog", .text = request.changelog, .verify_with = "release notes review" },
    });
}

/// Implements suggest semver workflow logic using caller-owned inputs.
pub fn suggestSemver(request: SemverRequest) SemverSuggestion {
    return release_model.suggestSemver(request.api_diff, request.changelog, request.release_notes);
}

/// Implements draft notes workflow logic using caller-owned inputs.
pub fn draftNotes(allocator: std.mem.Allocator, request: ReleaseNotesRequest) !ReleaseNotesDraft {
    return release_model.draftReleaseNotes(allocator, request.version, &.{
        .{ .title = "Changes", .text = request.changes },
        .{ .title = "API", .text = request.api_diff },
        .{ .title = "Validation", .text = request.validation },
        .{ .title = "CI", .text = request.ci },
        .{ .title = "Dependencies", .text = request.dependencies },
        .{ .title = "Security", .text = request.security },
    });
}

/// Implements evidence pack workflow logic using caller-owned inputs.
pub fn evidencePack(allocator: std.mem.Allocator, request: EvidencePackRequest) !EvidencePack {
    return release_model.buildEvidencePack(allocator, &.{
        .{ .name = "validation", .text = request.validation },
        .{ .name = "ci", .text = request.ci },
        .{ .name = "api", .text = request.api },
        .{ .name = "docs", .text = request.docs },
        .{ .name = "dependencies", .text = request.dependencies },
        .{ .name = "security", .text = request.security },
        .{ .name = "artifacts", .text = request.artifacts },
    });
}
