# Tool Change Workflow

Use this workflow when adding, removing, renaming, regrouping, or changing an
MCP tool.

## Roles

- Tool Engineer
- Architect when ownership or module boundaries change
- Security Sandbox Reviewer when paths, commands, or writes are involved
- Docs Maintainer when user-facing behavior changes
- QA Release for validation scope

## Steps

1. Identify the layer that owns the behavior: domain, usecase, adapter,
   manifest, docs, or fixture.
2. Implement behavior in the lowest appropriate layer.
3. Update typed manifest sources:
   - `src/manifest/definitions.zig`
   - `src/manifest/types.zig`
   - `src/manifest/groups.zig`
4. Update `src/manifest/tool_catalog.json` for grouping, discovery keywords,
   docs, and compact `tool_arguments` hints.
5. Preserve `structuredContent` and text fallback output.
6. Add or update tests for schema, arguments, behavior, diagnostics conversion,
   path handling, and source-write gating as relevant.
7. Run `zig build tool-index` and verify `docs/tool-index.generated.md`.
8. Update HTTP or stdio smoke fixtures when registration, schema, transport
   shape, or representative output changes.

## Validation

```sh
zig build docs-check json-check
zig build test
```

Add this when MCP registration or transport output changes:

```sh
zig build smoke stdio-fixtures
```

Report which checks ran and any skipped checks.
