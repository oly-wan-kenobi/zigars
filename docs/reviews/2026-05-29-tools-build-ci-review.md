# Code Review — `tools/` + build & CI supply-chain

- **Date:** 2026-05-29
- **Scope:** `tools/release/*`, `tools/quality/architecture_guard.zig`, `tools/zigars_tools.zig`, `tools/fuzz_test_runner.zig`, `tools/common/*`, `tools/integration/*`, `build.zig`, `build.zig.zon`, `.github/workflows/*`, `.github/scripts/*`
- **Repo:** zigars — deterministic Zig 0.16 MCP server (built/run in ReleaseSafe)

## Method

Four parallel subagents reviewed non-overlapping file clusters; every load-bearing claim was then re-read against source by the lead reviewer.

- **VERIFIED** = the exact code was read and the logic traced.
- **INFERRED / relayed** = subagent claim not independently line-verified (called out as such).

The two architecture-guard findings were down-ranked from the subagent's CRITICAL to **HIGH**: they defeat the guard's purpose but are CI/maintainability soundness holes, not security/runtime/data-loss — no untrusted-input path reaches them.

### Invariants held the code against

1. Workspace sandbox: every user-provided path must resolve under the configured workspace before read/write.
2. Source-mutating MCP tools must require `apply=true`.
3. stdout reserved for MCP JSON-RPC; diagnostics/logs to stderr.
4. MCP results structured (JSON `structuredContent` + text fallback).
5. The shipped source tree is pure Zig (no `.py` scripts).

---

## Findings (ranked)

### HIGH-1 — Architecture guard: `build.zig` named-module imports bypass every import wall (VERIFIED)

The guard scans only `src/`:

```zig
// tools/quality/architecture_guard.zig:214
var dir = Io.Dir.cwd().openDir(io, "src", .{ .iterate = true }) catch |err| switch (err) {
```

and `normalizeImport` returns any non-`.zig` import target **unchanged**:

```zig
// tools/quality/architecture_guard.zig:471
if (!std.mem.endsWith(u8, raw_import, ".zig")) return allocator.dupe(u8, raw_import);
```

Every forbidden-import predicate matches on `src/…` prefixes or the **single** hardcoded bare name `"mcp"`:

```zig
// tools/quality/architecture_guard.zig:644-646, :701-706
fn isMcpImport(path: []const u8) bool { return std.mem.eql(u8, path, "mcp"); }
fn infraMcpForbiddenImport(path: []const u8) bool {
    return isMcpImport(path) or std.mem.startsWith(u8, path, "src/adapters/") or ...
```

Named modules are the project's **normal** wiring mechanism — `build.zig:281` already does `zigars_mod.addImport("cancellation", … "src/domain/cancellation.zig")`:

```zig
// build.zig:280-285
zigars_mod.addImport("mcp", mcp_mod);
zigars_mod.addImport("cancellation", b.createModule(.{
    .root_source_file = b.path("src/domain/cancellation.zig"),
    .target = target,
    .optimize = optimize,
}));
```

So a developer who adds `infra_mod.addImport("render", b.path("src/adapters/mcp/server.zig"))` (in `build.zig`, which the guard never reads) and writes `const render = @import("render");` in an infra file introduces a real `infra → adapters/mcp` edge that `infra_no_mcp` intends to forbid — but `normalized == "render"` matches no predicate, so it **passes silently**. The authors clearly anticipated this for `"mcp"` and stopped there.

- **Impact:** the entire layering wall is defeatable through the project's standard import idiom; architecture erodes without CI noticing.
- **Fix:** parse `addImport(name, b.path("…"))` pairs out of `build.zig`, build a name→path map, resolve bare module names through it before applying predicates, and deny *unknown* bare names in deny-by-default layers.

### HIGH-2 — Architecture guard: one crafted line latches a whole file into "test mode," disabling all downstream checks (VERIFIED)

`test_tail_active` is set but **never cleared**:

```zig
// tools/quality/architecture_guard.zig:252, :258, :266
var test_tail_active = false;
...
line_scan.is_test_file = scan.is_test_file or test_tail_active or test_depth > 0 or enters_test_block or starts_test_tail;
...
if (starts_test_tail or enters_test_block) test_tail_active = true;
```

