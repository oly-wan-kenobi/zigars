# Code Review — Domain logic + Manifest invariants + Bootstrap

**Date:** 2026-05-29
**Reviewer:** Senior Zig/MCP systems engineer (multi-agent, evidence-based)
**Build target:** Zig 0.16, ReleaseSafe (integer overflow/underflow, out-of-range `@intCast`/`@intFromFloat`, OOB slicing, and `unreachable` all **panic** the process)

## Scope

- `src/domain/zig/{compiler_output,zon_dependencies,analysis,backend_contracts,static_analysis_contracts,backend_catalog}.zig`
- `src/domain/editing/*` (patch session + path policy)
- `src/domain/diagnostics/*`, `src/domain/profiling/*`, `src/domain/performance/*`, `src/domain/release/*`
- `src/domain/{evidence,trust}.zig`
- `src/manifest/*` (aggregate, mod, types, groups, tooling, definitions, catalog, render)
- `src/bootstrap/*` + `src/main.zig`

Four subagents reviewed non-overlapping file clusters in parallel. Every claim below was **re-verified against source by the lead reviewer** unless explicitly marked INFERRED. Claims that could not be confirmed are listed separately.

## Headline

This is a disciplined codebase. The parsers tolerate malformed input without panicking, the workspace foundation is sound, and bootstrap teardown is clean. The one serious issue is a systematic **MCP trust-annotation defect** in the manifest hint logic (Finding 1). The previously "known-open" ZON injection is in fact **closed**.

---

## Findings (ranked by severity)

### 1. HIGH — VERIFIED — `destructiveHint=false` advertised for 15 command/code-execution tools

**File:** `src/manifest/mod.zig:172`

```zig
pub fn destructiveHintFor(spec: ToolMeta) bool {
    const risk_value = riskFor(spec.id);
    if (risk_value.writes_require_apply and risk_value.preview_by_default) return false; // <-- swallows everything below
    return risk_value.writes_source or risk_value.writes_artifacts or
        risk_value.mutates_lsp_state or risk_value.executes_project_code or
        risk_value.executes_user_command or !spec.read_only;
}
```

This hint becomes the MCP `destructiveHint` annotation verbatim — `src/adapters/mcp/registry.zig:45`:

```zig
.annotations = .{
    .readOnlyHint = manifest.readOnlyHintFor(spec),
    .idempotentHint = manifest.idempotentHintFor(spec),
    .destructiveHint = manifest.destructiveHintFor(spec),
```

The early-return means **any apply-gated tool reports `destructiveHint=false`**, even ones that execute arbitrary caller-supplied commands. Verified affected set (all declare `executes_user_command=true` + the gate flags `writes_require_apply` + `preview_by_default`):

- **`src/manifest/definitions/diagnostics.zig`** (11 tools): `zig_libfuzzer_run`, `zig_afl_run`, `zig_qemu_test`, `zig_heaptrack_run`, `zig_valgrind_memcheck`, `zig_callgrind_report`, `zig_lldb_backtrace`, `zig_core_inspect`, `zig_objdump_summary`, `zig_dwarfdump_check`, `zig_symbolize` — risk profiles at `diagnostics.zig:12-16`.
- **`src/manifest/definitions/performance.zig`** (4 tools): `zig_coverage_run`, `zig_bench_run`, `zig_samply_record`, `zig_tracy_capture` — risk profiles at `performance.zig:12-14`.

Tool descriptions include *"Runs the caller-provided libFuzzer command"* (`diagnostics.zig:156`) and *"Run a caller-supplied coverage command"* (`performance.zig:143`).

The contradiction is internal and self-evident: `zig_profile_run` (*"explicit user-provided profiler command"*, `profiling.zig:21`) and `zig_matrix_check` (`ci.zig:27`) have the **same** `executes_user_command=true` but, lacking the gate flags, correctly report `destructive=true`. So the apply-gate — a safety feature — paradoxically suppresses the destructive annotation.

**Impact:** An MCP client/agent using `destructiveHint` for auto-approval is told that 15 arbitrary-command-execution tools perform only "additive" updates. The runtime `apply=true` gate still stands (comptime-enforced), so this is not direct RCE — but the hint *is* the trust signal an agent uses to decide whether to pass `apply=true`. Calibrated to **HIGH** (a subagent rated it Critical); treat as release-blocking.

**Fix:** Capability must dominate the default-preview convenience. Reorder so execution / source-write forces destructive:

