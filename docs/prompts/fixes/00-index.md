# Fix campaign — session prompts

Each file in this directory is a **standalone, paste-into-a-fresh-session prompt** that fixes one
conflict-free cluster of findings from the 2026-05-29 review pass
(`docs/reviews/*.md` + `CODE_REVIEW.md`).

## How this is organized

- **One session per file-cluster, not per finding.** Many findings share files; splitting them
  across sessions would guarantee merge conflicts. Each session owns a disjoint set of files.
- **Sessions within a wave touch disjoint files** → run them in parallel, each in its own
  worktree/branch (`git switch -c fix/<slug>`).
- **Waves are ordered by severity and dependency.** Land a wave (merge to `main`) before starting
  the next, then rebase the next wave on `main`. Cross-wave file overlaps are intentional and safe
  *because* waves are serialized (e.g. S1 and S12 both touch `src/manifest/definitions/`).
- **Adjudicated severities applied.** The 10 codex-disputed findings carry their adjudicated
  severities (see `docs/reviews/codex-disagreed-findings.md`): MEDIUM-3 pure-Zig gate → LOW,
  manifest `read_only` → LOW; the two true drops (LOW-5 resource-error path, LOW-11
  `workflow_dispatch`) are handled as doc/accept items in S14, not code changes.

## Wave map

| Wave | Sessions | Theme |
|---|---|---|
| **1 — HIGH + directly-reachable DoS/corruption** | S1 manifest trust annotations · S2 app subprocess sandbox · S3 ReleaseSafe numeric-panic sweep · S4 editing safety · S5 architecture guard | the release-blockers |
| **2 — MEDIUM core/infra/fidelity** | S6 MCP server core · S7 jobs/tasks/state ring · S8 workspace TOCTOU · S9 contract fidelity A | correctness/robustness |
| **3 — LOW + fidelity B + tests + docs + npm** | S10 app LOW leaks · S11 domain/bootstrap/registry · S12 contract fidelity B · S13 integration tests · S14 release-gate + docs + accepted-risk · S15 npm shim | the tail |

## Already-fixed (verify, then skip if confirmed)

Recent commits closed several brief items. Each prompt says "verify first," but for the record these
appear **already remediated**: reentrant elicitation dispatch (`protocol_client.zig`,
now `rejectNestedRequest`); npm cache-poisoning re-hash (`install.ts`); non-constant-time checksum
compare (`checksums.ts`); ZON injection (`zon_dependencies.zig`, `requireSafeStringLiteralField`);
unguarded re-`initialize` (`server.zig`); `argInt .float`→`@intFromFloat` at `usecase_support.zig`
(`floatToInt` guard); `patch_sessions.zig` negative `@intCast` (guarded `@max`).

## Standard footer (already embedded in each session file)

> Cold-start session. Repo `zigars` = deterministic **Zig 0.16** MCP server, built/run in
> **ReleaseSafe** (a failed `@intCast`/`@intFromFloat`, `unreachable`, OOB, or integer overflow
> **panics → crashes the serial transport = DoS**). Read `AGENTS.md` and the smallest applicable
> `.agents/` file first. Verify each finding is still present before editing; stay strictly within
> the listed files; add a regression test that fails before / passes after; no shell anywhere; work
> on a dedicated branch; validate with `zig fmt build.zig build.zig.zon src tools`, `zig build test`,
> `zig build docs-check json-check`, `zig build -Doptimize=ReleaseSafe`, and summarize what you ran.
