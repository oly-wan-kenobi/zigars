# Agent Instructions

These instructions apply to `tools/` and child directories.

## Scope

This directory contains local helper, quality, release, coverage, fixture, and
integration tooling for the repository.

## Local Rules

- Keep `tools/zigars_tools.zig` as a dispatcher. Move substantial helper logic
  into focused Zig modules under `tools/`.
- Keep helper tooling pure Zig; do not add Python helper scripts.
- Preserve artifact hygiene: do not require generated release artifacts,
  coverage output, local caches, `zig-out/`, or `.zig-cache/` to be tracked.
- Keep release, architecture, coverage, fixture, and public-contract checks
  deterministic and runnable from the repository root.
- When tooling changes generated outputs or release/package behavior, update the
  corresponding docs and validation commands.
- Send diagnostics to stderr when building command-line helpers that may produce
  machine-readable stdout.

## Validation

For tooling changes, run the most focused relevant build step first. For
release, artifact, or generated-output changes, add:

```sh
zig build artifact-hygiene
```

Use `zig build release-check` for release-style changes or when several tool
surfaces are affected.
