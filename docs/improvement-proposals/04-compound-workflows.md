# 04 — Compound Workflow Primitives

**Author:** Claude Opus 4.7 (1M context)
**Date:** 2026-05-27
**Status:** Proposal — read-only analysis, no code or doc changes made.
**Scope:** Identify chains of *existing* zigars tools that agents currently
compose by hand and that deserve to be promoted to first-class workflow
primitives. Excludes anything already on the CLAUDE_ANALYSIS.md P0–P4 list.

---

## 1. Method

Existing zigars tools were grouped by execution phase (discover / plan / edit /
verify / release) using [docs/tool-index.generated.md](../tool-index.generated.md).
Each candidate workflow was checked against three filters:

1. **Net-new capability?** A chain that today has no zigars tool at all.
2. **Round-trip compression?** Does packaging it reduce the agent's MCP calls
   by more than three, given a typical task?
3. **State management?** Does the chain require carrying preimages, identities,
   git refs, baselines, or session ids between calls in a way that is
   error-prone for agents to manage themselves?

A proposal must clear at least two of the three to be recommended as a tool.
Workflows that clear only one are recommended as documented playbooks instead.

**Out of scope (already covered):** the patch-session chain
(`zigars_patch_session_*`), validation chain (`zigars_validate_patch`,
`zigars_validation_plan`, `zigars_validation_run`), failure fusion
(`zigars_failure_fusion`), handoff (`zigars_session_snapshot`,
`zigars_handoff_pack`), routing (`zigars_capability_match`,
`zigars_tool_sequence_plan`), static fusion (`zig_static_fusion`).

---

## 2. Proposals

Listed in descending order of expected agent leverage. Each entry covers the
manual sequence, composed tools, new state required, effort sizing, and a
tool-vs-playbook recommendation.

### 2.1 `zig_build_bisect` — git-aware build/test bisect

**Replaces:** Today the only way for an agent to find the commit that
introduced a build break is to drive `git bisect` from the shell side, calling
`zig_build` or `zig_test` per ref and recording good/bad outcomes by hand.
zigars has no concept of a bisect session and no shell access to do it.

**Composes:**
`zigars_clean_tree_gate` → repeated `zig_build` / `zig_test` / `zig_check`
across refs → `zig_test_failure_triage` on the first-bad ref →
`zigars_failure_fusion` → `zigars_decision_record` (optional).

**New state:** A persistent `bisect_session_id` keyed by
`{good_ref, bad_ref, command}` with per-ref outcome, captured stdout/stderr
tail, and the current bisect bracket. Persisted under
`.zigars-cache/bisect/<session>.jsonl`, preview-first writes, apply-gated
checkouts (or refusal to mutate the working tree when the user prefers
worktree-isolated runs).

**Why this is hard to do by hand:** Bisect is the canonical case where state
management dominates the workflow. An agent doing this manually loses track of
which ref was tested with which command, which failures were the *same*
failure, and which were transient. A `crash_identity`-style fingerprint on
failures would let the tool dedupe transients automatically.

**Effort:** L. Needs git interaction (read-only ref enumeration + read-only
`git show`), worktree-or-checkout policy, persistent session, and a clean
contract for "skip" / "untestable" refs.

**Recommendation:** **Tool.** Compresses 10–100+ round trips into one session
with auditable state. Hits all three filters. The only zigars tool today that
crosses git history is `zig_public_api_diff`'s `baseline_ref` argument; a
bisect tool would extend that pattern coherently. Pair the proposal with a
`bisect-build-failure` playbook in `.agents/workflows/`.

---

### 2.2 `zig_dependency_migrate` — end-to-end `build.zig.zon` migration

**Replaces:** Migrating a Zig dependency today requires:
`zig_dependency_update_plan` → edit `build.zig.zon` by hand →
`zig_dependency_fetch_check` → `zig_dependency_lock_audit` →
`zig_dependency_impact` → `zig_dependency_security_report` → `zig_build` →
`zig_test`. Eight round trips, and the agent must remember the pre-migration
state to roll back if a later step fails.

