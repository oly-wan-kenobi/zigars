//! Shared input-schema and risk vocabulary for the runtime diagnostics tool
//! definitions. Splitting these private building blocks out of
//! `diagnostics.zig` keeps that file a compact, ordered list of public tool
//! declarations while leaving the emitted catalog unchanged (only `pub` tool
//! declarations contribute manifest entries; these helpers are imported back).
const types = @import("../types.zig");

const fieldHint = types.fieldHint;
const schema = types.schema;
const schemaWithHints = types.schemaWithHints;

/// Workspace-relative executable or test binary path.
pub const backend_read_risk = types.ToolRisk{ .executes_backend = true };
/// Workspace-relative executable or test binary path.
pub const backend_apply_risk = types.ToolRisk{ .writes_require_apply = true, .preview_by_default = true, .executes_backend = true, .executes_project_code = true, .executes_user_command = true };
/// Workspace-relative executable or test binary path.
pub const backend_run_risk = types.ToolRisk{ .writes_artifacts = true, .writes_require_apply = true, .preview_by_default = true, .executes_backend = true, .executes_project_code = true, .executes_user_command = true };
/// Workspace-relative executable or test binary path.
pub const command_run_risk = types.ToolRisk{ .writes_artifacts = true, .writes_require_apply = true, .preview_by_default = true, .executes_project_code = true, .executes_user_command = true };

/// Workspace-relative executable or test binary path.
pub const evidence_schema = schema(&.{
    .{ "text", "string", false },
    .{ "content", "string", false },
    .{ "path", "string", false },
    .{ "command", "string", false },
    .{ "target", "string", false },
    .{ "limit", "integer", false },
});
/// Workspace-relative executable or test binary path.
pub const debug_schema = schemaWithHints(&.{
    .{ "binary", "string", false },
    .{ "core", "string", false },
    .{ "command", "string", false },
    .{ "target", "string", false },
    .{ "lldb_path", "string", false },
    .{ "apply", "boolean", false },
    .{ "timeout_ms", "integer", false },
    .{ "probe_backend", "boolean", false },
}, &.{
    fieldHint("binary", .{ .description = "Workspace-relative executable or test binary path.", .path_kind = "input_file" }),
    fieldHint("core", .{ .description = "Workspace-relative core dump path.", .path_kind = "input_file" }),
    fieldHint("lldb_path", .{ .description = "Optional LLDB executable path for this call only." }),
    fieldHint("probe_backend", .{ .description = "Run an LLDB availability probe for this call.", .default_bool = false }),
});
/// Optional heaptrack executable path for this call only.
pub const memory_run_schema = schemaWithHints(&.{
    .{ "command", "string", true },
    .{ "output", "string", false },
    .{ "apply", "boolean", false },
    .{ "timeout_ms", "integer", false },
    .{ "heaptrack_path", "string", false },
    .{ "valgrind_path", "string", false },
}, &.{
    fieldHint("heaptrack_path", .{ .description = "Optional heaptrack executable path for this call only." }),
    fieldHint("valgrind_path", .{ .description = "Optional Valgrind executable path for this call only." }),
});
/// Workspace-relative callgrind report path.
pub const callgrind_schema = schemaWithHints(&.{
    .{ "command", "string", false },
    .{ "text", "string", false },
    .{ "content", "string", false },
    .{ "path", "string", false },
    .{ "output", "string", false },
    .{ "apply", "boolean", false },
    .{ "timeout_ms", "integer", false },
    .{ "valgrind_path", "string", false },
}, &.{
    fieldHint("path", .{ .description = "Workspace-relative callgrind report path.", .path_kind = "input_file" }),
    fieldHint("valgrind_path", .{ .description = "Optional Valgrind executable path for this call only." }),
});
/// Input schema for AFL++ runs: seed corpus, output dir, optional afl-fuzz path,
/// and a target hint, all of which the handler reads.
pub const afl_run_schema = schemaWithHints(&.{
    .{ "command", "string", true },
    .{ "corpus", "string", false },
    .{ "output", "string", false },
    .{ "target", "string", false },
    .{ "apply", "boolean", false },
    .{ "timeout_ms", "integer", false },
    .{ "afl_path", "string", false },
}, &.{
    fieldHint("corpus", .{ .description = "Workspace-relative fuzz corpus directory.", .path_kind = "input_path" }),
    fieldHint("afl_path", .{ .description = "Optional AFL++ afl-fuzz executable path for this call only." }),
});
/// Input schema for libFuzzer runs. libFuzzer takes its corpus/dictionary inside
/// the caller-provided `command`, so the handler reads only the command, output
/// path, apply gate, and timeout (no AFL-specific `corpus`/`afl_path`).
pub const libfuzzer_run_schema = schema(&.{
    .{ "command", "string", true },
    .{ "output", "string", false },
    .{ "apply", "boolean", false },
    .{ "timeout_ms", "integer", false },
});
/// Workspace-relative baseline binary path.
pub const binary_schema = schemaWithHints(&.{
    .{ "path", "string", true },
    .{ "baseline", "string", false },
    .{ "objdump_path", "string", false },
    .{ "dwarfdump_path", "string", false },
    .{ "symbolizer_path", "string", false },
    .{ "addresses", "string", false },
    .{ "apply", "boolean", false },
    .{ "timeout_ms", "integer", false },
}, &.{
    fieldHint("baseline", .{ .description = "Workspace-relative baseline binary path.", .path_kind = "input_file" }),
    fieldHint("objdump_path", .{ .description = "Optional llvm-objdump executable path for this call only." }),
    fieldHint("dwarfdump_path", .{ .description = "Optional llvm-dwarfdump executable path for this call only." }),
    fieldHint("symbolizer_path", .{ .description = "Optional llvm-symbolizer executable path for this call only." }),
    fieldHint("addresses", .{ .description = "Whitespace or comma separated addresses to symbolize." }),
});
/// Workspace-relative cross-target executable path.
pub const cross_schema = schemaWithHints(&.{
    .{ "target", "string", false },
    .{ "targets", "string", false },
    .{ "command", "string", false },
    .{ "binary", "string", false },
    .{ "qemu_path", "string", false },
    .{ "apply", "boolean", false },
    .{ "timeout_ms", "integer", false },
}, &.{
    fieldHint("binary", .{ .description = "Workspace-relative cross-target executable path.", .path_kind = "input_file" }),
    fieldHint("qemu_path", .{ .description = "Optional QEMU executable path for this call only." }),
});
/// Workspace-relative firmware image path.
pub const embedded_schema = schemaWithHints(&.{
    .{ "board", "string", false },
    .{ "target", "string", false },
    .{ "image", "string", false },
    .{ "flash_tool", "string", false },
    .{ "probe_backend", "boolean", false },
    .{ "timeout_ms", "integer", false },
    .{ "limit", "integer", false },
}, &.{
    fieldHint("image", .{ .description = "Workspace-relative firmware image path.", .path_kind = "input_file" }),
    fieldHint("flash_tool", .{ .description = "Optional flash backend command such as probe-rs, openocd, or pyocd." }),
    fieldHint("probe_backend", .{ .description = "Run a flash-tool availability probe for this call.", .default_bool = false }),
});
