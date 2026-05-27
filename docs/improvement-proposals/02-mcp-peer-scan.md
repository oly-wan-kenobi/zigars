# 02 — MCP Peer Scan

**Author:** Claude Opus 4.7 (1M context)
**Date:** 2026-05-27
**Scope:** Benchmark zigar against peer MCP servers (TypeScript, Python, Rust, Go, Anthropic-official) and the current MCP protocol spec (2025-06-18). Identify capability and protocol-feature gaps. Propose 10 specific borrows with attribution.
**Constraints:** Read-only. No code or existing-doc changes. Excludes everything already in CLAUDE_ANALYSIS.md P0–P4.

---

## 1. Peers Reviewed

Each entry is one paragraph: what the peer is, the tool surface I sampled, and the angle that's interesting for a Zig dev MCP.

### Anthropic-official `modelcontextprotocol/servers`

The reference repo was reorganized in 2025. Seven servers remain in the "actively maintained reference implementations" set ([modelcontextprotocol/servers](https://github.com/modelcontextprotocol/servers)) — **filesystem**, **git**, **memory**, **sequential-thinking**, **fetch**, **time**, **everything** — and the rest moved to [modelcontextprotocol/servers-archived](https://github.com/modelcontextprotocol/servers-archived) (github, gitlab, slack, postgres, sqlite, puppeteer, brave-search, etc.). The official line is that all of these are educational examples, not production; vendor-maintained servers (e.g. [github/github-mcp-server](https://github.com/github/github-mcp-server) with 105+ tools) now own first-party integrations. For zigar, the most relevant lessons are in **filesystem** (`read_text_file` with `head`/`tail`, `edit_file(..., dryRun)`, `directory_tree` with structured JSON, `read_multiple_files` with partial-success), **everything** (the conformance reference for sampling/completions/elicitation/progress/logging — every MCP feature exercised in one server), **sequential-thinking** (revisable/branching reasoning state machine), **memory** (knowledge-graph CRUD with batched arrays), and **github-mcp-server** (PR review / issue / actions / code-security surface).

### gopls built-in MCP (Go, official)

As of `gopls v0.20` (Aug 2025), the Go tools team ships an MCP server directly inside gopls: `gopls mcp` runs in "attached" mode (live LSP session) or "detached" (one-shot). Headline tools: `go_package_api` (exported funcs/types/comments without reading impl), `go_search` (codebase + dependency search), `go_symbol_references` (call-site discovery), `go_workspace` (module graph). This is the de facto standard the Go team blesses. Third-party wrappers like [hloiseau/mcp-gopls](https://github.com/hloiseau/mcp-gopls) layer on test/diagnostic/coverage tooling (`run_go_test`, `run_govulncheck`, `analyze_coverage`, `module_graph`) and ship MCP **prompts** (`summarize_diagnostics`, `refactor_plan`) — the prompt surface in particular is well-developed. Two things stand out: the **`go_package_api` pattern** (return the public contract of a package without dumping source) and the **first-party shipping channel** (compiler-suite ships the MCP, not a community wrapper).

### Rust ecosystem (cargo + rust-analyzer)

No single official Rust MCP yet. Best-of-breed are [jbr/cargo-mcp](https://github.com/jbr/cargo-mcp) (cargo orchestration: `cargo_check/clippy/test/fmt_check/build/bench/add/remove/update/clean/run`, all with `toolchain` + `cargo_env` params), [zeenix/rust-analyzer-mcp](https://github.com/zeenix/rust-analyzer-mcp) (thin LSP bridge), and [dexwritescode/rust-mcp](https://github.com/dexwritescode/rust-mcp) which goes further: `generate_struct/enum/trait_impl/tests`, `change_signature`, `move_items`, `apply_clippy_suggestions`, `validate_lifetimes`, `suggest_dependencies`. The standout in this ecosystem is [joshrotenberg/cratesio-mcp](https://github.com/joshrotenberg/cratesio-mcp) — 23 tools covering `search_crates`, `get_crate_info/versions/readme/features/docs/dependencies/reverse_dependencies`, `audit_dependencies` (OSV.dev), `get_downloads/owners/categories/keywords`. There's a public instance at `cratesio-mcp.fly.dev`. **None** of cargo, rust-analyzer, or the docs servers have wrapped `bacon`, `cargo-watch`, `miri`, `tokio-console`, or `criterion` as MCPs yet — the watch / hot-reload / UB-detection space is open.

### TypeScript / JavaScript

Three buckets. **Language**: [mizchi/typescript-mcp](https://mcpservers.org/servers/mizchi/typescript-mcp) (LSP bridge with `lsp_get_hover`, `lsp_find_references`, `lsp_get_diagnostics`, `lsp_rename_symbol`, plus higher-level `get_project_overview`, `search_symbols`, `replace_regex`), and [jgauffin/ts-language-mcp](https://github.com/jgauffin/ts-language-mcp) (uses the TS Compiler API directly; notable adds: `get_call_hierarchy`, `get_type_hierarchy`, `rename_preview`, `batch_analyze`). **Runtime/package**: [carlosedp/mcp-bun](https://github.com/carlosedp/mcp-bun) (`run-bun-script-file`, `run-bun-eval`, `run-bun-install`, `analyze-bun-performance`, plus long-running dev-server lifecycle — `start-bun-server`, `stop-server`, `get-server-logs`, `list-servers`); [pinkpixel-dev/npm-helper-mcp](https://github.com/pinkpixel-dev/npm-helper-mcp) and `@jixo/mcp-pnpm` for package CRUD. **Frameworks**: [prisma/mcp](https://github.com/prisma/mcp) (official; `migrate-dev/status/reset`, `IntrospectSchemaTool`, `Prisma-Studio`, `ExecuteSqlQueryTool`), [vercel/next-devtools-mcp](https://github.com/vercel/next-devtools-mcp) (integrates with Next.js 16's `/_next/mcp` endpoint; codemod-driven `upgrade_nextjs_16`), [microsoft/playwright-mcp](https://github.com/microsoft/playwright-mcp) (~60 tools; accessibility-tree snapshots, network mocking, tracing/video, PDF export), [storybook/mcp](https://storybook.js.org/docs/ai/mcp/overview) (development + docs + testing toolsets). The notable pattern across this ecosystem is **long-lived process lifecycle as first-class tools** (mcp-bun) and **codemod / scaffolding** (Next.js DevTools).

### Python ecosystem

[pylancemcp.com](https://pylancemcp.com) wraps Pyright with the full LSP surface plus `python.setInterpreter` (auto-detect venv/conda/poetry) and `export_training_data`. [Anselmoo/mcp-server-analyzer](https://github.com/Anselmoo/mcp-server-analyzer) combines Ruff + Astral's `ty` type-checker + Vulture dead-code into one server (`ruff-check`, `ruff-format`, `ruff-check-ci`, `ty-check`, `vulture-scan`, `analyze-code`); an upstream Ruff MCP discussion is open at `astral-sh/ruff#19639`. [dmclain/uv-mcp](https://github.com/dmclain/uv-mcp) is the cleanest package-manager MCP I saw — tools `uv_init/add/remove/sync/lock/run` plus pip-compat, and exposes installed packages as **resources** (`python:packages://installed`, `python:packages://{pkg}/dependencies`, `python:requirements://{path}`) rather than tools. [datalayer/jupyter-mcp-server](https://github.com/datalayer/jupyter-mcp-server) has 15 tools across three groups — server (`list_files`, `list_kernels`, `connect_to_jupyter`), notebook (`use_notebook`, `read_notebook`, `restart_notebook`), and cells (`insert_cell`, `overwrite_cell_source`, `execute_cell`, `execute_code` for kernel scratchpad). The notable patterns: **package state as resources** (uv-mcp) and **persistent REPL/notebook** (jupyter-mcp).

---

## 2. Tool-Surface Comparison

Capability × peer. Cells: ✓ = present, • = partial/peripheral, blank = absent. "Peers" column groups Rust, TypeScript, Python, Go for column compactness — see §1 for the canonical peer behind each tick.

| Capability | gopls | cargo/RA-mcp | crates.io-mcp | TS-mcp / bun-mcp | Python (pylance / uv / ruff) | Anthropic-official | **zigar** |
|---|---|---|---|---|---|---|---|
| LSP bridge (hover/def/refs/completion/symbols) | ✓ | ✓ | | ✓ | ✓ | | ✓ |
| Build/test/check wrappers | ✓ | ✓ | | ✓ | ✓ | | ✓ |
| Formatter + format-check | ✓ | ✓ | | ✓ | ✓ | | ✓ |
| Linter + SARIF | • | ✓ | | • | ✓ | | ✓ |
| Refactor (rename/move/extract/imports) | ✓ | ✓ | | ✓ | ✓ | | ✓ |
| Coverage (basic) | ✓ | • | | • | • | | ✓ |
| Coverage baselines + diff + budget | | | | | | | ✓ |
| Benchmarks (run) | | ✓ | | • | | | ✓ |
| Benchmark baselines + history + compare | | | | | | | ✓ |
| Profiling (samply/tracy/flamegraph) | | | | | | | ✓ |
| Fuzz (afl/libfuzzer + crash minimize + corpus) | | | | | | | ✓ |
| Debugger bridge (lldb / delve / DAP) | • | | | | | | ✓ |
| Sanitizer / panic-trace fusion | | | | | | | ✓ |
| Cross-target / cross-compile matrix | • | • | | | | | ✓ |
| Embedded / flash workflows | | | | | | | ✓ |
| SBOM (CycloneDX) | | | | | | | ✓ |
| OSV vulnerability scan | | | ✓ | | • | | ✓ |
| License summary | | | • | | | | ✓ |
| Public API baseline + diff | | | | | | | ✓ |
| Release plan / notes / evidence pack | | | | | | | ✓ |
| Transactional patch sessions (preview/apply/revert) | | | | | | | ✓ |
| Artifact registry with SHA-256 provenance | | | | | | | ✓ |
| Async jobs with cursored result reads | | | | | | | ✓ |
| Project memory / decision records | • | | | | | ✓ (memory) | ✓ |
| **Package install/add/remove/upgrade (mutates manifest)** | • (`mod tidy`) | ✓ (`cargo_add/remove/update`) | | ✓ (npm/pnpm/bun add) | ✓ (`uv_add/remove/sync/lock`) | | |
| **Package registry browse (search/info/readme/versions)** | • (pkg.go.dev MCP upcoming) | | ✓ (23 tools) | • (`search_npm`) | • | | |
| **Third-party dependency docs query** | ✓ (`go_package_api`) | | ✓ | | • | | • (zigar has own-project docs only) |
| **File-system watch / hot-reload long job** | | | | | | | |
| **REPL / scratch-eval surface** | | | | ✓ (`run-bun-eval`) | ✓ (jupyter `execute_code`) | | |
| **Code scaffold / new project / new module** | | • (`generate_*` in dexwritescode/rust-mcp) | | • (`init` in next-devtools) | • (`uv_init`) | | |
| **Live dev-server lifecycle (start/stop/logs)** | | | | ✓ (mcp-bun) | | | • (zigar has single-shot `run_stream`) |
| **PR review / issue / GitHub workflow surface** | | | | | | ✓ (github-mcp-server) | • (only `zig_github_dependency_submit_plan`) |
| **Comptime / macro expansion view** | | • (`cargo expand` ad-hoc) | | | | | |
| **Browser preview / accessibility-tree** | | | | ✓ (Playwright MCP) | | ✓ (puppeteer-archived) | |
| **Schema migration tooling** | | | | | | | n/a — Zig idiom |
| **Database introspection** | | | | ✓ (Prisma) | | ✓ (postgres/sqlite) | n/a — out of scope |
| **MCP `sampling/createMessage`** | | | | | | ✓ (everything) | |
| **MCP `elicitation/create`** (2025-06-18) | | | | | | ✓ (everything) | • (zigar `_elicit` tools return text; not protocol-level) |
| **MCP `completion/complete`** | | | | | | ✓ (everything) | ✓ (basic route; deepen manifest-backed argument sources) |
| **Tool `outputSchema` declarations** | • | • | | • | • | ✓ (everything, spec) | |
| **`resource_link` content blocks in tool results** | | | | | | ✓ (puppeteer, everything) | |
| **`tools/list` cursor pagination** | | | | | | ✓ (spec) | ✓ |
| **MCP resources (subscribe + templates)** | | | | | ✓ (uv-mcp) | ✓ | ✓ |
| **MCP prompts** | ✓ (`summarize_diagnostics`, `refactor_plan`) | | | | | ✓ | ✓ (`zigar_prompt_pack`) |
| **Roots awareness** | ✓ | | | | | ✓ | ✓ |

### What the table says

- **Zigar leads peers** on coverage budgets, benchmark history, profiling depth, fuzz surface, sanitizer fusion, public-API diffing, release-evidence packaging, transactional patch sessions, artifact provenance, async-job ergonomics, and embedded workflows. Nothing in the survey matches this combination.
- **Zigar trails peers** on package-manager mutation (zigar has `_update_plan` and `_inspect` but no `_add/_remove`), package-registry browse, dependency-docs consumption, dev-server lifecycle, file-system watch, REPL/scratch eval, scaffolding, and PR-workflow composition.
- **Zigar trails the MCP spec itself** on `sampling/createMessage`, `elicitation/create`, declared `outputSchema`, and `resource_link` content blocks in tool results. A basic `completion/complete` route, resource templates/subscriptions, and cursor pagination already exist; the remaining completion work is manifest-backed and dynamic argument sources. These are protocol features, not tools — implementing them is a substrate change that improves *every* tool, not a new tool.

---

## 3. Proposals (10)

Each proposal: what it adds, the peer/spec it borrows from, why it fits zigar's architecture, and a sketch of the surface change. I've ordered them by leverage — protocol-level changes first (they multiply across the 300-tool surface), then capability gaps.

### P1 — Implement MCP `elicitation/create` for risky and transactional operations

**Borrowed from:** [MCP 2025-06-18 spec](https://modelcontextprotocol.io/specification/2025-06-18/client/elicitation); the `everything` reference server; the [Memgraph elicitation write-up](https://memgraph.com/blog/memgraph-mcp-elicitation-and-sampling).

**Gap:** Zigar has `zigar_setup_elicit`, `zigar_profile_elicit`, `zigar_backend_elicit` — but those are **tools that return guidance text** for the agent to consume. They are not the MCP-spec **`elicitation/create`** primitive, which is a server→client request issued mid-tool-call that pauses execution and asks the user for structured input via the client UI. Today, when `zigar_patch_session_apply` would overwrite a file, or `zig_libfuzzer_run` is about to allocate gigabytes for a corpus, zigar must rely on the agent honoring an `apply=false` preview convention. With protocol-level elicitation, zigar can hand control back to the human and resume on the response.

**Sketch:** Add a thin `elicit(...)` helper inside `src/adapters/mcp/` that wraps `elicitation/create` with the spec's restricted JSON-Schema subset (flat object, primitives + enum + format-string). Tools that opt in pass `{action: "apply"|"stash"|"abort", note?: string}` schemas. Hosts that don't support elicitation fall back to the existing `apply=true` convention. Candidate first adopters: `zigar_patch_session_apply`, `zig_libfuzzer_run`, `zig_afl_run`, `zig_dependency_update_plan → apply path` (when P7 lands), `zigar_clean_tree_gate` confirmation.

**Why now:** Spec is stable; client adoption (Claude Desktop, Claude Code) is in flight; the spec is explicit that **MUST NOT** be used for secrets, which matches zigar's threat model.

---

### P2 — Implement MCP `sampling/createMessage` for in-tool diagnostic summarization

**Borrowed from:** [MCP sampling spec](https://modelcontextprotocol.io/specification/2025-06-18/client/sampling); the `everything` reference server.

**Gap:** Zigar produces dense outputs that beg for prose summarization: zlint findings, panic-trace analyses, sanitizer fusions, fuzz crash repros, samply profile summaries, public-API diffs. Today an agent must re-paste the output to its own LLM. With `sampling/createMessage`, zigar **asks the host's LLM** with explicit `modelPreferences` (e.g. `speedPriority: 0.9, intelligencePriority: 0.3` for in-loop summarization) — no API key in zigar, no second round trip from the user's perspective.

**Sketch:** Add an optional `summarize: true` parameter (or a sibling `_summarize` tool) on a handful of high-volume tools — `zig_zlint`, `zigar_failure_fusion`, `zig_panic_trace_analyze`, `zig_samply_summary`, `zig_public_api_diff`. When set and the client advertises sampling capability, zigar issues `sampling/createMessage` with a system prompt scoped to "summarize this Zig {diagnostic|trace|diff} in N bullets." When the client doesn't, the raw structured output is returned unchanged (and the response includes `summary_unavailable: "client_does_not_support_sampling"` so the agent knows).

**Why now:** Tracy/samply summarization is a particularly clean fit — the raw profiles are megabytes; a one-paragraph summary is what the human actually wants.

---

### P3 — Implement MCP `completion/complete` for tool arguments

**Borrowed from:** [MCP completion spec](https://modelcontextprotocol.io/specification/2025-06-18/server/utilities/completion); the `everything` reference server; the `context.arguments` pattern in particular.

**Gap:** Zigar already routes `completion/complete` for prompts, resources, selected argument names, and resource URI templates. The remaining gap is that unusually rich enumerable inputs — build targets, ZLS symbol names, registered backend ids (zlint/zwanzig/zflame/etc.), test names from `zig_test_discover`, profile names, artifact SHAs from `zigar_artifact_index`, validation modes, output modes — are not yet manifest-backed dynamic completion sources. Without those sources, an agent still has to guess or pre-list many values. With richer `completion/complete` (and the `context.arguments` map so e.g. completing a `test_name` is scoped by the already-selected `target`), slash-command UX in supporting clients (Claude Code, Claude Desktop) gets dramatically better.

**Sketch:** Extend the existing MCP adapter completion handler. Drive completions from the existing manifest at `src/manifest/`: any argument with an enum gets autocomplete for free; arguments tagged `completion_source: "test_discover"` (or `"artifact_index"`, `"backend_catalog"`, `"profile_names"`) get callbacks. Cap suggestions at 100 per the spec, return `hasMore`/`total`.

**Why now:** Spec is stable; zigar already has the manifest discipline that makes this almost free to retrofit.

---

### P4 — Declare `outputSchema` and emit `structuredContent` consistently

**Borrowed from:** [MCP 2025-06-18 tools spec](https://modelcontextprotocol.io/specification/2025-06-18/server/tools); the `everything` reference server.

**Gap:** Zigar produces rich `structuredContent`, but does not declare an `outputSchema` per tool. The 2025-06-18 spec formalizes `outputSchema` (JSON-Schema for the return shape) alongside `structuredContent` — declared schemas let clients validate, render tables, drive form UIs, and let downstream agents stop re-parsing prose. For zigar's audience (CI pipelines, agent loops) this is high-leverage.

**Sketch:** Extend `src/manifest/definitions/*.zig` to allow per-tool `output_schema` entries. Generate the schemas alongside the existing input-schema generation in the tool-index pipeline. Tools that already return rich JSON (ZLS bridges, `zig_zlint`, `zig_sbom`, `zig_osv_scan`, `zig_public_api_diff`, `zig_coverage_*`, samply/tracy outputs) get the highest payoff. Architecture guard could enforce that any tool returning `structuredContent` must declare an `outputSchema`.

**Why now:** Spec-grade type contracts are a clean alignment with zigar's "evidence-labels" and "result-shape" disciplines. This is the protocol equivalent of zigar's existing `argument_error` discipline.

---

### P5 — Return heavy artifacts as `resource_link` content blocks

**Borrowed from:** [MCP spec content types](https://modelcontextprotocol.io/specification/2025-06-18/server/tools#content-types); the **puppeteer** archived server (screenshots returned as `screenshot://<name>` resources, console logs as `console://logs`); the `everything` reference server's mixed-content responses.

**Gap:** Zigar's heavy outputs (samply profiles, tracy traces, fuzz crash inputs, full SBOM JSON, coverage reports, large patch diffs) currently live inside response bodies or require an explicit artifact read. Even with the `result_shape` "compact" mode that omits big sections, the agent has to round-trip through `zigar_artifact_read` to get the content. The 2025-06-18 spec formalizes `resource_link` content blocks: a tool result can include a `{type: "resource_link", uri: "zigar://artifacts/sha256-...", name, description, mimeType}` block that the client fetches on demand and may combine with zigar's existing resource subscriptions for live update notification.

**Sketch:** Zigar already exposes a workspace-local artifact registry and already routes resource templates and subscriptions. Add a `zigar://artifacts/{sha}` URI template and refactor a handful of heavy-output tools (`zig_samply_record`, `zig_tracy_capture`, `zig_flamegraph`, `zig_sbom`, `zig_coverage_run`, `zig_fuzz_corpus_summary`, `zigar_patch_session_preview` when the diff is large) to return `resource_link` blocks pointing to the registry. Combined with `resources/subscribe`, this gives agents a way to live-tail a long build's log stream instead of polling.

**Why now:** Zigar already has the registry. The only missing piece is the URI template + content-block emission. Big token-cost win on every long-running invocation.

---

### P6 — Add `zig_pkg_search` / `zig_pkg_info` / `zig_pkg_readme` / `zig_pkg_versions`

**Borrowed from:** [joshrotenberg/cratesio-mcp](https://github.com/joshrotenberg/cratesio-mcp) (23 tools, the most complete registry-MCP in any ecosystem); the upcoming **pkg.go.dev MCP** ([golang/go#76718](https://github.com/golang/go/issues/76718)); fpt/go-dev-mcp's `search_godoc`.

**Gap:** Zigar has rich tools for what's already in `build.zig.zon` (`zig_dependency_inspect`, `_impact`, `_security_report`, `_provenance`, `_license_summary`, `_lock_audit`). It has **no way to discover** what's available before adding it — no search, no version listing, no README preview. The Zig package ecosystem is decentralized (URL + hash), but indexes exist (e.g. zigistry, zig.community lists, GitHub topic search). Whatever index the user trusts, zigar should be able to wrap it.

**Sketch:** Add a new tool group `package_registry` with:
- `zig_pkg_search(query, registry?)` → ranked list of `{name, repo_url, latest_version, description, downloads?}`
- `zig_pkg_info(name|repo_url, registry?)` → full metadata
- `zig_pkg_versions(name|repo_url, registry?)` → semver list + tag-to-sha map
- `zig_pkg_readme(name|repo_url, version?)` → markdown body
- `zig_pkg_docs(name|repo_url, version?, query?)` → autodoc JSON consumption (closes the "third-party docs query" gap separately called out in the table)

Registries pluggable via env or `.zigar/profile.json`. Outputs include the URL+hash pair ready to drop into `build.zig.zon` — pairs naturally with P7.

**Why:** "I want to add an HTTP client" is a real user need that zigar cannot answer today. Every peer ecosystem has a registry-MCP; Zig should not be the outlier.

---

### P7 — Add `zig_deps_add` / `zig_deps_remove` / `zig_deps_upgrade` (apply-gated `build.zig.zon` mutators)

**Borrowed from:** [jbr/cargo-mcp](https://github.com/jbr/cargo-mcp) (`cargo_add`, `cargo_remove`, `cargo_update`); [dmclain/uv-mcp](https://github.com/dmclain/uv-mcp) (`uv_add`, `uv_remove`, `uv_sync`, `uv_lock`); [npm-helper-mcp](https://github.com/pinkpixel-dev/npm-helper-mcp) (`add_dependency`, `update_dependency`).

**Gap:** Zigar has `zig_dependency_update_plan` (plan only) and the full security/license/provenance suite, but **no tool that mutates `build.zig.zon`**. Agents have to fall back to raw text edits, which defeats the patch-session machinery and the architecture-guard discipline.

**Sketch:** Three tools, all preview-by-default and gated through the existing patch-session infrastructure:
- `zig_deps_add(name_or_url, version_or_ref, save_dev?, apply?)` — calls `zig fetch --save=…` style logic, emits the diff to `build.zig.zon`, threads through `zigar_patch_session_create/preview/apply`.
- `zig_deps_remove(name, apply?)` — symmetric.
- `zig_deps_upgrade(name?, target_version?, apply?)` — wraps `_update_plan` + apply.

Each returns a structured `before/after` `build.zig.zon` snippet and a `zigar://artifacts/{sha}` link to the full preview (P5).

**Why:** This is the most-cited missing-tool across every package-manager MCP I surveyed. Zigar's apply-gate discipline is the right place to add it — patch sessions get audit, revert, validation runs for free.

---

### P8 — Add `zig_watch` — long-running file-system monitor as an async job

**Borrowed from:** [bacon](https://dystroy.org/bacon/analyzers/) (Rust); [cargo-watch](https://crates.io/crates/cargo-watch) (Rust); [air](https://github.com/cosmtrek/air) (Go); [mcp-bun](https://github.com/carlosedp/mcp-bun) (`start-bun-server` + logs). Note: **none of these have been wrapped well as MCP servers in any ecosystem** — this is white space zigar can claim.

**Gap:** Zigar has `zigar_job_start`/`status`/`result`/`cancel` and `zigar_run_events` (cursored streaming), but no file-system watcher that emits build/test/lint deltas as a long-running job. Zig compile cycles are short — a tight watch loop is unusually valuable.

**Sketch:** `zigar_watch_start(globs, on=[build,test,zlint,zls_diagnostics], debounce_ms?)` → returns a `job_id` plus a `zigar://watch/{job}/events` resource URI. Reuses the async-job + cursored-result pattern zigar already ships. Each event is a structured `{ts, trigger_files[], result: {tool, structuredContent, summary?}}`. `zigar_watch_stop(job_id)` ends it. Pairs with `resources/subscribe` (P5) for true push notifications instead of polling.

**Why now:** Zigar already has every primitive (async jobs, cursors, structured outputs, optional sampling-based summaries from P2). The watcher itself is small. The result would leapfrog Rust and Go in MCP-native dev-loop ergonomics.

---

### P9 — Add `zig_comptime_view` — post-comptime expansion analogue

**Borrowed from:** `cargo expand` (Rust). Not wrapped as an MCP anywhere I found, but a well-known cargo subcommand. Zig's comptime is the language-idiom analogue of Rust macros.

**Gap:** Zigar can analyze imports, decls, error sets, public APIs — but it cannot show **what comptime produced**. For a generic instantiation, a `comptime` block, or an `inline for` loop, the materialized declarations and IR are invisible. This is a real friction point in Zig debugging: a type error inside a generic at a callsite often needs the reader to manually evaluate the comptime path.

**Sketch:** `zig_comptime_view(file, line, character)` (or `(symbol)`) → returns the post-comptime expansion for that call site or instantiation. Implementation paths:
- Cheap version: shell `zig build-obj -femit-llvm-ir` on a temp file and grep the symbol. Returns LLVM IR.
- Richer version: parser + comptime-evaluation walk in `domain/zig/` that emits a synthesized Zig source view of the materialized declaration. (Closer to `cargo expand`'s ergonomics.)

**Why:** Distinctive — no peer has it, and the Zig idiom genuinely needs it more than Rust needs `cargo expand`. Plays to zigar's "parser-backed" capability tier.

---

### P10 — Convert `zig_debug_plan` and `zigar_failure_fusion` to a sequential-thinking-style revisable planner

**Borrowed from:** Anthropic's [sequential-thinking](https://github.com/modelcontextprotocol/servers/tree/main/src/sequentialthinking) reference server (a single tool with revisable, branching thought-state: `thoughtNumber`, `totalThoughts`, `isRevision`, `revisesThought`, `branchFromThought`, `branchId`, `needsMoreThoughts`).

**Gap:** Zigar's planning tools (`zig_debug_plan`, `zig_crash_repro_plan`, `zigar_failure_fusion`, `zig_fuzz_plan`, `zigar_next_action`) are one-shot — they emit a plan and exit. For real debugging workflows (bisecting a fuzz crash, narrowing a sanitizer report, deciding which test to bisect next) the agent needs to **revise** earlier reasoning ("the sanitizer pointed at X but TSan disagrees; revise step 2"), **branch** ("try LLDB first; if that fails, try sanitizer-only"), and explicitly mark "needs more thoughts." A persistent revisable state is the right primitive.

**Sketch:** A `zigar_debug_session_*` family (or extend the existing patch-session pattern):
- `zigar_debug_session_create(failure_context)` → session id
- `zigar_debug_session_step(session_id, thought, thoughtNumber, totalThoughts, isRevision?, revisesThought?, branchFromThought?, branchId?, needsMoreThoughts?, suggested_tool?, suggested_args?)` — same shape as Anthropic's primitive but specialized: each step can suggest a zigar tool to invoke next, and the tool result is folded into the session state.
- `zigar_debug_session_view(session_id)` → full trace + branches.
- `zigar_debug_session_close(session_id, outcome)` → archive as a decision-record artifact (composes with `zigar_decision_record`).

**Why:** Debug planning is exactly the workload sequential-thinking was designed for. Zigar's decision-record + artifact-registry + project-memory machinery means the session outcome lands in long-term project memory automatically — something no peer combination can match.

---

## 4. Honorable Mentions (not in the top 10)

Things worth tracking but not yet worth proposing:

- **PR / GitHub-MCP composition.** Don't duplicate [github-mcp-server](https://github.com/github/github-mcp-server)'s 105+ tools. Instead, make zigar's `zig_release_*` outputs (release-notes markdown, evidence packs, API-diff JSON) shaped for direct consumption by the GitHub MCP. A thin `zigar_release_open_pr_plan` that returns the structured payload ready for `create_pull_request` is the right scope.
- **Scaffold / `zigar_scaffold_new`.** Useful (`uv_init`, `cargo new`, Next.js `init` analogs), but Zig project topology varies enough that a template registry is a project of its own. Worth doing after P6/P7 land.
- **REPL / scratch eval (`zigar_scratch_eval`).** Real value for "what does this snippet do" workflows; ergonomic shape unclear (write temp file → build-run → capture? real REPL? Wasm-eval?). Park until requested.
- **`tools/list` cursor pagination.** Cursor pagination is already part of the server baseline. Keep it covered while adding output schemas, since `outputSchema` could otherwise increase first-turn payload size.
- **`go_package_api` style "exported contract only" view for Zig modules.** Closest existing tool is `zig_public_api`; the gap is "get the exported contract of a third-party dep without reading source." Lands once P6 (`zig_pkg_docs`) is in place.
- **Live config introspection** (`zigar_build_config` returning resolved `build.zig` graph, targets, options, deps). Astro-mcp and Vite plugins both ship this; zigar has `zig_build_options/_targets/_graph` separately but a fused view is missing.

---

## 5. What Zigar Already Leads On

For honesty in the comparison: in the peer scan, nothing matched zigar's combined coverage of —

- coverage **baselines + budgets + diff + merge** (no peer has all four);
- benchmark **baselines + history + compare + regression** (cratesio has `bench` only; cargo-mcp has `cargo_bench` only);
- the **fuzz quartet** (afl + libfuzzer + crash-minimize + corpus-summary);
- **sanitizer + panic-trace + crash-repro fusion** as orchestrated tools;
- **public-API baseline / check / diff / docs-diff** with versioning implications;
- **release plan + notes + evidence pack** as a pipeline;
- **transactional patch sessions** with preview/apply/revert/validate;
- **artifact registry** with SHA-256 provenance;
- **environment profile** import/export/diff/validate with `.zigar/profile.json` schema;
- **embedded / microzig / flash** workflows;
- **architecture-guard / no-patch-MCP / release-check** invariants enforced as code.

Adopting P1–P10 lifts zigar from "leads on depth, trails on protocol surface and onboarding" to "leads on both."

---

## 6. Attribution Index

| Proposal | Primary inspiration | Secondary |
|---|---|---|
| P1 elicitation/create | [MCP 2025-06-18 spec](https://modelcontextprotocol.io/specification/2025-06-18/client/elicitation) | `everything` ref server; Memgraph blog |
| P2 sampling/createMessage | [MCP sampling spec](https://modelcontextprotocol.io/specification/2025-06-18/client/sampling) | `everything` ref server |
| P3 completion/complete | [MCP completion spec](https://modelcontextprotocol.io/specification/2025-06-18/server/utilities/completion) | `everything` ref server |
| P4 outputSchema + structuredContent | [MCP 2025-06-18 tools spec](https://modelcontextprotocol.io/specification/2025-06-18/server/tools) | `everything` ref server |
| P5 resource_link content blocks | [MCP content types](https://modelcontextprotocol.io/specification/2025-06-18/server/tools#content-types) | puppeteer-archived; `everything` |
| P6 package registry browse | [joshrotenberg/cratesio-mcp](https://github.com/joshrotenberg/cratesio-mcp) | pkg.go.dev MCP; fpt/go-dev-mcp |
| P7 deps add/remove/upgrade | [jbr/cargo-mcp](https://github.com/jbr/cargo-mcp) | [dmclain/uv-mcp](https://github.com/dmclain/uv-mcp); npm-helper-mcp |
| P8 zig_watch | [bacon](https://dystroy.org/bacon/analyzers/), cargo-watch, air | [mcp-bun](https://github.com/carlosedp/mcp-bun) lifecycle pattern |
| P9 comptime view | `cargo expand` (Rust idiom) | n/a |
| P10 revisable debug planner | [sequential-thinking](https://github.com/modelcontextprotocol/servers/tree/main/src/sequentialthinking) | zigar `zigar_decision_record` for archival |

---

## 7. TL;DR

The biggest single win is **deepening the MCP protocol features zigar has not finished yet** (P1-P5): declared output schemas, artifact resource links, manifest-backed completions, elicitation, and sampling. They're substrate, not tools — they upgrade everything at once. After that, **package-management mutation + registry browse** (P6-P7) closes the most-cited capability gap. **Watch / hot-reload** (P8) is open white space across every peer ecosystem. **Comptime view** (P9) is a distinctive language-idiom-fit no one else has. **Revisable debug planner** (P10) layers naturally onto zigar's decision-record + memory infrastructure.
