# Zigars Improvement Surface Implementation Plan

Date: 2026-05-27
Scope: Implement the roadmap synthesized in `docs/improvement-proposals/00-synthesis.md`, with corrections from current repo inspection.

## Requirements Summary

Implement the improvement surface as a staged program, not a single giant feature branch. The work covers:

- Dependency lifecycle: registry discovery, `build.zig.zon` mutation, hash sync, and migration orchestration.
- MCP protocol contract upgrades: output schemas, richer completions, artifact resource links, elicitation, and sampling.
- Architecture-neutral agent-ergonomics queries: import cycles, module surface, symbol/test/risk dossiers, insertion sites.
- Zig developer-pain analyzers: comptime diagnosis, 0.16 IO migration scans, ABI/layout, unsafe/safety catalogs, leak triage.
- Compound workflows and persistent sessions: dependency migration, bench gates, crash capture, debug sessions, build bisect, watch.
- Client/skills/docs packaging: keep tool surfaces, prompts, docs, fixtures, and skill guidance synchronized.

Current-state correction: `src/bootstrap/runtime.zig` already enables completions, resource subscriptions, and tasks; `src/adapters/mcp/server.zig` already routes `completion/complete`, paginated `tools/list`, resource templates, and resource subscribe/unsubscribe; tool results already use `structuredContent`. The protocol work should therefore finish and deepen existing substrate rather than treat it as absent.

Phase handoff documents live under `.omx/plans/zigars-improvement-phases/`.
Each phase document is self-contained enough for a fresh implementation session:

- Phase 0: `.omx/plans/zigars-improvement-phases/phase-00-baseline-reconciliation.md`
- Phase 1: `.omx/plans/zigars-improvement-phases/phase-01-mcp-contract-foundations.md`
- Phase 2: `.omx/plans/zigars-improvement-phases/phase-02-dependency-lifecycle.md`
- Phase 3: `.omx/plans/zigars-improvement-phases/phase-03-architecture-neutral-agent-ergonomics.md`
- Phase 4: `.omx/plans/zigars-improvement-phases/phase-04-zig-developer-pain-analyzers.md`
- Phase 5: `.omx/plans/zigars-improvement-phases/phase-05-compound-workflows-and-session-system.md`
- Phase 6: `.omx/plans/zigars-improvement-phases/phase-06-protocol-feature-pilots.md`
- Phase 7: `.omx/plans/zigars-improvement-phases/phase-07-docs-skills-release-adoption.md`

## Guiding Decisions

1. Keep zigars deterministic. Do not add AI code-generation behavior inside the server.
2. All source mutation remains preview-first and requires `apply=true`.
3. Workspace path policy remains fail-closed: every user path resolves under the configured workspace before reads or writes.
4. New tool contracts are manifest-first: IDs, schemas, risk metadata, docs, and smoke fixtures move together.
5. Protocol support is graceful by default. Elicitation and sampling are used when the client advertises support; existing apply and raw-output behavior remains the fallback.
6. Rename advisory `_elicit` tools to `_guidance` before protocol-level elicitation is adopted broadly.
7. Sessions share a small envelope, but each session kind owns its state machine.
8. Async jobs plus cursored event resources are canonical for long-running event streams. MCP resource subscription is an optional notification layer.
9. Dependency search is pluggable. Direct URL/ref flows and `zig_zon_dep_sync` ship before registry presets. Zigistry can be the first community-index preset with explicit trust metadata.
10. Comptime tools are separate tools with shared prompt guidance: parser-only diagnose first, compiler-probe inspect later, quota probing deferred until demand justifies the cost.
11. Zigars' hexagonal architecture rules remain internal to zigars. Do not expose zigars-specific layer policy as a default public Zig tool; any public architecture-policy surface must be explicit and opt-in.

## Acceptance Criteria

