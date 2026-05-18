const std = @import("std");
const tooling = @import("tooling.zig");

pub const ToolId = enum {
    zigar_capabilities,
    zigar_tool_index,
    zigar_schema,
    zigar_doctor,
    zigar_workspace_info,
    zigar_metrics,
    zigar_http_status,
    zigar_context_pack,
    zigar_next_action,
    zigar_agent_guide,
    zigar_validate_patch,
    zigar_failure_fusion,
    zigar_impact,
    zigar_project_profile,
    zigar_patch_guard,
    zig_command_plan,
    zig_toolchain_resolve,
    zig_version,
    zig_env,
    zig_targets,
    zig_build,
    zig_test,
    zig_check,
    zig_compile_error_index,
    zig_explain_errors,
    zig_translate_c,
    zig_format,
    zig_format_check,
    zig_patch_preview,
    zig_rename,
    zig_code_actions,
    zig_code_action_apply,
    zig_document_open,
    zig_document_change,
    zig_document_close,
    zig_document_status,
    zig_diagnostics,
    zig_diagnostics_all,
    zig_diagnostics_workspace,
    zig_hover,
    zig_definition,
    zig_references,
    zig_completion,
    zig_signature_help,
    zig_document_symbols,
    zig_workspace_symbols,
    zig_builtin_list,
    zig_builtin_list_json,
    zig_builtin_doc,
    zig_std_search,
    zig_std_search_json,
    zig_std_item,
    zig_lang_ref_search,
    zig_import_graph,
    zig_import_graph_json,
    zig_decl_summary,
    zig_decl_summary_json,
    zig_allocations,
    zig_error_sets,
    zig_public_api,
    zig_dead_decl_candidates,
    zig_build_graph,
    zig_build_targets,
    zig_build_options,
    zig_file_owner,
    zig_import_resolve,
    zig_test_discover,
    zig_changed_files_plan,
    zig_dependency_inspect,
    zig_target_matrix_plan,
    zig_test_failure_triage,
    zig_workspace_symbol_cache,
    zig_package_cache_doctor,
    zig_test_map,
    zig_test_select,
    zig_public_api_diff,
    zig_ci_annotations,
    zig_junit,
    zig_matrix_check,
    zig_lint,
    zig_lint_sarif,
    zig_lint_rules,
    zig_analysis_graphs,
    zig_profile_plan,
    zig_profile_run,
    zig_flamegraph,
    zig_flamegraph_diff,
};

pub const ToolMeta = struct {
    id: ToolId,
    name: []const u8,
    description: []const u8,
    input_schema: tooling.SchemaSpec,
    read_only: bool,
};

pub const ToolRisk = struct {
    writes_source: bool = false,
    writes_artifacts: bool = false,
    writes_require_apply: bool = false,
    preview_by_default: bool = false,
    mutates_lsp_state: bool = false,
    executes_project_code: bool = false,
    executes_user_command: bool = false,
    executes_backend: bool = false,
};

fn schema(comptime fields: []const tooling.SchemaField) tooling.SchemaSpec {
    return tooling.schema(fields);
}

