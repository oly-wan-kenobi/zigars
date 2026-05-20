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
fixtures, kcov line coverage floors, artifact hygiene, structured tool-error
contracts, and line-budget headroom for large implementation files.

For targeted checks:

```sh
zig build test
zig build smoke
zig build stdio-fixtures
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
gate cannot silently shrink.

`zig build stdio-fixtures` starts zigar over stdio and uses a temporary
workspace with Zig-backed fake optional backends. It checks newline-delimited
JSON-RPC, formatter preview/apply behavior, zwanzig JSON/SARIF/rule/graph
flows, structured profiling plans, zflame SVG output metadata, and diff-folded
flamegraph generation with intermediate metadata. The fake backends are
intentionally strict about supported argv shapes so stale flags or option syntax
fail before release. The fixture enforces the configured minimum `tools/call`
count before it reports success.

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
configured floors. The coverage job uploads the complete `coverage/` directory
as the `zigar-coverage` artifact. A build/test/ReleaseSafe plus HTTP/stdio
transport smoke matrix runs on macOS and Windows to catch path, process,
transport, and executable suffix issues.

## Release Assets

`zig build dist` builds ReleaseSafe archives for every release target and writes
SHA-256 checksums under `dist/assets`. `zig build release-asset-smoke` verifies
the checksums and required archive contents, then extracts and runs the native
archive when the current host matches one of the release targets.