- `zig build docs-check json-check` passes after every manifest or docs-facing slice.
- `zig build test` passes after every source slice.
- `zig build smoke stdio-fixtures` runs for every tool registration, schema, transport, or representative output change.
- Source-mutating tools have tests proving `apply=false` performs no source write and `apply=true` enforces expected preimages.
- Every new tool returns JSON-native `structuredContent` plus a useful text fallback.
- Every new tool has manifest entries in `src/manifest/definitions*.zig`, catalog metadata in `src/manifest/tool_catalog.json`, grouping in `src/manifest/groups.zig` when needed, and generated docs in `docs/tool-index.generated.md`.
- Every new command-backed tool records exact argv, timeout behavior, optional-backend unavailable states, and stderr/stdout handling.
- Every network-backed registry tool labels provider, trust basis, retrieved URL, cache behavior, and unavailable/offline states.
- Persistent sessions survive process restart where claimed, reject stale preimages, and expose inspectable artifacts under `.zigars-cache/`.
- Zigars' internal architecture guard remains a quality gate, not a public `zig_*` tool. Public tools may use import graphs and project-local evidence, but must not enforce zigars' folder/layer policy on other projects by default.

## Phase 0 - Baseline Reconciliation

Goal: make the roadmap and current repo state agree before adding new public surface.

Steps:

1. Update the improvement proposal notes or add a short implementation appendix noting that completions, resource templates/subscriptions, paginated list calls, and `structuredContent` already exist.
2. Re-run release-hygiene checks from `CLAUDE_ANALYSIS.md` because some findings are stale: `packages/zigars-skills-npm/package.json` and tests now exist, but release/npm/MCPB/coverage status may still need verification.
3. Add an ADR for the implementation program and the decisions above, likely under `docs/architecture/` or `docs/adr/` if an ADR location already exists.
4. Confirm generated/artifact hygiene before starting feature work.

Key files:

- `docs/improvement-proposals/00-synthesis.md`
- `CLAUDE_ANALYSIS.md`
- `docs/architecture.md`
- `packages/zigars-skills-npm/`
- `tools/quality/architecture_guard.zig`

Validation:

- `zig build docs-check json-check`
- `npm test` in `packages/zigars-skills-npm` if that package is touched

## Phase 1 - MCP Contract Foundations

Goal: finish protocol substrate that later tools can rely on.

Steps:

1. Add output-schema support to manifest types.
   - Extend `src/manifest/types.zig` with an `output_schema` field.
   - Extend schema projection in `src/adapters/mcp/schema.zig` or a sibling module.
   - Register output schemas in `src/adapters/mcp/registry.zig`.
   - Serialize `outputSchema` from `tools/list` in `src/adapters/mcp/server.zig`.
2. Start with shared output shapes rather than 300 bespoke schemas.
   - Common error envelope.
   - Common command result envelope.
   - Common analysis result envelope.
   - Common patch/session/artifact envelope.
   - Require output schema for all new tools, then backfill high-value existing tools.
3. Upgrade completions from static allowlists to manifest-backed sources.
   - Enum fields complete from schema hints.
   - Add completion source hints for test names, backend IDs, artifact IDs, profile names, workflows, and resource URIs.
   - Keep the existing `completion/complete` handler but route through a manifest-aware provider.
4. Add artifact resource-link support.
   - Register `zigars://artifacts/{sha}` as a resource template.
   - Add a dynamic resource handler that reads artifacts through existing artifact/workspace ports.
   - Add result helpers that emit `resource_link` blocks for large artifacts while keeping compact text fallback.
5. Add protocol helper scaffolds for elicitation and sampling.
   - Store client capabilities from `initialize`.
   - Add server-to-client request helpers for `elicitation/create` and `sampling/createMessage`.
   - Return explicit structured fallback fields when client support is missing.
   - Do not adopt them broadly until first pilot tools are ready.

Key files:

- `src/manifest/types.zig`
- `src/manifest/tooling.zig`
- `src/adapters/mcp/schema.zig`
- `src/adapters/mcp/registry.zig`
- `src/adapters/mcp/server.zig`
- `src/adapters/mcp/server/completion.zig`
- `src/adapters/mcp/resources.zig`
- `src/adapters/mcp/result.zig`
- `tools/integration/http/*`
- `tools/integration/stdio/*`

Acceptance:

- `tools/list` includes `outputSchema` for pilot tools.
- Existing clients still work when they ignore `outputSchema`.
- `completion/complete` can complete at least enum-backed arguments and one dynamic source.
- At least one heavy-output tool returns a `resource_link` to an artifact.

Validation:

