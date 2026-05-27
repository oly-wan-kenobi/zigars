# Zigar Development Workflow Map

Use this reference when a zigar development task needs more than the quick
workflow in `SKILL.md`.

## Server And Tooling Work

For MCP tool behavior, schema, grouping, discovery, planning policy, or risk
metadata changes:

1. Read `.agents/workflows/tool-change.md` and the relevant role file.
2. Use `zigar_context_pack` or `zigar_adoption_pack` to establish workspace and
   backend state.
3. Use `zigar_patch_guard` on planned paths before editing.
4. Keep these files synchronized when the public tool contract changes:
   `src/manifest/tool_catalog.json`, `src/manifest/definitions.zig`,
   `src/manifest/types.zig`, `src/manifest/groups.zig`, and
   `docs/tool-index.generated.md`.
5. Validate with `zig build tool-index`, `zig build docs-check`, and the
   focused Zig tests for the touched usecase or adapter.

## Zig Source Work

Use zigar to narrow the affected surface before editing:

- `zig_file_owner` for a file-to-build-target hint.
- `zig_workspace_symbol_cache` for repeated symbol/import searches.
- `zigar_impact` or `zig_impact_semantic` to identify likely tests and public
  API risk.
- `zigar_validation_plan` before running broad validation.
- `zigar_validate_patch` or `zigar_validation_run` before handoff.

Prefer compiler-backed, parser-backed, or ZLS-backed evidence over heuristic
matches when claiming correctness.

## Skills Work

Zigar-specific skills are repo-maintained client artifacts. They must not become
server runtime behavior.

- Keep shipped skills under `packages/zigar-skills-npm/skills/<skill-name>/`.
- Keep each skill folder self-contained with `SKILL.md`, optional
  `agents/openai.yaml`, and optional one-level `references/`.
- Do not add Python helper scripts to this repo for skills.
- Prefer short workflow instructions that route agents to zigar MCP tools.
- Validate changed skills with the skill validator and package-local tests.

## Distribution Work

The skills package is separate from the MCP server package:

- `@zigars/mcp` launches the local zigar MCP server.
- `@zigars/skills` ships client-consumable skills that can mention zigar MCP.
- The skills package must not widen zigar workspace access, install MCP
  configuration automatically, or claim skills are part of base MCP.
- Client-specific install helpers are allowed only when they are explicit,
  previewable, and documented.
