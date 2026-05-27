# Agent Workflows

Zigars exposes deterministic workflow tools so Codex, Claude, Gemini CLI, Hermes,
and other MCP clients can avoid guessing which low-level Zig command to run next.

## Start Here

Call `zigars_context_pack` when entering a workspace. It returns the workspace,
project type, build/test/dependency/source-map summaries, validation policy, and
agent rules in one compact payload. Each result includes `included_sections` and
`omitted_sections`; compact modes must make omissions explicit instead of
silently hiding context.

Use `zigars_next_action` with the current goal when the next step is unclear.
Common goals such as `fix compile error`, `fix failing tests`, `format`, `review`,
and `profile` route to concrete zigars tools.

Use `zigars_agent_guide_v2`, `zigars_client_guide`, and `zigars_prompt_pack` when
a client needs compact operating instructions, client-specific MCP guidance, or
workflow prompt text for compile errors, tests, refactors, API changes,
releases, and performance work.

When a client wants retained build or test evidence, use `zigars_job_start` or
`zigars_run_stream` instead of a direct one-shot command. Then read
`zigars_job_status`, `zigars_job_result`, `zigars_run_events`, or the MCP task
methods for the retained job id. Job state is bounded and process-local, so
long-term evidence should still be captured in normal CI or artifact outputs.

## Finish Gate

Use `zigars_validate_patch` before handing work back. In `quick` mode it checks
touched-file formatting and `zig ast-check`. In `standard` mode it also runs
`zig build test`. The result includes failing phases, `skipped_phases` with
reasons, and the next diagnostic tool.

Use `zigars_validation_plan` when a client needs the validation shape before
running anything. It returns changed-file facts, risk, required command phases,
read-only tool phases, skipped phases, unknowns, and a stop condition.
`zigars_validation_run` executes only allow-listed Zig command phases without a
shell. History writes are preview-first: it returns the record and target path,
and appends to workspace-local history only with `apply=true`.

Fixture coverage asserts routing contracts, included/omitted sections, and
skipped-phase reporting. It does not turn a workflow recommendation into proof
that a patch is correct.

## Output Contract

Agent workflow tools are routers and gates, not autonomous correctness engines.
Results expose a `workflow_contract` with inspected evidence, inferred
conclusion, confidence, limitations, recommended next tools, verification, and a
stop condition. Evidence labels distinguish compiler output, git/status or
user-supplied text, parser-backed data, and heuristic text scans. Treat
heuristic fields as routing advice until a compiler-backed command or
`zigars_validate_patch` verifies the change.

## Failure Handling

Use `zigars_failure_fusion` to combine compiler diagnostics and test failures into
a primary failure, rerun command, likely scope, and suggested follow-up tools.
Pass `summarize=true` only when a client-supported MCP sampling summary would be
useful; unsupported clients still receive the deterministic evidence and
fallback metadata. Lower-level command results also expose a `failure_summary`
field.

Use `zig_build_events` and `zig_test_events` for captured stdout/stderr when a
client already ran a Zig command. They extract diagnostic, build-step, test, and
timing events and keep the raw command output as the audit source. Without
captured text, they run bounded allow-listed Zig commands. `zig_test_timing`
extracts timing rows from captured test output only.

Use `zigars_validation_history`, `zig_test_flake_history`, and
`zig_failure_history` to summarize retained JSONL validation records. They report
last run, last good run, recurring failure fingerprints, and history limits.
They are summaries of supplied or zigars-written history, not a CI database.

## Runtime Diagnostics

Use `zig_debug_plan` when a crash or core dump needs debugger orientation before
running anything. It returns exact LLDB-oriented argv plans and optional backend
probe status. `zig_lldb_backtrace` and `zig_core_inspect` execute only with
`apply=true`; preview mode reports skipped backend execution.

For supplied crash logs, start with `zig_sanitizer_fusion`,
`zig_panic_trace_analyze`, or `zig_crash_repro_plan`. These tools parse
sanitizer and panic evidence, extract frames, assign stable crash identities, and
recommend follow-up verification without invoking external tools.

Use memory, fuzzing, binary, cross-target, and embedded tools when runtime
evidence depends on optional backends. `zig_heaptrack_run`,
`zig_valgrind_memcheck`, `zig_callgrind_report`, `zig_afl_run`,
`zig_libfuzzer_run`, and `zig_qemu_test` are preview-first and write registered
evidence artifacts only when applied. `zig_binary_size`, `zig_binary_size_diff`,
`zig_cross_smoke`, `zig_target_runtime_plan`, `zig_embedded_detect`,
`zig_microzig_plan`, `zig_board_profile`, and `zig_flash_plan` are planning or
static-inspection tools; `zig_flash_plan` never flashes hardware.

## Impact And Tests

Use `zigars_impact` for touched files or symbols. It reports direct importers,
symbol hits, likely tests, public API declarations, recommended commands,
confidence, and limitations. It is a heuristic text/import scan, not semantic
dependency proof.

Use `zig_impact_semantic` when parser-backed semantic-index evidence is
available. It maps changed files, symbols, or diff paths to touched files,
importers, declarations, tests, public API, recommended checks, unknowns, and
skipped validation. `zig_test_select_semantic` turns that evidence into focused
test commands with an explicit `zig build test` fallback. These tools improve
routing, but release decisions still need compiler-backed validation or CI.

Use `zig_test_map` to inspect discovered test declarations and `zig_test_select`
to choose heuristic focused test commands for changed files or symbols.

Use `zig_import_cycles`, `zig_module_surface`, `zig_symbol_dossier`,
`zig_change_risk_audit`, and `zig_insertion_sites` when planning structural
work before editing. These tools expose import-cycle SCCs, directory-level
public surfaces, symbol dossiers, static risk weights, and insertion-site
rankings without applying zigars' internal architecture policy to arbitrary Zig
projects.

