# Code Review — App Use-Cases A (validation + static analysis)

- **Date:** 2026-05-29
- **Reviewer:** senior Zig/MCP systems engineer (multi-agent, evidence-based)
- **Build target:** Zig 0.16, ReleaseSafe (safety checks active — out-of-range `@intCast`/`@intFromFloat`, OOB index, `unreachable`, failed `assert`, and usize underflow all **panic**, crashing the serial MCP transport = DoS).
- **Scope (10 files, ~13.8k lines):**
  - `src/app/usecases/validation/project_intelligence.zig` (2937)
  - `src/app/usecases/static_analysis/lint_intelligence.zig` (1835) + `project_values.zig` (1673)
  - `src/app/usecases/static_analysis/agent_ergonomics.zig` (1157) + `semantic_index.zig` (827) + `layout_probes.zig` (798)
  - `src/app/usecases/usecase_support.zig` (1523) + `validation/workflows.zig` (2113)
  - `src/domain/zig/analysis.zig` (656) + `static_analysis_contracts.zig` (318)
- **Method:** 5 parallel subagents (non-overlapping scopes), every claim re-verified against source by the lead. Findings split into VERIFIED (lead read the exact code) vs INFERRED (relied on subagent excerpt, not re-read).

---

## Framing (verified — reshapes severity of the whole surface)

1. **No shell anywhere.** `src/infra/process/command.zig:89` spawns a direct argv array via `std.process.spawn(io, .{ .argv = spawn_argv, .cwd = ... })` — never `/bin/sh -c`. So **nothing on this surface is command injection**; the worst a user string can do is inject *additional flags to a fixed binary* (`zig`/`zls`/`git`).
2. **The workspace port self-sandboxes.** Every `WorkspaceStore` op — `read`/`write`/`resolve`/`delete`/`exists`/`ensure_dir`/`scan_directory` — funnels the raw `request.path` through `workspace.resolve`/`resolveOutput` → `resolveInsideRoot`/`resolveOutputInsideRoot` (`src/infra/workspace/filesystem.zig:76-108`, `src/infra/workspace/workspace.zig:50-152`), which reject `..`, absolute, and symlink escapes **before** any disk access.

**Consequence:** a raw user path handed to the port is safe; a raw user path handed to a **subprocess argv** is not. The codebase resolves paths meticulously before port I/O, but **three subprocess-argv construction sites forward raw, unresolved user input**, escaping the sandbox the rest of the code maintains. Those are the real findings.

**No Critical or High findings.** The three Medium findings are one theme; everything else is Low.

---

## Findings (ranked)

### 1. `publicApiBaseline` runs `git show <ref>:<file>` with raw, unresolved user paths — discloses repo content outside the workspace
- **Severity: Medium** · **VERIFIED** · `src/app/usecases/static_analysis/project_values.zig:1577-1586`

```zig
const spec = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ baseline_ref, rel });
const result = runner.run(allocator, .{
    .argv = &.{ "git", "show", spec },
    .cwd = context.workspace.root,
    .timeout_ms = 5000,
    .provenance = "static_analysis.public_api_diff.baseline",
}) catch return "";
...
return allocator.dupe(u8, result.stdout);   // returned as the diff "before" content
```

Its sibling `publicApiCurrent` (`project_values.zig:1592-1596`) reads the same `file` through the sandboxed `workspace_store.read`. The baseline path bypasses it entirely.

- **Impact:** `file` and `baseline_ref` are caller-controlled tool args. `git show <ref>:<path>` resolves `path` against the git repo tree (or cwd for `./`/`../`-prefixed paths). When the configured workspace is a **subdirectory of a larger git repo**, a caller can read the full text of *any blob tracked anywhere in that repo* — including files outside the workspace boundary — and exfiltrate it via the returned `before`/diff body. This is the one finding that discloses file **content** (not just an oracle), so fix it first. Bounded to git-tracked objects; not arbitrary FS read. Not arg-injection (`spec` is a single token); not shell.
- **Fix:** Resolve `file` via `context.workspace_store.resolve(allocator, .{ .path = file, .provenance = "...baseline" })`, convert to a workspace-relative path (as `workspaceRelative`/`fileOwnerForPathValue` already do), reject anything that resolves outside root, and use that relative path in `spec`. Optionally validate `baseline_ref` against a revision charset.

### 2. `zig fmt --check` runs a raw, unresolved user path — every sibling branch resolves it
- **Severity: Medium** · **VERIFIED** · `src/app/usecases/validation/project_intelligence.zig:1737-1740`

```zig
} else if (std.mem.eql(u8, command_name, "fmt-check")) {
    try appendOwnedArg(allocator, &list, "fmt");
    try appendOwnedArg(allocator, &list, "--check");
    if (file) |file_value| try appendOwnedArg(allocator, &list, file_value) else try appendOwnedArg(allocator, &list, "src");
}
```

