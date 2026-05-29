# S7 — Job/subscription ring eviction + tasks projection + retained-byte clamp (Wave 2)

> **Cold-start session.** Repo `zigars`, **Zig 0.16**, **ReleaseSafe**. Read `AGENTS.md` first.
> **Rules:** verify first · stay within *Files in scope* · regression test (fails before / passes
> after) · branch `git switch -c fix/jobs-tasks-ring` · validate and report.

**Reviews:** `docs/reviews/2026-05-29-mcp-server-core-protocol-transports-review.md` — MEDIUM-1,
LOW-3; `docs/reviews/2026-05-29-infra-zls-process-workspace-observability.md` — M2, L3.

## Files in scope (only these)

- `src/infra/runtime_ux/state.zig`
- `src/adapters/mcp/server/tasks.zig`
- `src/infra/zls/documents.zig`

## Findings

1. **[MEDIUM] Job & subscription "rings" only ever churn slot 0 after capacity** (`state.zig`
   ~279-286 `reserveJobSlot`; identical pattern in `subscribe` ~193-200). The docstring promises
   "overwrite the oldest slot," but once `job_count == max_jobs (32)` every new job returns
   `&self.jobs[0]` and `job_count` never advances — slots 1–31 freeze holding jobs #2–#32 forever
   while jobs #33+ clobber slot 0. `appendEvent` (~266) already does this correctly via
   `ringIndex(sequence, max_events)`. **Impact:** a long-lived server loses results for the 33rd+
   background task via `zigars_job_status`/`job_result`. **Fix:** use a true ring — track a head
   index, overwrite `jobs[head % max_jobs]`, advance head — for both jobs and subscriptions. Project
   `tasks/list` sorted by the existing `created_sequence` field (`state.zig` ~131). If 32 is a hard
   cap, return an explicit "evicted" status for unknown-but-recent ids rather than a bare "Task not
   found."

2. **[LOW] `tasks/result` duplicates raw, unnormalized job fields beside the spec `task`**
   (`tasks.zig` ~131-138) — the top-level `status` exposes internal vocabulary (`queued`/`running`)
   that disagrees with the normalized `task.status` (`working`). Cosmetic contract inconsistency.
   **Fix:** drop the raw duplicates (or normalize them); keep the payload inside `task` /
   `structuredContent`.

3. **[LOW] `documents.zig` retained-byte subtraction is unclamped** (~321, ~442, ~452) — raw
   `self.retained_content_bytes -= contentLen(...)`, whereas `diagnostics_cache.zig` deliberately
   clamps via `subtractBytesLocked`. No underflow on traced paths today, but a future accounting
   desync wraps to ~`usize.MAX` and spuriously trips `RetainedContentLimitExceeded`. **Fix:** mirror
   the cache's saturating subtraction.

## Acceptance

- Test the ring with `max_jobs + 2` pushes (the existing test only pushes `max_jobs + 1` and asserts
  slot 0 — that's what hid this): assert eviction picks the **oldest**, that the 33rd job is
  retrievable by id, and that `tasks/list` is ordered by `created_sequence`. Same for subscriptions.
- A `tasks/result` test asserting the top-level/`task` status agree (or the raw fields are gone).
- `zig fmt build.zig build.zig.zon src tools` · `zig build test` · `zig build smoke` ·
  `zig build -Doptimize=ReleaseSafe` green. Report commands run.
