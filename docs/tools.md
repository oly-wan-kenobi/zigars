# Zigar Tools

`zigar_capabilities`, `zigar_tool_index`, and `zigar_schema` expose the same
catalog. Tool grouping, discovery keywords, argument schemas, risk metadata,
planning metadata, and handler references are generated from
the typed manifest under `src/manifest/`; the public MCP tool/resource
response adds static safety notes and common intents from
`src/manifest/tool_catalog.json`.

Standard MCP discovery is the first-class path: `tools/list` publishes each
registered `inputSchema` with `properties`, `required` fields, defaults, enums,
and zigar path hints. `zigar_schema` and the `zigar://tools/schema` resource
remain compact catalog views for grouping, risk, planning, and discovery
keywords.

## Evidence Labels

Public feature claims use this vocabulary:

- Command-backed: zigar invokes an explicit `zig` argv and returns captured
  command metadata.
- LSP-backed: ZLS provided the result for that call; unsupported capabilities
  and missing sessions are structured results.
- Parser-backed: zigar parsed Zig source with `std.zig.Ast`; this is syntactic,
  not compiler semantic analysis.
- Source-scan-backed: zigar scanned local files and reports source paths,
  ranking, skipped files, and provenance.
- Heuristic/advisory: useful for orientation or prioritization, not proof.
- External-backend-backed: ZLint, zwanzig, zflame, diff-folded, Samply, Tracy,
  LLDB, heaptrack, Valgrind, AFL++, LLVM binary tools, QEMU, flash tools, or
  platform profilers own the backend semantics; zigar reports argv, probes, and
  artifact metadata.
- Curated fallback: bundled partial data used when installed docs are missing.
- Real conformance artifact: optional-backend compatibility claimed from a
  release evidence package, not from fake-backend fixtures.

## Public Contract Compatibility

Treat `tools/list`, `zigar_schema`, `zigar_tool_index`, and
`zigar://tools/schema` as client-visible API. Tool names, argument fields,
required sets, enum values, defaults, risk flags, discovery keywords, backend
setup entries, and capability tiers are compatibility-sensitive. Additive fields
are usually safe; removals, renames, risk changes, or stronger/weaker precision
claims need changelog notes and smoke fixture updates before a public tag.

`src/manifest/` is the authority for structured contract data, while
`src/manifest/tool_catalog.json` adds static safety notes and common intents. Do not
teach clients to scrape prose when the manifest or schema exposes a structured
field.

[tool-index.generated.md](tool-index.generated.md) is generated from
the typed manifest and static catalog notes. CI runs `zig build docs-check` so
the committed tool index cannot drift from registered groups, keywords, or
schemas.

Tool calls are validated before handler execution. Invalid arguments return a
structured `argument_error` result with a stable `code`, `field`, `expected`,
`actual`, and `resolution`.

Argument hints are scoped to the owning tool schema. Shared path/apply/timeout
semantics are reused where they mean the same thing, but enum and default
contracts live on the specific schema that owns the field. For example,
`zigar_context_pack.mode` and `zigar_validate_patch.mode` can advertise
different valid values without a global `mode` default leaking between tools.

Handlers preserve that contract after validation too. Expected user-facing
failures such as missing workspace files, unsupported planning targets, malformed
extra arguments, unavailable optional backends, failed writes, and analysis-cache
decode failures are returned as MCP error results with structured payloads. The
payload names the tool, operation, phase, machine-readable code, category,
underlying error when available, and a resolution. Bare `InvalidArguments`,
`ExecutionFailed`, and `ResourceNotFound` are treated as release-check failures in
the public tool-handler modules.

Registry-derived argument hints also include a `risk` object. The MCP
`readOnlyHint` remains useful for client UI, but zigar's risk fields are more
specific: source writes, artifact writes, apply-gated writes, preview-by-default
behavior, LSP-state mutation, backend execution, project-code execution, and
arbitrary user-command execution are tracked independently.

Planning support is also registry-derived. Use `zig_tool_plan` for the broad
answer for any registered tool: exact command, runtime-dependent backend, ZLS
request, apply-gated mutation, workspace artifact, pure analysis, or explicitly
unsupported. `zig_command_plan` is intentionally narrower: it returns exact
`argv`/`cwd`/`timeout_ms` only for command-backed tools and returns a structured
unsupported response for other known tools instead of `InvalidArguments`.

## Artifact registry and provenance

