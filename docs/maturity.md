# Feature Maturity

This document is the public-release maturity checkpoint. It records the rubric
used to re-rate feature areas that were previously below A- and the evidence
that keeps those ratings honest.

## Rubric

Minimum public-release rating: A-.

A feature area reaches A- only when it has:

- a clear public contract in docs and structured output;
- tests for successful use and major failure modes;
- honest limitations where behavior is advisory, optional, or backend-bound;
- stable machine-readable fields for agent or CI consumers;
- release-check, smoke-test, generated-doc, or CI coverage against drift;
- no known high-impact adoption blocker.

Known limitations are allowed at A- when they are explicit, non-surprising, and
paired with a reliable fallback or verification path. Hidden precision claims,
silent fallbacks, missing raw evidence, or untested public contracts keep a
feature below A-.

## Reassessment

| Feature area | Previous rating | Public-release rating | Evidence |
| --- | --- | --- | --- |
| ZLS/LSP tools | B+ | A- | Structured unavailable-vs-unsupported capability reporting in ZLS tool results, degraded advisory fallbacks for symbols/diagnostics, fake-LSP regression tests, and troubleshooting docs for backend status and timeouts. |
| Docs lookup | B+ | A- | Source/provenance/completeness metadata across docs tools, generated tool-index checks, source/bundled fallback disclosure, and docs contract coverage in `docs/tools.md`. |
| Static analysis | B | A- | Capability tiers (`advisory_orientation`, `parser_backed`, `zwanzig_backed`), parser-backed AST tools, limitations and `verify_with` metadata, stdio coverage, and generated tool-index/release checks. |
| zwanzig optional backend | B | A- | Optional-backend contract docs, explicit backend probes, fake-backend stdio fixtures for JSON/SARIF/rules/graphs, and stable errors when zwanzig is unavailable. |
| Profiling/zflame | B | A- | Explicit `zig_profile_run` argv contract, external-capture docs, zflame/diff-folded backend metadata, SVG/intermediate artifact smoke tests, and release-check docs guards. |
| Agent workflows | B | A- | `workflow_contract`, `included_sections`, `omitted_sections`, `skipped_phases`, heuristic limitations, focused tests, and stdio coverage for agent routing/validation output. |
| CI artifact tools | B- | A- | Annotation parser confidence and basis, command-level JUnit metadata, direct matrix entry status fields, XML escaping tests, matrix failure tests, docs examples, and stdio annotation coverage. |
| HTTP/MCP substrate | B | A- | First-party MCP adapter without upstream patches, explicit tool/resource/prompt result ownership and deinit tests, HTTP/stdio smoke fixtures, loopback-only HTTP docs, task-frontmatter release blockers, trust-doc guards, and release checks preventing patched MCP reintroduction. |

No below-A- feature area remains without a blocking follow-up. Remaining limits
are documented as product boundaries rather than hidden defects.

## Remaining Limits

- Optional backends remain optional. ZLS, zwanzig, zflame, and diff-folded tools
  return structured unavailable errors or degraded advisory output instead of
  requiring those binaries in default CI.
- Static-analysis and agent-routing features disclose heuristic scope. Use
  parser-backed tools, compiler-backed commands, ZLS, or project CI before
  making release decisions from advisory output.
- `zig_junit` is command-level JUnit. It does not infer per-test cases from Zig
  output because Zig does not expose a stable event stream for every invocation.
- HTTP transport is local-only. zigar does not provide authenticated remote MCP
  serving.
- External repository policy is not inferred from local files. GitHub branch
  protection, release permissions, and real optional-backend CI runs must be
  checked outside the repository when release notes claim them.

## Release Gate

Before publishing, the releaser must run:

```sh
zig build release-check
zig build dist release-asset-smoke
```

`release-check` validates this maturity document, generated docs/JSON, unit and
smoke tests, coverage floors, fake-backend conformance report contracts,
artifact hygiene, line-budget headroom, command contracts, backend-contract docs,
public-release blocker task frontmatter, trust checklist coverage, and the
no-patch MCP architecture guard.
