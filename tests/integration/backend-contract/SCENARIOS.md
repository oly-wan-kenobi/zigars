# Fake Backend Contract Scenarios

Owner gates:

- `zig build backend-conformance-contract`
- `zig build release-check`

Scenario harnesses:

- `tests/integration/backend-contract/scenarios.zig`
- `.github/scripts/backend-conformance-contract-smoke.sh`
- `.github/scripts/backend-conformance.sh`

Scenario manifest:

- `zls_document_symbols`
- `zlint_diagnostics_json`
- `zlint_sarif`
- `zlint_rules`
- `zlint_fix_preview`
- `zwanzig_lint_json`
- `zwanzig_lint_sarif`
- `zwanzig_lint_rules`
- `zwanzig_analysis_graphs_cfg`
- `zflame_recursive_folded_svg`
- `diff_folded_recursive_svg_intermediate`

Fake backend coverage:

- fake ZLS document symbols.
- fake ZLint diagnostics, SARIF, rules, and AST refs.
- fake zwanzig diagnostics and graph output.
- fake zflame SVG output.
- fake diff-folded output.

Public behavior covered:

- Backend conformance report schema version, result status, source metadata,
  SHA-256 fields, compatibility matrix rows, and required scenario names.
- Scenario-manifest drift between `tests/integration/backend-contract`,
  `.github/scripts/backend-conformance.sh`, and
  `.github/scripts/backend-conformance-contract-smoke.sh`.

Transition note:

The script-backed fake backend contract remains under `.github/scripts` because
it is also the release-check conformance driver and shells out to Python for report
validation. `tests/integration/backend-contract/scenarios.zig` owns scenario
discovery; `zig build backend-contract-scenarios`,
`zig build backend-conformance-contract`, and `zig build release-check` fail when
the manifest, docs, contract harness, or smoke-required tuple drift. Real
optional backend conformance stays separate and opt-in.
