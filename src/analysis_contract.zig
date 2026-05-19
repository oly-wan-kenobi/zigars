const std = @import("std");
const tool_manifest = @import("tool_manifest.zig");

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
    confidence: Confidence,
    classification: Classification,
    limitations: []const []const u8,
    verify_with: []const []const u8,
};

const text_scan_limits = &.{
    "Scans source text and does not perform full Zig semantic analysis.",
    "Comptime-generated declarations, conditional code, and aliasing can be missed.",
};

const workspace_scan_limits = &.{
    "Walks readable workspace Zig files up to the requested limit.",
    "Ignores generated/cache paths and reports unreadable files separately when supported.",
};

const build_scan_limits = &.{
    "Recognizes common build.zig/build.zig.zon patterns without executing the build script.",
    "Custom helper functions, loops, or comptime build logic can hide modules, artifacts, and options.",
};

const test_scan_limits = &.{
    "Discovers textual test declarations and likely symbol names.",
    "Recommended commands are impact hints, not proof that unaffected tests can be skipped.",
};

const api_diff_limits = &.{
    "Compares public declaration lines by name and signature text.",
    "Does not prove ABI or behavioral compatibility and can miss generated or re-exported API changes.",
};

pub const contracts = [_]Contract{
    .{ .tool = "zig_import_graph", .analysis_kind = "heuristic_import_scan", .confidence = .medium, .classification = .orientation_only, .limitations = workspace_scan_limits, .verify_with = &.{ "zig build test", "ZLS references" } },
    .{ .tool = "zig_import_graph_json", .analysis_kind = "heuristic_import_scan", .confidence = .medium, .classification = .orientation_only, .limitations = workspace_scan_limits, .verify_with = &.{ "zig build test", "ZLS references" } },
    .{ .tool = "zig_decl_summary", .analysis_kind = "heuristic_declaration_scan", .confidence = .medium, .classification = .orientation_only, .limitations = text_scan_limits, .verify_with = &.{ "ZLS document symbols", "zig ast-check" } },
    .{ .tool = "zig_decl_summary_json", .analysis_kind = "heuristic_declaration_scan", .confidence = .medium, .classification = .orientation_only, .limitations = text_scan_limits, .verify_with = &.{ "ZLS document symbols", "zig ast-check" } },
    .{ .tool = "zig_allocations", .analysis_kind = "heuristic_keyword_scan", .confidence = .low, .classification = .orientation_only, .limitations = text_scan_limits, .verify_with = &.{ "code review", "compiler diagnostics" } },
    .{ .tool = "zig_error_sets", .analysis_kind = "heuristic_keyword_scan", .confidence = .low, .classification = .orientation_only, .limitations = text_scan_limits, .verify_with = &.{ "zig ast-check", "ZLS diagnostics" } },
    .{ .tool = "zig_public_api", .analysis_kind = "heuristic_public_decl_scan", .confidence = .medium, .classification = .advisory, .limitations = text_scan_limits, .verify_with = &.{ "ZLS symbols", "release review" } },
    .{ .tool = "zig_dead_decl_candidates", .analysis_kind = "heuristic_private_decl_scan", .confidence = .low, .classification = .orientation_only, .limitations = text_scan_limits, .verify_with = &.{ "ZLS references", "workspace search", "zig build test" } },
    .{ .tool = "zig_build_graph", .analysis_kind = "heuristic_build_file_scan", .confidence = .medium, .classification = .advisory, .limitations = build_scan_limits, .verify_with = &.{ "zig build --help", "zig build test" } },
    .{ .tool = "zig_build_targets", .analysis_kind = "heuristic_build_file_scan", .confidence = .medium, .classification = .advisory, .limitations = build_scan_limits, .verify_with = &.{ "zig build --help", "zig build test" } },
    .{ .tool = "zig_build_options", .analysis_kind = "heuristic_build_option_scan", .confidence = .medium, .classification = .advisory, .limitations = build_scan_limits, .verify_with = &.{"zig build --help"} },
    .{ .tool = "zig_file_owner", .analysis_kind = "heuristic_build_owner_scan", .confidence = .medium, .classification = .advisory, .limitations = build_scan_limits, .verify_with = &.{ "zig build test", "zig test <file>" } },
    .{ .tool = "zig_import_resolve", .analysis_kind = "heuristic_import_resolution", .confidence = .medium, .classification = .advisory, .limitations = build_scan_limits, .verify_with = &.{ "zig build test", "ZLS definition" } },
    .{ .tool = "zig_test_discover", .analysis_kind = "heuristic_test_scan", .confidence = .medium, .classification = .orientation_only, .limitations = test_scan_limits, .verify_with = &.{ "zig test <file>", "zig build test" } },
    .{ .tool = "zig_changed_files_plan", .analysis_kind = "git_status_command_planner", .confidence = .medium, .classification = .advisory, .limitations = &.{"Uses git status and file-name heuristics to recommend validation commands."}, .verify_with = &.{ "zig build test", "project CI" } },
    .{ .tool = "zig_dependency_inspect", .analysis_kind = "heuristic_zon_dependency_scan", .confidence = .medium, .classification = .advisory, .limitations = &.{"Scans build.zig.zon dependency fields without fetching packages."}, .verify_with = &.{ "zig build --fetch", "zig build test" } },
    .{ .tool = "zig_target_matrix_plan", .analysis_kind = "heuristic_target_matrix_plan", .confidence = .medium, .classification = .advisory, .limitations = &.{"Plans candidate commands without running cross-target builds."}, .verify_with = &.{ "zig_matrix_check", "project CI" } },
    .{ .tool = "zig_test_failure_triage", .analysis_kind = "compiler_output_triage", .confidence = .medium, .classification = .advisory, .limitations = &.{"Parses compiler/test output text and may miss custom runner formats."}, .verify_with = &.{ "rerun failing command", "zig_test_select" } },
    .{ .tool = "zig_workspace_symbol_cache", .analysis_kind = "cached_heuristic_symbol_import_scan", .confidence = .medium, .classification = .orientation_only, .limitations = workspace_scan_limits, .verify_with = &.{ "ZLS workspace symbols", "workspace search" } },
    .{ .tool = "zig_package_cache_doctor", .analysis_kind = "package_cache_hygiene_scan", .confidence = .medium, .classification = .advisory, .limitations = &.{"Combines filesystem/git checks with heuristic dependency inspection."}, .verify_with = &.{ "git status", "zig build --fetch" } },
    .{ .tool = "zig_test_map", .analysis_kind = "heuristic_test_declaration_scan", .confidence = .medium, .classification = .orientation_only, .limitations = test_scan_limits, .verify_with = &.{ "zig test <file>", "zig build test" } },
    .{ .tool = "zig_test_select", .analysis_kind = "heuristic_test_impact_selection", .confidence = .low, .classification = .advisory, .limitations = test_scan_limits, .verify_with = &.{ "zig build test", "project CI" } },
    .{ .tool = "zig_public_api_diff", .analysis_kind = "heuristic_public_decl_diff", .confidence = .medium, .classification = .advisory, .limitations = api_diff_limits, .verify_with = &.{ "release review", "zig build test" } },
};

pub fn forTool(tool_name: []const u8) ?Contract {
    for (contracts) |contract| {
        if (std.mem.eql(u8, contract.tool, tool_name)) return contract;
    }
    return null;
}

pub fn putMetadata(allocator: std.mem.Allocator, obj: *std.json.ObjectMap, tool_name: []const u8) !void {
    const contract = forTool(tool_name) orelse return error.UnknownAnalysisContract;
    try obj.put(allocator, "analysis_kind", .{ .string = contract.analysis_kind });
    try obj.put(allocator, "confidence", .{ .string = confidenceName(contract.confidence) });
    try obj.put(allocator, "confidence_class", .{ .string = classificationName(contract.classification) });
    try obj.put(allocator, "limitations", try stringArrayValue(allocator, contract.limitations));
    try obj.put(allocator, "verify_with", try stringArrayValue(allocator, contract.verify_with));
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

test "every static analysis manifest entry has a confidence contract" {
    for (tool_manifest.entries) |entry| {
        if (entry.group != .static_analysis) continue;
        const contract = forTool(entry.name) orelse return error.MissingStaticAnalysisContract;
        try std.testing.expect(contract.analysis_kind.len > 0);
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
