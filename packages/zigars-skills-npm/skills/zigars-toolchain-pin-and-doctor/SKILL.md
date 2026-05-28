---
name: zigars-toolchain-pin-and-doctor
description: Use when configuring a Zig project for reproducible builds, when pinning Zig and ZLS versions, when bootstrapping or repairing .zigars/profile.json, when installing or conforming optional backends (Tracy, Samply, Valgrind, AFL++, ZLint), or when zigars_doctor reports a mismatched toolchain.
---

# Zigars Toolchain Pin And Doctor

## Purpose

Use this skill to make a project's Zig toolchain, ZLS, and optional backends
reproducible on this machine. The skill is scoped to setup and conformance, not
to scaffolding new projects or refactoring existing source.

## Workflow

1. Run `zigars_doctor` with `probe_backends: false` first to capture current
   toolchain, ZLS, workspace facts, and profile state without slow probes.
2. For first-time configuration, call `zigars_setup_guidance`; for narrower
   prompts use `zigars_profile_guidance` and `zigars_backend_guidance`. These
   return questions and unknowns rather than blocking on interactive input.
3. Generate or update the project profile with `zigars_project_profile_v2`
   (preview, then `apply: true`). Validate with `zigars_profile_validate`;
   compare against an existing profile with `zigars_profile_diff` when
   relevant.
4. Pin the Zig toolchain with `zig_toolchain_pin` and confirm ZLS alignment
   with `zig_zls_match_check`. Resolve mismatches by upgrading ZLS, downgrading
   Zig, or recording the gap in the profile.
5. For optional backends, request a plan from `zigars_backend_install_plan`,
   install per the plan, then verify with `zigars_backend_conformance` to bind
   backend identity to a known version.
6. Regenerate developer environment files (shell config, MCP client config,
   etc.) with `zigars_dev_env_generate` (`apply: true` gated).
7. Re-run `zigars_doctor` (optionally with `probe_backends: true`) to confirm a
   clean state before claiming the toolchain is pinned.

## Claim Boundary

- A pinned profile binds this project to a toolchain on this machine; remote
  hosts and CI must run their own `zigars_doctor` to confirm parity.
- Backend conformance proves an installed backend matches a known version, not
  that every backend feature works for every Zig target.
- This skill does not scaffold new projects, choose architecture, or refactor
  existing source.

## Finish

Report:

- pinned Zig and ZLS versions;
- profile written (path, schema version);
- backends installed and their conformance status;
- `zigars_doctor` summary after setup, including any remaining unknowns.
