# Distribution Strategy

This document records the public distribution strategy for zigars across current
and planned channels. It is not a release checklist and does not by itself prove
that any package, bundle, or registry entry has been published for a given
version. Use [release.md](release.md) as the authority for tagging, archive
verification, and release-note evidence.

## Goals

- Keep the primary runtime model local stdio. zigars needs local Zig workspaces,
  local toolchains, optional local backends, and workspace-bounded file access.
- Give most MCP clients the same simple command shape through an npm shim.
- Ship zigars-aware agent skills as a separate npm package so client guidance can
  be refined without changing the MCP server contract.
- Provide a polished Claude Desktop path with MCPB packages for mainstream
  desktop platforms.
- Keep GitHub release archives as the verified binary source and fallback
  install path.
- Treat Zig package indexes and community lists as discovery channels, not as
  the primary MCP onboarding path.

## Public Names

| Surface | Public name |
|---|---|
| Binary command | `zigars` |
| Display title | `zigars MCP` |
| MCP Registry server name | `io.github.oly-wan-kenobi/zigars` |
| npm package | `@zigars/mcp` |
| skills npm package | `@zigars/skills` |
| MCPB display title | `zigars MCP` |
| GitHub release archives | existing `zigars-<target>.tar.gz` names |

Use descriptive listing text such as `zigars: deterministic Zig MCP server` so
community package indexes do not confuse this project with unrelated Zig
projects that use similar names.

## Channel Strategy

| Channel | Role | Artifact | Main users | Main drawback |
|---|---|---|---|---|
| GitHub Releases | Verified binary source and fallback install path | Existing platform archives plus `zigars-checksums.txt` | Power users, CI, npm shim downloader | Manual path and MCP config work |
| npm shim | Broadest MCP client onboarding path | `@zigars/mcp` executable package | Cursor, VS Code, Cline, Codex, Claude Code, Gemini CLI, opencode, Kimi, Antigravity | Requires Bun or Node/npm and wrapper maintenance |
| npm skills package | Zigars-aware client guidance | `@zigars/skills` static skill package | Codex, Claude Code, and other clients with filesystem-style skills | Skills are client-specific artifacts, not portable MCP server features |
| MCP Registry | Official MCP discovery surface | `server.json` pointing first at the npm package | MCP-aware clients and directories | Registry metadata must match a public package and verified namespace |
| MCPB | Polished Claude Desktop install path | `zigars-darwin-universal.mcpb`, `zigars-linux-x64.mcpb`, `zigars-windows-x64.mcpb` | Claude Desktop users | MCPB platform metadata is OS-only, so architecture policy must be clear in filenames and docs |
| Zig community indexes | Zig ecosystem discovery | GitHub topics and community submissions | Zig developers | Discovery only; not a standard MCP install mechanism |
| OCI image | Later optional channel | Multi-arch `ghcr.io/.../zigars` image | CI, devcontainers, enterprise runners | Local workspace mounts and stdio UX are less ergonomic |

The npm shim is the primary broad-client channel because it keeps client
configuration consistent:

```sh
bunx --bun @zigars/mcp@0.2.0 --workspace /absolute/path/to/zig/project
```

Node/npm remains a supported fallback:

```sh
npx -y @zigars/mcp@0.2.0 --workspace /absolute/path/to/zig/project
```

Yarn and pnpm are supported through explicit binary selection:

```sh
yarn dlx -p @zigars/mcp@0.2.0 zigars-mcp --workspace /absolute/path/to/zig/project
pnpm dlx --package @zigars/mcp@0.2.0 zigars-mcp --workspace /absolute/path/to/zig/project
```

The shim is authored in TypeScript, publishes compiled JavaScript for
Node-compatible npm clients, and forwards zigars arguments after selecting the
correct binary. The resulting process runs zigars as a local stdio MCP server.
GitHub release assets for the matching `v<version>` tag must be uploaded before
the npm package can start successfully, because the package downloads
`zigars-checksums.txt` and the selected platform archive from GitHub Releases.

## npm Shim Contract

The npm package stays small. Its responsibility is distribution, not MCP tool
behavior.

Minimum behavior:

- detect `process.platform` and `process.arch`;
- map the host to one of the published GitHub release archives;
- download `zigars-checksums.txt` and the selected archive from the matching tag;
- verify the archive SHA-256 before extraction;
- cache the extracted binary in a user cache directory keyed by version and
  platform target;
- execute the cached binary without a shell;
- pass `--transport stdio` unless the caller explicitly supplies a transport;
- forward workspace, Zig, ZLS, and optional backend path arguments unchanged;
- print npm-shim diagnostics to stderr only, preserving stdout for MCP JSON-RPC;
- fail with a clear platform or checksum error instead of falling back silently.

Linux hosts map to the musl archives by default (`zigars-x86_64-linux-musl` and
`zigars-aarch64-linux-musl`) because Node and Bun do not expose libc ABI
consistently. The release also publishes GNU Linux archives for direct
downloads and CI workflows that explicitly need glibc ABI.

