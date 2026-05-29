# S4 — Editing safety & path policy (Wave 1)

> **Cold-start session.** Repo `zigars`, **Zig 0.16**, **ReleaseSafe**. Read `AGENTS.md` and
> `.agents/roles/security-sandbox-reviewer.md` first.
> **Invariants:** source-mutating tools require `apply=true`; direct edits must avoid generated/
> cache/artifact/vendored paths; an edit tool must never silently corrupt or drop edits.
> **Rules:** verify first · stay within *Files in scope* · regression test (fails before / passes
> after) · branch `git switch -c fix/editing-safety` · validate and report.

**Review:**
`docs/reviews/2026-05-29-app-usecases-b-diagnostics-performance-release-environment-editing-review.md`
— Findings 3, 5, 6, 7.

## Files in scope (only these)

- `src/app/usecases/editing/workflows.zig`
- `src/app/usecases/editing/patch_sessions.zig`

(For the record, `patch_sessions.zig` ~849 `@intCast(if (bytes < 0) 0 else bytes)` is already
guarded — verify, don't touch.)

## Findings

1. **[HIGH] `zig_move_decl` corrupts source when `source_file == target_file`**
   (`workflows.zig` ~124-140; realized in the apply loop ~318-326). `moveDeclValue` builds
   `source_updated` (decl removed) and `target_updated` (original bytes + appended decl) as two
   replacements with the *same* path; the apply loop writes source, then re-reads and overwrites with
   target computed from the original bytes → the decl is **duplicated** and the removal lost (file no
   longer compiles). `extractDeclValue` already guards this at ~144. **Fix:** add
   `if (std.mem.eql(u8, source_file, target_file)) return error.InvalidArguments;` at the top of
   `moveDeclValue` (mirror extract), or coalesce same-path replacements into one combined edit.

2. **[MEDIUM] `zig_format` / `zig_patch_preview` skip the generated/vendored path policy on apply**
   (`workflows.zig` ~223 `formatValue`, ~276 `patchPreviewValue`). Both are `writes_source=true` but
   write without `classifyPath()`, unlike `replacementSessionValue` (~306-318) which sets
   `safe=false` on `!direct_edit_allowed` and only writes `if (apply and safe)`. Not a sandbox/apply
   bypass, but `patch_preview --apply` can land arbitrary content on a vendored/cache path with no
   signal to the caller. **Fix:** classify `rel` before the `if (apply)` write in both functions;
   refuse (or downgrade to `safe_to_apply=false`) when `!direct_edit_allowed`, and surface the policy
   classification in the result.

3. **[MEDIUM] Duplicate same-file edits in one patch-session apply silently last-wins**
   (`patch_sessions.zig` ~416-434). Two `edits` targeting the same `file` apply sequentially:
   iteration 2 reads iteration 1's output, discarding the earlier edit, and records an
   *intermediate*-state preimage (so revert can't reach the original). **Fix:** detect duplicate
   paths in `request.replacements` up front and reject (`error.InvalidArguments`), or deterministically
   coalesce before preview/apply.

4. **[LOW] Expected-preimage TOCTOU between verify and apply passes** (`patch_sessions.zig` ~370-382
   verify vs ~416-434 apply). Pass 1 checks `expectedMatches` against the pass-1 read; pass 2 re-reads
   and overwrites without re-checking the expected preimage against the fresh bytes. Mitigated (serial
   transport, microseconds apart, default `expected_preimages` fails closed, clobbered bytes saved as
   preimage). **Fix:** re-verify the expected preimage inside the apply loop against the fresh
   snapshot, aborting the whole apply on mismatch.

## Acceptance

- Tests: `zig_move_decl` with `source_file == target_file` rejects (no duplication);
  `zig_format`/`zig_patch_preview` apply onto a generated/vendored path is refused or flagged
  `safe_to_apply=false`; duplicate `file` in one `edits` batch rejects/coalesces; a fake store
  returning different bytes on successive reads triggers the TOCTOU abort.
- `zig fmt build.zig build.zig.zon src tools` · `zig build test` ·
  `zig build -Doptimize=ReleaseSafe` green; if MCP-surfaced, `zig build smoke stdio-fixtures`.
  Report commands run.