Compare the `check` (1731-1736) and `test` (1744-1749) branches in the same function, which both route `file` through `context.workspace_store.resolve(...)` and append the **resolved** path. `fmt-check` appends the raw value with no resolve and no existence probe.

- **Impact:** Reachable from `zigars_failure_fusion`, `zig_build_events`, `zig_test_events` (all advertise `command="fmt-check"` + a free-string `file`). `file="../../../../etc/hosts"` yields `zig fmt --check ../../../../etc/hosts` with `cwd=workspace.root`, escaping the realpath boundary the tool advertises as enforced. `zig fmt --check` is read-only and prints filenames/parse status, not contents — so this is an existence + "is-valid-Zig" oracle for arbitrary paths, not content disclosure. Still a clear sandbox-boundary violation and inconsistent with every other path-bearing command.
- **Fix:** Resolve like the siblings, preserving the `src` default:

```zig
if (file) |file_value| {
    const resolved = try context.workspace_store.resolve(allocator, .{ .path = file_value, .provenance = "project_intelligence.command_arg" });
    defer resolved.deinit(allocator);
    try appendOwnedArg(allocator, &list, resolved.path);
} else try appendOwnedArg(allocator, &list, "src");
```

### 3. `args`/`command` passthrough injects workspace-escaping flags into `zig build`/`zig test`
- **Severity: Medium** (reconciling subagent disagreement: scope-1 rated "Low/by-design", scope-4 rated "High") · **VERIFIED** · splitter `src/app/usecases/usecase_support.zig:533-590`; sink `src/app/usecases/validation/project_intelligence.zig:1755`

```zig
// project_intelligence.zig:1755 — user tokens appended after the zig subcommand, no "--" guard
for (extra_args) |arg| try appendOwnedArg(allocator, &list, arg);
```

`extra_args` comes from `splitToolArgs(argString(args,"args"))` (adapter `project_intelligence.zig:48,148`). The `--` end-of-options separator **is** inserted for the heaptrack/afl/samply wrappers (`diagnostics/workflows.zig:231,352`; `performance/workflows.zig:1215`) but **not** for the `zig build`/`zig test` `extra_args` path — so the inconsistency is real, not intentional.

