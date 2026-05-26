# Testing And Coverage

zigar uses layered tests so transport behavior, tool registration, and backend
argument wiring are checked separately from the unit tests.

## Local Gate

Run the same release-style gate used before publishing:

```sh
zig build release-check
```

`release-check` is intentionally broader than test execution. It also checks
formatting, generated docs/JSON drift, `zig build test`, ReleaseSafe
compilation, coverage with release-binary HTTP/stdio fixture coverage,
fake-backend conformance report contracts, backend scenario manifest drift,
artifact hygiene, architecture guard, hex architecture inventory, public MCP
contracts, structured tool/resource/CLI error contracts, line-budget headroom,
workflow permissions, and public claim/security/capability documentation checks.

For targeted checks:

```sh
zig build test
zig build smoke
zig build stdio-fixtures
zig build backend-contract-scenarios
zig build backend-conformance-contract
zig build coverage
zig build architecture-guard
zig build hex-architecture-inventory
zig build public-contracts
zig build dist release-asset-smoke
```

## Testing By Layer

Business behavior belongs in the fastest typed layer that can express it:

| Layer | Primary assertions |
|---|---|
| Domain | Parsers, classifiers, path policies, coverage/diagnostic/benchmark models, source-analysis contracts, and other pure value transformations. Domain tests should not import MCP or concrete effects. |
| App/use case | Workflow orchestration, risk/apply decisions, typed errors, port call sequencing, artifact provenance, backend-unavailable paths, and workspace rejections. Use `src/testing/fakes/**` and assert typed results, not MCP `ToolResult` or `structuredContent`. |
| MCP adapter/server | JSON argument decoding, defaults, schema compatibility, public field names, `ToolResult` shape, structured error mapping, resource/prompt routing, tasks, completions, pagination, and transport-specific contracts. |
| Infra | Concrete process, workspace, artifact, backend, ZLS, runtime-state, and persistence behavior. Temp directories and fake binaries are appropriate when the effect itself is under test. |
| Integration | Public behavior from the built `zigar` binary over HTTP or stdio. Integration fixtures assert MCP schema, transport, tool-call, artifact, resource, prompt, and report contracts; they do not assert internal module paths or handler implementation details. |

`src/testing/fakes` is the sanctioned fake-port layer. Its fakes own copied
expectations and call records, fail stale argv/write bytes or unexpected calls,
and expose `verify()` so missing expected port interactions fail at the
use-case layer.

When behavior moves out of an MCP handler, add domain or app/use-case coverage
for the moved policy. Smoke or stdio fixtures are still needed for public
transport shape, but they are not the primary place to prove business behavior.

## Unit Tests

`zig build test` runs four compiled test binaries: `zigar-lib-tests`,
`zigar-exe-tests`, `zigar-tools-tests`, and `zigar-fuzz-tests`. All four have
non-zero floors in `tools/coverage/coverage_config.zig`, including the executable module
and fuzz corpus smoke, so the release summary cannot pass with an untested
installed binary entrypoint or missing fuzz smoke coverage. The suites cover CLI
startup helpers and embedded version wiring, CLI parsing and deinit ownership,
workspace sandboxing, strict symlink rejection, command execution, argument
validation, tool risk metadata, output-limit handling, docs/index metadata,
source-write gating, diagnostics retention, ZLS session behavior with a fake LSP
server, heuristic analysis fixtures, public manifest invariants, and the
pure-Zig release helpers.

## MCP Smoke Tests

`zig build smoke` starts zigar over HTTP and checks `initialize`,
`tools/list`, `zigar_schema`, `zigar_doctor`, and representative tool calls
against `tests/fixtures/http-smoke.expect.json`. The helper also enforces a
minimum scenario floor from `tools/coverage/coverage_config.zig` so this integration
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

`zig build backend-contract-scenarios` checks scenario-manifest drift between
`tests/integration/backend-contract/scenarios.zig`,
`tests/integration/backend-contract/SCENARIOS.md`,
`.github/scripts/backend-conformance.sh`, and
`.github/scripts/backend-conformance-contract-smoke.sh`. The public contract
gate also checks backend conformance report invariants: report kind and schema
version, source metadata, claimed backends, compatibility matrix, tool evidence,
artifact entries, SVG artifact validation, and required scenario names.