- `zig build docs-check json-check`
- `zig build test`
- `zig build smoke stdio-fixtures`

## Phase 2 - Dependency Lifecycle

Goal: close the highest-signal capability gap without overcommitting to one registry.

Steps:

1. Build a reusable `build.zig.zon` dependency model.
   - Parser-backed where practical.
   - Preserve formatting enough for minimal diffs.
   - Emit stable diagnostics for ambiguous or unsupported ZON shapes.
2. Implement `zig_zon_dep_sync`.
   - Preview by default.
   - Use exact `zig fetch` argv through command runner ports.
   - Capture current hash, fetched hash, replacement fragment, diff, and preimage.
   - Apply through patch-session mechanics only.
3. Implement direct dependency mutators.
   - `zig_deps_add`
   - `zig_deps_remove`
   - `zig_deps_upgrade`
   - All are preview-first, apply-gated, and validation-aware.
4. Add dependency registry provider abstraction.
   - Direct URL/ref provider.
   - Zigistry provider as first preset, clearly labeled as community index.
   - Optional GitHub topic provider only after rate-limit and trust handling are explicit.
   - Provider failures are structured, not generic command failures.
5. Implement registry browse tools.
   - `zig_pkg_search`
   - `zig_pkg_info`
   - `zig_pkg_versions`
   - `zig_pkg_readme`
   - Defer `zig_pkg_docs` unless autodoc consumption is clearly bounded.
6. Implement `zig_dependency_migrate`.
   - Session-backed orchestrator over update plan, sync/add/upgrade, fetch check, lock audit, impact, security, and validation.
   - Rollback uses the shared session envelope and patch-session preimages.

Key files:

- `src/app/usecases/dependencies/`
- `src/app/ports.zig`
- `src/infra/`
- `src/adapters/mcp/tools/dependencies.zig`
- `src/manifest/definitions/phase6.zig`
- `src/manifest/definitions/static_analysis.zig`
- `src/manifest/tool_catalog.json`
- `docs/tool-index.generated.md`
- `tools/integration/http/http_phase6_smoke.zig`

Acceptance:

- `zig_zon_dep_sync` fixes a fixture hash mismatch in preview and apply modes.
- Add/remove/upgrade never mutate without `apply=true`.
- Registry browse works with provider unavailable/offline tests.
- Dependency migration can be resumed or inspected by `migration_session_id`.

Validation:

- Focused dependency unit tests
- `zig build test`
- `zig build docs-check json-check`
- `zig build smoke stdio-fixtures`

## Phase 3 - Architecture-Neutral Agent Ergonomics

Goal: expose structural facts agents currently recover with grep and broad reads.

Steps:

1. Implement `zig_import_cycles`.
   - Post-process existing import graph output.
   - Return cycle paths, severity, and confidence.
2. Implement quick parser-backed catalogs.
   - `zig_test_name_resolve`
   - `zig_test_fixture_inventory`
   - `zig_safety_site_catalog`
3. Implement reviewer/planner composites.
   - `zig_test_for_symbol`
   - `zig_module_surface`
   - `zig_symbol_dossier`
   - `zig_change_risk_audit`
   - `zig_insertion_sites`
   - Use import graph, semantic index, public API, tests, and project-local path evidence.
   - If a future explicit architecture profile exists, composites may consume it, but must label it as configured project policy.
4. Add prompt/skill guidance after the tools exist.
   - Update `zigars_prompt_pack` or equivalent prompts.
   - Keep `packages/zigars-skills-npm/skills/zigars-development/SKILL.md` concise and route to tools rather than duplicating tool docs.

Key files:

- `src/domain/`
- `src/app/usecases/static_analysis/`
- `src/adapters/mcp/tools/static_analysis.zig`
- `src/adapters/mcp/tools/project_intelligence.zig`
- `src/manifest/definitions/static_analysis.zig`
- `src/manifest/definitions/agent.zig`
- `docs/agent-workflows.md`
- `packages/zigars-skills-npm/skills/zigars-development/SKILL.md`

Acceptance:

- `zig_import_cycles` returns empty cycles for current zigars source unless a fixture introduces one.
- Planner/reviewer tools label confidence and limitations.
- No new public tool implies that arbitrary Zig projects should follow zigars' internal hexagonal layout.

