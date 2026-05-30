//! Release gate: documentation content contracts.
//! Each exported function probes a specific doc page for required vocabulary
//! terms.  Missing terms indicate the docs drifted from the implementation;
//! the orchestrator in release_checks.zig runs all of them as part of the
//! artifact-hygiene gate.
const std = @import("std");
const zigars = @import("zigars");

const Io = std.Io;
const Allocator = std.mem.Allocator;

/// Confirms that docs/tools.md and the generated tool-index contain the
/// static-analysis capability-tier vocabulary and representative tool names.
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

/// Confirms that README.md documents the shell-free execution model and that
/// every manifest entry marked `executes_user_command` is mentioned by name.
pub fn checkCommandRunningToolDocs(allocator: Allocator, io: Io) !bool {
    const path = "README.md";
    const bytes = readFileAlloc(allocator, io, path, 1024 * 1024) catch |err| {
        try stderrPrint(io, "command-running tool docs check could not read {s}: {s}\n", .{ path, @errorName(err) });
        return false;
    };
    defer allocator.free(bytes);
    var ok = std.mem.indexOf(u8, bytes, "without a shell") != null and
        std.mem.indexOf(u8, bytes, "MCP `readOnlyHint`") != null;
    for (zigars.manifest.entries) |entry| {
        if (entry.risk.executes_user_command and std.mem.indexOf(u8, bytes, entry.name) == null) {
            try stderrPrint(io, "command-running tool docs check missing `{s}` in {s}\n", .{ entry.name, path });
            ok = false;
        }
    }
    return ok;
}

/// Confirms that docs/agent-workflows.md contains the required contract and
/// workflow-elicitation vocabulary.
pub fn checkAgentWorkflowDocs(allocator: Allocator, io: Io) !bool {
    return checkDocNeedles(allocator, io, "docs/agent-workflows.md", &.{
        "workflow_contract",
        "omitted_sections",
        "skipped_phases",
        "heuristic text/import scan",
        "zigars_setup_guidance",
        "elicitation/create",
        "summarize=true",
        "zigars_context_pack -> zigars_next_action",
    });
}

/// Confirms that docs/ci-artifacts.md documents the parser-confidence, failure
/// summary, and GitHub Actions integration vocabulary.
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

/// Confirms that docs/tools.md explains the docs-lookup provenance model and
/// the fields that distinguish installed, source-scanned, and fallback sources.
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

/// Confirms that docs/release.md explains the evidence block format and
/// the requirement to cite real-backend and clean-tree evidence before claiming.
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

/// Confirms that docs/maturity.md covers the minimum rating (A), clean-tree
/// requirement, and the full capability-area rubric table.
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

/// Confirms that docs/trust.md covers the MCP operation scope, deadline policy,
/// evidence validation, advisory orientation tier, and CI permission model.
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

/// Confirms that docs/tools.md, docs/trust.md, docs/release.md, and the
/// generated tool index all reference the foundation contract tool set
/// (artifact registry, metrics, trust report, result shape, docs-drift check).
pub fn checkFoundationContractDocs(allocator: Allocator, io: Io) !bool {
    var ok = true;
    ok = (try checkDocNeedles(allocator, io, "docs/tools.md", &.{
        "Artifact registry and provenance",
        "zigars_artifact_index",
        "result_shape",
        "omitted_sections",
        "zigars_metrics_v2",
        "zigars_docs_drift_check",
    })) and ok;
    ok = (try checkDocNeedles(allocator, io, "docs/trust.md", &.{
        "zigars_trust_report",
        "zigars_command_provenance",
        "zigars_clean_tree_gate",
        "clean-tree gate",
    })) and ok;
    ok = (try checkDocNeedles(allocator, io, "docs/release.md", &.{
        "zigars_docs_drift_check",
        "zigars_release_claim_check",
        "zigars_tool_index_check",
    })) and ok;
    ok = (try checkDocNeedles(allocator, io, "docs/tool-index.generated.md", &.{
        "zigars_artifact_index",
        "zigars_metrics_v2",
        "zigars_trust_report",
        "zigars_result_shape",
        "zigars_docs_drift_check",
    })) and ok;
    return ok;
}

/// Confirms that docs/tools.md and docs/agent-clients.md document the public
/// adoption tool set and the protocol-feature fallback model.
pub fn checkPublicAdoptionDocs(allocator: Allocator, io: Io) !bool {
    var ok = true;
    ok = (try checkDocNeedles(allocator, io, "docs/tools.md", &.{
        "Public Adoption Tools",
        "zigars_adoption_pack",
        "zigars_client_config_generate",
        "zigars_smoke_plan",
        "zigars_conformance_report",
        "missing_evidence",
        "failed rows do not",
    })) and ok;
    ok = (try checkDocNeedles(allocator, io, "docs/agent-clients.md", &.{
        "zigars_client_config_generate",
        "zigars_adoption_pack",
        "zigars_smoke_plan",
        "zigars_conformance_report",
        "Protocol Feature Fallbacks",
        "outputSchema",
        "sampling/createMessage",
    })) and ok;
    return ok;
}

/// Returns `true` iff every needle in `needles` is a substring of the file at
/// `path`.  Missing needles and read errors are reported to stderr.
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

/// Reads a repository-relative docs file with a byte limit.
fn readFileAlloc(allocator: Allocator, io: Io, path: []const u8, max_bytes: usize) ![]u8 {
    return Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_bytes));
}

/// Writes a formatted diagnostic to stderr.
fn stderrPrint(io: Io, comptime fmt: []const u8, args: anytype) !void {
    var buffer: [4096]u8 = undefined;
    var writer = Io.File.stderr().writer(io, &buffer);
    try writer.interface.print(fmt, args);
    try writer.interface.flush();
}

test "release docs checker exposes static analysis docs check" {
    try std.testing.expect(@hasDecl(@This(), "checkStaticAnalysisDocs"));
}
