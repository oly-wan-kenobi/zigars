const types = @import("../types.zig");

const fieldHint = types.fieldHint;
const schema = types.schema;
const schemaWithHints = types.schemaWithHints;
const tool = types.tool;
const group = types.ToolGroup.runtime_diagnostics;

/// Workspace-relative executable or test binary path.
const backend_read_risk = types.ToolRisk{ .executes_backend = true };
/// Workspace-relative executable or test binary path.
const backend_apply_risk = types.ToolRisk{ .writes_require_apply = true, .preview_by_default = true, .executes_backend = true, .executes_project_code = true, .executes_user_command = true };
/// Workspace-relative executable or test binary path.
const backend_run_risk = types.ToolRisk{ .writes_artifacts = true, .writes_require_apply = true, .preview_by_default = true, .executes_backend = true, .executes_project_code = true, .executes_user_command = true };
/// Workspace-relative executable or test binary path.
const command_run_risk = types.ToolRisk{ .writes_artifacts = true, .writes_require_apply = true, .preview_by_default = true, .executes_project_code = true, .executes_user_command = true };

/// Workspace-relative executable or test binary path.
const evidence_schema = schema(&.{
    .{ "text", "string", false },
    .{ "content", "string", false },
    .{ "path", "string", false },
    .{ "command", "string", false },
    .{ "target", "string", false },
    .{ "limit", "integer", false },
});
/// Workspace-relative executable or test binary path.
const debug_schema = schemaWithHints(&.{
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
const memory_run_schema = schemaWithHints(&.{
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
const callgrind_schema = schemaWithHints(&.{
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
const afl_run_schema = schemaWithHints(&.{
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
const libfuzzer_run_schema = schema(&.{
    .{ "command", "string", true },
    .{ "output", "string", false },
    .{ "apply", "boolean", false },
    .{ "timeout_ms", "integer", false },
});
/// Workspace-relative baseline binary path.
const binary_schema = schemaWithHints(&.{
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
const cross_schema = schemaWithHints(&.{
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
const embedded_schema = schemaWithHints(&.{
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

/// Plan an LLDB-oriented debug session from a binary, core dump, command, target, or crash text.
pub const zig_debug_plan = tool(.{ .description = "Plan an LLDB-oriented debug session from a binary, core dump, command, target, or crash text.", .input_schema = debug_schema, .group = group, .risk = backend_read_risk, .plan = .{ .dynamic_command = "Optionally probes LLDB and returns exact debugger argv without running a debuggee." } });
/// Preview or capture an LLDB backtrace for a workspace binary or core dump.
pub const zig_lldb_backtrace = tool(.{ .description = "Preview or capture an LLDB backtrace for a workspace binary or core dump.", .input_schema = debug_schema, .read_only = false, .group = group, .risk = backend_apply_risk, .plan = .{ .apply_gated_mutation = "Runs LLDB only with apply=true." } });
/// Inspect a core dump with LLDB planning metadata or an apply-gated LLDB summary.
pub const zig_core_inspect = tool(.{ .description = "Inspect a core dump with LLDB planning metadata or an apply-gated LLDB summary.", .input_schema = debug_schema, .read_only = false, .group = group, .risk = backend_apply_risk, .plan = .{ .apply_gated_mutation = "Runs LLDB against a core dump only with apply=true." } });
/// Summarize debugger, sanitizer, or symbolized stack frames from supplied text.
pub const zig_debug_frame_summary = tool(.{ .description = "Summarize debugger, sanitizer, or symbolized stack frames from supplied text.", .input_schema = evidence_schema, .group = group, .plan = .{ .pure_analysis = "Parses supplied frame text without invoking a debugger." } });

/// Fuse sanitizer logs, crash output, and symbolized frames into one runtime failure summary.
pub const zig_sanitizer_fusion = tool(.{ .description = "Fuse sanitizer logs, crash output, and symbolized frames into one runtime failure summary.", .input_schema = evidence_schema, .group = group, .plan = .{ .pure_analysis = "Parses supplied sanitizer or crash evidence." } });
/// Analyze Zig panic traces and extract panic message, frames, and repro guidance.
pub const zig_panic_trace_analyze = tool(.{ .description = "Analyze Zig panic traces and extract panic message, frames, and repro guidance.", .input_schema = evidence_schema, .group = group, .plan = .{ .pure_analysis = "Parses supplied Zig panic output." } });
/// Build a crash reproduction plan from command, target, binary, and crash evidence.
pub const zig_crash_repro_plan = tool(.{ .description = "Build a crash reproduction plan from command, target, binary, and crash evidence.", .input_schema = evidence_schema, .group = group, .plan = .{ .pure_analysis = "Builds a repro plan from supplied crash evidence and command text." } });

/// Preview or run heaptrack for a caller-supplied command with explicit unavailable-tool behavior.
pub const zig_heaptrack_run = tool(.{ .description = "Preview or run heaptrack for a caller-supplied command with explicit unavailable-tool behavior.", .input_schema = memory_run_schema, .read_only = false, .group = group, .risk = backend_run_risk, .plan = .{ .apply_gated_mutation = "Runs heaptrack and registers an output artifact only with apply=true." } });
/// Summarize heaptrack text or exported JSON evidence.
pub const zig_heaptrack_summary = tool(.{ .description = "Summarize heaptrack text or exported JSON evidence.", .input_schema = evidence_schema, .group = group, .plan = .{ .pure_analysis = "Parses supplied heaptrack evidence without invoking heaptrack." } });
/// Preview or run Valgrind memcheck for a caller-supplied command.
pub const zig_valgrind_memcheck = tool(.{ .description = "Preview or run Valgrind memcheck for a caller-supplied command.", .input_schema = memory_run_schema, .read_only = false, .group = group, .risk = backend_run_risk, .plan = .{ .apply_gated_mutation = "Runs valgrind memcheck and writes normalized evidence only with apply=true." } });
/// Summarize callgrind output or preview an apply-gated callgrind command.
pub const zig_callgrind_report = tool(.{ .description = "Summarize callgrind output or preview an apply-gated callgrind command.", .input_schema = callgrind_schema, .read_only = false, .group = group, .risk = backend_run_risk, .plan = .{ .apply_gated_mutation = "Runs valgrind callgrind only with apply=true; supplied report parsing is read-only." } });

/// Plan AFL++ or libFuzzer harness execution, corpus layout, limits, and crash handling.
pub const zig_fuzz_plan = tool(.{ .description = "Plan AFL++ or libFuzzer harness execution, corpus layout, limits, and crash handling.", .input_schema = evidence_schema, .group = group, .plan = .{ .pure_analysis = "Builds a fuzzing plan without running a fuzzer." } });
/// Preview or run AFL++ with caller-provided command and corpus paths.
pub const zig_afl_run = tool(.{ .description = "Preview or run AFL++ with caller-provided command and corpus paths.", .input_schema = afl_run_schema, .read_only = false, .group = group, .risk = backend_run_risk, .plan = .{ .apply_gated_mutation = "Runs afl-fuzz and writes fuzz evidence only with apply=true." } });
/// Preview or run a libFuzzer-enabled binary command and normalize result evidence.
pub const zig_libfuzzer_run = tool(.{ .description = "Preview or run a libFuzzer-enabled binary command and normalize result evidence.", .input_schema = libfuzzer_run_schema, .read_only = false, .group = group, .risk = command_run_risk, .plan = .{ .apply_gated_mutation = "Runs the caller-provided libFuzzer command and writes evidence only with apply=true." } });
/// Plan deterministic minimization for AFL++ or libFuzzer crash inputs.
pub const zig_fuzz_crash_minimize = tool(.{ .description = "Plan deterministic minimization for AFL++ or libFuzzer crash inputs.", .input_schema = evidence_schema, .group = group, .plan = .{ .pure_analysis = "Returns minimization argv plans without running minimizers." } });
/// Summarize workspace fuzz corpus file count, bytes, and bounded identity metadata.
pub const zig_fuzz_corpus_summary = tool(.{ .description = "Summarize workspace fuzz corpus file count, bytes, and bounded identity metadata.", .input_schema = schema(&.{ .{ "path", "string", true }, .{ "limit", "integer", false } }), .group = group, .plan = .{ .pure_analysis = "Reads a workspace corpus directory without executing code." } });

/// Report binary artifact size, format sniffing, and identity metadata.
pub const zig_binary_size = tool(.{ .description = "Report binary artifact size, format sniffing, and identity metadata.", .input_schema = binary_schema, .group = group, .plan = .{ .pure_analysis = "Reads a workspace binary artifact and computes bounded identity metadata." } });
/// Compare two binary artifacts and classify size deltas.
pub const zig_binary_size_diff = tool(.{ .description = "Compare two binary artifacts and classify size deltas.", .input_schema = binary_schema, .group = group, .plan = .{ .pure_analysis = "Reads two workspace binary artifacts and compares their sizes." } });
/// Preview or run llvm-objdump and summarize section and symbol signals.
pub const zig_objdump_summary = tool(.{ .description = "Preview or run llvm-objdump and summarize section and symbol signals.", .input_schema = binary_schema, .read_only = false, .group = group, .risk = backend_apply_risk, .plan = .{ .apply_gated_mutation = "Runs llvm-objdump only with apply=true." } });
/// Preview or run llvm-dwarfdump verification for debug information.
pub const zig_dwarfdump_check = tool(.{ .description = "Preview or run llvm-dwarfdump verification for debug information.", .input_schema = binary_schema, .read_only = false, .group = group, .risk = backend_apply_risk, .plan = .{ .apply_gated_mutation = "Runs llvm-dwarfdump only with apply=true." } });
/// Preview or run llvm-symbolizer for addresses in a workspace binary.
pub const zig_symbolize = tool(.{ .description = "Preview or run llvm-symbolizer for addresses in a workspace binary.", .input_schema = binary_schema, .read_only = false, .group = group, .risk = backend_apply_risk, .plan = .{ .apply_gated_mutation = "Runs llvm-symbolizer only with apply=true." } });

/// Preview or run a QEMU-backed smoke command for a selected target.
pub const zig_qemu_test = tool(.{ .description = "Preview or run a QEMU-backed smoke command for a selected target.", .input_schema = cross_schema, .read_only = false, .group = group, .risk = backend_run_risk, .plan = .{ .apply_gated_mutation = "Runs QEMU only with apply=true." } });
/// Plan cross-target smoke execution and emulator coverage for one or more targets.
pub const zig_cross_smoke = tool(.{ .description = "Plan cross-target smoke execution and emulator coverage for one or more targets.", .input_schema = cross_schema, .group = group, .plan = .{ .pure_analysis = "Builds a cross-target smoke matrix without executing emulators." } });
/// Describe runtime expectations, emulator backend, and limitations for a Zig target.
pub const zig_target_runtime_plan = tool(.{ .description = "Describe runtime expectations, emulator backend, and limitations for a Zig target.", .input_schema = cross_schema, .group = group, .plan = .{ .pure_analysis = "Maps target triples to runtime and emulator planning guidance." } });

/// Detect embedded Zig, MicroZig, board, linker, and flash workflow signals in the workspace.
pub const zig_embedded_detect = tool(.{ .description = "Detect embedded Zig, MicroZig, board, linker, and flash workflow signals in the workspace.", .input_schema = embedded_schema, .group = group, .plan = .{ .pure_analysis = "Scans workspace files for embedded-project signals." } });
/// Plan MicroZig build, board, simulator, debug, and flash workflow checks.
pub const zig_microzig_plan = tool(.{ .description = "Plan MicroZig build, board, simulator, debug, and flash workflow checks.", .input_schema = embedded_schema, .group = group, .plan = .{ .pure_analysis = "Builds a MicroZig workflow plan without mutating hardware or source." } });
/// Return a structured board profile from known board hints and target metadata.
pub const zig_board_profile = tool(.{ .description = "Return a structured board profile from known board hints and target metadata.", .input_schema = embedded_schema, .group = group, .plan = .{ .pure_analysis = "Builds an advisory board profile from caller input and static workspace signals." } });
/// Plan firmware flashing commands and optionally probe the selected flash backend.
pub const zig_flash_plan = tool(.{ .description = "Plan firmware flashing commands and optionally probe the selected flash backend.", .input_schema = embedded_schema, .group = group, .risk = backend_read_risk, .plan = .{ .dynamic_command = "Optionally probes a flash backend with --help; never flashes hardware." } });
