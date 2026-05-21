const std = @import("std");
const tool_manifest = @import("tool_manifest.zig");

pub const CapabilityTier = tool_manifest.StaticAnalysisTier;

pub const Confidence = enum {
    low,
    medium,
    high,
};

pub const Classification = enum {
    orientation_only,
    advisory,
    release_gating_candidate,
};

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

const text_scan_limits = &.{
    "Advisory source-text scan; does not perform Zig parsing or semantic analysis.",
    "Comptime-generated declarations, conditional code, and aliasing can be missed.",
};

const workspace_scan_limits = &.{
    "Advisory workspace text scan; does not perform Zig parsing or semantic analysis.",
    "Walks readable workspace Zig files up to the requested limit.",
    "Ignores generated/cache paths and reports unreadable files separately when supported.",
};

const build_scan_limits = &.{
    "Advisory build-file text scan; does not execute or semantically evaluate build.zig.",
    "Custom helper functions, loops, or comptime build logic can hide modules, artifacts, and options.",
};

const test_scan_limits = &.{
    "Advisory text scan for test declarations and likely symbol names.",
    "Recommended commands are impact hints, not proof that unaffected tests can be skipped.",
};

const api_diff_limits = &.{
    "Compares public declaration lines by name and signature text.",
    "Does not prove ABI or behavioral compatibility and can miss generated or re-exported API changes.",
};

const parser_limits = &.{
    "Parser-backed syntax view only; does not resolve imports, aliases, conditional compilation, or semantic references.",
    "Parse errors are reported and can make the result partial until `zig ast-check` succeeds.",
};

const compiler_output_limits = &.{
    "Backed by compiler/test output when a command is run, or by caller-supplied transcript text.",
    "Custom test runners or truncated output can hide failures.",
};

const zwanzig_limits = &.{
    "Requires an optional configured zwanzig executable; zigar does not bundle or require the backend.",
    "Rule coverage, false positives, and graph support depend on the installed zwanzig version and configuration.",
};

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
    .{ .tool = "zig_lint", .analysis_kind = "optional_zwanzig_lint_json", .tier = .zwanzig_backed, .confidence = .high, .classification = .release_gating_candidate, .source_coverage = zwanzig_output_coverage, .limitations = zwanzig_limits, .verify_with = &.{"configured zwanzig --help"} },
    .{ .tool = "zig_lint_sarif", .analysis_kind = "optional_zwanzig_lint_sarif", .tier = .zwanzig_backed, .confidence = .high, .classification = .release_gating_candidate, .source_coverage = zwanzig_output_coverage, .limitations = zwanzig_limits, .verify_with = &.{"configured zwanzig --help"} },
    .{ .tool = "zig_lint_rules", .analysis_kind = "optional_zwanzig_rule_catalog", .tier = .zwanzig_backed, .confidence = .medium, .classification = .advisory, .source_coverage = zwanzig_output_coverage, .limitations = zwanzig_limits, .verify_with = &.{"configured zwanzig --help"} },
    .{ .tool = "zig_analysis_graphs", .analysis_kind = "optional_zwanzig_analysis_graph", .tier = .zwanzig_backed, .confidence = .high, .classification = .advisory, .source_coverage = zwanzig_output_coverage, .limitations = zwanzig_limits, .verify_with = &.{"configured zwanzig graph mode"} },
};

pub fn forTool(tool_name: []const u8) ?Contract {
    for (contracts) |contract| {
        if (std.mem.eql(u8, contract.tool, tool_name)) return contract;
    }
    return null;
}

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

pub fn capabilityTierName(tier: CapabilityTier) []const u8 {
    return @tagName(tier);
}

pub fn confidenceName(confidence: Confidence) []const u8 {
    return @tagName(confidence);
}

pub fn classificationName(classification: Classification) []const u8 {
    return @tagName(classification);
}

fn stringArrayValue(allocator: std.mem.Allocator, values: []const []const u8) !std.json.Value {
    var array = std.json.Array.init(allocator);
    errdefer array.deinit();
    for (values) |value| try array.append(.{ .string = value });
    return .{ .array = array };
}

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

fn isStaticAnalysisProductGroup(group: tool_manifest.ToolGroup) bool {
    return group == .static_analysis or group == .zwanzig;
}

test "every static analysis product manifest entry has tier and confidence contract" {
    for (tool_manifest.entries) |entry| {
        if (!isStaticAnalysisProductGroup(entry.group)) continue;
        const tier = entry.static_analysis_tier orelse return error.MissingStaticAnalysisTier;
        const contract = forTool(entry.name) orelse return error.MissingStaticAnalysisContract;
        try std.testing.expectEqual(tier, contract.tier);
        try std.testing.expect(contract.analysis_kind.len > 0);
        try std.testing.expect(contract.source_coverage.len > 0);
        try std.testing.expect(contract.limitations.len > 0);
        try std.testing.expect(contract.verify_with.len > 0);
    }
}

