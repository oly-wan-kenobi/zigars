# S2 — App subprocess sandbox escapes (Wave 1)

> **Cold-start session.** Repo `zigars`, **Zig 0.16**, **ReleaseSafe** (panics = DoS). Read
> `AGENTS.md` and `.agents/roles/security-sandbox-reviewer.md` first.
> **There is NO shell** — the single argv-array spawn is `src/infra/process/command.zig`; these are
> *flag-injection / sandbox-boundary* issues, not command injection. Keep it that way.
> **Rules:** verify first · stay within *Files in scope* · regression test (fails before / passes
> after) · branch `git switch -c fix/app-subprocess-sandbox` · validate (bottom) and report.

**Review:** `docs/reviews/2026-05-29-app-usecases-validation-static-analysis-review.md` —
Findings 1, 2, 3. Invariant: every user path must resolve under the workspace **before** it reaches
a subprocess argv; sibling branches already do this via `context.workspace_store.resolve`.

## Files in scope (only these)

- `src/app/usecases/static_analysis/project_values.zig`
- `src/app/usecases/validation/project_intelligence.zig`
- `src/app/usecases/usecase_support.zig` (the arg splitter only)

## Findings

1. **[MEDIUM] `publicApiBaseline` runs `git show <ref>:<file>` with a raw, unresolved user `file`**
   (`project_values.zig` ~1577). When the workspace is a subdirectory of a larger git repo, a caller
   can read *any* tracked blob outside the workspace and exfiltrate it via the returned diff `before`.
   Its sibling `publicApiCurrent` reads through the sandboxed `workspace_store.read`. **Fix:** resolve
   `file` via `context.workspace_store.resolve(...)`, convert to a workspace-relative path (as
   `workspaceRelative` / `fileOwnerForPathValue` already do), reject out-of-root, and use that
   relative path in the `<ref>:<path>` spec. Optionally validate `baseline_ref` against a revision
   charset. (Single-token spec, no shell — keep it a single argv token.)

2. **[MEDIUM] `fmt-check` branch appends a raw `file`** (`project_intelligence.zig` ~1737) to
   `zig fmt --check`, while the sibling `check`/`test` branches in the same function resolve via
   `workspace_store.resolve`. Reachable from `zigars_failure_fusion` / `zig_build_events` /
   `zig_test_events`. **Fix:** resolve identically, preserving the `src` default when `file` is null.

3. **[MEDIUM] `args`/`command` passthrough injects workspace-escaping build flags**
   (`project_intelligence.zig` ~1755; splitter `usecase_support.zig` ~533-590). User tokens are
   appended to `zig build`/`zig test` with no `--` guard, so a caller can pass `--build-file`,
   `--prefix`, `--cache-dir`, `--global-cache-dir`, `--zig-lib-dir`, or `-femit-*` to execute/emit
   outside the workspace. The `--` guard *is* used for the heaptrack/afl/samply wrappers but not here.
   **Fix:** for `zig test`, insert `--` before user tokens (safe). For `zig build` (where `zig build
   --` has run-args semantics — do **not** blindly add `--`), deny-list the path-bearing build-system
   flags above, or resolve their operands through the workspace store.

## Acceptance

- Add tests asserting **argv content**: an out-of-workspace `file` is dropped/resolved for both
  `fmt-check` and `publicApiBaseline`; `args` tokens cannot inject `--build-file`/`--prefix`/
  `--cache-dir`. (No argv-content assertions exist today — that's why this was invisible.)
- If behavior is surfaced over MCP, run `zig build smoke stdio-fixtures`.
- `zig fmt build.zig build.zig.zon src tools` · `zig build test` ·
  `zig build -Doptimize=ReleaseSafe` green. Report commands run.
