---
name: zigar-evidence-contract
description: Use when auditing final claims from zigar MCP results, especially "done", "safe", "validated", "release-ready", skipped validation, omitted sections, advisory static analysis, preview-only execution, optional backend gaps, CI evidence, or handoff summaries.
---

# Zigar Evidence Contract

## Purpose

Use this skill to decide what an agent is allowed to claim after using zigar.
The skill is about evidence interpretation, not running every possible check.

## Workflow

1. Identify the claim being made: done, safe, validated, release-ready,
   regression-free, backend-supported, or locally reproduced.
2. Collect the strongest available evidence with zigar before summarizing:
   `zigar_result_shape`, `zigar_output_budget_plan`,
   `zigar_validation_plan`, `zigar_validation_run`,
   `zigar_validation_history`, `zigar_trust_report`,
   `zigar_risk_audit`, `zigar_artifact_index`, and
   `zigar_artifact_read` when available.
3. Classify each evidence item as compiler-backed, parser-backed, CI-derived,
   user-supplied, advisory, preview-only, skipped, omitted, or unavailable.
4. If a result is compact, inspect `omitted_sections`. Rerun with a deeper mode
   or bounded limit before using omitted evidence in a claim.
5. Treat optional backend setup, configured paths, probes, fake fixtures, and
   planning output as weaker than real backend execution or citable CI evidence.
6. Keep preview-only command, debugger, profiler, fuzzer, emulator, and artifact
   writes separate from applied execution.

## Claim Boundary

- Do not say validation passed when a phase was skipped, omitted, truncated, or
  only planned.
- Do not treat advisory static analysis as proof of semantic correctness.
- Do not treat local success as hosted CI success.
- Do not treat artifact existence as provenance unless the artifact identity and
  producing command are known.
- Say directly when a zigar tool is unavailable and what evidence replaces it.

## Finish

Report:

- claim being evaluated;
- strongest supporting evidence;
- gaps and skipped checks;
- confidence level;
- next validation that would most reduce uncertainty.
