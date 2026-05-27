# Phase 3 - Architecture-Neutral Agent Ergonomics

Source plan: `../zigars-improvement-surface-implementation.md`

## Goal

Expose structural facts agents currently recover with grep and broad reads:
import cycles, test resolution, fixture inventory, safety catalogs, module
surfaces, symbol dossiers, risk audit, and insertion-site suggestions.

## Standing Constraints

- Public tools must be architecture-neutral. Do not add `zig_architecture_layer`
  or default enforcement of zigars' internal hexagonal layout.
- If a future architecture profile is introduced, it must be explicit,
  project-configured, and labeled as project policy in outputs.
- Parser-backed tools must label confidence and limitations.
- Keep outputs bounded and provide machine-readable `structuredContent`.
- New tools require manifest entries, generated docs, output schemas if Phase 1
  has landed, and smoke fixtures where representative.

## Current Code Anchors

- Existing static tools live in `src/adapters/mcp/tools/static_analysis.zig`.
- Existing project intelligence use cases live under
  `src/app/usecases/validation/` and static-analysis use cases.
- Existing manifest definitions for static tools live in
  `src/manifest/definitions/static_analysis.zig` and
  `src/manifest/definitions/agent.zig`.
- `docs/tool-index.generated.md` already lists many static-analysis tools:
  import graph, AST imports, public API, test discovery, semantic index, refs,
  callers, impact, and test selection.

## Work Items

1. Implement `zig_import_cycles`.
   - Post-process `zig_import_graph_json`.
   - Return SCCs, cycle paths, topological depths, severity, and confidence.
   - Keep severity architecture-neutral: SCC size, public API exposure,
     importer count, and optional configured policy hints.
2. Implement quick parser-backed catalogs.
   - `zig_test_name_resolve`: map requested filters to actual test names.
   - `zig_test_fixture_inventory`: list helpers, fixtures, harness utilities,
     and usage sites.
   - `zig_safety_site_catalog`: catalog `@panic`, `unreachable`, `catch
     unreachable`, unchecked casts, and related safety sites.
3. Implement reviewer/planner composites.
   - `zig_test_for_symbol`: reverse test-coverage map over semantic index,
     callers, refs, and AST tests.
   - `zig_module_surface`: directory-level public API aggregate with
     re-exports, consumers, and unused exports.
   - `zig_symbol_dossier`: symbol-scoped package of decl, signature, docs,
     callers, tests, diagnostics, lint findings, module role hints, history,
     and public API membership.
   - `zig_change_risk_audit`: risk-ranked diff using importer count, graph
     centrality, test coverage delta, and public API delta.
   - `zig_insertion_sites`: rank existing files/modules by topic similarity,
     module purpose, import-neighborhood shape, sibling patterns, and
     project-local naming conventions.
4. Add prompt and skill guidance after the tools exist.
   - Update agent workflow docs and skills to route users to tools.
   - Keep guidance concise; do not duplicate the full tool index.

## Key Files

- `src/domain/zig/analysis.zig`
- `src/domain/zig/static_analysis_contracts.zig`
- `src/app/usecases/static_analysis/`
- `src/app/usecases/validation/project_intelligence.zig`
- `src/adapters/mcp/tools/static_analysis.zig`
- `src/adapters/mcp/tools/project_intelligence.zig`
- `src/manifest/definitions/static_analysis.zig`
- `src/manifest/definitions/agent.zig`
- `src/manifest/tool_catalog.json`
- `docs/agent-workflows.md`
- `packages/zigars-skills-npm/skills/zigars-development/SKILL.md`

## Tool Contract Notes

- Every result should include `evidence_basis`, `confidence`, and
  `limitations`.
- Composite tools should include `omitted_sections` when budget or missing
  backend support prevents a section from being populated.
- `zig_insertion_sites` must be recommendation-oriented, not authoritative.
- `zig_change_risk_audit` should expose weights so callers can tune scoring.
- `zig_import_cycles` should be useful for arbitrary Zig projects and must not
  call cycles "hexagonal violations" unless a configured project policy says so.

## Tests And Fixtures

- Import graph fixtures with no cycles, simple cycles, nested SCCs, and external
  imports.
- Test-name fixtures with duplicate names, substring filters, parameterized
  naming patterns, and malformed test declarations.
- Fixture-inventory tests for helpers used across files and unused helpers.
- Safety-site fixtures with false-positive-prone comments and strings.
- Composite tests with fake semantic index/caller/test data and bounded output.
- Smoke fixtures for representative calls in static-analysis and agent groups.

## Acceptance Criteria

- `zig_import_cycles` returns empty cycles for current zigars source unless a
  fixture introduces one.
- Planner/reviewer tools label confidence and limitations.
- No new public tool implies arbitrary Zig projects should follow zigars'
  internal hexagonal layout.
- Generated tool index and manifest groups include all new tools.
- Skills/docs mention only tools that exist.

## Validation

```sh
zig build test
zig build docs-check json-check
zig build smoke stdio-fixtures
```

Run fuzz tests for parser-heavy additions:

```sh
zig build test --fuzz=10K
```

## Handoff For Next Phase

Record:

- Tool IDs implemented and any deferred composites.
- Confidence classes and known limitations.
- Fixture coverage added.
- Any new shared static-analysis contracts.
- Exact validation commands run.
