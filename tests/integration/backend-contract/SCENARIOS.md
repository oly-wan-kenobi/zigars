# Fake Backend Contract Scenarios

Owner gates:

- `zig build backend-conformance-contract`
- `zig build release-check`

Scenario harnesses:

- `.github/scripts/backend-conformance-contract-smoke.sh`
- `.github/scripts/backend-conformance.sh`

Fake backend coverage:

- fake ZLS document symbols.
- fake ZLint diagnostics, SARIF, rules, and AST refs.
- fake zwanzig diagnostics and graph output.
- fake zflame SVG output.
- fake diff-folded output.

Public behavior covered:

- Backend conformance report schema version, result status, source metadata,
  SHA-256 fields, compatibility matrix rows, and required scenario names.

Transition note:

The script-backed fake backend contract remains under `.github/scripts` because
it is also the release-check conformance driver and shells out to Python for
report validation. `tests/integration/backend-contract` owns scenario discovery;
real optional backend conformance stays separate and opt-in.
