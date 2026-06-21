//! Adapter support helpers for the static-analysis MCP tools: argument parsing,
//! semantic error classification, and the static-analysis evidence-contract
//! metadata table. Extracted from static_analysis.zig so the handler module
//! stays focused on tool dispatch. Leaf layer: it never calls the handlers.
const std = @import("std");
const mcp = @import("mcp");
const app_context = @import("../../../app/context.zig");
const ports = @import("../../../app/ports.zig");
const mcp_errors = @import("../errors.zig");

/// Pre-validates an optional findings JSON argument, returning a ready argument
/// error result when it is present but unparseable, or null when it is absent,
/// blank, or valid. Returning the error as a value (not a thrown error) lets the
/// caller short-circuit with `if (... ) |err| return err` before doing real work.
pub fn validateFindingsArgument(allocator: std.mem.Allocator, args: ?std.json.Value, field: []const u8) mcp.tools.ToolError!?mcp.tools.ToolResult {
    // Reject incompatible inputs early so callers get a precise failure reason.
    const text = argString(args, field) orelse return null;
    if (std.mem.trim(u8, text, " \t\r\n").len == 0) return null;
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, text, .{}) catch {
        return try mcp_errors.missingArgument(allocator, "zig_static_fusion", field, "valid JSON findings");
    };
    defer parsed.deinit();
    return null;
}

/// Maps semantic error code failures to structured MCP errors.
pub fn semanticErrorCode(err: anyerror) []const u8 {
    // Keep this logic centralized so callers observe one consistent behavior path.
    return switch (err) {
        error.MissingCachePort => "missing_cache_port",
        error.MissingCommandRunner => "missing_command_runner",
        error.InvalidCache => "invalid_semantic_cache",
        error.PathOutsideWorkspace, error.EmptyPath => "workspace_path",
        error.FileNotFound, error.NotFound => "file_not_found",
        error.Timeout, error.RequestTimeout => "timeout",
        error.OutputLimitExceeded, error.StreamTooLong => "output_limit",
        else => "semantic_index_failed",
    };
}

/// Maps semantic error category failures to structured MCP errors.
pub fn semanticErrorCategory(err: anyerror) []const u8 {
    // Keep this logic centralized so callers observe one consistent behavior path.
    return switch (err) {
        error.MissingCachePort, error.MissingCommandRunner => "configuration",
        error.InvalidCache => "cache",
        error.PathOutsideWorkspace, error.EmptyPath => "workspace_path",
        error.FileNotFound, error.NotFound => "filesystem",
        error.Timeout, error.RequestTimeout => "timeout",
        error.OutputLimitExceeded, error.StreamTooLong => "output_limit",
        else => "static_analysis",
    };
}

/// Maps semantic error retryable failures to structured MCP errors.
pub fn semanticErrorRetryable(err: anyerror) bool {
    return switch (err) {
        error.Timeout, error.RequestTimeout, error.InvalidCache => true,
        else => false,
    };
}

/// Maps semantic error resolution failures to structured MCP errors.
pub fn semanticErrorResolution(err: anyerror) []const u8 {
    // Keep this logic centralized so callers observe one consistent behavior path.
    return switch (err) {
        error.MissingCachePort => "Run this tool through a runtime that supplies the semantic-index StaticCache port.",
        error.MissingCommandRunner => "Run this tool through a runtime that supplies the command runner port, or retry without ZLint-backed reference confirmation.",
        error.InvalidCache => "Retry with refresh=true to rebuild the semantic index from workspace sources.",
        error.PathOutsideWorkspace, error.EmptyPath => "Retry with a non-empty workspace-relative path inside the configured workspace.",
        error.Timeout, error.RequestTimeout => "Retry with a smaller limit or a larger timeout_ms value.",
        error.OutputLimitExceeded, error.StreamTooLong => "Retry with a smaller limit or narrower query.",
        else => "Retry with a smaller limit or refresh=true; inspect unreadable Zig files if the failure repeats.",
    };
}

/// Returns an allocator-owned JSON value for semantic cache status.
pub fn semanticCacheStatusValue(allocator: std.mem.Allocator, cache: ports.StaticCacheStatus) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "cached", .{ .bool = cache.cached });
    try obj.put(allocator, "hits", .{ .integer = @intCast(cache.hits) });
    try obj.put(allocator, "refreshes", .{ .integer = @intCast(cache.refreshes) });
    try obj.put(allocator, "signature", .{ .integer = signatureInteger(cache.signature) });
    return .{ .object = obj };
}

/// Converts a u64 signature to the signed JSON integer range expected by MCP.
pub fn signatureInteger(signature: u64) i64 {
    return @intCast(signature & @as(u64, std.math.maxInt(i64)));
}

/// Reads a string argument when it is present with the expected type.
pub fn argString(args: ?std.json.Value, name: []const u8) ?[]const u8 {
    return mcp.tools.getString(args, name);
}

