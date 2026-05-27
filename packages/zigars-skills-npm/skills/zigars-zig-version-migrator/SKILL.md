---
name: zigars-zig-version-migrator
description: Use when migrating a Zig project across Zig versions, resolving Zig/ZLS/toolchain mismatches, handling stdlib or language-reference drift, updating build.zig/build.zig.zon version constraints, or validating version-specific compiler errors.
---

# Zigars Zig Version Migrator

## Purpose

Use this skill when a change depends on the active Zig version. Keep all advice
version-scoped and verify stdlib, language, ZLS, and package assumptions against
the configured toolchain.

## Workflow

1. Establish the target and current versions with `zig_version`, `zig_env`,
   `zigars_env_pack`, `zig_toolchain_resolve`, `zig_toolchain_pin_check`,
   `zigars_profile_read`, or `zigars_profile_validate`.
2. Check editor and backend compatibility with `zig_zls_match_check`,
   `zigars_backend_guidance`, and `zigars_backend_verify` when backend behavior is
   part of the task.
3. Use local, version-aware docs tools before giving language or stdlib advice:
   `zig_std_search_json`, `zig_std_item_json`, `zig_std_signature`,
   `zig_lang_ref_search_json`, and `zig_langref_item`.
4. Classify migration failures with `zig_compile_error_index`,
   `zig_explain_errors`, `zig_io_migration_scan`, `zig_comptime_diagnose`,
   and focused source inspection.
5. Update docs examples and README commands only after checking snippets with
   `zig_doc_example_check`, `zig_snippet_check`, or
   `zig_readme_command_check`.
6. Validate on the intended Zig version and, when relevant, with a target or CI
   matrix rather than only the local default toolchain.

## Claim Boundary

- Do not apply stale Zig API knowledge without checking the active toolchain.
- Do not treat ZLS compatibility as compiler compatibility.
- Do not say a migration is complete until package metadata, build commands,
  tests, and docs examples agree on the intended Zig version.

## Finish

Report current version, target version, changed assumptions, compiler evidence,
docs evidence, validation run, and remaining version-specific gaps.