and the arming heuristic fires on any `const … @import(… "testing/" …)` line:

```zig
// tools/quality/architecture_guard.zig:582-584
return std.mem.startsWith(u8, trimmed, "const ") and
    std.mem.indexOf(u8, trimmed, import_prefix) != null and
    std.mem.indexOf(u8, trimmed, "testing/") != null;
```

Because `is_test_file` is computed *before* the import check, the arming line **also exempts itself** from `no_production_testing_import` (which requires `!scan.is_test_file`, :311). So a single line `const _t = @import("../../testing/fakes/root.zig");` at the top of a production infra file (a) escapes the testing-import wall on its own line and (b) flips every subsequent line to test-exempt — `checkImport`, `checkEffectTokensInLine` (:398), and `checkMcpResultBoundaryInLine` (:386) all early-return on `is_test_file`.

- **Impact:** a one-line "disable the guard for this file" primitive; also a realistic *accidental* footgun (moving a testing import to the top silently unguards the rest).
- **Fix:** the loop already tracks real `test_depth` — scope test-context to brace depth (`test_depth > 0`) and drop the irreversible latch, or reset it when `test_depth` returns to 0. Don't treat a heuristic import line as equivalent to a `test {` block.

### MEDIUM-3 → LOW (adjudicated) — The "pure Zig / no-.py" release gate can pass while its stated property is violated (VERIFIED)