/// True when the caller requested the structured JSON payload via
/// `output_format=json`; folds the former `*_json` twin tools into one tool.
pub fn wantsJson(args: ?std.json.Value) bool {
    const fmt = argString(args, "output_format") orelse return false;
    return std.mem.eql(u8, fmt, "json");
}

/// Reads a bool argument when it is present with the expected type.
pub fn argBool(args: ?std.json.Value, name: []const u8, default: bool) bool {
    return mcp.tools.getBoolean(args, name) orelse default;
}

/// Reads an int argument when it is present with the expected type.
pub fn argInt(args: ?std.json.Value, name: []const u8) ?usize {
    const value = mcp.tools.getInteger(args, name) orelse return null;
    return @intCast(@max(value, 1));
}

/// Reads an integer argument when it is present with the expected type.
pub fn argInteger(args: ?std.json.Value, name: []const u8) ?i64 {
    return mcp.tools.getInteger(args, name);
}

/// Reads a `has` argument when it is present with the expected type.
pub fn argHas(args: ?std.json.Value, name: []const u8) bool {
    const value = args orelse return false;
    return switch (value) {
        .object => |obj| obj.get(name) != null,
        else => false,
    };
}

/// Clamps a requested timeout to [1ms, 1 hour], defaulting to the configured
/// command timeout. The upper bound caps backend-invoking analyses (lint,
/// compiler-backed layout probes) so a single call cannot run unbounded.
pub fn timeoutMs(context: app_context.StaticAnalysisContext, args: ?std.json.Value) ?u64 {
    const raw = mcp.tools.getInteger(args, "timeout_ms") orelse context.timeouts.command_ms;
    return @intCast(@max(1, @min(raw, 60 * 60 * 1000)));
}

/// Reads a string field from a JSON object when it has the expected type.
pub fn objectString(obj: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const value = obj.get(name) orelse return null;
    return switch (value) {
        .string => |text| text,
        else => null,
    };
}

/// Copies text into an allocator-owned JSON string value.
pub fn ownedString(allocator: std.mem.Allocator, value: []const u8) !std.json.Value {
    return .{ .string = try allocator.dupe(u8, value) };
}

/// Splits one shell-like argument string into argv tokens (single/double quotes
/// and backslash escapes honored). Tokens are forwarded to optional lint/graph
/// backends, never run through a shell. Returns error.InvalidArguments on an
/// unterminated quote or trailing escape, which the caller turns into a
/// structured argument error. Tokens and the slice are owned by `allocator`.
pub fn splitArgs(allocator: std.mem.Allocator, text: []const u8) ![]const []const u8 {
    // Keep this logic centralized so callers observe one consistent behavior path.
    var list: std.ArrayList([]const u8) = .empty;
    var current: std.ArrayList(u8) = .empty;
    errdefer {
        for (list.items) |arg| allocator.free(arg);
        list.deinit(allocator);
        current.deinit(allocator);
    }

    var quote: ?u8 = null;
    var escaping = false;
    var in_token = false;
    for (text) |c| {
        if (escaping) {
            try current.append(allocator, c);
            in_token = true;
            escaping = false;
            continue;
        }
        if (c == '\\') {
            escaping = true;
            in_token = true;
            continue;
        }
        if (quote) |q| {
            if (c == q) {
                quote = null;
            } else {
                try current.append(allocator, c);
            }
            in_token = true;
            continue;
        }
        switch (c) {
            '\'', '"' => {
                quote = c;
                in_token = true;
            },
            ' ', '\t', '\r', '\n' => {
                if (in_token) {
                    try finishArg(allocator, &list, &current);
                    in_token = false;
                }
            },
            else => {
                try current.append(allocator, c);
                in_token = true;
            },
        }
    }
    if (escaping or quote != null) return error.InvalidArguments;
    if (in_token) try finishArg(allocator, &list, &current);
    return list.toOwnedSlice(allocator);
}

/// Parses finish arg from MCP JSON arguments.
pub fn finishArg(allocator: std.mem.Allocator, list: *std.ArrayList([]const u8), current: *std.ArrayList(u8)) !void {
    const arg = try current.toOwnedSlice(allocator);
    errdefer allocator.free(arg);
    try list.append(allocator, arg);
}

/// Structured evidence contract attached to static-analysis tool responses.
pub const Contract = struct {
    tool: []const u8,
    analysis_kind: []const u8,
    capability_tier: []const u8,
    confidence: []const u8,
    confidence_class: []const u8,
    source_coverage: []const u8,
    limitations: []const []const u8,
    verify_with: []const []const u8,
};

