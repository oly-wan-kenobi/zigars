---
name: zigars-safe-refactor
description: Use when planning, reviewing, or applying nontrivial Zig source changes, refactors, declaration moves, import updates, public API edits, generated/vendor path edits, or validation depth decisions for a risky patch.
---

# Zigars Safe Refactor

## Purpose

Use this skill when a Zig change can affect more than the visible edit. The
skill coordinates impact analysis, edit safety, and validation depth while
leaving deterministic checks to zigars MCP tools.

## Workflow

1. Orient on the workspace and change goal with `zigars_context_pack`,
   `zigars_next_action`, `zig_changed_files_plan`, or
   `zigars_validation_plan` when available.
2. Map ownership and structure before editing:
   `zig_file_owner`, `zig_import_cycles`, `zig_module_surface`,
   `zig_symbol_dossier`, `zig_insertion_sites`, `zig_impact_semantic`,
   and `zig_test_select_semantic` when supported.
3. Check edit boundaries with `zig_generated_file_trace`,
   `zigars_edit_policy_check`, or `zigars_generated_route` before touching
   generated, cache, artifact, vendored, or output paths.
4. For public API or behavior-facing changes, inspect `zig_public_api_diff`,
   `zig_api_check`, test candidates, and docs impact before claiming safety.
5. Use preview-first write paths. For zigars mutating tools, require
   `apply=true`; for patch sessions, require matching preimages.
6. Validate in risk order: formatting and AST checks first, focused tests next,
   broader build/test or CI evidence when public API, dependency, target, or
   release risk is present.

## Claim Boundary

- Test selection is a recommendation, not proof that unselected tests can be
  skipped.
- Parser-backed and advisory findings guide where to look; they do not replace
  compiler, test, or CI evidence.
- Generated artifacts should be changed through their source inputs or
  regeneration path, not edited directly.

## Finish

Summarize changed surface area, evidence gathered before editing, validation
run, skipped phases, and residual risk.