Artifact registry and provenance tools make generated evidence inspectable
without weakening workspace path policy. `zigar_artifact_index` reads the
workspace-local `.zigar-cache/artifacts/registry.jsonl` registry when present,
scans bounded generated roots such as `.zigar-cache`, `zig-out`, `coverage`, and
`dist`, and reports artifact paths, counts, bounded SHA-256 identities,
provenance records, evidence source, confidence, limitations, and next actions.
`zigar_artifact_read` reads one workspace artifact with a caller-specified byte
limit and hash. `zigar_artifact_prune` is preview-first: with `apply=false` it
reports the registry preimage identity and stale-entry summary, and with
`apply=true` it rewrites registry metadata only. It never deletes artifact
files.

Artifact registry results use the shared `result_shape` fields for `mode` and
`omitted_sections`. Compact mode can omit large collections or hash detail, but
the omissions name the skipped section, the reason, and the recovery path.
Before release decisions, treat artifact entries as evidence pointers and verify
the producing command, source tree, and release gate that generated them.

## Environment Profiles

Environment profile tools make setup state explicit and reproducible. The
profile contract is `.zigar/profile.json` with `schema_version: 2`; it records
workspace facts, source sets, generated directories, targets, tests, toolchain
paths, optional backend policy, unresolved unknowns, and verification tools.
`zigar_project_profile_v2` previews or writes that file, and
`zigar_profile_bootstrap`, `zigar_profile_import`, `zigar_profile_diff`,
`zigar_profile_validate`, and `zigar_profile_read` cover generation, import,
comparison, validation, and bounded reads. Writes are preview-first and require
`apply=true`.

`zigar_setup_guidance`, `zigar_profile_guidance`, and
`zigar_backend_guidance` return detected facts, questions, and unknowns for
advisory setup. They do not issue MCP protocol elicitation and do not block
deterministic non-interactive flows; unresolved ambiguity stays visible in the
result so a client can either ask a human or continue with conservative
defaults. The older `_elicit` names remain registered as compatibility aliases.

`zigar_env_pack` returns a reproducible environment pack with configured Zig,
ZLS, optional backend paths, probe argv, optional executable hashes, project
version hints, pins, compatibility state, setup hints, and limitations.
`zigar_env_export` writes the pack under `.zigar-cache/env/` only when
`apply=true` and registers artifact provenance. `zig_toolchain_pin` previews or
writes `.zigar/toolchain.json`; `zig_toolchain_pin_check` compares that pin with
the current environment pack. `zig_zls_match_check` compares observed Zig and
ZLS release prefixes when probes are enabled and reports `unknown` rather than
claiming compatibility when version evidence is missing.

ZVM tools are inert by default. `zigar_zvm_probe` runs bounded read-only ZVM
commands, while `zigar_zvm_install_plan` and `zigar_zvm_switch_plan` return
exact argv plans with `plan_only=true`, `mutates_environment=false`, and
`requires_user_execution=true`. They never install Zig or switch the developer
environment.

Backend setup tools follow the same contract. `zigar_backend_install_plan`
returns setup commands and verification steps from the backend catalog without
running them. `zigar_backend_verify` runs bounded probes for configured paths.
`zigar_dev_env_generate` previews or writes pinned mise, asdf, Nix,
devcontainer, or GitHub Actions setup artifacts. `zigar_backend_conformance`
returns conformance scenarios and evidence paths, and
`zigar_backend_evidence_pack` turns an existing conformance report into a compact
registered artifact when applied. The MCP conformance tool does not replace the
script-backed release evidence path.

## Public Adoption Tools

Public adoption tools package existing evidence for MCP clients without
installing dependencies or broadening setup claims. `zigar_adoption_pack` is
read-only: it combines client identity, transport, workspace roots, backend
catalog state, generated-config basis, smoke-plan basis, conformance-report
basis, limitations, skipped validation, and verification commands. Optional
backends remain `not_probed` or `missing_configured_path` until a separate
backend verification or conformance run observes them.

`zigar_client_config_generate` previews deterministic client configuration for
generic MCP JSON, Codex TOML, Claude JSON, Gemini JSON, or Markdown notes.
The result includes generated content, target path, preimage identity, artifact
identity, server argv, provenance, skipped validation, and verification
commands. It writes only with `apply=true`, resolves the output path under the
workspace, and registers the generated config in the artifact registry.