/// Evidence coverage statement for semantic index contract metadata.
const semantic_index_coverage = "Readable workspace Zig files up to the requested limit; declarations/imports/tests are parser-backed where std.zig.Ast can parse the file, with parse_status, partial_result, and parse_error_count carried from parser-backed evidence when available.";
/// Evidence coverage statement for semantic reference contract metadata.
const semantic_refs_coverage = "Readable workspace Zig files up to the requested limit; matching lines are confirmed with optional ZLint --print-ast symbol references when the configured backend supports it, with source-scan fallback.";
/// Evidence coverage statement for lint fusion contract metadata.
const lint_fusion_coverage = "Semantic index and optional normalized linter evidence supplied by the caller.";
/// Evidence coverage statement for caller-provided lint contract metadata.
const lint_evidence_coverage = "Caller-supplied normalized lint JSON or optional lint backend output, depending on the tool and arguments.";
/// Evidence coverage statement for ZLint output contract metadata.
const zlint_output_coverage = "Optional ZLint backend output for the requested workspace path, normalized into zigars lint findings.";
/// Evidence coverage statement for ZLint fix contract metadata.
const zlint_fix_coverage = "Optional ZLint --fix or --fix-dangerously over a workspace-local path, previewed unless apply=true.";
/// Evidence coverage statement for zwanzig output contract metadata.
const zwanzig_output_coverage = "Optional zwanzig backend output for the requested workspace path or graph mode.";

/// Shared semantic index limitations surfaced in structured result metadata.
const semantic_index_limits = &.{
    "Parser-backed syntax view plus source-scan evidence; it does not resolve comptime execution, aliases, or conditional imports.",
    "Parse errors are reported through parser metadata when available and can make file-level evidence partial.",
    "Workspace walks are bounded by the requested limit and skip generated/cache paths.",
};
/// Shared semantic reference limitations surfaced in structured result metadata.
const semantic_refs_limits = &.{
    "ZLint symbol-reference evidence is used when the configured backend exposes --print-ast; otherwise results fall back to source scans.",
    "Locations are still reported from matching source lines and can include textual matches that require review.",
    "Does not execute comptime code or prove cross-module alias resolution.",
};
/// Shared lint intelligence limitations surfaced in structured result metadata.
const lint_intelligence_limits = &.{
    "Compares normalized lint evidence by stable rule/path/line fingerprints and cannot prove semantic correctness by itself.",
    "Gate and trend outputs are policy decisions over observed findings, not compiler or runtime proof.",
};
/// Shared ZLint output limitations surfaced in structured result metadata.
const zlint_limits = &.{
    "Requires an optional configured ZLint executable; zigars does not bundle or require the backend.",
    "Rule coverage, false positives, and output shape depend on the installed ZLint version and configuration.",
};
/// Shared ZLint fix limitations surfaced in structured result metadata.
const zlint_fix_limits = &.{
    "Requires an optional configured ZLint executable with --fix support; zigars does not implement the edits itself.",
    "Runs only when apply=true and the selected path resolves inside the workspace.",
    "dangerous=true delegates to ZLint --fix-dangerously and should be followed by git diff review and tests.",
};
/// Shared zwanzig output limitations surfaced in structured result metadata.
const zwanzig_limits = &.{
    "Requires an optional configured zwanzig executable; zigars does not bundle or require the backend.",
    "Rule coverage, false positives, and graph support depend on the installed zwanzig version and configuration.",
};

