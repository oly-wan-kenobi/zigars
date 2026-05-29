# S14 — Release-gate scope, docs reconciliation, accepted-risk + severity updates (Wave 3)

> **Cold-start session.** Repo `zigars`, **Zig 0.16**, **ReleaseSafe**. Read `AGENTS.md` first.
> Mostly docs/test/wording reconciliation — little or no production-logic change. **Land last** (it
> edits the review trackers to reflect what the other waves fixed).
> **Rules:** verify first · stay within *Files in scope* · branch
> `git switch -c fix/release-gate-docs` · validate and report.

**Reviews:** `docs/reviews/2026-05-29-tools-build-ci-review.md` — MEDIUM-3 (adjudicated **LOW**),
LOW-10, LOW-11 (accepted), Informational (committed dist); `docs/reviews/codex-disagreed-findings.md`
(severity adjudications); App-B release Quality notes (optional cosmetics).

## Files in scope (only these)

- `tools/release/release_checks.zig`, `tools/release/release_rules.zig`
- `AGENTS.md`, `docs/release.md`
- `.github/workflows/*.yml` (LOW-11 only)
- `docs/reviews/*.md` + `CODE_REVIEW.md` + `docs/reviews/codex-disagreed-findings.md` (severity/status)
- `src/app/usecases/release/workflows.zig` (optional cosmetics only)

## Tasks

1. **[LOW — was MEDIUM-3] Pure-Zig/no-`.py` gate scope.** Adjudication: the gate is *correctly
   scoped* — `docs/release.md` ~145 and `AGENTS.md` ~44 both limit it to `.github, docs, examples,
   scripts, src, tests, tools` (npm `packages/` is JS/TS by design), so "packages ships a `.py`
   undetected" is **not** false assurance. **Do:** (a) decide policy — either accept the documented
   scope (preferred; the message is accurate) **or** deliberately add `packages/` if you want it
   covered; (b) add a **negative-path test** that plants a `.py` under a scoped root and asserts the
   gate fails (none exists today); (c) optionally tighten the `release_checks.zig` message so it can't
   be read as covering `packages`.

2. **[LOW-10] Python-in-CI vs AGENTS.md "pure Zig … CI paths."** `.github/scripts/*.sh` embed inline
   `python3 <<'PY'` heredocs (safe: quoted, env-passed data, list-argv) — but `AGENTS.md` ~44 bans
   Python "under … CI paths." Reconcile: **reword AGENTS.md** to scope the ban to the **shipped Zig
   tree** (matching the gate's real `.py`-extension behavior), or port the inline Python to Zig.
   Recommend the reword.

3. **[LOW-11 — accepted] `workflow_dispatch` input interpolated into `run:`**
   (`release-readiness.yml` ~59, `backend-conformance.yml`, `zls-conformance.yml`). Arbitrary command
   execution by design, manual dispatch, write-access actors, `contents:read` — **accepted risk**.
   Either leave as-is with a one-line comment, or (cleaner) pass via `env:` and invoke a vetted
   script. Document the decision.

4. **[Informational] Committed `packages/@zigars/mcp/dist/*.js`.** Confirm tracking these build
   outputs is intentional vs AGENTS.md's "do not commit build outputs," and document the exception in
   `AGENTS.md`/`docs/release.md` either way.

5. **Severity & status reconciliation** (the point of the codex challenge): in the review files +
   `CODE_REVIEW.md` + `codex-disagreed-findings.md`, apply the adjudicated outcomes — MEDIUM-3 →
   **LOW**; domain-manifest Finding 4 (`read_only` coexists with exec) → **LOW** (raw `read_only` is
   not the MCP source of truth; `mcp_read_only_hint`/`readOnlyHintFor` is). Reclassify **already-fixed**
   items as fixed: ZON injection (`CODE_REVIEW.md` M6), reentrant dispatch (M1), npm cache poisoning
   (M2), constant-time compare (L6), unguarded re-`initialize` (L1). Leave a short note where codex
   was *wrong* (app-`plan()` #4: the argv **is** spawned server-side by `run()`; it's safe via the
   read-probe gating, not because "it's just a plan").

6. **[Optional cosmetics]** `stripXml` is a no-op (`release/workflows.zig` ~1499; JUnit `<failure>`
   markup emitted raw — raw evidence preserved elsewhere); best-effort registry indexing swallows
   errors (~1315) — add a one-line intent comment. Skippable.

## Acceptance

- New negative-path gate test (#1) passes; docs/AGENTS wording matches enforced behavior; review
  trackers reflect adjudicated severities.
- `zig build artifact-hygiene` (or `zig build release-check`) green; `zig build test` green if you
  touched gate code. Report commands run.
