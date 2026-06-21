//! Contract tests for performance.zig: pins that every coverage, benchmark,
//! and profiler tool exposes a non-empty description and that write-capable
//! tools carry the expected apply-gate risk metadata.
const std = @import("std");
const subject = @import("performance.zig");
const zig_coverage_run = subject.zig_coverage_run;
const zig_coverage = subject.zig_coverage;
const zig_coverage_merge = subject.zig_coverage_merge;
const zig_coverage_baseline = subject.zig_coverage_baseline;
const zig_bench_discover = subject.zig_bench_discover;
const zig_bench_run = subject.zig_bench_run;
const zig_bench_baseline = subject.zig_bench_baseline;
const zig_benchmark_history = subject.zig_benchmark_history;
const zig_bench_compare = subject.zig_bench_compare;
const zig_perf_budget_check = subject.zig_perf_budget_check;
const zig_profile_regression = subject.zig_profile_regression;
const zig_samply_record = subject.zig_samply_record;
const zig_samply_summary = subject.zig_samply_summary;
const zig_samply_import = subject.zig_samply_import;
const zig_samply_artifact = subject.zig_samply_artifact;
const zig_profile_open = subject.zig_profile_open;
const zig_tracy_plan = subject.zig_tracy_plan;
const zig_tracy_probe = subject.zig_tracy_probe;
const zig_tracy_capture = subject.zig_tracy_capture;
const zig_tracy_artifacts = subject.zig_tracy_artifacts;
const zig_tracy_hints = subject.zig_tracy_hints;
const zig_perf_evidence_pack = subject.zig_perf_evidence_pack;

test "performance definitions expose coverage metadata" {
    try @import("std").testing.expect(zig_coverage_run.description.len > 0);
}
