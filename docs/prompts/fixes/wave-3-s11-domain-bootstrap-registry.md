# S11 — Domain / bootstrap / registry robustness + dead-code deletion (Wave 3)

> **Cold-start session.** Repo `zigars`, **Zig 0.16**, **ReleaseSafe**. Read `AGENTS.md` first.
> **Rules:** verify first · stay within *Files in scope* · regression test per fix · branch
> `git switch -c fix/domain-bootstrap-registry` · validate and report.

**Reviews:** `docs/reviews/2026-05-29-domain-manifest-bootstrap-review.md` — Findings 6, 8;
`docs/reviews/2026-05-29-infra-zls-process-workspace-observability.md` — L1, L2; `CODE_REVIEW.md` —
M5 (the registry half).

## Files in scope (only these)

- `src/domain/zig/zon_dependencies.zig`
- `src/bootstrap/config.zig`
- `src/infra/artifacts/registry.zig`
- `src/infra/zls/edits.zig` (delete) + its test references

## Findings

1. **[LOW] `fieldInEntry` uses substring search, not a token-aware scan** (`zon_dependencies.zig`
   ~276). A dependency entry containing the literal `.url = "` / `.hash = "` inside a comment or
   another value matches the wrong occurrence; a later `replaceHash`/upgrade then splices the wrong
   span and corrupts the manifest. In-bounds (no panic) — pure correctness. **Fix:** scan for the
   field as a token at brace-depth 1, skipping over string literals and comments. (Note: ZON injection
   itself is already closed via `requireSafeStringLiteralField` — don't undo that.)

2. **[LOW] Empty path flags accepted → deferred spawn failure** (`bootstrap/config.zig` ~76).
   `--audit-log` rejects empty values but `--zig-path`/`--zls-path`/`--workspace` via
   `replaceOwned`→`dupeNext` do not, so `--zig-path ""` stores an empty `argv[0]` that fails obscurely
   at first tool use. **Fix:** reject empty values for path-like flags in `dupeNext` or a dedicated
   validator, mirroring the `--audit-log` check.

3. **[LOW] A single corrupt registry line disables the artifact subsystem** (`registry.zig`
   ~222-228). `loadRegistry` runs at the top of every `put`/`recordWorkspace`; any malformed line
   aborts the whole load → `error.Unavailable` for all artifact writes. **Fix:** skip-and-continue on
   a bad line.

4. **[LOW→correctness] Negative on-disk `bytes` → `@intCast` panic** (`registry.zig` ~367:
   `owned.bytes = @intCast(integerField(obj,"bytes") …)`). A negative value in a tampered/corrupt
   `.zigars-cache` JSON traps in ReleaseSafe. (This is the still-live half of `CODE_REVIEW.md` M5; the
   `patch_sessions.zig` half is already guarded.) **Fix:** `std.math.cast(usize, …)` /
   `@intCast(@max(integerField(...) orelse 0, 0))`, or reject negatives as malformed (fits #3's
   skip-bad-line).

5. **[LOW] `src/infra/zls/edits.zig` is entirely dead code** — `applyTextEdits` /
   `lspPositionToByteOffset` are referenced only by `edits_tests.zig`; the live edit path is
   `domain/editing/patch_session.zig`. Its UTF-16 math is correct but it has no production caller and
   writes nothing (so its apply-gate/atomic-write invariant is moot). **Fix:** delete `edits.zig` and
   its test file / references. (If ZLS-driven code-action apply is ever wired up, route it through the
   gated `patch_session` path — out of scope here.)

## Acceptance

- Tests: a registry file with one malformed line still loads the good entries (#3); `"bytes": -1`
  loads without panic (#4); empty `--zig-path` is rejected at startup (#2); the `fieldInEntry`
  wrong-match case (a `// see .url = "..."` comment) does not corrupt a `replaceHash` (#1); the build
  still compiles with `edits.zig` removed (#5).
- `zig fmt build.zig build.zig.zon src tools` · `zig build test` ·
  `zig build -Doptimize=ReleaseSafe` green. Report commands run.
