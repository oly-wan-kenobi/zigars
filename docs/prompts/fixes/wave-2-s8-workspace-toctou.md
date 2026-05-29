# S8 — Workspace resolve→open TOCTOU (Wave 2)

> **Cold-start session.** Repo `zigars`, **Zig 0.16**, **ReleaseSafe**. Read `AGENTS.md` and
> `.agents/roles/security-sandbox-reviewer.md` first. The workspace sandbox is **invariant #1**.
> This is a **defense-in-depth** hardening: not exploitable under today's serial single-threaded
> dispatch, but the fix removes a class of future foot-guns and is testable.
> **Rules:** verify first · stay within *Files in scope* · regression test · branch
> `git switch -c fix/workspace-toctou` · validate and report.

**Review:** `docs/reviews/2026-05-29-infra-zls-process-workspace-observability.md` — M1.

## Files in scope (only these)

- `src/infra/workspace/workspace.zig`
- `src/infra/workspace/filesystem.zig` (only if needed to thread an fd-based open through the port)

## Finding

**[MEDIUM] Check-then-open on a path *string*; realpath-failure degrades to a lexical-only check.**
`resolve()` (~50-110) returns a canonical path *string*; every consumer (`readFileAlloc`, writes via
`createFileAtomic` with default `follow_symlinks`) re-opens that string in a separate syscall — a
classic TOCTOU window. Worse, on any realpath failure other than OOM (~105-110) containment falls
back to the lexical `isInside` check and returns the unresolved string. Not exploitable today (serial
dispatch means the MCP client can't run code inside the resolve→open window; pre-existing
outside-pointing symlinks are still caught by realpath), but it's the sandbox invariant, so harden it.

**Fix:** operate on a **file descriptor**, not a re-walked string — open the canonical parent dir then
`openat`/create the final component with `O_NOFOLLOW`, or use the std `resolve_beneath: true` open
option so the kernel enforces containment atomically. Treat realpath failure as **fatal for inputs**
rather than returning a lexically-checked path.

Preserve all currently-correct behavior (verified safe and must stay so): prefix-sibling escape
rejected (separator required after root), pre-existing outside symlinks caught, `..` collapsed and
rejected, user-supplied absolute paths re-checked.

## Acceptance

- Add a **symlink-swap / TOCTOU test** (now feasible once containment is fd/`resolve_beneath`-based):
  a path component that resolves inside but points outside must be rejected on open, not just on the
  pre-check. Keep the existing static-containment tests green.
- `zig fmt build.zig build.zig.zon src tools` · `zig build test` ·
  `zig build -Doptimize=ReleaseSafe` green. If you change the workspace port surface, run
  `zig build smoke stdio-fixtures`. Report commands run.
