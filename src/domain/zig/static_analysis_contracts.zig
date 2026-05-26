const std = @import("std");

/// Static-analysis capability source advertised to clients.
pub const CapabilityTier = enum {
    advisory_orientation,
    parser_backed,
    compiler_backed,
    zls_backed,
    zlint_backed,
    zwanzig_backed,
};

/// Confidence label attached to analysis contract evidence.
pub const Confidence = enum {
    low,
    medium,
    high,
};

/// How the result should be used in review or release workflows.
pub const Classification = enum {
    orientation_only,
    advisory,
    release_gating_candidate,
};

/// Evidence contract for one static-analysis tool.
pub const Contract = struct {
    tool: []const u8,
    analysis_kind: []const u8,
    tier: CapabilityTier,
    confidence: Confidence,
    classification: Classification,
    source_coverage: []const u8,
    limitations: []const []const u8,
    verify_with: []const []const u8,
};

const single_file_text_coverage = "Single caller-provided Zig source file scanned as text.";
const workspace_text_coverage = "Readable workspace Zig files up to the requested limit; skipped files are reported when supported.";
const build_text_coverage = "Root build.zig/build.zig.zon files scanned as text without executing the build script.";
const parser_file_coverage = "Single caller-provided Zig source file parsed with std.zig.Ast; parse_status, partial_result, and parse_error_count report syntax completeness.";
const git_status_coverage = "Current git status plus workspace file-name checks.";
const compiler_output_coverage = "Compiler/test-runner output from a supplied transcript or a focused Zig command.";
const zwanzig_output_coverage = "Optional zwanzig backend output for the requested workspace path or graph mode.";
const semantic_index_coverage = "Readable workspace Zig files up to the requested limit; declarations/imports/tests are parser-backed where std.zig.Ast can parse the file, with parse_status, partial_result, and parse_error_count carried from parser-backed evidence when available.";
const semantic_impact_coverage = "Readable workspace Zig files up to the requested limit; changed files, diff paths, symbols, imports, declarations, and tests are matched against the std.zig.Ast parser-backed semantic index; parse_status, partial_result, and parse_error_count are preserved with heuristic fallbacks called out explicitly.";
const semantic_refs_coverage = "Readable workspace Zig files up to the requested limit; matching lines are confirmed with optional ZLint --print-ast symbol references when the configured backend supports it, with source-scan fallback.";
const lint_evidence_coverage = "Caller-supplied normalized lint JSON or optional lint backend output, depending on the tool and arguments.";
const zlint_output_coverage = "Optional ZLint backend output for the requested workspace path, normalized into zigar lint findings.";
const zlint_fix_coverage = "Optional ZLint --fix or --fix-dangerously over a workspace-local path, previewed unless apply=true.";

/// Limit value used by text scans operations.
const text_scan_limits = &.{
    "Advisory source-text scan; does not perform Zig parsing or semantic analysis.",
    "Comptime-generated declarations, conditional code, and aliasing can be missed.",
};

/// Limit value used by workspace scans operations.
const workspace_scan_limits = &.{
    "Advisory workspace text scan; does not perform Zig parsing or semantic analysis.",
    "Walks readable workspace Zig files up to the requested limit.",
    "Ignores generated/cache paths and reports unreadable files separately when supported.",
};

/// Limit value used by build scans operations.
const build_scan_limits = &.{
    "Advisory build-file text scan; does not execute or semantically evaluate build.zig.",
    "Custom helper functions, loops, or comptime build logic can hide modules, artifacts, and options.",
};

/// Limit value used by test scans operations.
const test_scan_limits = &.{
    "Advisory text scan for test declarations and likely symbol names.",
    "Recommended commands are impact hints, not proof that unaffected tests can be skipped.",
};

/// Limit value used by api diffs operations.
const api_diff_limits = &.{
    "Compares public declaration lines by name and signature text.",
    "Does not prove ABI or behavioral compatibility and can miss generated or re-exported API changes.",
};

/// Limit value used by parsers operations.
const parser_limits = &.{
    "Parser-backed syntax view only; does not resolve imports, aliases, conditional compilation, or semantic references.",
    "Parse errors are reported and can make the result partial until `zig ast-check` succeeds.",
};