- **Impact:** Because there is no shell (framing #1), this is flag injection, not command injection. But appending unfiltered tokens to `zig build` lets a caller pass `--build-file <path>` (execute a `build.zig` outside the workspace), `--prefix`/`--cache-dir`/`--global-cache-dir`/`--zig-lib-dir <path>` (write build outputs outside the workspace), or `-femit-bin=<path>`. That escapes the write/exec boundary the rest of the server enforces. Rated **Medium, not High**: it is bounded to flags of a fixed binary, these tools already execute the project's own `build.zig` by design (`executes_project_code`), and the realistic harm is output/exec **redirection** rather than RCE-from-nothing. It is more than Low because it is a genuine boundary escape and the careful `--`-guarding elsewhere shows confinement is the intent.
- **Fix:** Do **not** blindly insert `--` on the build path (`zig build --` has special "args to run step" semantics). Instead deny-list path-bearing build-system flags (`--build-file`, `--prefix`, `--cache-dir`, `--global-cache-dir`, `--zig-lib-dir`, `-femit-*`) in the passthrough, or resolve their operands through the workspace store. For `zig test`, inserting `--` before user tokens is safe and sufficient.

### 4. `plan()` embeds raw changed-paths in `zig fmt`/`ast-check` argv (probe-gated)
- **Severity: Low** · **VERIFIED** · `src/app/usecases/validation/workflows.zig:455-461`

```zig
for (request.changed_paths) |path| {
    if (!std.mem.endsWith(u8, path, ".zig")) continue;
    if (!workspacePathExists(allocator, context, path)) continue;   // sandboxed exists() probe
    try appendPhase(allocator, &phases, .{ .id = "format_check", .kind = .command,
        .argv = &.{ context.tool_paths.zig, "fmt", "--check", path }, ... });
```

- **Impact:** Unlike #1/#2, the raw path is gated by `workspacePathExists` → port `exists` → `resolve`, which returns `.exists=false` for any `..`/absolute escape (`filesystem.zig:158-163`), so the path is dropped before reaching argv. A surviving path resolves inside root, and the subprocess opens the same relative path against `cwd=root` with identical realpath semantics — no divergence. So there is **no practical escape**; this is a consistency defect (should use the resolved path like `buildZigArgv`), not an exploitable one.
- **Fix:** Resolve each path via `workspace_store.resolve` and embed the resolved path, matching `buildZigArgv`.

### 5. `parseAst` leaks the source buffer on `Ast.parse` OOM
- **Severity: Low** · **VERIFIED** · `src/domain/zig/analysis.zig:264-267`

```zig
fn parseAst(allocator: std.mem.Allocator, contents: []const u8) !std.zig.Ast {
    const source = try allocator.dupeZ(u8, contents);
    return std.zig.Ast.parse(allocator, source, .zig);   // no errdefer free(source)
}
```

- **Impact:** `Ast.deinit` deliberately does not free `tree.source` (callers free it separately), so if `Ast.parse` returns `error.OutOfMemory` the duped buffer leaks. The production caller (`static_source_summary` adapter) uses the base GPA, not an arena, so this is a real OOM-path leak — though bounded and non-panicking.
- **Fix:** `errdefer allocator.free(source);` between the dupe and the parse.

### 6. `forTool(...) orelse unreachable` panics on any future tool-registration gap
- **Severity: Low** · **VERIFIED** · `src/domain/zig/static_analysis_contracts.zig:225`

```zig
pub fn putMetadata(allocator, obj, tool_name) error{OutOfMemory}!void {
    const contract = forTool(tool_name) orelse unreachable;
```

- **Impact:** Not reachable today (all callers pass literals present in `contracts`). But the two contract tables (this file vs. `static_analysis.zig`) are maintained independently, so a future tool added without a matching entry turns this into a **ReleaseSafe panic that crashes the serial MCP server** instead of degrading.
- **Fix:** Return `error.UnknownTool` (or skip metadata) on miss; add a comptime/test assertion that every dispatched tool name resolves.

### 7. `normalizeFindingsText`/`normalizeRulesText` drop the `Parsed` handle (arena-masked leak)
- **Severity: Low** · **VERIFIED** (`lint_intelligence.zig:468`) · `:515` same pattern (INFERRED) · `semantic_index.zig:100,529` same pattern (INFERRED)

```zig
const parsed = try std.json.parseFromSlice(std.json.Value, allocator, text, .{});
const raw = findingsArray(parsed.value);   // parsed.deinit() never called
```

- **Impact:** Leaks the parse arena per call. Masked in production because the static-analysis adapter wraps each call in an `ArenaAllocator` (reclaimed at request end), but becomes a true unbounded leak if ever called with a non-arena allocator. Downstream values are deep-copied via `ownedString`, so adding `defer parsed.deinit()` is safe.
- **Fix:** `defer parsed.deinit();` after each `parseFromSlice` (matching `artifacts/registry.zig` and `semantic_index.zig:447`), or document the arena requirement explicitly.

### 8. `findingsArray` empty fallback binds to `std.heap.page_allocator`
- **Severity: Low** · **VERIFIED** · `lint_intelligence.zig:485` · `semantic_index.zig:546` (INFERRED)

```zig
return std.json.Array.init(std.heap.page_allocator);
```

- **Impact:** No live bug — the array is returned empty and only iterated, never appended to. Latent footgun: a future edit that appends would allocate from a global allocator inside an arena-scoped flow.
- **Fix:** Thread the caller allocator through `findingsArray`.

### 9. `containsWordIgnoreCase` silently fails to match needles >128 bytes
- **Severity: Low** · **VERIFIED** · `src/app/usecases/static_analysis/agent_ergonomics.zig:1050-1053`

```zig
fn containsWordIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    var buffer: [128]u8 = undefined;
    if (needle.len > buffer.len) return false;
    const lowered_needle = std.ascii.lowerString(buffer[0..needle.len], needle);
```

- **Impact:** Correctness, not safety (the guard prevents overflow). Reached from `topicScore`/`insertionSitesValue` with a user `topic` token; a >128-char topic silently never matches, quietly skewing insertion-site/module-role results. (The pre-lowering is also redundant since the loop uses `eqlIgnoreCase`.)
- **Fix:** Compare with `std.ascii.eqlIgnoreCase` directly and drop the 128-byte ceiling.

### Lower-confidence / theoretical (INFERRED — relied on subagent excerpts, not re-read by lead)
- **`u64`→`i64` `duration_ms` casts** (`usecase_support.zig:244`, `workflows.zig:1124/1530`): `@intCast` panics if a clock-derived duration exceeds `i64::max` — not user-controllable, theoretical. Route through the existing `saturatingI64`. **Low.**
- **Splitter backslash escaping applies inside single quotes** (`usecase_support.zig:547-557`): diverges from POSIX (`'a\b'`→`ab`); can mangle Windows-style path tokens. Argv *count* unchanged, so no injection. **Low.**
- **`parseHistoryRuns`** (`workflows.zig:931-968`): a single 8 MiB history line is fully parsed before the `limit` cap applies — bounded memory amplification, not a crash. **Low.**
- **`layout_probes` `u64`→`i64`** size/alignment casts (`:375`) and unresolved-but-sanitized probe argv (`:296`): not reachable (compiler can't emit a 2^63 size; tokens pass `sanitizePathToken`/`validTargetToken`). **Low/safe.**

---

## Verified-safe areas

- **Workspace port sandbox (VERIFIED by lead):** all seven port ops resolve through `resolveInsideRoot`/`resolveOutputInsideRoot` before disk access; `..`/absolute/symlink escapes rejected (`filesystem.zig:76-212`, `workspace.zig:50-152`). The `buildZigArgv` `check`/`test` branches correctly use the resolved path (`project_intelligence.zig:1731,1744`).
- **No command injection (VERIFIED by lead):** single no-shell argv-array spawn point (`command.zig:89`); every `splitToolArgs` consumer feeds a `.argv` array, never a shell string.
- **Arg clamps (VERIFIED):** `floatToInt` rejects non-finite/out-of-range before `@intFromFloat` (`usecase_support.zig:332-338`); `toolTimeout` clamps to `[1, 3_600_000]` (`:348`); the adapter floors `limit` with `@max(1, …)` before the i64→usize cast, and these modules use `limit` only as a loop bound, never an index.
- **Determinism (INFERRED-strong):** `std.json.ObjectMap` is `StringArrayHashMap` (insertion-ordered), so object serialization is stable; all four content agents specifically hunted for `AutoHashMap`/`StringHashMap` iteration leaking into output and found none — symbol/type/finding lists are built by iterating ordered slices. Absolute `workspace.root`/`cwd` appears only in deliberate config-echo/provenance fields, consistent across the codebase.
- **Allocator ownership (INFERRED-strong):** `FailingAllocator` OOM sweeps exist and pass for `project_intelligence`, `usecase_support`, and `workflows` (e.g. `workflows.zig` exercises 192 allocation indices); `errdefer`/`toOwnedSlice` ownership transfer verified in spot checks.
- **Parser robustness in `analysis.zig` (INFERRED-strong):** AST work delegates to `std.zig.Ast`; the `std.zig.string_literal.parseAlloc` assert (`len>=2`, quoted) is gated by callers only passing tokenizer-classified `.string_literal` tokens (unterminated literals tokenize as `.invalid`); hand-rolled scanners use only `splitScalar`/`trim`/`startsWith`/`indexOf` with no raw indexing.

---

## Refuted subagent claim

**The "history write escape" (scope-4 finding W2) is NOT a vulnerability.** `run()` writes `request.output` via `context.workspace_store.write` (`workflows.zig:610`), and `write` resolves through `workspace.writeFile` → `resolveOutput` → `resolveOutputInsideRoot`, which rejects out-of-root paths (`filesystem.zig:108`, `workspace.zig:67-68,128-130`). `output="../escape.jsonl"` fails with `PathOutsideWorkspace`. The subagent correctly flagged it as INFERRED pending this check; the write is confined. Same reasoning clears the `preimageForPath`/`existingHistoryBytes`/`workspacePathExists` reads in that path.

---

## Test-coverage gaps

1. **No test exercises `fmt-check` with an out-of-workspace `file`** (would catch #2). No argv-content assertions for any path-bearing command, so raw-vs-resolved is invisible to the suite.
2. **No test for `publicApiBaseline` path scoping** (would catch #1) — existing tests only use inline before/after text.
3. **No test that `args`/`command` tokens can't inject `--build-file`/`--prefix`/`--cache-dir`** (would catch #3).
4. **No malformed-source fixtures** with an unterminated string/char literal, embedded NULs, a 0-byte file, or a lone `test "` feeding `analysis.zig` — the parser-robustness claims are sound by construction but unproven by tests.
5. **`parseSourceSummary` is never run under `std.testing.checkAllAllocationFailures`** (all its tests use an arena, masking #5).
6. **No leak-checking (non-arena) test around `normalizeFindingsText`/`normalizeRulesText`** (masks #7), and no adversarial findings-JSON test (negative/huge `line`/`column`).
7. **No contract-completeness test** asserting every dispatched tool name resolves in `contracts` (would convert #6 from a runtime panic into a build failure).

---

## Already-known items (excluded from scope per review brief — listed for traceability)

Treated as known/fixed and intentionally not re-reported: `argInt .float`→`@intFromFloat` panic (`usecase_support.zig:326`); reentrant dispatch via elicitation (`protocol_client.zig:166`); npm cache poisoning (`packages/@zigars/mcp/src/install.ts:94`); `zig_code_action_batch` stub vs manifest; the three discovery tools returning text-only results; negative `@intCast` (`patch_sessions.zig:848`, `registry.zig:383`); zon injection (`zon_dependencies.zig:193`). Verified-safe per prior passes and not re-litigated: workspace sandbox internals, the subprocess command runner, ZLS client concurrency, and `structured()` deep-copy (`result.zig:103`).
