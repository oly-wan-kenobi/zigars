# Agent Instructions

These instructions apply to the entire repository.

## Project Shape

`zigars` is a deterministic Zig development MCP server. Keep changes focused on
tools that inspect, build, test, format, analyze, document, or profile Zig
projects. Do not add AI code-generation behavior to the server itself.

Reusable role and workflow playbooks live under `.agents/`. Consult the
smallest applicable role and workflow files before substantial changes, for
example `.agents/workflows/tool-change.md` for MCP tool changes or
`.agents/roles/security-sandbox-reviewer.md` for path, command, or write
behavior.

The project is primarily Zig:

- Core server code lives under `src/`.
- MCP tool projection lives under `src/adapters/mcp/tools/`.
- Runtime composition belongs under `src/bootstrap/`.
- Tool behavior belongs in focused modules under `src/app/usecases/`.
- Pure Zig parsing and domain policy belongs under `src/domain/`.
- The release and local helper dispatcher is `tools/zigars_tools.zig`.
- The npm shim is under `packages/@zigars/mcp/`.

## Required Toolchain

- Use Zig `0.16.0`.
- Optional local backends include ZLS `0.16.0`, ZLint, zwanzig, zflame, and
  diff-folded. Treat them as optional unless the task specifically requires
  backend-backed behavior.
- For the npm shim, use Bun or Node.js 18+ as appropriate for the package
  scripts.

## Coding Rules

- Preserve the workspace sandbox: every user-provided path must resolve under
  the configured workspace before it is read or written.
- Source-mutating MCP tools must require `apply=true`.
- Keep stdout reserved for MCP JSON-RPC. Send logs and diagnostics to stderr.
- Prefer structured MCP results with JSON-native `structuredContent` and a text
  fallback.
- Keep the project pure Zig. Do not add Python helper scripts under source,
  tools, tests, scripts, examples, docs, or CI paths.
- Keep `src/main.zig` as a small startup/lifecycle entrypoint.
- Keep `tools/zigars_tools.zig` as a dispatcher; move large helper logic into
  focused Zig modules.
- Add or update tests for path handling, parser behavior, command arguments,
  diagnostics conversion, source-write gating, and generated contract drift when
  those areas change.

## Manifest And Docs Sync

When changing tool ids, schemas, grouping, discovery metadata, risk metadata,
planning policy, or argument-heavy tools, keep these files synchronized:

- `src/manifest/tool_catalog.json`
- `src/manifest/definitions.zig`
- `src/manifest/types.zig`
- `src/manifest/groups.zig`
- `docs/tool-index.generated.md`

Regenerate and check the generated tool index with:

```sh
zig build tool-index
zig build docs-check
```

## Build And Test

Use focused checks while developing, then scale up based on the risk of the
change.

Common commands:

```sh
zig fmt build.zig build.zig.zon src tools
zig build test
zig build docs-check json-check
zig build -Doptimize=ReleaseSafe
```

Broader pre-PR checks:

```sh
zig build test --fuzz=10K
zig build smoke stdio-fixtures coverage
```

Release-style local verification:

```sh
zig build release-check
```

If a change affects MCP registration, transports, tool schemas, or optional
backend integrations, update the HTTP and stdio smoke fixtures with a
representative `tools/call`.

For npm shim changes:

```sh
cd packages/@zigars/mcp
npm run build
npm run test:node
bun run test:bun
```

## Generated And Artifact Hygiene

- Do not commit build outputs, local caches, coverage output, `zig-out/`, or
  generated release artifacts unless the repository explicitly tracks them.
- Run `zig build artifact-hygiene` or `zig build release-check` when changing
  release, packaging, or generated-artifact workflows.

## Git Hygiene

- Keep changes narrowly scoped to the request.
- Do not revert unrelated work in a dirty tree.
- Before committing or opening a PR, summarize the validation commands run and
  note any checks that could not be run.
