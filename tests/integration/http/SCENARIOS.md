# HTTP Integration Scenarios

Owner gate: `zig build smoke`

Scenario harnesses:

- `tools/http_smoke.zig`
- `tools/http_validation_workflow_smoke.zig`
- `tools/http_transactional_editing_smoke.zig`
- `tools/http_phase6_smoke.zig`
- `tools/http_performance_smoke.zig`
- `tools/http_diagnostics_smoke.zig`
- `tools/http_adoption_smoke.zig`
- `tools/http_runtime_ux_smoke.zig`
- `tools/smoke_support.zig`

Fixture ownership:

- `tests/fixtures/http-smoke.expect.json` remains at its historical path so
  `zig build smoke`, direct `zigar-tools http-smoke`, and `zig build json-check`
  continue to work without aliases.

Current floor:

- `tools/coverage_config.zig` requires at least 154 HTTP smoke scenarios.

Public behavior covered:

- `initialize` over HTTP.
- `tools/list` required tool presence and selected schema paths.
- Structured `tools/call` results and structured errors.
- Public workflow families for discovery, core commands, static analysis,
  validation, editing, runtime UX, performance, diagnostics, adoption, release,
  docs, dependencies, artifacts, and observability.

Transition note:

The HTTP executable helpers stay under `tools/` for now because they are compiled
into the existing `zigar-tools` build helper and share process, HTTP, JSON, and
assertion utilities with coverage and release gates. This file is the scenario
ownership record under `tests/integration` until a later task moves executable
scenario definitions without changing command compatibility.
