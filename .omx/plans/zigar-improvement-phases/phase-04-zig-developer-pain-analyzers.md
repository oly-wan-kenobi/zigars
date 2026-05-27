# Phase 4 - Zig Developer Pain Analyzers

Source plan: `../zigar-improvement-surface-implementation.md`

## Goal

Add Zig-specific analyzers where zigar can outperform generic MCP servers:
0.16 IO migration scans, leak triage, comptime diagnosis, memory/safety
catalogs, ABI layout diff, and selected navigation wrappers.

## Standing Constraints

- Parser-backed tools must label unsupported syntax, confidence, and evidence
  basis.
- Command-backed compiler probes must be workspace-safe, bounded, and explicit
  about argv, timeout, stdout/stderr handling, and backend status.
- Do not claim full semantic comptime evaluation. Label parser-only,
  compiler-probe, and optional backend results distinctly.
- Optional ZLS/backend failures must return structured degraded results.
- New source-mutating behavior, if any, must be preview-first and require
  `apply=true`.

## Current Code Anchors

- Parser/domain code belongs under `src/domain/zig/`.
- Diagnostics code belongs under `src/domain/diagnostics/` and
  `src/app/usecases/diagnostics/`.
- Static-analysis adapters live in `src/adapters/mcp/tools/static_analysis.zig`.
- Diagnostics adapters live in `src/adapters/mcp/tools/diagnostics.zig`.
- ZLS adapters live in `src/adapters/mcp/tools/zls.zig` and infra ZLS types live
  under `src/infra/zls/` when present.
- Existing backend catalog and optional backend patterns live under
  `src/domain/zig/backend_catalog.zig` and `src/infra/backends/`.

## Work Items

1. Implement `zig_io_migration_scan`.
   - Focus on Zig 0.15 to 0.16 migration pain while it is still timely.
   - Use a curated mapping table for known IO API changes.
   - Return exact, likely, and manual-review findings.
   - Include suggested verification commands, not source edits.
2. Implement `zig_leak_triage`.
   - Parse GPA leak stderr.
   - Group allocation sites and repeated traces.
   - Symbolize when binary/debug info or symbolizer backend is available.
   - Return raw evidence references and grouped summaries.
3. Implement `zig_comptime_diagnose`.
   - Parser-only first.
   - Use compiler diagnostic locations when supplied by the caller.
   - Return runtime-tainted operands, likely causes, likely fixes, and
     limitations.
4. Implement memory and safety catalogs.
   - `zig_memory_layout`: parser-backed layout candidate catalog.
   - `zig_unsafe_operations_audit`: unsafe/boundary operation catalog.
   - Extend `zig_safety_site_catalog` from Phase 3 if needed.
5. Implement `zig_abi_layout_diff`.
   - Build after `zig_memory_layout` has stable fixtures.
   - Generate bounded `@sizeOf`, `@alignOf`, and `@offsetOf` probes.
   - Run compiler probes through command runner ports only.
   - Store probe artifacts under `.zigar-cache/` where needed.
6. Implement lower-risk navigation wrappers.
   - `zig_typedef_jump`
   - `zig_call_hierarchy`
   - `zig_type_hierarchy`
   - `zig_inlay_hints`
   - Use ZLS or semantic-index backends when available, with structured
     unavailable states.
7. Implement `zig_target_chooser` and `zig_error_propagation` after the static
   analysis base is stable.
8. Keep `zig_comptime_inspect` and `zig_comptime_view` as later compiler-probe
   work.
   - Label backend as `compiler_probe`.
   - Cache probe artifacts under `.zigar-cache/`.
   - Do not claim full semantic comptime evaluation.

## Key Files

- `src/domain/zig/analysis.zig`
- `src/domain/diagnostics/`
- `src/app/usecases/static_analysis/`
- `src/app/usecases/diagnostics/`
- `src/app/usecases/zls/code_intel.zig`
- `src/infra/zls/types.zig`
- `src/infra/process/command_runner.zig`
- `src/adapters/mcp/tools/static_analysis.zig`
- `src/adapters/mcp/tools/diagnostics.zig`
- `src/adapters/mcp/tools/zls.zig`
- `src/manifest/definitions/static_analysis.zig`
- `src/manifest/definitions/diagnostics.zig`
- `src/manifest/definitions/zls.zig`

## Tests And Fixtures

- IO migration fixtures for exact migrated calls, likely matches, comments, and
  strings.
- GPA leak stderr fixtures with one leak, repeated leak, malformed trace, and
  symbolizer unavailable.
- Comptime diagnostic fixtures with runtime-tainted operand, missing location,
  nested comptime, and unsupported syntax.
- Memory layout fixtures covering structs, packed structs, extern structs,
  unions, enums, and opaque/unsupported declarations.
- ABI probe fake command tests for exact argv, timeout, stderr, and cache paths.
- ZLS fake-backend tests for navigation wrappers and unavailable capabilities.

## Acceptance Criteria

- Parser-backed tools include fixture coverage for shadowed names, unsupported
  syntax, comments/strings false positives, and bounded output.
- Command-backed probes use workspace-safe temp/cache paths and exact argv.
- Optional ZLS/backend unavailability returns structured degraded results.
- Comptime tools clearly label parser-only versus compiler-probe evidence.
- Generated docs and manifest metadata agree.

## Validation

```sh
zig build test
zig build docs-check json-check
```

For parser/probe-heavy work:

```sh
zig build test --fuzz=10K
zig build smoke stdio-fixtures
```

## Handoff For Next Phase

Record:

- Which analyzers are parser-only, command-backed, or backend-backed.
- Unsupported Zig syntax cases.
- Probe cache layout, if introduced.
- Backend unavailable result shapes.
- Exact validation commands run.