> **Adjudication (S14):** downgraded MEDIUM → **LOW**. The gate is *correctly
> scoped*: `docs/release.md` and `AGENTS.md` both limit the pure-Zig roots to
> `.github, docs, examples, scripts, src, tests, tools`, and the npm `packages/`
> tree is JS/TS by design (intentionally excluded). This is documentation/false-
> assurance hardening, not a security hole — no `.py` is tracked. **Resolved in
> S14:** the gate's rejection message was tightened so it can no longer be read
> as covering `packages/`; AGENTS.md and `docs/release.md` were scoped to the
> `.py`-extension behavior the gate actually enforces; and a negative-path test
> (`tools/release/release_checks.zig`, "pure-Zig tree gate rejects a planted .py
> and passes when absent") now plants a `.py` under a scoped root and asserts the
> gate fails. The "derive roots from tracked top-level dirs" and ".sh heredoc
> token scan" suggestions below are deliberately *not* adopted — the hand list is
> the intended policy surface and the inline CI Python is vetted (see LOW-10).

The gate walks a hand-maintained root list and matches only the `.py` *extension*:

```zig
// tools/release/release_rules.zig:555-563  — note: no "packages"
pub const pure_zig_roots = [_][]const u8{ ".github", "docs", "examples", "scripts", "src", "tests", "tools" };
```

```zig
// tools/release/release_checks.zig:417, :426-428
error.FileNotFound => return true,            // missing root = silent pass
...
if (!std.mem.endsWith(u8, entry.path, extension)) continue;
try stderrPrint(io, "pure Zig hygiene rejected ... Python files do not belong in project-owned source, tools, tests, scripts, examples, docs, or CI\n", ...);
```

Two false-negative holes:

- **Scope drift:** `packages/` is tracked, project-owned source (`git ls-files packages` → `src/*.ts`, `dist/*.js`, …) but is **not** in `pure_zig_roots`, so a `packages/**/foo.py` ships undetected. The error message itself claims to guard "project-owned source." (`scripts` is in the list but no top-level `scripts/` dir exists → `FileNotFound → true`, a dead no-op — the list has drifted in both directions.)
- **Extension-only match:** `.github` *is* scanned, yet the real Python lives in `.sh` heredocs (`backend-conformance.sh:130 python3 <<'PY'`, etc.). AGENTS.md:44 says "Do not add Python helper scripts under … CI paths," so the gate reports OK while that stated invariant is violable.

No `.py` is tracked today, so nothing is currently broken — the defect is **false assurance**: the gate cannot enforce the property it advertises.

- **Fix:** derive roots from tracked top-level dirs (minus a binary/`node_modules`/`dist` denylist) rather than a hand list; and either scan `.sh`/text for `python`/`python3` invocation tokens or narrow the gate's message + AGENTS.md to the scope actually enforced. Add a negative-path test that plants `packages/x.py` and asserts failure.

### MEDIUM-4 — Smoke suite never asserts `isError`; success-vs-error envelope flips are invisible (VERIFIED)

The server emits tool failures as `result` with `isError:true` + a structured error payload. Both harness extractors read only `structuredContent`/text and **ignore the sibling flag**:

```zig
// tools/integration/smoke_support.zig:45-50
const result = parsed.value.object.get("result").?.object;
if (result.get("structuredContent")) |structured| { return jsonStringifyAlloc(...); }
const text = result.get("content").?.array.items[0].object.get("text").?.string;
```

`grep isError tools/integration tools/common` → **none**. A regression that flips `isError` (error marked success, or vice-versa) passes every smoke/fixture test, since the structured `kind` payload is unchanged.

- **Fix:** return `isError` from `callTool`/`callHttpToolJson` and assert it on the error-path fixtures (`argument_error` ⇒ `isError==true`; ordinary results ⇒ `false`).

### MEDIUM-5 — HTTP apply-gating is never checked against the filesystem (VERIFIED)

`http_transactional_editing_smoke.zig` sends `apply:true` against a blocked path and asserts only the self-reported `applied:false`. The HTTP server's workspace is the repo root (`http_smoke.zig:20 workspace = "."`), and `grep readFile|expectFileContains tools/integration/http` → **none**. Only stdio verifies writes against disk:

```zig
// tools/integration/stdio/stdio_transactional_editing_fixtures.zig:36, :49, :112
try expectFileContains(client, workspace, "src/main.zig", "const x = 3;");
...
const bytes = try cli_io.readFileAlloc(client.allocator, client.io, path, 1024 * 1024);
```

- **Impact:** a regression where a sandbox-blocked or `apply=false` write actually hits disk while still reporting `applied:false` passes every HTTP fixture. The "apply=false ⇒ no write" invariant is verified for `zig_format` on stdio only (`stdio_fixtures.zig:314`) — never on HTTP, never for the cache/generated/blocked path classes.
- **Fix:** after the blocked-apply call, assert the target file does not exist on disk; mirror stdio's negative `expectFileContains` on HTTP.

### MEDIUM-6 — Architecture guard coverage gaps: no cycle detection, no `adapter_other` wall, unclassified dirs unguarded (VERIFIED)

- **No dependency-cycle detection of any kind** — the guard is purely per-line/per-file; nothing accumulates an import graph, so `A→B→C→A` is undetectable. (The review premise assumed cycle detection exists; it does not.)
- `src/adapters/` (non-mcp, e.g. CLI) classifies as `.adapter_other` (:530), is a target layer (:540), but `checkImport`'s switch has **no `.adapter_other` arm** (`else => {}`, :345) → no import wall; a CLI adapter may import `src/infra/**` or `src/adapters/mcp/**` freely.
- Any `src/` file not matching the 8 known prefixes is `.other` (:535) → `isTargetLayer` false → exempt from import walls, effect tokens, and retired-surface checks. A new `src/util/` directory is silently unguarded.

```zig
// tools/quality/architecture_guard.zig:530, :345
if (std.mem.startsWith(u8, path, "src/adapters/")) return .adapter_other;
...
else => {},   // .adapter_other falls through here — no import wall
```

- **Fix:** add an `.adapter_other` import wall + cross-adapter isolation; fail-closed on unclassified `src/` dirs (warn on `.other`); add an import-graph cycle check.

### LOW-7 — Architecture guard flags inert multiline-string / comment content as violations (VERIFIED)

Only `checkImportsInLine` skips multiline strings (:290); `checkMcpResultBoundaryInLine` (:386) and `checkEffectTokensInLine` (:397-398) do not, and `withoutLineComment` (:569-571) truncates at the first `//` with no string-awareness:

```zig
// tools/quality/architecture_guard.zig:569-571
fn withoutLineComment(line: []const u8) []const u8 {
    const comment = std.mem.indexOf(u8, line, "//") orelse return line;
    return line[0..comment];
}
```

A domain/app doc line `\\ … mcp.tools.ToolResult …` or `\\ … std.process. …` produces a **false CI failure**.

- **Fix:** apply the `isMultilineStringLiteralLine` skip in the effect/ToolResult checks; strip comments with string-literal awareness.

### LOW-8 — HTTP smoke helpers panic instead of failing cleanly (VERIFIED)

`smoke_support.zig:45` `…get("result").?.object` has no error-envelope guard, while the stdio client *does*:

```zig
// tools/integration/stdio/stdio_fixtures.zig:446
if (parsed.value.object.get("error")) |_| return error.McpError;
```

And `smoke_support.zig:49`'s `.?` chain panics if `content`/`text` is absent. A JSON-RPC `error` or a malformed result crashes opaquely rather than reporting a diagnosable assertion.

- **Fix:** mirror the stdio `error` guard; replace `.?` with `orelse return error.AssertionFailed`.

### LOW-9 — Non-deterministic smoke port (VERIFIED)

```zig
// tools/integration/smoke_support.zig:15-19
pub fn pickPort(io: Io) u16 {
    const ns = nowNs(io);
    const positive: u128 = @intCast(if (ns < 0) -ns else ns);
    return @intCast(41000 + (positive % 8000));
}
```

Wall-clock-derived port contradicts the project's determinism goal; concurrent runs or a lingering socket can flake.

- **Fix:** bind port 0 and read back the assignment, or retry on `AddrInUse`.

### LOW-10 — Policy/enforcement drift: Python in CI vs. AGENTS.md "pure Zig" (VERIFIED, RESOLVED S14)

> **Resolution (S14):** reworded AGENTS.md to scope the Python ban to the
> shipped Zig tree (the `.py`-extension gate), explicitly acknowledging the
> vetted inline Python inside `.github/scripts/*.sh` conformance heredocs as
> CI-only embedded scripting rather than a shipped `.py` file. `docs/release.md`
> carries the matching scope note. The inline Python was not ported to Zig (it is
> safe: quoted heredocs, env-passed data, list-argv `subprocess`).

`.github/scripts/*` embed substantial inline Python via `python3 <<'PY'`, directly contradicting AGENTS.md:44 ("no Python … under … CI paths"):

```
.github/scripts/backend-conformance.sh:130:python3 <<'PY'
.github/scripts/real-zls-conformance.sh:101:python3 <<'PY'
.github/scripts/release-readiness.sh:75:python3 <<'PY'
.github/scripts/backend-conformance-contract-smoke.sh:191:REPORT_DIR="$report_dir" python3 <<'PY'
```

The usage itself is **safe** (all heredocs quoted, data passed via `env:`/`os.environ`, list-argv `subprocess`, no `${{ github.event }}` in shell). This is a docs-vs-enforcement reconciliation item, not a security hole.

- **Fix:** reword AGENTS.md to scope the ban to the shipped Zig tree (matching the gate's real behavior), or port the inline Python to Zig.

### LOW-11 — `workflow_dispatch` input interpolated into `run:` (VERIFIED, ACCEPTED RISK, documented S14)

> **Resolution (S14):** accepted risk, left as-is by decision. Each of the three
> `Optional … setup` steps (`release-readiness.yml`, `backend-conformance.yml`,
> `zls-conformance.yml`) now carries an inline comment recording the accepted
> risk (manual dispatch only, write-access actors, `contents: read`), and
> `docs/release.md` documents the decision. The `env:` + vetted-script
> alternative was considered but not adopted.

```yaml
# .github/workflows/release-readiness.yml:59-60
#   (also backend-conformance.yml:47-48, zls-conformance.yml:35-36)
        if: ${{ inputs.setup_command != '' }}
        run: ${{ inputs.setup_command }}
```

Arbitrary command execution by design, but only via manual `workflow_dispatch` (write-access actors) under a `contents: read` token. Bounded. Cleaner to pass via `env:` and invoke a vetted script.

### Informational — committed build outputs (CONFIRMED INTENTIONAL, documented S14)

`packages/@zigars/mcp/dist/*.js` (compiled TypeScript build outputs) are tracked in git — worth confirming that's intentional given AGENTS.md's "do not commit build outputs" guidance.

> **Resolution (S14):** confirmed **intentional**. The npm shim must run via
> `npx`/`bunx` without a TypeScript build step, so the prebuilt JS is committed.
> `packages/@zigars/mcp/.gitignore` keeps `node_modules/` and `dist/test/`
> untracked while deliberately tracking the runtime `dist/` output, and the
> `artifact-hygiene` tracked-artifact gate only covers the top-level generated
> dirs (so it does not flag the package `dist/`). Documented as an explicit
> exception in both AGENTS.md ("Generated And Artifact Hygiene") and
> `docs/release.md`.

---

## Verified-safe (independently re-confirmed)

- **dist release-set is pinned, not just counted (fail-closed):** a `seen[]` bitmap + `indexByPackageName` (rejects unknown) + `exe_name` equality (rejects swaps) on top of the cardinality check — you **cannot** ship the wrong 8 packages.

  ```zig
  // tools/release/dist.zig:99-114
  var seen = [_]bool{false} ** release_targets.all.len;
  for (packages) |package| {
      const index = release_targets.indexByPackageName(package.name) orelse { ... return error.InvalidArguments; };
      if (seen[index]) { ... return error.InvalidArguments; }
      const expected = release_targets.all[index];
      if (!std.mem.eql(u8, package.exe_name, expected.exe_name)) { ... return error.InvalidArguments; }
      seen[index] = true;
  }
  ```

- **Dispatcher has no injection surface:** `zigars_tools.zig:100-147` is an `eql` chain dispatching **in-process** to imported Zig modules (no `Child`/`spawn`/`exec`); unknown command → `usage` + `error.InvalidArguments` (:144-147).
- **CI action pinning:** every `uses:` across all 5 workflows is a 40-char commit SHA (checkout, setup-zig, upload-artifact, attest-build-provenance, action-gh-release) — no mutable tags.
- **No `pull_request_target`** anywhere; write/`id-token` scopes confined to the tag-triggered `release.yml`; the only `github.event` use is a boolean `if:` (`release.yml:50 ${{ !github.event.repository.private }}`), not shell interpolation.
- **All script heredocs use quoted `<<'PY'`** (no shell expansion into Python bodies).
- **stdio harness is the gold standard:** verifies writes against disk (`stdio_fixtures.zig:298/:312/:320`, transactional `:36/:49`) and guards the JSON-RPC error envelope (`stdio_fixtures.zig:446`).

## Relayed but NOT independently re-verified (treat as INFERRED)

- Checksum gate recomputes SHA-256 content (`dist.zig:287-312`); backend-contract-scenario drift fails-closed (`backend_contract_scenarios.zig:41-63`); native-archive stdout-empty/stderr-banner assertion (`dist.zig:345-371` — the tar-listing gate at :320-338 was confirmed, but not the stdout-empty assert itself).
- `fuzz_test_runner.zig` is the verbatim upstream Zig stdlib runner that `exit(1)`s on failure (does not swallow crashes).
- `setup-real-backends.sh` / `install-kcov.sh` SHA-256-verify all downloads (no `curl|sh`); `build.zig.zon` pins its one dep by hash.

## Test-coverage gaps

1. **No negative-path test for the pure-Zig gate** — nothing plants a `.py` (esp. under `packages/`) and asserts failure; would have caught MEDIUM-3.
2. **`isError` flag** — asserted by zero integration fixtures (MEDIUM-4).
3. **HTTP filesystem effects** — apply-gating/sandbox-escape never confirmed against disk on HTTP (MEDIUM-5).
4. **Sandbox-escape rejection** — no fixture sends `../../etc/passwd` or an out-of-workspace absolute path and asserts rejection; path-safety is only described in a text field, never exercised.
5. **Architecture-guard self-tests** — no test demonstrates the guard *catches* a build.zig-aliased forbidden import or a test-tail-latched violation (HIGH-1/HIGH-2 would be caught by such tests).

---

## Bottom line

The gate that *lies* is the **architecture guard** (defeatable via the project's normal named-module idiom, and via a one-line test-tail latch). The **pure-Zig/no-.py gate** was adjudicated **LOW**: it is correctly scoped to the seven pure-Zig roots (npm `packages/` is JS/TS by design), and S14 tightened its message, scoped the docs to the enforced behavior, and added a negative-path test — so the false-assurance gap is closed. The packaging, checksum, dispatch, and CI-pinning surfaces are genuinely fail-closed.
