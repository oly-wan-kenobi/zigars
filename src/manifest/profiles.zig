//! Named tool-surface profiles: curated subsets of `ToolGroup` selectable at
//! process startup (via `--profile`) to shrink the registered tool catalog.
//! `full` registers every group and is the default, preserving the complete
//! ~317-tool surface byte-for-byte; `core` registers a curated essential subset
//! for clients that want a smaller, lower-noise `tools/list`.
const std = @import("std");
const types = @import("types.zig");

const ToolGroup = types.ToolGroup;

/// Tool-surface profile chosen at startup. Drives registration-time filtering,
/// so a tool excluded by the active profile is never registered and is therefore
/// absent from both `tools/list` and `tools/call`.
pub const ToolProfile = enum {
    /// Every manifest tool group is registered. Default; unchanged behavior.
    full,
    /// A curated essential subset covering the everyday Zig development loop.
    core,
};

/// Tool groups registered under the `core` profile. Chosen to cover the common
/// inner loop — discovery, build/test/check, formatting and edits, ZLS code
/// intelligence, docs, and agent workflow helpers — while dropping the heavier
/// static-analysis, release, profiling, observability, and dependency surfaces
/// that `full` still exposes.
const core_groups = [_]ToolGroup{
    .discovery,
    .core_zig,
    .formatting_and_edits,
    .zls,
    .docs,
    .agent_workflows,
};

/// Returns whether a tool group is registered under the given profile.
/// `full` admits every group; `core` admits only `core_groups`.
pub fn groupInProfile(group: ToolGroup, profile: ToolProfile) bool {
    return switch (profile) {
        .full => true,
        .core => for (core_groups) |core_group| {
            if (core_group == group) break true;
        } else false,
    };
}

/// Parses a `--profile` flag value into a `ToolProfile`, or null when the value
/// names no known profile (the caller maps null to a startup parse error).
pub fn parseProfile(value: []const u8) ?ToolProfile {
    return std.meta.stringToEnum(ToolProfile, value);
}
