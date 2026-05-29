# S3 — ReleaseSafe numeric-panic sweep (coverage + budget + version) (Wave 1)

> **Cold-start session.** Repo `zigars`, **Zig 0.16**, **ReleaseSafe** — a negative/oversized
> `@intCast` into an unsigned type, an `@intFromFloat`, or an integer multiply/add overflow **traps
> and crashes the single-process serial server (unauthenticated single-call DoS)**. Read `AGENTS.md`.
> **Rules:** verify first · stay within *Files in scope* · regression test per fix (the payload must
> panic on current code) · branch `git switch -c fix/numeric-panic-sweep` · validate and report.

This is the project's **#1 panic class**: raw JSON ints / `argInt` values cast into unsigned or
narrow types without a clamp. Inputs come straight from client args / tool-supplied JSON, several on
read-only (non-`apply`-gated) tools.

**Reviews:**
`docs/reviews/2026-05-29-app-usecases-b-diagnostics-performance-release-environment-editing-review.md`
— Findings 1, 2, 4, 8; `docs/reviews/2026-05-29-domain-manifest-bootstrap-review.md` — Finding 3;
`CODE_REVIEW.md` — H1 (float-cast siblings).

## Files in scope (only these)

- `src/domain/performance/coverage_model.zig`
- `src/app/usecases/performance/workflows.zig`
- `src/app/usecases/performance/coverage.zig`
- `src/app/usecases/environment/workflows.zig`

Do **not** edit `src/app/usecases/usecase_support.zig` (owned by S2; its `floatToInt` guard is
already fixed).

## Findings

1. **[HIGH] `rateBp` multiply overflow** (`coverage_model.zig` ~54; accumulation `appendFile` ~167).
   `covered * 10000` overflows `usize` once `covered ≳ 1.84e15`; JSON counts are clamped lower-bound
   only (`@max(0,..)`), so reach `i64` max. Reachable via `zig_coverage_map`/`_diff`/`_merge` (no
   `apply`). **Fix (widen + cap to 100%):**
   ```zig
   pub fn rateBp(covered: usize, total: usize) usize {
       if (total == 0) return 0;
       const num = @as(u128, covered) * 10000;
       return @intCast(@min(@as(u128, 10000), num / total));
   }
   ```
   Use saturating ops (`+|`) for the `existing.total += total` / `set.covered += ...` accumulation in
   `appendFile`.

2. **[HIGH] Negative coverage-budget `@intCast`** (`performance/workflows.zig` ~216-217; field types
   `usize` at `coverage.zig` ~29-30). `.min_line_rate_bp = @intCast(argInt(args,
   "min_line_rate_bp", 8000))` traps on a negative `i64`. `zig_coverage_budget_check` is read-only —
   `{"min_line_rate_bp": -1}` aborts the server. **Fix:** `@intCast(@max(0, argInt(...)))` for both
   fields (matches the `@max(1, …)` pattern already used for `limit` nearby).

3. **[MEDIUM] `parseVersionPrefix` `u32` overflow** (`environment/workflows.zig` ~1372-1390;
   overflow at ~1379/1386). `major = major * 10 + digit` over the (untrimmed-length) stdout of
   `zig version` / `zls --version`; a ≥10-digit component traps — violating "malformed backend output
   must not panic." **Fix:** overflow-checked/saturating parse returning `null` (→ status
   `"unknown"`), e.g. `std.math.add(u32, std.math.mul(u32, major, 10) catch return null, d) catch
   return null;`, or bound the component length.

4. **[LOW] Negative `threshold_pct` inverts the bench gate** (`performance/workflows.zig` ~339/357;
   `i64→i64`, no panic). A negative threshold makes `zig_bench_regression_gate`/`zig_bench_compare`
   produce nonsensical pass/fail. **Fix:** `@max(0, argInt(...))` or reject negatives with a
   structured error.

5. **[VERIFY] H1 float-cast siblings** (`CODE_REVIEW.md` H1): confirm
   `performance/workflows.zig` ~1097 and `coverage_model.zig` ~188 are guarded (the App-B sweep
   suggests they are: `@max(1,…)`-guarded or `i64→i64`). Fix only if a raw unguarded
   `@intFromFloat`/unsigned cast of an `argInt`/JSON int remains.

## Acceptance

- Regression tests with the exact DoS payloads: huge JSON coverage counts (e.g.
  `total_lines/covered_lines = 2_000_000_000_000_000`), `{"min_line_rate_bp": -1}`,
  `parseVersionPrefix("99999999999.0")`, negative `threshold_pct` — each panics on old code, passes
  on new. Existing `1e308`/NaN coverage tests still pass.
- `zig fmt build.zig build.zig.zon src tools` · `zig build test` ·
  `zig build -Doptimize=ReleaseSafe` green. Report commands run.
