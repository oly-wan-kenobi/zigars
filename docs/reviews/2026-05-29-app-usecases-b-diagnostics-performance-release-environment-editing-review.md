# Code Review — App use-cases B (diagnostics / performance / release / environment / runtime_ux / editing / discovery)

- **Date:** 2026-05-29
- **Reviewer:** senior Zig/MCP review pass (5 parallel subagents, non-overlapping scopes; every actionable claim re-verified against source)
- **Target:** `zigars` — deterministic Zig 0.16 MCP server, built/run in ReleaseSafe
- **Branch:** `main`

## Scope

| Cluster | Files |
| --- | --- |
| diagnostics | `src/app/usecases/diagnostics/workflows.zig`, `crash_evidence.zig`, `src/domain/diagnostics/{crash,stacktrace,root}.zig` |
| performance | `src/app/usecases/performance/{workflows,benchmark,coverage}.zig`, `src/domain/performance/{benchmark_model,coverage_model,root}.zig` |
| release | `src/app/usecases/release/{workflows,drift,ci_evidence,docs_index,release_intelligence}.zig`, `src/domain/release/{docs_index,release_model,root}.zig` |
| environment | `src/app/usecases/environment/{workflows,adoption,trust}.zig` |
| runtime_ux / editing / discovery | `src/app/usecases/runtime_ux/workflows.zig`, `editing/{workflows,patch_sessions}.zig`, `discovery/workflows.zig` |

## Invariants checked

1. Workspace sandbox: every user path resolves under the workspace before read/write.
2. Source-mutating tools require `apply=true`.
3. `stdout` reserved for MCP JSON-RPC; logs to `stderr`.
4. Structured results (`structuredContent` + text fallback).
5. Pure Zig.

## Method note

A cross-cutting sweep for the `@intCast(argInt(...))` panic class was run across all 7 use-case dirs + 3 domain dirs. `argInt` (`usecase_support.zig:322`) returns a raw `i64` that may be negative/huge; casting it into an unsigned type without a clamp traps in ReleaseSafe. The sweep result is summarized under "Verified-safe areas".

Diagnostics and release came back **clean** (confirmed). The real defects are in performance, editing, and environment.

---

## Findings (ranked by severity)

### 1. HIGH · VERIFIED — Negative coverage-budget args crash the server (DoS, no `apply` needed)

- **Location:** `src/app/usecases/performance/workflows.zig:216-217`; field types `usize` at `src/app/usecases/performance/coverage.zig:29-30`
- **Evidence:**
  ```zig
  .min_line_rate_bp = @intCast(argInt(args, "min_line_rate_bp", 8000)),
  .min_changed_line_rate_bp = @intCast(argInt(args, "min_changed_line_rate_bp", 0)),
  ```
- **Impact:** `BudgetRequest.min_line_rate_bp`/`min_changed_line_rate_bp` are `usize`. A negative `i64 → @intCast(usize)` is illegal behavior and **traps in ReleaseSafe**. `zig_coverage_budget_check` is read-only (no `apply` gate), so a single call with `{"min_line_rate_bp": -1}` aborts the single-process server. Unauthenticated DoS.
- **Fix:** clamp before cast (matches the `@max(1, …)` pattern already used for `limit` at lines 228/493/541):
  ```zig
  .min_line_rate_bp = @intCast(@max(0, argInt(args, "min_line_rate_bp", 8000))),
  .min_changed_line_rate_bp = @intCast(@max(0, argInt(args, "min_changed_line_rate_bp", 0))),
  ```

### 2. HIGH · VERIFIED — `rateBp` multiply overflows on attacker-supplied JSON coverage counts (DoS)

- **Location:** `src/domain/performance/coverage_model.zig:54-57`, reached via `parseFilesArray` at `coverage_model.zig:156-158`
- **Evidence:**
  ```zig
  pub fn rateBp(covered: usize, total: usize) usize {
      if (total == 0) return 0;
      return @intCast(@divTrunc(covered * 10000, total));  // covered*10000 overflows usize
  }
  ```
  ```zig
  const total = intField(item.object, "total_lines") orelse intField(item.object, "total") orelse 0;
  const covered = intField(item.object, "covered_lines") orelse intField(item.object, "covered") orelse 0;
  try appendFile(allocator, set, path, @intCast(@max(0, total)), @intCast(@max(0, covered))); // lower-bound only
  ```
