---
name: zigar-ci-forensics
description: Use when triaging CI failures, GitHub Actions logs, annotations, JUnit, SARIF, matrix failures, platform-only failures, Zig-version-only failures, or local reproduction plans from CI evidence.
---

# Zigar CI Forensics

## Purpose

Use this skill when CI artifacts are the primary evidence. The goal is to
preserve raw CI authority while using zigar to normalize, group, and reproduce
failures locally.

## Workflow

1. Preserve the raw artifact first: log text, annotation payload, JUnit XML,
   SARIF, matrix entry, job name, platform, Zig version, command, and commit.
2. Ingest evidence with `zig_ci_ingest`, `zig_ci_annotations`, `zig_junit`,
   `zig_matrix_check`, and `zig_ci_failure_map` when available.
3. Use parser confidence, raw-reference hashes, and limitations from zigar
   results when ranking failures.
4. Build a local reproduction plan with `zig_ci_repro_plan`, changed-file hints,
   `zigar_validation_plan`, and focused build/test commands.
5. Run local validation only when it is safe and useful. Keep local results
   separate from hosted CI status.
6. If the failure is matrix-specific, preserve target, platform, Zig version,
   optional backend status, and unavailable local reproduction constraints.

## Claim Boundary

- Raw CI artifacts remain authoritative.
- A local pass does not prove hosted CI is green.
- Parsed annotations and JUnit summaries do not replace raw logs when the parser
  reports partial confidence or command-level scope.
- Do not claim a matrix failure is fixed until the corresponding matrix leg has
  passing evidence or the missing rerun is stated.

## Finish

Report primary failure, raw artifact identity, parser confidence, repro command,
local evidence, CI evidence still missing, and the next CI check needed.