`zigar_smoke_plan` returns a client, transport, platform, timeout, and backend
aware smoke checklist. It does not start a server or run backends; unsupported
platforms and too-small timeout budgets are structured planning results with a
resolution. Use the plan to capture startup, `tools/list`, schema, workspace,
doctor, config preview, smoke-plan, conformance-report, and optional-backend
verification evidence for the target client.

`zigar_conformance_report` ingests inline or workspace conformance JSON and
maps it to conservative public claims. Missing evidence returns a structured
`missing_evidence` report with the verification path. Passing conformance rows
can allow a backend claim; configured paths, availability, planning output, or
failed rows do not. Report artifacts are preview-first, workspace-bound, and
provenance-registered only when `apply=true`.

## Result Shapes

`zigar_result_shape` describes the public compact, standard, and deep response
contracts. New shared-contract tools can accept `mode=compact|standard|deep` and
return stable machine fields first: `kind`, `ok`, `mode`, `result_shape`,
`omitted_sections`, evidence source, confidence, limitations, and resolution
where applicable. `zigar_output_budget_plan` returns planning budgets for a
tool and mode. Token budgets are planning estimates for clients; they are not
tokenizer-exact guarantees.

Compact output is for routing and automation, standard output is the normal
agent path, and deep output is for human review or verification. A compact
result must not imply that omitted validation ran. If a section is truncated or
not returned, clients should inspect `omitted_sections` and rerun with a deeper
mode or higher bounded limit.

## Observability

`zigar_metrics_v2` reports in-memory runtime counters for the current server
process: command calls, ZLS requests, runtime tool errors, observed tool
dispatch calls/errors, analysis-cache state, artifact registry counts, bounded
artifact scan counts, backend health history, ZLS timeline, tool latency, and
observed command durations. `zigar_backend_health_history`,
`zigar_zls_timeline`, and `zigar_tool_latency` expose those sections
individually.

Observability data resets when the zigar process restarts. Backend history
records probes observed through zigar helper paths; it does not watch external
backend state independently. Command durations are observed for commands routed
through shared zigar helpers, and tool latency is MCP validation plus handler
dispatch time, not client/network serialization time. Use `zigar_doctor
probe_backends=true`, project CI, and release gates for stronger evidence.

## Coverage, Benchmarks, And Performance Evidence

Performance workflow tools share a stable evidence envelope: `evidence_basis`,
`backend_status`, `command_argv`, `toolchain`, `target`, `artifact_identity`,
`baseline_identity`, `confidence`, `limitations`, and `skipped_validation`
appear where they apply. Preview results must not imply skipped execution or
validation ran.

Coverage tools parse LCOV and zigar JSON evidence. `zig_coverage_map` normalizes
file totals and line-rate records, `zig_coverage_merge` combines two maps,
`zig_coverage_diff` compares current and baseline evidence, and
`zig_coverage_budget_check` evaluates configured line-rate and changed-file
budgets. `zig_coverage_baseline` previews or writes a baseline artifact only
with `apply=true`. `zig_coverage_run` runs a caller-supplied coverage command
only with `apply=true`; preview returns argv, output path, preimage identity,
and skipped validation instead of executing project code.

Benchmark tools discover likely benchmark entrypoints, normalize JSON or simple
text timing output, preserve baselines, compare current results to baselines,
and check regression budgets. `zig_bench_run` is preview-first and executes the
caller-supplied benchmark command only with `apply=true`; `zig_bench_baseline`
and `zig_perf_evidence_pack` write workspace artifacts only when applied.
`zig_profile_regression` plans follow-up profiling from comparison evidence; it
does not start a profiler.

Samply tools use per-call `samply_path` and never install profiler tools.
`zig_samply_record` previews or runs `samply record` with explicit unavailable
and unsupported-platform states. `zig_samply_summary` summarizes supplied
Samply/Firefox profile JSON, `zig_samply_import` previews or writes a normalized
profile artifact, and `zig_samply_artifact` registers an existing workspace
profile artifact only with `apply=true`.

Tracy tools follow the same explicit backend model. `zig_tracy_plan` scans
source for instrumentation signals, `zig_tracy_probe` reports `not_probed`
unless `probe_backend=true`, and `zig_tracy_capture` previews or runs
`tracy-capture` only with `apply=true`. `zig_tracy_artifacts` registers existing
trace artifacts, and `zig_tracy_hints` produces advisory instrumentation hints
without modifying source. `zig_profile_open` returns a viewer launch plan only;
it never opens GUI applications.

## Runtime Diagnostics, Fuzzing, Binary, And Targets

