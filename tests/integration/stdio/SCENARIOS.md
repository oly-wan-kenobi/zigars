# Stdio Integration Scenarios

Owner gate: `zig build stdio-fixtures`

Scenario harnesses:

- `tools/integration/stdio/stdio_fixtures.zig`
- `tools/integration/stdio/stdio_validation_workflow_fixtures.zig`
- `tools/integration/stdio/stdio_transactional_editing_fixtures.zig`
- `tools/integration/stdio/stdio_environment_fixtures.zig`
- `tools/integration/stdio/stdio_runtime_ux_fixtures.zig`
- `tools/integration/stdio/stdio_adoption_fixtures.zig`
- `tools/integration/smoke_support.zig`

Generated fixture workspace:

- `tools/integration/stdio/stdio_fixtures.zig` creates a temporary `.zig-cache/zigar-fixtures-*`
  workspace containing Zig source files, malformed source, folded-stack inputs,
  and fake backend launchers.

Fake backend coverage:

- `fake-zwanzig`
- `fake-zlint`
- `fake-zflame`
- `fake-diff-folded`

Current floor:

- `tools/coverage/coverage_config.zig` requires at least 76 stdio fixture tool calls.

Public behavior covered:

- `initialize`, `notifications/initialized`, `tools/list`, `resources/list`,
  `resources/read`, `prompts/list`, and `prompts/get`.
- Public `tools/call` behavior for formatting, patch preview, validation,
  static analysis, docs, linting, ZLint, semantic refs, graphs, profiling,
  diagnostics, environment, runtime UX, adoption, and conformance report flows.

Transition note:

The stdio executable helpers remain under `tools/integration/stdio/` because
they need to spawn the built `zigar` binary, install fake backend launchers that
delegate to `zigar-tools`, and share JSON/path assertions with the HTTP smoke
helpers.
