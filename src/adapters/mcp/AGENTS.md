# Agent Instructions

These instructions apply to `src/adapters/mcp/` and child directories.

## Scope

This directory owns MCP protocol projection: registration, handler dispatch,
argument validation, result shaping, resources, prompts, transport-facing
errors, and adapter modules for MCP tools.

## Local Rules

- Keep business behavior in `src/app/usecases/` and pure policy or parsing in
  `src/domain/`; adapters should project those results into MCP shapes.
- Preserve JSON-native `structuredContent` plus a useful text fallback for tool
  results.
- Keep MCP `ToolResult` ownership inside the adapter layer.
- Return expected user failures as structured tool results where the existing
  local pattern does so; reserve protocol errors for adapter-level failures.
- Keep stdout reserved for MCP JSON-RPC. Diagnostics and logs go to stderr.
- When adding or changing tools, consult `.agents/workflows/tool-change.md` and
  update handler mapping, registration, manifest data, docs, and smoke fixtures
  as needed.
- Do not bypass workspace, process, or backend ports from this layer.

## Validation

For adapter or registration changes, run focused tests plus:

```sh
zig build docs-check json-check
zig build smoke stdio-fixtures
```