/// Static contract table mapping tool names to structured evidence metadata.
const contracts = [_]Contract{
    .{ .tool = "zig_import_graph", .analysis_kind = "heuristic_import_graph", .capability_tier = "advisory_orientation", .confidence = "medium", .confidence_class = "orientation_only", .source_coverage = "Readable workspace Zig files up to the requested limit.", .limitations = &.{"String-literal import scan; it does not resolve conditional imports, aliases, or comptime logic."}, .verify_with = &.{ "zig ast-check", "ZLS references" } },
    .{ .tool = "zig_import_cycles", .analysis_kind = "architecture_neutral_import_cycle_scc", .capability_tier = "advisory_orientation", .confidence = "medium", .confidence_class = "advisory", .source_coverage = "Readable workspace Zig files up to the requested limit, post-processed from the heuristic import graph.", .limitations = &.{"Cycle detection only follows workspace-relative string-literal .zig imports; comptime imports, build module aliases, and package imports require compiler/ZLS verification."}, .verify_with = &.{ "zig_import_graph", "zig build test", "ZLS references" } },
    .{ .tool = "zig_test_name_resolve", .analysis_kind = "parser_backed_test_name_resolution", .capability_tier = "parser_backed", .confidence = "high", .confidence_class = "advisory", .source_coverage = "Readable workspace Zig files up to the requested limit; test declarations are parsed with std.zig.Ast when possible.", .limitations = &.{"Matches declared test names and declarations; custom build test routing and runtime-generated cases are outside the evidence."}, .verify_with = &.{ "zig_ast_tests", "zig test --test-filter", "zig build test" } },
    .{ .tool = "zig_test_fixture_inventory", .analysis_kind = "parser_backed_test_fixture_inventory", .capability_tier = "parser_backed", .confidence = "medium", .confidence_class = "orientation_only", .source_coverage = "Readable workspace Zig files up to the requested limit; helper classification uses parser declarations plus path/name hints.", .limitations = &.{"Fixture/helper labels are heuristic and usage counts are source-text occurrences, not semantic references."}, .verify_with = &.{ "ZLS references", "zig build test" } },
    .{ .tool = "zig_safety_site_catalog", .analysis_kind = "safety_keyword_site_catalog", .capability_tier = "advisory_orientation", .confidence = "medium", .confidence_class = "advisory", .source_coverage = "Readable workspace Zig files up to the requested limit with line-level masking for obvious comments and string literals.", .limitations = &.{"Safety sites are review prompts, not proof of unsafety; full semantic intent requires code review and compiler-backed validation."}, .verify_with = &.{ "code review", "zig build test", "configured linters" } },
    .{ .tool = "zig_test_for_symbol", .analysis_kind = "symbol_to_test_candidate_map", .capability_tier = "advisory_orientation", .confidence = "medium", .confidence_class = "advisory", .source_coverage = "Readable workspace Zig files up to the requested limit; matches symbol names against tests and source proximity.", .limitations = &.{"Candidate tests do not prove coverage and should not be used to skip project validation by themselves."}, .verify_with = &.{ "zig test --test-filter", "zig build test" } },
    .{ .tool = "zig_module_surface", .analysis_kind = "parser_backed_module_surface", .capability_tier = "parser_backed", .confidence = "medium", .confidence_class = "advisory", .source_coverage = "Readable workspace Zig files under the requested path up to the limit; public declarations are parser-backed where possible.", .limitations = &.{"Consumer and unused-export signals are source scans and can miss aliases, re-exports, and comptime-selected API."}, .verify_with = &.{ "zig_public_api", "ZLS references", "zig build test" } },
    .{ .tool = "zig_symbol_dossier", .analysis_kind = "symbol_scoped_static_dossier", .capability_tier = "advisory_orientation", .confidence = "medium", .confidence_class = "advisory", .source_coverage = "Readable workspace Zig files up to the requested limit; combines declarations, source references, tests, and module hints.", .limitations = &.{"Diagnostics, lint findings, and git history are omitted unless supplied by separate tools."}, .verify_with = &.{ "zig_semantic_decl", "zig_semantic_refs", "zig build test" } },
    .{ .tool = "zig_change_risk_audit", .analysis_kind = "architecture_neutral_change_risk_audit", .capability_tier = "advisory_orientation", .confidence = "medium", .confidence_class = "advisory", .source_coverage = "Caller-supplied files, symbols, or diff text matched against workspace declarations, imports, and tests.", .limitations = &.{"Risk scores are planner weights over static evidence, not release gates or architecture-policy enforcement."}, .verify_with = &.{ "zig_changed_files_plan", "zig build test", "project CI" } },
    .{ .tool = "zig_insertion_sites", .analysis_kind = "project_local_insertion_site_ranking", .capability_tier = "advisory_orientation", .confidence = "medium", .confidence_class = "orientation_only", .source_coverage = "Readable workspace Zig files up to the requested limit ranked by path, declaration, import, and source-text similarity.", .limitations = &.{"Recommendations are non-authoritative and architecture-neutral; inspect nearby modules before editing."}, .verify_with = &.{ "code review", "zig_module_surface", "zig build test" } },
    .{ .tool = "zig_io_migration_scan", .analysis_kind = "zig_016_io_migration_catalog", .capability_tier = "advisory_orientation", .confidence = "medium", .confidence_class = "advisory", .source_coverage = "Readable workspace Zig files up to the requested limit, masked for obvious comments and strings, matched against a curated std.io/std.Io migration table.", .limitations = &.{"Catalogs likely migration sites only; buffer ownership and concrete reader/writer types require compiler-backed verification."}, .verify_with = &.{ "zig fmt --check .", "zig build test", "zig build -Doptimize=ReleaseSafe" } },
    .{ .tool = "zig_leak_triage", .analysis_kind = "gpa_leak_stderr_grouping", .capability_tier = "advisory_orientation", .confidence = "medium", .confidence_class = "advisory", .source_coverage = "Caller-supplied or workspace-read GPA leak stderr text; repeated traces are grouped by first Zig stack frame when present.", .limitations = &.{"Does not execute symbolizers or inspect binaries; optimized or stripped traces can omit allocation sites."}, .verify_with = &.{ "rerun failing test with GPA leak detection", "debug build stack traces" } },
    .{ .tool = "zig_comptime_diagnose", .analysis_kind = "parser_only_comptime_diagnosis", .capability_tier = "advisory_orientation", .confidence = "medium", .confidence_class = "advisory", .source_coverage = "Caller-supplied source snippet, workspace file, or compiler diagnostic text mined for comptime-known/runtime-known failure clues.", .limitations = &.{"Does not execute compiler probes or evaluate comptime code; compiler diagnostic locations remain authoritative."}, .verify_with = &.{ "zig build test", "zig check", "compiler diagnostic location" } },
    .{ .tool = "zig_memory_layout", .analysis_kind = "layout_sensitive_declaration_catalog_with_optional_compiler_measurements", .capability_tier = "compiler_backed", .confidence = "medium", .confidence_class = "advisory", .source_coverage = "Default mode scans readable workspace Zig files; measure=true writes standalone probes under .zigars-cache and invokes direct zig build-obj commands for target-specific @sizeOf/@alignOf/@offsetOf evidence.", .limitations = &.{ "Default mode is parser-only and does not execute the compiler.", "Compiler-backed mode skips project imports, @embedFile, and explicit comptime logic unless opted in; it does not execute build.zig or target binaries." }, .verify_with = &.{ "zig_abi_layout_diff measure=true", "compiler @sizeOf/@alignOf probes", "targeted tests" } },
    .{ .tool = "zig_unsafe_operations_audit", .analysis_kind = "unsafe_boundary_operation_catalog", .capability_tier = "advisory_orientation", .confidence = "medium", .confidence_class = "advisory", .source_coverage = "Readable workspace Zig files up to the requested limit, masked for obvious comments and strings, matched against unsafe builtin and boundary-operation patterns.", .limitations = &.{"Review catalog only; it does not prove the matched operation is unsafe or incorrect."}, .verify_with = &.{ "zig_safety_site_catalog", "code review", "zig build test" } },
    .{ .tool = "zig_abi_layout_diff", .analysis_kind = "abi_layout_target_comparison_with_optional_compiler_measurements", .capability_tier = "compiler_backed", .confidence = "medium", .confidence_class = "advisory", .source_coverage = "Default mode plans probes for packed/extern declarations; measure=true compares standalone compiler-backed layout measurements across requested target triples.", .limitations = &.{ "Default mode remains parser-only and does not execute compiler commands.", "Compiler-backed mode uses direct zig build-obj -fno-emit-bin probes; it does not execute build.zig or target binaries and refuses project imports by default." }, .verify_with = &.{ "zig_memory_layout measure=true", "target-specific ABI tests", "code review at FFI boundaries" } },
    .{ .tool = "zig_build_graph", .analysis_kind = "heuristic_build_graph", .capability_tier = "advisory_orientation", .confidence = "medium", .confidence_class = "orientation_only", .source_coverage = "build.zig and build.zig.zon when present in the workspace root.", .limitations = &.{"Heuristic source scan of build files; it does not execute build.zig."}, .verify_with = &.{"zig build --help"} },
    .{ .tool = "zig_build_targets", .analysis_kind = "heuristic_build_targets", .capability_tier = "advisory_orientation", .confidence = "medium", .confidence_class = "orientation_only", .source_coverage = "build.zig target, artifact, test, step, and command suggestions from the workspace root.", .limitations = &.{"Heuristic source scan of build.zig; it does not execute build.zig."}, .verify_with = &.{"zig build --help"} },
    .{ .tool = "zig_build_options", .analysis_kind = "heuristic_build_option_scan", .capability_tier = "advisory_orientation", .confidence = "medium", .confidence_class = "orientation_only", .source_coverage = "build.zig option declarations in the workspace root.", .limitations = &.{"Only detects common std.Build option syntax; dynamic options may be missed."}, .verify_with = &.{"zig build --help"} },
    .{ .tool = "zig_file_owner", .analysis_kind = "heuristic_file_owner", .capability_tier = "advisory_orientation", .confidence = "medium", .confidence_class = "orientation_only", .source_coverage = "build.zig root_source_file references and the requested workspace file.", .limitations = &.{"Only exact root_source_file matches are high confidence."}, .verify_with = &.{ "zig ast-check", "zig build test" } },
    .{ .tool = "zig_import_resolve", .analysis_kind = "heuristic_import_resolve", .capability_tier = "advisory_orientation", .confidence = "medium", .confidence_class = "orientation_only", .source_coverage = "build.zig, build.zig.zon, and workspace-relative import candidates.", .limitations = &.{"Does not execute build.zig or compiler import resolution."}, .verify_with = &.{ "zig ast-check", "zig build test" } },
    .{ .tool = "zig_test_discover", .analysis_kind = "heuristic_test_discovery", .capability_tier = "advisory_orientation", .confidence = "medium", .confidence_class = "orientation_only", .source_coverage = "Readable workspace Zig files up to the requested limit.", .limitations = &.{"Scans textual test declarations; it does not run tests."}, .verify_with = &.{"zig build test"} },
    .{ .tool = "zig_changed_files_plan", .analysis_kind = "git_changed_files_plan", .capability_tier = "advisory_orientation", .confidence = "medium", .confidence_class = "advisory", .source_coverage = "Current git porcelain status for the workspace.", .limitations = &.{"Requires git status; command suggestions are conservative defaults."}, .verify_with = &.{"git status --porcelain"} },
    .{ .tool = "zig_dependency_inspect", .analysis_kind = "heuristic_dependency_inspect", .capability_tier = "advisory_orientation", .confidence = "medium", .confidence_class = "orientation_only", .source_coverage = "build.zig.zon dependencies in the workspace root.", .limitations = &.{"Heuristic build.zig.zon source scan; it does not fetch dependencies."}, .verify_with = &.{"zig build --fetch"} },
    .{ .tool = "zig_target_matrix_plan", .analysis_kind = "target_matrix_planning", .capability_tier = "advisory_orientation", .confidence = "medium", .confidence_class = "orientation_only", .source_coverage = "Caller-supplied target and step lists.", .limitations = &.{"Plans commands only; it does not validate target availability."}, .verify_with = &.{"zig targets"} },
    .{ .tool = "zig_test_failure_triage", .analysis_kind = "test_failure_triage", .capability_tier = "advisory_orientation", .confidence = "medium", .confidence_class = "advisory", .source_coverage = "Caller-supplied test output or command output from the configured Zig backend.", .limitations = &.{"Line classification is heuristic; rerun the suggested command for proof."}, .verify_with = &.{"zig build test"} },
    .{ .tool = "zig_workspace_symbol_cache", .analysis_kind = "cached_heuristic_symbol_import_scan", .capability_tier = "advisory_orientation", .confidence = "medium", .confidence_class = "orientation_only", .source_coverage = "Readable workspace Zig files up to the requested limit.", .limitations = &.{"Textual declaration and import scan; it does not resolve aliases or comptime code."}, .verify_with = &.{ "zig ast-check", "ZLS workspace symbols" } },
    .{ .tool = "zig_package_cache_doctor", .analysis_kind = "package_cache_doctor", .capability_tier = "advisory_orientation", .confidence = "medium", .confidence_class = "advisory", .source_coverage = "Workspace cache paths, git tracking state, and build.zig.zon dependency hints.", .limitations = &.{"Reports cache hygiene signals; it does not delete files."}, .verify_with = &.{ "git status", "zig build test" } },
    .{ .tool = "zig_test_map", .analysis_kind = "heuristic_test_declaration_scan", .capability_tier = "advisory_orientation", .confidence = "medium", .confidence_class = "orientation_only", .source_coverage = "Readable workspace Zig files up to the requested limit.", .limitations = &.{"Scans textual test declarations; it does not run tests."}, .verify_with = &.{"zig build test"} },
    .{ .tool = "zig_test_select", .analysis_kind = "heuristic_test_selection", .capability_tier = "advisory_orientation", .confidence = "medium", .confidence_class = "advisory", .source_coverage = "Caller-supplied changed files/symbols and heuristic workspace test map.", .limitations = &.{"Command recommendations are conservative and may over-select."}, .verify_with = &.{"zig build test"} },
    .{ .tool = "zig_public_api_diff", .analysis_kind = "heuristic_public_api_diff", .capability_tier = "advisory_orientation", .confidence = "medium", .confidence_class = "advisory", .source_coverage = "Caller-supplied before/after source text or git baseline plus workspace file.", .limitations = &.{"Public declaration scan is textual and does not prove ABI compatibility."}, .verify_with = &.{ "zig build test", "code review" } },
    .{ .tool = "zig_semantic_index_build", .analysis_kind = "parser_backed_semantic_workspace_index", .capability_tier = "parser_backed", .confidence = "high", .confidence_class = "advisory", .source_coverage = semantic_index_coverage, .limitations = semantic_index_limits, .verify_with = &.{ "zig ast-check", "ZLS workspace symbols", "zig build test" } },
    .{ .tool = "zig_semantic_index_status", .analysis_kind = "semantic_index_cache_status", .capability_tier = "advisory_orientation", .confidence = "medium", .confidence_class = "orientation_only", .source_coverage = "In-memory semantic index cache metadata for the current zigars process.", .limitations = &.{"Status reports cache state only; it does not refresh or validate source semantics."}, .verify_with = &.{"zig_semantic_index_refresh"} },
    .{ .tool = "zig_semantic_index_refresh", .analysis_kind = "parser_backed_semantic_workspace_index", .capability_tier = "parser_backed", .confidence = "high", .confidence_class = "advisory", .source_coverage = semantic_index_coverage, .limitations = semantic_index_limits, .verify_with = &.{ "zig ast-check", "ZLS workspace symbols", "zig build test" } },
    .{ .tool = "zig_semantic_query", .analysis_kind = "parser_backed_semantic_index_query", .capability_tier = "parser_backed", .confidence = "high", .confidence_class = "advisory", .source_coverage = semantic_index_coverage, .limitations = semantic_index_limits, .verify_with = &.{ "zig ast-check", "ZLS definition/references", "workspace search" } },
    .{ .tool = "zig_semantic_refs", .analysis_kind = "zlint_confirmed_reference_scan", .capability_tier = "advisory_orientation", .confidence = "medium", .confidence_class = "orientation_only", .source_coverage = semantic_refs_coverage, .limitations = semantic_refs_limits, .verify_with = &.{ "ZLS references", "zig build test" } },
    .{ .tool = "zig_semantic_decl", .analysis_kind = "parser_backed_declaration_lookup", .capability_tier = "parser_backed", .confidence = "high", .confidence_class = "advisory", .source_coverage = semantic_index_coverage, .limitations = semantic_index_limits, .verify_with = &.{ "zig ast-check", "ZLS definition" } },
    .{ .tool = "zig_semantic_callers", .analysis_kind = "zlint_confirmed_call_site_scan", .capability_tier = "advisory_orientation", .confidence = "medium", .confidence_class = "orientation_only", .source_coverage = semantic_refs_coverage, .limitations = semantic_refs_limits, .verify_with = &.{ "ZLS references", "code review" } },
    .{ .tool = "zig_static_fusion", .analysis_kind = "multi_source_static_confidence_fusion", .capability_tier = "advisory_orientation", .confidence = "medium", .confidence_class = "advisory", .source_coverage = lint_fusion_coverage, .limitations = lint_intelligence_limits, .verify_with = &.{ "zig build test", "ZLS", "configured linters" } },
    .{ .tool = "zig_code_index_export", .analysis_kind = "parser_backed_code_index_export", .capability_tier = "parser_backed", .confidence = "high", .confidence_class = "advisory", .source_coverage = semantic_index_coverage, .limitations = semantic_index_limits, .verify_with = &.{ "zig ast-check", "zig_semantic_index_build", "consumer schema validation" } },
    .{ .tool = "zig_scip_export", .analysis_kind = "parser_backed_scip_like_export", .capability_tier = "parser_backed", .confidence = "high", .confidence_class = "advisory", .source_coverage = semantic_index_coverage, .limitations = semantic_index_limits, .verify_with = &.{ "zig ast-check", "zig_semantic_index_build", "SCIP consumer validation" } },
    .{ .tool = "zig_zlint", .analysis_kind = "optional_zlint_diagnostics", .capability_tier = "zlint_backed", .confidence = "high", .confidence_class = "release_gating_candidate", .source_coverage = zlint_output_coverage, .limitations = zlint_limits, .verify_with = &.{"configured ZLint --help"} },
    .{ .tool = "zig_zlint_sarif", .analysis_kind = "optional_zlint_sarif_export", .capability_tier = "zlint_backed", .confidence = "high", .confidence_class = "release_gating_candidate", .source_coverage = zlint_output_coverage, .limitations = zlint_limits, .verify_with = &.{"configured ZLint --help"} },
    .{ .tool = "zig_zlint_rules", .analysis_kind = "optional_zlint_rule_catalog", .capability_tier = "zlint_backed", .confidence = "medium", .confidence_class = "advisory", .source_coverage = zlint_output_coverage, .limitations = zlint_limits, .verify_with = &.{"configured ZLint --help"} },
    .{ .tool = "zig_zlint_fix", .analysis_kind = "optional_zlint_apply_gated_fix", .capability_tier = "zlint_backed", .confidence = "medium", .confidence_class = "advisory", .source_coverage = zlint_fix_coverage, .limitations = zlint_fix_limits, .verify_with = &.{ "configured ZLint --help", "git diff", "zig build test" } },
    .{ .tool = "zig_lint_compare", .analysis_kind = "dual_linter_consensus_comparison", .capability_tier = "advisory_orientation", .confidence = "medium", .confidence_class = "advisory", .source_coverage = lint_evidence_coverage, .limitations = lint_intelligence_limits, .verify_with = &.{ "zig_zlint", "zig_lint" } },
    .{ .tool = "zig_lint_profile", .analysis_kind = "lint_gate_profile_policy", .capability_tier = "advisory_orientation", .confidence = "medium", .confidence_class = "orientation_only", .source_coverage = "Built-in lint gate profile policy table.", .limitations = &.{"Profiles are policy presets; they do not inspect source or run linters."}, .verify_with = &.{"zig_lint_gate"} },
    .{ .tool = "zig_lint_gate", .analysis_kind = "lint_findings_policy_gate", .capability_tier = "advisory_orientation", .confidence = "medium", .confidence_class = "advisory", .source_coverage = lint_evidence_coverage, .limitations = lint_intelligence_limits, .verify_with = &.{ "configured linters", "project CI" } },
    .{ .tool = "zig_lint_fix_plan", .analysis_kind = "lint_fix_planning", .capability_tier = "advisory_orientation", .confidence = "low", .confidence_class = "orientation_only", .source_coverage = lint_evidence_coverage, .limitations = &.{"Produces planning buckets over observed findings; source edits are delegated to apply-gated fix tools such as zig_zlint_fix."}, .verify_with = &.{ "code review", "zig build test" } },
    .{ .tool = "zig_lint_baseline", .analysis_kind = "lint_baseline_comparison", .capability_tier = "advisory_orientation", .confidence = "medium", .confidence_class = "advisory", .source_coverage = lint_evidence_coverage, .limitations = lint_intelligence_limits, .verify_with = &.{ "zig_lint_gate", "configured linters" } },
    .{ .tool = "zig_lint_suppressions", .analysis_kind = "lint_suppression_filter", .capability_tier = "advisory_orientation", .confidence = "medium", .confidence_class = "advisory", .source_coverage = lint_evidence_coverage, .limitations = lint_intelligence_limits, .verify_with = &.{ "code review", "configured linters" } },
    .{ .tool = "zig_lint_trend", .analysis_kind = "lint_trend_comparison", .capability_tier = "advisory_orientation", .confidence = "medium", .confidence_class = "advisory", .source_coverage = lint_evidence_coverage, .limitations = lint_intelligence_limits, .verify_with = &.{ "configured linters", "project CI" } },
    .{ .tool = "zig_lint", .analysis_kind = "optional_zwanzig_lint_json", .capability_tier = "zwanzig_backed", .confidence = "high", .confidence_class = "release_gating_candidate", .source_coverage = zwanzig_output_coverage, .limitations = zwanzig_limits, .verify_with = &.{"configured zwanzig --help"} },
    .{ .tool = "zig_lint_sarif", .analysis_kind = "optional_zwanzig_lint_sarif", .capability_tier = "zwanzig_backed", .confidence = "high", .confidence_class = "release_gating_candidate", .source_coverage = zwanzig_output_coverage, .limitations = zwanzig_limits, .verify_with = &.{"configured zwanzig --help"} },
    .{ .tool = "zig_lint_rules", .analysis_kind = "optional_zwanzig_rule_catalog", .capability_tier = "zwanzig_backed", .confidence = "medium", .confidence_class = "advisory", .source_coverage = zwanzig_output_coverage, .limitations = zwanzig_limits, .verify_with = &.{"configured zwanzig --help"} },
    .{ .tool = "zig_analysis_graphs", .analysis_kind = "optional_zwanzig_analysis_graph", .capability_tier = "zwanzig_backed", .confidence = "high", .confidence_class = "advisory", .source_coverage = zwanzig_output_coverage, .limitations = zwanzig_limits, .verify_with = &.{"configured zwanzig graph mode"} },
};

