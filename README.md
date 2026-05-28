# zigars

`zigars` is a deterministic Zig MCP workbench, not an AI code generator. It
gives MCP-capable agents such as Codex, Claude, Gemini CLI, and Hermes
structured Zig evidence: compiler commands, formatting, ZLS code intelligence,
parser-backed facts, local docs lookup, static-analysis summaries,
transactional edit/refactor previews, optional backend evidence, and
runtime/test/performance workflow helpers.

Shell can run `zig build`. zigars adds structured diagnostics, command metadata,
parser-backed facts, ZLS-backed code intelligence, preview diffs, confidence
labels, and next verification steps so agents do not have to infer everything
from shell text. Shell, the Zig compiler, project tests, CI, and external
backends remain the source of truth for the behavior they execute. See
[docs/why-zigars.md](docs/why-zigars.md).

## Quickstart

The fastest MCP client path is the npm shim. Bun is the preferred launcher:

```sh
bunx --bun @zigars/mcp@0.2.0 --workspace /absolute/path/to/zig/project
```

Node/npm remains a supported launcher:

```sh
npx -y @zigars/mcp@0.2.0 --workspace /absolute/path/to/zig/project
```

Minimum prerequisites:

- Bun 1.3 or newer, or Node.js 18 or newer with npm/npx, Yarn dlx, or pnpm dlx
- Zig `0.16.0` available on `PATH` or passed with `--zig-path`
- A supported host release asset: Linux x64/arm64, macOS x64/arm64, or Windows
  x64/arm64
- An MCP client that can launch a stdio server

The npm package is named `@zigars/mcp`; the project, binary, and MCP server are
named `zigars`. The shim downloads the matching GitHub release archive, verifies
it against `zigars-checksums.txt`, caches the extracted binary, and runs zigars
as a local stdio MCP server. The shim does not verify npm attestations.

Common MCP JSON shape:

```json
{
  "mcpServers": {
    "zigars": {
      "command": "bunx",
      "args": [
        "--bun",
        "@zigars/mcp@0.2.0",
        "--workspace",
        "/absolute/path/to/zig/project"
      ]
    }
  }
}
```

Codex uses TOML:

```toml
[mcp_servers.zigars]
command = "bunx"
args = [
  "--bun",
  "@zigars/mcp@0.2.0",
  "--workspace",
  "/absolute/path/to/zig/project"
]
startup_timeout_sec = 20.0
```

## First Five Minutes

After startup, make these first calls from the MCP client. If your project does
not have `src/main.zig`, substitute an existing workspace-relative Zig file.

```text
zigars_workspace_info
zigars_doctor {"probe_backends":false}
zig_ast_imports {"file":"src/main.zig"}
zig_format {"file":"src/main.zig","apply":false}
zigars_trust_report
resources/read {"uri":"zigars://trust/manifest"}
```

This verifies the served workspace, basic server health without optional backend
probes, one parser-backed read-only insight, the preview-first source-write
gate, the process trust posture, and the connection-time trust manifest linked
from MCP `initialize`. The guided walkthrough is
[docs/getting-started.md](docs/getting-started.md).

## Thin CLI Mode

MCP remains the primary agent surface, but the `zigars` binary also has an
explicit thin JSON CLI for CI, release bots, and shell-only checks:

```sh
zigars cli workspace-info --workspace /absolute/path/to/zig/project --json
zigars cli doctor --workspace /absolute/path/to/zig/project --probe-backends=false --json
```

Successful CLI command output is stable machine JSON on stdout using the same
structured object shapes as the corresponding MCP tool results. Diagnostics go
to stderr. The CLI is a reporting surface over existing use cases; generated
artifacts and CLI JSON are the non-MCP integration path, while a public Zig
library API remains deferred. See [docs/cli.md](docs/cli.md) for exit codes and
the follow-up command list.

## How To Trust A Result

Public feature claims use evidence labels instead of broad precision claims:
command-backed, LSP/ZLS-backed, parser-backed, source-scan-backed,
heuristic/advisory, external-backend-backed, curated fallback, and real
conformance artifact. The short reference is
[docs/evidence-tiers.md](docs/evidence-tiers.md); the full tool-surface
discussion is [docs/tools.md](docs/tools.md).

## Trust Boundary

No LLM calls run inside zigars server tools. Source writes are preview-first and
require `apply=true`. Command-backed tools execute argv vectors directly,
without a shell. The workspace is the primary safety boundary; zigars is not an
OS sandbox, and project commands or optional backends run with the local user's
privileges. MCP `initialize` links `zigars://trust/manifest`, a JSON resource
that summarizes these policies, configured backend identities, output limits,
HTTP posture, checksum posture, and current limitations. See
[docs/trust.md](docs/trust.md) and
[docs/determinism.md](docs/determinism.md).

