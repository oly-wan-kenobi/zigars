//! Performance benchmark use-case adapters for parse/compare/budget/profile planning flows.
const std = @import("std");

const benchmark_model = @import("../../../domain/performance/benchmark_model.zig");

pub const EvidenceRequest = struct {
    bytes: []const u8,
    source_kind: []const u8,
};

pub const CompareRequest = struct {
    current: EvidenceRequest,
    baseline: EvidenceRequest,
    threshold_pct: i64 = 5,
};

pub const BudgetRequest = struct {
    comparison: []const u8,
    max_regression_pct: f64 = 5,
};

pub const ProfileRegressionRequest = struct {
    comparison: []const u8,
    backend: []const u8 = "samply",
};

pub const BudgetResult = struct {
    summary: benchmark_model.CompareSummary,
    max_regression_pct: f64,

    pub fn passed(self: BudgetResult) bool {
        return benchmark_model.budgetPassed(self.summary, self.max_regression_pct);
    }
};

pub const ProfileRegressionPlan = struct {
    summary: benchmark_model.CompareSummary,
    backend: []const u8,

    pub fn needsProfile(self: ProfileRegressionPlan) bool {
        return self.summary.regression_count > 0;
    }

    pub fn recommendedTools(self: ProfileRegressionPlan) []const []const u8 {
        if (std.mem.eql(u8, self.backend, "tracy")) {
            return &.{ "zig_tracy_plan", "zig_tracy_capture", "zig_tracy_hints" };
        }
        return &.{ "zig_samply_record", "zig_samply_summary", "zig_perf_evidence_pack" };
    }
};

pub fn parse(allocator: std.mem.Allocator, request: EvidenceRequest) !benchmark_model.BenchSet {
    return benchmark_model.parseEvidence(allocator, request.bytes, request.source_kind);
}

pub fn compare(allocator: std.mem.Allocator, request: CompareRequest) !benchmark_model.BenchComparison {
    // Returned comparison owns allocated slices; caller deinitializes it.
    var current = try parse(allocator, request.current);
    defer current.deinit(allocator);
    var baseline = try parse(allocator, request.baseline);
    defer baseline.deinit(allocator);
    return benchmark_model.compare(allocator, current, baseline, request.threshold_pct);
}

pub fn budget(allocator: std.mem.Allocator, request: BudgetRequest) !BudgetResult {
    return .{
        .summary = try benchmark_model.compareSummaryFromJson(allocator, request.comparison),
        .max_regression_pct = request.max_regression_pct,
    };
}

pub fn planProfileRegression(allocator: std.mem.Allocator, request: ProfileRegressionRequest) !ProfileRegressionPlan {
    return .{
        .summary = try benchmark_model.compareSummaryFromJson(allocator, request.comparison),
        .backend = request.backend,
    };
}
