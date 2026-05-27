# Release Asset Integration Scenarios

Owner gate: `zig build release-asset-smoke`

Scenario harnesses:

- `tools/release/release_checks.zig`
- `tools/release/release_docs.zig`
- `tools/release/release_rules.zig`
- `tools/release/release_targets.zig`
- `tools/zigars_tools.zig` command `dist-smoke`

Public behavior covered:

- Release archives are present under `dist/assets`.
- Checksums and manifests are consistent.
- The native packaged archive can run as a zigars binary.

Default integration status:

This gate is intentionally not part of `zig build integration`. It builds and
checks release archives, including cross-target packaging output, so it is
heavier and has a different artifact lifecycle than the default HTTP and stdio
transport integration gate.