/// Limit value used by compiler outputs operations.
const compiler_output_limits = &.{
    "Backed by compiler/test output when a command is run, or by caller-supplied transcript text.",
    "Custom test runners or truncated output can hide failures.",
};

/// Limit value used by zwanzigs operations.
const zwanzig_limits = &.{
    "Requires an optional configured zwanzig executable; zigar does not bundle or require the backend.",
    "Rule coverage, false positives, and graph support depend on the installed zwanzig version and configuration.",
};

/// Limit value used by semantic indexs operations.
const semantic_index_limits = &.{
    "Parser-backed syntax view plus source-scan evidence; it does not resolve comptime execution, aliases, or conditional imports.",
    "Parse errors are reported through parser metadata when available and can make file-level evidence partial.",
    "Workspace walks are bounded by the requested limit and skip generated/cache paths.",
};

/// Limit value used by semantic impacts operations.
const semantic_impact_limits = &.{
    "Advisory impact and test-selection evidence; it does not prove that unselected tests can be skipped.",
    "Parse errors are reported through parser metadata when available and can make file-level impact evidence partial.",
    "Import matching uses parser-backed import declarations plus path/basename matching and can miss generated, aliased, or comptime-selected dependencies.",
    "Release decisions still require compiler-backed validation such as zig build test or project CI.",
};

/// Limit value used by semantic refss operations.
const semantic_refs_limits = &.{
    "ZLint symbol-reference evidence is used when the configured backend exposes --print-ast; otherwise results fall back to source scans.",
    "Locations are still reported from matching source lines and can include textual matches that require review.",
    "Does not execute comptime code or prove cross-module alias resolution.",
};

/// Limit value used by lint intelligences operations.
const lint_intelligence_limits = &.{
    "Compares normalized lint evidence by stable rule/path/line fingerprints and cannot prove semantic correctness by itself.",
    "Gate and trend outputs are policy decisions over observed findings, not compiler or runtime proof.",
};

/// Limit value used by zlints operations.
const zlint_limits = &.{
    "Requires an optional configured ZLint executable; zigar does not bundle or require the backend.",
    "Rule coverage, false positives, and output shape depend on the installed ZLint version and configuration.",
};

/// Limit value used by zlint fixs operations.
const zlint_fix_limits = &.{
    "Requires an optional configured ZLint executable with --fix support; zigar does not implement the edits itself.",
    "Runs only when apply=true and the selected path resolves inside the workspace.",
    "dangerous=true delegates to ZLint --fix-dangerously and should be followed by git diff review and tests.",
};

