---
name: zigars-zig-version-migrator
description: Use when bumping a Zig project across toolchain versions for changes other than std.Io, when build.zig or package metadata needs updating for a new Zig release, when non-IO stdlib re-paths or language-reference drift need to be resolved, or when a single fix must be evaluated against the active Zig version's stdlib and language reference.
---

# Zigars Zig Version Migrator

## Purpose

Use this skill for the cross-version work that has no dedicated owner:
`build.zig` API changes, package metadata changes, non-IO stdlib re-paths,
language-reference drift, and version-scoped docs validation. Specialized
concerns route to their own skills so this one stays sharp.

## Workflow

1. Establish current and target versions with `zig_version`, `zig_env`,
   `zigars_env_pack`, `zigars_profile_read`, or `zigars_profile_validate`.
2. Route specialized concerns instead of duplicating their work:
   - `std.Io`, `std.posix`, `std.net.Address`, `std.time` migration for
     0.15 to 0.16 — switch to `zigars-io-016-migration`;
   - pinning Zig, ZLS, and backends for reproducibility — switch to
     `zigars-toolchain-pin-and-doctor`;
   - a specific compile error encountered during the bump — switch to
     `zigars-compile-error-triage`;
   - `build.zig.zon` hash mismatch — switch to `zigars-zon-hash-sync`.
3. For `build.zig` API changes (build steps, options, package definitions,
   install/output declarations), check the active version's docs with
   `zig_lang_ref_search_json`, `zig_langref_item`, and `zig_std_signature`
   before editing.
4. For non-IO stdlib re-paths (e.g. `std.fmt`, `std.heap`, `std.debug`
   reorganizations across releases), use `zig_std_search_json` and
   `zig_std_item_json` to confirm the new path before updating call sites.
5. For README, snippet, and docs example drift after a version bump,
   validate with `zig_doc_example_check`, `zig_snippet_check`, and
   `zig_readme_command_check`.
6. Validate on the intended Zig version (and a target/CI matrix when relevant)
   with `zigars-incremental-validation` rather than only the local default
   toolchain.

## Claim Boundary

- Do not apply stale Zig API knowledge without checking the active toolchain.
- Do not treat ZLS compatibility as compiler compatibility.
- This skill does not own `std.Io` migration, toolchain pinning, compile-error
  triage, or hash repair; route to the dedicated skill instead of duplicating
  their workflow.
- Migration is complete only when `build.zig`, package metadata, tests, and
  docs examples all agree on the intended Zig version.

## Finish

Report:

- current version and target version;
- `build.zig` and package metadata changes applied;
- non-IO stdlib re-paths handled;
- docs and snippet evidence checked;
- validation run on the intended version;
- remaining version-specific gaps and the skill that owns each.