**Composes:**
`zig_dependency_update_plan` → preview-first edit to `build.zig.zon` (uses
`zigars_patch_session_create`/`preview`/`apply` semantics) →
`zig_dependency_fetch_check` → `zig_dependency_lock_audit` →
`zig_dependency_impact` → `zig_dependency_security_report` →
`zigars_validation_run` (mode=standard).

**New state:** A `migration_session_id` with: preimage hash of
`build.zig.zon`, preimage of any lockfile, target dependency + version,
collected fetch/lock/impact/security/validation outcomes, and rollback
preimages. Reuses the existing patch-session infrastructure under
`.zigars-cache/patch-sessions/` so rollback semantics are uniform.

**Why this is hard to do by hand:** Each tool's output is the next tool's
input (lock-audit reads from fetch-check output; impact reads from update-plan;
security reads from manifest + sbom). An agent typically forgets to thread a
field, or rolls back partially after a failure. The "did the fetch actually
write a new hash to the manifest" check is the most common silent failure.

**Effort:** M. All composed tools exist; new logic is orchestration, state
threading, and rollback. Reuses patch-session and artifact-registry plumbing.

**Recommendation:** **Tool.** Three+ round-trip reduction *and* hard state.
Most useful when paired with `zig_sbom` regeneration as an optional terminal
step. Surface the dry-run / apply gate at the migration-session level, not
per inner tool.

---

### 2.3 `zig_crash_capture_session` — crash repro with persisted evidence chain

**Replaces:** Today, when a Zig program crashes the agent must call
`zig_crash_repro_plan`, then one or more of `zig_sanitizer_fusion` /
`zig_panic_trace_analyze` / `zig_debug_frame_summary`, then `zig_debug_plan`,
then `zig_lldb_backtrace` (apply=true), then optionally `zig_fuzz_crash_minimize`
to narrow the input, then `zigars_decision_record` to capture the bug. The
crash repro plan and the sanitizer fusion both return a `crash_identity`, but
nothing carries that identity across calls — the agent has to copy it
manually and risk losing the link to the original evidence.

**Composes:**
`zig_crash_repro_plan` → `zig_sanitizer_fusion` / `zig_panic_trace_analyze` /
`zig_debug_frame_summary` (parse supplied evidence) → optional `zig_debug_plan`
+ `zig_lldb_backtrace` + `zig_core_inspect` (apply-gated capture) → optional
`zig_fuzz_crash_minimize` → `zigars_decision_record`.

**New state:** A `crash_session_id` keyed by `crash_identity` with: original
panic/sanitizer text, parsed frames, debugger artifact hashes if captured,
minimized input file path, repro command, and the linked decision record.
Persisted under `.zigars-cache/crash-sessions/<crash_identity>/`. Multiple
recurrences of the same crash collapse into one session.

**Why this is hard to do by hand:** Crashes recur. Without a session, the
agent re-parses the same panic for the third time, re-runs lldb against an
already-captured core, or files a duplicate decision record. The
`crash_identity` field already exists in zigars' runtime-diagnostic envelope
— this proposal puts it to work as a session key.

**Effort:** L. Touches multiple optional backends (lldb, sanitizer evidence,
fuzz harnesses) and needs explicit "session can have no captured artifact
yet" states. The apply gates from `zig_lldb_backtrace` and `zig_core_inspect`
must remain — the session can record intent without executing.

**Recommendation:** **Tool.** State management is the killer feature here:
without a session, the existing tool surface technically covers crash repro
but is exhausting to drive correctly. Build the tool *after* verifying that
`crash_identity` is stable across the three parser tools — if it isn't, that
becomes a prerequisite cleanup.

---

### 2.4 `zig_c_header_port` — C header → Zig port pipeline

**Replaces:** Today, porting a C header involves `zig_translate_c` →
read the output → `zig_format` → `zig_organize_imports` → `zig_check` →
fix parse errors by hand → optionally `zig_public_api_diff` against a
reference. 4–6 round trips, and the intermediate translated file lives only
in tool output until the agent writes it somewhere.

