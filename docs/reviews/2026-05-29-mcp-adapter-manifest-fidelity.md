# Review: MCP adapters & tool-handler ↔ manifest fidelity

- **Date:** 2026-05-29
- **Scope:** `src/adapters/mcp/` (tool handlers + projection glue) paired against `src/manifest/definitions/`
- **Method:** 5 parallel subagents over non-overlapping handler+definition pairings; every key claim re-verified against source by reading the exact lines. Findings marked **VERIFIED** (lead reviewer read the lines this session) vs **INFERRED** (subagent-reported, pattern-consistent, not personally re-opened).
- **Build target:** Zig 0.16, ReleaseSafe.

## Headline

No Critical or High findings survive verification. The security-critical invariants held across all five scopes:

- The workspace sandbox is intact on path-taking tools.
- `apply=true` gating is present on every source/artifact mutator reviewed.
- The risk-derived `readOnly` / `destructive` MCP annotations are faithful — no mutating tool advertises itself as read-only.
- Result shape is structured everywhere (`structuredContent` + text fallback), including error envelopes.

The dominant defect class is **contract-honesty drift at shared schemas/handlers**: tools advertise arguments the handler can never receive (M1) or silently ignores (M2). Two subagent severities were corrected downward after verification (see "Corrected").

---

## M1 — Handlers read arguments absent from their own schema → permanently unreachable *and* un-tunable

**Severity: Medium**

Central validation (`src/adapters/mcp/args.zig:27-29`) rejects any argument not in the tool's `input_schema` as `unknown_argument` **before** the handler runs. So when a handler reads such an arg, two things are simultaneously true: a client that *passes* it gets a hard error, and a client that *omits* it can never override the default. For the cluster below the dropped arg is `timeout_ms` on backend-spawning tools (lint/graph/semantic scans that can be slow) — the per-call timeout is silently locked to the server default.

Root cause: shared handler helpers (`timeoutMs`, `toolTimeout`, `docsQueryTool`, `commandEventsTool`) read fields that only *some* of their sibling tools register.

| Tool | Handler reads | Schema | Status |
|---|---|---|---|
| `zig_lint`, `zig_lint_sarif` | `timeoutMs` (`tools/static_analysis.zig:1193`) | `{path,rules_do,rules_skip,config,args}` (`definitions/zwanzig.zig:12,22`) | VERIFIED |
| `zig_lint_rules` | `timeoutMs` (`tools/static_analysis.zig:618`) | `&.{}` empty (`definitions/zwanzig.zig:32`) | VERIFIED |
| `zig_analysis_graphs` | `timeoutMs` (`tools/static_analysis.zig:650`) | `{mode,path,output,args}` (`definitions/zwanzig.zig:42`) | VERIFIED |
| `zig_semantic_refs`, `zig_semantic_callers` | `timeoutMs` via `sourceRefsResult` | `{symbol,limit}` (`definitions/static_evidence.zig:23,27`) | VERIFIED |
| `zig_format` | `toolTimeout`→`timeout_ms` (`tools/zls.zig:22`) | `{file,apply,content}` (`definitions/formatting.zig:11`) | VERIFIED |
| `zig_docs_query` | `argString(args,"autodoc")` via `docsQueryTool` (`tools/release.zig:382`) | `{query,scope,limit}` (`definitions/phase6.zig:153`) | VERIFIED |
| `zigars_failure_fusion` | `argString(args,"filter")` (`tools/project_intelligence.zig:54`) | lacks `filter` (`definitions/agent.zig`) | INFERRED |
| `zig_build_events` | `filter` via shared `commandEventsTool` | lacks `filter` | INFERRED |

Supporting evidence:

- `timeoutMs` reads `timeout_ms`: `tools/static_analysis.zig:1450-1452`
  ```zig
  fn timeoutMs(context: app_context.StaticAnalysisContext, args: ?std.json.Value) ?u64 {
      const raw = mcp.tools.getInteger(args, "timeout_ms") orelse context.timeouts.command_ms;
      return @intCast(@max(1, @min(raw, 60 * 60 * 1000)));
  }
  ```
- `toolTimeout` reads `timeout_ms`: `tools/zls.zig` (`return @max(1, @min(argInt(args, "timeout_ms", context.timeouts.command_ms), ...))`).
- `zig_format_check` *does* register `timeout_ms` (`definitions/formatting.zig`) while `zig_format` does not — confirming the asymmetry is unintentional.
- `docsQueryTool` (`tools/release.zig:378-382`) is shared by `zig_docs_query` (call site `:227`) and `zig_project_docs_query` (call site `:233`); it reads `autodoc`, but `zig_docs_query`'s schema omits it.

