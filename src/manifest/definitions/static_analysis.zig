const types = @import("../types.zig");

const schema = types.schema;
const schemaWithHints = types.schemaWithHints;
const outputSchema = types.outputSchema;
const tool = types.tool;
const fieldHint = types.fieldHint;

/// Build a heuristic import graph from workspace Zig files.
pub const zig_import_graph = tool(.{
    .description = "Build a heuristic import graph from workspace Zig files.",
    .input_schema = schema(&.{.{ "limit", "integer", false }}),
    .read_only = true,
    .group = .static_analysis,
    .plan = .{ .pure_analysis = "Static workspace analysis; reads project files and returns deterministic guidance without executing backends." },
    .static_analysis_tier = .advisory_orientation,
});
/// Build a JSON-native heuristic import graph from workspace Zig files.
pub const zig_import_graph_json = tool(.{
    .description = "Build a JSON-native heuristic import graph from workspace Zig files.",
    .input_schema = schema(&.{.{ "limit", "integer", false }}),
    .output_schema = outputSchema(.analysis_result),
    .read_only = true,
    .group = .static_analysis,
    .plan = .{ .pure_analysis = "Static workspace analysis; reads project files and returns deterministic guidance without executing backends." },
    .static_analysis_tier = .advisory_orientation,
});
/// Detect architecture-neutral import cycles from workspace Zig imports.
pub const zig_import_cycles = tool(.{
    .description = "Detect architecture-neutral import cycles from workspace Zig imports, returning SCCs, cycle paths, topological depths, severity, confidence, and limitations.",
    .input_schema = schema(&.{.{ "limit", "integer", false }}),
    .output_schema = outputSchema(.analysis_result),
    .read_only = true,
    .group = .static_analysis,
    .plan = .{ .pure_analysis = "Static workspace analysis; post-processes import graph evidence without executing backends or applying project-specific architecture policy." },
    .static_analysis_tier = .advisory_orientation,
});
/// Return parser-backed import calls for one Zig source file.
pub const zig_ast_imports = tool(.{ .description = "Return parser-backed @import calls for a Zig file using std.zig.Ast tokens.", .input_schema = schema(&.{.{ "file", "string", true }}), .read_only = true, .group = .static_analysis, .plan = .{ .pure_analysis = "Parser-backed source analysis; parses one Zig file with std.zig.Ast without executing compiler semantic analysis." }, .static_analysis_tier = .parser_backed });
/// Heuristically summarize declarations in a Zig file.
pub const zig_decl_summary = tool(.{
    .description = "Heuristically summarize declarations in a Zig file.",
    .input_schema = schema(&.{.{ "file", "string", true }}),
    .read_only = true,
    .group = .static_analysis,
    .plan = .{ .pure_analysis = "Static workspace analysis; reads project files and returns deterministic guidance without executing backends." },
    .static_analysis_tier = .advisory_orientation,
});
/// Return a JSON-native heuristic declaration summary for a Zig file.
pub const zig_decl_summary_json = tool(.{
    .description = "Return a JSON-native heuristic declaration summary for a Zig file.",
    .input_schema = schema(&.{.{ "file", "string", true }}),
    .read_only = true,
    .group = .static_analysis,
    .plan = .{ .pure_analysis = "Static workspace analysis; reads project files and returns deterministic guidance without executing backends." },
    .static_analysis_tier = .advisory_orientation,
});
/// Return a parser-backed declaration summary for one Zig source file.
pub const zig_ast_decl_summary = tool(.{ .description = "Return a parser-backed declaration summary for a Zig file using std.zig.Ast.", .input_schema = schema(&.{.{ "file", "string", true }}), .read_only = true, .group = .static_analysis, .plan = .{ .pure_analysis = "Parser-backed source analysis; parses one Zig file with std.zig.Ast without executing compiler semantic analysis." }, .static_analysis_tier = .parser_backed });
/// Find likely allocation-related call sites in a Zig file.
pub const zig_allocations = tool(.{
    .description = "Find likely allocation-related call sites in a Zig file.",
    .input_schema = schema(&.{.{ "file", "string", true }}),
    .read_only = true,
    .group = .static_analysis,
    .plan = .{ .pure_analysis = "Static workspace analysis; reads project files and returns deterministic guidance without executing backends." },
    .static_analysis_tier = .advisory_orientation,
});
/// Find likely error-related sites in a Zig file.
pub const zig_error_sets = tool(.{
    .description = "Find likely error-related sites in a Zig file.",
    .input_schema = schema(&.{.{ "file", "string", true }}),
    .read_only = true,
    .group = .static_analysis,
    .plan = .{ .pure_analysis = "Static workspace analysis; reads project files and returns deterministic guidance without executing backends." },
    .static_analysis_tier = .advisory_orientation,
});
/// Find likely public API declarations in a Zig file.
pub const zig_public_api = tool(.{
    .description = "Find likely public API declarations in a Zig file.",
    .input_schema = schema(&.{.{ "file", "string", true }}),
    .read_only = true,
    .group = .static_analysis,
    .plan = .{ .pure_analysis = "Static workspace analysis; reads project files and returns deterministic guidance without executing backends." },
    .static_analysis_tier = .advisory_orientation,
});
/// List private declaration candidates that need reference checks before deletion.
pub const zig_dead_decl_candidates = tool(.{
    .description = "List private declaration candidates that need reference checks before deletion.",
    .input_schema = schema(&.{.{ "file", "string", true }}),
    .read_only = true,
    .group = .static_analysis,
    .plan = .{ .pure_analysis = "Static workspace analysis; reads project files and returns deterministic guidance without executing backends." },
    .static_analysis_tier = .advisory_orientation,
});
/// Parse build files into modules, dependencies, steps, and artifacts.
pub const zig_build_graph = tool(.{
    .description = "Parse build.zig/build.zig.zon heuristically into modules, dependencies, build steps, and artifacts.",
    .input_schema = schema(&.{}),
    .read_only = true,
    .group = .static_analysis,
    .plan = .{ .pure_analysis = "Static workspace analysis; reads project files and returns deterministic guidance without executing backends." },
    .static_analysis_tier = .advisory_orientation,
});
/// Return likely build steps, artifacts, modules, and suggested zig build commands.
pub const zig_build_targets = tool(.{
    .description = "Return likely build steps, artifacts, modules, and suggested zig build commands.",
    .input_schema = schema(&.{}),
    .read_only = true,
    .group = .static_analysis,
    .plan = .{ .pure_analysis = "Static workspace analysis; reads project files and returns deterministic guidance without executing backends." },
    .static_analysis_tier = .advisory_orientation,
});
/// Heuristically discover available `zig build -D...` options.
pub const zig_build_options = tool(.{
    .description = "Heuristically discover available `zig build -D...` options from build.zig and standard Zig build knobs.",
    .input_schema = schema(&.{}),
    .read_only = true,
    .group = .static_analysis,
    .plan = .{ .pure_analysis = "Static workspace analysis; reads project files and returns deterministic guidance without executing backends." },
    .static_analysis_tier = .advisory_orientation,
});
/// Map a workspace Zig file to likely build module/artifact/test commands.
pub const zig_file_owner = tool(.{
    .description = "Map a workspace Zig file to likely build module/artifact/test commands.",
    .input_schema = schema(&.{.{ "file", "string", true }}),
    .read_only = true,
    .group = .static_analysis,
    .plan = .{ .pure_analysis = "Static workspace analysis; reads project files and returns deterministic guidance without executing backends." },
    .static_analysis_tier = .advisory_orientation,
});
/// Heuristically resolve a Zig @import string against workspace modules, packages, stdlib, or a source file.
pub const zig_import_resolve = tool(.{
    .description = "Heuristically resolve a Zig @import string against workspace modules, packages, stdlib, or a source file.",
    .input_schema = schema(&.{ .{ "import", "string", true }, .{ "from", "string", false } }),
    .read_only = true,
    .group = .static_analysis,
    .plan = .{ .pure_analysis = "Static workspace analysis; reads project files and returns deterministic guidance without executing backends." },
    .static_analysis_tier = .advisory_orientation,
});
/// Heuristically discover Zig test declarations and runnable test commands.
pub const zig_test_discover = tool(.{
    .description = "Heuristically discover Zig test declarations and runnable test commands.",
    .input_schema = schema(&.{.{ "limit", "integer", false }}),
    .read_only = true,
    .group = .static_analysis,
    .plan = .{ .pure_analysis = "Static workspace analysis; reads project files and returns deterministic guidance without executing backends." },
    .static_analysis_tier = .advisory_orientation,
});
/// Return parser-backed Zig test declarations for one source file.
pub const zig_ast_tests = tool(.{ .description = "Return parser-backed Zig test declarations for a Zig file using std.zig.Ast.", .input_schema = schema(&.{.{ "file", "string", true }}), .read_only = true, .group = .static_analysis, .plan = .{ .pure_analysis = "Parser-backed source analysis; parses one Zig file with std.zig.Ast without executing compiler semantic analysis." }, .static_analysis_tier = .parser_backed });
/// Resolve requested test filters to actual declared Zig test names.
pub const zig_test_name_resolve = tool(.{
    .description = "Resolve requested test filters to actual declared Zig test names, files, commands, duplicate-name flags, confidence, and limitations.",
    .input_schema = schemaWithHints(&.{ .{ "filters", "string", false }, .{ "limit", "integer", false } }, &.{
        fieldHint("filters", .{ .description = "Comma, whitespace, or newline separated test filters to match against declared test names." }),
    }),
    .output_schema = outputSchema(.analysis_result),
    .read_only = true,
    .group = .static_analysis,
    .plan = .{ .pure_analysis = "Parser-backed test declaration analysis; reads workspace source without executing tests." },
    .static_analysis_tier = .parser_backed,
});
/// Inventory likely test helpers, fixtures, fakes, and harness utilities.
pub const zig_test_fixture_inventory = tool(.{
    .description = "Inventory likely test helpers, fixtures, fakes, and harness utilities with bounded usage-site evidence.",
    .input_schema = schema(&.{ .{ "path", "string", false }, .{ "limit", "integer", false } }),
    .output_schema = outputSchema(.analysis_result),
    .read_only = true,
    .group = .static_analysis,
    .plan = .{ .pure_analysis = "Parser-backed and heuristic workspace source analysis; reads project files without executing tests." },
    .static_analysis_tier = .parser_backed,
});
/// Catalog safety-relevant Zig source sites for review.
pub const zig_safety_site_catalog = tool(.{
    .description = "Catalog safety-relevant Zig source sites such as @panic, unreachable, catch unreachable, and unchecked casts.",
    .input_schema = schema(&.{ .{ "path", "string", false }, .{ "limit", "integer", false } }),
    .output_schema = outputSchema(.analysis_result),
    .read_only = true,
    .group = .static_analysis,
    .plan = .{ .pure_analysis = "Line-level static source scan; masks obvious comments and strings and returns review prompts without executing code." },
    .static_analysis_tier = .advisory_orientation,
});
/// Map a symbol to likely relevant tests.
pub const zig_test_for_symbol = tool(.{
    .description = "Map a symbol to likely relevant tests using test names, declarations, and source proximity.",
    .input_schema = schema(&.{ .{ "symbol", "string", true }, .{ "limit", "integer", false } }),
    .output_schema = outputSchema(.analysis_result),
    .read_only = true,
    .group = .static_analysis,
    .plan = .{ .pure_analysis = "Advisory symbol-to-test analysis over workspace source; does not run tests or prove coverage." },
    .static_analysis_tier = .advisory_orientation,
});
/// Aggregate a directory-level Zig module surface.
pub const zig_module_surface = tool(.{
    .description = "Aggregate a directory-level Zig module surface with public exports, re-exports, consumers, unused-export candidates, and role hints.",
    .input_schema = schema(&.{ .{ "path", "string", false }, .{ "limit", "integer", false } }),
    .output_schema = outputSchema(.analysis_result),
    .read_only = true,
    .group = .static_analysis,
    .plan = .{ .pure_analysis = "Parser-backed public declaration aggregation plus source-scan consumers; architecture-neutral and read-only." },
    .static_analysis_tier = .parser_backed,
});
/// Build a symbol-scoped static dossier.
pub const zig_symbol_dossier = tool(.{
    .description = "Build a symbol-scoped dossier with declarations, public API membership, callers, tests, module hints, omitted sections, confidence, and limitations.",
    .input_schema = schema(&.{ .{ "symbol", "string", true }, .{ "limit", "integer", false } }),
    .output_schema = outputSchema(.analysis_result),
    .read_only = true,
    .group = .static_analysis,
    .plan = .{ .pure_analysis = "Architecture-neutral symbol dossier over parser and source-scan evidence; diagnostics/history/lint are explicitly omitted when unavailable." },
    .static_analysis_tier = .advisory_orientation,
});
/// Risk-rank a proposed change using static evidence.
pub const zig_change_risk_audit = tool(.{
    .description = "Risk-rank a proposed change using import/reference centrality, public API hints, test proximity, and exposed scoring weights.",
    .input_schema = schemaWithHints(&.{ .{ "files", "string", false }, .{ "symbols", "string", false }, .{ "diff", "string", false }, .{ "limit", "integer", false } }, &.{
        fieldHint("files", .{ .description = "Comma, whitespace, or newline separated workspace files to audit." }),
        fieldHint("symbols", .{ .description = "Comma, whitespace, or newline separated symbols to audit." }),
        fieldHint("diff", .{ .description = "Unified diff text to mine for changed files and public API signals." }),
    }),
    .output_schema = outputSchema(.analysis_result),
    .read_only = true,
    .group = .static_analysis,
    .plan = .{ .pure_analysis = "Static risk scoring over caller-supplied change evidence; does not enforce architecture policy or run validation." },
    .static_analysis_tier = .advisory_orientation,
});
/// Rank likely insertion sites for a topic.
pub const zig_insertion_sites = tool(.{
    .description = "Rank likely insertion sites for a topic using project-local path, declaration, import-neighborhood, and sibling-pattern evidence.",
    .input_schema = schemaWithHints(&.{ .{ "topic", "string", true }, .{ "path", "string", false }, .{ "limit", "integer", false } }, &.{
        fieldHint("topic", .{ .description = "Feature, symbol, module, or behavior topic to place in the existing codebase." }),
    }),
    .output_schema = outputSchema(.analysis_result),
    .read_only = true,
    .group = .static_analysis,
    .plan = .{ .pure_analysis = "Recommendation-oriented static ranking; reads workspace source and remains architecture-neutral." },
    .static_analysis_tier = .advisory_orientation,
});
/// Scan for Zig 0.15 to 0.16 IO migration sites without editing source.
pub const zig_io_migration_scan = tool(.{
    .description = "Scan for Zig 0.15 to 0.16 IO migration sites using a curated std.io/std.Io mapping table, confidence labels, and verification commands.",
    .input_schema = schema(&.{ .{ "path", "string", false }, .{ "limit", "integer", false } }),
    .output_schema = outputSchema(.analysis_result),
    .read_only = true,
    .group = .static_analysis,
    .plan = .{ .pure_analysis = "Parser-backed and comment/string-masked source scan; returns migration findings and verification commands without editing source." },
    .static_analysis_tier = .advisory_orientation,
});
/// Triage GeneralPurposeAllocator leak stderr into grouped allocation traces.
pub const zig_leak_triage = tool(.{
    .description = "Triage GeneralPurposeAllocator leak stderr into grouped allocation traces, repeated allocation sites, raw frames, and parser limitations.",
    .input_schema = schemaWithHints(&.{ .{ "text", "string", false }, .{ "path", "string", false }, .{ "limit", "integer", false } }, &.{
        fieldHint("text", .{ .description = "Captured GPA leak stderr text. If omitted, path is read from the workspace." }),
        fieldHint("path", .{ .description = "Workspace-relative file containing captured GPA leak stderr." }),
    }),
    .output_schema = outputSchema(.analysis_result),
    .read_only = true,
    .group = .static_analysis,
    .plan = .{ .pure_analysis = "Parser-only stderr analysis; does not execute a symbolizer or inspect host debug information." },
    .static_analysis_tier = .advisory_orientation,
});
/// Diagnose likely comptime failures from source snippets and compiler diagnostics.
pub const zig_comptime_diagnose = tool(.{
    .description = "Diagnose likely comptime failures from source snippets and compiler diagnostic text, labeling parser-only evidence and limitations.",
    .input_schema = schemaWithHints(&.{ .{ "text", "string", false }, .{ "path", "string", false }, .{ "diagnostic", "string", false }, .{ "limit", "integer", false } }, &.{
        fieldHint("diagnostic", .{ .description = "Compiler diagnostic text to mine for comptime-known/runtime-known failure clues." }),
    }),
    .output_schema = outputSchema(.analysis_result),
    .read_only = true,
    .group = .static_analysis,
    .plan = .{ .pure_analysis = "Parser-only comptime diagnosis; does not execute compiler probes or claim semantic evaluation." },
    .static_analysis_tier = .advisory_orientation,
});
const layout_measure_hint = fieldHint("measure", .{ .description = "Run optional standalone compiler-backed layout probes.", .default_bool = false });
const layout_targets_hint = fieldHint("targets", .{ .description = "Space- or comma-separated Zig target triples for compiler-backed measurements." });
const layout_comptime_hint = fieldHint("allow_project_comptime", .{ .description = "Opt in to compiling copied declarations that contain explicit comptime logic; project imports and build.zig remain disallowed.", .default_bool = false });
/// Catalog layout-sensitive Zig declarations for memory and ABI review.
pub const zig_memory_layout = tool(.{
    .description = "Catalog layout-sensitive Zig declarations and, with measure=true, run standalone compiler-backed target measurements without importing project modules or executing build.zig.",
    .input_schema = schemaWithHints(&.{ .{ "path", "string", false }, .{ "limit", "integer", false }, .{ "measure", "boolean", false }, .{ "targets", "string", false }, .{ "allow_project_comptime", "boolean", false }, .{ "timeout_ms", "integer", false } }, &.{ layout_measure_hint, layout_targets_hint, layout_comptime_hint }),
    .output_schema = outputSchema(.analysis_result),
    .read_only = true,
    .group = .static_analysis,
    .risk = .{ .writes_artifacts = true, .executes_project_code = true, .executes_backend = true },
    .plan = .{ .dynamic_command = "Default mode is parser-only; measure=true writes standalone probes under .zigars-cache and runs direct zig build-obj -fno-emit-bin commands with argv evidence." },
    .static_analysis_tier = .compiler_backed,
});
/// Catalog unsafe and boundary-sensitive Zig operations for review.
pub const zig_unsafe_operations_audit = tool(.{
    .description = "Catalog unsafe and boundary-sensitive Zig operations such as casts, unreachable paths, runtime safety toggles, volatile, extern, packed, and anyopaque sites.",
    .input_schema = schema(&.{ .{ "path", "string", false }, .{ "limit", "integer", false } }),
    .output_schema = outputSchema(.analysis_result),
    .read_only = true,
    .group = .static_analysis,
    .plan = .{ .pure_analysis = "Review-oriented source catalog; masks obvious comments and strings and does not claim the operation is incorrect." },
    .static_analysis_tier = .advisory_orientation,
});
/// Plan bounded ABI layout probes for layout-sensitive declarations.
pub const zig_abi_layout_diff = tool(.{
    .description = "Plan ABI layout probes and, with measure=true, compare standalone compiler-backed @sizeOf/@alignOf/@offsetOf/@bitOffsetOf evidence across target triples.",
    .input_schema = schemaWithHints(&.{ .{ "path", "string", false }, .{ "limit", "integer", false }, .{ "measure", "boolean", false }, .{ "targets", "string", false }, .{ "allow_project_comptime", "boolean", false }, .{ "timeout_ms", "integer", false } }, &.{ layout_measure_hint, layout_targets_hint, layout_comptime_hint }),
    .output_schema = outputSchema(.analysis_result),
    .read_only = true,
    .group = .static_analysis,
    .risk = .{ .writes_artifacts = true, .executes_project_code = true, .executes_backend = true },
    .plan = .{ .dynamic_command = "Default mode is parser-only; measure=true writes standalone probes under .zigars-cache and runs direct zig build-obj -fno-emit-bin commands for each declaration/target." },
    .static_analysis_tier = .compiler_backed,
});
/// Inspect git changes and recommend the smallest useful Zig validation commands.
pub const zig_changed_files_plan = tool(.{
    .description = "Inspect git changes and recommend the smallest useful Zig validation commands.",
    .input_schema = schema(&.{.{ "timeout_ms", "integer", false }}),
    .read_only = true,
    .group = .static_analysis,
    .risk = .{ .executes_backend = true },
    .plan = .{ .dynamic_command = "Backend-backed workflow whose exact argv depends on runtime arguments, workspace state, or configured helper paths." },
    .static_analysis_tier = .advisory_orientation,
});
/// Inspect dependency metadata, local package state, and package hash risks.
pub const zig_dependency_inspect = tool(.{
    .description = "Inspect build.zig.zon dependencies, hashes, local package/cache state, and dependency wiring risks.",
    .input_schema = schema(&.{}),
    .read_only = true,
    .group = .static_analysis,
    .plan = .{ .pure_analysis = "Static workspace analysis; reads project files and returns deterministic guidance without executing backends." },
    .static_analysis_tier = .advisory_orientation,
});
/// Plan cross-target Zig build/test matrix commands without running them.
pub const zig_target_matrix_plan = tool(.{
    .description = "Plan cross-target Zig build/test matrix commands without running them.",
    .input_schema = schema(&.{ .{ "targets", "string", false }, .{ "steps", "string", false } }),
    .read_only = true,
    .group = .static_analysis,
    .plan = .{ .pure_analysis = "Command matrix planner; returns candidate build/test commands without running them." },
    .static_analysis_tier = .advisory_orientation,
});
/// Parse Zig test output or run tests and return failing tests, panic clues, and rerun commands.
pub const zig_test_failure_triage = tool(.{
    .description = "Parse Zig test output or run tests and return failing tests, panic clues, and rerun commands.",
    .input_schema = schema(&.{ .{ "text", "string", false }, .{ "file", "string", false }, .{ "filter", "string", false }, .{ "args", "string", false }, .{ "timeout_ms", "integer", false } }),
    .read_only = true,
    .group = .static_analysis,
    .risk = .{ .writes_artifacts = true, .executes_project_code = true, .executes_backend = true },
    .plan = .{ .dynamic_command = "Backend-backed workflow whose exact argv depends on runtime arguments, workspace state, or configured helper paths." },
    .static_analysis_tier = .compiler_backed,
});
/// Build or inspect a cached heuristic workspace symbol/import index for repeated MCP calls.
pub const zig_workspace_symbol_cache = tool(.{
    .description = "Build or inspect a cached heuristic workspace symbol/import index for repeated MCP calls.",
    .input_schema = schema(&.{ .{ "refresh", "boolean", false }, .{ "query", "string", false }, .{ "limit", "integer", false } }),
    .read_only = true,
    .group = .static_analysis,
    .plan = .{ .pure_analysis = "Static workspace analysis; reads project files and returns deterministic guidance without executing backends." },
    .static_analysis_tier = .advisory_orientation,
});
/// Diagnose Zig package/cache directories, git-tracked generated artifacts, and package hash risks.
pub const zig_package_cache_doctor = tool(.{
    .description = "Diagnose Zig package/cache directories, git-tracked generated artifacts, and package hash risks.",
    .input_schema = schema(&.{.{ "timeout_ms", "integer", false }}),
    .read_only = true,
    .group = .static_analysis,
    .risk = .{ .executes_backend = true },
    .plan = .{ .dynamic_command = "Backend-backed workflow whose exact argv depends on runtime arguments, workspace state, or configured helper paths." },
    .static_analysis_tier = .advisory_orientation,
});
/// Build a deterministic map of Zig test declarations, files, likely symbols, and test commands.
pub const zig_test_map = tool(.{
    .description = "Build a deterministic map of Zig test declarations, files, likely symbols, and test commands.",
    .input_schema = schema(&.{.{ "limit", "integer", false }}),
    .read_only = true,
    .group = .static_analysis,
    .plan = .{ .pure_analysis = "Static workspace analysis; reads project files and returns deterministic guidance without executing backends." },
    .static_analysis_tier = .advisory_orientation,
});
/// Recommend focused Zig test commands for changed files or symbols.
pub const zig_test_select = tool(.{
    .description = "Recommend focused Zig test commands for changed files or symbols.",
    .input_schema = schema(&.{ .{ "files", "string", false }, .{ "symbols", "string", false }, .{ "limit", "integer", false } }),
    .read_only = true,
    .group = .static_analysis,
    .plan = .{ .pure_analysis = "Static workspace analysis; reads project files and returns deterministic guidance without executing backends." },
    .static_analysis_tier = .advisory_orientation,
});
/// Compare heuristic public Zig declaration snapshots and report likely breaking changes.
pub const zig_public_api_diff = tool(.{
    .description = "Compare heuristic public Zig declaration snapshots and report likely breaking changes.",
    .input_schema = schemaWithHints(&.{ .{ "file", "string", false }, .{ "before", "string", false }, .{ "after", "string", false }, .{ "baseline_ref", "string", false } }, &.{
        .{ .field_name = "before", .hint = .{ .description = "Baseline public API source text. Omit this and pass file/baseline_ref to read from git." } },
        .{ .field_name = "after", .hint = .{ .description = "Current public API source text. Omit this and pass file to read from the workspace." } },
    }),
    .read_only = true,
    .group = .static_analysis,
    .risk = .{ .executes_backend = true },
    .plan = .{ .dynamic_command = "Backend-backed workflow whose exact argv depends on runtime arguments, workspace state, or configured helper paths." },
    .static_analysis_tier = .advisory_orientation,
});
