# Agent Workflows

Zigar exposes deterministic workflow tools so Codex, Claude, Gemini CLI, Hermes,
and other MCP clients can avoid guessing which low-level Zig command to run next.

## Start Here

Call `zigar_context_pack` when entering a workspace. It returns the workspace,
project type, build/test/dependency/source-map summaries, validation policy, and
agent rules in one compact payload. Each result includes `included_sections` and
`omitted_sections`; compact modes must make omissions explicit instead of
silently hiding context.

Use `zigar_next_action` with the current goal when the next step is unclear.
Common goals such as `fix compile error`, `fix failing tests`, `format`, `review`,
and `profile` route to concrete zigar tools.

Use `zigar_agent_guide_v2`, `zigar_client_guide`, and `zigar_prompt_pack` when
a client needs compact operating instructions, client-specific MCP guidance, or
workflow prompt text for compile errors, tests, refactors, API changes,
releases, and performance work.

When a client wants retained build or test evidence, use `zigar_job_start` or
`zigar_run_stream` instead of a direct one-shot command. Then read
`zigar_job_status`, `zigar_job_result`, `zigar_run_events`, or the MCP task
methods for the retained job id. Job state is bounded and process-local, so
long-term evidence should still be captured in normal CI or artifact outputs.

## Finish Gate

Use `zigar_validate_patch` before handing work back. In `quick` mode it checks
touched-file formatting and `zig ast-check`. In `standard` mode it also runs
`zig build test`. The result includes failing phases, `skipped_phases` with
reasons, and the next diagnostic tool.

Use `zigar_validation_plan` when a client needs the validation shape before
running anything. It returns changed-file facts, risk, required command phases,
read-only tool phases, skipped phases, unknowns, and a stop condition.
`zigar_validation_run` executes only allow-listed Zig command phases without a
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
`zigar_validate_patch` verifies the change.

## Failure Handling

Use `zigar_failure_fusion` to combine compiler diagnostics and test failures into
a primary failure, rerun command, likely scope, and suggested follow-up tools.
Lower-level command results also expose a `failure_summary` field.

Use `zig_build_events` and `zig_test_events` for captured stdout/stderr when a
client already ran a Zig command. They extract diagnostic, build-step, test, and
timing events and keep the raw command output as the audit source. Without
captured text, they run bounded allow-listed Zig commands. `zig_test_timing`
extracts timing rows from captured test output only.

Use `zigar_validation_history`, `zig_test_flake_history`, and
`zig_failure_history` to summarize retained JSONL validation records. They report
last run, last good run, recurring failure fingerprints, and history limits.
They are summaries of supplied or zigar-written history, not a CI database.

## Impact And Tests

Use `zigar_impact` for touched files or symbols. It reports direct importers,
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

## Handoff And Memory

Use `zigar_session_snapshot` and `zigar_handoff_pack` to capture the current
goal, changed files, validation status, profile state, workspace facts, and
recommended next steps for another client or later run. Handoff output describes
observed state; it does not freeze the workspace or prove unrun validation.

Use `zigar_decision_record` to preview or append a workspace-local project
decision record. Writes require `apply=true`. `zigar_project_notes` reads
structured notes with query/category filters, and `zigar_project_memory` adds
the built-in zigar policies that matter to agents, including generated-path and
apply-gate rules.

Use `zigar_capability_match` to rank zigar tools for a goal, error, or diff.
Use `zigar_tool_sequence_plan` when a client needs an ordered tool sequence with
execution-risk markers and stop conditions before calling tools.

## Edit Safety

Use `zigar_patch_guard` before broad edits or generated patches. It rejects paths
outside the workspace and flags generated/vendor paths such as `.zig-cache`,
`.zigar-cache`, `zig-out`, and `zig-pkg`.

Use `zigar_patch_session_create` and `zigar_patch_session_preview` for multi-file
edits that need stable preimage hashes before applying. Apply with
`zigar_patch_session_apply` only after passing the preview's
`expected_preimages`; stale files or generated/vendor paths block the write.
`zigar_patch_session_revert` can roll back an applied session while the current
file hashes still match the recorded session output.

Use `zig_generated_file_trace`, `zigar_edit_policy_check`, and
`zigar_generated_route` when a requested edit touches generated, cache, artifact,
or vendored files. Route those changes to source inputs or regeneration commands
instead of editing derived output directly.

Use `zig_move_decl`, `zig_extract_decl`, `zig_update_imports`, and
`zig_organize_imports` for preview-first refactor edits, then validate with
`zigar_patch_session_validate` or the normal validation workflow before claiming
the refactor is complete.

Use `zig_public_api_diff` when library-facing files change. It compares public
declarations from supplied text or from `git show <baseline>:<file>` against the
current file and marks removed or signature-changed declarations as breaking
change risk.

## Project Profile

Use `zigar_project_profile` to inspect the generated deterministic profile.
Writing `.zigar/profile.json` requires `apply: true`.

Use `zigar_project_profile_v2` for the structured profile contract. It previews
or writes `.zigar/profile.json` with `schema_version: 2`; `zigar_profile_read`,
`zigar_profile_validate`, `zigar_profile_bootstrap`, `zigar_profile_import`, and
`zigar_profile_diff` cover bounded reads, validation, generation, import, and
top-level comparison.

For setup work, start with `zigar_setup_elicit` or the narrower
`zigar_profile_elicit` and `zigar_backend_elicit` tools. They return questions
and unknowns without blocking non-interactive automation. Then use
`zigar_env_pack`, `zig_toolchain_pin`, `zig_zls_match_check`,
`zigar_backend_install_plan`, `zigar_dev_env_generate`, and
`zigar_backend_conformance` to make the toolchain, setup files, and backend
evidence reproducible.

## Examples

- Compile error triage: `zigar_context_pack -> zigar_next_action ->
  zigar_run_stream -> zig_compile_error_index -> zigar_failure_fusion ->
  zigar_validate_patch`.
- Changed Zig file validation: `zigar_patch_guard -> zig_impact_semantic ->
  zig_test_select_semantic -> zigar_validation_plan -> zigar_validation_run`.
- Transactional refactor: `zigar_patch_session_create ->
  zigar_patch_session_preview -> zigar_patch_session_apply ->
  zigar_patch_session_validate`.
- Retained test evidence: `zigar_prompt_pack -> zig_test_select ->
  zigar_job_start -> zigar_job_result -> tasks/result`.
- Handoff after an interrupted run: `zigar_session_snapshot ->
  zigar_handoff_pack -> zigar_tool_sequence_plan`.
- Reproducible setup: `zigar_setup_elicit -> zigar_project_profile_v2 ->
  zigar_env_pack -> zig_zls_match_check -> zigar_backend_conformance`.
- Profiling workflow routing: `zigar_next_action -> zig_profile_plan ->
  zig_profile_run` when an explicit command is needed, then `zig_flamegraph` or
  `zig_flamegraph_diff` for rendering captured data.
