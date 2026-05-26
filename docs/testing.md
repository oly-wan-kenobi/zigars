# Testing And Coverage

zigar uses layered tests so transport behavior, tool registration, and backend
argument wiring are checked separately from the unit tests.

## Local Gate

Run the same release-style gate used before publishing:

```sh
zig build release-check
```

`release-check` is intentionally broader than test execution. It also checks
generated docs/JSON drift, ReleaseSafe compilation, HTTP/stdio transport smoke
fixtures, kcov line coverage floors, fake-backend conformance report contracts,
artifact hygiene, structured tool-error contracts, and line-budget headroom for
large implementation files.

For targeted checks:

```sh
zig build test
zig build smoke
zig build stdio-fixtures
zig build backend-conformance-contract
zig build coverage
zig build dist release-asset-smoke
```

## Unit Tests

`zig build test` runs the library, executable, and release-helper test suites.
All three suites have non-zero floors in `tools/coverage_config.zig`, including
the executable module, so the release summary cannot pass with an untested
installed binary entrypoint. The suites cover CLI startup helpers and embedded
version wiring, CLI parsing and deinit ownership, workspace sandboxing, strict
symlink rejection, command execution, argument validation, tool risk metadata,
output-limit handling, docs/index metadata, source-write gating, diagnostics
retention, ZLS session behavior with a fake LSP server, heuristic analysis
fixtures, and the pure-Zig release helper.

## MCP Smoke Tests

`zig build smoke` starts zigar over HTTP and checks `initialize`,
`tools/list`, `zigar_schema`, `zigar_doctor`, and representative tool calls
against `tests/fixtures/http-smoke.expect.json`. The helper also enforces a
minimum scenario floor from `tools/coverage_config.zig` so this integration
gate cannot silently shrink. HTTP smoke also exercises the coverage, benchmark,
Samply, Tracy, and performance evidence tool surface in parser or preview modes
so every public performance workflow has a transport-level fixture without
requiring external profiler binaries.

`zig build stdio-fixtures` starts zigar over stdio and uses a temporary
workspace with Zig-backed fake optional backends. It checks newline-delimited
JSON-RPC, formatter preview/apply behavior, semantic impact/test-selection
contracts, validation plans/runs/history, transactional patch apply/revert,
generated/vendor policy routing, preview-first refactor helpers, build/test
event parsing, handoff and project-memory tools, capability routing, zwanzig
JSON/SARIF/rule/graph flows, ZLint diagnostics/SARIF/rules/fix preview
normalization, CI annotation contracts, structured profiling plans, zflame SVG
output metadata, and diff-folded flamegraph generation with intermediate
metadata. The fake backends are intentionally strict about supported argv shapes
so stale flags or option syntax fail before release. The fixture enforces the
configured minimum `tools/call` count before it reports success.

## Real Backend Conformance

Default CI does not require real optional backend binaries. Before claiming real
ZLS, ZLint, zwanzig, zflame, or diff-folded support in release notes, run:

```sh
bash .github/scripts/backend-conformance.sh
```

The same check is available as the manual `Backend Conformance` GitHub Actions
workflow. It starts zigar over stdio with real backend paths, probes them through
`zigar_doctor`, runs one representative tool for each backend family, and
verifies zflame/diff-folded SVG artifacts. Use `ZIGAR_ZLS_PATH`,
`ZIGAR_ZLINT_PATH`, `ZIGAR_ZWANZIG_PATH`, `ZIGAR_ZFLAME_PATH`, and
`ZIGAR_DIFF_FOLDED_PATH` when the binaries are not on `PATH`. The check writes
`report.json`, `summary.md`, `stdout.jsonl`, and `stderr.log` under
`.zigar-cache/backend-conformance/` by default, and the workflow uploads those
files as `zigar-backend-conformance`.

`zig build backend-conformance-contract` is the local fake-backend companion
check. It validates that the conformance script still writes the documented
report files and that the release binary can exercise representative ZLS,
ZLint, zwanzig, zflame, and diff-folded tool paths. `zig build release-check`
depends on this contract smoke; real backend certification still requires the
manual script or workflow above.

Samply and Tracy capture tools are not part of the repo-pinned real-backend
conformance script. Projects that depend on those profilers should pin and probe
the exact binaries in their own CI or release workflow, then package the profiler
evidence with `zig_perf_evidence_pack`.

## Coverage

`zig build coverage` installs the Zig test binaries, requires `kcov` on `PATH`,
runs the binaries directly under kcov, and writes `coverage/summary.json`. The
summary records pass/fail status for the library, executable, and tooling test
binaries, per-suite test floors, the configured minimum total test count, Zig
version, measured total/`src`/`tools` line coverage, configured line-coverage
floors, and per-floor pass/fail fields. The floors are defined in
`tools/coverage_config.zig`; use `zig-out/bin/zigar-tools coverage --min-tests
<count>` after `zig build install-test-bins` to override only the aggregate
test-count floor.

The coverage helper writes per-binary reports under `coverage/kcov/`, merges
them, parses Cobertura XML, and fails when kcov is unavailable, produces no
project-source report, or total, `src/`, or `tools` line coverage falls below the
configured floors. It also emits per-file line coverage, uncovered line numbers,
and tracked `src/**/*.zig` or `tools/**/*.zig` files missing from Cobertura; the
strict gate fails unless both counts are zero. The coverage job uploads the
complete `coverage/` directory as the `zigar-coverage` artifact. A
build/test/ReleaseSafe plus HTTP/stdio transport smoke matrix runs on macOS and
Windows to catch path, process, transport, and executable suffix issues.

## Fuzzing

`zig build test --fuzz=10K` runs the bounded parser/classifier fuzz target used
by CI. The target is intentionally small and deterministic enough for pull
requests: it fuzzes Cobertura/LCOV-style coverage parsing, stacktrace and crash
classifiers, path policy checks, and command argument splitting. Longer fuzz
runs remain manual or scheduled work.

Zig 0.16.0's fuzz runner currently fails to compile on this macOS Homebrew
toolchain with an upstream `compiler/test_runner.zig` stacktrace type mismatch;
CI runs the bounded fuzz smoke on Linux, while macOS still runs normal
`zig build test` and transport smoke coverage.

The MCP coverage workflow is separate from the `zig build coverage` release
gate. `zig_coverage_map`, `zig_coverage_merge`, `zig_coverage_diff`,
`zig_coverage_baseline`, and `zig_coverage_budget_check` consume supplied LCOV
or zigar JSON evidence; `zig_coverage_run` runs a caller-provided coverage
command only with `apply=true` and records artifact provenance.

## Release Assets

`zig build dist` builds ReleaseSafe archives for every release target and writes
SHA-256 checksums under `dist/assets`. `zig build release-asset-smoke` verifies
the checksums and required archive contents, then extracts and runs the native
archive when the current host matches one of the release targets.
