# Contributing

Thanks for improving zigar.

## Scope

zigar is a deterministic Zig development MCP server. Keep changes focused on
tools that inspect, build, test, format, analyze, document, or profile Zig
projects. Do not add AI code-generation behavior to the server itself.

## Development Setup

Install Zig 0.16.0 and, optionally, matching ZLS 0.16.0.

```sh
zig build test
zig build -Doptimize=ReleaseSafe
```

Optional runtime backends:

- `zls` for LSP-backed diagnostics, symbols, references, completion, code
  actions, and rename.
- `zwanzig` for linting and analysis graph workflows.
- `zflame` and `diff-folded` for flamegraph workflows.

## Change Guidelines

- Preserve the workspace sandbox: every user-provided path must resolve under
  the configured workspace before it is read or written.
- Source-mutating tools must require `apply=true`.
- Keep `src/tool_catalog.json` synchronized with tool grouping, discovery
  keywords, docs, and compact `tool_arguments` hints for common
  argument-heavy tools.
- Keep `src/tool_metadata.zig` as the typed tool source for ids, schemas, MCP
  read-only annotations, and fine-grained risk metadata.
- Keep heuristic source scanners in `src/analysis.zig` or a dedicated analysis
  module, with confidence labels and fixture tests.
- Regenerate and check `docs/tool-index.generated.md` with
  `zig build tool-index` and `zig build docs-check`.
- Prefer structured MCP results with JSON-native `structuredContent` and a text
  fallback.
- Keep stdout reserved for MCP JSON-RPC. Logs and diagnostics must go to stderr.
- Keep the project pure Zig. Do not add Python helper scripts under source,
  tools, tests, scripts, examples, docs, or CI paths.
- Keep `src/main.zig` as a small startup/lifecycle entrypoint and keep
  `tools/zigar_tools.zig` as a dispatcher; move large helper logic into focused
  Zig modules.
- Add or update tests for path handling, parser behavior, command arguments,
  diagnostics conversion, and source-write gating when those areas change.

## Before Opening a Pull Request

```sh
zig fmt build.zig build.zig.zon src tools
zig build docs-check json-check
zig build test
zig build -Doptimize=ReleaseSafe
zig build smoke stdio-fixtures coverage
```

If the change affects MCP registration, transports, tool schemas, or optional
backend integrations, keep the HTTP and stdio smoke fixtures updated with a
representative `tools/call`.

For local release-style verification, run `zig build release-check`. This also
checks generated artifact hygiene, pure-Zig helper policy, and size budgets for
the entrypoint and release-tool dispatcher.