**Fix:** Add the read fields to each tool's schema. The `timeout_ms` name-based hint in `tooling.zig:86` already supplies `minimum:1` + description, so `.{ "timeout_ms", "integer", false }` is sufficient — no hint override needed. For genuinely inapplicable cases, stop reading the arg and use the context default directly. For `zig_docs_query`, decide whether `autodoc` belongs there (it is live for `zig_project_docs_query`, which shares the helper).

---

## M2 — Schemas advertise optional fields the handler never reads → silently dropped

**Severity: Medium**

Inverse of M1: the field *is* registered (so clients are told it works and it passes validation) but the handler discards it. No error, no effect — a client-visible contract lie.

| Tool | Advertised-but-ignored | Status |
|---|---|---|
| `zigars_context_pack` | `include` (`definitions/agent.zig:11`); handler reads only `mode`,`token_budget` (`tools/project_intelligence.zig:18-22`) | VERIFIED |
| `zig_diagnostics` | `wait_ms` (`definitions/zls.zig:45`); never read in `tools/zls.zig` (`fileOnlyTool:255`) | VERIFIED |
| `zig_diagnostics_all` | `wait_ms`,`timeout_ms` (`definitions/zls.zig:54`); ignored | VERIFIED |
| `zig_coverage_diff` / `zig_coverage_budget_check` | share `coverage_compare_schema` (`definitions/performance.zig:48,149,153`); each ignores the other's `current/baseline` vs `coverage` fields | schema-sharing VERIFIED; disjoint reads INFERRED |
| `zig_libfuzzer_run` | `corpus`,`afl_path` via shared `fuzz_run_schema` (`definitions/diagnostics.zig:70-79`, also used by `zig_afl_run`); handler reads neither | schema-sharing VERIFIED; handler-ignore INFERRED |
| `zig_bench_compare` | `results`,`limit` in `bench_compare_schema` (`definitions/performance.zig:77-83`); handler reads only `current/baseline/threshold_pct` | INFERRED |

Notes:

- `wait_ms` carries a documented `default_int=500` (`tooling.zig:89`) the tool never honors.
- `afl_path` on a *libFuzzer* tool is conceptually wrong (AFL-specific) — a side effect of `fuzz_run_schema` being shared with `zig_afl_run`.

**Fix:** Give each tool a minimal schema matching what its handler actually consumes, instead of sharing one superset schema across tools with divergent field usage. Where a field is genuinely meaningful (e.g. `corpus` for libFuzzer, `include` for context pack), wire it into the handler.

---

## Low / maintainability

- **`zig_format` over-claims `mutates_lsp_state=true`** (`definitions/formatting.zig:14`). VERIFIED the flag is set; INFERRED it is spurious: `zigFormat` uses `CoreCommandContext` and never touches ZLS. Harmless to MCP hints (`destructiveHint`=false via preview gating; `readOnly`=false via `writes_source`), but the raw `riskValue` JSON in `zigars_command_provenance` / `zigars_risk_audit` will falsely report LSP mutation. **Fix:** drop the flag.
- **Dead `apply` guards in `zigRename`/`zigCodeActionApply`** (`tools/zls.zig:128,154`). VERIFIED. Both check `argBool(args,"apply",false)` but `apply` is not in their schemas, so the branch is unreachable. Safe (defensive) but misleading. **Fix:** remove the guard, or add `apply` + write risk flags if writes are actually intended.
- **`mode="compact"` behaves identically to `"standard"`** in a runtime_ux tool (`app/usecases/runtime_ux/workflows.zig:962`, per subagent). INFERRED. Enum advertises a mode that does nothing distinct. **Fix:** implement or remove `"compact"`.
- **`zig_zon_dep_sync` risk omits `executes_*`** (`definitions/phase6.zig:329`). VERIFIED. It runs `zig fetch <url>` (network) with only `executes_backend=true`. Net risk level is still "high" (via `writes_source`), so no under-statement reaches clients; this is a structural gap (no network flag in `ToolRisk`). Low.
- **`schema.zig:80-82` triple-writes the `"default"` key** (`default_bool`/`default_int`/`default_string` all target `"default"`, last non-null wins). VERIFIED. No current definition sets more than one, so latent only. **Fix:** assert mutual exclusion or unify into one `default: ?std.json.Value`.

