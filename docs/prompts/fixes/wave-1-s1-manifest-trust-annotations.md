# S1 — Manifest trust annotations & invariants (Wave 1)

> **Cold-start session.** Read this whole file, then the linked review section for full evidence.
> **Repo:** `zigars`, deterministic **Zig 0.16** MCP server, built/run in **ReleaseSafe** (failed
> `@intCast`/`@intFromFloat`, `unreachable`, OOB, overflow → **panic = DoS**). Read `AGENTS.md` and
> `.agents/workflows/tool-change.md` first.
> **Rules:** verify each finding is still present before editing · stay strictly within *Files in
> scope* · add a regression test that fails before / passes after · no shell · work on a branch
> (`git switch -c fix/manifest-trust-annotations`) · validate (see bottom) and report commands run.

**Review:** `docs/reviews/2026-05-29-domain-manifest-bootstrap-review.md` — Findings 1, 2, 4, 5, 7.
(Finding 4 and the severity context come from `docs/reviews/codex-disagreed-findings.md`: raw
`read_only` is **not** the MCP source of truth — `mcp_read_only_hint`/`readOnlyHintFor` is — so it's
LOW internal-consistency hardening, but still worth the comptime guard.)

## Files in scope (only these)

- `src/manifest/mod.zig`
- `src/manifest/aggregate.zig`
- `src/manifest/invariants_tests.zig`
- `src/manifest/mod_tests.zig`
- `src/manifest/definitions/ci.zig`, `src/manifest/definitions/profiling.zig` (read_only flips only)

## Findings

1. **[HIGH] `destructiveHintFor` early-returns `false` for every apply-gated tool** (`mod.zig` ~172).
   The guard `if (writes_require_apply and preview_by_default) return false;` runs *before* the
   capability checks, so 15 arbitrary-command-execution tools (libfuzzer/afl/qemu/heaptrack/valgrind/
   callgrind/lldb/core/objdump/dwarfdump/symbolize + coverage/bench/samply/tracy) advertise
   `destructiveHint=false` to agents that use it for auto-approval. **Fix — capability dominates:**
   ```zig
   if (risk_value.writes_source or risk_value.executes_project_code or risk_value.executes_user_command) return true;
   if (risk_value.writes_require_apply and risk_value.preview_by_default) return false;
   return risk_value.writes_artifacts or risk_value.mutates_lsp_state or !spec.read_only;
   ```

2. **[MEDIUM] The destructive invariant test reproduces the bug** (`invariants_tests.zig` ~35;
   `mod_tests.zig` ~107 hard-codes the wrong expectation for a gated tool). The test only asserts
   destructiveness for *non-gated* tools, so the 15 mislabeled tools pass. **Fix:** add an
   **unconditional** invariant over every registered entry — `executes_user_command OR
   executes_project_code OR writes_source ⇒ destructiveHintFor(meta) == true` — and correct the
   `mod_tests.zig` expectation. The new assertion must fail on the old `destructiveHintFor`.

3. **[LOW] `validateDefinition` comptime guard is too narrow** (`aggregate.zig` ~81) — it rejects only
   `writes_source && read_only`. **Fix:** also reject `read_only` combined with
   `executes_project_code` / `executes_user_command` / `writes_artifacts` / `mutates_lsp_state`, then
   flip the now-illegal decls to `read_only = false`: `zig_matrix_check` (`definitions/ci.zig` ~31)
   and `zig_profile_run` (`definitions/profiling.zig` ~25). This changes **no** external hint
   (`readOnlyHintFor` already derives `false` for them) — internal consistency only.

4. **[LOW] Apply-gate guard checks the flag, not the schema** (`aggregate.zig` ~75). When
   `writes_require_apply` is set, comptime-scan `definition.input_schema` for an `apply` boolean field
   and `@compileError` if absent. Decide + comment whether `writes_artifacts` must always be
   apply-gated (`zig_matrix_check` is intentionally artifact-writing but ungated).

5. **[LOW] `idempotentHintFor` is redundant** (`mod.zig` ~161): it ANDs `readOnlyHintFor` with the
   same five `!`-flags `readOnlyHintFor` already requires, so `idempotent ≡ readOnly` for every tool.
   **Preferred fix:** collapse the redundancy and add a comment documenting the current "idempotent
   iff externally read-only" policy. **Do not change any emitted annotation value.**

## Acceptance

- `destructiveHintFor == true` for all 15 tools; every `readOnlyHint` value unchanged.
- New invariant test fails on old `destructiveHintFor`, passes on new.
- Risk/annotation output is generated → run `zig build tool-index` and update
  `src/manifest/tool_catalog.json` + `docs/tool-index.generated.md` if they change; if any
  stdio/HTTP smoke fixture asserts these annotations, update it with a representative `tools/call`.
- `zig fmt build.zig build.zig.zon src tools` · `zig build test` · `zig build docs-check json-check` ·
  `zig build -Doptimize=ReleaseSafe` all green. Report commands run.