**Composes:**
`zig_translate_c` → write translation to a workspace-local file (apply-gated)
→ `zig_format` → `zig_organize_imports` → `zig_check` → `zig_ast_decl_summary`
(report what survived translation) → optional `zig_public_api_diff` against a
supplied baseline.

**New state:** A translation artifact registered through `zigars_artifact_index`
with provenance pointing at the source header path, the translate-c argv, and
the post-format hash. The artifact is the deliverable; no long-lived session
needed.

**Why this is hard to do by hand:** `zig_translate_c` returns the translation
inline; the agent has to remember to write it, format it, organize imports,
and ast-check it. Each step usually surfaces a different class of issue
(comptime-only constructs, missing extern markers, packed-struct mismatches).
Bundling them gives one structured "translation report" instead of five
disjoint tool results.

**Effort:** S–M. All composed tools exist; new logic is orchestration plus
a structured "translation report" output shape. No new persistent state
beyond the artifact registry entry.

**Recommendation:** **Tool.** This is the classic compose-and-report pattern.
A small tool here is much more useful than a playbook because the report
shape (which decls translated cleanly, which need manual fixup, which have
public-API impact) only makes sense if one tool owns the pipeline.

---

### 2.5 `zig_workspace_rename` — semantic rename across the workspace as a transaction

**Replaces:** `zig_rename` is a single-file ZLS rename. A workspace-scoped
rename today is: `zig_semantic_refs` / `zig_semantic_callers` → loop over
hits, calling `zig_rename` per file with `apply=false` → assemble edits →
`zigars_patch_session_create` → `_preview` → `_apply` → `_validate`. 3–4
round trips per file plus session bookkeeping.

**Composes:**
`zig_semantic_refs` (or ZLS `zig_references`) → enumerate edit sites →
`zigars_patch_session_create` with all sites → `zigars_patch_session_preview`
→ `zigars_patch_session_apply` (apply-gated) → `zigars_patch_session_validate`.

**New state:** Just a `patch_session_id`. No new persistence layer required
— the existing patch-session infrastructure already carries preimages,
rollback evidence, and validation hooks. The new tool is sugar over the
existing session contract plus a semantic reference query.

**Why this is hard to do by hand:** The error-prone parts are (a) missing
references that ZLS knows about but the parser-backed semantic index doesn't
(and vice versa), and (b) forgetting to validate after apply. Surfacing the
reference-source coverage (`ZLS confirmed N sites; parser confirmed M sites;
both confirmed K`) up front is what makes this tool valuable beyond raw
orchestration.

**Effort:** M. Composes existing primitives; the interesting work is the
reference-coverage envelope and a clear contract for "ZLS unavailable —
parser-backed only, with X% coverage caveat."

**Recommendation:** **Tool.** Saves round trips *and* makes the reference-source
trust contract explicit. Without the tool, the trust contract is buried in
each underlying tool's `evidence_basis` field and agents tend to ignore it.

---

### 2.6 `zig_bench_regression_gate` — one-call benchmark regression detection

**Replaces:** `zig_bench_discover` → `zig_bench_run` (apply=true) →
`zig_bench_compare` → `zig_perf_budget_check` → optional
`zig_profile_regression` → optional `zig_bench_baseline` (write). 5–6 round
trips, with state passed by hand: which result file is "current," which is
"baseline," which threshold applies.

**Composes:**
`zig_bench_discover` → `zig_bench_run` (apply-gated) → `zig_bench_compare`
against the configured baseline → `zig_perf_budget_check` →
`zig_profile_regression` planning (read-only) → optional `zig_bench_baseline`
write on a passing run.

**New state:** A `bench_run_id` linking the run artifact, the comparison
artifact, and the budget verdict. Stored under `.zigars-cache/bench/<id>/`
with the existing performance-evidence envelope.