Runtime diagnostic tools use the same evidence envelope as performance tools:
`evidence_basis`, `backend_status`, `command_argv`, `platform`, `toolchain`,
`target`, `artifact_identity`, `preimage_identity`, `crash_identity`,
`confidence`, `limitations`, and `skipped_validation` appear where they apply.
Preview results expose exact argv and skipped validation without running
debuggers, fuzzers, emulators, or project commands.

Debugging tools plan and capture LLDB-oriented evidence. `zig_debug_plan`
returns a debugger workflow and optional LLDB probe. `zig_lldb_backtrace` and
`zig_core_inspect` preview LLDB argv and run only with `apply=true`, with
explicit unavailable or unsupported-platform results. `zig_debug_frame_summary`
parses supplied debugger, sanitizer, or symbolized frames without invoking a
backend.

Crash fusion tools are read-only parsers for supplied evidence.
`zig_sanitizer_fusion`, `zig_panic_trace_analyze`, and `zig_crash_repro_plan`
classify sanitizer, panic, and crash text, extract frames, return stable crash
identity fields, and list follow-up verification steps.

Memory and fuzzing tools never install optional backends. `zig_heaptrack_run`,
`zig_valgrind_memcheck`, `zig_callgrind_report`, `zig_afl_run`, and
`zig_libfuzzer_run` are preview-first and execute only with `apply=true`.
Applied runs write normalized workspace evidence with preimage and artifact
identity metadata. `zig_heaptrack_summary`, `zig_fuzz_plan`,
`zig_fuzz_crash_minimize`, and `zig_fuzz_corpus_summary` parse or plan from
supplied/workspace evidence without running external tools.

Binary and target tools separate static artifact reads from optional backend
execution. `zig_binary_size` and `zig_binary_size_diff` read workspace artifacts
and report size, format, and hash identity. `zig_objdump_summary`,
`zig_dwarfdump_check`, and `zig_symbolize` preview LLVM backend argv and run only
when applied. `zig_qemu_test` previews or runs QEMU smoke commands with
apply-gated execution, while `zig_cross_smoke` and `zig_target_runtime_plan`
produce cross-target runtime guidance without starting emulators.

Embedded tools remain advisory unless explicitly probing a flash backend.
`zig_embedded_detect` scans workspace files for embedded, MicroZig, linker, and
flash workflow signals. `zig_microzig_plan` and `zig_board_profile` return board
and target guidance. `zig_flash_plan` may probe a selected flash tool with
`--help`, but it never flashes hardware or mutates devices.

## Runtime Jobs, Resources, And Client Guides

Runtime UX tools expose process-local state for clients that want richer MCP
interaction without weakening the workspace guard. `zigar_job_start` and
`zigar_run_stream` run allow-listed Zig commands (`build`, `build-test`,
`test`, `check`, and `fmt-check`) without a shell, retain a bounded job record,
and return output tails, event cursors, and a job id. `zigar_job_status`,
`zigar_job_result`, `zigar_run_events`, `zigar_job_cancel`, and
`zigar_cancel_status` read or update that retained state. Jobs and events are
bounded, process-local, and not persisted across server restarts; cancellation
records intent for retained jobs but cannot kill a synchronous command that has
already completed.

MCP task support is advertised for clients that use `tasks/list`, `tasks/get`,
`tasks/result`, and `tasks/cancel`. The task surface is backed by the same
retained zigar job records as the tools above, so task ids are job ids.

`zigar_resource_query` reads registered runtime resources and dynamic file
resources. The server also exposes `zigar://jobs`, `zigar://run/events`, and
`zigar://workspace/roots`, plus the dynamic templates
`zigar://file/{path}/symbols`, `zigar://file/{path}/diagnostics`, and
`zigar://file/{path}/imports`. Dynamic file resources remain workspace-bound.
Symbols and imports use parser-backed Zig source analysis; diagnostics are
read-only static placeholders with explicit cross-check guidance for compiler or
ZLS-backed diagnostics.

Resource subscriptions are acknowledged through MCP and inspectable through
`zigar_resource_subscribe` and `zigar_resource_unsubscribe`. They are
process-local subscription records for client coordination; they do not start a
filesystem watcher. `zigar_roots_sync`, `zigar_workspace_map`, and
`zigar_workspace_select` expose client root guidance while file tools continue
to resolve paths inside the configured zigar workspace.