The shim must not widen zigars' trust boundary. Workspace resolution, apply
gates, backend execution, and MCP result contracts remain owned by the zigars
binary.

## Skills Package Contract

The skills package is a dogfooding and client-guidance channel, not an MCP
server channel. It lives under `packages/@zigars/skills/`, publishes as
`@zigars/skills`, and ships static skill folders under `skills/`.

Minimum behavior:

- include zigars-specific skills that route agents to zigars MCP tools and
  validation workflows;
- keep each skill self-contained with `SKILL.md`, optional `agents/` metadata,
  and optional one-level `references/`;
- include static Claude Code plugin and Gemini CLI extension metadata when those
  clients can consume the same skill folders without install side effects;
- provide an explicit helper command for listing skills and printing package
  paths, including the package root for plugin or extension clients;
- avoid postinstall hooks, automatic client config writes, or implicit MCP
  installation;
- avoid claiming skills are part of base MCP; clients consume them through their
  own skill/plugin mechanisms.

The initial package should ship `zigars-development`, the dogfooding skill used
while changing zigars itself. See [dogfooding.md](dogfooding.md) for the repo
development strategy.

## MCPB Contract

MCPB is a secondary, desktop-focused path for Claude Desktop. It should not
block the npm shim or MCP Registry publication.

Target bundles:

- `zigars-darwin-universal.mcpb`
- `zigars-linux-x64.mcpb`
- `zigars-windows-x64.mcpb`

Chosen artifact strategy:

- Prefer true binary MCPB packages for mainstream desktop platforms. This keeps
  Claude Desktop onboarding one-click and avoids requiring Bun, Node.js, npm,
  or a dispatcher script inside the bundle.
- Ship one macOS MCPB with a universal binary built from the x86_64 and aarch64
  release archives. macOS users should not need to choose an architecture.
- Ship Linux x64 and Windows x64 MCPB packages first. The current MCPB manifest
  compatibility field supports OS platform selectors (`darwin`, `win32`,
  `linux`) and does not provide a CPU architecture selector, so separate
  Linux/Windows architecture bundles would rely on filename/user choice rather
  than client-side compatibility checks.
- Keep Linux arm64 and Windows arm64 covered by the npm shim and direct release
  archives until separate MCPB packages have install smoke evidence and clear
  user-facing selection guidance.
- Do not ship a Node dispatcher MCPB containing every binary. It would avoid the
  architecture-selector limitation, but it would make MCPB depend on a Node
  runtime and duplicate the npm shim's responsibility inside a desktop bundle.

Each MCPB manifest should:

- run zigars with `--transport stdio`;
- request a required workspace directory from the user;
- avoid embedding optional backend paths by default;
- document that Zig is required and ZLS/other backends are optional;
- include only claims covered by the release evidence for that version;
- be validated with the MCPB CLI and a real Claude Desktop install smoke before
  publication.

MCPB build tooling lives in `packages/@zigars/mcpb/`. It consumes the
`zig build dist` release archives, stages `manifest.json`, `server/zigars` or
`server/zigars.exe`, README/LICENSE files, and `.mcpbignore`, then runs:

```sh
npm --prefix packages/@zigars/mcpb ci
npm --prefix packages/@zigars/mcpb run pack
```

The package is TypeScript and supports both npm/Node and Bun. The npm path
compiles `src/build.ts` to `dist/build.js`; the Bun path runs
`bun run --cwd packages/@zigars/mcpb pack:bun` directly against the TypeScript
source. The scripts use the current npm-published MCPB CLI package
`@anthropic-ai/mcpb`; `mcpb` and `@modelcontextprotocol/mcpb` are not published
npm package names at the time of this plan. The pack step validates each
manifest, writes the `.mcpb` files under `dist/assets`, runs `mcpb info`, and
writes `zigars-mcpb-checksums.txt` with SHA-256 hashes for registry
`fileSha256` values.

## Client Matrix

| Client | Primary onboarding | Secondary path | Notes and drawbacks |
|---|---|---|---|
| Claude Desktop | MCPB package | npm shim or manual JSON config | Best target for MCPB. Manual config still matters for users who prefer pinned paths. |
| Claude Code | CLI command using npm shim | Project `.mcp.json` with direct binary | Scope and config behavior should be smoke-tested before recommending defaults. |
| Codex | generated TOML using npm shim | direct binary in `~/.codex/config.toml` | TOML differs from the common `mcpServers` JSON shape. Keep Codex-specific examples. |
| Cursor | generated `mcp.json` using npm shim | direct binary | No MCPB dependency. Workspace path and command refresh behavior need client smoke evidence. |
| VS Code Copilot | generated `.vscode/mcp.json` using npm shim | VS Code install link when available | Uses a VS Code-specific server config shape. Verify Agent mode and workspace behavior. |
| Cline | generated Cline config using npm shim | Cline marketplace submission | Marketplace listing is separate from MCP Registry publication. |
| Windsurf | generated `mcp_config.json` using npm shim | marketplace or deeplink when available | Tool limits and workspace policies can vary by installation. |
| Antigravity | generated MCP config using npm shim | direct binary config | Treat config paths and UI behavior as verification-required because the client is evolving. |
| Gemini CLI | generated `settings.json` using npm shim | direct binary config | Keep trust/workspace settings explicit. |
| opencode | generated `opencode.jsonc` using npm shim | direct binary config | MCP tool count affects context and UX; recommend zigars tool discovery flows. |
| Kimi Code | CLI or VS Code MCP config using npm shim | direct binary config | Keep CLI and VS Code guidance separate until both are smoke-tested. |
| Generic MCP clients | standard `mcpServers` JSON using npm shim | direct binary config | Use absolute workspace paths unless the client reliably starts servers in the project root. |