/// Static-analysis contracts rendered into tool results and catalog metadata.
pub const contracts = [_]Contract{
    .{ .tool = "zig_import_graph", .analysis_kind = "heuristic_import_scan", .tier = .advisory_orientation, .confidence = .medium, .classification = .orientation_only, .source_coverage = workspace_text_coverage, .limitations = workspace_scan_limits, .verify_with = &.{ "zig_ast_imports", "zig build test", "ZLS references" } },
    .{ .tool = "zig_import_graph_json", .analysis_kind = "heuristic_import_scan", .tier = .advisory_orientation, .confidence = .medium, .classification = .orientation_only, .source_coverage = workspace_text_coverage, .limitations = workspace_scan_limits, .verify_with = &.{ "zig_ast_imports", "zig build test", "ZLS references" } },
    .{ .tool = "zig_ast_imports", .analysis_kind = "parser_backed_import_scan", .tier = .parser_backed, .confidence = .high, .classification = .advisory, .source_coverage = parser_file_coverage, .limitations = parser_limits, .verify_with = &.{ "zig ast-check <file>", "zig build test" } },
    .{ .tool = "zig_decl_summary", .analysis_kind = "heuristic_declaration_scan", .tier = .advisory_orientation, .confidence = .medium, .classification = .orientation_only, .source_coverage = single_file_text_coverage, .limitations = text_scan_limits, .verify_with = &.{ "zig_ast_decl_summary", "ZLS document symbols", "zig ast-check" } },
    .{ .tool = "zig_decl_summary_json", .analysis_kind = "heuristic_declaration_scan", .tier = .advisory_orientation, .confidence = .medium, .classification = .orientation_only, .source_coverage = single_file_text_coverage, .limitations = text_scan_limits, .verify_with = &.{ "zig_ast_decl_summary", "ZLS document symbols", "zig ast-check" } },
    .{ .tool = "zig_ast_decl_summary", .analysis_kind = "parser_backed_declaration_scan", .tier = .parser_backed, .confidence = .high, .classification = .advisory, .source_coverage = parser_file_coverage, .limitations = parser_limits, .verify_with = &.{ "zig ast-check <file>", "ZLS document symbols" } },
    .{ .tool = "zig_allocations", .analysis_kind = "heuristic_keyword_scan", .tier = .advisory_orientation, .confidence = .low, .classification = .orientation_only, .source_coverage = single_file_text_coverage, .limitations = text_scan_limits, .verify_with = &.{ "code review", "compiler diagnostics" } },
    .{ .tool = "zig_error_sets", .analysis_kind = "heuristic_keyword_scan", .tier = .advisory_orientation, .confidence = .low, .classification = .orientation_only, .source_coverage = single_file_text_coverage, .limitations = text_scan_limits, .verify_with = &.{ "zig ast-check", "ZLS diagnostics" } },
    .{ .tool = "zig_public_api", .analysis_kind = "heuristic_public_decl_scan", .tier = .advisory_orientation, .confidence = .medium, .classification = .advisory, .source_coverage = single_file_text_coverage, .limitations = text_scan_limits, .verify_with = &.{ "zig_ast_decl_summary", "ZLS symbols", "release review" } },
    .{ .tool = "zig_dead_decl_candidates", .analysis_kind = "heuristic_private_decl_scan", .tier = .advisory_orientation, .confidence = .low, .classification = .orientation_only, .source_coverage = single_file_text_coverage, .limitations = text_scan_limits, .verify_with = &.{ "ZLS references", "workspace search", "zig build test" } },
    .{ .tool = "zig_build_graph", .analysis_kind = "heuristic_build_file_scan", .tier = .advisory_orientation, .confidence = .medium, .classification = .advisory, .source_coverage = build_text_coverage, .limitations = build_scan_limits, .verify_with = &.{ "zig build --help", "zig build test" } },
    .{ .tool = "zig_build_targets", .analysis_kind = "heuristic_build_file_scan", .tier = .advisory_orientation, .confidence = .medium, .classification = .advisory, .source_coverage = build_text_coverage, .limitations = build_scan_limits, .verify_with = &.{ "zig build --help", "zig build test" } },
    .{ .tool = "zig_build_options", .analysis_kind = "heuristic_build_option_scan", .tier = .advisory_orientation, .confidence = .medium, .classification = .advisory, .source_coverage = build_text_coverage, .limitations = build_scan_limits, .verify_with = &.{"zig build --help"} },
    .{ .tool = "zig_file_owner", .analysis_kind = "heuristic_build_owner_scan", .tier = .advisory_orientation, .confidence = .medium, .classification = .advisory, .source_coverage = build_text_coverage, .limitations = build_scan_limits, .verify_with = &.{ "zig build test", "zig test <file>" } },
    .{ .tool = "zig_import_resolve", .analysis_kind = "heuristic_import_resolution", .tier = .advisory_orientation, .confidence = .medium, .classification = .advisory, .source_coverage = build_text_coverage, .limitations = build_scan_limits, .verify_with = &.{ "zig build test", "ZLS definition" } },
    .{ .tool = "zig_test_discover", .analysis_kind = "heuristic_test_scan", .tier = .advisory_orientation, .confidence = .medium, .classification = .orientation_only, .source_coverage = workspace_text_coverage, .limitations = test_scan_limits, .verify_with = &.{ "zig_ast_tests", "zig test <file>", "zig build test" } },
    .{ .tool = "zig_ast_tests", .analysis_kind = "parser_backed_test_scan", .tier = .parser_backed, .confidence = .high, .classification = .advisory, .source_coverage = parser_file_coverage, .limitations = parser_limits, .verify_with = &.{ "zig ast-check <file>", "zig test <file>" } },
    .{ .tool = "zig_changed_files_plan", .analysis_kind = "git_status_command_planner", .tier = .advisory_orientation, .confidence = .medium, .classification = .advisory, .source_coverage = git_status_coverage, .limitations = &.{"Uses git status and file-name heuristics to recommend validation commands."}, .verify_with = &.{ "zig build test", "project CI" } },
    .{ .tool = "zig_dependency_inspect", .analysis_kind = "heuristic_zon_dependency_scan", .tier = .advisory_orientation, .confidence = .medium, .classification = .advisory, .source_coverage = build_text_coverage, .limitations = &.{"Scans build.zig.zon dependency fields without fetching packages."}, .verify_with = &.{ "zig build --fetch", "zig build test" } },
    .{ .tool = "zig_target_matrix_plan", .analysis_kind = "heuristic_target_matrix_plan", .tier = .advisory_orientation, .confidence = .medium, .classification = .advisory, .source_coverage = "Configured target/step text arguments only; no builds are executed.", .limitations = &.{"Plans candidate commands without running cross-target builds."}, .verify_with = &.{ "zig_matrix_check", "project CI" } },
    .{ .tool = "zig_test_failure_triage", .analysis_kind = "compiler_output_triage", .tier = .compiler_backed, .confidence = .medium, .classification = .advisory, .source_coverage = compiler_output_coverage, .limitations = compiler_output_limits, .verify_with = &.{ "rerun failing command", "zig_test_select" } },
    .{ .tool = "zig_workspace_symbol_cache", .analysis_kind = "cached_heuristic_symbol_import_scan", .tier = .advisory_orientation, .confidence = .medium, .classification = .orientation_only, .source_coverage = workspace_text_coverage, .limitations = workspace_scan_limits, .verify_with = &.{ "ZLS workspace symbols", "workspace search" } },
    .{ .tool = "zig_package_cache_doctor", .analysis_kind = "package_cache_hygiene_scan", .tier = .advisory_orientation, .confidence = .medium, .classification = .advisory, .source_coverage = "Filesystem/git checks plus build.zig.zon text inspection when present.", .limitations = &.{"Combines filesystem/git checks with heuristic dependency inspection."}, .verify_with = &.{ "git status", "zig build --fetch" } },
    .{ .tool = "zig_test_map", .analysis_kind = "heuristic_test_declaration_scan", .tier = .advisory_orientation, .confidence = .medium, .classification = .orientation_only, .source_coverage = workspace_text_coverage, .limitations = test_scan_limits, .verify_with = &.{ "zig_ast_tests", "zig test <file>", "zig build test" } },
    .{ .tool = "zig_test_select", .analysis_kind = "heuristic_test_impact_selection", .tier = .advisory_orientation, .confidence = .low, .classification = .advisory, .source_coverage = workspace_text_coverage, .limitations = test_scan_limits, .verify_with = &.{ "zig build test", "project CI" } },
    .{ .tool = "zig_public_api_diff", .analysis_kind = "heuristic_public_decl_diff", .tier = .advisory_orientation, .confidence = .medium, .classification = .advisory, .source_coverage = "Before/after source text or git-show baseline compared by public declaration line.", .limitations = api_diff_limits, .verify_with = &.{ "zig_ast_decl_summary", "release review", "zig build test" } },
    .{ .tool = "zig_semantic_index_build", .analysis_kind = "parser_backed_semantic_workspace_index", .tier = .parser_backed, .confidence = .high, .classification = .advisory, .source_coverage = semantic_index_coverage, .limitations = semantic_index_limits, .verify_with = &.{ "zig ast-check", "ZLS workspace symbols", "zig build test" } },
    .{ .tool = "zig_semantic_index_status", .analysis_kind = "semantic_index_cache_status", .tier = .advisory_orientation, .confidence = .medium, .classification = .orientation_only, .source_coverage = "In-memory semantic index cache metadata for the current zigar process.", .limitations = &.{"Status reports cache state only; it does not refresh or validate source semantics."}, .verify_with = &.{"zig_semantic_index_refresh"} },
    .{ .tool = "zig_semantic_index_refresh", .analysis_kind = "parser_backed_semantic_workspace_index", .tier = .parser_backed, .confidence = .high, .classification = .advisory, .source_coverage = semantic_index_coverage, .limitations = semantic_index_limits, .verify_with = &.{ "zig ast-check", "ZLS workspace symbols", "zig build test" } },
    .{ .tool = "zig_semantic_query", .analysis_kind = "parser_backed_semantic_index_query", .tier = .parser_backed, .confidence = .high, .classification = .advisory, .source_coverage = semantic_index_coverage, .limitations = semantic_index_limits, .verify_with = &.{ "zig ast-check", "ZLS definition/references", "workspace search" } },
    .{ .tool = "zig_semantic_refs", .analysis_kind = "zlint_confirmed_reference_scan", .tier = .advisory_orientation, .confidence = .medium, .classification = .orientation_only, .source_coverage = semantic_refs_coverage, .limitations = semantic_refs_limits, .verify_with = &.{ "ZLS references", "zig build test" } },
    .{ .tool = "zig_semantic_decl", .analysis_kind = "parser_backed_declaration_lookup", .tier = .parser_backed, .confidence = .high, .classification = .advisory, .source_coverage = semantic_index_coverage, .limitations = semantic_index_limits, .verify_with = &.{ "zig ast-check", "ZLS definition" } },
    .{ .tool = "zig_semantic_callers", .analysis_kind = "zlint_confirmed_call_site_scan", .tier = .advisory_orientation, .confidence = .medium, .classification = .orientation_only, .source_coverage = semantic_refs_coverage, .limitations = semantic_refs_limits, .verify_with = &.{ "ZLS references", "code review" } },
    .{ .tool = "zig_static_fusion", .analysis_kind = "multi_source_static_confidence_fusion", .tier = .advisory_orientation, .confidence = .medium, .classification = .advisory, .source_coverage = "Semantic index and optional normalized linter evidence supplied by the caller.", .limitations = lint_intelligence_limits, .verify_with = &.{ "zig build test", "ZLS", "configured linters" } },
    .{ .tool = "zig_code_index_export", .analysis_kind = "parser_backed_code_index_export", .tier = .parser_backed, .confidence = .high, .classification = .advisory, .source_coverage = semantic_index_coverage, .limitations = semantic_index_limits, .verify_with = &.{ "zig ast-check", "zig_semantic_index_build", "consumer schema validation" } },
    .{ .tool = "zig_scip_export", .analysis_kind = "parser_backed_scip_like_export", .tier = .parser_backed, .confidence = .high, .classification = .advisory, .source_coverage = semantic_index_coverage, .limitations = semantic_index_limits, .verify_with = &.{ "zig ast-check", "zig_semantic_index_build", "SCIP consumer validation" } },
    .{ .tool = "zig_zlint", .analysis_kind = "optional_zlint_diagnostics", .tier = .zlint_backed, .confidence = .high, .classification = .release_gating_candidate, .source_coverage = zlint_output_coverage, .limitations = zlint_limits, .verify_with = &.{"configured ZLint --help"} },
    .{ .tool = "zig_zlint_sarif", .analysis_kind = "optional_zlint_sarif_export", .tier = .zlint_backed, .confidence = .high, .classification = .release_gating_candidate, .source_coverage = zlint_output_coverage, .limitations = zlint_limits, .verify_with = &.{"configured ZLint --help"} },
    .{ .tool = "zig_zlint_rules", .analysis_kind = "optional_zlint_rule_catalog", .tier = .zlint_backed, .confidence = .medium, .classification = .advisory, .source_coverage = zlint_output_coverage, .limitations = zlint_limits, .verify_with = &.{"configured ZLint --help"} },
    .{ .tool = "zig_zlint_fix", .analysis_kind = "optional_zlint_apply_gated_fix", .tier = .zlint_backed, .confidence = .medium, .classification = .advisory, .source_coverage = zlint_fix_coverage, .limitations = zlint_fix_limits, .verify_with = &.{ "configured ZLint --help", "git diff", "zig build test" } },
    .{ .tool = "zig_lint_compare", .analysis_kind = "dual_linter_consensus_comparison", .tier = .advisory_orientation, .confidence = .medium, .classification = .advisory, .source_coverage = lint_evidence_coverage, .limitations = lint_intelligence_limits, .verify_with = &.{ "zig_zlint", "zig_lint" } },
    .{ .tool = "zig_lint_profile", .analysis_kind = "lint_gate_profile_policy", .tier = .advisory_orientation, .confidence = .medium, .classification = .orientation_only, .source_coverage = "Built-in lint gate profile policy table.", .limitations = &.{"Profiles are policy presets; they do not inspect source or run linters."}, .verify_with = &.{"zig_lint_gate"} },
    .{ .tool = "zig_lint_gate", .analysis_kind = "lint_findings_policy_gate", .tier = .advisory_orientation, .confidence = .medium, .classification = .advisory, .source_coverage = lint_evidence_coverage, .limitations = lint_intelligence_limits, .verify_with = &.{ "configured linters", "project CI" } },
    .{ .tool = "zig_lint_fix_plan", .analysis_kind = "lint_fix_planning", .tier = .advisory_orientation, .confidence = .low, .classification = .orientation_only, .source_coverage = lint_evidence_coverage, .limitations = &.{"Produces planning buckets over observed findings; source edits are delegated to apply-gated fix tools such as zig_zlint_fix."}, .verify_with = &.{ "code review", "zig build test" } },
    .{ .tool = "zig_lint_baseline", .analysis_kind = "lint_baseline_comparison", .tier = .advisory_orientation, .confidence = .medium, .classification = .advisory, .source_coverage = lint_evidence_coverage, .limitations = lint_intelligence_limits, .verify_with = &.{ "zig_lint_gate", "configured linters" } },
    .{ .tool = "zig_lint_suppressions", .analysis_kind = "lint_suppression_filter", .tier = .advisory_orientation, .confidence = .medium, .classification = .advisory, .source_coverage = lint_evidence_coverage, .limitations = lint_intelligence_limits, .verify_with = &.{ "code review", "configured linters" } },
    .{ .tool = "zig_lint_trend", .analysis_kind = "lint_trend_comparison", .tier = .advisory_orientation, .confidence = .medium, .classification = .advisory, .source_coverage = lint_evidence_coverage, .limitations = lint_intelligence_limits, .verify_with = &.{ "configured linters", "project CI" } },
    .{ .tool = "zig_impact_semantic", .analysis_kind = "parser_backed_semantic_impact", .tier = .parser_backed, .confidence = .high, .classification = .advisory, .source_coverage = semantic_impact_coverage, .limitations = semantic_impact_limits, .verify_with = &.{ "zig ast-check on impacted files", "zig_test_select_semantic", "zigar_validation_plan", "zig build test" } },
    .{ .tool = "zig_test_select_semantic", .analysis_kind = "parser_backed_semantic_test_selection", .tier = .parser_backed, .confidence = .high, .classification = .advisory, .source_coverage = semantic_impact_coverage, .limitations = semantic_impact_limits, .verify_with = &.{ "zig ast-check on selected test files", "zigar_validation_run", "zig build test", "project CI" } },
    .{ .tool = "zig_lint", .analysis_kind = "optional_zwanzig_lint_json", .tier = .zwanzig_backed, .confidence = .high, .classification = .release_gating_candidate, .source_coverage = zwanzig_output_coverage, .limitations = zwanzig_limits, .verify_with = &.{"configured zwanzig --help"} },
    .{ .tool = "zig_lint_sarif", .analysis_kind = "optional_zwanzig_lint_sarif", .tier = .zwanzig_backed, .confidence = .high, .classification = .release_gating_candidate, .source_coverage = zwanzig_output_coverage, .limitations = zwanzig_limits, .verify_with = &.{"configured zwanzig --help"} },
    .{ .tool = "zig_lint_rules", .analysis_kind = "optional_zwanzig_rule_catalog", .tier = .zwanzig_backed, .confidence = .medium, .classification = .advisory, .source_coverage = zwanzig_output_coverage, .limitations = zwanzig_limits, .verify_with = &.{"configured zwanzig --help"} },
    .{ .tool = "zig_analysis_graphs", .analysis_kind = "optional_zwanzig_analysis_graph", .tier = .zwanzig_backed, .confidence = .high, .classification = .advisory, .source_coverage = zwanzig_output_coverage, .limitations = zwanzig_limits, .verify_with = &.{"configured zwanzig graph mode"} },
};

