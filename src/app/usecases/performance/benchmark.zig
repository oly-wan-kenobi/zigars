//! Performance benchmark use-case adapters for parse/compare/budget/profile planning flows.
const std = @import("std");

const benchmark_model = @import("../../../domain/performance/benchmark_model.zig");

/// Carries evidence request data across use case and port boundaries.
pub const EvidenceRequest = struct {
    bytes: []const u8,
    source_kind: []const u8,
};

/// Carries compare request data across use case and port boundaries.
pub const CompareRequest = struct {
    current: EvidenceRequest,
    baseline: EvidenceRequest,
    /// Per-benchmark regression tolerance, in percent of baseline ns/iter; a sample
    /// counts as a regression only once it slows down by more than this much.
    threshold_pct: i64 = 5,
};

/// Carries budget request data across use case and port boundaries.
pub const BudgetRequest = struct {
    /// Pre-computed benchmark comparison JSON (output of `compare`), parsed for a summary.
    comparison: []const u8,
    /// Gate ceiling: a budget passes only if the worst regression is within this percent.
    max_regression_pct: f64 = 5,
};

/// Carries profile regression request data across use case and port boundaries.
pub const ProfileRegressionRequest = struct {
    comparison: []const u8,
    backend: []const u8 = "samply",
};

/// Carries budget result data across use case and port boundaries.
pub const BudgetResult = struct {
    summary: benchmark_model.CompareSummary,
    max_regression_pct: f64,

    /// True when the comparison's worst regression stays within `max_regression_pct`.
    pub fn passed(self: BudgetResult) bool {
        return benchmark_model.budgetPassed(self.summary, self.max_regression_pct);
    }
};

/// Carries profile regression plan data across use case and port boundaries.
pub const ProfileRegressionPlan = struct {
    summary: benchmark_model.CompareSummary,
    backend: []const u8,

    /// True when at least one benchmark regressed, i.e. focused profiling is worthwhile.
    pub fn needsProfile(self: ProfileRegressionPlan) bool {
        return self.summary.regression_count > 0;
    }

    /// Ordered zigars tool ids to drive the follow-up profiling, selected by backend
    /// (Tracy vs. the default samply/perf path). Returns a static slice; no allocation.
    pub fn recommendedTools(self: ProfileRegressionPlan) []const []const u8 {
        if (std.mem.eql(u8, self.backend, "tracy")) {
            return &.{ "zig_tracy_plan", "zig_tracy_capture", "zig_tracy_hints" };
        }
        return &.{ "zig_samply_record", "zig_samply_summary", "zig_perf_evidence_pack" };
    }
};

/// Parses benchmark input using caller-provided storage; malformed input and allocation failures propagate.
pub fn parse(allocator: std.mem.Allocator, request: EvidenceRequest) !benchmark_model.BenchSet {
    return benchmark_model.parseEvidence(allocator, request.bytes, request.source_kind);
}

/// Parses both evidence blobs and classifies each shared benchmark as regression or
/// improvement against `threshold_pct`. The two parsed sets are scratch and freed here.
pub fn compare(allocator: std.mem.Allocator, request: CompareRequest) !benchmark_model.BenchComparison {
    // Returned comparison owns allocated slices; caller deinitializes it.
    var current = try parse(allocator, request.current);
    defer current.deinit(allocator);
    var baseline = try parse(allocator, request.baseline);
    defer baseline.deinit(allocator);
    return benchmark_model.compare(allocator, current, baseline, request.threshold_pct);
}

/// Summarizes a prior comparison JSON into pass/fail against `max_regression_pct`.
/// Pairs the parsed summary with the threshold so `BudgetResult.passed()` can decide.
pub fn budget(allocator: std.mem.Allocator, request: BudgetRequest) !BudgetResult {
    return .{
        .summary = try benchmark_model.compareSummaryFromJson(allocator, request.comparison),
        .max_regression_pct = request.max_regression_pct,
    };
}

/// Implements plan profile regression workflow logic using caller-owned inputs.
pub fn planProfileRegression(allocator: std.mem.Allocator, request: ProfileRegressionRequest) !ProfileRegressionPlan {
    return .{
        .summary = try benchmark_model.compareSummaryFromJson(allocator, request.comparison),
        .backend = request.backend,
    };
}
