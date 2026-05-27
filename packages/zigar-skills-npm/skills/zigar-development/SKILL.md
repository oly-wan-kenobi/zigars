---
name: zigar-development
description: Use when developing zigar itself, including Zig MCP server code, repo docs, release/package tooling, zigar npm packages, MCP workflow prompts, or zigar-specific agent skills. Route work through zigar MCP dogfooding workflows, patch safety, Zig 0.16 validation, and skill refinement practices.
---

# Zigar Development

## Overview

Use zigar while working on zigar. Keep the MCP server deterministic: add tools,
prompts, resources, docs, package metadata, and validation workflows, not AI
code-generation behavior inside the server.

## Startup

1. Read the applicable repo instructions, including `AGENTS.md` and the
   smallest matching `.agents/` role or workflow.
2. If the zigar MCP server is connected, call `zigar_doctor` with
   `probe_backends=false` and use `zigar_client_guide` or
   `zigar_adoption_pack` when client behavior or setup is part of the task.
3. For Zig-source work, prefer zigar routing tools before shell commands:
   `zigar_context_pack`, `zigar_next_action`, `zig_file_owner`,
   `zig_workspace_symbol_cache`, `zigar_impact`, or `zig_impact_semantic`
   depending on what the connected server exposes.
4. Before broad edits or generated patches, run `zigar_patch_guard` on the
   target paths when available.

If a listed zigar tool is unavailable, inspect `tools/list` or use the closest
available zigar workflow tool before falling back to direct shell commands.

## Workflow Routing

- Compile or test failures: use `zigar_next_action`, retained build/test jobs,
  failure fusion, then focused validation.
- MCP tool or schema changes: check the manifest/docs sync requirements before
  editing, then validate generated contract drift.
- Architecture-neutral planning: use `zig_import_cycles`,
  `zig_module_surface`, `zig_symbol_dossier`, `zig_change_risk_audit`, and
  `zig_insertion_sites` before broad structural edits. Use
  `zig_test_name_resolve`, `zig_test_fixture_inventory`,
  `zig_safety_site_catalog`, and `zig_test_for_symbol` for bounded test and
  safety-review evidence.
- Source writes: keep preview-first behavior and require `apply=true` for MCP
  tools that mutate files or run effectful captures.
- Package or distribution changes: keep package files explicit, avoid install
  side effects, and preserve stdout for MCP JSON-RPC in server-facing launchers.
- Skill changes: keep `SKILL.md` concise, put only directly useful references
  under `references/`, and validate the skill folder before finishing.

Read `references/workflow-map.md` when the task needs a more detailed mapping
from zigar development work to zigar MCP tools and validation gates.

## Finish Gate

Use the narrowest validation that proves the change:

- Zig/server changes: `zig fmt build.zig build.zig.zon src tools`, then
  `zig build test` or a focused zigar validation workflow.
- Docs or generated-index changes: `zig build docs-check`; add `json-check`
  when catalog or fixture JSON changes.
- npm package changes: run the package-local Node/Bun build or tests listed in
  that package.
- Skill package changes: run the package-local tests and the skill validator for
  each changed skill.

Report which zigar MCP calls and local commands were run, and say directly when
validation was skipped or a zigar tool was unavailable.
