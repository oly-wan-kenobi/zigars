# Testing And Coverage

zigar uses layered tests so transport behavior, tool registration, and backend
argument wiring are checked separately from the unit tests.

## Local Gate

Run the same release-style gate used before publishing:

```sh
zig build release-check
```

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
The suites cover CLI parsing and deinit ownership, workspace sandboxing, strict
symlink rejection, command execution, argument validation, tool risk metadata,
output-limit handling, docs/index metadata, source-write gating, diagnostics
parsing, ZLS session behavior with a fake LSP server, heuristic analysis
fixtures, and the pure-Zig release helper.

## MCP Smoke Tests

`zig build smoke` starts zigar over HTTP and checks `initialize`,
`tools/list`, `zigar_schema`, `zigar_doctor`, and representative tool calls
against `tests/fixtures/http-smoke.expect.json`. The helper also enforces a
minimum scenario floor from `tools/coverage_config.zig` so this integration
gate cannot silently shrink.

`zig build stdio-fixtures` starts zigar over stdio and uses a temporary
workspace with Zig-backed fake optional backends. It checks newline-delimited
JSON-RPC, formatter preview/apply behavior, zwanzig SARIF passthrough, zflame
SVG output, and diff-folded flamegraph generation. The fixture enforces the
configured minimum `tools/call` count before it reports success.

## Coverage

`zig build coverage` installs the Zig test binaries, runs them directly, and
writes `coverage/summary.json`. The summary records pass/fail status for the
library, executable, and tooling test binaries, per-suite test floors, the
configured minimum total test count, Zig version, and coverage status. The
floors are defined in `tools/coverage_config.zig`; use
`zig-out/bin/zigar-tools coverage --min-tests <count>` after
`zig build install-test-bins` to override only the aggregate test-count floor.

If `kcov` is on `PATH`, the coverage helper writes per-binary reports under
`coverage/kcov/`, merges them, parses Cobertura XML, and records total, `src/`,
and `tools/` line-coverage percentages in `coverage/summary.json`. Without
kcov, the portable `zig build coverage` step still produces the test summary and
records why line coverage was not measured.

Line coverage is intentionally advisory for now. Docker validation against
Ubuntu 22.04 kcov 38 and Zig 0.16.0 produced project source entries with zero
executed project hits, so CI does not treat that signal as a release gate. The
hard CI signal is the unit-test pass/fail result, per-suite test floors, HTTP
and stdio smoke scenario floors, and release hygiene. The coverage job uploads
the complete `coverage/` directory as the `zigar-coverage` artifact. A
build/test/ReleaseSafe plus HTTP/stdio transport smoke matrix runs on macOS and
Windows to catch path, process, transport, and executable suffix issues.

## Release Assets

`zig build dist` builds ReleaseSafe archives for every release target and writes
SHA-256 checksums under `dist/assets`. `zig build release-asset-smoke` verifies
the checksums and required archive contents, then extracts and runs the native
archive when the current host matches one of the release targets.
