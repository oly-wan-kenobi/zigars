---
name: zigars-incremental-validation
description: Use when choosing what to validate after edits, when deciding between quick and standard validation depth, when ordering risk-ranked checks (format, ast-check, focused tests, broad build/test), or when an agent must justify what evidence the current change actually has.
---

# Zigars Incremental Validation

## Purpose

Use this skill to pick the cheapest sufficient validation for a change instead
of running everything or nothing. The skill orders checks by risk and keeps
skipped phases visible so downstream claims stay honest.

## Workflow

1. Orient with `zigars_context_pack` for project type, validation policy, and
   agent rules; note the workspace's existing validation depth defaults.
2. Compute the touched surface: `zig_changed_files_plan` or a git-derived
   diff, then `zig_impact_semantic` for semantic importer, test, and public-API
   coverage. Fall back to `zigars_impact` when the semantic index is
   unavailable.
3. Get the validation shape with `zigars_validation_plan` for the changed
   files: required command phases, read-only phases, `skipped_phases` with
   reasons, unknowns, and stop condition.
4. Use `zig_test_select_semantic` (or `zig_test_select`) to derive focused
   `zig build test` commands; otherwise the plan falls back to a broad
   `zig build test`.
5. Execute in risk order with `zigars_validation_run`: format and `ast-check`
   first, focused tests next, broad build/test only when public API,
   dependency, target, or release risk is present.
6. Finish with `zigars_validate_patch` (`quick` for low-risk patches,
   `standard` for risk-bearing changes) and read `failing_phases`,
   `skipped_phases`, and `next_diagnostic_tool` from the result.
7. For retained evidence across long-running validations, prefer
   `zigars_job_start` and `zigars_job_result` over one-shot commands so the
   evidence survives a handoff.

## Claim Boundary

- A passing phase only proves what that phase exercises; `skipped_phases`
  remain residual risk that must be reported.
- Heuristic impact (`zigars_impact`) is a text and import scan, not semantic
  dependency proof.
- Test selection is a recommendation; unselected tests are not proven safe to
  skip.
- Local pass is not hosted CI pass; `zigars-ci-forensics` owns CI evidence.

## Finish

Report:

- changed files and assessed risk;
- phases run, with the evidence they produced;
- phases skipped, with the reason for each;
- failing phases and the next diagnostic tool to call;
- the smallest additional phase that would most reduce residual uncertainty.