**Why this is hard to do by hand:** Most agents conflate "the run completed"
with "the run passed the gate" — they look at `zig_bench_run` output and
forget to call `_compare` and `_budget_check`. A gate tool that returns one
verdict (pass / regression / inconclusive) with the supporting artifacts
removes that footgun.

**Effort:** M. All composed tools exist with stable envelopes already; the
work is wiring + a clear pass/fail surface that includes "no baseline yet"
as a non-failure state.

**Recommendation:** **Tool.** Three+ round-trip reduction and an
agent-error-mode the existing tools cannot prevent on their own. Pair with
the existing `zig_perf_evidence_pack` for release-time bundling.

---

### 2.7 `zig_target_matrix_run` — cross-target verification orchestrator

**Replaces:** For library/CLI authors validating a release across targets:
`zig_targets` → `zig_target_matrix_plan` → per-target `zig_build` + optional
`zig_cross_smoke` + optional `zig_qemu_test` (apply=true) +
`zig_binary_size_diff`. With N targets and 4 steps each, this is 4N+2 round
trips and the per-target failure context is scattered.

**Composes:**
`zig_target_matrix_plan` → per-target `zig_build` → `zig_cross_smoke` →
`zig_qemu_test` (apply-gated, only where supported) → `zig_binary_size` /
`zig_binary_size_diff` → aggregated matrix report.

**New state:** A `matrix_run_id` with per-target rows: build status, smoke
status, qemu status (or "unsupported on this host"), binary size + diff,
and a stable per-target failure fingerprint. Stored under
`.zigars-cache/target-matrix/<id>/` and registered as an artifact.

**Why this is hard to do by hand:** The cross-product is large, individual
runs are expensive, and partial-success reporting is what makes this useful.
Agents driving it manually usually stop at the first failure and miss the
"3 of 7 targets passed, 2 failed compile, 2 unsupported on this host"
distinction.

**Effort:** L. Each per-target step is well-defined, but the partial-success
report shape and the "unsupported on this host" classification need design.
Must remain apply-gated for qemu_test since that executes the binary.

**Recommendation:** **Tool, with caveats.** High value for library authors
and embedded work, but only justifies the implementation cost once at least
two adopter projects regularly run target matrices. Worth scoping as a
follow-up after the cheaper tools (2.1, 2.2, 2.4, 2.5) land.

---

### 2.8 `zig_allocator_audit` — workspace-wide allocator usage aggregate

**Replaces:** `zig_allocations` per file × N files → manually correlate
results → optionally `zig_heaptrack_summary` or `zig_valgrind_memcheck`
output → manually map findings back to source. Many round trips but each one
is cheap.

**Composes:**
Enumerate workspace Zig files via `zig_ast_imports` / `zig_semantic_query` →
`zig_allocations` per file → aggregate by allocator kind (arena / page /
general purpose / fixed buffer / page allocator / custom) → optionally
cross-reference with supplied `zig_heaptrack_summary` or
`zig_valgrind_memcheck` results to flag potential leak sites.

**New state:** None beyond an optional artifact-registry entry for the
aggregate report.

**Why this isn't a strong tool candidate:** `zig_allocations` is already
flagged as `advisory_orientation`, low confidence. Aggregating low-confidence
results across the workspace amplifies noise more than signal. The
correlation with runtime evidence is the interesting half, and that requires
the user to have already captured `heaptrack` / `valgrind` output — at which
point a playbook explaining how to feed those into existing tools is
sufficient.

**Effort:** M. Mostly aggregation; correlation logic is the only non-trivial
piece.

**Recommendation:** **Playbook.** Document the chain in
`.agents/workflows/allocator-audit.md` and consider promotion only if the
underlying `zig_allocations` tier moves from `advisory_orientation` to
`parser_backed`. Until then a per-file orientation aid is the right contract.

---

## 3. Summary

