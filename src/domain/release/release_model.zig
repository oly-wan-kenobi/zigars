//! Release readiness domain: evidence-check plans, semver suggestion, release-note
//! drafting, and evidence pack assembly. No I/O occurs here; callers supply all
//! text evidence and receive owned result structs that they must deinit.

const std = @import("std");

/// Caller-provided evidence check and command used to verify it.
/// `text` is nil when the evidence was not supplied; an empty string is treated as missing.
pub const EvidenceCheckInput = struct {
    name: []const u8,
    text: ?[]const u8,
    verify_with: []const u8,
};

/// One release-readiness check with an owned optional summary.
/// `summary` is allocator-owned when non-nil and must be freed via deinit.
pub const EvidenceCheck = struct {
    name: []const u8,
    observed: bool,
    status: []const u8,
    verify_with: []const u8,
    summary: ?[]u8,

    /// Frees the owned summary and invalidates the check.
    pub fn deinit(self: *EvidenceCheck, allocator: std.mem.Allocator) void {
        if (self.summary) |summary| allocator.free(summary);
        self.* = undefined;
    }
};

/// Owned release plan summarizing evidence checks and block status.
/// `release_blocked` is true when any check has observed=false; callers should
/// treat a blocked plan as a hard gate, not a suggestion.
pub const ReleasePlan = struct {
    checks: std.ArrayList(EvidenceCheck) = .empty,
    release_blocked: bool = true,

    /// Frees nested checks and backing storage.
    pub fn deinit(self: *ReleasePlan, allocator: std.mem.Allocator) void {
        for (self.checks.items) |*check| check.deinit(allocator);
        self.checks.deinit(allocator);
        self.* = undefined;
    }
};

/// Suggested semantic-version bump class derived from keyword evidence.
pub const SemverBump = enum {
    major,
    minor,
    patch,

    /// Returns the serialized bump token.
    pub fn text(self: SemverBump) []const u8 {
        return switch (self) {
            .major => "major",
            .minor => "minor",
            .patch => "patch",
        };
    }
};

/// Semver recommendation plus human-readable rationale.
pub const SemverSuggestion = struct {
    bump: SemverBump,
    reason: []const u8,
};

/// Named release-note source text supplied by callers.
pub const ReleaseNoteInput = struct {
    title: []const u8,
    text: ?[]const u8,
};

/// Release-note section with allocator-owned body text.
pub const ReleaseNoteSection = struct {
    title: []const u8,
    body: []u8,

    /// Frees the owned section body.
    pub fn deinit(self: *ReleaseNoteSection, allocator: std.mem.Allocator) void {
        allocator.free(self.body);
        self.* = undefined;
    }
};

/// Owned release-note draft with rendered markdown.
pub const ReleaseNotesDraft = struct {
    version: ?[]const u8,
    sections: std.ArrayList(ReleaseNoteSection) = .empty,
    markdown: []u8,
    requires_review: bool = true,

    /// Frees section bodies, backing storage, and rendered markdown.
    pub fn deinit(self: *ReleaseNotesDraft, allocator: std.mem.Allocator) void {
        for (self.sections.items) |*section| section.deinit(allocator);
        self.sections.deinit(allocator);
        allocator.free(self.markdown);
        self.* = undefined;
    }
};

/// Caller-provided evidence pointer for release review packs.
pub const EvidencePointerInput = struct {
    name: []const u8,
    text: ?[]const u8,
};

/// Evidence pointer with an owned optional summary.
pub const EvidencePointer = struct {
    name: []const u8,
    provided: bool,
    summary: ?[]u8,

    /// Frees the owned summary and invalidates the pointer.
    pub fn deinit(self: *EvidencePointer, allocator: std.mem.Allocator) void {
        if (self.summary) |summary| allocator.free(summary);
        self.* = undefined;
    }
};

/// Owned set of evidence pointers for release review.
pub const EvidencePack = struct {
    evidence: std.ArrayList(EvidencePointer) = .empty,
    ready_for_release_review: bool = false,

    /// Frees nested pointers and backing storage.
    pub fn deinit(self: *EvidencePack, allocator: std.mem.Allocator) void {
        for (self.evidence.items) |*pointer| pointer.deinit(allocator);
        self.evidence.deinit(allocator);
        self.* = undefined;
    }
};

/// Builds a release plan and blocks it when any required evidence is missing.
pub fn buildReleasePlan(allocator: std.mem.Allocator, inputs: []const EvidenceCheckInput) !ReleasePlan {
    var plan = ReleasePlan{};
    errdefer plan.deinit(allocator);
    for (inputs) |input| try appendEvidenceCheck(allocator, &plan.checks, input);
    plan.release_blocked = hasMissingEvidence(plan.checks.items);
    return plan;
}

/// Suggests a semver bump from explicit breaking/additive wording.
/// All three text inputs are scanned case-insensitively; the highest applicable bump wins.
/// No ownership is taken; the returned SemverSuggestion borrows string literals only.
pub fn suggestSemver(api_diff: []const u8, changelog: []const u8, release_notes: []const u8) SemverSuggestion {
    const bump: SemverBump = if (containsAnyIgnoreCase(&.{ api_diff, changelog, release_notes }, &.{ "breaking_change_risk\":true", "breaking change", "removed", "incompatible" }))
        .major
    else if (containsAnyIgnoreCase(&.{ api_diff, changelog, release_notes }, &.{ "added", "feature", "new tool", "capability" }))
        .minor
    else
        .patch;

    return .{
        .bump = bump,
        .reason = switch (bump) {
            .major => "Observed API/removal/breaking-change evidence.",
            .minor => "Observed additive feature evidence without explicit breaking-change evidence.",
            .patch => "No explicit breaking or additive API evidence was provided.",
        },
    };
}