/// Looks up the evidence contract for a tool by exact name.
pub fn forTool(tool_name: []const u8) ?Contract {
    for (contracts) |contract| {
        if (std.mem.eql(u8, contract.tool, tool_name)) return contract;
    }
    return null;
}

/// Adds standardized analysis metadata to a JSON object.
pub fn putMetadata(allocator: std.mem.Allocator, obj: *std.json.ObjectMap, tool_name: []const u8) error{OutOfMemory}!void {
    const contract = forTool(tool_name) orelse unreachable;
    try obj.put(allocator, "analysis_kind", .{ .string = contract.analysis_kind });
    try obj.put(allocator, "capability_tier", .{ .string = capabilityTierName(contract.tier) });
    try obj.put(allocator, "confidence", .{ .string = confidenceName(contract.confidence) });
    try obj.put(allocator, "confidence_class", .{ .string = classificationName(contract.classification) });
    try obj.put(allocator, "source_coverage", .{ .string = contract.source_coverage });
    try obj.put(allocator, "limitations", try stringArrayValue(allocator, contract.limitations));
    try obj.put(allocator, "verify_with", try stringArrayValue(allocator, contract.verify_with));
    try obj.put(allocator, "evidence_basis", try evidenceBasisValue(allocator, contract));
    try obj.put(allocator, "cross_check", try crossCheckValue(allocator, contract));
    if (contract.verify_with.len > 0) try obj.put(allocator, "recommended_cross_check", .{ .string = contract.verify_with[0] });
}