Validation:

- `zig build test`
- `zig build docs-check json-check`
- Smoke fixtures for representative new tools

## Phase 4 - Zig Developer Pain Analyzers

Goal: add Zig-specific analysis where zigars can be better than generic MCP peers.

Steps:

1. Implement `zig_io_migration_scan` while the 0.15 to 0.16 migration window is still relevant.
   - Curated mapping table.
   - Parser-backed findings.
   - Confidence labels for exact/likely/manual review.
2. Implement `zig_leak_triage`.
   - Parse GPA leak stderr.
   - Group allocation sites.
   - Symbolize when binary/debug info is available.
3. Implement comptime diagnosis.
   - `zig_comptime_diagnose` first, parser-only.
   - Use compiler diagnostic locations when supplied.
   - Return runtime-tainted operands and likely fixes with limitations.
4. Implement memory and safety catalogs.
   - `zig_memory_layout`
   - `zig_unsafe_operations_audit`
   - Extend `zig_safety_site_catalog` as needed.
5. Implement ABI layout diff after memory layout has stable fixtures.
   - Generate bounded `@sizeOf`, `@alignOf`, and `@offsetOf` probes.
   - Keep compiler probes sandboxed and command-backed.
6. Implement lower-risk navigation wrappers.
   - `zig_typedef_jump`
   - `zig_call_hierarchy`
   - `zig_type_hierarchy`
   - `zig_inlay_hints`
7. Implement `zig_target_chooser` and `zig_error_propagation` once the static analysis base is stable.
8. Keep `zig_comptime_inspect` and `zig_comptime_view` as later compiler-probe work.
   - Label backend as `compiler_probe`.
   - Cache probe artifacts under `.zigars-cache/`.
   - Do not claim full semantic comptime evaluation.

Key files:

- `src/domain/zig/analysis.zig`
- `src/domain/diagnostics/`
- `src/app/usecases/static_analysis/`
- `src/app/usecases/diagnostics/`
- `src/app/usecases/zls/code_intel.zig`
- `src/infra/zls/types.zig`
- `src/adapters/mcp/tools/static_analysis.zig`
- `src/adapters/mcp/tools/diagnostics.zig`
- `src/adapters/mcp/tools/zls.zig`

Acceptance:

- Parser-backed tools include fixture coverage for shadowed names, unsupported syntax, and bounded output.
- Command-backed probes use workspace-safe temp/cache paths and exact argv.
- Optional ZLS/backend unavailability returns structured degraded results.

Validation:

- Focused parser/domain tests
- ZLS fake-backend tests
- `zig build test`
- `zig build docs-check json-check`

## Phase 5 - Compound Workflows And Session System

Goal: promote high-round-trip workflows into auditable sessions.

Steps:

1. Introduce a shared session envelope.
   - `id`
   - `kind`
   - `status`
   - `workspace_root`
   - `created_at`
   - `updated_at`
   - `preimages`
   - `artifacts`
   - `events`
   - `validation`
   - `schema_version`
2. Store sessions under `.zigars-cache/sessions/<kind>/<id>.jsonl` or an equivalent cache-local layout.
3. Build lower-risk composed tools first.
   - `zig_c_header_port`
   - `zig_workspace_rename`
   - `zig_bench_regression_gate`
4. Build dependency migration on the shared session envelope if Phase 2 has not already done so.
5. Build crash/debug workflows.
   - `zig_crash_capture_session`
   - `zigars_debug_session_create`
   - `zigars_debug_session_step`
   - `zigars_debug_session_view`
   - `zigars_debug_session_close`
6. Build `zig_build_bisect`.
   - Use internal temporary git worktrees under workspace cache.
   - Never checkout refs in the primary workspace.
   - Require explicit apply/execute opt-in because it creates/deletes worktrees and runs commands.
7. Build `zig_watch`.
   - Async job plus `zigars://run/events` style cursored resource is canonical.
   - Resource subscription only acknowledges or signals availability unless true push is implemented.
8. Promote or defer target matrix based on adopter evidence.
   - If two adopter projects need matrices, implement `zig_target_matrix_run`.
   - Otherwise keep it as a documented playbook.

