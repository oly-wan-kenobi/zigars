# Zigar Tools

`zigar_capabilities`, `zigar_tool_index`, and `zigar_schema` expose the same
catalog. Tool grouping, discovery keywords, argument schemas, risk metadata,
planning metadata, and handler references are generated from
the typed manifest under `src/tool_manifest/`; the public MCP tool/resource
response adds static safety notes and common intents from
`src/tool_catalog.json`.

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
- External-backend-backed: zwanzig, zflame, diff-folded, or platform profilers
  own the backend semantics; zigar reports argv, probes, and artifact metadata.
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

`src/tool_manifest/` is the authority for structured contract data, while
`src/tool_catalog.json` adds static safety notes and common intents. Do not
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

`zigar_setup_elicit`, `zigar_profile_elicit`, and `zigar_backend_elicit` return
detected facts, questions, and unknowns for client-mediated setup. They do not
block deterministic non-interactive flows; unresolved ambiguity stays visible in
the result so a client can either ask a human or continue with conservative
defaults.

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
process: command calls, ZLS requests, legacy tool errors, observed tool
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
`parser_backed` tools such as `zig_ast_decl_summary`, `zig_ast_imports`, and
`zig_ast_tests` when syntactic precision matters. Parser-backed results expose
`parse_status`, `partial_result`, `result_complete`, and `parse_error_count` so
malformed source cannot look complete. Verify release decisions with Zig
compiler, ZLS, CI, or optional zwanzig-backed tools. `zwanzig_backed` tools are
optional zwanzig-backed static-analysis/lint integrations; zigar reports their
tier and does not require zwanzig to be installed.

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
  `failure fusion`, `impact analysis`
- `fmt`, `formatter`, `formatting`, `zig fmt`
- `toolchain`, `version manager`, `mise`, `asdf`, `zvm`, `zigup`
- `doctor`, `health`, `workspace`, `PermissionDenied`
- `compile error index`, `changed files`, `dependency inspector`
- `build options`, `target matrix`, `test failure triage`, `symbol cache`
- `zls`, `lsp`, `diagnostics`, `hover`, `definition`, `references`
- `zwanzig`, `lint`, `sarif`
- `zflame`, `profile`, `profile plan`, `external capture`, `flamegraph`

Source-mutating tools are preview-first and require `apply=true` to write:

- `zig_format`
- `zig_patch_preview`
- `zig_rename`
- `zig_code_action_apply`
- `zigar_project_profile`

Generated output tools such as `zig_flamegraph` and `zig_analysis_graphs` must
write to explicit workspace-local output paths. `zig_profile_plan` is read-only
and returns structured guidance for external profilers; zigar does not define
capture semantics. `zig_flamegraph` requires an explicit zflame format and
returns argv/backend/probe/compatibility metadata with the SVG path.
`zig_flamegraph_diff` also reports the diff-folded intermediate, defaulting to
`.zigar-cache/profile/diff-<n>.folded` unless an explicit workspace-local
`intermediate` path is supplied.
