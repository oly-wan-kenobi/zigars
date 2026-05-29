# S10 — App-layer LOW leaks & robustness (Wave 3)

> **Cold-start session.** Repo `zigars`, **Zig 0.16**, **ReleaseSafe**. Read `AGENTS.md` first.
> These are bounded LOW correctness/leak items (mostly arena-masked today). Keep changes minimal.
> **Rules:** verify first · stay within *Files in scope* · add/upgrade a leak or behavior test where
> noted · branch `git switch -c fix/app-low-leaks` · validate and report.

**Review:** `docs/reviews/2026-05-29-app-usecases-validation-static-analysis-review.md` —
Findings 4, 5, 6, 7, 8, 9.

## Files in scope (only these)

- `src/domain/zig/analysis.zig`
- `src/domain/zig/static_analysis_contracts.zig`
- `src/app/usecases/static_analysis/lint_intelligence.zig`
- `src/app/usecases/static_analysis/semantic_index.zig`
- `src/app/usecases/static_analysis/agent_ergonomics.zig`
- `src/app/usecases/validation/workflows.zig` (the `plan()` consistency fix only)

## Findings

1. **[LOW] `parseAst` leaks the source buffer on `Ast.parse` OOM** (`analysis.zig` ~264-267).
   `Ast.deinit` doesn't free `tree.source`, so an OOM from `Ast.parse` leaks the duped buffer; the
   production caller uses the base GPA, not an arena. **Fix:** `errdefer allocator.free(source);`
   between the dupe and the parse.

2. **[LOW] `forTool(...) orelse unreachable` panics on any future tool-registration gap**
   (`static_analysis_contracts.zig` ~225). Not reachable today, but a future tool added without a
   matching contract entry becomes a ReleaseSafe panic crashing the serial server. **Fix:** return
   `error.UnknownTool` (or skip metadata) on miss; add a comptime/test assertion that every dispatched
   tool name resolves.

3. **[LOW] `normalizeFindingsText`/`normalizeRulesText` drop the `Parsed` handle** (arena-masked leak)
   (`lint_intelligence.zig` ~468, ~515; `semantic_index.zig` ~100, ~529). `parseFromSlice` result is
   never `deinit`'d. Downstream values are deep-copied via `ownedString`, so **Fix:** add
   `defer parsed.deinit();` after each `parseFromSlice` (matching `semantic_index.zig` ~447).

4. **[LOW] `findingsArray` empty fallback binds `std.heap.page_allocator`** (`lint_intelligence.zig`
   ~485; `semantic_index.zig` ~546). No live bug (returned empty, only iterated) but a footgun if a
   future edit appends. **Fix:** thread the caller allocator through `findingsArray`.

5. **[LOW] `containsWordIgnoreCase` silently fails on needles > 128 bytes** (`agent_ergonomics.zig`
   ~1050-1053). A >128-char `topic` token never matches, skewing insertion-site/module-role results;
   the pre-lowering is also redundant. **Fix:** compare with `std.ascii.eqlIgnoreCase` directly and
   drop the 128-byte ceiling.

6. **[LOW] `plan()` embeds raw changed-paths in `zig fmt`/`ast-check` argv** (`validation/workflows.zig`
   ~455-461). Adjudicated **consistency-only**: the path is already gated by `workspacePathExists` →
   `workspace_store.read` (sandboxed), so out-of-workspace paths are dropped before argv — **and** the
   argv *is* spawned server-side by `run()` (so don't rely on "it's just a plan"). **Fix:** resolve
   each surviving path via `workspace_store.resolve` and embed the resolved path, matching
   `buildZigArgv`.

## Acceptance

- A non-arena (base-GPA) leak test around `normalizeFindingsText`/`normalizeRulesText` and `parseAst`
  OOM (e.g. `std.testing.checkAllAllocationFailures` or `FailingAllocator`); a contract-completeness
  test that every dispatched tool name resolves (covers #2); a >128-char topic match test (#5).
- `zig fmt build.zig build.zig.zon src tools` · `zig build test` ·
  `zig build -Doptimize=ReleaseSafe` green. Report commands run.
