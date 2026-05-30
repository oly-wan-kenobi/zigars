//! Tool definitions for the `runtime_diagnostics` group: debug planning, LLDB
//! backtraces/core inspection, sanitizer/panic analysis, memory profiling,
//! fuzzing, binary introspection, cross-target emulation, and embedded workflows.
//! Backend-executing and source-mutating tools require apply=true; pure-analysis
//! tools operate on caller-supplied evidence without invoking backends.
const types = @import("../types.zig");
const schemas = @import("diagnostics_schemas.zig");

const schema = types.schema;
const tool = types.tool;
const group = types.ToolGroup.runtime_diagnostics;

const backend_read_risk = schemas.backend_read_risk;
const backend_apply_risk = schemas.backend_apply_risk;
const backend_run_risk = schemas.backend_run_risk;
const command_run_risk = schemas.command_run_risk;

const evidence_schema = schemas.evidence_schema;
const debug_schema = schemas.debug_schema;
const memory_run_schema = schemas.memory_run_schema;
const callgrind_schema = schemas.callgrind_schema;
const afl_run_schema = schemas.afl_run_schema;
const libfuzzer_run_schema = schemas.libfuzzer_run_schema;
const binary_schema = schemas.binary_schema;
const cross_schema = schemas.cross_schema;
const embedded_schema = schemas.embedded_schema;

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
