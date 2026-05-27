# Changelog

## 0.2.0 - 2026-05-19

Adoption hardening release focused on safer defaults, clearer tool contracts,
and more reliable docs discovery.

- Enforced the realpath workspace boundary by default for inputs, outputs,
  cache paths, and symlink targets that escape the workspace.
- Hardened ZLS document lifecycle handling, edit-base synchronization, and tool
  risk metadata for state-mutating LSP requests.
- Refactored `zig_lang_ref_search` to search real language-reference sources
  when present and fall back to a bundled language-reference section index
  instead of scanning Zig docs implementation files.
- Added agent-client setup guidance and discovery profiles for Codex, Claude,
  Gemini CLI, and Hermes-style wrappers.
- Added a backend setup catalog for Zig, ZLS, zwanzig, zflame, and diff-folded
  installation and verification guidance.
- Scoped schema hints by owning tool, strengthened structured error payloads for
  resources and helper CLI failures, and added release-check guards for those
  contracts.
- Split more line-budget hotspots into focused modules to keep tool handlers,
  release helpers, LSP tests, and static-analysis scanners maintainable.

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
- `zigars_schema` and `zigars_doctor` discovery/health surfaces.
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