/// Builds an owned markdown release-note draft from non-empty sections.
/// Sections whose text is nil or entirely whitespace are silently skipped.
/// Body text is capped at 1200 bytes with a trailing ellipsis on truncation.
/// `requires_review` is always true; the draft must not be published without human review.
pub fn draftReleaseNotes(allocator: std.mem.Allocator, version: ?[]const u8, inputs: []const ReleaseNoteInput) !ReleaseNotesDraft {
    var sections: std.ArrayList(ReleaseNoteSection) = .empty;
    errdefer {
        for (sections.items) |*section| section.deinit(allocator);
        sections.deinit(allocator);
    }

    for (inputs) |input| {
        const body = input.text orelse continue;
        if (std.mem.trim(u8, body, " \t\r\n").len == 0) continue;
        const section_body = try shortString(allocator, body, 1200);
        errdefer allocator.free(section_body);
        try sections.append(allocator, .{
            .title = input.title,
            .body = section_body,
        });
    }

    const markdown = try releaseNotesMarkdown(allocator, version orelse "next", sections.items);
    return .{
        .version = version,
        .sections = sections,
        .markdown = markdown,
        .requires_review = true,
    };
}

/// Builds an owned evidence pack and marks it reviewable when non-empty.
/// `ready_for_release_review` is false only when no inputs were supplied.
/// Empty-text inputs are recorded as not-provided but still appear in the evidence list.
pub fn buildEvidencePack(allocator: std.mem.Allocator, inputs: []const EvidencePointerInput) !EvidencePack {
    var pack = EvidencePack{};
    errdefer pack.deinit(allocator);
    for (inputs) |input| try appendEvidencePointer(allocator, &pack.evidence, input);
    pack.ready_for_release_review = pack.evidence.items.len > 0;
    return pack;
}

/// Appends one evidence check, truncating supplied text for display.
fn appendEvidenceCheck(allocator: std.mem.Allocator, checks: *std.ArrayList(EvidenceCheck), input: EvidenceCheckInput) !void {
    const observed = input.text != null and input.text.?.len > 0;
    const summary = if (input.text) |text| try shortString(allocator, text, 240) else null;
    errdefer if (summary) |text| allocator.free(text);
    try checks.append(allocator, .{
        .name = input.name,
        .observed = observed,
        .status = if (observed) "observed" else "missing",
        .verify_with = input.verify_with,
        .summary = summary,
    });
}

/// Appends one evidence pointer, preserving whether text was provided.
fn appendEvidencePointer(allocator: std.mem.Allocator, evidence: *std.ArrayList(EvidencePointer), input: EvidencePointerInput) !void {
    const summary = if (input.text) |text| try shortString(allocator, text, 400) else null;
    errdefer if (summary) |text| allocator.free(text);
    try evidence.append(allocator, .{
        .name = input.name,
        .provided = input.text != null and input.text.?.len > 0,
        .summary = summary,
    });
}

/// Returns whether a release plan includes missing-evidence findings.
fn hasMissingEvidence(checks: []const EvidenceCheck) bool {
    for (checks) |check| {
        if (!check.observed) return true;
    }
    return false;
}

/// Builds allocator-owned release notes markdown from release evidence.
fn releaseNotesMarkdown(allocator: std.mem.Allocator, version: []const u8, sections: []const ReleaseNoteSection) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    out.writer.print("# {s}\n\n", .{version}) catch return error.OutOfMemory;
    if (sections.len == 0) out.writer.writeAll("_No release evidence was supplied._\n") catch return error.OutOfMemory;
    for (sections) |section| {
        out.writer.print("## {s}\n\n{s}\n\n", .{ section.title, section.body }) catch return error.OutOfMemory;
    }
    return try out.toOwnedSlice();
}

/// Returns whether any needle appears in haystack with ASCII-insensitive matching.
fn containsAnyIgnoreCase(haystacks: []const []const u8, needles: []const []const u8) bool {
    for (haystacks) |haystack| {
        for (needles) |needle| {
            if (indexOfIgnoreCase(haystack, needle) != null) return true;
        }
    }
    return false;
}

/// Returns the byte index of an ASCII-insensitive match when present.
fn indexOfIgnoreCase(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0) return 0;
    if (needle.len > haystack.len) return null;
    var index: usize = 0;
    while (index + needle.len <= haystack.len) : (index += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[index .. index + needle.len], needle)) return index;
    }
    return null;
}

/// Returns an owned trimmed string, truncating with an ellipsis past limit bytes.
fn shortString(allocator: std.mem.Allocator, input: []const u8, limit: usize) ![]u8 {
    const trimmed = std.mem.trim(u8, input, " \t\r\n");
    if (trimmed.len <= limit) return allocator.dupe(u8, trimmed);
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, trimmed[0..limit]);
    try out.appendSlice(allocator, "...");
    return out.toOwnedSlice(allocator);
}

test "release short string truncation cleans partial allocations" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, truncateWithAllocator, .{});
}

/// Returns an owned trimmed string capped to a byte limit.
fn truncateWithAllocator(allocator: std.mem.Allocator) !void {
    const value = try shortString(allocator, "abcdef", 3);
    defer allocator.free(value);
    try std.testing.expectEqualStrings("abc...", value);
}
