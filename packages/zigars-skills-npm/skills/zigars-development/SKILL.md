---
name: zigars-development
description: Use when developing zigars itself, including Zig MCP server code, repo docs, release/package tooling, zigars npm packages, MCP workflow prompts, or zigars-specific agent skills. Route work through zigars MCP dogfooding workflows, patch safety, Zig 0.16 validation, and skill refinement practices.
---

# Zigars Development

## Overview

Use zigars while working on zigars. Keep the MCP server deterministic: add tools,
prompts, resources, docs, package metadata, and validation workflows, not AI
code-generation behavior inside the server.

## Startup

1. Read the applicable repo instructions, including `AGENTS.md` and the
   smallest matching `.agents/` role or workflow.
2. If the zigars MCP server is connected, call `zigars_doctor` with
   `probe_backends=false` and use `zigars_client_guide` or
   `zigars_adoption_pack` when client behavior or setup is part of the task.
   For setup ambiguity, prefer `zigars_setup_guidance`,
   `zigars_profile_guidance`, and `zigars_backend_guidance`; the older
   `_elicit` names are compatibility aliases.
3. For Zig-source work, prefer zigars routing tools before shell commands:
   `zigars_context_pack`, `zigars_next_action`, `zig_file_owner`,
   `zig_workspace_symbol_cache`, `zigars_impact`, or `zig_impact_semantic`
   depending on what the connected server exposes.
4. Before broad edits or generated patches, run `zigars_patch_guard` on the
   target paths when available.

If a listed zigars tool is unavailable, inspect `tools/list` or use the closest
available zigars workflow tool before falling back to direct shell commands.

## Workflow Routing

- Compile or test failures: use `zigars_next_action`, retained build/test jobs,
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
  tools that mutate files or run effectful captures. Patch-session apply may
  use MCP `elicitation/create` when the client supports it, but stale preimages
  and `apply=true` remain mandatory.
- Package or distribution changes: keep package files explicit, avoid install
  side effects, and preserve stdout for MCP JSON-RPC in server-facing launchers.
- Skill changes: keep `SKILL.md` concise, put only directly useful references
  under `references/`, and validate the skill folder before finishing.
- Failure summaries: `zigars_failure_fusion` can use MCP
  `sampling/createMessage` only when `summarize=true` and the client supports
  sampling; unsupported clients keep deterministic failure evidence.

Read `references/workflow-map.md` when the task needs a more detailed mapping
from zigars development work to zigars MCP tools and validation gates.

## Finish Gate

Use the narrowest validation that proves the change:

- Zig/server changes: `zig fmt build.zig build.zig.zon src tools`, then
  `zig build test` or a focused zigars validation workflow.
- Docs or generated-index changes: `zig build docs-check`; add `json-check`
  when catalog or fixture JSON changes.
- npm package changes: run the package-local Node/Bun build or tests listed in
  that package.
- Skill package changes: run the package-local tests and the skill validator for
  each changed skill.

Report which zigars MCP calls and local commands were run, and say directly when
validation was skipped or a zigars tool was unavailable.
