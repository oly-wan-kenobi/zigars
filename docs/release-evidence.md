# Release Evidence Notes

This file records local release/adoption hardening evidence that is useful for a
maintainer handoff. It is not a substitute for clean-tree `Release Readiness`
workflow evidence when release notes claim public optional-backend support.

## Phase 7 Docs, Skills, Release, And Adoption

Date: 2026-05-27

Scope:

- Reconcile public docs, package README text, and skill guidance with the
  shipped Phase 1-6 surface.
- Keep `zigars_setup_guidance`, `zigars_profile_guidance`, and
  `zigars_backend_guidance` as the primary setup names while preserving
  `_elicit` aliases for older clients.
- Document shipped protocol fallbacks: declared `outputSchema`, artifact
  `resource_link` blocks, `zigars_patch_session_apply` protocol elicitation, and
  `zigars_failure_fusion summarize=true` protocol sampling.
- Preserve the existing session file shape under
  `.zigars-cache/sessions/<kind>/<id>.jsonl`.

Validation run for this phase:

- `zig version` -> passed, reported `0.16.0`.
- `zig build tool-index` -> passed.
- `zig fmt build.zig build.zig.zon src tools` -> passed.
- `zig build test --summary all` -> passed, 911/911 tests.
- `zig build docs-check json-check --summary all` -> passed.
- `zig build smoke stdio-fixtures --summary all` -> passed.
- `zig build -Doptimize=ReleaseSafe --summary all` -> passed.
- `git diff --check` -> passed.
- `npm run build` in `packages/@zigars/mcp` -> passed.
- `npm run test:node` in `packages/@zigars/mcp` -> passed, 24/24 tests.
- `bun run test:bun` in `packages/@zigars/mcp` -> passed, 24/24 tests.
- `npm pack --dry-run` in `packages/@zigars/mcp` -> passed.
- `npm test` in `packages/@zigars/skills` -> passed, 4/4 tests.
- `npm run pack:dry` in `packages/@zigars/skills` -> passed.
- `zig build artifact-hygiene --summary all` -> failed on unrelated existing
  line-budget checks in MCP adapter, manifest, and fixture files not changed by
  this phase.

Known limitations:

- This note does not claim real optional-backend validation.
- This note does not claim GitHub release asset, npm publish, or MCPB install
  success until those package/release checks are run for the exact release
  commit.
