const std = @import("std");
const subject = @import("static_evidence.zig");
const zig_semantic_index_build = subject.zig_semantic_index_build;
const zig_semantic_index_status = subject.zig_semantic_index_status;
const zig_semantic_index_refresh = subject.zig_semantic_index_refresh;
const zig_semantic_query = subject.zig_semantic_query;
const zig_semantic_refs = subject.zig_semantic_refs;
const zig_semantic_decl = subject.zig_semantic_decl;
const zig_semantic_callers = subject.zig_semantic_callers;
const zig_static_fusion = subject.zig_static_fusion;
const zig_code_index_export = subject.zig_code_index_export;
const zig_scip_export = subject.zig_scip_export;
const zig_zlint = subject.zig_zlint;
const zig_zlint_sarif = subject.zig_zlint_sarif;
const zig_zlint_rules = subject.zig_zlint_rules;
const zig_zlint_fix = subject.zig_zlint_fix;
const zig_lint_compare = subject.zig_lint_compare;
const zig_lint_profile = subject.zig_lint_profile;
const zig_lint_gate = subject.zig_lint_gate;
const zig_lint_fix_plan = subject.zig_lint_fix_plan;
const zig_lint_baseline = subject.zig_lint_baseline;
const zig_lint_suppressions = subject.zig_lint_suppressions;
const zig_lint_trend = subject.zig_lint_trend;

test "static evidence definitions expose semantic index metadata" {
    try @import("std").testing.expect(zig_semantic_index_build.description.len > 0);
}