| # | Proposal | Effort | Recommendation | Round-trip compression | New persistent state |
| --- | --- | --- | --- | --- | --- |
| 2.1 | `zig_build_bisect` | L | **Tool** | 10–100+ → 1 session | `bisect_session_id` |
| 2.2 | `zig_dependency_migrate` | M | **Tool** | 8 → 1 | `migration_session_id` (reuses patch-session) |
| 2.3 | `zig_crash_capture_session` | L | **Tool** | 5–7 → 1 session | `crash_session_id` keyed by `crash_identity` |
| 2.4 | `zig_c_header_port` | S–M | **Tool** | 5–6 → 1 | Artifact only |
| 2.5 | `zig_workspace_rename` | M | **Tool** | 6–10 → 1 | Reuses patch-session |
| 2.6 | `zig_bench_regression_gate` | M | **Tool** | 5–6 → 1 | `bench_run_id` |
| 2.7 | `zig_target_matrix_run` | L | Tool (defer) | 4N+2 → 1 | `matrix_run_id` |
| 2.8 | `zig_allocator_audit` | M | **Playbook** | N→N | None |

## 4. Suggested sequencing

1. **First batch (highest leverage, lowest novelty risk):** 2.4
   (`zig_c_header_port`) and 2.5 (`zig_workspace_rename`). Both compose
   well-understood existing tools and add small, contained state.
2. **Second batch (clear pain points, moderate scope):** 2.2
   (`zig_dependency_migrate`) and 2.6 (`zig_bench_regression_gate`). Both
   reuse existing session/artifact infrastructure.
3. **Third batch (high value, new state model):** 2.1 (`zig_build_bisect`)
   and 2.3 (`zig_crash_capture_session`). These introduce session shapes
   zigars does not have today; prototype against one adopter before
   generalizing the contract.
4. **Defer:** 2.7 (`zig_target_matrix_run`) until target-matrix adoption is
   visible; 2.8 (`zig_allocator_audit`) until `zig_allocations` moves up the
   capability tier.

## 5. Cross-cutting notes

- Every proposed tool retains the **preview-first / apply-gated** rule for
  any inner step that executes project code or writes source. Compounding
  does not relax the existing safety contracts.
- Each proposed tool returns a **`workflow_contract`** identical in shape to
  the one used by `zigars_validate_patch` (`inspected_evidence`,
  `inferred_conclusion`, `confidence`, `limitations`, `recommended_next_tools`,
  `verification`, `stop_condition`). This keeps the public agent surface
  uniform.
- Each proposed tool should ship with **smoke fixtures** (HTTP + stdio)
  covering at least one happy-path call and one structured-failure call, in
  line with the existing tool-change workflow in
  `.agents/workflows/tool-change.md`.
- Persistent session directories under `.zigars-cache/<kind>/` should reuse
  the existing artifact-registry provenance model so they are inspectable
  through `zigars_artifact_index` and prunable through `zigars_artifact_prune`.

---

## 6. Out-of-scope items considered and dropped

- **`zig_workspace_orient`** (aggregate `zigars_context_pack` +
  `zigars_doctor` + `zigars_workspace_info` + `zigars_setup_elicit`). Dropped:
  `zigars_context_pack` already covers most of this and the rest is one-shot
  setup-time work, not a recurring agent loop.
- **`zig_test_fix_session`** (pin a failing test, retain attempt history,
  suggest next action each iteration). Dropped: this is an *agent loop*
  shape, not a tool shape. The existing `zigars_validation_history` +
  `zig_test_flake_history` cover the evidence layer; the loop itself
  belongs in a skill or playbook.
- **`zig_release_orchestrate`** (single-call wrap of `release-check`).
  Dropped: already covered by the `release-check` build target and the
  release-readiness workflow. Adding an MCP tool wrapper duplicates the
  authoritative shell-level gate.
- **`zig_lint_adoption_rollout`** (baseline → suppressions → policy →
  trend). Dropped: lint policy is org-specific; a generic tool would either
  be too prescriptive or too thin. Document as a playbook instead.
- **`zig_doc_sync`** (doc-example-check + snippet-check + readme-command-check
  bundled). Dropped: each component is already cheap to call individually
  and the chain is sequential without shared state.
