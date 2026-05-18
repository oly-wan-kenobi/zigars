# Changelog

## 0.1.0 - 2026-05-17

Initial `0.1.0` package baseline.

- Zig 0.16.0 executable MCP server using stdio transport.
- Workspace-sandboxed command tools for Zig version/env/targets/build/test/check
  and translate-c.
- Formatting tools with preview-by-default behavior and `apply=true` write
  gating.
- Long-lived ZLS session for diagnostics, hover, definition, references,
  completion, signature help, symbols, code actions, rename, and in-memory
  document sync.
- Local Zig builtin, stdlib, and language-reference lookup helpers.
- Heuristic static-analysis tools for imports, declarations, allocations, error
  sets, public API, build graph, file ownership, import resolution, and test
  discovery.
- Optional zwanzig integration for linting, SARIF, rule listing, and analysis
  graph output.
- Optional zflame integration for profiler-output conversion and flamegraph
  diffs.
- CI/test artifact helpers for annotations, JUnit XML, and Zig version matrix
  checks.
- First-class release packaging through `zig build dist`, release-asset smoke
  checks, SHA-256 checksums, and GitHub provenance attestations.
- Compact capability/tool-index surface for MCP tool discovery.
- `mcp.zig` 0.0.4 URL dependency with HTTP transport enabled.
- `zigar_schema` and `zigar_doctor` discovery/health surfaces.
- Package version sourced from `build.zig.zon` for CLI, MCP server metadata,
  release checks, generated catalogs, and CI smoke tests.
- Optional `--strict-workspace` realpath checks and dedicated
  `--zls-timeout-ms`.
- Typed tool metadata with centralized argument validation and structured
  `argument_error` results.
- Generated tool-index documentation, reusable HTTP smoke fixtures, release
  check script, example MCP client configs, and a security-readiness checklist.
- Stdio fixture integration checks for formatting, zwanzig, zflame, and
  diff-folded flows plus coverage summaries with optional kcov artifacts.
- Toolchain resolver, compile-error indexing, changed-file check planning,
  dependency/build-option inspection, target matrix planning, test-failure
  triage, cached workspace symbol indexing, package/cache doctor, and generic
  patch preview support.
- Hardened strict workspace output canonicalization, LSP request timeout cleanup,
  unsaved document replay after ZLS restart, flamegraph diff intermediates, and
  heuristic analysis completeness metadata.