```zig
if (risk_value.writes_source or risk_value.executes_project_code or risk_value.executes_user_command) return true;
if (risk_value.writes_require_apply and risk_value.preview_by_default) return false;
return risk_value.writes_artifacts or risk_value.mutates_lsp_state or !spec.read_only;
```

---

### 2. MEDIUM — VERIFIED — Destructive invariant test reproduces the bug, so Finding 1 is uncovered

**File:** `src/manifest/invariants_tests.zig:35`

```zig
if (!risk.writes_require_apply or !risk.preview_by_default) {     // only un-gated tools
    if (risk.writes_source or ... or risk.executes_user_command ...) {
        try std.testing.expect(manifest.destructiveHintFor(entry.meta));
    }
}
```

The test asserts destructiveness **only** for non-gated tools, so the 15 mislabeled tools pass. `src/manifest/mod_tests.zig:107` even hard-codes the (incorrect) expectation for a gated tool.

**Impact:** the defect is locked in as "intended."

**Fix:** add an unconditional assertion across all entries: any entry with `executes_user_command` (or `executes_project_code`/`writes_source`) must satisfy `destructiveHintFor(entry.meta) == true`.

---

### 3. MEDIUM — VERIFIED — Coverage parser overflow → ReleaseSafe panic (DoS) on crafted input

**File:** `src/domain/performance/coverage_model.zig:54` (and `:167`)

```zig
pub fn rateBp(covered: usize, total: usize) usize {
    if (total == 0) return 0;
    return @intCast(@divTrunc(covered * 10000, total));   // covered*10000 overflows usize
}
```

`covered`/`total` come straight from JSON ints, clamped only `@max(0, ..)` (`coverage_model.zig:156-158`), so each can be up to `i64` max (~9.2e18). A single crafted field `"covered": 1000000000000000000` makes `covered * 10000 ≈ 1e22 > maxInt(usize)` → overflow panic. The `+=` accumulation in `appendFile` (`coverage_model.zig:167-180`) is the same class:

```zig
existing.total += total;
existing.covered += @min(covered, total);
set.total += total;
set.covered += @min(covered, total);
```

**Impact:** feeding a malicious coverage JSON to `zig_coverage_map`/`zig_coverage_diff`/`zig_coverage_merge` crashes the server.

**Fix:** saturating math (`*|`, `+|`) or `std.math.mul`/`std.math.add` returning an error in `rateBp`/`appendFile`.

---

### 4. MEDIUM — VERIFIED — `read_only=true` may coexist with execution capabilities (source-of-truth field lies)

**File:** `src/manifest/aggregate.zig:81` — `validateDefinition` guards only the `writes_source` case:

```zig
if (definition.risk.writes_source and definition.read_only) {
    @compileError(name ++ ": source-writing tools cannot be read-only");
}
```

Nothing forbids `read_only=true` with `executes_project_code` / `executes_user_command` / `writes_artifacts` / `mutates_lsp_state`. Real instances: `zig_matrix_check` (`ci.zig:31`) and `zig_profile_run` (`profiling.zig:25`) both declare `.read_only = true` alongside `executes_user_command=true`.

The external `readOnlyHintFor` *derives* the correct `false` (`mod.zig:150-157`, which ANDs in `!executes_user_command` etc.), so the **MCP surface is safe** — but the raw `meta.read_only` field is internally contradictory.

**Impact:** a future consumer reading `.read_only` directly (not via the hint) sees a command-runner as read-only.

**Fix:** extend the comptime guard to reject `read_only` combined with any execution / artifact / LSP-mutation capability, and flip those declarations to `read_only=false` (matching the diagnostics/performance files, which correctly use `read_only=false`).

---

### 5. LOW — VERIFIED — `idempotentHintFor` is dead logic (always equals `readOnlyHintFor`)

**File:** `src/manifest/mod.zig:161`

```zig
pub fn idempotentHintFor(spec: ToolMeta) bool {
    const risk_value = riskFor(spec.id);
    return readOnlyHintFor(spec) and !risk_value.writes_source and ... and !risk_value.executes_user_command;
}
```

`readOnlyHintFor` already requires all five `!`-flags, so the extra conjunction can never change the result → `idempotent ≡ readOnly` for every tool.

**Impact:** the `idempotentHint` annotation carries no information distinct from `readOnlyHint`; a read-only-but-non-idempotent op cannot be expressed.

**Fix:** delete the duplication, or make idempotency meaningful (e.g. distinguish on `executes_backend`).

---

### 6. LOW — VERIFIED — `fieldInEntry` uses substring search, not a token-aware scan

