const std = @import("std");
const zigar = @import("zigar");

const Io = std.Io;
const Allocator = std.mem.Allocator;

pub fn checkStaticAnalysisDocs(allocator: Allocator, io: Io) !bool {
    var ok = true;
    ok = (try checkDocNeedles(allocator, io, "docs/tools.md", &.{
        "capability_tier",
        "advisory_orientation",
        "parser_backed",
        "zlint_backed",
        "zwanzig_backed",
        "zig_semantic_index_build",
        "zig_zlint",
        "zig_zlint_fix",
        "zig_lint_compare",
        "evidence_basis",
        "cross_check",
        "parse_status",
        "partial_result",
        "optional ZLint/zwanzig-backed",
        "zig_dead_decl_candidates",
        "reference checks before deletion",
        "zig_public_api_diff",
        "comparison basis",
        "zig_test_select",
        "recommendations",
    })) and ok;
    ok = (try checkDocNeedles(allocator, io, "docs/tool-index.generated.md", &.{
        "## Static Analysis Capability Tiers",
        "zig_ast_decl_summary",
        "parser_backed",
        "zig_lint",
        "zwanzig_backed",
    })) and ok;
    return ok;
}

pub fn checkCommandRunningToolDocs(allocator: Allocator, io: Io) !bool {
    const path = "README.md";
    const bytes = readFileAlloc(allocator, io, path, 1024 * 1024) catch |err| {
        try stderrPrint(io, "command-running tool docs check could not read {s}: {s}\n", .{ path, @errorName(err) });
        return false;
    };
    defer allocator.free(bytes);
    var ok = std.mem.indexOf(u8, bytes, "without a shell") != null and
        std.mem.indexOf(u8, bytes, "MCP `readOnlyHint`") != null;
    for (zigar.tool_metadata.entries) |entry| {
        if (entry.risk.executes_user_command and std.mem.indexOf(u8, bytes, entry.name) == null) {
            try stderrPrint(io, "command-running tool docs check missing `{s}` in {s}\n", .{ entry.name, path });
            ok = false;
        }
    }
    return ok;
}

pub fn checkAgentWorkflowDocs(allocator: Allocator, io: Io) !bool {
    return checkDocNeedles(allocator, io, "docs/agent-workflows.md", &.{
        "workflow_contract",
        "omitted_sections",
        "skipped_phases",
        "heuristic text/import scan",
        "zigar_context_pack -> zigar_next_action",
    });
}

pub fn checkCiArtifactDocs(allocator: Allocator, io: Io) !bool {
    return checkDocNeedles(allocator, io, "docs/ci-artifacts.md", &.{
        "parser_confidence",
        "parsing_basis",
        "command_level_junit",
        "raw_output_available",
        "failure_summary",
        "GitHub Actions",
    });
}

pub fn checkDocsLookupDocs(allocator: Allocator, io: Io) !bool {
    return checkDocNeedles(allocator, io, "docs/tools.md", &.{
        "Docs tools are intentionally split by source",
        "provenance/completeness",
        "active Zig version",
        "drift_check_status",
        "active_builtin_source_path",
        "triple-slash doc comments",
        "qualified_name",
        "import_hint",
        "source_scan_limitations",
        "installed_doc_available",
        "fallback_reason",
        "parse_failure_count",
        "index_metadata",
        "source roots",
        "curated fallback status",
    });
}

pub fn checkReleaseEvidenceDocs(allocator: Allocator, io: Io) !bool {
    return checkDocNeedles(allocator, io, "docs/release.md", &.{
        "validation evidence block",
        "real-backend validation status",
        "do not claim real backend coverage",
        "Release Readiness",
        "backend compatibility matrix",
        "ZLS Conformance",
        "source_tree_clean: true",
        "backend-provisioning/real_backend_pins.json",
    });
}

