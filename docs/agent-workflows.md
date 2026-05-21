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

Use `zigar_agent_guide` when a client needs compact operating instructions. It
includes Codex, Claude, Gemini, Hermes, and generic rules, workflow hints, and
common aliases such as `fmt -> zig_format` and
`done -> zigar_validate_patch`.

## Finish Gate

Use `zigar_validate_patch` before handing work back. In `quick` mode it checks
touched-file formatting and `zig ast-check`. In `standard` mode it also runs
`zig build test`. The result includes failing phases, `skipped_phases` with
reasons, and the next diagnostic tool.

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

## Impact And Tests

Use `zigar_impact` for touched files or symbols. It reports direct importers,
symbol hits, likely tests, public API declarations, recommended commands,
confidence, and limitations. It is a heuristic text/import scan, not semantic
dependency proof.

Use `zig_test_map` to inspect discovered test declarations and `zig_test_select`
to choose focused test commands for changed files or symbols.

## Edit Safety

Use `zigar_patch_guard` before broad edits or generated patches. It rejects paths
outside the workspace and flags generated/vendor paths such as `.zig-cache`,
`.zigar-cache`, `zig-out`, and `zig-pkg`.

Use `zig_public_api_diff` when library-facing files change. It compares public
declarations from supplied text or from `git show <baseline>:<file>` against the
current file and marks removed or signature-changed declarations as breaking
change risk.

## Project Profile

Use `zigar_project_profile` to inspect the generated deterministic profile.
Writing `.zigar/profile.json` requires `apply: true`.

## Examples

- Compile error triage: `zigar_context_pack -> zigar_next_action ->
  zig_compile_error_index -> zigar_failure_fusion -> zigar_validate_patch`.
- Changed Zig file validation: `zigar_patch_guard -> zigar_impact ->
  zig_test_select -> zigar_validate_patch`.
- Profiling workflow routing: `zigar_next_action -> zig_profile_plan ->
  zig_profile_run` when an explicit command is needed, then `zig_flamegraph` or
  `zig_flamegraph_diff` for rendering captured data.
