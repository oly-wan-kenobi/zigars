# Integration Test Ownership

This directory owns integration scenario discovery for built-binary MCP behavior.
The executable harnesses remain under `tools/` during Phase 10 because `zig build`
already compiles `zigar-tools` once and uses it to run smoke, fixture, coverage,
release, and architecture helper commands without adding a second helper target.

Default integration gate:

```text
zig build integration
```

Current delegation:

- `zig build smoke` covers HTTP MCP transport scenarios.
- `zig build stdio-fixtures` covers stdio MCP transport scenarios and fake backend success paths.
- `zig build backend-contract-scenarios` checks fake backend conformance
  scenario discovery against the executable contract harnesses.

Scenario floors remain enforced by `tools/coverage_config.zig`:

- HTTP smoke scenarios: at least 154.
- Stdio fixture tool calls: at least 76.

`zig build release-asset-smoke` remains an explicit release packaging gate rather
than part of the default integration alias because it builds cross-target release
archives under `dist/assets` and verifies packaged assets instead of ordinary
transport behavior.

Public contract gate:

```text
zig build public-contracts
```

This direct gate checks MCP no-patch, advertised capability, schema, structured
argument-error, resource/prompt fixture, scenario-manifest drift, and report
contract invariants. It is also part of `zig build release-check`.

Rules:

- Assert public MCP schema, transport, tool-call, and artifact behavior only.
- Do not assert internal module paths or handler implementation details.
- Keep compatibility for existing fixture paths and build commands.
- Raise floors only after new scenarios land; do not lower floors without a
  reviewed companion-doc reason.
