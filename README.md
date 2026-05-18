# zigar

`zigar` is a deterministic MCP server for Zig development. It gives MCP clients
such as Codex a structured Zig workbench: compiler commands, formatting, ZLS
code intelligence, local docs lookup, static analysis summaries, zwanzig
linting, and zflame profiling helpers.

`zigar` is intentionally not an AI code generator. It exposes tools that inspect,
run, format, and analyze Zig projects. Any source write requires an explicit
`apply=true` argument.

## Status

`zigar` is ready for early public use with Zig 0.16.0 and stdio MCP transport.
The current package version is `0.1.0`; see [CHANGELOG.md](CHANGELOG.md).

Known limitations:

- `mcp.zig` is consumed as a URL dependency at version 0.0.4. `zig-pkg/` is a
  local cache/artifact directory and is ignored.
- ZLS, zwanzig, zflame, and diff-folded are optional runtime backends. Tools
  that need a missing backend return an explicit error.

## Requirements

- Zig `0.16.0`
- An MCP client that supports stdio servers
- Optional: `zls` `0.16.0` for language-server-backed tools
- Optional: `zwanzig` for linting/static-analysis backend tools
- Optional: `zflame` and `diff-folded` for flamegraphs and flamegraph diffs

Optional backend setup, verification commands, and failure triage are documented
in [docs/backends.md](docs/backends.md). The same backend setup contract is
available at runtime through `zigar_backend_catalog` and in `zigar_schema` under
`backend_setup`.

## Install

Build from source:

```sh
git clone https://github.com/oly-wan-kenobi/zigar.git
cd zigar
zig build -Doptimize=ReleaseSafe
install -m 0755 zig-out/bin/zigar ~/.local/bin/zigar
zigar --version
```

When a tagged GitHub release is published, download the archive for your
platform from that release, verify it against `zigar-checksums.txt`, and put
`zigar` on `PATH`. GitHub release attestations are generated from the same
checksum file.

Published release archives are named:

```text
zigar-x86_64-linux-musl.tar.gz
zigar-aarch64-linux-musl.tar.gz
zigar-x86_64-macos.tar.gz
zigar-aarch64-macos.tar.gz
zigar-x86_64-windows.tar.gz
```

## Build

```sh
zig build test
zig build -Doptimize=ReleaseSafe
```

The binary is written to:

```text
zig-out/bin/zigar
```

`zig build test` includes unit coverage for executable startup helpers, CLI
parsing, workspace sandboxing, command parsing, JSON serialization, diagnostics
retention, source-write gating, strict symlink rejection, command output-limit
metadata, ZLS timeout/EOF behavior, a fake-ZLS LSP roundtrip, and the Zig helper
used by release checks. The release coverage summary enforces non-zero floors for
the library, executable, and tooling test binaries.

Integration and coverage helpers are available as build steps:

```sh
zig build smoke
zig build stdio-fixtures
zig build coverage
zig build dist release-asset-smoke
```

`zig build coverage` requires `kcov` on `PATH` and writes
`coverage/summary.json` with the installed library, executable, and tooling test
binary results, per-suite floors, Cobertura-derived line coverage, and the
configured coverage floors. The default local release gate fails when kcov cannot
measure project source coverage or total, `src/`, or `tools/` coverage drops
below the configured floors in `tools/coverage_config.zig`.

`zig build dist` creates ReleaseSafe archives and `zigar-checksums.txt` under
`dist/assets`. `zig build release-asset-smoke` verifies checksums, archive
contents, and the native archive's `zigar --version` behavior.

## Run

```sh
zig-out/bin/zigar --workspace /path/to/zig/project --transport stdio
```

Options:

```text
--workspace <path>
--zig-path <path>
--zls-path <path>
--zwanzig-path <path>
--zflame-path <path>
--diff-folded-path <path>
--transport stdio|http
--host 127.0.0.1
--port 8080
--cache-dir <path>
--timeout-ms <n>
--zls-timeout-ms <n>
--strict-workspace
```

Use `--transport stdio` for Codex. `--transport http` is available for clients
that need an HTTP endpoint.

## Codex Configuration

Add a server entry to `~/.codex/config.toml`:

```toml
[mcp_servers.zigar]
command = "/absolute/path/to/zigar"
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
tool returns a workspace sandbox error, call `zigar_workspace_info` to confirm
which project the server is actually serving.

For a single global Codex entry that serves the current project, keep the
workspace argument out of the global config and make sure Codex launches the MCP
server from the active workspace:

```toml
[mcp_servers.zigar]
command = "/absolute/path/to/zigar"
args = ["--transport", "stdio", "--strict-workspace"]
startup_timeout_sec = 10.0
```

For a pinned workspace, include `--workspace` explicitly. This is safer for one
project, but it should not be reused across unrelated workspaces.

Useful project instruction:

```md
When working on Zig code, prefer the zigar MCP tools for Zig version/env,
build, check, test, formatting, ZLS diagnostics, symbols, references, docs,
static analysis, and profiling before falling back to direct shell commands.
Source writes require apply=true.
```

## Tool Groups

- Discovery/meta: `zigar_capabilities`, `zigar_tool_index`,
  `zigar_schema`, `zigar_doctor`, `zigar_workspace_info`, `zigar_metrics`,
  `zigar_http_status`, `zig_command_plan`, `zig_tool_plan`,
  `zig_toolchain_resolve`
- Agent workflows: `zigar_context_pack`, `zigar_next_action`,
  `zigar_agent_guide`, `zigar_validate_patch`, `zigar_failure_fusion`,
  `zigar_impact`, `zigar_project_profile`, `zigar_patch_guard`
- Core Zig: `zig_version`, `zig_env`, `zig_targets`, `zig_build`, `zig_test`,
  `zig_check`, `zig_compile_error_index`, `zig_explain_errors`,
  `zig_translate_c`
- Formatting: `zig_format`, `zig_format_check`, `zig_patch_preview`
- ZLS intelligence: `zig_diagnostics`, `zig_diagnostics_all`,
  `zig_diagnostics_workspace`, `zig_hover`, `zig_definition`,
  `zig_references`, `zig_completion`, `zig_signature_help`,
  `zig_document_symbols`, `zig_workspace_symbols`
- ZLS edits/session: `zig_rename`, `zig_code_actions`,
  `zig_code_action_apply`, `zig_document_open`, `zig_document_change`,
  `zig_document_close`, `zig_document_status`
- Docs: `zig_builtin_list`, `zig_builtin_doc`, `zig_builtin_list_json`,
  `zig_std_search`, `zig_std_search_json`, `zig_std_item`,
  `zig_lang_ref_search`
- Static analysis: `zig_import_graph`, `zig_import_graph_json`,
  `zig_decl_summary`, `zig_decl_summary_json`, `zig_allocations`,
  `zig_error_sets`, `zig_public_api`, `zig_dead_decl_candidates`,
  `zig_build_graph`, `zig_build_targets`, `zig_build_options`,
  `zig_file_owner`, `zig_import_resolve`, `zig_test_discover`,
  `zig_test_map`, `zig_test_select`, `zig_public_api_diff`,
  `zig_changed_files_plan`, `zig_dependency_inspect`,
  `zig_target_matrix_plan`, `zig_test_failure_triage`,
  `zig_workspace_symbol_cache`, `zig_package_cache_doctor`
- CI/test artifacts: `zig_ci_annotations`, `zig_junit`, `zig_matrix_check`
- zwanzig: `zig_lint`, `zig_lint_sarif`, `zig_lint_rules`,
  `zig_analysis_graphs`
- Profiling/zflame: `zig_profile_plan`, `zig_profile_run`, `zig_flamegraph`,
  `zig_flamegraph_diff`

`zigar_schema` includes registry-derived required and optional argument hints for
argument-heavy tools. Use it when an MCP client shows only generic `tools/list`
schemas.

The generated index in [docs/tool-index.generated.md](docs/tool-index.generated.md)
is built from `src/tool_catalog.json` plus the typed registry metadata and
checked in CI.

For Codex/Claude-oriented workflows, see
[docs/agent-workflows.md](docs/agent-workflows.md). The short version is:
start with `zigar_context_pack`, route uncertain work through
`zigar_next_action`, and finish with `zigar_validate_patch`.

## Safety Model

- Every input and output path is resolved under `--workspace`.
- `--strict-workspace` additionally checks real paths for existing files and
  output parents to reject symlink escapes.
- Source writes require `apply=true`.
- Formatting, patch preview, and rename tools return previews/diffs by default.
- Build, test, and profiling commands run with the workspace as cwd.
- `zigar_schema` includes finer-grained tool risk metadata for source writes,
  artifact writes, LSP state mutation, backend execution, project-code
  execution, and user-command execution.
- stdout is reserved for MCP JSON-RPC. Logs, help, version, and startup errors
  go to stderr.
- zwanzig graph output and zflame SVG output must use explicit workspace-local
  output paths.

More detail:

- [Tool discovery](docs/tools.md)
- [Generated tool index](docs/tool-index.generated.md)
- [Architecture notes](docs/architecture.md)
- [Agent workflows](docs/agent-workflows.md)
- [Codex setup](docs/codex.md)
- [Security model](docs/security-model.md)
- [Security readiness audit](docs/security-audit.md)
- [Optional backends](docs/backends.md)
- [Testing and coverage](docs/testing.md)
- [Troubleshooting](docs/troubleshooting.md)
- [Release checklist](docs/release.md)

## Troubleshooting

### `PermissionDenied` or workspace sandbox errors

Run:

```text
zigar_workspace_info
```

If the reported workspace is not the project you are editing, restart/configure
the MCP server with the correct `--workspace` or pass workspace-relative paths.

### Formatter tool not found

Restart the MCP client so it refreshes `tools/list`, then search for:

```text
zigar formatter
zigar format
zig_format
zig_format_check
```

`zigar_capabilities` and `zigar_tool_index` include these discovery keywords.

### ZLS tools are unavailable

Confirm `--zls-path` points to a working `zls` binary compatible with your Zig
version. Command-backed tools such as `zig_check`, `zig_build`, and `zig_test`
continue to work without ZLS.

For install paths, wrapper-script configuration, and zwanzig/zflame/diff-folded
checks, see [docs/backends.md](docs/backends.md).

Run `zigar_doctor` for a compact health report that includes workspace,
dependency, transport, timeout, ZLS status, and optional backend paths. Pass
`probe_backends=true` to execute short backend probes for Zig, ZLS, zwanzig,
zflame, and diff-folded. Probe results are cached in the server process and are
also visible through `zigar_workspace_info` and `zigar_metrics`.

## Development

Before sending a change:

```sh
zig fmt build.zig build.zig.zon src tools
zig build docs-check json-check
zig build test
zig build -Doptimize=ReleaseSafe
zig build smoke stdio-fixtures coverage
```

For release-style verification, run `zig build release-check`. To verify the
release archive path too, run `zig build dist release-asset-smoke`.

Example Codex configs and sample tool calls live in [examples](examples).

## License

MIT. See [LICENSE](LICENSE).
