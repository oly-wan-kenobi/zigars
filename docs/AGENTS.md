# Agent Instructions

These instructions apply to `docs/` and child directories.

## Scope

This directory contains user-facing and maintainer-facing documentation. Keep
docs concise, operational, and aligned with actual code, release, and package
behavior.

## Local Rules

- Do not hand-edit `docs/tool-index.generated.md`; regenerate it with
  `zig build tool-index` when tool metadata changes.
- Keep public claims evidence-backed. Distinguish implemented behavior,
  optional backend-backed behavior, prototypes, and planned work.
- Keep command examples runnable from the directory they state.
- Keep distribution docs synchronized with package metadata, release artifacts,
  checksums, and launcher behavior.
- Describe optional dependencies as optional unless code requires them.
- Prefer concrete workflows, limitations, and validation steps over broad
  marketing language.

## Validation

For documentation-only changes, run:

```sh
zig build docs-check
```

Add `zig build json-check` when docs reference catalog, fixture, package, or
manifest JSON behavior.
