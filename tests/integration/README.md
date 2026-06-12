# Integration Scenario Manifests

This directory contains build-enforced integration scenario manifests.
Executable HTTP and stdio integration harnesses live under `tools/integration/`
and are dispatched through the existing `zigars-tools` helper binary.

Current contents:

- `backend-contract/scenarios.zig` is the fake optional-backend scenario manifest
  imported by `zigars-tools`.
- `backend-contract/SCENARIOS.md` is the human-readable companion checked for
  drift against the manifest and backend conformance scripts.

Related build gates:

- `zig build integration` runs the default transport integration gates:
  `zig build smoke` and `zig build stdio-fixtures`.
- `zig build backend-contract-scenarios` checks fake backend scenario drift.
- `zig build backend-conformance-contract` smoke-tests the fake backend
  conformance report contract.
- `zig build public-contracts` includes backend scenario drift and other public
  MCP contract checks.
- `zig build release-asset-smoke` remains a separate packaging gate because it
  builds and verifies release archives rather than ordinary transport behavior.

HTTP smoke and stdio fixture floors are owned by
`tools/coverage/coverage_config.zig`; avoid duplicating numeric floor values in
this README.

Maintenance rules:

- Keep executable HTTP and stdio fixture code under `tools/integration/` unless
  the build topology changes.
- Keep this directory limited to manifests and companion docs that are checked by
  build gates.
- Assert public MCP schema, transport, tool-call, and artifact behavior only.
- Do not assert internal module paths or handler implementation details.
