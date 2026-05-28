# @zigars/mcp

`@zigars/mcp` is the npm entry point for `zigars`, a deterministic local MCP
server for Zig development.

It is a small TypeScript launcher: it downloads the matching `zigars` binary from
GitHub Releases, verifies the archive checksum, caches the binary locally, and
runs it as a stdio MCP server. The package name is `@zigars/mcp`; the project,
server, and downloaded binary are still named `zigars`.

## Quickstart

```sh
bunx --bun @zigars/mcp@0.2.0 --workspace /absolute/path/to/zig/project
```

Node/npm is also supported:

```sh
npx -y @zigars/mcp@0.2.0 --workspace /absolute/path/to/zig/project
```

Yarn and pnpm are supported through their `dlx` package selectors:

```sh
yarn dlx -p @zigars/mcp@0.2.0 zigars-mcp --workspace /absolute/path/to/zig/project
pnpm dlx --package @zigars/mcp@0.2.0 zigars-mcp --workspace /absolute/path/to/zig/project
```

Use the same command in any MCP client that can launch a stdio server:

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

After the server starts, these calls are useful first checks:

```text
zigars_workspace_info
zigars_doctor {"probe_backends":false}
zigars_schema
zigars_setup_guidance
zigars_smoke_plan
```

## What zigars Provides

zigars gives MCP-capable agents a structured Zig workbench. It is not an AI code
generator; it exposes local tools that inspect, run, format, analyze, and plan
changes in Zig workspaces. Source writes require explicit `apply=true`.

| Area | Examples | Notes |
|---|---|---|
| Zig commands | `zig_version`, `zig_env`, `zig_check`, `zig_build`, `zig_test`, `zig_translate_c` | Runs explicit Zig commands with the workspace as cwd. |
| Formatting and edits | `zig_format`, `zig_format_check`, `zig_patch_preview`, `zig_move_decl`, `zig_extract_decl`, `zig_rename` | Preview-first; source writes require `apply=true`. |
| ZLS intelligence | `zig_diagnostics`, `zig_hover`, `zig_definition`, `zig_references`, `zig_completion`, `zig_document_symbols` | Requires a compatible `zls` for live LSP-backed results. |
| Docs lookup | `zig_builtin_doc`, `zig_std_search`, `zig_std_item`, `zig_lang_ref_search` | Uses installed source/docs and curated fallback data. |
| Static analysis | `zig_import_graph`, `zig_decl_summary`, `zig_allocations`, `zig_public_api`, `zig_test_map`, `zig_static_fusion` | Results include confidence, limitations, and verification guidance. |
| Optional lint backends | `zig_zlint`, `zig_zlint_sarif`, `zig_lint`, `zig_lint_gate`, `zig_lint_fix_plan` | ZLint and zwanzig are optional. Missing backends return structured errors. |
| Profiling and performance | `zig_profile_plan`, `zig_flamegraph`, `zig_coverage_run`, `zig_bench_run`, `zig_perf_budget_check` | Command-running tools are apply-gated and preserve backend provenance. |
| Runtime diagnostics | `zig_debug_plan`, `zig_lldb_backtrace`, `zig_valgrind_memcheck`, `zig_fuzz_plan`, `zig_binary_size` | Uses explicit local backend paths when needed. |
| Release and adoption | `zigars_schema`, `zigars_doctor`, `zigars_client_config_generate`, `zigars_release_claim_check`, `zigars_smoke_plan` | Helps clients discover capabilities and package setup evidence. |

Protocol features are additive. Clients that understand `outputSchema`,
`resource_link`, MCP elicitation, or MCP sampling get richer integration;
clients that do not still receive normal text plus `structuredContent` results.
Patch-session writes remain `apply=true` and stale-preimage gated, and
`zigars_failure_fusion summarize=true` falls back to deterministic evidence when
sampling is unavailable.

<details>
<summary>Tool group table</summary>

