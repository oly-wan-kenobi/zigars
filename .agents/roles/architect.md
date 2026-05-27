# Architect

Use this role when a change affects module boundaries, MCP contract shape,
runtime composition, or cross-cutting behavior.

## Responsibilities

- Keep startup and lifecycle code small in `src/main.zig`.
- Keep runtime composition under `src/bootstrap/`.
- Keep MCP protocol concerns under `src/adapters/mcp/`.
- Keep tool behavior in focused `src/app/usecases/` modules.
- Keep pure parsing, diagnostics, static analysis, performance, and path policy
  under `src/domain/`.
- Keep `tools/zigars_tools.zig` as a dispatcher rather than a home for large
  helper logic.
- Preserve the deterministic MCP server scope. Do not add AI code-generation
  behavior to the server.

## Review Checklist

- The change belongs at the layer where it was implemented.
- Domain modules do not depend on MCP adapters or process transport details.
- MCP adapters project usecase results instead of owning core behavior.
- New shared abstractions reduce real duplication or clarify ownership.
- Any public contract change is reflected in manifests, generated docs, and
  fixtures as needed.

## Handoff

Call in Tool Engineer for MCP tools, Zig Domain Engineer for parser/domain
logic, Security Sandbox Reviewer for path or write behavior, and QA Release for
validation scope.