`completion/complete` returns values for prompt names, resource URIs, workflow
names, allow-listed command names, and client names. `zigar_agent_guide_v2`,
`zigar_client_guide`, and `zigar_prompt_pack` summarize shipped workflows for
compile errors, tests, refactors, API changes, releases, and performance work.

MCP protocol enhancements are capability-gated. `tools/list` publishes declared
`outputSchema` metadata, large artifact-producing results can include
`resource_link` blocks, and older clients can ignore both while still reading
the text and `structuredContent` fallback. `zigar_patch_session_apply` may issue
`elicitation/create` when `apply=true` and the active client advertises
elicitation support; accepted responses still must pass the existing
`apply=true`, workspace, generated/vendor, and stale-preimage checks. Declined,
cancelled, malformed, or timed-out elicitation responses block the write.
Clients without elicitation support continue to use the existing apply-gated
path. `zigar_failure_fusion` accepts `summarize=true` and may issue
`sampling/createMessage` when the client supports sampling; unsupported clients
receive the deterministic failure evidence plus structured fallback metadata.

## Validation Workflow State

`zigar_validation_plan` returns a risk-aware validation plan without executing
commands. It reports changed-file facts, command phases, read-only tool phases,
skipped phases, unknowns, and a stop condition. `zigar_validation_run` executes
only allow-listed Zig command phases without a shell and records phase results,
structured events, skipped phases, next action, and a history record. History is
preview-first: `.zigar-cache/validation/history.jsonl` is appended only when
`apply=true`, and the preimage identity is reported before the write.

`zig_build_events`, `zig_test_events`, and `zig_test_timing` expose a stable
event-shaping contract for captured or executed Zig output. Captured text is
parsed without running commands. Executed mode uses the same allow-listed Zig
command vocabulary as runtime jobs and reports argv, cwd, timeout, stdout/stderr
tails, diagnostic summaries, test failures, timing rows, confidence, and
limitations.

`zigar_validation_history`, `zig_test_flake_history`, and
`zig_failure_history` read supplied history text or workspace-local JSONL
history and summarize last runs, recurring failure fingerprints, slow phases,
and history availability. They are workflow memory over observed records, not a
replacement for CI logs.

`zigar_session_snapshot` and `zigar_handoff_pack` package current goal,
changed files, validation state, profile state, workspace metadata, recommended
next steps, and limitations for client handoff. `zigar_decision_record`
previews or appends structured decision records only with `apply=true`;
`zigar_project_notes` and `zigar_project_memory` read those records and expose
built-in zigar policies such as generated-path and apply-gate rules.

`zigar_capability_match` ranks registered zigar tools for a goal, error, or
diff using manifest descriptions, keywords, risk, and confidence metadata.
`zigar_tool_sequence_plan` returns an ordered tool sequence with execution-risk
markers and stop conditions. Both are read-only routing aids.

## Transactional Editing And Refactors

Patch-session tools provide preview-first multi-file editing with explicit
preimage evidence. `zigar_patch_session_create` records current file identities
and generated/vendor policy for the requested paths. `zigar_patch_session_preview`
returns per-file diffs plus `expected_preimages`; `zigar_patch_session_apply`
writes only with `apply=true`, matching expected preimages, and editable source
paths. Applied sessions write rollback preimages under
`.zigar-cache/patch-sessions/` and append a bounded JSONL history record.
`zigar_patch_session_revert` restores only files whose current hash still matches
the recorded session output, and `zigar_patch_session_validate` delegates to the
validation workflow with session or edit-derived changed files.

Generated and vendor policy tools make non-source paths explicit.
`zig_generated_file_trace` classifies one path, `zigar_edit_policy_check`
checks files or patch text before broad edits, and `zigar_generated_route`
returns likely source inputs and regeneration commands. These tools are routing
aids; they do not expand workspace path access or edit generated output.

Refactor helpers are intentionally conservative and diff-first.
`zig_organize_imports` sorts and deduplicates top-level `@import` declarations,
`zig_update_imports` performs exact `@import("...")` path replacements,
`zig_move_decl` moves a heuristic top-level declaration between files, and
`zig_extract_decl` extracts an explicit line range to another file. Each writes
only with `apply=true` and returns limitations plus validation guidance.
`zig_code_action_batch` reports ZLS unavailability or unsupported transaction
state rather than guessing when safe batch code actions are not available.

## CI, Release, And API Evidence

