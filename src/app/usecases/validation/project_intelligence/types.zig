//! Shared request/value types and defaults for the project-intelligence use
//! cases. Extracted from project_intelligence.zig so the orchestrator module and
//! its internal helpers can reference the same types without a circular import.
//! Depends only on std and the leaf-helper support module.
const std = @import("std");
const support = @import("support.zig");

/// Schema version written into this module's structured payloads.
pub const schema_version: i64 = 1;
/// Default semantic limit used when the caller omits an explicit value.
pub const semantic_limit_default: usize = 500;
/// Default memory path used when the caller omits an explicit value.
pub const memory_path_default = ".zigars/project-memory.jsonl";
/// Default profile path used when the caller omits an explicit value.
pub const profile_path_default = ".zigars/profile.json";

/// Carries path list data across use case and port boundaries.
pub const PathList = struct {
    items: []const []const u8,

    /// Releases allocations owned by this value; callers must not use owned slices after this returns.
    pub fn deinit(self: *PathList, allocator: std.mem.Allocator) void {
        support.freeStringList(allocator, self.items);
        allocator.free(self.items);
        self.* = undefined;
    }
};

/// Carries context pack request data across use case and port boundaries.
pub const ContextPackRequest = struct {
    mode: []const u8 = "standard",
    token_budget: i64 = 4000,
};

/// Carries validate patch request data across use case and port boundaries.
pub const ValidatePatchRequest = struct {
    mode: []const u8 = "standard",
    changed_files: ?[]const u8 = null,
    timeout_ms: i64,
    stop_on_failure: bool = false,
};

/// Carries failure fusion request data across use case and port boundaries.
pub const FailureFusionRequest = struct {
    text: ?[]const u8 = null,
    command: ?[]const u8 = null,
    file: ?[]const u8 = null,
    filter: ?[]const u8 = null,
    extra_args: []const []const u8 = &.{},
    timeout_ms: i64,
};

/// Carries impact request data across use case and port boundaries.
pub const ImpactRequest = struct {
    files: ?[]const u8 = null,
    symbols: ?[]const u8 = null,
    limit: usize = 300,
};

/// Carries project profile request data across use case and port boundaries.
pub const ProjectProfileRequest = struct {
    content: ?[]const u8 = null,
    apply: bool = false,
};

/// Carries patch guard request data across use case and port boundaries.
pub const PatchGuardRequest = struct {
    files: ?[]const u8 = null,
    patch: ?[]const u8 = null,
};

/// Carries semantic impact request data across use case and port boundaries.
pub const SemanticImpactRequest = struct {
    files: ?[]const u8 = null,
    diff: ?[]const u8 = null,
    symbols: ?[]const u8 = null,
    limit: usize = semantic_limit_default,
};

/// Defines the allowed event command kind variants accepted by this workflow.
pub const EventCommandKind = enum { build, test_cmd };

/// Carries command events request data across use case and port boundaries.
pub const CommandEventsRequest = struct {
    text: ?[]const u8 = null,
    command: ?[]const u8 = null,
    file: ?[]const u8 = null,
    filter: ?[]const u8 = null,
    extra_args: []const []const u8 = &.{},
    timeout_ms: i64,
    kind: EventCommandKind,
};

/// Carries session snapshot request data across use case and port boundaries.
pub const SessionSnapshotRequest = struct {
    kind: []const u8,
    goal: ?[]const u8 = null,
    changed_files: ?[]const u8 = null,
    diff: ?[]const u8 = null,
    validation: ?[]const u8 = null,
    last_error: ?[]const u8 = null,
};

/// Carries decision record request data across use case and port boundaries.
pub const DecisionRecordRequest = struct {
    title: []const u8,
    decision: []const u8,
    rationale: ?[]const u8 = null,
    category: []const u8 = "architecture",
    path: []const u8 = memory_path_default,
    apply: bool = false,
};

/// Carries project memory request data across use case and port boundaries.
pub const ProjectMemoryRequest = struct {
    content: ?[]const u8 = null,
    path: []const u8 = memory_path_default,
    query: ?[]const u8 = null,
    category: ?[]const u8 = null,
    limit: usize = 100,
    include_builtins: bool = false,
    tool_name: []const u8,
};

/// Carries tool risk data across use case and port boundaries.
pub const ToolRisk = struct {
    level: []const u8,
    mcp_read_only_hint: bool,
    writes_source: bool,
    writes_artifacts: bool,
    writes_require_apply: bool,
    preview_by_default: bool,
    mutates_lsp_state: bool,
    executes_project_code: bool,
    executes_user_command: bool,
    executes_backend: bool,
};

/// Carries capability entry data across use case and port boundaries.
pub const CapabilityEntry = struct {
    name: []const u8,
    description: []const u8,
    group: []const u8,
    group_keywords: []const []const u8,
    risk: ToolRisk,
    plan_kind: []const u8,
};

/// Owns a built argv slice plus its backing string allocations.
pub const ArgvList = struct {
    items: []const []const u8,

    /// Releases allocations owned by this value; callers must not use owned slices after this returns.
    pub fn deinit(self: *ArgvList, allocator: std.mem.Allocator) void {
        support.freeStringList(allocator, self.items);
        allocator.free(self.items);
        self.* = undefined;
    }
};