pub fn checkMaturityDocs(allocator: Allocator, io: Io) !bool {
    return checkDocNeedles(allocator, io, "docs/maturity.md", &.{
        "Minimum public-release rating: A",
        "source_tree_clean: true",
        "No high-impact release blocker remains",
        "Contract maturity",
        "Capability maturity",
        "Release gate and packaging",
        "MCP/tool contract",
        "ZLS/LSP tools",
        "Docs lookup",
        "Static analysis",
        "ZLint optional backend",
        "zwanzig optional backend",
        "Profiling/zflame",
        "Agent workflows",
        "CI artifact tools",
        "HTTP/MCP substrate",
        "command-level JUnit",
    });
}

pub fn checkTrustDocs(allocator: Allocator, io: Io) !bool {
    return checkDocNeedles(allocator, io, "docs/trust.md", &.{
        "tools/call`, `resources/read`, and",
        "prompts/get",
        "total wall-clock deadlines",
        "validation evidence block",
        "advisory_orientation",
        "release-check",
        "release-asset-smoke",
        "least-privilege GitHub Actions permissions",
    });
}

pub fn checkFoundationContractDocs(allocator: Allocator, io: Io) !bool {
    var ok = true;
    ok = (try checkDocNeedles(allocator, io, "docs/tools.md", &.{
        "Artifact registry and provenance",
        "zigar_artifact_index",
        "result_shape",
        "omitted_sections",
        "zigar_metrics_v2",
        "zigar_docs_drift_check",
    })) and ok;
    ok = (try checkDocNeedles(allocator, io, "docs/trust.md", &.{
        "zigar_trust_report",
        "zigar_command_provenance",
        "zigar_clean_tree_gate",
        "clean-tree gate",
    })) and ok;
    ok = (try checkDocNeedles(allocator, io, "docs/release.md", &.{
        "zigar_docs_drift_check",
        "zigar_release_claim_check",
        "zigar_tool_index_check",
    })) and ok;
    ok = (try checkDocNeedles(allocator, io, "docs/tool-index.generated.md", &.{
        "zigar_artifact_index",
        "zigar_metrics_v2",
        "zigar_trust_report",
        "zigar_result_shape",
        "zigar_docs_drift_check",
    })) and ok;
    return ok;
}

pub fn checkPublicAdoptionDocs(allocator: Allocator, io: Io) !bool {
    var ok = true;
    ok = (try checkDocNeedles(allocator, io, "docs/tools.md", &.{
        "Public Adoption Tools",
        "zigar_adoption_pack",
        "zigar_client_config_generate",
        "zigar_smoke_plan",
        "zigar_conformance_report",
        "missing_evidence",
        "failed rows do not",
    })) and ok;
    ok = (try checkDocNeedles(allocator, io, "docs/agent-clients.md", &.{
        "zigar_client_config_generate",
        "zigar_adoption_pack",
        "zigar_smoke_plan",
        "zigar_conformance_report",
    })) and ok;
    return ok;
}

fn checkDocNeedles(allocator: Allocator, io: Io, path: []const u8, needles: []const []const u8) !bool {
    const bytes = readFileAlloc(allocator, io, path, 8 * 1024 * 1024) catch |err| {
        try stderrPrint(io, "docs check could not read {s}: {s}\n", .{ path, @errorName(err) });
        return false;
    };
    defer allocator.free(bytes);
    var ok = true;
    for (needles) |needle| {
        if (std.mem.indexOf(u8, bytes, needle) == null) {
            try stderrPrint(io, "docs check missing `{s}` in {s}\n", .{ needle, path });
            ok = false;
        }
    }
    return ok;
}

fn readFileAlloc(allocator: Allocator, io: Io, path: []const u8, max_bytes: usize) ![]u8 {
    return Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_bytes));
}

fn stderrPrint(io: Io, comptime fmt: []const u8, args: anytype) !void {
    var buffer: [4096]u8 = undefined;
    var writer = Io.File.stderr().writer(io, &buffer);
    try writer.interface.print(fmt, args);
    try writer.interface.flush();
}
