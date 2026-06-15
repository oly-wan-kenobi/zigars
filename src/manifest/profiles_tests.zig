//! Pins the tool-surface profile predicate: full admits every group, core admits
//! only the curated subset, the named-profile parser round-trips, and the core
//! profile yields a non-empty proper subset of the full tool catalog.
const std = @import("std");
const manifest = @import("mod.zig");
const profiles = @import("profiles.zig");

const ToolGroup = manifest.ToolGroup;
const ToolProfile = profiles.ToolProfile;

test "full profile admits every tool group" {
    inline for (std.meta.fields(ToolGroup)) |field| {
        const group = @field(ToolGroup, field.name);
        try std.testing.expect(profiles.groupInProfile(group, .full));
    }
}

test "core profile admits the curated groups and excludes the rest" {
    // Representative members of the core set stay in; heavy non-core surfaces drop.
    try std.testing.expect(profiles.groupInProfile(.discovery, .core));
    try std.testing.expect(profiles.groupInProfile(.core_zig, .core));
    try std.testing.expect(profiles.groupInProfile(.zls, .core));
    try std.testing.expect(profiles.groupInProfile(.docs, .core));
    try std.testing.expect(profiles.groupInProfile(.formatting_and_edits, .core));
    try std.testing.expect(profiles.groupInProfile(.agent_workflows, .core));

    try std.testing.expect(!profiles.groupInProfile(.static_analysis, .core));
    try std.testing.expect(!profiles.groupInProfile(.profiling, .core));
    try std.testing.expect(!profiles.groupInProfile(.dependency_security, .core));
    try std.testing.expect(!profiles.groupInProfile(.observability, .core));
}

test "parseProfile round-trips known names and rejects unknown ones" {
    try std.testing.expectEqual(ToolProfile.full, profiles.parseProfile("full").?);
    try std.testing.expectEqual(ToolProfile.core, profiles.parseProfile("core").?);
    try std.testing.expect(profiles.parseProfile("bogus") == null);
    try std.testing.expect(profiles.parseProfile("") == null);
}

test "core profile is a non-empty proper subset of the full catalog" {
    var core_count: usize = 0;
    for (manifest.entries) |entry| {
        if (profiles.groupInProfile(entry.group, .core)) core_count += 1;
    }
    try std.testing.expect(core_count > 0);
    try std.testing.expect(core_count < manifest.specs.len);
}