Samply and Tracy capture tools are not part of the repo-pinned real-backend
conformance script. Projects that depend on those profilers should pin and probe
the exact binaries in their own CI or release workflow, then package the profiler
evidence with `zig_perf_evidence_pack`.

## Coverage

`zig build coverage` installs the Zig test binaries, requires `kcov` on `PATH`,
runs the binaries directly under kcov, and writes `coverage/summary.json`. The
summary records pass/fail status for the library, executable, tools, and fuzz
test binaries, per-binary floors, the configured minimum total test count, Zig
version, measured total/`src`/`tools` line coverage, configured line-coverage
floors, uncovered lines, missing tracked files, and per-floor pass/fail fields.
The floors are defined in `tools/coverage/coverage_config.zig`: total tests at least
500, library tests at least 480, executable tests at least 1, tools tests at
least 26, fuzz tests at least 2, and total/`src`/`tools` line coverage at
100.00%. Use `zig-out/bin/zigar-tools coverage --min-tests <count>` after
`zig build install-test-bins` to override only the aggregate test-count floor.

The coverage helper writes per-binary reports under `coverage/kcov/`, merges
them, parses Cobertura XML, and fails when kcov is unavailable, produces no
project-source report, or total, `src/`, or `tools` line coverage falls below the
configured floors. It also emits per-file line coverage, uncovered line numbers,
and tracked `src/**/*.zig` or `tools/**/*.zig` files missing from Cobertura; the
strict gate fails unless uncovered-line and missing-file counts are both zero.
`src/testing/coverage_imports.zig` is the explicit coverage-only import list for
metadata and contract modules that otherwise have no direct unit-test entrypoint;
adding a file there should be a conscious coverage decision, not a substitute
for domain or use-case tests when behavior exists.

Generated and runner outputs are excluded from kcov by
`tools/coverage/coverage_config.zig`, including build caches, release artifacts,
coverage output, and the custom fuzz test runner. The runner is harness code for
Zig's fuzz mode; the fuzz targets themselves live under `src/testing/fuzz_tests.zig`
and remain part of `zig build test` and coverage accounting.

During `zig build release-check`, the release coverage command also runs the
HTTP smoke and stdio fixtures under kcov against the ReleaseSafe binary. That
keeps public transport conformance in the coverage gate while unit binaries keep
typed domain/app/adapter/infra behavior covered. The coverage job uploads the
complete `coverage/` directory as the `zigar-coverage` artifact. A
build/test/ReleaseSafe plus HTTP/stdio transport smoke matrix runs on macOS and
Windows to catch path, process, transport, and executable suffix issues.

## Public Contracts

`zig build public-contracts` is the direct public MCP drift gate, and it is part
of `zig build release-check`. The authoritative checks live in
`tools/release/public_contracts.zig`, `tools/release/mcp_contracts.zig`, and
`tools/release/backend_contract_scenarios.zig`.

The gate checks:

- no-patch MCP behavior: `build.zig` and `build.zig.zon` must not reintroduce a
  local patched MCP server wrapper, while the first-party adapter keeps explicit
  post-serialization deinit hooks for tools, resources, and prompts;
- advertised capability wiring for completions, resource subscriptions, tasks,
  pagination, task results/cancel/list/get, and completion refs;
- every manifest entry's MCP input schema, required-field count, structured
  invalid-argument result, apply gate for source writes, and plan metadata for
  artifact/backend tools;
- resource and prompt fixture coverage, resource/prompt routing tokens, and the
  public resource URI and prompt-name surface;
- backend conformance report invariants, release-readiness report invariants,
  real-ZLS report invariants, and backend scenario manifest drift.

## Fuzzing

`zig build test --fuzz=10K` runs the bounded parser/classifier fuzz target used
by CI. The target is intentionally small and deterministic enough for pull
requests: it fuzzes Cobertura/LCOV-style coverage parsing, stacktrace and crash
classifiers, path policy checks, and command argument splitting. Longer fuzz
runs remain manual or scheduled work.

`zigar-fuzz-tests` uses the repository's custom runner at
`tools/fuzz_test_runner.zig`, wired from `build.zig`, so the normal test gate can
compile and account for the fuzz target. Run the bounded fuzz command above when
changing parser, classifier, path-policy, coverage-parser, or command-argument
logic.

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
