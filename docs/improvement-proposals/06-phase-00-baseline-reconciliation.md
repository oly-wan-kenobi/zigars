# 06 - Phase 0 Baseline Reconciliation

**Date:** 2026-05-27
**Status:** Implementation appendix for Phase 0 of the improvement roadmap.
**Scope:** Documentation reconciliation only. No new public MCP surface is
introduced here.

---

## 1. Decisions Carried Forward

These decisions are binding inputs for later phases of the improvement surface:

1. **Dependency lifecycle order:** ship direct `build.zig.zon` hash sync and
   apply-gated URL/ref mutation before registry presets; add registry browse
   only after provider trust metadata, offline behavior, and unavailable states
   are explicit.
2. **Graceful protocol fallback:** protocol features such as elicitation,
   sampling, output schemas, and resource links must improve supporting clients
   without making non-supporting clients unusable. Existing `apply=true`,
   preview-first, and raw structured-output behavior remains the fallback.
3. **`_elicit` to `_guidance` direction:** the current `zigars_*_elicit` tools
   are advisory guidance tools, not MCP `elicitation/create`. Rename them to
   `_guidance` before broad protocol-level elicitation is adopted.
4. **Shared session envelope:** new durable workflows should share a small
   envelope containing id, kind, state, preimages where applicable,
   persistence path, artifacts, validation hooks, and stale-preimage checks.
   Each session kind still owns its state machine.
5. **Async jobs plus cursored resources:** long-running workflows should expose
   bounded async jobs and cursored event resources as the canonical read model.
   MCP resource subscriptions are an optional notification layer, not the sole
   transport for event history.
6. **Comptime tool split:** keep `zig_comptime_diagnose`,
   `zig_comptime_inspect` or `zig_comptime_view`, and
   `zig_comptime_quota_probe` as separate tools because their evidence basis,
   runtime cost, and backend requirements differ. Shared prompt guidance can
   explain how to choose among them.
7. **Architecture-neutral public tooling:** public tools may expose import
   cycles, module surfaces, symbol dossiers, insertion sites, and risk audits,
   but must not expose zigars' own hexagonal layer rules as a default Zig
   policy. The zigars architecture guard remains internal unless a future
   explicit opt-in architecture profile is designed.

## 2. Current Baseline Evidence

Phase 0 reconciles the proposal set with these current repository facts:

- `src/bootstrap/runtime.zig` enables completions, resource subscriptions, and
  tasks during server startup.
- `src/adapters/mcp/server.zig` routes `completion/complete`,
  `resources/templates/list`, `resources/subscribe`,
  `resources/unsubscribe`, `tasks/*`, and cursor-aware list handlers.
- `src/adapters/mcp/server/completion.zig` already implements a basic
  completion route for prompts, resources, selected argument names, and
  resource URI templates. Phase 1 should deepen this into manifest-backed
  argument completions rather than introduce completion routing from scratch.
- `src/adapters/mcp/result.zig` and `src/adapters/mcp/server.zig` already emit
  `structuredContent` for tool results. The remaining contract gap is declared
  `outputSchema` projection and coverage.
- `packages/@zigars/skills/` now contains `package.json`, a CLI entrypoint,
  README, license, tests, and a populated `zigars-development` skill. It is no
  longer the placeholder package described in the original analysis.
- `zig_architecture_layer` is not part of the public roadmap surface. Keep
  architecture work project-neutral unless a later opt-in profile is approved.

## 3. Corrected Stale Assumptions

| Previous assumption | Phase 0 correction |
|---|---|
| Completion routing is absent. | A basic `completion/complete` route exists; improve manifest-backed and dynamic completions in Phase 1. |
| Resource templates and subscriptions are unknown or absent. | Resource templates and subscribe/unsubscribe routes exist; artifact-specific resource links remain future work. |
| Tool outputs need `structuredContent` consistency from scratch. | `structuredContent` is already emitted broadly; declared `outputSchema` remains missing. |
| `tools/list` pagination needed verification before planning. | Cursor pagination infrastructure and handlers exist; later work should preserve and extend coverage. |
| `packages/@zigars/skills` is only a placeholder with no package metadata. | The package now has metadata, CLI, README, tests, and a concrete skill; publish readiness still requires package-local validation and any client-side skill validator. |
| Public architecture-layer tooling is a roadmap item. | It is removed from the public surface; public ergonomics remain architecture-neutral. |

## 4. `CLAUDE_ANALYSIS.md` Finding Classification

| Finding | Classification | Phase 0 note |
|---|---|---|
| v0.2.0 GitHub release has Zig tarballs but no MCPB bundles. | Still valid | `gh release view v0.2.0 --repo oly-wan-kenobi/zigars` on 2026-05-27 showed the five Zig tarballs and `zigars-checksums.txt`; no `.mcpb` assets were listed. |
| `@zigars/mcp@0.2.0` has not been published to npm. | Still valid | `npm view @zigars/mcp@0.2.0 version --json` returned `E404` on 2026-05-27. |
| Coverage gate reports `ok: false` because of missing files despite 100% measured line coverage. | Deferred | This remains outside Phase 0's documentation-only scope unless a later quality-gate phase changes coverage policy. |
| `packages/@zigars/skills` is a placeholder with no `package.json`. | Stale | The package now has `package.json`, `bin/zigars-skills.js`, tests, README, license, and `skills/zigars-development/SKILL.md`. |
| npm shim lacks end-to-end install/launch smoke tests. | Deferred | Relevant to package hardening and release readiness, but not changed by Phase 0. |
| README install-path routing, maturity/trust links, Zig version matrix, error catalog, ADRs, performance thresholds, backend conformance build targets, checksum signing, MCPB pin docs, and README/package README duplication. | Deferred | Valid roadmap or polish items, but outside this baseline reconciliation unless their text misstates current state. |
| Original correction that all v0.2.0 assets returning 404 was stale. | Still valid correction | GitHub release assets were reachable through release metadata; the missing release asset class is MCPB. |
| Original correction that fuzzing is CI-gated. | Still valid correction | No Phase 0 change needed. |

## 5. Generated And Artifact Hygiene

Phase 0 touches roadmap documentation only. It does not hand-edit generated
tool-index output, JSON manifests, package build outputs, coverage output,
`zig-out/`, or release artifacts. Because this reconciliation records release
and artifact workflow claims, the handoff validation includes:

```sh
zig build docs-check json-check
zig build artifact-hygiene
```

If the skills package is edited in a later phase, run:

```sh
cd packages/@zigars/skills
npm test
npm run pack:dry
```

## 6. Phase 1 Notes

- Phase 1 should start from the existing MCP routes and add missing contract
  projection: declared `outputSchema`, manifest-backed completions, and
  artifact `resource_link` content blocks.
- No Phase 1 work should add `zig_architecture_layer` or expose zigars'
  internal layer policy as a default public tool.
- Skills package publish readiness is now a packaging validation question, not
  a "directory is placeholder" decision.