test "static analysis tools remain read-only and source-safe" {
    for (tool_manifest.entries) |entry| {
        if (entry.group != .static_analysis) continue;
        try std.testing.expect(entry.meta.read_only);
        try std.testing.expect(!entry.risk.writes_source);
    }
}

test "static analysis contracts do not overstate evidence maturity" {
    for (contracts) |contract| switch (contract.tier) {
        .advisory_orientation => {
            try std.testing.expect(contract.confidence != .high);
            try std.testing.expect(contract.classification != .release_gating_candidate);
            const entry = tool_manifest.findEntry(contract.tool).?;
            try std.testing.expect(!contains(entry.meta.description, "release-gating"));
            try std.testing.expect(!contains(entry.meta.description, "release gating"));
            try std.testing.expect(!contains(entry.meta.description, "high confidence"));
        },
        .parser_backed => {
            try std.testing.expectEqual(Confidence.high, contract.confidence);
            try std.testing.expectEqual(Classification.advisory, contract.classification);
            try std.testing.expect(contains(contract.analysis_kind, "parser_backed"));
            try std.testing.expect(contains(contract.source_coverage, "std.zig.Ast"));
            try std.testing.expect(contains(contract.source_coverage, "parse_status"));
            try std.testing.expect(contains(contract.source_coverage, "partial_result"));
            try std.testing.expect(contains(contract.source_coverage, "parse_error_count"));
            try std.testing.expect(anyContains(contract.limitations, "Parse errors"));
            try std.testing.expect(contract.verify_with.len > 0);
            try std.testing.expect(contains(contract.verify_with[0], "zig ast-check"));
        },
        .compiler_backed => {
            try std.testing.expect(contains(contract.source_coverage, "Compiler") or contains(contract.source_coverage, "compiler"));
            try std.testing.expect(anyContains(contract.limitations, "compiler") or anyContains(contract.limitations, "test output"));
        },
        .zls_backed => {
            try std.testing.expect(contains(contract.source_coverage, "ZLS") or anyContains(contract.verify_with, "ZLS"));
        },
        .zwanzig_backed => {
            try std.testing.expect(contains(contract.source_coverage, "zwanzig"));
            try std.testing.expect(anyContains(contract.limitations, "optional configured zwanzig"));
            try std.testing.expect(contract.verify_with.len > 0);
            try std.testing.expect(contains(contract.verify_with[0], "configured zwanzig"));
        },
    };
}

test "release-gating static analysis claims require executable-backed evidence" {
    for (contracts) |contract| {
        if (contract.classification != .release_gating_candidate) continue;
        switch (contract.tier) {
            .compiler_backed, .zwanzig_backed => {},
            else => return error.ReleaseGatingClaimWithoutExecutableEvidence,
        }
        const entry = tool_manifest.findEntry(contract.tool).?;
        try std.testing.expect(entry.risk.executes_backend or entry.risk.executes_project_code);
        try std.testing.expectEqual(Confidence.high, contract.confidence);
        try std.testing.expect(contract.verify_with.len > 0);
        try std.testing.expect(contains(contract.source_coverage, "output") or contains(contract.source_coverage, "Compiler") or contains(contract.source_coverage, "zwanzig"));
    }
}

test "static analysis metadata exposes structured evidence and cross-checks" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    for (contracts) |contract| {
        var obj = std.json.ObjectMap.empty;
        try putMetadata(allocator, &obj, contract.tool);
        const evidence = obj.get("evidence_basis").?.object;
        const cross_check = obj.get("cross_check").?.object;
        try std.testing.expectEqualStrings(contract.analysis_kind, evidence.get("analysis_kind").?.string);
        try std.testing.expectEqualStrings(capabilityTierName(contract.tier), evidence.get("capability_tier").?.string);
        try std.testing.expectEqualStrings(confidenceName(contract.confidence), evidence.get("confidence").?.string);
        try std.testing.expectEqualStrings(classificationName(contract.classification), evidence.get("confidence_class").?.string);
        try std.testing.expect(evidence.get("limitations").?.array.items.len > 0);
        try std.testing.expect(cross_check.get("verify_with").?.array.items.len > 0);
        try std.testing.expectEqual(contract.classification == .release_gating_candidate, cross_check.get("required_for_release_gate").?.bool);
        try std.testing.expectEqualStrings(contract.verify_with[0], cross_check.get("primary").?.string);
        try std.testing.expectEqualStrings(contract.verify_with[0], obj.get("recommended_cross_check").?.string);
    }
}

fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

fn anyContains(values: []const []const u8, needle: []const u8) bool {
    for (values) |value| {
        if (contains(value, needle)) return true;
    }
    return false;
}
