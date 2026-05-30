//! Coverage evidence use-case adapters for parse/merge/diff and quality budget checks.
const std = @import("std");

const coverage_model = @import("../../../domain/performance/coverage_model.zig");

/// Carries evidence request data across use case and port boundaries.
pub const EvidenceRequest = struct {
    bytes: []const u8,
    source_kind: []const u8,
    format: []const u8 = "auto",
};

/// Carries merge request data across use case and port boundaries.
pub const MergeRequest = struct {
    left: EvidenceRequest,
    right: EvidenceRequest,
};

/// Carries diff request data across use case and port boundaries.
pub const DiffRequest = struct {
    current: EvidenceRequest,
    baseline: EvidenceRequest,
};

/// Carries budget request data across use case and port boundaries.
pub const BudgetRequest = struct {
    coverage: EvidenceRequest,
    /// Workspace-relative paths whose coverage is scored separately; only paths that
    /// also appear in the coverage evidence contribute to the changed-file rate.
    changed_files: []const []const u8 = &.{},
    /// Overall line-rate floor in basis points (10000 = 100%); default 8000 = 80%.
    min_line_rate_bp: usize = 8000,
    /// Changed-file line-rate floor in basis points; 0 disables the changed-file gate.
    min_changed_line_rate_bp: usize = 0,
};

/// Carries coverage diff data across use case and port boundaries.
pub const CoverageDiff = struct {
    current: coverage_model.CoverageSet,
    baseline: coverage_model.CoverageSet,
    /// current minus baseline overall line rate, in basis points (signed: negative = drop).
    line_rate_delta_bp: i64,

    /// Releases allocations owned by this value; callers must not use owned slices after this returns.
    pub fn deinit(self: *CoverageDiff, allocator: std.mem.Allocator) void {
        // Both snapshots are owned by this result and must be released together.
        self.current.deinit(allocator);
        self.baseline.deinit(allocator);
        self.* = undefined;
    }
};

/// Carries coverage budget data across use case and port boundaries.
pub const CoverageBudget = struct {
    coverage: coverage_model.CoverageSet,
    changed: coverage_model.ChangedCoverage,
    line_rate_bp: usize,
    changed_line_rate_bp: usize,
    min_line_rate_bp: usize,
    min_changed_line_rate_bp: usize,

    /// True when the overall line rate meets its floor and, unless the changed-file
    /// floor is 0 (disabled), the changed-file line rate meets its floor too. All in bp.
    pub fn passed(self: CoverageBudget) bool {
        return self.line_rate_bp >= self.min_line_rate_bp and
            (self.min_changed_line_rate_bp == 0 or self.changed_line_rate_bp >= self.min_changed_line_rate_bp);
    }

    /// Releases allocations owned by this value; callers must not use owned slices after this returns.
    pub fn deinit(self: *CoverageBudget, allocator: std.mem.Allocator) void {
        self.coverage.deinit(allocator);
        self.* = undefined;
    }
};

/// Parses coverage evidence (LCOV or zigars coverage JSON; `format` "auto" detects) into
/// a fresh `CoverageSet`. Borrows `request.bytes`; the returned set is owned by the caller.
pub fn map(allocator: std.mem.Allocator, request: EvidenceRequest) !coverage_model.CoverageSet {
    return coverage_model.parse(allocator, request.bytes, request.source_kind, request.format);
}

/// Implements merge workflow logic using caller-owned inputs.
pub fn merge(allocator: std.mem.Allocator, request: MergeRequest) !coverage_model.CoverageSet {
    var left = try map(allocator, request.left);
    defer left.deinit(allocator);
    var right = try map(allocator, request.right);
    defer right.deinit(allocator);
    return coverage_model.merge(allocator, left, right);
}

/// Parses current and baseline evidence and computes their overall line-rate delta (bp).
/// On success both parsed sets are moved into the returned `CoverageDiff` (caller frees);
/// the ownership flags ensure a mid-parse failure does not leak the first set.
pub fn diff(allocator: std.mem.Allocator, request: DiffRequest) !CoverageDiff {
    // Keep this logic centralized so callers observe one consistent behavior path.
    var current = try map(allocator, request.current);
    var current_owned = true;
    defer if (current_owned) current.deinit(allocator);
    var baseline = try map(allocator, request.baseline);
    var baseline_owned = true;
    defer if (baseline_owned) baseline.deinit(allocator);
    current_owned = false;
    baseline_owned = false;
    return .{
        .line_rate_delta_bp = @as(i64, @intCast(coverage_model.rateBp(current.covered, current.total))) -
            @as(i64, @intCast(coverage_model.rateBp(baseline.covered, baseline.total))),
        .current = current,
        .baseline = baseline,
    };
}

/// Parses coverage evidence and computes overall and changed-file line rates (bp) against
/// the request floors. The parsed set is moved into the returned budget (caller frees).
pub fn budget(allocator: std.mem.Allocator, request: BudgetRequest) !CoverageBudget {
    // Keep this logic centralized so callers observe one consistent behavior path.
    var set = try map(allocator, request.coverage);
    errdefer set.deinit(allocator);
    const changed = coverage_model.changedCoverage(set, request.changed_files);
    return .{
        .line_rate_bp = coverage_model.rateBp(set.covered, set.total),
        .changed_line_rate_bp = coverage_model.rateBp(changed.covered, changed.total),
        .changed = changed,
        .min_line_rate_bp = request.min_line_rate_bp,
        .min_changed_line_rate_bp = request.min_changed_line_rate_bp,
        .coverage = set,
    };
}
