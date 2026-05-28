# Phase 1 - Public Wedge And Onboarding

Status: ready for implementation
Primary source sections:
[08 section 3.1-3.2](../08-exceptional-bar-action-plan.md#31-public-wedge),
[09 section 4](../09-exceptional-bar-deep-research-findings.md#4-product-and-positioning-research)

## Objective

Make zigars' existing trust and evidence posture clear in the first five
minutes. This phase is documentation-only. It should not add new MCP tools or
change runtime behavior.

## Ordered Tasks

### P1-T1 Add `docs/evidence-tiers.md`

Create a concise page explaining the evidence labels already used by zigars:
command-backed, LSP/ZLS-backed, parser-backed, source-scan-backed,
heuristic/advisory, external-backend-backed, curated fallback, and real
conformance artifact.

Acceptance criteria:

- The page states what each label proves and what it does not prove.
- The page links to [docs/tools.md](../../tools.md) and
  [docs/trust.md](../../trust.md).
- The page avoids "fully deterministic" and "secure sandbox" claims.

### P1-T2 Add `docs/determinism.md`

Create a precise determinism contract.

Acceptance criteria:

- It states that no LLM calls run inside zigars server tools.
- It explains that outputs depend on inputs, workspace state, configured Zig
  toolchain, optional backend versions, and documented external command
  behavior.
- It distinguishes stable fields from runtime-specific fields such as timing,
  backend output, timestamps, and artifact paths.
- It states that source writes are preview-first and require `apply=true`.

### P1-T3 Add `docs/why-zigars.md`

Create the public wedge page: why zigars is more than an agent running shell
commands.

Acceptance criteria:

- It uses the defensible claim: shell can run `zig build`, while zigars returns
  structured diagnostics, command metadata, parser-backed facts, ZLS-backed code
  intelligence, preview diffs, confidence labels, and next verification steps.
- It does not claim semantic completeness for refactors.
- It explains where shell remains the source of truth.

### P1-T4 Add `docs/getting-started.md`

Create one obvious first-five-minutes walkthrough.

Acceptance criteria:

- It starts with the preferred Bun launcher and one Node fallback.
- It walks through `zigars_workspace_info`,
  `zigars_doctor {"probe_backends":false}`, one read-only insight, one
  preview-only edit, and `zigars_trust_report`.
- Each call says what it proves.
- It sends users to the generated tool index only after the guided path.

### P1-T5 Add `examples/README.md`

Document the existing examples directory.

Acceptance criteria:

- It describes each existing client config example and `tool-calls.jsonl`.
- It does not mention non-existent examples such as `http-smoke.sh`.
- It includes the same first verification calls as `docs/getting-started.md`.

### P1-T6 Rewrite The README Opening

Update the top of [README.md](../../../README.md) so the first screen presents
the product wedge, preferred install path, first verification calls, evidence
tiers, and trust boundary before the long capability catalog.

Acceptance criteria:

- The first section says zigars is a deterministic Zig MCP workbench, not an AI
  code generator.
- The preferred Bun install remains first; Node/npm remains a supported
  fallback.
- The first-five-minutes sequence links to `docs/getting-started.md`.
- Evidence tiers link to `docs/evidence-tiers.md`.
- Trust posture links to `docs/trust.md` and `docs/determinism.md`.
- Alternate launchers and long tool lists move below the first verification
  path.

## Out Of Scope

- Do not change MCP result payloads.
- Do not change generated `docs/tool-index.generated.md`.
- Do not add trust manifest runtime fields; that belongs to Phase 4.

## Validation

```sh
zig build docs-check json-check
```

## Handoff Notes

This phase is safe to implement first. It should make later implementation
phases easier because it fixes the public vocabulary for evidence, determinism,
and trust boundaries.
