# Agent Instructions

These instructions apply to `src/manifest/` and child directories.

## Scope

This directory owns the typed public contract for MCP tool discovery, grouping,
risk metadata, planning metadata, and JSON schema projection.

## Local Rules

- Treat manifest definitions as source-of-truth contract data, not runtime
  behavior.
- Keep tool ids, schemas, groups, risk metadata, planning policy, and discovery
  metadata synchronized across `definitions.zig`, `types.zig`, `groups.zig`,
  and `tool_catalog.json`.
- When contract data changes, regenerate `docs/tool-index.generated.md` with
  `zig build tool-index`.
- Do not add adapter, workspace, command, filesystem, or backend execution
  logic here.
- Add or update manifest invariant tests for generated contract drift, schema
  shape, group coverage, planning policy, and risk metadata changes.

## Validation

For manifest changes, run:

```sh
zig build tool-index
zig build docs-check json-check
```

Add `zig build smoke stdio-fixtures` when a change affects MCP registration,
schema shape, transport output, or representative tool calls.
