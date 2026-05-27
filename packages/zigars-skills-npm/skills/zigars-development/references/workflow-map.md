# Zigars Development Workflow Map

Use this reference when a zigars development task needs more than the quick
workflow in `SKILL.md`.

## Server And Tooling Work

For MCP tool behavior, schema, grouping, discovery, planning policy, or risk
metadata changes:

1. Read `.agents/workflows/tool-change.md` and the relevant role file.
2. Use `zigars_context_pack` or `zigars_adoption_pack` to establish workspace and
   backend state.
3. Use `zigars_patch_guard` on planned paths before editing.
4. Keep these files synchronized when the public tool contract changes:
   `src/manifest/tool_catalog.json`, `src/manifest/definitions.zig`,
   `src/manifest/types.zig`, `src/manifest/groups.zig`, and
   `docs/tool-index.generated.md`.
5. Validate with `zig build tool-index`, `zig build docs-check`, and the
   focused Zig tests for the touched usecase or adapter.

## Zig Source Work

Use zigars to narrow the affected surface before editing:

- `zig_file_owner` for a file-to-build-target hint.
- `zig_workspace_symbol_cache` for repeated symbol/import searches.
- `zigars_impact` or `zig_impact_semantic` to identify likely tests and public
  API risk.
- `zigars_validation_plan` before running broad validation.
- `zigars_validate_patch` or `zigars_validation_run` before handoff.

Prefer compiler-backed, parser-backed, or ZLS-backed evidence over heuristic
matches when claiming correctness.

## Skills Work

Zigars-specific skills are repo-maintained client artifacts. They must not become
server runtime behavior.

- Keep shipped skills under `packages/zigars-skills-npm/skills/<skill-name>/`.
- Keep each skill folder self-contained with `SKILL.md`, optional
  `agents/openai.yaml`, and optional one-level `references/`.
- Do not add Python helper scripts to this repo for skills.
- Prefer short workflow instructions that route agents to zigars MCP tools.
- Validate changed skills with the skill validator and package-local tests.

## Distribution Work

The skills package is separate from the MCP server package:

- `@zigars/mcp` launches the local zigars MCP server.
- `@zigars/skills` ships client-consumable skills that can mention zigars MCP.
- The skills package must not widen zigars workspace access, install MCP
  configuration automatically, or claim skills are part of base MCP.
- Client-specific install helpers are allowed only when they are explicit,
  previewable, and documented.
