# S5 — Architecture guard soundness (Wave 1)

> **Cold-start session.** Repo `zigars`, **Zig 0.16**, **ReleaseSafe**. Read `AGENTS.md` first.
> The architecture guard is a CI gate that enforces the project's layering walls (e.g. `infra` must
> not import `adapters/mcp`). It currently **lies** — it can be defeated by the project's own normal
> idioms. No untrusted-input path reaches it, so this is CI/maintainability soundness, not a runtime
> vuln — but it's release-blocking for the guard's purpose.
> **Rules:** verify first · stay within *Files in scope* · add guard **self-tests** · branch
> `git switch -c fix/architecture-guard` · validate and report.

**Review:** `docs/reviews/2026-05-29-tools-build-ci-review.md` — HIGH-1, HIGH-2, MEDIUM-6, LOW-7.

## Files in scope (only these)

- `tools/quality/architecture_guard.zig`
- `build.zig` — **read only** (parse `addImport` pairs from it; do not edit it)

## Findings

1. **[HIGH-1] `build.zig` named-module imports bypass every wall.** The guard scans only `src/`
   (~214) and returns any non-`.zig` import target unchanged (`normalizeImport` ~471); the
   forbidden-import predicates match `src/…` prefixes or the single hardcoded bare name `"mcp"`
   (~644-706). But named modules are the project's normal wiring — `build.zig` already does
   `addImport("cancellation", b.path("src/domain/cancellation.zig"))`. So
   `infra_mod.addImport("render", b.path("src/adapters/mcp/server.zig"))` +
   `@import("render")` introduces a real `infra → adapters/mcp` edge that passes silently.
   **Fix:** parse `addImport(name, b.path("…"))` pairs out of `build.zig` into a name→path map,
   resolve bare module names through it before applying predicates, and **deny unknown bare names** in
   deny-by-default layers.

2. **[HIGH-2] One crafted line latches a whole file into "test mode."** `test_tail_active` is set
   (~266) but never cleared; the arming heuristic (~582) fires on any `const … @import(…
   "testing/" …)` line, and because `is_test_file` is computed before the import check, that line also
   exempts itself from `no_production_testing_import`. So a single
   `const _t = @import("../../testing/fakes/root.zig");` at the top of a production file (a) escapes
   the testing-import wall and (b) flips every later line to test-exempt (`checkImport`,
   `checkEffectTokensInLine`, `checkMcpResultBoundaryInLine` all early-return on `is_test_file`).
   **Fix:** scope test context to real brace depth (`test_depth > 0`) and drop the irreversible
   latch (or reset it when `test_depth` returns to 0). Don't treat a heuristic import line as a
   `test {` block.

3. **[MEDIUM-6] Coverage gaps.** No `.adapter_other` import wall (`else => {}` at ~345) → a non-mcp
   `src/adapters/` (e.g. CLI) adapter may freely import `src/infra/**` or `src/adapters/mcp/**`; any
   `src/` dir not matching the 8 known prefixes is `.other` and exempt from all walls; no
   dependency-cycle detection exists. **Fix:** add an `.adapter_other` import wall + cross-adapter
   isolation; fail-closed (or at least warn) on unclassified `src/` dirs; add an import-graph cycle
   check.

4. **[LOW-7] False positives on inert content.** `checkMcpResultBoundaryInLine` (~386) and
   `checkEffectTokensInLine` (~397) don't skip multiline-string lines, and `withoutLineComment`
   (~569) truncates at the first `//` with no string-awareness — so a doc line like
   `\\ … mcp.tools.ToolResult …` produces a false CI failure. **Fix:** apply the
   `isMultilineStringLiteralLine` skip in those checks; strip comments with string-literal awareness.

## Acceptance

- Add guard **self-tests** proving it now **catches** (a) a `build.zig`-aliased forbidden import and
  (b) a test-tail-latched violation — and does **not** flag the LOW-7 false-positive doc line.
- Find the guard's build step (grep `build.zig` for `architecture`/`guard`/`hygiene`) and run it to
  confirm the **current real tree still passes** clean after the fix.
- `zig fmt build.zig build.zig.zon src tools` · `zig build test` green. Report commands run.