| Group | Representative tools |
|---|---|
| Discovery and health | `zigars_capabilities`, `zigars_tool_index`, `zigars_schema`, `zigars_backend_catalog`, `zigars_doctor`, `zigars_workspace_info` |
| Agent workflow | `zigars_context_pack`, `zigars_next_action`, `zigars_agent_guide_v2`, `zigars_client_guide`, `zigars_validate_patch`, `zigars_validation_plan` |
| Core Zig | `zig_version`, `zig_env`, `zig_targets`, `zig_build`, `zig_test`, `zig_check`, `zig_translate_c` |
| Formatting and transactional edits | `zig_format`, `zig_format_check`, `zig_patch_preview`, `zigars_patch_session_preview`, `zigars_patch_session_apply` |
| ZLS code intelligence | `zig_diagnostics`, `zig_hover`, `zig_definition`, `zig_references`, `zig_completion`, `zig_signature_help` |
| ZLS edits and document state | `zig_rename`, `zig_code_actions`, `zig_code_action_apply`, `zig_document_open`, `zig_document_change`, `zig_document_close` |
| Docs | `zig_builtin_list`, `zig_builtin_doc`, `zig_std_search`, `zig_std_item`, `zig_lang_ref_search` |
| Static analysis | `zig_import_graph`, `zig_ast_imports`, `zig_decl_summary`, `zig_error_sets`, `zig_public_api`, `zig_test_discover` |
| Semantic index | `zig_semantic_index_build`, `zig_semantic_index_status`, `zig_semantic_query`, `zig_semantic_refs`, `zig_scip_export` |
| Linting | `zig_zlint`, `zig_zlint_sarif`, `zig_lint`, `zig_lint_sarif`, `zig_lint_gate`, `zig_lint_baseline` |
| Coverage and benchmarks | `zig_coverage_run`, `zig_coverage_map`, `zig_coverage_budget_check`, `zig_bench_run`, `zig_bench_compare` |
| Profiling | `zig_profile_plan`, `zig_profile_run`, `zig_flamegraph`, `zig_flamegraph_diff`, `zig_samply_record`, `zig_tracy_capture` |
| Runtime diagnostics | `zig_debug_plan`, `zig_lldb_backtrace`, `zig_valgrind_memcheck`, `zig_fuzz_plan`, `zig_qemu_test`, `zig_flash_plan` |
| Artifact registry | `zigars_artifact_index`, `zigars_artifact_read`, `zigars_artifact_prune` |
| Trust and release drift | `zigars_trust_report`, `zigars_command_provenance`, `zigars_clean_tree_gate`, `zigars_docs_drift_check`, `zigars_release_claim_check` |
| Public adoption | `zigars_client_config_generate`, `zigars_adoption_pack`, `zigars_smoke_plan`, `zigars_conformance_report` |

The full tool list and schemas are available from MCP `tools/list` and
`zigars_schema`.

</details>

## Requirements

| Requirement | Minimum | Notes |
|---|---:|---|
| Bun | 1.3 | Preferred launcher. Use `bunx --bun @zigars/mcp@0.2.0 ...` for one-off startup. |
| Node.js | 18 | Supported runtime for npm/npx and installed `zigars-mcp` commands. |
| npm/npx | bundled with Node | Use `npx -y @zigars/mcp@0.2.0 ...` when Bun is not available. |
| Yarn | 4 with `dlx` | Use `yarn dlx -p @zigars/mcp@0.2.0 zigars-mcp ...`. |
| pnpm | 10 or newer | Use `pnpm dlx --package @zigars/mcp@0.2.0 zigars-mcp ...`. |
| Zig | `0.16.0` | Put `zig` on `PATH` or pass `--zig-path`. |
| MCP client | stdio support | Cursor, VS Code, Cline, Codex, Claude Code, Gemini CLI, opencode, Kimi, and generic clients can use this command shape. |

| Host | Release archive |
|---|---|
| Linux x64 | `zigars-x86_64-linux-musl.tar.gz` |
| Linux arm64 | `zigars-aarch64-linux-musl.tar.gz` |
| macOS x64 | `zigars-x86_64-macos.tar.gz` |
| macOS arm64 | `zigars-aarch64-macos.tar.gz` |
| Windows x64 | `zigars-x86_64-windows-gnu.tar.gz` |
| Windows arm64 | `zigars-aarch64-windows-gnu.tar.gz` |

Linux hosts deliberately use the musl archives as the npm default because Node
and Bun do not expose libc ABI consistently. The release also publishes GNU
Linux archives for direct downloads and CI jobs that explicitly need glibc ABI.

Optional backends are configured with paths when needed:

| Backend | Common argument |
|---|---|
| Zig | `--zig-path /absolute/path/to/zig` |
| ZLS | `--zls-path /absolute/path/to/zls` |
| ZLint | `--zlint-path /absolute/path/to/zlint` |
| zwanzig | `--zwanzig-path /absolute/path/to/zwanzig` |
| zflame | `--zflame-path /absolute/path/to/zflame` |
| diff-folded | `--diff-folded-path /absolute/path/to/diff-folded` |

<details>
<summary>Command line reference</summary>

The shim accepts zigars server arguments and forwards them to the downloaded
binary. It adds `--transport stdio` unless you pass `--transport` yourself.