- **Impact:** the JSON path clamps only the lower bound — no upper cap — so `covered`/`total` reach `i64` max. `covered * 10000` overflows `usize` once `covered ≳ 1.84e15` and **traps**. Reachable from `coverageSummaryValue` (`workflows.zig:687`, called at `:196`/`:677`) via `zig_coverage_map`/`_diff`/`_merge` — none apply-gated. Payload: `{"files":[{"path":"a","total_lines":2000000000000000,"covered_lines":2000000000000000}]}`. (The LCOV path is bounded by `+= 1` per line, so this is JSON-specific.) Unauthenticated single-call DoS.
- **Fix:** widen the math and cap to 100%:
  ```zig
  pub fn rateBp(covered: usize, total: usize) usize {
      if (total == 0) return 0;
      const num = @as(u128, covered) * 10000;
      return @intCast(@min(@as(u128, 10000), num / total));
  }
  ```
  and/or cap parsed counts in `parseFilesArray`.

### 3. HIGH · VERIFIED — `zig_move_decl` corrupts source when `source_file == target_file`

- **Location:** `src/app/usecases/editing/workflows.zig:124-140`; corruption realized in the apply loop at `:318-326`
- **Evidence:**
  ```zig
  const source_updated = try concat3(allocator, source.bytes[0..range.start], "", source.bytes[range.end..]); // decl removed
  const target_updated = try appendDeclText(allocator, target.bytes, decl_text);                              // ORIGINAL + decl
  const replacements = [_]Replacement{ .{ .file = source.file, .content = source_updated },
                                       .{ .file = target.file, .content = target_updated } };                 // same path
  ```
  Contrast `extractDeclValue`, which guards the case at `:144`:
  ```zig
  if (std.mem.eql(u8, file, target_file) or start_line == 0 or end_line < start_line) return error.InvalidArguments;
  ```