CI evidence tools consume artifacts that already exist and keep local execution
separate from interpretation. `zig_ci_ingest` parses inline or workspace-local
logs, GitHub-style annotations, JUnit, and SARIF into failure records with
parser confidence, raw-reference hashes, limitations, and next actions.
`zig_ci_repro_plan` turns those records and changed-file hints into candidate
local commands without running them, while `zig_ci_failure_map` groups parsed
failures by file and kind for triage. Raw CI artifacts remain authoritative.

Release planning tools are read-only evidence organizers. `zig_release_plan`
lists observed and missing validation, CI, API, docs, dependency, security, and
changelog evidence, then names the release gate commands that still need to
pass. `zig_semver_suggest` classifies supplied API/release text into a
conservative bump suggestion, `zig_release_notes_draft` produces editable notes
from supplied evidence, and `zig_release_evidence_pack` packages evidence
pointers and verification commands for review. None of these tools tag,
publish, or mark skipped checks as passed.

API lifecycle tools use public-declaration snapshots as review evidence.
`zig_api_baseline_init` previews or writes a `.zigar-cache` baseline artifact
only with `apply=true` and reports artifact/preimage identities. `zig_api_check`
and `zig_api_diff_baseline` compare a supplied or workspace baseline with
current source and report added, removed, changed, and likely breaking entries.
`zig_api_docs_diff` checks public declaration names against supplied docs text
or a docs file. These are source-text and snapshot checks, not ABI or behavior
proofs.

## Docs, Examples, And Dependency Security

Docs-oracle tools expose local documentation evidence without network access.
`zig_docs_index_build` and `zig_docs_query` scan README, docs files, and source
comments with source-family labels and skipped-file counts. `zig_std_signature`
and `zig_langref_item` wrap local Zig stdlib and language-reference lookup with
the same evidence/limitations envelope. `zig_autodoc_ingest` normalizes supplied
autodoc JSON or text into response-local entries, and
`zig_project_docs_query` can query that inline autodoc together with workspace
docs.

Example-validation tools parse text but do not execute it.
`zig_doc_example_check` extracts fenced Zig snippets from supplied docs content
or a docs file and parses them with `std.zig.Ast`; `zig_snippet_check` checks one
inline snippet; `zig_readme_command_check` extracts Zig shell commands from
README-style text and marks them unsafe for automatic execution.

Dependency and security tools inspect `build.zig.zon` and supplied scanner
evidence. `zig_dependency_update_plan`, `zig_dependency_fetch_check`,
`zig_dependency_lock_audit`, and `zig_dependency_impact` plan updates, fetch
verification, lock/hash review, and likely source impact without fetching
packages. `zig_sbom` previews or writes a CycloneDX-style SBOM artifact only
with `apply=true`. `zig_zat_scan` and `zig_osv_scan` ingest externally produced
reports when supplied, otherwise they return explicit unavailable results
instead of contacting services. `zig_dependency_security_report`,
`zig_dependency_provenance`, `zig_dependency_license_summary`, and
`zig_github_dependency_submit_plan` summarize observed security, origin,
license, and dependency-submission evidence for human or CI review.

## Release Drift Tools

`zigar_docs_drift_check`, `zigar_release_claim_check`, and
`zigar_tool_index_check` are fast, read-only guards for public docs and
generated index drift. They return structured checks with `ok`, evidence source,
limitations, and resolution. They do not replace `zig build docs-check`,
`zig build json-check`, or `zig build release-check`; they are agent-facing
preflight checks that make missing generated-index entries and over-broad claim
tokens visible before the full gate runs.

Static-analysis tools use a shared confidence and capability-tier contract.
Structured results include `analysis_kind`, `capability_tier`, `confidence`,
`confidence_class`, `source_coverage`, `limitations`, `verify_with`,
`evidence_basis`, `cross_check`, and a `recommended_cross_check`. Text results
carry the same metadata beside their human-readable body. Treat
`advisory_orientation` tools as navigation aids: `zig_dead_decl_candidates`
still needs reference checks before deletion, `zig_public_api_diff` has a public
declaration line comparison basis with known blind spots, and `zig_test_select`
returns recommendations unless a stronger dependency model validates them. Use
`parser_backed` tools such as `zig_ast_decl_summary`, `zig_ast_imports`,
`zig_ast_tests`, `zig_semantic_index_build`, `zig_semantic_query`,
`zig_semantic_decl`, `zig_impact_semantic`, and
`zig_test_select_semantic` when syntactic precision matters. Parser-backed results
expose `parse_status`, `partial_result`, `result_complete`, and
`parse_error_count` so malformed source cannot look complete. The semantic
index cache records declarations, imports, tests, source locations, cache hits,
refreshes, and evidence sources; `zig_code_index_export` and `zig_scip_export`
preview workspace-local JSON artifacts and write only with `apply=true`.
Semantic impact and test-selection tools report affected files, importers,
declarations, tests, public API, recommended checks, unknowns, skipped
validation, and conservative fallback commands; they do not prove that
unselected tests can be skipped.
`zig_semantic_refs` and `zig_semantic_callers` use ZLint `--print-ast` symbol
references when the configured backend supports it, then fall back to bounded
source scans with explicit limits.

