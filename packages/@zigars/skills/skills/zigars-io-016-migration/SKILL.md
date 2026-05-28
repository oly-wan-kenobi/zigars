---
name: zigars-io-016-migration
description: Use when migrating a Zig project from 0.15 to 0.16, when std.io.Reader/Writer, std.net.Address, std.time.Instant/Timer, std.fs, or std.posix call sites need updating to std.Io, or when a project reports "extremely breaking" IO compile errors after a toolchain bump.
---

# Zigars IO 0.16 Migration

## Purpose

Use this skill to audit and migrate `std.io.*`, `std.net.Address`, `std.time`,
`std.fs`, and `std.posix` call sites to Zig 0.16's `std.Io` interface. The skill
keeps the audit parser-backed and the rewrites preview-gated so a multi-file
migration is reviewable batch by batch.

## Workflow

1. Confirm the target Zig version with `zig_zls_match_check` and
   `zigars_workspace_info`; the migration is scoped to 0.15 to 0.16 unless an
   explicit `from_version` or `to_version` is supplied.
2. Call `zig_io_migration_scan` over the workspace. Read each finding's `file`,
   `line`, `pattern`, `recommended_replacement`, and `mapping_confidence`
   (`exact`, `likely`, or `manual_review`).
3. Prioritize files by unmigrated call count; group `exact` findings into the
   first batch and split `likely` and `manual_review` into separate review
   passes.
4. For each batch, plan with `zigars_validation_plan` for the touched files,
   then use `zigars_patch_session_create`, `zigars_patch_session_preview`, and
   `zigars_patch_session_apply` so multi-file rewrites land atomically with
   recorded `expected_preimages`.
5. After each applied batch, run `zigars_validate_patch` in `standard` mode so
   `zig ast-check` and `zig build test` cover the migration before the next
   batch.
6. When library-facing files change, run `zig_public_api_diff` to surface
   breaking API changes that downstream consumers will need to mirror.
7. Iterate until `zig_io_migration_scan` returns zero unmigrated patterns or
   only `manual_review` entries explained in the handoff.

## Claim Boundary

- `exact` mappings are mechanical replacements; `likely` mappings still need a
  human read for semantic equivalence (e.g. proactor versus reactor semantics).
- The scan is parser-backed; runtime behavior of `std.Io` differs from
  `std.io` in ways AST evidence cannot prove.
- Migration is complete only when `zig build test` passes against the 0.16
  toolchain, not when the scan returns no findings.

## Finish

Report:

- files migrated and files remaining;
- counts by `mapping_confidence`;
- patch sessions applied;
- post-batch validation status and any `manual_review` entries deferred.
