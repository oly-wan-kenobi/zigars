//! Tool definitions for the `core_zig` group: version introspection, env/target
//! queries, build/test execution, AST checking, diagnostic indexing, and C
//! translation. All tools delegate to the Zig toolchain backend and are
//! read-only from a workspace perspective — no source files are mutated.
const types = @import("../types.zig");

const schema = types.schema;
const schemaWithHints = types.schemaWithHints;
const tool = types.tool;
const fieldHint = types.fieldHint;

/// Return Zig and ZLS version information.
pub const zig_version = tool(.{
    .description = "Return Zig and ZLS version information.",
    .input_schema = schema(&.{}),
    .read_only = true,
    .group = .core_zig,
    .risk = .{ .executes_backend = true },
    .plan = .{ .dynamic_command = "Backend-backed workflow whose exact argv depends on runtime arguments, workspace state, or configured helper paths." },
});
/// Run `zig env`.
pub const zig_env = tool(.{
    .description = "Run `zig env`.",
    .input_schema = schema(&.{}),
    .read_only = true,
    .group = .core_zig,
    .risk = .{ .executes_backend = true },
    .plan = .{ .exact_command = .{ .argv = &.{"env"} } },
});
/// Run `zig targets`.
pub const zig_targets = tool(.{
    .description = "Run `zig targets`.",
    .input_schema = schema(&.{}),
    .read_only = true,
    .group = .core_zig,
    .risk = .{ .executes_backend = true },
    .plan = .{ .exact_command = .{ .argv = &.{"targets"} } },
});
/// Run `zig build` in the workspace.
pub const zig_build = tool(.{
    .description = "Run `zig build` in the workspace.",
    .input_schema = schema(&.{ .{ "args", "string", false }, .{ "timeout_ms", "integer", false } }),
    .read_only = true,
    .group = .core_zig,
    .risk = .{ .writes_artifacts = true, .executes_project_code = true, .executes_backend = true },
    .plan = .{ .exact_command = .{ .argv = &.{"build"} } },
});
/// Run Zig tests.
pub const zig_test = tool(.{
    .description = "Run Zig tests. Uses `zig test <file>` when file is provided, otherwise `zig build test`.",
    .input_schema = schema(&.{ .{ "file", "string", false }, .{ "filter", "string", false }, .{ "args", "string", false }, .{ "timeout_ms", "integer", false } }),
    .read_only = true,
    .group = .core_zig,
    .risk = .{ .writes_artifacts = true, .executes_project_code = true, .executes_backend = true },
    .plan = .{ .exact_command = .{ .optional_file = .{ .file_args = &.{"test"}, .fallback_args = &.{ "build", "test" } } } },
});
/// Run `zig ast-check` on a workspace Zig file.
pub const zig_check = tool(.{
    .description = "Run `zig ast-check` on a workspace Zig file.",
    .input_schema = schema(&.{ .{ "file", "string", true }, .{ "timeout_ms", "integer", false } }),
    .read_only = true,
    .group = .core_zig,
    .risk = .{ .executes_backend = true },
    .plan = .{ .exact_command = .{ .required_file = &.{"ast-check"} } },
});
/// Parse compiler output or run a focused Zig command and return grouped compile diagnostics.
pub const zig_compile_error_index = tool(.{
    .description = "Parse compiler output or run a focused Zig command and return grouped compile diagnostics.",
    .input_schema = schemaWithHints(&.{ .{ "text", "string", false }, .{ "command", "string", false }, .{ "file", "string", false }, .{ "args", "string", false }, .{ "timeout_ms", "integer", false } }, &.{
        fieldHint("command", .{ .description = "Focused Zig command mode.", .enum_values = &.{ "check", "test", "build", "build-test", "fmt-check" } }),
    }),
    .read_only = true,
    .group = .core_zig,
    .risk = .{ .writes_artifacts = true, .executes_project_code = true, .executes_backend = true },
    .plan = .{ .dynamic_command = "Backend-backed workflow whose exact argv depends on runtime arguments, workspace state, or configured helper paths." },
});
/// Run a focused Zig command and return parsed compiler findings plus deterministic next actions.
pub const zig_explain_errors = tool(.{
    .description = "Run a focused Zig command and return parsed compiler findings plus deterministic next actions.",
    .input_schema = schemaWithHints(&.{ .{ "command", "string", false }, .{ "file", "string", false }, .{ "args", "string", false }, .{ "timeout_ms", "integer", false } }, &.{
        fieldHint("command", .{ .description = "Focused Zig command mode.", .enum_values = &.{ "check", "test", "build", "build-test", "fmt-check" } }),
    }),
    .read_only = true,
    .group = .core_zig,
    .risk = .{ .writes_artifacts = true, .executes_project_code = true, .executes_backend = true },
    .plan = .{ .dynamic_command = "Backend-backed workflow whose exact argv depends on runtime arguments, workspace state, or configured helper paths." },
});
/// Run `zig translate-c` on a workspace C header/source file.
pub const zig_translate_c = tool(.{
    .description = "Run `zig translate-c` on a workspace C header/source file.",
    .input_schema = schema(&.{ .{ "file", "string", true }, .{ "args", "string", false }, .{ "timeout_ms", "integer", false } }),
    .read_only = true,
    .group = .core_zig,
    .risk = .{ .executes_backend = true },
    .plan = .{ .exact_command = .{ .required_file = &.{"translate-c"} } },
});