Every public client profile should include the same validation sequence:

```text
tools/list
zigars_schema
zigars_workspace_info
zigars_doctor {"probe_backends":false}
zigars_smoke_plan
```

Before a profile is called mature, capture a client-specific smoke transcript
showing startup, workspace identity, structured MCP results, one read-only Zig
command, one docs/static-analysis call, and one preview-first source-write tool
without `apply=true`.

## Binary CLI Reporting Surface

Release archives also expose a thin, explicit CLI mode under the same `zigars`
binary:

```sh
zigars cli workspace-info --workspace /absolute/path/to/zig/project --json
zigars cli doctor --workspace /absolute/path/to/zig/project --probe-backends=false --json
```

This is not the MCP server path and does not use `tools/zigars_tools.zig`.
Successful command output is minified JSON on stdout, diagnostics go to stderr,
and the output shape matches the corresponding MCP `structuredContent` object.
Use CLI JSON and generated artifacts as the non-MCP integration path for CI and
release automation. A public Zig library API remains deferred. See
[cli.md](cli.md) for exit codes and follow-up CLI candidates.

## MCP Registry Plan

The first MCP Registry package should point to the npm shim. MCPB packages can
be added after real Claude Desktop install smoke evidence exists for the
published bundles.

Server metadata:

- `name`: `io.github.oly-wan-kenobi/zigars`
- `title`: `zigars MCP`
- `description`: deterministic local MCP server for Zig development
- primary package: npm package `@zigars/mcp`
- later packages: MCPB release assets for `darwin`, `linux`, and `windows`

Before publishing to the registry:

- confirm the repository, release assets, and npm package are publicly
  reachable;
- confirm the registry namespace authentication method;
- confirm the npm package includes the registry ownership metadata expected by
  the MCP Registry;
- run a clean-tree zigars release gate for the exact version being advertised;
- verify the registry listing after publication.

## Implementation Checklist

Completed for the npm shim package:

- Create the TypeScript npm package skeleton for `@zigars/mcp`.
- Implement host target detection and archive-name mapping.
- Implement download, checksum verification, extraction, cache reuse, and
  no-shell exec.
- Add npm shim tests for target mapping, checksum failure, cache reuse, and
  argument forwarding.
- Add package-local npm README and LICENSE files for the published tarball.

Remaining before or after publication of a given version:

1. Confirm the `v0.2.0` GitHub release has all platform archives and
   `zigars-checksums.txt`.
2. Run `bun run test:bun`, `npm run test:node`, and `npm pack --dry-run` in
   `packages/@zigars/mcp`.
3. Publish `@zigars/mcp@0.2.0` with public access.
4. Add an MCP Registry `server.json` that points to the package.
5. Add client-config generation templates for Cursor, VS Code, Cline,
   Windsurf, Antigravity, opencode, and Kimi.
6. Add generated docs examples that use the npm shim as the default command.
7. Smoke-test npm shim onboarding in at least Codex, Claude Code, Cursor,
   VS Code, Gemini CLI, and one generic MCP JSON client.
8. Produce `zigars-darwin-universal.mcpb`, `zigars-linux-x64.mcpb`, and
   `zigars-windows-x64.mcpb` from verified release binaries with
   `npm --prefix packages/@zigars/mcpb ci && npm --prefix packages/@zigars/mcpb run pack`.
9. Inspect `dist/assets/zigars-mcpb-checksums.txt` and copy the final hash of
   each published `.mcpb` into MCP Registry `fileSha256` metadata.
10. Smoke-test MCPB installation in Claude Desktop on each package platform that
    will be published.
11. Publish MCP Registry metadata, then MCPB packages as secondary package
    entries once their smoke evidence exists.

## Release Evidence

Distribution artifacts should not create broader public claims than the release
already supports. For each published version, release notes should state:

- source commit and clean-tree status;
- `zig build release-check` result;
- `zig build dist release-asset-smoke` result;
- npm shim version and checksum verification behavior;
- MCP Registry package entries published for the version;
- MCPB packages published for the version and the platforms actually smoke-tested;
- optional backend conformance status, using `not run` where no clean evidence
  exists.

If npm, MCPB, or registry publication is skipped for a version, say so directly
instead of implying that all onboarding channels are available.