ZLint-backed tools are optional and separate from zwanzig. `zig_zlint` runs a
configured ZLint-compatible executable and normalizes diagnostics into findings
with rule, severity, location, fingerprint, and summary fields.
`zig_zlint_sarif` converts those normalized findings to SARIF 2.1.0, and
`zig_zlint_rules` normalizes rule metadata when the installed binary exposes a
rule-catalog flag; otherwise it reports a capability fallback. `zig_zlint_fix`
previews the exact ZLint `--fix` argv and runs it only with `apply=true`.
`zig_lint_compare`, `zig_lint_gate`, `zig_lint_profile`, `zig_lint_fix_plan`,
`zig_lint_baseline`, `zig_lint_suppressions`, and `zig_lint_trend` consume
normalized findings for consensus, policy, fix planning, baselines,
suppressions, and before/after reporting. Verify release decisions with Zig
compiler, ZLS, CI, or optional ZLint/zwanzig-backed tools. `zlint_backed` and
`zwanzig_backed` tools report their tier and do not require those binaries to
be installed for default zigar operation.

CI artifact tools use an explicit artifact contract. `zig_ci_annotations`
reports `parser_confidence`, `parsing_basis`, limitations, parse summaries, and
raw `zig ast-check` output. `zig_junit` is command-level JUnit, not inferred
per-test JUnit, and embeds that contract in XML properties. `zig_matrix_check`
returns direct per-entry `ok`, `zig`, `command`, and `failure_summary` fields.
See [ci-artifacts.md](ci-artifacts.md) for integration examples.

`zigar_doctor` accepts optional `probe_backends` and `timeout_ms` arguments. Use
backend probes when a client reports `PermissionDenied`, missing formatter/ZLS
tools, or unclear executable-path failures. Probe results are cached for the
server process and surfaced through `zigar_workspace_info` and `zigar_metrics`.

Docs tools are intentionally split by source, and each source reports
provenance/completeness. `zig_builtin_*` uses curated zigar data, records the
active Zig version when `zig env` is available, and is marked
`partial_curated`. Builtin metadata includes `drift_check_status` and, when the
active toolchain source is available, `active_builtin_source_path`.
`zig_std_search` scans local Zig standard-library `.zig` source files and is
marked `source_scan`. `zig_std_item` extracts adjacent triple-slash doc comments
for declaration matches and returns `qualified_name`, `import_hint`, and
`source_scan_limitations`. `zig_lang_ref_search` searches language-reference
sections, reports whether it used `installed_langref_html` or
`bundled_langref_index`, marks bundled fallback data as `partial_curated`, and
does not scan Zig autodoc implementation files. Installed language-reference
metadata includes `installed_doc_available`, `fallback_reason`, and
`parse_failure_count` so fallback mode is explicit rather than silent.

Structured docs outputs use the same contract across builtin, stdlib source, std
item, and language-reference workflows: `source`, `completeness_level`, `query`,
`limit`, `result_count`, `no_result_reason`, `ranking`, and `index_metadata`.
The top-level `completeness_level` mirrors `source.completeness` so clients do
not need to parse nested provenance before deciding whether a result is
complete, source-scanned, or partial curated fallback. The `source` object
includes `id`, `label`, `provenance`, `completeness`, explicit
`version`/`version_status`, and `path`/`source_path` when a local file or
directory is known. `index_metadata` records the in-memory index strategy,
source roots, per-call creation status, scanned/skipped counts where applicable,
and curated fallback status. Stdlib and installed language-reference hits also
include result-level `source_path` for the exact local file behind the match.
Text docs tools are human-readable projections of the same contract, and the
`_json` companions
(`zig_builtin_doc_json`, `zig_std_search_json`, `zig_std_item_json`,
`zig_lang_ref_search_json`) are the preferred interface for agents that need
stable result metadata.

High-signal discovery keywords include:

- `agent`, `agent client`, `mcp client`, `codex`, `claude`, `gemini`,
  `hermes`, `context pack`, `next action`, `validate patch`,
  `validation plan`, `validation run`, `build events`, `test events`,
  `validation history`, `handoff`, `project memory`, `capability match`,
  `tool sequence`, `failure fusion`, `impact analysis`
- `fmt`, `formatter`, `formatting`, `zig fmt`
- `toolchain`, `version manager`, `mise`, `asdf`, `zvm`, `zigup`
- `doctor`, `health`, `workspace`, `PermissionDenied`
- `compile error index`, `changed files`, `dependency inspector`
- `build options`, `target matrix`, `test failure triage`, `symbol cache`
- `semantic index`, `semantic query`, `references`, `callers`, `code index`,
  `scip`, `semantic impact`, `semantic test select`
- `ci ingest`, `ci repro`, `failure map`, `release plan`, `semver`,
  `release notes`, `api baseline`, `api docs diff`
- `docs query`, `autodoc`, `doc examples`, `snippet check`, `readme commands`
- `dependency update`, `fetch check`, `lock audit`, `sbom`, `osv`, `zat`,
  `security report`, `license`, `dependency provenance`
- `patch session`, `transactional edit`, `rollback`, `preimage`,
  `generated route`, `vendor`, `refactor`, `move declaration`,
  `extract declaration`, `update imports`, `organize imports`
- `zls`, `lsp`, `diagnostics`, `hover`, `definition`, `references`
- `zlint`, `zwanzig`, `lint`, `lint compare`, `lint gate`, `lint baseline`,
  `suppressions`, `trend`, `sarif`
- `zflame`, `profile`, `profile plan`, `external capture`, `flamegraph`
- `coverage`, `coverage baseline`, `coverage budget`, `benchmark`,
  `benchmark baseline`, `performance budget`, `profile regression`, `samply`,
  `tracy`, `profile artifact`, `performance evidence`
- `debug`, `lldb`, `core dump`, `sanitizer`, `panic`, `crash repro`,
  `heaptrack`, `valgrind`, `callgrind`, `fuzz`, `afl`, `libfuzzer`, `corpus`
- `binary size`, `objdump`, `dwarf`, `symbolize`, `qemu`, `cross target`,
  `embedded`, `microzig`, `board`, `firmware`, `flash`

Source-mutating tools are preview-first and require `apply=true` to write:

- `zig_format`
- `zig_patch_preview`
- `zigar_patch_session_apply`
- `zigar_patch_session_revert`
- `zig_move_decl`
- `zig_extract_decl`
- `zig_update_imports`
- `zig_organize_imports`
- `zig_code_action_batch`
- `zig_rename`
- `zig_code_action_apply`
- `zig_zlint_fix`
- `zigar_project_profile`

Generated output tools such as `zig_code_index_export`, `zig_scip_export`,
`zig_lint_baseline`, `zig_api_baseline_init`, `zig_sbom`,
`zigar_validation_run`, `zigar_decision_record`, `zig_flamegraph`, and
`zig_analysis_graphs` must write to explicit workspace-local output paths and
preserve preview-first apply gates where advertised. Coverage and performance
artifacts from `zig_coverage_run`, `zig_coverage_merge`,
`zig_coverage_baseline`, `zig_bench_run`, `zig_bench_baseline`,
`zig_samply_record`, `zig_samply_import`, `zig_samply_artifact`,
`zig_tracy_capture`, `zig_tracy_artifacts`, and `zig_perf_evidence_pack` follow
the same preview/apply provenance rule. Runtime diagnostic artifacts from
`zig_heaptrack_run`, `zig_valgrind_memcheck`, `zig_callgrind_report`,
`zig_afl_run`, `zig_libfuzzer_run`, and `zig_qemu_test` also follow this rule.
`zig_profile_plan`, `zig_debug_plan`, `zig_fuzz_plan`, `zig_cross_smoke`,
`zig_target_runtime_plan`, `zig_microzig_plan`, `zig_board_profile`, and
`zig_flash_plan` are planning tools; external capture, debugger, fuzzer,
emulator, and flash semantics remain with the selected backend.
`zig_flamegraph` requires an explicit zflame format and returns
argv/backend/probe/compatibility metadata with the SVG path.
`zig_flamegraph_diff` also reports the diff-folded intermediate, defaulting to
`.zigar-cache/profile/diff-<n>.folded` unless an explicit workspace-local
`intermediate` path is supplied.