**File:** `src/domain/zig/zon_dependencies.zig:276`

```zig
fn fieldInEntry(_: []const u8, entry_start: usize, entry_text: []const u8, field_name: []const u8) ?Field {
    const field_idx = std.mem.indexOf(u8, entry_text, field_name) orelse return null; // ".url"/".hash"/".path"
    var cursor = field_idx + field_name.len;
    cursor = skipHorizontal(entry_text, cursor, entry_text.len);
    if (cursor >= entry_text.len or entry_text[cursor] != '=') return null;
```

A dependency entry containing the literal text `.url = "` / `.hash = "` inside a comment or another value (e.g. a `// see .url = "..."` line) matches the wrong occurrence; a subsequent `replaceHash`/upgrade then splices into the wrong span and corrupts the manifest. Offsets stay in-bounds (`scanStringEnd` is loop-guarded), so **no panic** — pure correctness.

**Fix:** scan for the field as a token at brace-depth 1, skipping over string literals and comments.

---

### 7. LOW — VERIFIED — comptime apply-gate checks a flag, not the schema

**File:** `src/manifest/aggregate.zig:75`

```zig
if (definition.risk.writes_source and !definition.risk.writes_require_apply) {
    @compileError(name ++ ": source-writing tools must require apply=true");
}
```

The guard asserts the `writes_require_apply` bool but never verifies the `input_schema` actually contains an `apply` boolean field. All current defs include `apply`, so this is latent.

**Related, also latent:** `writes_artifacts` has no symmetric `⇒ apply-gate` guard (`aggregate.zig:84-101` only checks the reverse: `workspace_artifact` plan ⇒ `writes_artifacts`). An artifact-writing `dynamic_command` tool could therefore ship un-gated. INFERRED-by-design: `zig_matrix_check` already does exactly this (`writes_artifacts=true`, `dynamic_command`, no apply gate), which may be intentional for build/test side-effects.

**Fix:** when `writes_require_apply`, comptime-scan `definition.input_schema.fields` for an `apply` entry and `@compileError` if absent. Decide and document whether `writes_artifacts` must always be apply-gated.

---

### 8. LOW — VERIFIED — Empty path flags accepted, deferred spawn failure

**File:** `src/bootstrap/config.zig:76`

`--audit-log` rejects empty values (`config.zig:96-99`) but `--zig-path` / `--zls-path` / `--workspace` / etc. via `replaceOwned` → `dupeNext` do not. `--zig-path ""` stores an empty `argv[0]` that fails obscurely at first tool use rather than at startup. Operator-controlled (not a sandbox boundary), hence Low.

**Fix:** reject empty values for path-like flags in `dupeNext` or a dedicated validator, mirroring the `--audit-log` empty check.

---

## Subagent claims that could NOT be confirmed (refuted / out of scope)

- **REFUTED — `coverage_model.zig:194` `floatToInt` boundary panic** (a subagent rated this VERIFIED/Low).

  ```zig
  fn floatToInt(value: f64) ?i64 {
      if (!std.math.isFinite(value)) return null;
      const max: f64 = @floatFromInt(std.math.maxInt(i64));
      const min: f64 = @floatFromInt(std.math.minInt(i64));
      if (value >= max or value < min) return null;
      return @intFromFloat(value);
  }
  ```

  `max = @floatFromInt(maxInt(i64))` rounds to exactly `2^63`; the guard `if (value >= max) return null` rejects everything `≥ 2^63`. The largest representable `f64` strictly below `2^63` is `2^63 − 1024`, whose `@intFromFloat` is `9223372036854774784 ≤ maxInt(i64)`. The claimed `[2^63−512, 2^63)` window contains **no representable float**, so there is no out-of-range cast. This code is **safe**.

- **INFERRED / out-of-session-scope — `zig fetch` argv injection** at `src/app/usecases/dependencies/workflows.zig:64`: a subagent flagged that a dependency `url` reaches `zig fetch <url>` argv without the `requireSafeStringLiteralField` check (a leading-`-` could be parsed as a flag — argument injection, not command injection, since no shell is involved). This is outside this session's file scope (usecases) and was **not verified**. Flagged for the usecases reviewer.

---

## Verified-safe areas (high confidence, with evidence)