```sh
bunx --bun @zigars/mcp@0.2.0 \
  --workspace /absolute/path/to/zig/project \
  --zig-path /absolute/path/to/zig \
  --zls-path /absolute/path/to/zls
```

Equivalent package-manager launchers:

```sh
npx -y @zigars/mcp@0.2.0 --workspace /absolute/path/to/zig/project
yarn dlx -p @zigars/mcp@0.2.0 zigars-mcp --workspace /absolute/path/to/zig/project
pnpm dlx --package @zigars/mcp@0.2.0 zigars-mcp --workspace /absolute/path/to/zig/project
```

Common server arguments:

| Argument | Purpose |
|---|---|
| `--workspace <path>` | Workspace root zigars is allowed to serve. Prefer an absolute path. |
| `--zig-path <path>` | Zig executable path when the client does not inherit your shell `PATH`. |
| `--zls-path <path>` | ZLS executable path for language-server-backed tools. |
| `--transport stdio\|http` | Transport. `@zigars/mcp` defaults to `stdio`. |
| `--host 127.0.0.1` | Host for local HTTP mode. |
| `--port 8080` | Port for local HTTP mode. |
| `--cache-dir <path>` | zigars server cache directory. Different from the package launcher cache. |
| `--timeout-ms <n>` | Command timeout. |
| `--zls-timeout-ms <n>` | ZLS request timeout. |

Shim-only commands:

```sh
bunx --bun @zigars/mcp@0.2.0 --help
bunx --bun @zigars/mcp@0.2.0 --version
```

</details>

## MCP Client Setup

<details open>
<summary>Generic JSON clients</summary>

Use this shape for clients that read an `mcpServers` object:

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

With explicit Zig and ZLS paths:

```json
{
  "mcpServers": {
    "zigars": {
      "command": "bunx",
      "args": [
        "--bun",
        "@zigars/mcp@0.2.0",
        "--workspace",
        "/absolute/path/to/zig/project",
        "--zig-path",
        "/absolute/path/to/zig",
        "--zls-path",
        "/absolute/path/to/zls"
      ]
    }
  }
}
```

</details>

<details>
<summary>Codex</summary>

Add a server entry to `~/.codex/config.toml`:

```toml
[mcp_servers.zigars]
command = "bunx"
args = [
  "--bun",
  "@zigars/mcp@0.2.0",
  "--workspace",
  "/absolute/path/to/zig/project",
  "--zig-path",
  "/absolute/path/to/zig",
  "--zls-path",
  "/absolute/path/to/zls"
]
startup_timeout_sec = 20.0
```

</details>

<details>
<summary>Claude Desktop</summary>

Claude Desktop can use manual JSON configuration today:

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

MCPB packages are the polished Claude Desktop install path for mainstream
desktop platforms:

```text
zigars-darwin-universal.mcpb
zigars-linux-x64.mcpb
zigars-windows-x64.mcpb
```

MCPB bundles include the zigars server binary directly and ask for the workspace
directory during installation. `@zigars/mcp` remains the broad MCP-client path,
the fallback when you need Linux arm64, and the easiest way to pass optional
backend paths such as `--zls-path`.

</details>

## Download, Verification, and Cache

The package version selects the GitHub release tag. For `@zigars/mcp@0.2.0`,
the shim downloads from:

```text
https://github.com/oly-wan-kenobi/zigars/releases/download/v0.2.0/zigars-checksums.txt
https://github.com/oly-wan-kenobi/zigars/releases/download/v0.2.0/<host-archive>
```

Startup sequence:

| Step | Behavior |
|---:|---|
| 1 | Detect `process.platform` and `process.arch`. |
| 2 | Select the matching release archive. |
| 3 | Download `zigars-checksums.txt`. |
| 4 | Download the selected archive. |
| 5 | Verify the archive SHA-256. |
| 6 | Extract `zigars` or `zigars.exe` into the user cache. |
| 7 | Execute the cached binary with `shell:false`. |

Default shim cache roots:

| Platform | Cache root |
|---|---|
| Linux | `$XDG_CACHE_HOME/zigars-mcp` or `~/.cache/zigars-mcp` |
| macOS | `~/Library/Caches/zigars-mcp` |
| Windows | `%LOCALAPPDATA%\zigars-mcp` or `%APPDATA%\zigars-mcp` |

Override the shim cache:

```sh
ZIGARS_MCP_CACHE_DIR=/absolute/cache/dir \
  bunx --bun @zigars/mcp@0.2.0 --workspace /absolute/path/to/zig/project
```