/// Stamps the tool's evidence-contract fields (analysis kind, capability tier,
/// confidence, limitations, cross-checks) onto a result object so every static
/// result self-describes how much to trust it. Invariant: every tool routed
/// through this adapter must have a `contracts` entry, hence the `unreachable`
/// when one is missing -- a registration/contract drift bug, not a user error.
pub fn putMetadata(allocator: std.mem.Allocator, obj: *std.json.ObjectMap, tool_name: []const u8) !void {
    // Keep this logic centralized so callers observe one consistent behavior path.
    const contract = contractFor(tool_name) orelse unreachable;
    try obj.put(allocator, "analysis_kind", .{ .string = contract.analysis_kind });
    try obj.put(allocator, "capability_tier", .{ .string = contract.capability_tier });
    try obj.put(allocator, "confidence", .{ .string = contract.confidence });
    try obj.put(allocator, "confidence_class", .{ .string = contract.confidence_class });
    try obj.put(allocator, "source_coverage", .{ .string = contract.source_coverage });
    try obj.put(allocator, "limitations", try stringArrayValue(allocator, contract.limitations));
    try obj.put(allocator, "verify_with", try stringArrayValue(allocator, contract.verify_with));
    try obj.put(allocator, "evidence_basis", try evidenceBasisValue(allocator, contract));
    try obj.put(allocator, "cross_check", try crossCheckValue(allocator, contract));
    if (contract.verify_with.len > 0) try obj.put(allocator, "recommended_cross_check", .{ .string = contract.verify_with[0] });
}

