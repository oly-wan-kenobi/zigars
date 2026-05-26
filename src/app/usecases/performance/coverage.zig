//! Coverage evidence use-case adapters for parse/merge/diff and quality budget checks.
const std = @import("std");

const coverage_model = @import("../../../domain/performance/coverage_model.zig");

pub const EvidenceRequest = struct {
    bytes: []const u8,
    source_kind: []const u8,
    format: []const u8 = "auto",
};

pub const MergeRequest = struct {
    left: EvidenceRequest,
    right: EvidenceRequest,
};

pub const DiffRequest = struct {
    current: EvidenceRequest,
    baseline: EvidenceRequest,
};

pub const BudgetRequest = struct {
    coverage: EvidenceRequest,
    changed_files: []const []const u8 = &.{},
    min_line_rate_bp: usize = 8000,
    min_changed_line_rate_bp: usize = 0,
};

pub const CoverageDiff = struct {
    current: coverage_model.CoverageSet,
    baseline: coverage_model.CoverageSet,
    line_rate_delta_bp: i64,

    pub fn deinit(self: *CoverageDiff, allocator: std.mem.Allocator) void {
        // Both snapshots are owned by this result and must be released together.
        self.current.deinit(allocator);
        self.baseline.deinit(allocator);
        self.* = undefined;
    }
};

pub const CoverageBudget = struct {
    coverage: coverage_model.CoverageSet,
    changed: coverage_model.ChangedCoverage,
    line_rate_bp: usize,
    changed_line_rate_bp: usize,
    min_line_rate_bp: usize,
    min_changed_line_rate_bp: usize,

    pub fn passed(self: CoverageBudget) bool {
        return self.line_rate_bp >= self.min_line_rate_bp and
            (self.min_changed_line_rate_bp == 0 or self.changed_line_rate_bp >= self.min_changed_line_rate_bp);
    }

    pub fn deinit(self: *CoverageBudget, allocator: std.mem.Allocator) void {
        self.coverage.deinit(allocator);
        self.* = undefined;
    }
};

pub fn map(allocator: std.mem.Allocator, request: EvidenceRequest) !coverage_model.CoverageSet {
    return coverage_model.parse(allocator, request.bytes, request.source_kind, request.format);
}

pub fn merge(allocator: std.mem.Allocator, request: MergeRequest) !coverage_model.CoverageSet {
    var left = try map(allocator, request.left);
    defer left.deinit(allocator);
    var right = try map(allocator, request.right);
    defer right.deinit(allocator);
    return coverage_model.merge(allocator, left, right);
}

pub fn diff(allocator: std.mem.Allocator, request: DiffRequest) !CoverageDiff {
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

pub fn budget(allocator: std.mem.Allocator, request: BudgetRequest) !CoverageBudget {
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
