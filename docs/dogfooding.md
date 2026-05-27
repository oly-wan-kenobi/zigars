# Dogfooding Strategy

Zigar development should use zigar as part of the normal development loop. The
goal is practical pressure on the MCP workflows, not self-modifying server
behavior.

## Principles

- Keep zigar a deterministic MCP server. Skills may guide agents, but server
  behavior remains tools, resources, prompts, validation, and structured results.
- Use zigar MCP tools before falling back to raw shell commands when the task is
  about Zig source, MCP workflow behavior, validation, docs, profiling, or
  package distribution.
- Treat friction as product evidence. If zigar makes a zigar task awkward, refine
  the matching tool, prompt, docs, or skill.
- Keep skill refinement in the repo, but ship skills separately from the MCP
  server package.

## Development Loop

1. Start with repo instructions and the smallest applicable `.agents/` workflow.
2. Ask zigar for workspace and client state with tools such as `zigar_doctor`,
   `zigar_client_guide`, `zigar_adoption_pack`, or `zigar_context_pack`.
3. Use zigar routing tools to choose the next action before editing Zig source or
   MCP workflow contracts.
4. Use `zigar_patch_guard` for planned edit paths when available.
5. Validate with zigar validation tools and the focused local commands required
   by the touched area.
6. Capture repeated agent friction as changes to
   `packages/zigar-skills-npm/skills/`.

## Skills Package

Zigar-specific skills live in `packages/zigar-skills-npm/` and are published as
`@zigars/skills`. This package is intentionally separate from `@zigars/mcp`.

The skills package may:

- ship skill folders for Codex, Claude Code, or other clients that support
  filesystem-style skills;
- include package-local helper commands for locating shipped skills;
- describe how to use zigar MCP tools effectively during development.

The skills package must not:

- change zigar's MCP server contract;
- install or edit a user's MCP client config automatically;
- imply that skills are a portable MCP server feature;
- widen zigar's workspace sandbox or source-write policy.

## Initial Skill

The first maintained skill is `zigar-development`. It routes zigar repo work
through zigar MCP startup checks, impact analysis, patch safety, validation, and
skill-refinement rules. It should stay concise; detailed mappings belong in
one-level reference files under the skill.

## Validation

For skill-package changes, run:

```sh
npm --prefix packages/zigar-skills-npm test
npm --prefix packages/zigar-skills-npm run pack:dry
```

Also run the active client skill validator when it is available. For Codex
skill-authoring sessions, use the `skill-creator` validator against each changed
skill directory.

For server, docs, npm shim, or MCPB changes, use the validation commands from
the applicable `.agents/` workflow and `AGENTS.md`.