/// Finds the structured evidence contract for a static-analysis tool name.
pub fn contractFor(tool_name: []const u8) ?Contract {
    for (contracts) |contract| if (std.mem.eql(u8, contract.tool, tool_name)) return contract;
    return null;
}

/// Returns an allocator-owned JSON value for evidence basis.
pub fn evidenceBasisValue(allocator: std.mem.Allocator, contract: Contract) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "analysis_kind", .{ .string = contract.analysis_kind });
    try obj.put(allocator, "capability_tier", .{ .string = contract.capability_tier });
    try obj.put(allocator, "confidence", .{ .string = contract.confidence });
    try obj.put(allocator, "confidence_class", .{ .string = contract.confidence_class });
    try obj.put(allocator, "source_coverage", .{ .string = contract.source_coverage });
    try obj.put(allocator, "limitations", try stringArrayValue(allocator, contract.limitations));
    return .{ .object = obj };
}

/// Returns an allocator-owned JSON value for cross check.
pub fn crossCheckValue(allocator: std.mem.Allocator, contract: Contract) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "required_for_release_gate", .{ .bool = false });
    if (contract.verify_with.len > 0) {
        try obj.put(allocator, "primary", .{ .string = contract.verify_with[0] });
    } else {
        try obj.put(allocator, "primary", .null);
    }
    try obj.put(allocator, "verify_with", try stringArrayValue(allocator, contract.verify_with));
    return .{ .object = obj };
}

/// Copies a string slice into an allocator-owned JSON array.
pub fn stringArrayValue(allocator: std.mem.Allocator, values: []const []const u8) !std.json.Value {
    var array = std.json.Array.init(allocator);
    for (values) |value| try array.append(.{ .string = value });
    return .{ .array = array };
}
