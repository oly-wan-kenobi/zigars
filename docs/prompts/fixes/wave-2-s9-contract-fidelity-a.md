# S9 — Contract fidelity A: code_action_batch stub + discovery result shape (Wave 2)

> **Cold-start session.** Repo `zigars`, **Zig 0.16**, **ReleaseSafe**. Read `AGENTS.md` and
> `.agents/workflows/tool-change.md` first.
> **Invariants:** the MCP risk/`destructiveHint` annotation must match what the tool actually does;
> every handler returns structured results (`structuredContent` + text fallback).
> **Rules:** verify first · stay within *Files in scope* · regression test · branch
> `git switch -c fix/contract-fidelity-a` · validate and report.

**Reviews:** `CODE_REVIEW.md` — M3, M4; cross-ref
`docs/reviews/2026-05-29-mcp-adapter-manifest-fidelity.md` (Verified-safe list confirms only these 3
discovery tools are text-only — no 4th).

## Files in scope (only these)

- `src/adapters/mcp/tools/transactional_editing.zig`
- `src/adapters/mcp/tools/discovery.zig`
- `src/manifest/definitions/transactional_editing.zig`

## Findings

1. **[MEDIUM] `zig_code_action_batch`: inert stub advertised as a destructive ZLS mutator** (handler
   `transactional_editing.zig` ~169 vs manifest `definitions/transactional_editing.zig` ~135-142). The
   handler signature is `(allocator, context, _: ?std.json.Value)` — args discarded; it only checks
   `zls_state.running` and returns a hardcoded "unavailable" value. But the manifest declares 6
   **required** fields + `risk{writes_source, writes_require_apply, preview_by_default,
   mutates_lsp_state, executes_backend}` + `apply_gated_mutation`, so (after the S1
   `destructiveHintFor` fix) it advertises a destructive, source-writing, apply-gated tool that does
   nothing. Same drift class already fixed for `zig_rename`/`zig_code_action_apply`. **Fix:** strip the
   required fields + source/LSP risk from the manifest entry to match the stub (preferred), **or**
   implement the tool. Whichever you choose, handler and manifest must agree.

2. **[MEDIUM] Three discovery tools return text-only results** (`discovery.zig` ~12-19, ~73-81).
   `zigars_capabilities`, `zigars_tool_index` (→ `zigarsCapabilities`), and `zigars_schema` call
   `jsonTextOnly`, returning `.{ .content = content }` with **no** `structuredContent`, violating the
   repo-wide "structured + text fallback" rule every other handler follows via
   `mcp_result.structured`. (`zigars_schema` also emits the *identical* catalog as
   `zigars_capabilities`, contradicting its "schema-discovery hints" description — note it, but the
   structured-result fix is the deliverable.) **Fix:** route all three through `mcp_result.structured`.

## Acceptance

- Tests: `zig_code_action_batch`'s manifest risk/required-fields match its handler (an invariant test
  that handler-ignored args aren't declared *required*); the three discovery tools return
  `structuredContent`.
- If you change the manifest entry, run `zig build tool-index` and update
  `src/manifest/tool_catalog.json` + `docs/tool-index.generated.md`; update any smoke fixture that
  calls these tools.
- `zig fmt build.zig build.zig.zon src tools` · `zig build test` · `zig build docs-check json-check` ·
  `zig build -Doptimize=ReleaseSafe` green. Report commands run.