pub const specs = [_]ToolMeta{
    .{ .id = .zigar_capabilities, .name = "zigar_capabilities", .description = "Return a compact zigar tool/capability index with search keywords, including fmt, formatter, formatting, and zig fmt.", .input_schema = schema(&.{}), .read_only = true },
    .{ .id = .zigar_tool_index, .name = "zigar_tool_index", .description = "Return a compact searchable zigar tool index with aliases for fmt, formatter, formatting, zig fmt, docs, ZLS, lint, and profiling.", .input_schema = schema(&.{}), .read_only = true },
    .{ .id = .zigar_schema, .name = "zigar_schema", .description = "Return zigar's compact tool catalog and schema-discovery hints.", .input_schema = schema(&.{}), .read_only = true },
    .{ .id = .zigar_doctor, .name = "zigar_doctor", .description = "Diagnose common zigar MCP configuration, workspace, backend, and transport problems.", .input_schema = schema(&.{ .{ "probe_backends", "boolean", false }, .{ "timeout_ms", "integer", false } }), .read_only = true },
    .{ .id = .zigar_workspace_info, .name = "zigar_workspace_info", .description = "Return workspace and configured backend paths.", .input_schema = schema(&.{}), .read_only = true },
    .{ .id = .zigar_metrics, .name = "zigar_metrics", .description = "Return zigar process counters and backend health.", .input_schema = schema(&.{}), .read_only = true },
    .{ .id = .zigar_http_status, .name = "zigar_http_status", .description = "Report HTTP transport support and configured endpoint.", .input_schema = schema(&.{}), .read_only = true },
    .{ .id = .zigar_context_pack, .name = "zigar_context_pack", .description = "Return a compact deterministic Zig project context pack for agent orientation.", .input_schema = schema(&.{ .{ "mode", "string", false }, .{ "token_budget", "integer", false }, .{ "include", "string", false } }), .read_only = true },
    .{ .id = .zigar_next_action, .name = "zigar_next_action", .description = "Route a Zig development goal to the next deterministic zigar tool calls.", .input_schema = schema(&.{ .{ "goal", "string", true }, .{ "changed_files", "string", false }, .{ "last_error", "string", false } }), .read_only = true },
    .{ .id = .zigar_agent_guide, .name = "zigar_agent_guide", .description = "Return compact Codex/Claude/generic instructions for using zigar efficiently.", .input_schema = schema(&.{ .{ "client", "string", false }, .{ "task", "string", false } }), .read_only = true },
    .{ .id = .zigar_validate_patch, .name = "zigar_validate_patch", .description = "Run an agent-friendly changed-file validation loop and return structured blockers.", .input_schema = schema(&.{ .{ "mode", "string", false }, .{ "changed_files", "string", false }, .{ "stop_on_failure", "boolean", false }, .{ "timeout_ms", "integer", false } }), .read_only = true },
    .{ .id = .zigar_failure_fusion, .name = "zigar_failure_fusion", .description = "Fuse compiler/test output, primary failure data, impact hints, and suggested zigar tools.", .input_schema = schema(&.{ .{ "text", "string", false }, .{ "command", "string", false }, .{ "file", "string", false }, .{ "args", "string", false }, .{ "timeout_ms", "integer", false } }), .read_only = true },
    .{ .id = .zigar_impact, .name = "zigar_impact", .description = "Analyze affected imports, tests, public API, and validation commands for files or symbols.", .input_schema = schema(&.{ .{ "files", "string", false }, .{ "symbols", "string", false }, .{ "limit", "integer", false } }), .read_only = true },
    .{ .id = .zigar_project_profile, .name = "zigar_project_profile", .description = "Read or explicitly write a workspace-local deterministic zigar project profile.", .input_schema = schema(&.{ .{ "apply", "boolean", false }, .{ "content", "string", false } }), .read_only = false },
    .{ .id = .zigar_patch_guard, .name = "zigar_patch_guard", .description = "Validate proposed patch/file paths against zigar workspace and generated-path safety rules.", .input_schema = schema(&.{ .{ "files", "string", false }, .{ "patch", "string", false } }), .read_only = true },
    .{ .id = .zig_command_plan, .name = "zig_command_plan", .description = "Preview the exact argv/cwd/timeout for a deterministic zigar command workflow.", .input_schema = schema(&.{ .{ "tool", "string", true }, .{ "file", "string", false }, .{ "path", "string", false }, .{ "args", "string", false }, .{ "timeout_ms", "integer", false } }), .read_only = true },
    .{ .id = .zig_toolchain_resolve, .name = "zig_toolchain_resolve", .description = "Detect active Zig/ZLS versions, project version hints, and installed Zig version managers.", .input_schema = schema(&.{ .{ "probe_managers", "boolean", false }, .{ "timeout_ms", "integer", false } }), .read_only = true },
    .{ .id = .zig_version, .name = "zig_version", .description = "Return Zig and ZLS version information.", .input_schema = schema(&.{}), .read_only = true },
    .{ .id = .zig_env, .name = "zig_env", .description = "Run `zig env`.", .input_schema = schema(&.{}), .read_only = true },
    .{ .id = .zig_targets, .name = "zig_targets", .description = "Run `zig targets`.", .input_schema = schema(&.{}), .read_only = true },
    .{ .id = .zig_build, .name = "zig_build", .description = "Run `zig build` in the workspace.", .input_schema = schema(&.{ .{ "args", "string", false }, .{ "timeout_ms", "integer", false } }), .read_only = true },
    .{ .id = .zig_test, .name = "zig_test", .description = "Run Zig tests. Uses `zig test <file>` when file is provided, otherwise `zig build test`.", .input_schema = schema(&.{ .{ "file", "string", false }, .{ "filter", "string", false }, .{ "args", "string", false }, .{ "timeout_ms", "integer", false } }), .read_only = true },
    .{ .id = .zig_check, .name = "zig_check", .description = "Run `zig ast-check` on a workspace Zig file.", .input_schema = schema(&.{ .{ "file", "string", true }, .{ "timeout_ms", "integer", false } }), .read_only = true },
    .{ .id = .zig_compile_error_index, .name = "zig_compile_error_index", .description = "Parse compiler output or run a focused Zig command and return grouped compile diagnostics.", .input_schema = schema(&.{ .{ "text", "string", false }, .{ "command", "string", false }, .{ "file", "string", false }, .{ "args", "string", false }, .{ "timeout_ms", "integer", false } }), .read_only = true },
    .{ .id = .zig_explain_errors, .name = "zig_explain_errors", .description = "Run a focused Zig command and return parsed compiler findings plus deterministic next actions.", .input_schema = schema(&.{ .{ "command", "string", false }, .{ "file", "string", false }, .{ "args", "string", false }, .{ "timeout_ms", "integer", false } }), .read_only = true },
    .{ .id = .zig_translate_c, .name = "zig_translate_c", .description = "Run `zig translate-c` on a workspace C header/source file.", .input_schema = schema(&.{ .{ "file", "string", true }, .{ "args", "string", false }, .{ "timeout_ms", "integer", false } }), .read_only = true },
    .{ .id = .zig_format, .name = "zig_format", .description = "Format a Zig file. Returns preview by default; writes only with apply=true.", .input_schema = schema(&.{ .{ "file", "string", true }, .{ "apply", "boolean", false }, .{ "content", "string", false } }), .read_only = false },
    .{ .id = .zig_format_check, .name = "zig_format_check", .description = "Run `zig fmt --check` on a workspace file or directory.", .input_schema = schema(&.{ .{ "path", "string", true }, .{ "timeout_ms", "integer", false } }), .read_only = true },
    .{ .id = .zig_patch_preview, .name = "zig_patch_preview", .description = "Preview a replacement-content patch with hashes and unified diff; writes only with apply=true.", .input_schema = schema(&.{ .{ "file", "string", true }, .{ "content", "string", true }, .{ "apply", "boolean", false } }), .read_only = false },
    .{ .id = .zig_rename, .name = "zig_rename", .description = "Request a ZLS workspace edit for a symbol rename. Returns preview by default; writes only with apply=true.", .input_schema = schema(&.{ .{ "file", "string", true }, .{ "content", "string", false }, .{ "line", "integer", true }, .{ "character", "integer", true }, .{ "new_name", "string", true }, .{ "apply", "boolean", false } }), .read_only = false },
    .{ .id = .zig_code_actions, .name = "zig_code_actions", .description = "Get ZLS code actions for a range.", .input_schema = schema(&.{ .{ "file", "string", true }, .{ "content", "string", false }, .{ "start_line", "integer", true }, .{ "start_char", "integer", true }, .{ "end_line", "integer", true }, .{ "end_char", "integer", true } }), .read_only = true },
    .{ .id = .zig_code_action_apply, .name = "zig_code_action_apply", .description = "Preview or apply one ZLS code action by index. Writes only with apply=true.", .input_schema = schema(&.{ .{ "file", "string", true }, .{ "content", "string", false }, .{ "start_line", "integer", true }, .{ "start_char", "integer", true }, .{ "end_line", "integer", true }, .{ "end_char", "integer", true }, .{ "action_index", "integer", true }, .{ "apply", "boolean", false } }), .read_only = false },
    .{ .id = .zig_document_open, .name = "zig_document_open", .description = "Open or replace an in-memory Zig document in the ZLS session.", .input_schema = schema(&.{ .{ "file", "string", true }, .{ "content", "string", true } }), .read_only = false },
    .{ .id = .zig_document_change, .name = "zig_document_change", .description = "Replace an already-open in-memory Zig document in the ZLS session.", .input_schema = schema(&.{ .{ "file", "string", true }, .{ "content", "string", true } }), .read_only = false },
    .{ .id = .zig_document_close, .name = "zig_document_close", .description = "Close a Zig document in the ZLS session.", .input_schema = schema(&.{.{ "file", "string", true }}), .read_only = false },
    .{ .id = .zig_document_status, .name = "zig_document_status", .description = "Return tracked ZLS document version/hash/dirty metadata.", .input_schema = schema(&.{.{ "file", "string", true }}), .read_only = true },
    .{ .id = .zig_diagnostics, .name = "zig_diagnostics", .description = "Open a Zig file in ZLS and return the latest publishDiagnostics notification when available, with ast-check fallback.", .input_schema = schema(&.{ .{ "file", "string", true }, .{ "content", "string", false }, .{ "wait_ms", "integer", false } }), .read_only = true },
    .{ .id = .zig_diagnostics_all, .name = "zig_diagnostics_all", .description = "Aggregate diagnostics from ZLS publish/pull diagnostics and `zig ast-check`.", .input_schema = schema(&.{ .{ "file", "string", true }, .{ "content", "string", false }, .{ "wait_ms", "integer", false }, .{ "timeout_ms", "integer", false } }), .read_only = true },
    .{ .id = .zig_diagnostics_workspace, .name = "zig_diagnostics_workspace", .description = "Return cached workspace diagnostics grouped by file and severity.", .input_schema = schema(&.{}), .read_only = true },
    .{ .id = .zig_hover, .name = "zig_hover", .description = "Get ZLS hover information for a Zig symbol.", .input_schema = schema(&.{ .{ "file", "string", true }, .{ "content", "string", false }, .{ "line", "integer", true }, .{ "character", "integer", true } }), .read_only = true },
    .{ .id = .zig_definition, .name = "zig_definition", .description = "Get ZLS definition location for a Zig symbol.", .input_schema = schema(&.{ .{ "file", "string", true }, .{ "content", "string", false }, .{ "line", "integer", true }, .{ "character", "integer", true } }), .read_only = true },
    .{ .id = .zig_references, .name = "zig_references", .description = "Find ZLS references for a Zig symbol.", .input_schema = schema(&.{ .{ "file", "string", true }, .{ "content", "string", false }, .{ "line", "integer", true }, .{ "character", "integer", true }, .{ "include_declaration", "boolean", false } }), .read_only = true },
    .{ .id = .zig_completion, .name = "zig_completion", .description = "Get ZLS completions at a Zig source position.", .input_schema = schema(&.{ .{ "file", "string", true }, .{ "content", "string", false }, .{ "line", "integer", true }, .{ "character", "integer", true } }), .read_only = true },
    .{ .id = .zig_signature_help, .name = "zig_signature_help", .description = "Get ZLS signature help at a Zig source position.", .input_schema = schema(&.{ .{ "file", "string", true }, .{ "content", "string", false }, .{ "line", "integer", true }, .{ "character", "integer", true } }), .read_only = true },
    .{ .id = .zig_document_symbols, .name = "zig_document_symbols", .description = "List ZLS document symbols for a Zig source file.", .input_schema = schema(&.{ .{ "file", "string", true }, .{ "content", "string", false } }), .read_only = true },
    .{ .id = .zig_workspace_symbols, .name = "zig_workspace_symbols", .description = "Search ZLS workspace symbols matching a query.", .input_schema = schema(&.{ .{ "query", "string", true }, .{ "limit", "integer", false } }), .read_only = true },
    .{ .id = .zig_builtin_list, .name = "zig_builtin_list", .description = "List curated Zig builtin docs bundled with zigar.", .input_schema = schema(&.{}), .read_only = true },
    .{ .id = .zig_builtin_list_json, .name = "zig_builtin_list_json", .description = "Return curated Zig builtin docs as JSON-native records.", .input_schema = schema(&.{}), .read_only = true },
    .{ .id = .zig_builtin_doc, .name = "zig_builtin_doc", .description = "Search curated Zig builtin docs.", .input_schema = schema(&.{.{ "query", "string", true }}), .read_only = true },
    .{ .id = .zig_std_search, .name = "zig_std_search", .description = "Search local Zig standard library source for a query.", .input_schema = schema(&.{ .{ "query", "string", true }, .{ "limit", "integer", false } }), .read_only = true },
    .{ .id = .zig_std_search_json, .name = "zig_std_search_json", .description = "Search local Zig standard library source and return JSON-native records.", .input_schema = schema(&.{ .{ "query", "string", true }, .{ "limit", "integer", false } }), .read_only = true },
    .{ .id = .zig_std_item, .name = "zig_std_item", .description = "Search local Zig standard library source for a fully qualified item string.", .input_schema = schema(&.{ .{ "name", "string", true }, .{ "limit", "integer", false } }), .read_only = true },
    .{ .id = .zig_lang_ref_search, .name = "zig_lang_ref_search", .description = "Search Zig's installed documentation sources.", .input_schema = schema(&.{ .{ "query", "string", true }, .{ "limit", "integer", false } }), .read_only = true },
    .{ .id = .zig_import_graph, .name = "zig_import_graph", .description = "Build a heuristic import graph from workspace Zig files.", .input_schema = schema(&.{.{ "limit", "integer", false }}), .read_only = true },
    .{ .id = .zig_import_graph_json, .name = "zig_import_graph_json", .description = "Build a JSON-native heuristic import graph from workspace Zig files.", .input_schema = schema(&.{.{ "limit", "integer", false }}), .read_only = true },
    .{ .id = .zig_decl_summary, .name = "zig_decl_summary", .description = "Summarize declarations in a Zig file.", .input_schema = schema(&.{.{ "file", "string", true }}), .read_only = true },
    .{ .id = .zig_decl_summary_json, .name = "zig_decl_summary_json", .description = "Return JSON-native declaration summary for a Zig file.", .input_schema = schema(&.{.{ "file", "string", true }}), .read_only = true },
    .{ .id = .zig_allocations, .name = "zig_allocations", .description = "Find allocation-related call sites in a Zig file.", .input_schema = schema(&.{.{ "file", "string", true }}), .read_only = true },
    .{ .id = .zig_error_sets, .name = "zig_error_sets", .description = "Find error-related sites in a Zig file.", .input_schema = schema(&.{.{ "file", "string", true }}), .read_only = true },
    .{ .id = .zig_public_api, .name = "zig_public_api", .description = "Find public API declarations in a Zig file.", .input_schema = schema(&.{.{ "file", "string", true }}), .read_only = true },
    .{ .id = .zig_dead_decl_candidates, .name = "zig_dead_decl_candidates", .description = "List private declaration candidates that need reference checks before deletion.", .input_schema = schema(&.{.{ "file", "string", true }}), .read_only = true },
    .{ .id = .zig_build_graph, .name = "zig_build_graph", .description = "Parse build.zig/build.zig.zon heuristically into modules, dependencies, build steps, and artifacts.", .input_schema = schema(&.{}), .read_only = true },
    .{ .id = .zig_build_targets, .name = "zig_build_targets", .description = "Return build steps, artifacts, modules, and suggested zig build commands.", .input_schema = schema(&.{}), .read_only = true },
    .{ .id = .zig_build_options, .name = "zig_build_options", .description = "Discover available `zig build -D...` options from build.zig and standard Zig build knobs.", .input_schema = schema(&.{}), .read_only = true },
    .{ .id = .zig_file_owner, .name = "zig_file_owner", .description = "Map a workspace Zig file to likely build module/artifact/test commands.", .input_schema = schema(&.{.{ "file", "string", true }}), .read_only = true },
    .{ .id = .zig_import_resolve, .name = "zig_import_resolve", .description = "Resolve a Zig @import string against workspace modules, packages, stdlib, or a source file.", .input_schema = schema(&.{ .{ "import", "string", true }, .{ "from", "string", false } }), .read_only = true },
    .{ .id = .zig_test_discover, .name = "zig_test_discover", .description = "Discover Zig test declarations and runnable test commands.", .input_schema = schema(&.{.{ "limit", "integer", false }}), .read_only = true },
    .{ .id = .zig_changed_files_plan, .name = "zig_changed_files_plan", .description = "Inspect git changes and recommend the smallest useful Zig validation commands.", .input_schema = schema(&.{.{ "timeout_ms", "integer", false }}), .read_only = true },
    .{ .id = .zig_dependency_inspect, .name = "zig_dependency_inspect", .description = "Inspect build.zig.zon dependencies, hashes, local package/cache state, and dependency wiring risks.", .input_schema = schema(&.{}), .read_only = true },
    .{ .id = .zig_target_matrix_plan, .name = "zig_target_matrix_plan", .description = "Plan cross-target Zig build/test matrix commands without running them.", .input_schema = schema(&.{ .{ "targets", "string", false }, .{ "steps", "string", false } }), .read_only = true },
    .{ .id = .zig_test_failure_triage, .name = "zig_test_failure_triage", .description = "Parse Zig test output or run tests and return failing tests, panic clues, and rerun commands.", .input_schema = schema(&.{ .{ "text", "string", false }, .{ "file", "string", false }, .{ "filter", "string", false }, .{ "args", "string", false }, .{ "timeout_ms", "integer", false } }), .read_only = true },
    .{ .id = .zig_workspace_symbol_cache, .name = "zig_workspace_symbol_cache", .description = "Build or inspect a cached heuristic workspace symbol/import index for repeated MCP calls.", .input_schema = schema(&.{ .{ "refresh", "boolean", false }, .{ "query", "string", false }, .{ "limit", "integer", false } }), .read_only = true },
    .{ .id = .zig_package_cache_doctor, .name = "zig_package_cache_doctor", .description = "Diagnose Zig package/cache directories, git-tracked generated artifacts, and package hash risks.", .input_schema = schema(&.{.{ "timeout_ms", "integer", false }}), .read_only = true },
    .{ .id = .zig_test_map, .name = "zig_test_map", .description = "Build a deterministic map of Zig test declarations, files, likely symbols, and test commands.", .input_schema = schema(&.{.{ "limit", "integer", false }}), .read_only = true },
    .{ .id = .zig_test_select, .name = "zig_test_select", .description = "Select focused Zig test commands for changed files or symbols.", .input_schema = schema(&.{ .{ "files", "string", false }, .{ "symbols", "string", false }, .{ "limit", "integer", false } }), .read_only = true },
    .{ .id = .zig_public_api_diff, .name = "zig_public_api_diff", .description = "Compare public Zig declarations from git baseline/text/current file and report likely breaking changes.", .input_schema = schema(&.{ .{ "file", "string", false }, .{ "before", "string", false }, .{ "after", "string", false }, .{ "baseline_ref", "string", false } }), .read_only = true },
    .{ .id = .zig_ci_annotations, .name = "zig_ci_annotations", .description = "Convert diagnostics/check output into CI annotation records.", .input_schema = schema(&.{ .{ "file", "string", true }, .{ "timeout_ms", "integer", false } }), .read_only = true },
    .{ .id = .zig_junit, .name = "zig_junit", .description = "Run Zig tests and return a minimal JUnit XML artifact.", .input_schema = schema(&.{ .{ "file", "string", false }, .{ "filter", "string", false }, .{ "args", "string", false }, .{ "timeout_ms", "integer", false } }), .read_only = true },
    .{ .id = .zig_matrix_check, .name = "zig_matrix_check", .description = "Run build/test checks across configured Zig binaries.", .input_schema = schema(&.{ .{ "zig_paths", "string", false }, .{ "args", "string", false }, .{ "timeout_ms", "integer", false } }), .read_only = true },
    .{ .id = .zig_lint, .name = "zig_lint", .description = "Run zwanzig as optional Zig static-analysis backend with JSON output by default.", .input_schema = schema(&.{ .{ "path", "string", false }, .{ "rules_do", "string", false }, .{ "rules_skip", "string", false }, .{ "config", "string", false }, .{ "args", "string", false } }), .read_only = true },
    .{ .id = .zig_lint_sarif, .name = "zig_lint_sarif", .description = "Run zwanzig with SARIF output.", .input_schema = schema(&.{ .{ "path", "string", false }, .{ "rules_do", "string", false }, .{ "rules_skip", "string", false }, .{ "config", "string", false }, .{ "args", "string", false } }), .read_only = true },
    .{ .id = .zig_lint_rules, .name = "zig_lint_rules", .description = "List zwanzig rules when the backend is installed.", .input_schema = schema(&.{}), .read_only = true },
    .{ .id = .zig_analysis_graphs, .name = "zig_analysis_graphs", .description = "Run zwanzig graph/visualization options, writing only to an explicit workspace output path.", .input_schema = schema(&.{ .{ "path", "string", true }, .{ "output", "string", true }, .{ "args", "string", false } }), .read_only = false },
    .{ .id = .zig_profile_plan, .name = "zig_profile_plan", .description = "Return platform-specific profiling capture suggestions for the workspace.", .input_schema = schema(&.{.{ "binary", "string", false }}), .read_only = true },
    .{ .id = .zig_profile_run, .name = "zig_profile_run", .description = "Run a user-specified profiler command in the workspace.", .input_schema = schema(&.{ .{ "command", "string", true }, .{ "timeout_ms", "integer", false } }), .read_only = true },
    .{ .id = .zig_flamegraph, .name = "zig_flamegraph", .description = "Convert profiler output to SVG through zflame.", .input_schema = schema(&.{ .{ "format", "string", false }, .{ "input", "string", true }, .{ "output", "string", true }, .{ "title", "string", false }, .{ "palette", "string", false }, .{ "min_width", "string", false }, .{ "hash", "boolean", false } }), .read_only = false },
    .{ .id = .zig_flamegraph_diff, .name = "zig_flamegraph_diff", .description = "Create a differential folded stack file through diff-folded, then render it through zflame.", .input_schema = schema(&.{ .{ "before", "string", true }, .{ "after", "string", true }, .{ "output", "string", true }, .{ "title", "string", false } }), .read_only = false },
};