/// Returns the serialized capability-tier token.
pub fn capabilityTierName(tier: CapabilityTier) []const u8 {
    return @tagName(tier);
}

/// Returns the serialized confidence token.
pub fn confidenceName(confidence: Confidence) []const u8 {
    return @tagName(confidence);
}

/// Returns the serialized classification token.
pub fn classificationName(classification: Classification) []const u8 {
    return @tagName(classification);
}

/// Builds a JSON string array from borrowed string slices.
fn stringArrayValue(allocator: std.mem.Allocator, values: []const []const u8) !std.json.Value {
    var array = std.json.Array.init(allocator);
    errdefer array.deinit();
    for (values) |value| try array.append(.{ .string = value });
    return .{ .array = array };
}

/// Builds JSON evidence-basis metadata for a static-analysis contract.
fn evidenceBasisValue(allocator: std.mem.Allocator, contract: Contract) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "analysis_kind", .{ .string = contract.analysis_kind });
    try obj.put(allocator, "capability_tier", .{ .string = capabilityTierName(contract.tier) });
    try obj.put(allocator, "confidence", .{ .string = confidenceName(contract.confidence) });
    try obj.put(allocator, "confidence_class", .{ .string = classificationName(contract.classification) });
    try obj.put(allocator, "source_coverage", .{ .string = contract.source_coverage });
    try obj.put(allocator, "limitations", try stringArrayValue(allocator, contract.limitations));
    return .{ .object = obj };
}