Key files:

- `src/app/usecases/runtime_ux/`
- `src/app/usecases/transactional_editing/`
- `src/app/usecases/performance/`
- `src/app/usecases/diagnostics/`
- `src/infra/workspace/`
- `src/infra/artifacts/`
- `src/adapters/mcp/server/tasks.zig`
- `src/adapters/mcp/tools/runtime_ux.zig`
- `src/adapters/mcp/tools/transactional_editing.zig`
- `src/adapters/mcp/tools/performance.zig`

Acceptance:

- Sessions can be created, viewed, resumed where claimed, and closed.
- Stale preimages prevent apply/rollback.
- Bisect never mutates the primary worktree.
- Watch can start, emit bounded events, and stop cleanly.

Validation:

- Session persistence unit tests
- Fake command runner tests
- `zig build test`
- `zig build smoke stdio-fixtures`
- Release-style validation before enabling broad docs claims

## Phase 6 - Protocol Feature Pilots

Goal: use elicitation and sampling where they improve existing workflows without making zigars dependent on client support.

Steps:

1. Rename advisory tools.
   - `zigars_setup_elicit` to `zigars_setup_guidance`
   - `zigars_profile_elicit` to `zigars_profile_guidance`
   - `zigars_backend_elicit` to `zigars_backend_guidance`
   - Decide whether to remove old names immediately or mark them deprecated for one minor release.
2. Pilot protocol elicitation.
   - `zigars_patch_session_apply`
   - fuzz runs that execute or allocate substantially
   - dependency mutators when applying remote package changes
3. Pilot protocol sampling.
   - `zigars_failure_fusion`
   - `zig_panic_trace_analyze`
   - zlint/samply/public API diff summaries
4. Add client-capability fields to structured outputs.
   - `elicitation_used`
   - `elicitation_unavailable_reason`
   - `sampling_used`
   - `summary_unavailable_reason`

Key files:

- `src/adapters/mcp/tools/environment.zig`
- `src/app/usecases/environment/`
- `src/adapters/mcp/tools/transactional_editing.zig`
- `src/adapters/mcp/tools/diagnostics.zig`
- `src/adapters/mcp/tools/profiling.zig`
- `src/adapters/mcp/server.zig`

Acceptance:

- Non-supporting clients retain current behavior.
- Supporting-client tests cover request creation and response handling through fake transport.
- No elicitation request asks for secrets.

Validation:

- MCP adapter tests with fake client capabilities
- `zig build test`
- `zig build smoke stdio-fixtures`

## Phase 7 - Docs, Skills, Release, And Adoption

Goal: make the new surface discoverable and supportable.

Steps:

1. Update generated tool index after every tool batch.
2. Update `docs/tools.md`, `docs/agent-workflows.md`, `docs/agent-clients.md`, `docs/trust.md`, and `docs/backends.md` as relevant.
3. Keep package READMEs aligned.
   - `packages/zigars-mcp-npm/README.md`
   - `packages/zigars-skills-npm/README.md`
4. Add or update skill guidance only after corresponding tool surfaces exist.
5. Add smoke fixtures with representative `tools/call` for each new group.
6. Run release-style checks at the end of each major phase.

Key files:

- `docs/tool-index.generated.md`
- `docs/tools.md`
- `docs/agent-workflows.md`
- `docs/agent-clients.md`
- `docs/trust.md`
- `docs/backends.md`
- `packages/zigars-mcp-npm/README.md`
- `packages/zigars-skills-npm/`
- `tools/release/mcp_contracts.zig`

Acceptance:

- Docs and generated index agree.
- Tool catalog JSON passes validation.
- NPM and skills package docs do not claim unavailable tools.
- Release evidence lists exact checks run.

Validation:

- `zig build tool-index`
- `zig build docs-check json-check`
- `zig build smoke stdio-fixtures`
- Package-local npm tests where packages change

## Deferred Or Promotion-Gated Surface

Keep these as playbooks or later promotions unless clear adopter demand appears:

- `zig_linker_error_decode`: promote only if catalog maintenance owner exists.
- `zig_cimport_macro_wrap`: promote only for a concrete adopter with macro fixture coverage.
- `zig_comptime_quota_probe`: keep as playbook until repeated demand justifies wall-clock cost.
- `zig_target_matrix_run`: promote after two adopter projects regularly need matrices.
- `zig_allocator_audit`: keep as playbook unless allocation analysis moves beyond advisory orientation.
- `zig_pkg_docs`: promote after registry metadata and autodoc access are reliable.
- Public architecture-policy checking: defer unless there is demand for an explicit opt-in project profile. Zigars' internal hexagonal guard is not a default public Zig policy.

## Recommended PR Sequence

1. PR 1: Baseline reconciliation and ADR.
2. PR 2: Manifest output schema support plus `tools/list` outputSchema for pilot tools.
3. PR 3: Manifest-backed completions and completion-source hints.
4. PR 4: Artifact `resource_link` template and one heavy-output pilot.
5. PR 5: Shared ZON dependency model and `zig_zon_dep_sync`.
6. PR 6: Dependency add/remove/upgrade mutators.
7. PR 7: Registry provider abstraction and first browse tools.
8. PR 8: `zig_import_cycles`, `zig_test_name_resolve`, fixture and safety catalogs.
9. PR 9: Dependency migration session and shared session envelope.
10. PR 10: Reviewer/planner composites.
11. PR 11: IO migration scan and leak triage.
12. PR 12: Comptime diagnose and memory/unsafe catalogs.
13. PR 13: ABI layout diff and selected ZLS wrappers.
14. PR 14: Lower-risk compound workflow tools.
15. PR 15: Crash/debug sessions.
16. PR 16: Build bisect using temp worktrees.
17. PR 17: Watch/event stream.
18. PR 18: Protocol elicitation/sampling pilots and `_guidance` rename.
19. PR 19: Final docs, skills, release evidence, and broader release-check pass.

## Verification Ladder

Use this ladder per PR:

1. Narrow unit tests for the changed module.
2. `zig fmt build.zig build.zig.zon src tools`
3. `zig build test`
4. `zig build docs-check json-check`
5. `zig build smoke stdio-fixtures` for MCP surface changes.
6. `zig build test --fuzz=10K` for parser, dependency, or source-mutation changes with broad input surface.
7. `zig build smoke stdio-fixtures coverage` before merging large tool batches.
8. `zig build release-check` before public release claims.

For npm or skills package changes:

```sh
cd packages/zigars-mcp-npm
npm run build
npm run test:node
bun run test:bun
```

```sh
cd packages/zigars-skills-npm
npm test
npm run pack:dry
```

## Risk Register

| Risk | Mitigation |
|---|---|
| Tool surface grows too fast to validate | Ship by PR sequence, update smoke fixtures per batch, require output schemas for new tools. |
| Registry trust ambiguity | Provider labels, explicit trust metadata, direct URL path first, no silent provider fallback. |
| Output schemas bloat `tools/list` | Start with shared schema refs if supported or compact common envelopes; keep pagination tested. |
| Source-mutating dependency tools corrupt ZON formatting | Preview-first, fixture coverage, expected preimages, narrow parser model, rollback via patch sessions. |
| Public tools accidentally enforce zigars' internal hexagonal layout | Keep zigars' architecture guard internal unless a future explicit opt-in project profile is designed. |
| Sessions become inconsistent one-offs | Shared envelope plus per-kind state machines; schema version in every session. |
| Elicitation/sampling breaks clients | Capability-gated helpers and structured fallback fields. |
| Comptime inspect overclaims | Label parser-only vs compiler-probe basis; include limitations in every result. |
| Long-running watch leaks resources | Async job lifecycle tests, bounded buffers, explicit stop/cancel, no unbounded event history. |

## First Slice To Execute

Start with PR 1 and PR 2:

1. Add ADR/implementation appendix documenting the decisions in this plan and correcting stale protocol assumptions.
2. Add manifest output-schema plumbing and emit `outputSchema` for a small pilot set:
   - common tool error envelope
   - one static-analysis tool
   - one artifact/runtime tool
   - one patch/session tool
3. Update generated docs and smoke fixtures.
4. Run `zig build test`, `zig build docs-check json-check`, and `zig build smoke stdio-fixtures`.

This first slice creates the contract discipline that every later tool can reuse.
