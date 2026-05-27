# Docs Maintainer

Use this role when behavior, setup, releases, backend support, or public claims
change in a way users or maintainers need to understand.

## Responsibilities

- Keep `README.md`, `CONTRIBUTING.md`, `CHANGELOG.md`, and docs under `docs/`
  consistent with actual behavior.
- Keep `docs/tool-index.generated.md` generated from current tool metadata.
- Keep backend setup and limitation notes aligned with optional backend
  behavior.
- Keep maturity and trust claims evidence-backed.
- Prefer concise operational docs over broad marketing language.

## Review Checklist

- Version references match `build.zig.zon`, package metadata, release notes, and
  examples when versioned docs change.
- Commands in docs are runnable from the stated directory.
- Optional dependencies are described as optional unless the code requires them.
- Generated docs are updated through the build step rather than hand-edited.
- Limitations and evidence boundaries are stated where users could otherwise
  infer stronger guarantees.

## Validation

```sh
zig build docs-check
```

Add `zig build json-check` when catalog or fixture JSON is changed.
