# S12 — Contract fidelity B: handler↔schema honesty + manifest LOWs + method strings (Wave 3)

> **Cold-start session.** Repo `zigars`, **Zig 0.16**, **ReleaseSafe**. Read `AGENTS.md` and
> `.agents/workflows/tool-change.md` first. **Land this after S1 (Wave 1) — both touch
> `src/manifest/definitions/`; rebase on `main` first.**
> **Invariant:** a tool's `input_schema` must match exactly what its handler reads — central
> validation (`adapters/mcp/args.zig` ~27) rejects unknown args, so a handler-read field absent from
> the schema is both un-passable *and* un-overridable; a schema field the handler ignores is a
> client-visible lie.
> **Rules:** verify first · stay within *Files in scope* · add the "advertised args are honored"
> tests · branch `git switch -c fix/contract-fidelity-b` · validate and report.

**Review:** `docs/reviews/2026-05-29-mcp-adapter-manifest-fidelity.md` — M1, M2, all Low items;
`CODE_REVIEW.md` — L2, L3 (method strings).

## Files in scope (only these)

- `src/manifest/definitions/{zwanzig,static_evidence,formatting,phase6,zls,agent,performance,diagnostics}.zig`
- `src/manifest/schema.zig`
- `src/adapters/mcp/tools/{static_analysis,zls,release,project_intelligence}.zig`
- `src/adapters/mcp/handler_refs.zig`
- `src/app/usecases/runtime_ux/workflows.zig` (the `compact` mode item only)

## Findings

1. **[MEDIUM · M1] Handlers read args absent from their own schema** → permanently unreachable *and*
   un-tunable. Dropped arg is `timeout_ms` on slow backend tools, plus others:
   `zig_lint`/`zig_lint_sarif`/`zig_lint_rules`/`zig_analysis_graphs` (`timeoutMs`,
   `tools/static_analysis.zig`), `zig_semantic_refs`/`zig_semantic_callers`, `zig_format`
   (`toolTimeout`→`timeout_ms`, `tools/zls.zig`), `zig_docs_query` (`autodoc` via `docsQueryTool`,
   `tools/release.zig`), `zigars_failure_fusion`/`zig_build_events` (`filter`). **Fix:** add the read
   fields to each tool's schema (the `timeout_ms` name-hint in `tooling.zig` already supplies
   `minimum:1`+description, so `.{ "timeout_ms", "integer", false }` suffices). For genuinely
   inapplicable cases, stop reading the arg and use the context default. Decide whether `autodoc`
   belongs on `zig_docs_query` (it's live for `zig_project_docs_query`, which shares the helper).

2. **[MEDIUM · M2] Schemas advertise fields the handler never reads** (silently dropped):
   `zigars_context_pack` (`include`), `zig_diagnostics`/`_all` (`wait_ms`,`timeout_ms`),
   `zig_coverage_diff`/`_budget_check` and `zig_libfuzzer_run`/`zig_afl_run` and `zig_bench_compare`
   (superset shared schemas — each ignores some sibling field; `afl_path` on a libFuzzer tool is
   conceptually wrong). **Fix:** give each tool a minimal schema matching what its handler actually
   consumes instead of sharing one superset; where a field is genuinely meaningful (`corpus` for
   libFuzzer, `include` for context pack), wire it into the handler.

3. **[LOW] `zig_format` over-claims `mutates_lsp_state=true`** (`definitions/formatting.zig` ~14) —
   `zigFormat` uses `CoreCommandContext` and never touches ZLS; the raw `riskValue` JSON in
   `zigars_command_provenance`/`zigars_risk_audit` falsely reports LSP mutation. **Fix:** drop the flag.

4. **[LOW] Dead `apply` guards in `zigRename`/`zigCodeActionApply`** (`tools/zls.zig` ~128, ~154) —
   they check `argBool(args,"apply",false)` but `apply` isn't in their schemas, so the branch is
   unreachable. **Fix:** remove the guard (these tools are read-only), or add `apply` + write-risk
   flags if writes are intended.

5. **[LOW] `mode="compact"` behaves identically to `"standard"`** (`runtime_ux/workflows.zig` ~962).
   **Fix:** implement a distinct compact projection, or remove the `"compact"` enum value.

6. **[LOW] `zig_zon_dep_sync` risk omits `executes_*`** (`definitions/phase6.zig` ~329) — runs
   `zig fetch <url>` (network) with only `executes_backend=true`. Net level stays "high" (via
   `writes_source`), so no client under-statement, but it's a structural gap. **Fix:** add the
   appropriate execute flag (and consider whether `ToolRisk` needs a network marker — note it if so).

7. **[LOW] `schema.zig` triple-writes the `"default"` key** (~80-82: `default_bool`/`default_int`/
   `default_string` all target `"default"`, last non-null wins). Latent (no def sets >1). **Fix:**
   assert mutual exclusion, or unify into one `default: ?std.json.Value`.

8. **[LOW · verify] ZLS plan method-string drift** (`CODE_REVIEW.md` L2/L3): `zig_diagnostics` plan
   says `publishDiagnostics`/`diagnostic` vs the handler's actual `textDocument/diagnostic`
   (`tools/zls.zig` vs `definitions/zls.zig`); `zig_document_change` advertises `didChange` but the
   handler labels `didOpen` (`handler_refs.zig` ~341). **Note:** the adapter-fidelity review's
   verified-safe list says the 12+ ZLS plan strings *match* — so these may already be fixed. Verify
   against the actual LSP method sent; fix only the genuine mismatch (the correct diagnostics value is
   `textDocument/diagnostic`).

## Acceptance

- Add the missing **"advertised args are honored"** tests (none exist): `timeout_ms` on the static
  tools + `zig_format`, `wait_ms` on diagnostics, `autodoc` on `zig_docs_query`, `include` on
  `zigars_context_pack`, coverage diff/budget cross-fields, `zig_bench_compare` `results/limit`,
  libFuzzer `corpus`; plus `unknown_argument` rejection tests pinning the intended contract.
- Schemas changed → run `zig build tool-index` and update `src/manifest/tool_catalog.json` +
  `docs/tool-index.generated.md`; update stdio/HTTP smoke fixtures with representative `tools/call`s.
- `zig fmt build.zig build.zig.zon src tools` · `zig build test` · `zig build docs-check json-check` ·
  `zig build -Doptimize=ReleaseSafe` green. Report commands run.
