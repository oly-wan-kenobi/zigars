# Phase 2 - Dependency Lifecycle

Source plan: `../zigar-improvement-surface-implementation.md`

## Goal

Close the highest-signal capability gap: package discovery, apply-gated
`build.zig.zon` mutation, hash synchronization, and resumable dependency
migration.

## Standing Constraints

- Every source mutation is preview-first and requires `apply=true`.
- Every user-provided path resolves under the workspace before read or write.
- Command-backed tools must record exact argv, timeout behavior, stdout/stderr
  handling, and unavailable states.
- Registry/network-backed tools must label provider, trust basis, retrieved URL,
  cache behavior, and offline/unavailable behavior.
- Prefer direct URL/ref and `zig_zon_dep_sync` before registry browse.
- Keep `zig_pkg_docs` deferred unless autodoc access is bounded and reliable.

## Current Code Anchors

- Existing read-only dependency tools live in
  `src/adapters/mcp/tools/dependencies.zig`,
  `src/app/usecases/release/workflows.zig`, and
  `src/manifest/definitions/phase6.zig`.
- Existing workspace/dependency orientation lives in
  `src/adapters/mcp/tools/static_analysis.zig` and
  `src/manifest/definitions/static_analysis.zig`.
- Patch sessions already provide preview/apply/revert mechanics under
  `src/domain/editing/patch_session.zig` and app editing use cases.
- Command execution should go through app ports and infra command runner
  implementations, not direct process calls from adapters.

## Work Items

1. Build a reusable `build.zig.zon` dependency model.
   - Parse dependency names, URLs, hashes, refs, and local path entries.
   - Preserve formatting enough for minimal diffs.
   - Return stable diagnostics for ambiguous or unsupported ZON shapes.
   - Add fixtures for common Zig 0.16 dependency syntax and malformed inputs.
2. Implement `zig_zon_dep_sync`.
   - Preview by default.
   - Use exact `zig fetch` argv through command runner ports.
   - Capture current hash, fetched hash, replacement fragment, unified diff,
     preimage identity, and validation hints.
   - Apply only through patch-session mechanics.
3. Implement direct dependency mutators.
   - `zig_deps_add`
   - `zig_deps_remove`
   - `zig_deps_upgrade`
   - All preview-first, apply-gated, validation-aware, and preimage-checked.
4. Add dependency registry provider abstraction.
   - Direct URL/ref provider first.
   - Zigistry provider as the first community-index preset.
   - Optional GitHub topic provider only after rate-limit and trust handling
     are explicit.
   - Provider failures are structured results, not generic command failures.
5. Implement registry browse tools.
   - `zig_pkg_search`
   - `zig_pkg_info`
   - `zig_pkg_versions`
   - `zig_pkg_readme`
6. Implement `zig_dependency_migrate`.
   - Session-backed orchestrator over update plan, sync/add/upgrade, fetch
     check, lock audit, impact, security, and validation.
   - Use shared session envelope if Phase 5 has already landed; otherwise keep
     the shape aligned so it can migrate cleanly.
   - Rollback uses patch-session preimages.

## Key Files

- `src/app/usecases/dependencies/`
- `src/app/ports.zig`
- `src/infra/process/`
- `src/infra/workspace/`
- `src/adapters/mcp/tools/dependencies.zig`
- `src/adapters/mcp/tools/static_analysis.zig`
- `src/manifest/definitions/phase6.zig`
- `src/manifest/definitions/static_analysis.zig`
- `src/manifest/tool_catalog.json`
- `docs/tool-index.generated.md`
- `tools/integration/http/http_phase6_smoke.zig`
- `tools/integration/stdio/*`

## Tool Contract Notes

- `zig_zon_dep_sync` should return:
  - dependency identifier
  - current manifest entry
  - fetched hash and fetch command evidence
  - proposed manifest fragment
  - unified diff
  - expected preimages
  - `applied: false|true`
  - validation recommendations
- Mutators should return the same preview/apply shape and never silently run
  broad build commands unless requested.
- Registry tools must include provider metadata and confidence/trust fields.

## Tests And Fixtures

- ZON parser fixtures for URL dependencies, local path dependencies, missing
  hashes, hash mismatch, unsupported expressions, and malformed syntax.
- Command-runner fake tests for exact `zig fetch` argv and stderr handling.
- Apply-gate tests proving `apply=false` writes nothing and `apply=true` checks
  expected preimages.
- Provider tests for direct provider success, Zigistry unavailable, offline
  mode, malformed response, and rate-limit style failures.
- Migration session tests for resume, inspect, rollback, stale preimage, and
  failed validation.

## Acceptance Criteria

- `zig_zon_dep_sync` fixes a fixture hash mismatch in preview and apply modes.
- `zig_deps_add`, `zig_deps_remove`, and `zig_deps_upgrade` never mutate without
  `apply=true`.
- Registry browse works with provider unavailable/offline tests.
- `zig_dependency_migrate` can be resumed or inspected by
  `migration_session_id`.
- Manifest, generated tool index, and smoke fixtures agree with the new tools.

## Validation

```sh
zig build test
zig build docs-check json-check
zig build smoke stdio-fixtures
```

For broad parser/mutator coverage:

```sh
zig build test --fuzz=10K
```

## Handoff For Next Phase

Record:

- ZON shapes supported and intentionally unsupported.
- Registry providers implemented.
- Exact mutating tool names and apply semantics.
- Migration session storage shape.
- Validation commands and any known provider limitations.