/// Builds JSON cross-check metadata for a static-analysis contract.
fn crossCheckValue(allocator: std.mem.Allocator, contract: Contract) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "required_for_release_gate", .{ .bool = contract.classification == .release_gating_candidate });
    if (contract.verify_with.len > 0) {
        try obj.put(allocator, "primary", .{ .string = contract.verify_with[0] });
    } else {
        try obj.put(allocator, "primary", .null);
    }
    try obj.put(allocator, "verify_with", try stringArrayValue(allocator, contract.verify_with));
    return .{ .object = obj };
}

test "static analysis contract lookup and empty verification fallback are explicit" {
    try std.testing.expect(forTool("missing_tool") == null);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const value = try crossCheckValue(allocator, .{
        .tool = "test",
        .analysis_kind = "unit",
        .tier = .advisory_orientation,
        .confidence = .medium,
        .classification = .advisory,
        .source_coverage = "unit",
        .limitations = &.{"limited"},
        .verify_with = &.{},
    });
    try std.testing.expect(value.object.get("primary").? == .null);
}

/// Returns whether any string in a slice equals the needle.
fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

/// Returns whether any haystack contains any supplied needle.
fn anyContains(values: []const []const u8, needle: []const u8) bool {
    for (values) |value| {
        if (contains(value, needle)) return true;
    }
    return false;
}