## Install Alternatives

Yarn and pnpm work when the `zigars-mcp` binary is named explicitly:

```sh
yarn dlx -p @zigars/mcp@0.2.0 zigars-mcp --workspace /absolute/path/to/zig/project
pnpm dlx --package @zigars/mcp@0.2.0 zigars-mcp --workspace /absolute/path/to/zig/project
```

For npm-specific caching, troubleshooting, local publish testing, and Claude
Desktop/MCPB notes, see
[packages/zigars-mcp-npm/README.md](packages/zigars-mcp-npm/README.md).

## Optional zigars Skills

Zigars-aware agent skills are shipped separately as `@zigars/skills`. They do not
start the MCP server or change MCP configuration; they provide client-side
workflow guidance for using zigars effectively.

```sh
npx -y @zigars/skills@0.2.0 list
npx -y @zigars/skills@0.2.0 path zigars-development
```

The first maintained skill is `zigars-development`, which dogfoods zigars while
developing this repo. See [docs/dogfooding.md](docs/dogfooding.md).

## Quickstart with Claude Desktop MCPB

Claude Desktop users can install a release `.mcpb` bundle and choose the Zig
workspace directory during installation. Download the bundle for your platform
from the matching GitHub release:

```text
zigars-darwin-universal.mcpb
zigars-linux-x64.mcpb
zigars-windows-x64.mcpb
```

The MCPB path bundles the zigars server binary directly and runs it with
`--transport stdio --workspace <configured directory>`. It still requires Zig
`0.16.0` on `PATH`; optional backends such as ZLS can be configured through the
npm shim or a direct binary setup when needed.

## Status

`zigars` is ready for public use with Zig 0.16.0 over stdio and local HTTP MCP
transports. Major feature areas are documented against the clean A rubric in
[docs/maturity.md](docs/maturity.md), and the release-facing trust checklist is
kept in [docs/trust.md](docs/trust.md). A release should claim clean A only from
a clean-tree `Release Readiness` evidence package for the exact tagged commit.
The current package version is `0.2.0`; see [CHANGELOG.md](CHANGELOG.md).

Known limitations:

- `mcp.zig` is consumed as a pinned URL dependency without local patches.
  `zig-pkg/` is a local cache/artifact directory and is ignored.
- ZLS, ZLint, zwanzig, zflame, and diff-folded are optional runtime backends. Tools
  that need a missing backend return an explicit error, and public real-backend
  claims come from generated conformance evidence.
- Docs lookup is scoped lookup over installed source, installed langref HTML, or
  curated fallback data. It is not a complete rendered documentation browser.
- Static-analysis and agent-workflow tools expose confidence, limitations, and
  verification fields. Heuristic/advisory outputs are routing aids; release
  decisions still need parser-backed, command-backed, ZLS, optional linter
  backend, or CI evidence.
- `zig_junit` reports command-level JUnit because Zig does not expose a stable
  per-test event stream for every invocation.
- Coverage, benchmark, profiling, and runtime diagnostic tools normalize
  supplied evidence and record artifact hashes; command-backed capture,
  debugger, memory, fuzz, emulator, or benchmark runs execute only with
  `apply=true`, and capture correctness belongs to the selected external
  backend.

## Requirements

- Zig `0.16.0`
- An MCP client that supports stdio servers
- Optional: `zls` `0.16.0` for language-server-backed tools
- Optional: `zlint` for ZLint-backed diagnostics, AST reference evidence,
  apply-gated fixes, rules when exposed by the installed binary, and SARIF
  conversion
- Optional: `zwanzig` for linting/static-analysis backend tools
- Optional: `zflame` and `diff-folded` for flamegraphs and flamegraph diffs
- Optional: `samply` and `tracy-capture` for apply-gated profiler captures,
  passed per tool call with `samply_path` or `tracy_capture_path`
- Optional: `lldb`, `heaptrack`, `valgrind`, AFL++ `afl-fuzz`, LLVM binary
  tools, QEMU, and flash tools for apply-gated runtime diagnostic workflows,
  passed per tool call with the matching path argument when needed

Optional backend setup, verification commands, and failure triage are documented
in [docs/backends.md](docs/backends.md). Cataloged backend setup for Zig, ZLS,
ZLint, zwanzig, zflame, and diff-folded is available at runtime through
`zigars_backend_catalog` and in `zigars_schema` under `backend_setup`; profiler
and runtime diagnostic backend paths are supplied per tool call.
Release candidates that claim real optional-backend coverage should also run the
manual `Release Readiness` workflow with the exact backend versions, clean-tree
source metadata, and generated backend compatibility matrix. Maintainers can use
the repo-pinned setup in `tools/real_backend_pins.json` through
`.github/scripts/setup-real-backends.sh`.