pub fn find(name: []const u8) ?ToolMeta {
    for (specs) |spec| {
        if (std.mem.eql(u8, spec.name, name)) return spec;
    }
    return null;
}

pub fn riskFor(id: ToolId) ToolRisk {
    return switch (id) {
        .zig_format,
        .zig_patch_preview,
        .zig_rename,
        .zig_code_action_apply,
        => .{
            .writes_source = true,
            .writes_artifacts = id == .zig_format,
            .writes_require_apply = true,
            .preview_by_default = true,
            .executes_backend = id == .zig_format or id == .zig_rename or id == .zig_code_action_apply,
        },

        .zigar_project_profile,
        => .{ .writes_artifacts = true, .writes_require_apply = true, .preview_by_default = true },

        .zig_analysis_graphs,
        .zig_flamegraph,
        .zig_flamegraph_diff,
        => .{ .writes_artifacts = true, .executes_backend = id != .zigar_project_profile },

        .zig_document_open,
        .zig_document_change,
        .zig_document_close,
        => .{ .mutates_lsp_state = true, .executes_backend = true },

        .zig_build,
        .zig_test,
        .zig_junit,
        => .{ .writes_artifacts = true, .executes_project_code = true, .executes_backend = true },

        .zig_matrix_check,
        => .{ .writes_artifacts = true, .executes_project_code = true, .executes_user_command = true, .executes_backend = true },

        .zigar_validate_patch,
        .zigar_failure_fusion,
        .zig_compile_error_index,
        .zig_explain_errors,
        .zig_test_failure_triage,
        => .{ .writes_artifacts = true, .executes_project_code = true, .executes_backend = true },

        .zig_profile_run,
        => .{ .writes_artifacts = true, .executes_user_command = true, .executes_project_code = true },

        .zigar_doctor,
        .zig_toolchain_resolve,
        .zig_version,
        .zig_env,
        .zig_targets,
        .zig_changed_files_plan,
        .zig_package_cache_doctor,
        .zig_public_api_diff,
        => .{ .executes_backend = true },

        .zig_check,
        .zig_translate_c,
        .zig_format_check,
        .zig_diagnostics,
        .zig_diagnostics_all,
        .zig_hover,
        .zig_definition,
        .zig_references,
        .zig_completion,
        .zig_signature_help,
        .zig_document_symbols,
        .zig_workspace_symbols,
        .zig_lint,
        .zig_lint_sarif,
        .zig_lint_rules,
        .zig_ci_annotations,
        => .{ .executes_backend = true },

        else => .{},
    };
}

