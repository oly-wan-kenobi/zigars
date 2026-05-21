# Feature Maturity

This document is the public-release maturity checkpoint. It records the clean
A rubric, the evidence that keeps that rating honest, and the product
boundaries that remain visible even when the release gate is green.

## Rubric

Minimum public-release rating: A.

A feature area reaches A only when it has:

- a clear public contract in docs and structured output;
- tests for successful use and major failure modes;
- honest limitations where behavior is advisory, optional, or backend-bound;
- stable machine-readable fields for agent or CI consumers;
- release-check, smoke-test, generated-doc, or CI coverage against drift;
- no known high-impact adoption blocker.

Clean A release status also requires a citable `Release Readiness` package from
the exact tagged source commit with `source_tree_clean: true`, matching backend
and ZLS subreport commits, release-check and release-asset-smoke results,
repo-pinned backend setup provenance when used, and a generated compatibility
matrix for every claimed optional backend.

Known limitations are allowed at A when they are explicit, non-surprising, and
paired with a reliable fallback or verification path. Hidden precision claims,
silent fallbacks, missing raw evidence, or untested public contracts keep a
feature below A.

## Reassessment

| Feature area | Contract maturity | Capability maturity | Evidence and boundary |
| --- | --- | --- | --- |
| Release gate and packaging | A | A | `release-check`, release asset smoke, dirty-tree refusal for release-readiness, schema-v2 evidence with source commit, subreport commit agreement, backend path/hash inputs, and release-note-ready summaries. |
| MCP/tool contract | A | A- | Discovery/schema/required-field coverage, structured invalid-input behavior, apply gates where source writes exist, backend/artifact planning coverage, structured unexpected handler errors, resource/prompt routing, cleanup hooks, and report schema tokens. |
| ZLS/LSP tools | A | A- | Structured unavailable-vs-unsupported capability reporting, fake-LSP regression tests, troubleshooting docs, and real-ZLS conformance scenarios for document open, symbols, hover, diagnostics, formatting, rename, and workspace symbols. Coverage is tied to the configured ZLS backend. |
| Docs lookup | A | B+ | Source/provenance/completeness metadata across docs tools, installed langref availability/fallback/parse-failure metadata, stdlib qualified-name/import-hint/doc-comment extraction, builtin drift checks against active toolchain source, and offline fallback tests. It is scoped lookup, not complete rendered Zig documentation. |
| Static analysis | A | B+ | Capability tiers (`advisory_orientation`, `parser_backed`, `zlint_backed`, `zwanzig_backed`), parser-backed semantic index/query/export/impact/test-selection tools, ZLint-confirmed reference/caller evidence when `--print-ast` is available, normalized lint intelligence, parser-backed fixtures for tricky Zig syntax, `parse_status`/`partial_result`, structured `evidence_basis` and `cross_check`, and guards preventing advisory tools from release-gating language. Advisory tools are orientation aids, not complete semantic evidence. |
| ZLint optional backend | A | B+ | Optional diagnostics/SARIF/rules/fix command contracts, normalized finding fields, rule-catalog capability fallback, apply-gated fix preview, fake-backend deterministic smoke coverage, explicit optional-unavailable behavior, and conformance-script scenario hooks when a real ZLint path is claimed. Public claims must name the actual backend evidence. |
| zwanzig optional backend | A | B+ | Repo-pinned provisioning, JSON/SARIF/rules/CFG graph real scenarios, fake-backend deterministic smoke coverage, explicit optional-unavailable behavior, and generated scenario evidence in the compatibility matrix. Public claims must name the actual backend evidence. |
| Profiling/zflame | A | B+ | Explicit `zig_profile_run` argv contract, external-capture docs, zflame recursive SVG validation, XML-prologue SVG acceptance, rendered and intermediate artifact hashes, diff-folded metadata checks, and release-check docs guards. Capture correctness remains the profiler's responsibility. |
| Agent workflows | A- | B+ | `workflow_contract`, `included_sections`, `omitted_sections`, `skipped_phases`, risk-aware validation plans/runs, build/test event parsing, validation history summaries, handoff packs, project memory, capability matching, focused tests, and HTTP/stdio coverage for agent routing/validation output. Workflow output helps route validation; it does not prove code correctness. |
| CI artifact tools | A- | B+ | Annotation parser confidence and basis, command-level JUnit metadata, direct matrix entry status fields, XML escaping tests, matrix failure tests, docs examples, and stdio annotation coverage. `zig_junit` remains command-level JUnit. |
| HTTP/MCP substrate | A | A- | First-party MCP adapter without upstream patches, explicit tool/resource/prompt result ownership and deinit tests, HTTP/stdio smoke fixtures, loopback-only HTTP docs, deterministic discovery-order coverage, trust-doc guards, and release checks preventing patched MCP reintroduction. |

No high-impact release blocker remains, but scoped feature areas must be
marketed as scoped capabilities rather than full semantic or backend proof.

## Remaining Limits

- Optional backends remain optional. ZLS, ZLint, zwanzig, zflame, and diff-folded tools
  return structured unavailable errors or degraded advisory output instead of
  requiring those binaries in default CI. Public release notes should claim real
  optional-backend coverage only from a clean-tree manual `Release Readiness`
  evidence package or a specific conformance artifact.
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
ZIGAR_USE_PINNED_BACKEND_SETUP=1 bash .github/scripts/release-readiness.sh
```

`release-check` validates this maturity document, generated docs/JSON, unit and
smoke tests, coverage floors, fake-backend conformance report contracts,
artifact hygiene, line-budget headroom, command contracts, backend-contract docs,
trust checklist coverage, and the no-patch MCP architecture guard.