## Install

Fast MCP client install through Bun:

```sh
bunx --bun @zigars/mcp@0.2.0 --workspace /absolute/path/to/zig/project
```

Node/npm is still supported:

```sh
npx -y @zigars/mcp@0.2.0 --workspace /absolute/path/to/zig/project
```

Yarn and pnpm launch forms:

```sh
yarn dlx -p @zigars/mcp@0.2.0 zigars-mcp --workspace /absolute/path/to/zig/project
pnpm dlx --package @zigars/mcp@0.2.0 zigars-mcp --workspace /absolute/path/to/zig/project
```

For repeatable client configuration, pin the package version as shown above.
If you want a locally installed command instead:

```sh
npm install -g @zigars/mcp@0.2.0
pnpm add -g @zigars/mcp@0.2.0
zigars-mcp --workspace /absolute/path/to/zig/project
```

Build from source:

```sh
git clone https://github.com/oly-wan-kenobi/zigars.git
cd zigars
zig build -Doptimize=ReleaseSafe
install -m 0755 zig-out/bin/zigars ~/.local/bin/zigars
zigars --version
```

Published archives are available from
[GitHub Releases](https://github.com/oly-wan-kenobi/zigars/releases). Download
the archive for your platform, verify its SHA-256 against `zigars-checksums.txt`,
and put `zigars` on `PATH`. The initial `v0.1.0` release was built and verified
locally while GitHub Actions were unavailable; its release notes list the source
commit and local gates. Tag-workflow releases attach GitHub provenance
attestations generated from the checksum file when GitHub supports attestations
for the repository. The npm shim currently verifies SHA-256 checksums only; npm
attestation verification is not implemented.

Published release archives are named:

```text
zigars-x86_64-linux-gnu.tar.gz
zigars-aarch64-linux-gnu.tar.gz
zigars-x86_64-linux-musl.tar.gz
zigars-aarch64-linux-musl.tar.gz
zigars-x86_64-macos.tar.gz
zigars-aarch64-macos.tar.gz
zigars-x86_64-windows-gnu.tar.gz
zigars-aarch64-windows-gnu.tar.gz
```

The npm shim uses these same archive names for host detection, with Linux x64
and arm64 hosts deliberately mapped to the musl archives because Node and Bun do
not expose libc ABI consistently. GNU Linux archives remain available for direct
downloads and CI jobs that explicitly need glibc ABI. If a package version is
published before the matching `v<version>` GitHub release assets and
`zigars-checksums.txt` are available, startup fails with a download or checksum
error.

Claude Desktop MCPB bundles are published from those same release binaries:

```text
zigars-darwin-universal.mcpb
zigars-linux-x64.mcpb
zigars-windows-x64.mcpb
zigars-mcpb-checksums.txt
```

The macOS MCPB contains a universal binary. The Linux and Windows MCPB bundles
currently contain x86_64 binaries because MCPB compatibility metadata supports
OS platform selectors but not CPU architecture selectors. Linux arm64 users can
use the npm shim or direct `zigars-aarch64-linux-musl.tar.gz` archive; Windows
arm64 users can use the npm shim or direct `zigars-aarch64-windows-gnu.tar.gz`
archive.

## Build

```sh
zig build test
zig build -Doptimize=ReleaseSafe
```

The binary is written to:

```text
zig-out/bin/zigars
```

`zig build release-check` is the adoption gate: it runs formatting, generated
docs/JSON checks, unit tests, ReleaseSafe compilation, HTTP and stdio MCP smoke
fixtures, kcov line coverage floors, fake-backend conformance report-contract
smoke, artifact hygiene, structured error-contract scans, trust/maturity docs
checks, MCP public-surface contract checks, static/docs maturity guards, and
line-budget headroom checks.

`zig build test` includes unit coverage for executable startup helpers, CLI
parsing, workspace sandboxing, command parsing, JSON serialization, diagnostics
retention, source-write gating, symlink escape rejection, command output-limit
metadata, ZLS timeout/EOF behavior, a fake-ZLS LSP roundtrip, and the Zig helper
used by release checks.

Integration and coverage helpers are available as build steps:

```sh
zig build smoke
zig build stdio-fixtures
zig build backend-conformance-contract
zig build coverage
zig build test --fuzz=10K
zig build dist release-asset-smoke
```

`zig build coverage` requires `kcov` on `PATH` and writes
`coverage/summary.json` with the installed library, executable, and tooling test
binary results, per-suite floors, Cobertura-derived line coverage, per-file
uncovered lines, tracked files missing from Cobertura, and the configured
coverage floors. The default local release gate fails when kcov cannot measure
project source coverage, any tracked `src/` or `tools/` Zig file is missing from
the report, or total, `src/`, or `tools/` coverage drops below the configured
floors in `tools/coverage_config.zig`.

`zig build dist` creates ReleaseSafe archives and `zigars-checksums.txt` under
`dist/assets`. `zig build release-asset-smoke` verifies checksums, archive
contents, and the native archive's `zigars --version` behavior.

MCPB release bundles are built after `zig build dist`:

```sh
npm --prefix packages/zigars-mcpb ci
npm --prefix packages/zigars-mcpb run pack
```

That TypeScript package supports npm/Node and Bun. The npm path compiles
`src/build.ts` before running; Bun can run the same source with
`bun run --cwd packages/zigars-mcpb pack:bun`. The command stages the bundled
server, validates each `manifest.json` with the MCPB CLI, packs `.mcpb` files,
runs `mcpb info`, and writes
`dist/assets/zigars-mcpb-checksums.txt` for registry `fileSha256` values.

## Run

```sh
zig-out/bin/zigars --workspace /path/to/zig/project --transport stdio
```

Options:

```text
--workspace <path>
--zig-path <path>
--zls-path <path>
--zlint-path <path>
--zwanzig-path <path>
--zflame-path <path>
--diff-folded-path <path>
--transport stdio|http
--host 127.0.0.1
--port 8080
--cache-dir <path>
--timeout-ms <n>
--zls-timeout-ms <n>
```

Use `--transport stdio` for local agent clients. `--transport http` is available
only as a loopback endpoint for clients or wrappers that need local HTTP.

## Agent Client Configuration

Zigars works with any MCP client that can launch a local stdio server. Client
config shapes vary. For the npm path, prefer `bunx --bun` with
`@zigars/mcp@0.2.0`; `npx -y` remains the Node/npm fallback. For a direct binary
install, use an absolute `command`. Pin `--workspace` unless the client starts
servers from the active project directory. The npm shim adds `--transport stdio`
automatically unless you pass a transport yourself.

For Claude, Gemini CLI, Hermes, and generic client guidance, see
[docs/agent-clients.md](docs/agent-clients.md).

Use `zigars_client_config_generate` when you want zigars to preview a client
configuration artifact with preimage, hash, and provenance metadata. Use
`zigars_adoption_pack`, `zigars_smoke_plan`, and `zigars_conformance_report` to
package observed setup evidence, client smoke scenarios, and conservative
public support claims before recommending a client/backend profile.

### Codex

Add a server entry to `~/.codex/config.toml` using Bun:

```toml
[mcp_servers.zigars]
command = "bunx"
args = [
  "--bun",
  "@zigars/mcp@0.2.0",
  "--workspace",
  "/absolute/path/to/your/zig/project",
  "--zig-path",
  "/opt/homebrew/bin/zig",
  "--zls-path",
  "/opt/homebrew/bin/zls"
]
startup_timeout_sec = 20.0
```

Or use a direct binary:

```toml
[mcp_servers.zigars]
command = "/absolute/path/to/zigars"
args = [
  "--transport", "stdio",
  "--workspace", "/absolute/path/to/your/zig/project",
  "--zig-path", "/opt/homebrew/bin/zig",
  "--zls-path", "/opt/homebrew/bin/zls"
]
startup_timeout_sec = 10.0
```

For a global Codex configuration, omit `--workspace` only if your MCP client
starts servers with the active project as the process working directory. If a
tool returns a workspace sandbox error, call `zigars_workspace_info` to confirm
which project the server is actually serving.

For a single global Codex entry that serves the current project, keep the
workspace argument out of the global config and make sure Codex launches the MCP
server from the active workspace:

```toml
[mcp_servers.zigars]
command = "/absolute/path/to/zigars"
args = ["--transport", "stdio"]
startup_timeout_sec = 10.0
```

For a pinned workspace, include `--workspace` explicitly. This is safer for one
project, but it should not be reused across unrelated workspaces.

Useful project instruction:

```md
When working on Zig code, prefer the zigars MCP tools for Zig version/env,
build, check, test, formatting, ZLS diagnostics, symbols, references, docs,
static analysis, and profiling before falling back to direct shell commands.
Source writes require apply=true.
```

## Tool Groups

Public feature claims use evidence labels instead of broad precision claims:
command-backed tools run explicit `zig` argv, LSP-backed tools require a live
ZLS response for that call, parser-backed tools use `std.zig.Ast`, source-scan
tools search local files with provenance metadata, heuristic/advisory tools are
orientation aids, external-backend-backed tools report the backend executable
and probe metadata, and curated fallback means bundled partial data. Real
optional-backend support is claimed only from a release evidence artifact.

- Discovery/meta: `zigars_capabilities`, `zigars_tool_index`,
  `zigars_schema`, `zigars_backend_catalog`, `zigars_doctor`,
  `zigars_workspace_info`, `zigars_metrics`, `zigars_http_status`,
  `zig_command_plan`, `zig_tool_plan`, `zig_toolchain_resolve`
- Agent workflows: `zigars_context_pack`, `zigars_next_action`,
  `zigars_agent_guide`, `zigars_validate_patch`, `zigars_failure_fusion`,
  `zigars_impact`, `zigars_project_profile`, `zigars_patch_guard`,
  `zigars_validation_plan`, `zigars_validation_run`,
  `zigars_patch_session_create`, `zigars_patch_session_validate`
- Core Zig: `zig_version`, `zig_env`, `zig_targets`, `zig_build`, `zig_test`,
  `zig_check`, `zig_compile_error_index`, `zig_explain_errors`,
  `zig_translate_c`
- Formatting and transactional edits: `zig_format`, `zig_format_check`,
  `zig_patch_preview`, `zigars_patch_session_preview`,
  `zigars_patch_session_apply`, `zigars_patch_session_revert`, `zig_move_decl`,
  `zig_extract_decl`, `zig_update_imports`, `zig_organize_imports`,
  `zig_code_action_batch`
- ZLS intelligence: `zig_diagnostics`, `zig_diagnostics_all`,
  `zig_diagnostics_workspace`, `zig_hover`, `zig_definition`,
  `zig_references`, `zig_completion`, `zig_signature_help`,
  `zig_document_symbols`, `zig_workspace_symbols`
- ZLS edits/session: `zig_rename`, `zig_code_actions`,
  `zig_code_action_apply`, `zig_document_open`, `zig_document_change`,
  `zig_document_close`, `zig_document_status`
- Docs: `zig_builtin_list`, `zig_builtin_doc`, `zig_builtin_list_json`,
  `zig_std_search`, `zig_std_search_json`, `zig_std_item`,
  `zig_lang_ref_search` for language-reference sections
- Static analysis: `zig_import_graph`, `zig_import_graph_json`,
  `zig_ast_imports`,
  `zig_decl_summary`, `zig_decl_summary_json`, `zig_allocations`,
  `zig_ast_decl_summary`,
  `zig_error_sets`, `zig_public_api`, `zig_dead_decl_candidates`,
  `zig_build_graph`, `zig_build_targets`, `zig_build_options`,
  `zig_file_owner`, `zig_import_resolve`, `zig_test_discover`,
  `zig_ast_tests`,
  `zig_test_map`, `zig_test_select`, `zig_public_api_diff`,
  `zig_changed_files_plan`, `zig_dependency_inspect`,
  `zig_target_matrix_plan`, `zig_test_failure_triage`,
  `zig_workspace_symbol_cache`, `zig_package_cache_doctor`,
  `zig_semantic_index_build`, `zig_semantic_index_status`,
  `zig_semantic_index_refresh`, `zig_semantic_query`, `zig_semantic_refs`,
  `zig_semantic_decl`, `zig_semantic_callers`, `zig_static_fusion`,
  `zig_code_index_export`, `zig_scip_export`
  (results carry capability tiers, confidence, limitations, and verification
  guidance; fast heuristic tools are `advisory_orientation`, AST variants are
  `parser_backed`; semantic index exports are preview-first workspace artifacts)
- CI/test artifacts: `zig_ci_annotations`, `zig_junit`, `zig_matrix_check`
  (annotations expose parser confidence and raw output; JUnit is explicitly
  command-level; matrix entries expose direct status fields)
- ZLint: `zig_zlint`, `zig_zlint_sarif`, `zig_zlint_rules`, `zig_zlint_fix`
  (`zlint_backed`, optional), plus normalized lint intelligence tools
  `zig_lint_compare`, `zig_lint_profile`, `zig_lint_gate`, `zig_lint_fix_plan`,
  `zig_lint_baseline`, `zig_lint_suppressions`, and `zig_lint_trend`
- zwanzig: `zig_lint`, `zig_lint_sarif`, `zig_lint_rules`,
  `zig_analysis_graphs` (`zwanzig_backed`, optional)
- Profiling/zflame: `zig_profile_plan` returns structured external-capture
  plans for `perf`, macOS `sample`/`xctrace`, DTrace, VTune, and already-folded
  stacks; `zig_profile_run` runs an explicit user-provided argv command
  without a shell, with the workspace as cwd; `zig_flamegraph` and `zig_flamegraph_diff`
  render through zflame and diff-folded with artifact metadata.
  `zig_profile_run` can execute project code and create normal build/profile
  artifacts. zigars does not own profiler capture semantics.
- Coverage/performance workflows: `zig_coverage_run`, `zig_coverage_map`,
  `zig_coverage_merge`, `zig_coverage_diff`, `zig_coverage_baseline`, and
  `zig_coverage_budget_check` normalize LCOV or zigars JSON evidence and check
  line-rate budgets; `zig_bench_discover`, `zig_bench_run`,
  `zig_bench_baseline`, `zig_benchmark_history`, `zig_bench_compare`,
  `zig_perf_budget_check`, and `zig_profile_regression` discover benchmark
  commands, normalize timing evidence, compare baselines, and plan focused
  profiling; `zig_samply_record`, `zig_samply_summary`, `zig_samply_import`,
  `zig_samply_artifact`, `zig_profile_open`, `zig_tracy_plan`,
  `zig_tracy_probe`, `zig_tracy_capture`, `zig_tracy_artifacts`,
  `zig_tracy_hints`, and `zig_perf_evidence_pack` expose apply-gated profile
  capture, import, artifact registration, and evidence bundles. `zig_coverage_run`,
  `zig_bench_run`, `zig_samply_record`, and `zig_tracy_capture` can execute
  project code or external profiler commands, always without a shell and with
  preview-first artifact writes.
- Runtime diagnostics: `zig_debug_plan`, `zig_lldb_backtrace`,
  `zig_core_inspect`, `zig_debug_frame_summary`, `zig_sanitizer_fusion`,
  `zig_panic_trace_analyze`, `zig_crash_repro_plan`, `zig_heaptrack_run`,
  `zig_heaptrack_summary`, `zig_valgrind_memcheck`, `zig_callgrind_report`,
  `zig_fuzz_plan`, `zig_afl_run`, `zig_libfuzzer_run`,
  `zig_fuzz_crash_minimize`, `zig_fuzz_corpus_summary`, `zig_binary_size`,
  `zig_binary_size_diff`, `zig_objdump_summary`, `zig_dwarfdump_check`,
  `zig_symbolize`, `zig_qemu_test`, `zig_cross_smoke`,
  `zig_target_runtime_plan`, `zig_embedded_detect`, `zig_microzig_plan`,
  `zig_board_profile`, and `zig_flash_plan` cover debugger planning, crash
  fusion, optional memory/fuzz backends, binary inspection, emulator smoke
  planning, and embedded/flash workflow guidance. Command-running variants are
  preview-first, run without a shell, and keep external debugger, fuzzer,
  emulator, and flash semantics with the selected backend.
- Artifact registry: `zigars_artifact_index`, `zigars_artifact_read`, and
  `zigars_artifact_prune` expose workspace-local generated artifacts, bounded
  hashes, provenance records, and apply-gated registry cleanup. Pruning removes
  stale registry entries only; it does not delete generated files.
- Observability: `zigars_metrics_v2`, `zigars_backend_health_history`,
  `zigars_zls_timeline`, and `zigars_tool_latency` report in-process counters,
  backend probe history, ZLS status transitions, artifact counts, command
  durations observed by shared helpers, and per-tool dispatch latency.
- Trust and safety: `zigars_trust_report`, `zigars_command_provenance`,
  `zigars_risk_audit`, `zigars_clean_tree_gate`, `zig_generated_file_trace`,
  `zigars_edit_policy_check`, and `zigars_generated_route` summarize path policy,
  generated/vendor edit routing, backend identities, dependency hashes, manifest
  risk flags, and clean-tree evidence without broadening zigars' sandbox
  boundary.
- Result contracts and release drift: `zigars_result_shape` and
  `zigars_output_budget_plan` describe compact, standard, and deep output modes
  with explicit omissions; `zigars_docs_drift_check`,
  `zigars_release_claim_check`, and `zigars_tool_index_check` provide fast
  public-doc and generated-index drift checks before running the full release
  gate.
- Public adoption: `zigars_adoption_pack`, `zigars_client_config_generate`,
  `zigars_smoke_plan`, and `zigars_conformance_report` package client setup
  evidence, preview/apply-gated config artifacts, transport smoke scenarios,
  and conservative conformance claims without installing tools or claiming
  unobserved optional-backend support.

Standard MCP `tools/list` publishes each registered argument schema with
properties, required fields, defaults, enums, and path hints. `zigars_schema`
complements that with compact grouping, risk, planning, discovery keywords, and
backend setup metadata.

The server imports the pinned upstream `mcp.zig` package directly for protocol
types, JSON-RPC helpers, content/resource/prompt types, and transport
primitives. zigars' first-party MCP adapter owns request routing and releases
owned `tools/call`, `resources/read`, and `prompts/get` results after JSON-RPC
responses are serialized, so no patched upstream MCP server is part of the
build.

The generated index in [docs/tool-index.generated.md](docs/tool-index.generated.md)
is built from `src/manifest/tool_catalog.json` plus the typed registry metadata and
checked in CI.

For agent workflows, see [docs/agent-workflows.md](docs/agent-workflows.md).
The short version is: start with `zigars_context_pack`, ask
`zigars_agent_guide` for the client profile, route uncertain work through
`zigars_next_action`, and finish with `zigars_validate_patch`.

## Safety Model

- Every input and output path is resolved under the canonical `--workspace`.
- Existing input paths, existing output paths, and the nearest existing output
  parent are realpathed. Symlinks are supported only when the real target stays
  inside the workspace; symlink escapes are rejected.
- Source writes require `apply=true`.
- Formatting, patch-session, refactor, and rename tools return previews/diffs by
  default.
- Patch sessions record file preimage hashes and refuse apply when current files
  no longer match the previewed preimages.
- Generated, cache, artifact, and vendored paths are classified separately so
  agents can route changes to source inputs or regeneration commands.
- Build, test, coverage, benchmark, profiling, and runtime diagnostic commands
  run with the workspace as cwd.
- `zigars_schema` includes finer-grained tool risk metadata for source writes,
  artifact writes, LSP state mutation, backend execution, project-code
  execution, and user-command execution.
- MCP `readOnlyHint` is a client UI hint; zigars risk fields are the source of
  truth for command execution and artifact-write behavior.
- stdout is reserved for MCP JSON-RPC. Logs, help, version, and startup errors
  go to stderr.
- Audit JSONL is opt-in with `--audit-log <workspace-path>`. Enabled audit
  logging defaults to metadata mode; `--audit-log-mode full` must be explicit
  because it records raw MCP payloads and emits a stderr privacy warning. Runtime
  timings, latency samples, and cancellation counters are summarized in
  [docs/perf.md](docs/perf.md).
- zwanzig graph output, zflame SVG output, diff folded intermediates, coverage
  baselines, benchmark baselines, profile captures, performance evidence packs,
  and runtime diagnostic evidence artifacts must use workspace-local output
  paths. `zig_flamegraph` requires an explicit zflame format; there is no
  `guess` default.

More detail:

- [Getting started](docs/getting-started.md): the first-five-minutes path and
  what each verification call proves.
- [Why zigars](docs/why-zigars.md): shell versus structured Zig evidence.
- [Evidence tiers](docs/evidence-tiers.md) and
  [determinism contract](docs/determinism.md): result labels, stable fields,
  runtime-specific fields, and non-contracts.
- [Agent clients](docs/agent-clients.md): Codex, Claude, Gemini CLI, Hermes, and
  generic MCP client setup.
- [Codex setup](docs/codex.md): focused Codex stdio configuration, first calls,
  and health checks.
- [Agent workflows](docs/agent-workflows.md): context, planning, validation, and
  failure-triage loops for MCP clients.
- [Tool discovery](docs/tools.md) and
  [generated tool index](docs/tool-index.generated.md): schema, risk, planning,
  and keyword metadata for every registered tool.
- [Architecture notes](docs/architecture.md): module boundaries, manifest rules,
  and handler contracts.
- [Optional backends](docs/backends.md): ZLS, ZLint, zwanzig, zflame,
  diff-folded, Samply, and Tracy setup.
- [Runtime observability](docs/perf.md): audit JSONL modes, cancellation
  counters, startup timings, and latency samples.
- [Testing and coverage](docs/testing.md): local gates, smoke fixtures, kcov
  coverage, and release assets.
- [Feature maturity](docs/maturity.md): public-readiness rubric,
  reassessment, evidence, and known product boundaries.
- [Public trust checklist](docs/trust.md): release guarantees, local gates,
  and external validation that cannot be inferred from the repository alone.
- [Security policy](SECURITY.md), [security model](docs/security-model.md), and
  [security readiness audit](docs/security-audit.md): private vulnerability
  reporting, workspace boundaries, and remaining security posture.
- [Troubleshooting](docs/troubleshooting.md): common workspace, backend, and
  argument issues.
- [Release checklist](docs/release.md): publication gates and archive
  verification.

## Troubleshooting

### npm shim cannot download a release asset

The package downloads from:

```text
https://github.com/oly-wan-kenobi/zigars/releases/download/v0.2.0/
```

Confirm the release has `zigars-checksums.txt` and the archive for your host:

```text
zigars-x86_64-linux-gnu.tar.gz
zigars-aarch64-linux-gnu.tar.gz
zigars-x86_64-linux-musl.tar.gz
zigars-aarch64-linux-musl.tar.gz
zigars-x86_64-macos.tar.gz
zigars-aarch64-macos.tar.gz
zigars-x86_64-windows-gnu.tar.gz
zigars-aarch64-windows-gnu.tar.gz
```

If assets are missing, publish the GitHub release assets first or use a direct
source build.

### Unsupported platform

`@zigars/mcp` currently supports Linux x64/arm64, macOS x64/arm64, and Windows
x64/arm64. Linux hosts use the musl archives by default; choose GNU Linux
archives manually if you need glibc ABI. Other hosts fail with
`Unsupported zigars host target: <platform>/<arch>`. Build from source or use a
supported machine until a release asset exists for that target.

### Checksum mismatch or missing checksum

Delete the cached install and retry only after confirming the release asset and
`zigars-checksums.txt` were produced from the same build:

```sh
rm -rf ~/.cache/zigars-mcp/0.2.0
rm -rf ~/Library/Caches/zigars-mcp/0.2.0
```

On Windows, remove `%LOCALAPPDATA%\zigars-mcp\0.2.0`. You can override the cache
location with `ZIGARS_MCP_CACHE_DIR`.

### Bun or Node.js version issues

Use Bun 1.3 or newer for the preferred path, or Node.js 18 or newer for the
npm/npx path:

```sh
bun --version
node --version
npm --version
```

Older Node.js versions do not provide the runtime APIs the shim relies on.

### Zig path issues

Confirm the server can find Zig:

```sh
zig version
bunx --bun @zigars/mcp@0.2.0 \
  --workspace /absolute/path/to/zig/project \
  --zig-path /absolute/path/to/zig
```

Inside an MCP client, call `zigars_doctor {"probe_backends":false}`. Optional
backends such as ZLS, ZLint, zwanzig, zflame, and diff-folded can be configured
with their matching `--*-path` arguments.

### `PermissionDenied` or workspace sandbox errors

Run:

```text
zigars_workspace_info
```

If the reported workspace is not the project you are editing, restart/configure
the MCP server with the correct `--workspace` or pass workspace-relative paths.

### Formatter tool not found

Restart the MCP client so it refreshes `tools/list`, then search for:

```text
zigars formatter
zigars format
zig_format
zig_format_check
```

`zigars_capabilities` and `zigars_tool_index` include these discovery keywords.

### ZLS tools are unavailable

Confirm `--zls-path` points to a working `zls` binary compatible with your Zig
version. Command-backed tools such as `zig_check`, `zig_build`, and `zig_test`
continue to work without ZLS.

ZLS-only tools report a structured `backend_error` with the configured path,
current session status, restart attempts, last failure when available, and a
resolution. Tools with static or command-backed fallbacks, including
`zig_document_symbols`, diagnostics summaries, and workspace symbols, continue
with degraded advisory output when the ZLS session is unavailable. An
`zls_unsupported_capability` result means ZLS did initialize, but its
advertised capabilities omitted the requested LSP method.

For install paths, wrapper-script configuration, and ZLint, zwanzig, zflame,
and diff-folded checks, see [docs/backends.md](docs/backends.md).

Run `zigars_doctor` for a compact health report that includes workspace,
dependency, transport, timeout, ZLS status, and optional backend paths. Pass
`probe_backends=true` to execute short backend probes for Zig, ZLS, ZLint,
zwanzig, zflame, and diff-folded, and to compare `zig version` with
`build.zig.zon` `minimum_zig_version` when the project declares one. Startup
also emits a stderr warning with the same resolution text when that declared
minimum exists and the configured Zig is unavailable or too old. Probe results
are cached in the server process and are also visible through
`zigars_workspace_info` and `zigars_metrics`.

## Development

Before sending a change, run the complete local gate when possible:

```sh
zig fmt build.zig build.zig.zon src tools
zig build release-check
```

For tighter loops while developing:

```sh
zig build docs-check json-check
zig build test
zig build -Doptimize=ReleaseSafe
zig build smoke stdio-fixtures coverage
```

To verify the release archive path too, run
`zig build dist release-asset-smoke`.

Example agent configs and sample tool calls live in [examples](examples).

## License

MIT. See [LICENSE](LICENSE).
