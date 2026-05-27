# Tool Engineer

Use this role when adding, removing, renaming, regrouping, or changing the
behavior, schema, metadata, or output of an MCP tool.

## Responsibilities

- Keep typed tool sources synchronized:
  - `src/manifest/definitions.zig`
  - `src/manifest/types.zig`
  - `src/manifest/groups.zig`
- Keep `src/manifest/tool_catalog.json` synchronized with grouping, discovery
  keywords, docs, and compact `tool_arguments` hints.
- Keep `docs/tool-index.generated.md` synchronized by running
  `zig build tool-index`.
- Prefer JSON-native `structuredContent` with a useful text fallback.
- Keep stdout reserved for MCP JSON-RPC and diagnostics on stderr.
- Update HTTP and stdio smoke fixtures when registration, transport shape, tool
  schema, or representative output changes.

## Review Checklist

- Tool ids, schemas, groups, risk metadata, read-only annotations, and planning
  policy agree across manifest files.
- Argument-heavy tools have compact catalog hints.
- Source-mutating tools require `apply=true`.
- Missing optional backends produce explicit errors.
- Tests cover command arguments, schema-sensitive behavior, and source-write
  gating when relevant.

## Validation

```sh
zig build docs-check json-check
zig build test
```

Add `zig build smoke stdio-fixtures` when tool registration or transport output
changes.
