const types = @import("../types.zig");

const schema = types.schema;
const schemaWithHints = types.schemaWithHints;
const tool = types.tool;
const fieldHint = types.fieldHint;

pub const zig_import_graph = tool(.{
    .description = "Build a heuristic import graph from workspace Zig files.",
    .input_schema = schema(&.{.{ "limit", "integer", false }}),
    .read_only = true,
    .group = .static_analysis,
    .plan = .{ .pure_analysis = "Static workspace analysis; reads project files and returns deterministic guidance without executing backends." },
    .static_analysis_tier = .advisory_orientation,
});
pub const zig_import_graph_json = tool(.{
    .description = "Build a JSON-native heuristic import graph from workspace Zig files.",
    .input_schema = schema(&.{.{ "limit", "integer", false }}),
    .read_only = true,
    .group = .static_analysis,
    .plan = .{ .pure_analysis = "Static workspace analysis; reads project files and returns deterministic guidance without executing backends." },
    .static_analysis_tier = .advisory_orientation,
});
pub const zig_ast_imports = tool(.{ .description = "Return parser-backed @import calls for a Zig file using std.zig.Ast tokens.", .input_schema = schema(&.{.{ "file", "string", true }}), .read_only = true, .group = .static_analysis, .plan = .{ .pure_analysis = "Parser-backed source analysis; parses one Zig file with std.zig.Ast without executing compiler semantic analysis." }, .static_analysis_tier = .parser_backed });
pub const zig_decl_summary = tool(.{
    .description = "Heuristically summarize declarations in a Zig file.",
    .input_schema = schema(&.{.{ "file", "string", true }}),
    .read_only = true,
    .group = .static_analysis,
    .plan = .{ .pure_analysis = "Static workspace analysis; reads project files and returns deterministic guidance without executing backends." },
    .static_analysis_tier = .advisory_orientation,
});
pub const zig_decl_summary_json = tool(.{
    .description = "Return a JSON-native heuristic declaration summary for a Zig file.",
    .input_schema = schema(&.{.{ "file", "string", true }}),
    .read_only = true,
    .group = .static_analysis,
    .plan = .{ .pure_analysis = "Static workspace analysis; reads project files and returns deterministic guidance without executing backends." },
    .static_analysis_tier = .advisory_orientation,
});
pub const zig_ast_decl_summary = tool(.{ .description = "Return a parser-backed declaration summary for a Zig file using std.zig.Ast.", .input_schema = schema(&.{.{ "file", "string", true }}), .read_only = true, .group = .static_analysis, .plan = .{ .pure_analysis = "Parser-backed source analysis; parses one Zig file with std.zig.Ast without executing compiler semantic analysis." }, .static_analysis_tier = .parser_backed });
pub const zig_allocations = tool(.{
    .description = "Find likely allocation-related call sites in a Zig file.",
    .input_schema = schema(&.{.{ "file", "string", true }}),
    .read_only = true,
    .group = .static_analysis,
    .plan = .{ .pure_analysis = "Static workspace analysis; reads project files and returns deterministic guidance without executing backends." },
    .static_analysis_tier = .advisory_orientation,
});
pub const zig_error_sets = tool(.{
    .description = "Find likely error-related sites in a Zig file.",
    .input_schema = schema(&.{.{ "file", "string", true }}),
    .read_only = true,
    .group = .static_analysis,
    .plan = .{ .pure_analysis = "Static workspace analysis; reads project files and returns deterministic guidance without executing backends." },
    .static_analysis_tier = .advisory_orientation,
});
pub const zig_public_api = tool(.{
    .description = "Find likely public API declarations in a Zig file.",
    .input_schema = schema(&.{.{ "file", "string", true }}),
    .read_only = true,
    .group = .static_analysis,
    .plan = .{ .pure_analysis = "Static workspace analysis; reads project files and returns deterministic guidance without executing backends." },
    .static_analysis_tier = .advisory_orientation,
});
pub const zig_dead_decl_candidates = tool(.{
    .description = "List private declaration candidates that need reference checks before deletion.",
    .input_schema = schema(&.{.{ "file", "string", true }}),
    .read_only = true,
    .group = .static_analysis,
    .plan = .{ .pure_analysis = "Static workspace analysis; reads project files and returns deterministic guidance without executing backends." },
    .static_analysis_tier = .advisory_orientation,
});
pub const zig_build_graph = tool(.{
    .description = "Parse build.zig/build.zig.zon heuristically into modules, dependencies, build steps, and artifacts.",
    .input_schema = schema(&.{}),
    .read_only = true,
    .group = .static_analysis,
    .plan = .{ .pure_analysis = "Static workspace analysis; reads project files and returns deterministic guidance without executing backends." },
    .static_analysis_tier = .advisory_orientation,
});
pub const zig_build_targets = tool(.{
    .description = "Return likely build steps, artifacts, modules, and suggested zig build commands.",
    .input_schema = schema(&.{}),
    .read_only = true,
    .group = .static_analysis,
    .plan = .{ .pure_analysis = "Static workspace analysis; reads project files and returns deterministic guidance without executing backends." },
    .static_analysis_tier = .advisory_orientation,
});
pub const zig_build_options = tool(.{
    .description = "Heuristically discover available `zig build -D...` options from build.zig and standard Zig build knobs.",
    .input_schema = schema(&.{}),
    .read_only = true,
    .group = .static_analysis,
    .plan = .{ .pure_analysis = "Static workspace analysis; reads project files and returns deterministic guidance without executing backends." },
    .static_analysis_tier = .advisory_orientation,
});
pub const zig_file_owner = tool(.{
    .description = "Map a workspace Zig file to likely build module/artifact/test commands.",
    .input_schema = schema(&.{.{ "file", "string", true }}),
    .read_only = true,
    .group = .static_analysis,
    .plan = .{ .pure_analysis = "Static workspace analysis; reads project files and returns deterministic guidance without executing backends." },
    .static_analysis_tier = .advisory_orientation,
});
pub const zig_import_resolve = tool(.{
    .description = "Heuristically resolve a Zig @import string against workspace modules, packages, stdlib, or a source file.",
    .input_schema = schema(&.{ .{ "import", "string", true }, .{ "from", "string", false } }),
    .read_only = true,
    .group = .static_analysis,
    .plan = .{ .pure_analysis = "Static workspace analysis; reads project files and returns deterministic guidance without executing backends." },
    .static_analysis_tier = .advisory_orientation,
});
pub const zig_test_discover = tool(.{
    .description = "Heuristically discover Zig test declarations and runnable test commands.",
    .input_schema = schema(&.{.{ "limit", "integer", false }}),
    .read_only = true,
    .group = .static_analysis,
    .plan = .{ .pure_analysis = "Static workspace analysis; reads project files and returns deterministic guidance without executing backends." },
    .static_analysis_tier = .advisory_orientation,
});
pub const zig_ast_tests = tool(.{ .description = "Return parser-backed Zig test declarations for a Zig file using std.zig.Ast.", .input_schema = schema(&.{.{ "file", "string", true }}), .read_only = true, .group = .static_analysis, .plan = .{ .pure_analysis = "Parser-backed source analysis; parses one Zig file with std.zig.Ast without executing compiler semantic analysis." }, .static_analysis_tier = .parser_backed });
pub const zig_changed_files_plan = tool(.{
    .description = "Inspect git changes and recommend the smallest useful Zig validation commands.",
    .input_schema = schema(&.{.{ "timeout_ms", "integer", false }}),
    .read_only = true,
    .group = .static_analysis,
    .risk = .{ .executes_backend = true },
    .plan = .{ .dynamic_command = "Backend-backed workflow whose exact argv depends on runtime arguments, workspace state, or configured helper paths." },
    .static_analysis_tier = .advisory_orientation,
});
pub const zig_dependency_inspect = tool(.{
    .description = "Inspect build.zig.zon dependencies, hashes, local package/cache state, and dependency wiring risks.",
    .input_schema = schema(&.{}),
    .read_only = true,
    .group = .static_analysis,
    .plan = .{ .pure_analysis = "Static workspace analysis; reads project files and returns deterministic guidance without executing backends." },
    .static_analysis_tier = .advisory_orientation,
});
pub const zig_target_matrix_plan = tool(.{
    .description = "Plan cross-target Zig build/test matrix commands without running them.",
    .input_schema = schema(&.{ .{ "targets", "string", false }, .{ "steps", "string", false } }),
    .read_only = true,
    .group = .static_analysis,
    .plan = .{ .pure_analysis = "Command matrix planner; returns candidate build/test commands without running them." },
    .static_analysis_tier = .advisory_orientation,
});
pub const zig_test_failure_triage = tool(.{
    .description = "Parse Zig test output or run tests and return failing tests, panic clues, and rerun commands.",
    .input_schema = schema(&.{ .{ "text", "string", false }, .{ "file", "string", false }, .{ "filter", "string", false }, .{ "args", "string", false }, .{ "timeout_ms", "integer", false } }),
    .read_only = true,
    .group = .static_analysis,
    .risk = .{ .writes_artifacts = true, .executes_project_code = true, .executes_backend = true },
    .plan = .{ .dynamic_command = "Backend-backed workflow whose exact argv depends on runtime arguments, workspace state, or configured helper paths." },
    .static_analysis_tier = .compiler_backed,
});
pub const zig_workspace_symbol_cache = tool(.{
    .description = "Build or inspect a cached heuristic workspace symbol/import index for repeated MCP calls.",
    .input_schema = schema(&.{ .{ "refresh", "boolean", false }, .{ "query", "string", false }, .{ "limit", "integer", false } }),
    .read_only = true,
    .group = .static_analysis,
    .plan = .{ .pure_analysis = "Static workspace analysis; reads project files and returns deterministic guidance without executing backends." },
    .static_analysis_tier = .advisory_orientation,
});
pub const zig_package_cache_doctor = tool(.{
    .description = "Diagnose Zig package/cache directories, git-tracked generated artifacts, and package hash risks.",
    .input_schema = schema(&.{.{ "timeout_ms", "integer", false }}),
    .read_only = true,
    .group = .static_analysis,
    .risk = .{ .executes_backend = true },
    .plan = .{ .dynamic_command = "Backend-backed workflow whose exact argv depends on runtime arguments, workspace state, or configured helper paths." },
    .static_analysis_tier = .advisory_orientation,
});
pub const zig_test_map = tool(.{
    .description = "Build a deterministic map of Zig test declarations, files, likely symbols, and test commands.",
    .input_schema = schema(&.{.{ "limit", "integer", false }}),
    .read_only = true,
    .group = .static_analysis,
    .plan = .{ .pure_analysis = "Static workspace analysis; reads project files and returns deterministic guidance without executing backends." },
    .static_analysis_tier = .advisory_orientation,
});
pub const zig_test_select = tool(.{
    .description = "Recommend focused Zig test commands for changed files or symbols.",
    .input_schema = schema(&.{ .{ "files", "string", false }, .{ "symbols", "string", false }, .{ "limit", "integer", false } }),
    .read_only = true,
    .group = .static_analysis,
    .plan = .{ .pure_analysis = "Static workspace analysis; reads project files and returns deterministic guidance without executing backends." },
    .static_analysis_tier = .advisory_orientation,
});
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

test "static analysis definitions expose import graph metadata" {
    try @import("std").testing.expect(zig_import_graph.description.len > 0);
}