pub fn riskLevel(risk: ToolRisk) []const u8 {
    if (risk.writes_source or risk.executes_user_command) return "high";
    if (risk.executes_project_code or risk.writes_artifacts) return "medium";
    if (risk.mutates_lsp_state or risk.executes_backend) return "low";
    return "none";
}

pub fn destructiveHintFor(spec: ToolMeta) bool {
    const risk = riskFor(spec.id);
    if (risk.writes_require_apply and risk.preview_by_default) return false;
    return !spec.read_only;
}

test "tool names are unique" {
    try std.testing.expectEqual(@typeInfo(ToolId).@"enum".fields.len, specs.len);
    for (specs, 0..) |left, left_index| {
        for (specs[left_index + 1 ..]) |right| {
            try std.testing.expect(!std.mem.eql(u8, left.name, right.name));
        }
    }
}

test "tool schemas use validator-supported JSON field types" {
    for (specs) |spec| {
        for (spec.input_schema.fields) |field| {
            try std.testing.expect(std.mem.eql(u8, field[1], "string") or
                std.mem.eql(u8, field[1], "boolean") or
                std.mem.eql(u8, field[1], "integer"));
        }
    }
}

test "risk metadata distinguishes read-only annotations from code execution" {
    try std.testing.expect(find("zig_profile_run").?.read_only);
    const profile_risk = riskFor(.zig_profile_run);
    try std.testing.expect(profile_risk.executes_user_command);
    try std.testing.expectEqualStrings("high", riskLevel(profile_risk));

    const build_risk = riskFor(.zig_build);
    try std.testing.expect(build_risk.executes_project_code);
    try std.testing.expectEqualStrings("medium", riskLevel(build_risk));

    const validation_risk = riskFor(.zigar_validate_patch);
    try std.testing.expect(validation_risk.executes_project_code);
    try std.testing.expect(validation_risk.writes_artifacts);

    const triage_risk = riskFor(.zig_test_failure_triage);
    try std.testing.expect(triage_risk.executes_project_code);

    const fmt = find("zig_format").?;
    try std.testing.expect(riskFor(.zig_format).writes_require_apply);
    try std.testing.expect(riskFor(.zig_format).writes_artifacts);
    try std.testing.expect(!destructiveHintFor(fmt));

    const matrix_risk = riskFor(.zig_matrix_check);
    try std.testing.expect(matrix_risk.executes_user_command);
    try std.testing.expectEqualStrings("high", riskLevel(matrix_risk));
}