- **ZON injection is CLOSED** (was listed as known-open at `zon_dependencies.zig:193`). `requireSafeStringLiteralField` (`zon_dependencies.zig:369-373`) rejects `< 0x20`, `0x7f`, `"`, and `\` — exactly the `.zon` string break-out chars — and `requireSafeDependencyName` (`:361-367`) restricts names to `[A-Za-z_][A-Za-z0-9_]*`, both applied **before** interpolation (`:190-201`).
  > **Recommend updating the known-issues tracker: reclassify this item as fixed.**
- **`main.zig` is a thin entrypoint** — `src/main.zig:8-11` only calls `bootstrap_runtime.run` and maps the exit code. AGENTS.md-compliant.
- **Workspace root cannot be empty/`.`** — config defaults it to canonical cwd via `currentPath` (`config.zig:62-65`) before `Workspace.init` realpaths it.
- **Parsers tolerate malformed input** — `compiler_output` line/col use `lastIndexOfScalar` + `parseInt(i64, …) catch`; `stacktrace`/`crash` derive every slice bound from a matched `indexOf` and guard `idx > 0`; `findMatchingBrace` cannot underflow `depth`; `patch_session.unifiedDiff` prefix/suffix math is `@min`-clamped. (Subagent-fuzzed + spot-verified.)
- **`evidence.zig` / `trust.zig` JSON** is emitted via `std.json.Stringify`, which escapes untrusted strings — not a JSON-injection vector. No stdout writes anywhere in the domain layer (stderr-only); stdout discipline holds.
- **`flamegraph.zig` has no folded-stack parser** (corrects the review brief's hunt assumption) — it only builds argv and sniffs SVG, so the "sample-count overflow" concern is moot here.
- **Bootstrap teardown is clean** — no double-free on ZLS teardown (`State.deinit` resets pointers only; process/client are owned by longer-lived stack optionals), no leak on the audit-init error path (`errdefer file.close` before `dupe`), correctly-ordered `errdefer`s in `ownedDefaults`, and `StartupTimeline` is bounded (`< self.phases.len`). Optional ZLS absence is a real `?` consumed via `orelse error.Unavailable`, not a `.?`.
- **Catalog ↔ definition consistency** (INFERRED from subagent): `tool_catalog.json` stores no per-tool risk/group/read_only — those are generated from the `.zig` manifest by `tool_catalog_render.zig`, so drift is structurally impossible; `ToolId` is exhaustive and 1:1 with entries.

---

## Test-coverage gaps

1. **No test asserts the hint trio is non-contradictory per tool** — `invariants_tests.zig` never checks `readOnlyHintFor ⇒ !destructiveHintFor`, `executes_user_command ⇒ destructiveHintFor` (Findings 1/2), or `read_only` incompatible with execution flags (Finding 4).
2. **No coverage-parser overflow/accumulation test** (Finding 3) — `coverage_model_tests.zig` covers `1e308`/NaN but not the `covered*10000` or `+=` overflow.
3. **No adversarial ZON/manifest tests** — truncated/unbalanced `.zon`, and the `fieldInEntry` wrong-match case (Finding 6) are uncovered; `zon_dependencies_tests.zig` only exercises well-formed input.
4. **No bootstrap partial-init / null-port test** — nothing fails `zls_session.start` mid-way to assert slots null out, and no config test for empty path values (Finding 8) or relative-workspace resolution.

---

## Summary

| # | Severity | Status | Location | Issue |
|---|----------|--------|----------|-------|
| 1 | HIGH | VERIFIED | `manifest/mod.zig:172` | 15 command-execution tools advertise `destructiveHint=false` |
| 2 | MEDIUM | VERIFIED | `manifest/invariants_tests.zig:35` | Destructive invariant test reproduces Finding 1 |
| 3 | MEDIUM | VERIFIED | `domain/performance/coverage_model.zig:54` | Coverage int overflow → ReleaseSafe panic (DoS) |
| 4 | MEDIUM | VERIFIED | `manifest/aggregate.zig:81` | `read_only=true` coexists with execution caps |
| 5 | LOW | VERIFIED | `manifest/mod.zig:161` | `idempotentHintFor` is dead logic |
| 6 | LOW | VERIFIED | `domain/zig/zon_dependencies.zig:276` | `fieldInEntry` substring match can splice wrong span |
| 7 | LOW | VERIFIED | `manifest/aggregate.zig:75` | Apply-gate checks flag, not schema (latent) |
| 8 | LOW | VERIFIED | `bootstrap/config.zig:76` | Empty path flags accepted → deferred spawn failure |

One HIGH (trust-annotation) issue worth fixing before release, a handful of Medium/Low correctness items, and good defensive hygiene elsewhere. The ZON-injection known-open should be reclassified as fixed.
