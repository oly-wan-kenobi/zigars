const std = @import("std");
const subject = @import("static_analysis.zig");
const zig_import_graph = subject.zig_import_graph;
const zig_import_graph_json = subject.zig_import_graph_json;
const zig_ast_imports = subject.zig_ast_imports;
const zig_decl_summary = subject.zig_decl_summary;
const zig_decl_summary_json = subject.zig_decl_summary_json;
const zig_ast_decl_summary = subject.zig_ast_decl_summary;
const zig_allocations = subject.zig_allocations;
const zig_error_sets = subject.zig_error_sets;
const zig_public_api = subject.zig_public_api;
const zig_dead_decl_candidates = subject.zig_dead_decl_candidates;
const zig_build_graph = subject.zig_build_graph;
const zig_build_targets = subject.zig_build_targets;
const zig_build_options = subject.zig_build_options;
const zig_file_owner = subject.zig_file_owner;
const zig_import_resolve = subject.zig_import_resolve;
const zig_test_discover = subject.zig_test_discover;
const zig_ast_tests = subject.zig_ast_tests;
const zig_changed_files_plan = subject.zig_changed_files_plan;
const zig_dependency_inspect = subject.zig_dependency_inspect;
const zig_target_matrix_plan = subject.zig_target_matrix_plan;
const zig_test_failure_triage = subject.zig_test_failure_triage;
const zig_workspace_symbol_cache = subject.zig_workspace_symbol_cache;
const zig_package_cache_doctor = subject.zig_package_cache_doctor;
const zig_test_map = subject.zig_test_map;
const zig_test_select = subject.zig_test_select;
const zig_public_api_diff = subject.zig_public_api_diff;

test "static analysis definitions expose import graph metadata" {
    try @import("std").testing.expect(zig_import_graph.description.len > 0);
}
