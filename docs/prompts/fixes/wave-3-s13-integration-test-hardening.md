# S13 — Integration / smoke test hardening (Wave 3)

> **Cold-start session.** Repo `zigars`, **Zig 0.16**, **ReleaseSafe**. Read `AGENTS.md` first.
> These gates currently **can't catch the regressions they imply they catch** — the fix is mostly
> *new assertions and fixtures*, not production-code changes.
> **Rules:** verify first · stay within *Files in scope* · branch
> `git switch -c fix/integration-test-hardening` · validate and report.

**Review:** `docs/reviews/2026-05-29-tools-build-ci-review.md` — MEDIUM-4, MEDIUM-5, LOW-8, LOW-9.
Land **after Waves 1–2** so the new fixtures assert the fixed behavior (e.g. S4/S6 results), not the
buggy baseline.

## Files in scope (only these)

- `tools/integration/smoke_support.zig`
- `tools/integration/common/**`
- `tools/integration/http/**`
- `tools/integration/stdio/**` (add fixtures; the stdio harness is the gold standard to mirror)

## Findings

1. **[MEDIUM-4] Smoke suite never asserts `isError`** (`smoke_support.zig` ~45-50;
   `grep isError tools/integration tools/common` → none). The server emits failures as `result` with
   `isError:true` + a structured payload; both extractors read only `structuredContent`/text, so a
   regression that flips `isError` (error↔success) passes every fixture. **Fix:** return `isError`
   from `callTool`/`callHttpToolJson` and assert it — `argument_error` ⇒ `isError==true`, ordinary
   results ⇒ `false`.

2. **[MEDIUM-5] HTTP apply-gating is never checked against the filesystem**
   (`grep readFile|expectFileContains tools/integration/http` → none). `http_transactional_editing_smoke.zig`
   sends `apply:true` against a blocked path and asserts only the self-reported `applied:false`; only
   stdio verifies writes against disk. **Fix:** after the blocked-apply call, assert the target file
   does **not** exist on disk; mirror stdio's negative `expectFileContains` on HTTP for the
   cache/generated/blocked path classes. Also add a **sandbox-escape rejection** fixture
   (`../../etc/passwd` / out-of-workspace absolute) asserting rejection — currently path-safety is
   only described in a text field, never exercised.

3. **[LOW-8] HTTP smoke helpers panic instead of failing cleanly** (`smoke_support.zig` ~45
   `…get("result").?.object`, ~49 `.?` chain) while the stdio client guards the JSON-RPC `error`
   envelope (`stdio_fixtures.zig` ~446 `if (... get("error")) |_| return error.McpError;`). **Fix:**
   mirror the stdio `error` guard; replace `.?` with `orelse return error.AssertionFailed`.

4. **[LOW-9] Non-deterministic smoke port** (`smoke_support.zig` ~15-19, wall-clock-derived) —
   contradicts the determinism goal; concurrent runs / lingering sockets flake. **Fix:** bind port 0
   and read back the assignment, or retry on `AddrInUse`.

## Acceptance

- `isError` asserted on error-path fixtures; HTTP apply-gating + sandbox-escape verified against disk;
  helpers fail with diagnosable errors (no `.?` panics); deterministic port.
- `zig fmt build.zig build.zig.zon src tools` · `zig build test` ·
  `zig build smoke stdio-fixtures` · (HTTP smoke target) green. Report commands run.
