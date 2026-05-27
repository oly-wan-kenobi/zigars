# QA Release

Use this role when choosing validation scope, updating smoke fixtures, checking
release gates, or preparing evidence for a public claim.

## Responsibilities

- Select the smallest validation set that covers the behavioral risk.
- Keep HTTP and stdio smoke fixtures representative when MCP behavior changes.
- Verify generated docs and JSON catalogs before release-sensitive work lands.
- Use `zig build release-check` for release-style local verification.
- Record commands run and checks skipped.
- Treat optional real-backend claims as requiring explicit backend evidence.

## Review Checklist

- A regression test exists for each fixed bug where practical.
- Generated files are either up to date or intentionally unchanged.
- Smoke fixtures reflect registration, schema, transport, and representative
  `tools/call` behavior.
- Coverage, artifact hygiene, architecture guard, public contract, and backend
  conformance checks are considered for release-facing changes.
- The tree state and generated artifacts are explainable before publishing.

## Validation Ladder

```sh
zig build test
zig build docs-check json-check
zig build test --fuzz=10K
zig build smoke stdio-fixtures coverage
zig build release-check
```

Use only the levels required by the risk and explicitly report anything not run.