Use `zig_test_name_resolve`, `zig_test_fixture_inventory`,
`zig_safety_site_catalog`, and `zig_test_for_symbol` when test filters, fixture
helpers, safety review sites, or symbol-specific test candidates would otherwise
require broad grep. Treat the outputs as bounded evidence and keep
`zig build test` or CI as the correctness proof.

## Handoff And Memory

Use `zigars_session_snapshot` and `zigars_handoff_pack` to capture the current
goal, changed files, validation status, profile state, workspace facts, and
recommended next steps for another client or later run. Handoff output describes
observed state; it does not freeze the workspace or prove unrun validation.

Use `zigars_decision_record` to preview or append a workspace-local project
decision record. Writes require `apply=true`. `zigars_project_notes` reads
structured notes with query/category filters, and `zigars_project_memory` adds
the built-in zigars policies that matter to agents, including generated-path and
apply-gate rules.

Use `zigars_capability_match` to rank zigars tools for a goal, error, or diff.
Use `zigars_tool_sequence_plan` when a client needs an ordered tool sequence with
execution-risk markers and stop conditions before calling tools.

## Edit Safety

Use `zigars_patch_guard` before broad edits or generated patches. It rejects paths
outside the workspace and flags generated/vendor paths such as `.zig-cache`,
`.zigars-cache`, `zig-out`, and `zig-pkg`.

Use `zigars_patch_session_create` and `zigars_patch_session_preview` for multi-file
edits that need stable preimage hashes before applying. Apply with
`zigars_patch_session_apply` only after passing the preview's
`expected_preimages`; stale files or generated/vendor paths block the write.
When the active MCP client advertises protocol elicitation, an applied patch
session can request confirmation through `elicitation/create`; declined,
cancelled, malformed, or timed-out responses block the write. Clients without
elicitation support keep the same `apply=true` and stale-preimage contract.
`zigars_patch_session_revert` can roll back an applied session while the current
file hashes still match the recorded session output.

Use `zig_generated_file_trace`, `zigars_edit_policy_check`, and
`zigars_generated_route` when a requested edit touches generated, cache, artifact,
or vendored files. Route those changes to source inputs or regeneration commands
instead of editing derived output directly.

Use `zig_move_decl`, `zig_extract_decl`, `zig_update_imports`, and
`zig_organize_imports` for preview-first refactor edits, then validate with
`zigars_patch_session_validate` or the normal validation workflow before claiming
the refactor is complete.

Use `zig_public_api_diff` when library-facing files change. It compares public
declarations from supplied text or from `git show <baseline>:<file>` against the
current file and marks removed or signature-changed declarations as breaking
change risk.

## Project Profile

Use `zigars_project_profile` to inspect the generated deterministic profile.
Writing `.zigars/profile.json` requires `apply: true`.

Use `zigars_project_profile_v2` for the structured profile contract. It previews
or writes `.zigars/profile.json` with `schema_version: 2`; `zigars_profile_read`,
`zigars_profile_validate`, `zigars_profile_bootstrap`, `zigars_profile_import`, and
`zigars_profile_diff` cover bounded reads, validation, generation, import, and
top-level comparison.

For setup work, start with `zigars_setup_guidance` or the narrower
`zigars_profile_guidance` and `zigars_backend_guidance` tools. They return
questions and unknowns without blocking non-interactive automation. The older
`_elicit` names remain compatibility aliases, not the primary public names. Then use
`zigars_env_pack`, `zig_toolchain_pin`, `zig_zls_match_check`,
`zigars_backend_install_plan`, `zigars_dev_env_generate`, and
`zigars_backend_conformance` to make the toolchain, setup files, and backend
evidence reproducible.

## Examples

- Compile error triage: `zigars_context_pack -> zigars_next_action ->
  zigars_run_stream -> zig_compile_error_index -> zigars_failure_fusion ->
  zigars_validate_patch`.
- Changed Zig file validation: `zigars_patch_guard -> zig_impact_semantic ->
  zig_test_select_semantic -> zigars_validation_plan -> zigars_validation_run`.
- Transactional refactor: `zigars_patch_session_create ->
  zigars_patch_session_preview -> zigars_patch_session_apply ->
  zigars_patch_session_validate`.
- Retained test evidence: `zigars_prompt_pack -> zig_test_select ->
  zigars_job_start -> zigars_job_result -> tasks/result`.
- Handoff after an interrupted run: `zigars_session_snapshot ->
  zigars_handoff_pack -> zigars_tool_sequence_plan`.
- Reproducible setup: `zigars_setup_guidance -> zigars_project_profile_v2 ->
  zigars_env_pack -> zig_zls_match_check -> zigars_backend_conformance`.
- Profiling workflow routing: `zigars_next_action -> zig_profile_plan ->
  zig_profile_run` when an explicit command is needed, then `zig_flamegraph` or
  `zig_flamegraph_diff` for rendering captured data.
- Performance evidence routing: `zig_bench_discover -> zig_bench_run ->
  zig_bench_compare -> zig_perf_budget_check -> zig_profile_regression`, then
  `zig_samply_record` or `zig_tracy_capture` only when an apply-gated profiler
  capture is appropriate.
- Runtime crash routing: `zig_crash_repro_plan -> zig_sanitizer_fusion ->
  zig_debug_plan -> zig_lldb_backtrace`, using `apply=true` only when the
  debugger capture should run.
- Cross-target and embedded routing: `zig_target_runtime_plan ->
  zig_cross_smoke -> zig_qemu_test`, or `zig_embedded_detect ->
  zig_board_profile -> zig_flash_plan` for firmware workflows.