Shim diagnostics are written to stderr only. stdout is reserved for MCP
JSON-RPC.

## Troubleshooting

<details open>
<summary>Release assets must exist before npm works</summary>

Before publishing or using `@zigars/mcp@0.2.0`, the `v0.2.0` GitHub release
must include:

```text
zigars-checksums.txt
zigars-x86_64-linux-gnu.tar.gz
zigars-aarch64-linux-gnu.tar.gz
zigars-x86_64-linux-musl.tar.gz
zigars-aarch64-linux-musl.tar.gz
zigars-x86_64-macos.tar.gz
zigars-aarch64-macos.tar.gz
zigars-x86_64-windows-gnu.tar.gz
zigars-aarch64-windows-gnu.tar.gz
```

If startup prints `Failed to download ... HTTP 404`, the matching release,
checksum file, or host archive is missing. Upload the release assets first or
build zigars from source.

</details>

<details>
<summary>Unsupported platform</summary>

Error:

```text
Unsupported zigars host target: <platform>/<arch>
```

Use Linux x64/arm64, macOS x64/arm64, Windows x64/arm64, or build zigars from
source. The shim does not silently fall back to another platform archive.

</details>

<details>
<summary>Checksum errors</summary>

Errors:

```text
Missing checksum for <archive>
Checksum mismatch for <archive>: expected <sha>, got <sha>
```

Do not bypass checksum verification. Confirm `zigars-checksums.txt` and the
archive came from the same release build, then clear the cached version and
retry:

```sh
rm -rf ~/.cache/zigars-mcp/0.2.0
rm -rf ~/Library/Caches/zigars-mcp/0.2.0
```

On Windows, remove:

```text
%LOCALAPPDATA%\zigars-mcp\0.2.0
```

</details>

<details>
<summary>Bun or Node.js issues</summary>

Check your runtime:

```sh
bun --version
node --version
npm --version
```

Use Bun 1.3 or newer for the preferred path, or Node.js 18 or newer for the
npm/npx, Yarn, and pnpm paths. Older Node.js runtimes lack required APIs such
as `fetch`.

</details>

<details>
<summary>Extraction issues</summary>

The shim extracts `.tar.gz` release archives with `tar`. If extraction fails,
verify `tar` is available on `PATH`, clear the partial cache, and rerun the
command.

</details>

<details>
<summary>Zig and backend path issues</summary>

Confirm Zig works outside the MCP client:

```sh
zig version
```

If the MCP client does not inherit your shell `PATH`, pass absolute paths:

```sh
bunx --bun @zigars/mcp@0.2.0 \
  --workspace /absolute/path/to/zig/project \
  --zig-path /absolute/path/to/zig \
  --zls-path /absolute/path/to/zls
```

Inside the MCP client, call:

```text
zigars_doctor {"probe_backends":false}
```

Use `probe_backends:true` when you want zigars to execute short backend probes.

</details>

<details>
<summary>Workspace path issues</summary>

Use an absolute `--workspace` path unless your client reliably launches MCP
servers from the active project directory. If tools return workspace sandbox or
`PermissionDenied` errors, call:

```text
zigars_workspace_info
```

Restart the MCP server with the intended workspace path if the reported
workspace is wrong.

</details>

## Contributor Publish Checks

<details open>
<summary>Local package checks</summary>

Run from the package directory:

```sh
cd packages/@zigars/mcp
bun install
bun run test:bun
npm run test:node
npm pack --dry-run
```

The dry-run tarball should include:

| File or directory | Why it matters |
|---|---|
| `README.md` | npm package page and tarball onboarding. |
| `LICENSE` | License text in the published package. |
| `package.json` | Package metadata, bin entry, Bun/Node scripts, public access config. |
| `bin/` | `zigars-mcp` executable wrapper. |
| `dist/src/` | Compiled JavaScript used by the published bin. |
| `src/` | TypeScript launcher implementation. |

</details>

<details>
<summary>Test the packed package before publish</summary>

```sh
cd packages/@zigars/mcp
npm pack
npm exec --yes --package ./zigars-mcp-0.2.0.tgz -- \
  zigars-mcp --help
bunx --bun --package ./zigars-mcp-0.2.0.tgz zigars-mcp --help
npm exec --yes --package ./zigars-mcp-0.2.0.tgz -- \
  zigars-mcp --workspace /absolute/path/to/zig/project
```

The final command contacts GitHub unless the selected binary is already cached.
Confirm the matching `v0.2.0` GitHub release assets exist before using this as
a publish gate.

</details>

## License

MIT. See `LICENSE`.