---

## Corrected (subagent severities that did not survive verification)

- **`read_only=true` alongside write/execute risk flags is NOT a defect** (raised as Low ×3 for core tools and **High** for `zig_profile_run`). VERIFIED: `read_only` defaults to `true` and is set on essentially every tool — including every code-executing core tool (`zig_build`, `zig_test`, `definitions/core.zig:39-51`). The real external hint is *derived*: `readOnlyHintFor` (`mod.zig:150`) ANDs `read_only` with the absence of risk flags, and `riskValue` (`mod.zig:132`) exposes only the derived `mcp_read_only_hint`, never the raw field. Every reviewed mutator advertises correctly. The field is effectively vestigial; the load-bearing invariant is "every mutating tool carries the right risk flags," which held in all five scopes. **Downgraded High → non-issue.**
- **`completion_source` is NOT dropped from clients** (raised Medium). VERIFIED: `schema.zig:80-93` omits it from the `tools/list` inputSchema, *but* the MCP `completion/complete` endpoint serves it (`server/completion.zig:131-136`, the proper mechanism for argument completion) and the compact catalog emits it (`tool_catalog_render.zig:416`). The functional path works; only a non-standard inputSchema extension key is absent. **Downgraded Medium → Low cosmetic.**

---

## Verified safe (high confidence)

- **Apply-gating + risk fidelity on mutators.** Source/artifact writers gate on `apply=true` with `writes_require_apply + preview_by_default`: `zig_format`, `zig_patch_preview`, `zigMoveDecl/ExtractDecl/UpdateImports/OrganizeImports`, `patch_session_apply/revert`, `zig_code_index_export`/`zig_scip_export` (`definitions/static_evidence.zig:31,33`), `zig_api_baseline_init`, `zig_sbom`, `zig_deps_add/remove/upgrade`, `zig_zon_dep_sync`, `zig_dependency_migrate`, `zig_analysis_graphs` (`workspace_artifact`, explicit output dir). `zig_rename`/`zig_code_action_apply` are read-only and refuse writes.
- **ZLS plan method strings match the LSP methods actually sent** — all 12+ cross-checked (`textDocument/{didOpen,didChange,hover,definition,references,completion,signatureHelp,documentSymbol,rename,diagnostic}`, `workspace/symbol`); `mutates_lsp_state`/`mutates_document_state` set on open/change, absent on read queries.
- **Result shape is structured everywhere.** All handlers route through `mcp_result.structured`/`structuredError` (both `structuredContent` + text fallback); `errors.zig` envelopes are structured (code/category/resolution + text). The only known text-only cases are the 3 discovery tools (pre-known); no 4th found.
- **Glue correctness:** `registration.zig` iterates `manifest.specs` with no skipped/duplicate entries; `handler_refs.zig` maps each ToolId to a coherent (module,name); `zigars_tool_index`→`zigarsCapabilities` alias is intentional and the defs are compatible; `tool_catalog.json` `common_intents[].prefer` ids all resolve to real tools.
- **Arg validation:** missing-required + unknown-arg + enum(string)/min-max(integer) enforced centrally; `schemaTypeMatches` intentionally skips `number/array/object` and no reviewed handler feeds such a field into `argInt` unguarded.

---

## Test-coverage gaps

1. **No test asserts advertised args are honored** — would immediately surface M1/M2: `timeout_ms` on the 6 static tools + `zig_format`; `wait_ms` on diagnostics; `autodoc` on `zig_docs_query`; `include` on `zigars_context_pack`; coverage diff/budget cross-fields; `zig_bench_compare` `results/limit`; libFuzzer `corpus`.
2. **No test asserts `unknown_argument` rejection** for the M1 dead-reads — such a test would pin the intended contract and fail loudly if a field is later added.
3. **Preview-path (`apply=false`) coverage missing** for several gated writers: `zig_code_index_export`/`zig_scip_export`, `zig_libfuzzer_run`, `zig_dependency_migrate` (`mode=close`), `zig_coverage_baseline`.
4. **No `completion_source` round-trip test** (manifest → completion endpoint → resource URIs).

---

## Bottom line

Ship-blocking issues: none. The worth-fixing set is the shared-schema/handler argument drift (M1/M2), best resolved by giving each tool a schema that matches exactly what its handler reads — and adding tests that assert advertised arguments take effect.
