# Phase 5 - Compound Workflows And Session System

Source plan: `../zigar-improvement-surface-implementation.md`

## Goal

Promote high-round-trip workflows into auditable sessions with shared lifecycle,
event, artifact, validation, and preimage semantics.

## Standing Constraints

- Sessions must remain deterministic and inspectable.
- All session paths stay under `.zigar-cache/` or another workspace-safe cache
  root.
- Source mutation still requires preview and `apply=true`.
- Stale preimages must prevent apply and rollback.
- Long-running command-backed tools must use app ports and infra command
  runners, never direct process calls from adapters.
- `zig_build_bisect` must never checkout refs in the primary workspace.

## Current Code Anchors

- Existing patch-session domain logic lives in
  `src/domain/editing/patch_session.zig`.
- Existing app editing/session behavior lives under `src/app/usecases/editing/`
  if present, with MCP projection under
  `src/adapters/mcp/tools/transactional_editing.zig`.
- Existing runtime UX state/session code lives under `src/infra/runtime_ux/`
  and `src/adapters/mcp/tools/runtime_ux.zig`.
- Existing MCP task handling lives in `src/adapters/mcp/server/tasks.zig`.
- Artifact and workspace ports live under `src/app/ports.zig` and infra
  implementations.

## Work Items

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
2. Store sessions under a cache-local layout.
   - Preferred: `.zigar-cache/sessions/<kind>/<id>.jsonl`.
   - JSONL events should be append-friendly and bounded.
   - Include migration/versioning behavior for future schema changes.
3. Build lower-risk composed tools first.
   - `zig_c_header_port`
   - `zig_workspace_rename`
   - `zig_bench_regression_gate`
4. Build dependency migration on the shared session envelope if Phase 2 has not
   already done so.
5. Build crash/debug workflows.
   - `zig_crash_capture_session`
   - `zigar_debug_session_create`
   - `zigar_debug_session_step`
   - `zigar_debug_session_view`
   - `zigar_debug_session_close`
6. Build `zig_build_bisect`.
   - Use internal temporary git worktrees under workspace cache.
   - Never checkout refs in the primary workspace.
   - Require explicit execute/apply opt-in because it creates/deletes worktrees
     and runs commands.
   - Record per-ref command evidence and crash/build identity.
7. Build `zig_watch`.
   - Async job plus cursored resource is canonical.
   - Use a `zigar://.../events` style URI for event reads.
   - MCP resource subscription should only signal availability unless true push
     is implemented.
   - Include bounded buffers and explicit stop/cancel.
8. Promote or defer `zig_target_matrix_run`.
   - Implement only if two adopter projects need it.
   - Otherwise document it as a playbook.

## Key Files

- `src/domain/editing/patch_session.zig`
- `src/app/usecases/runtime_ux/`
- `src/app/usecases/transactional_editing/`
- `src/app/usecases/performance/`
- `src/app/usecases/diagnostics/`
- `src/infra/workspace/`
- `src/infra/artifacts/`
- `src/infra/runtime_ux/`
- `src/adapters/mcp/server/tasks.zig`
- `src/adapters/mcp/tools/runtime_ux.zig`
- `src/adapters/mcp/tools/transactional_editing.zig`
- `src/adapters/mcp/tools/performance.zig`
- `src/manifest/definitions/runtime_ux.zig`
- `src/manifest/definitions/transactional_editing.zig`
- `src/manifest/definitions/performance.zig`

## Tests And Fixtures

- Session create/view/resume/close unit tests.
- JSONL append/read tests, including malformed or mixed-version records.
- Stale preimage tests for apply and rollback.
- Fake command runner tests for composed workflows.
- Git worktree fake or integration test proving primary workspace is not
  checked out during bisect.
- Watch lifecycle tests: start, bounded event read, cursor continuation, stop,
  cancellation, and cleanup.
- Smoke fixtures for representative session create/view/close calls.

## Acceptance Criteria

- Sessions can be created, viewed, resumed where claimed, and closed.
- Stale preimages prevent apply/rollback.
- Bisect never mutates the primary worktree.
- Watch can start, emit bounded events, and stop cleanly.
- Session results include artifacts, events, validation, and limitations in
  structured form.

## Validation

```sh
zig build test
zig build smoke stdio-fixtures
```

Run broader validation before broad docs claims:

```sh
zig build release-check
```

## Handoff For Next Phase

Record:

- Session envelope schema and cache paths.
- Which workflows are resumable and which are one-shot.
- Bisect worktree cleanup behavior.
- Watch event URI and cursor semantics.
- Exact validation commands run.