- **Impact:** `moveDeclValue` has no such guard. With `apply=true` the loop writes `source_updated` (decl removed), then re-reads and overwrites with `target_updated` (computed from the *original* bytes + appended decl). Net: the declaration is **duplicated** and the removal is discarded → a file that no longer compiles (redefinition). Source corruption from a refactor tool on a plausible operation ("move a decl within one file"). Loud (won't compile) and VCS-recoverable, but the tool's core promise is violated.
- **Fix:** add `if (std.mem.eql(u8, source_file, target_file)) return error.InvalidArguments;` at the top of `moveDeclValue` (mirror extract), or coalesce same-path replacements into one combined edit.

### 4. MEDIUM · VERIFIED — `parseVersionPrefix` `u32` overflow on backend version output

- **Location:** `src/app/usecases/environment/workflows.zig:1372-1390` (overflow at `:1379` and `:1386`)
- **Evidence:**
  ```zig
  while (index < value.len and std.ascii.isDigit(value[index])) : (index += 1) {
      seen_digit = true;
      major = major * 10 + value[index] - '0';   // :1379 unchecked u32 (minor: :1386)
  }
  ```
- **Impact:** `value` is the trimmed stdout/stderr of `zig version` / `zls --version` (`probeVersion:1403-1408`), captured up to the 1 MiB output limit with no digit bound. A numeric component ≥ ~10 digits (e.g. `9999999999`) overflows `u32` and **traps** — violating the "malformed/truncated backend output must not panic" invariant. Reachable via `zig_zls_match_check` / `zig_zls_compatibility` / `zigars_env_pack` when backend probing runs. Reachability needs control of (or an oddly-versioned) backend binary → MEDIUM.
- **Fix:** overflow-checked/saturating parse returning `null` (→ status `"unknown"`), or bound the component length:
  ```zig
  major = std.math.add(u32, std.math.mul(u32, major, 10) catch return null, value[index] - '0') catch return null;
  ```

### 5. MEDIUM · VERIFIED — `zig_format` / `zig_patch_preview` skip the generated/vendored path policy on apply

- **Location:** `src/app/usecases/editing/workflows.zig:223` and `:276`; adapters `src/adapters/mcp/tools/zls.zig:22,43`
- **Evidence:**
  ```zig
  // formatValue
  if (apply) _ = try context.workspace_store.write(.{ .path = rel, .bytes = formatted.bytes,
      .provenance = "editing.format.apply.write_source" });   // no classifyPath()
  // patchPreviewValue
  if (apply) _ = try context.workspace_store.write(.{ .path = rel, .bytes = content,
      .provenance = "editing.patch_preview.write" });         // no classifyPath()
  ```
  Contrast `replacementSessionValue` (`:306-318`), which sets `safe = false` when `!classifyPath(snap.file).direct_edit_allowed` and only writes `if (apply and safe)`.
- **Impact:** both tools are declared `writes_source=true` yet never classify the path. This is **not** a sandbox or `apply`-gate bypass (path still resolves in-sandbox; `apply` still required), but the documented "direct edits avoid generated/cache/artifact/vendored paths" doctrine is silently unenforced for these two tools, and the caller can't tell (no `safe_to_apply`/`policy` field in their output). `patch_preview --apply` lets arbitrary content land on a vendored/cache path.
- **Fix:** classify `rel` before the `if (apply)` write in both functions; refuse (or downgrade to `safe_to_apply=false`) when `!direct_edit_allowed`, and surface the policy classification in the result.

### 6. MEDIUM · VERIFIED — Duplicate same-file edits in one patch-session apply silently last-wins

- **Location:** `src/app/usecases/editing/patch_sessions.zig:416-434` (same mechanism as finding #3)
- **Evidence:**
  ```zig
  for (request.replacements, 0..) |replacement, index| {
      var snapshot = try readSnapshot(allocator, context, replacement.file);  // re-read each iter
      if (!snapshot.exists or !std.mem.eql(u8, snapshot.bytes, replacement.content)) {
          ... write preimage(snapshot.bytes) ; write replacement.content ...
      }
  }
  ```
- **Impact:** two `edits` targeting the same `file` (via `zigars_patch_session_apply`) apply sequentially: iteration 2 reads iteration 1's output, so the earlier edit is discarded and the recorded preimage for the second entry is the *intermediate* state, not the original (pass-1 diffs/preimages were all against the original). Silent edit loss + a preimage chain that can only revert to the intermediate.
- **Fix:** detect duplicate paths in `request.replacements` up front and reject (`error.InvalidArguments`) or deterministically coalesce before preview/apply.

### 7. LOW · VERIFIED — Expected-preimage TOCTOU between verify and apply passes

- **Location:** `src/app/usecases/editing/patch_sessions.zig:370-382` (verify) vs `:416-434` (apply)
- **Evidence:** pass 1 checks `expected_ok = !request.apply or session_domain.expectedMatches(request.expected_preimages, snapshot.file, preimage)` (`:381`) against the pass-1 read; pass 2 re-reads (`:418`) and overwrites without re-checking the expected preimage against the freshly-read bytes.
- **Impact:** if the file changes between the two reads, apply clobbers the newer content even though the expected preimage no longer matches. **Mitigated to LOW:** the MCP transport is serial/single-threaded (no `spawn` in `src/adapters/mcp`), the reads are microseconds apart with no `await` between them, the apply-elicitation runs entirely before this function, default `expected_preimages=&.{}` fails closed, and the clobbered bytes are saved as a preimage artifact first (revertible).
- **Fix:** re-verify the expected preimage inside the apply loop against the fresh `snapshot`, aborting the whole apply on any mismatch.

### 8. LOW · VERIFIED — Negative `threshold_pct` inverts the bench regression gate (no panic)

- **Location:** `src/app/usecases/performance/workflows.zig:339` & `:357`; `CompareRequest.threshold_pct: i64` at `benchmark.zig:16`
- **Evidence:**
  ```zig
  .threshold_pct = @intCast(argInt(args, "threshold_pct", 5)),   // i64 -> i64: no panic
  ```
- **Impact:** the cast is `i64→i64` (safe), but `benchmark_model.compare` then treats a negative threshold as both "regression if `pct > -10`" and "improvement if `pct < 10`", so `zig_bench_regression_gate` / `zig_bench_compare` produce nonsensical pass/fail. Correctness only; no memory-safety issue.
- **Fix:** clamp `@max(0, argInt(...))` or reject negatives with a structured error.

### Quality notes (release cluster, LOW)

- **`stripXml` is a no-op** (`src/app/usecases/release/workflows.zig:1499-1501`, used at `:543`): JUnit `<failure>` snippets are emitted with raw markup. Cosmetic; raw evidence preserved elsewhere.
- **Best-effort registry indexing swallows errors** (`release/workflows.zig:1315`, `support.recordWrittenArtifact(...) catch {};`): the file write itself (`putFile`, `:1296`) and hashing are `try`; only provenance bookkeeping is best-effort. Reasonable; worth a one-line intent comment.

> **Verified non-issue (checked, not a finding):** `performance/workflows.zig:574` casts `port`/`seconds` from `argInt`, but `tracyCaptureArgv` takes `i64` (`:1221`), so the casts are `i64→i64` no-ops — a negative just yields a bad argv the backend rejects.

---

## High-confidence verified-safe areas

- **`@intCast(argInt)` sweep:** across all 7 use-case dirs + 3 domain dirs, the only unclamped cast of a raw `argInt` into an *unsigned* type is finding #1. Every other site is either `i64→i64` (benign: #8, line 574, `threshold_pct`) or `@intCast(@max(1, …))`-guarded (diagnostics 131/154/181/405/527/643; release 42/53/86/740/987; performance 228/493/541).
- **Diagnostics (clean):** crash/stacktrace parsers (`domain/diagnostics/{crash,stacktrace}.zig`) are bounds-correct on truncated/garbage input — delimiter offsets (`idx+4` for `" in "`, `tick+1`, `end+2`) provably ≤ `line.len`; zero `.?`/`orelse unreachable`/`catch unreachable` in non-test code; `parseInt` is `catch null`. All reads/writes route through `context.workspace_store`; the single write helper (`workflows.zig:1245`) is reached only after the `apply` gate.
- **Release (clean):** exactly two write sites (`workflows.zig:236-238`, `:349-351`), both `if (apply) writeAndRegisterArtifact(...)` → `putFile` (sandboxed); docs-index tools are read-only. JUnit (`parseJunitFailures:532`), SARIF (`parseSarifFailures:551`, `parseFromSlice ... catch return`), and CI-log (`ci_evidence.zig`) parsers tolerate truncation; the only `+1` column overflow case is explicitly guarded (`ci_evidence.zig:133`). Error-path ownership is sound (per-request arena scoping + `errdefer`/`committed` in the 1887-line `domain/release/docs_index.zig`).
- **Editing apply gating & sandbox routing:** `replacementSessionValue` writes only `if (apply and safe)` with `safe` cleared by any `!direct_edit_allowed` path; `revert` fails closed (`patch_sessions.zig:467`); the sole `@intCast` in `patch_sessions.zig` (`:849`) is the known, correctly-guarded `@intCast(if (bytes < 0) 0 else bytes)`; `extractDeclValue` bounds (`lineRange`, 1-based, EOF-guarded) and `concat3` byte-conservation are correct. No raw `std.fs.*` I/O on user paths anywhere in scope.
- **Environment:** all adoption/scaffold writes are `if (apply)`-gated and routed through `putFile`/`resolveOutput`; `trust.zig` is read-only reporting (no on-disk trust store to poison, no trust comparison) — the "trust persistence / timing-safe compare" hunt has no surface here; `build.zig.zon` hash scan tolerates malformed quoting.
- **runtime_ux / discovery:** read-only projection; all `@intCast(timeout_ms)` sites pre-clamped at the adapter; best-effort `catch return`/`catch {}` in hint collectors are intentional optional-evidence paths, not swallowed write failures.

---

## Test-coverage gaps

1. **No negative/huge numeric-arg tests** — nothing exercises `{"min_line_rate_bp": -1}` (#1), huge JSON coverage counts (#2), negative `threshold_pct` (#8), or `parseVersionPrefix("99999999999.0")` (#4). These are the load-bearing guards for the project's #1 panic class; add a regression case at each fix.
2. **No `zig_move_decl` test with `source_file == target_file`** (#3) — one assertion would catch it.
3. **No duplicate-file-in-`edits` test** for patch sessions / replacement sessions (#6), and **no TOCTOU test** simulating a file change between the verify and apply reads (#7) — a fake store returning different bytes on successive reads would cover it.
4. **No test that `zig_format` / `zig_patch_preview` apply respects (or documents ignoring) the generated/vendored policy** (#5).
5. **Coverage JSON-evidence paths** (`zig_coverage_merge` / `_diff` / `_baseline`) lack direct workflow tests; the #2 overflow reaches them via `coverageSummaryValue`.

---

## Bottom line

Two unauthenticated single-call DoS panics in the performance/coverage path (#1, #2), one source-corruption bug in `zig_move_decl` (#3), a backend-output parser overflow (#4), and three editing safety/policy gaps (#5–#7). Diagnostics and release are solid. Highest-priority fixes: **#1 and #2** (trivially reachable, no `apply`), then **#3**.

### Known-open items excluded from this review (already filed)

`argInt` `.float`→`@intFromFloat` (`usecase_support.zig:326`); reentrant dispatch via elicitation (`protocol_client.zig:166`); npm cache poisoning (`packages/@zigars/mcp/src/install.ts:94`); `zig_code_action_batch` stub vs manifest; the three discovery tools returning text-only results; negative `@intCast` at `patch_sessions.zig:848` / `registry.zig:383`; zon injection (`zon_dependencies.zig:193`).
