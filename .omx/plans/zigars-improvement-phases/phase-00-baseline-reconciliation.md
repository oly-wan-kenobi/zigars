# Phase 0 - Baseline Reconciliation

Source plan: `../zigars-improvement-surface-implementation.md`

## Goal

Make the roadmap and current repository state agree before new public surface is
implemented. This phase is intentionally documentation and verification heavy:
it prevents stale proposal assumptions from becoming implementation work.

## Standing Constraints

- Use Zig 0.16.0.
- Keep zigars deterministic and pure Zig; do not add AI code-generation behavior
  or Python helpers.
- Preserve the workspace sandbox and `apply=true` rule for source-mutating MCP
  tools.
- Keep public tool policy architecture-neutral. Zigars' hexagonal architecture
  guard stays internal unless a future explicit opt-in profile exists.
- Do not revert unrelated local work.

## Current Facts To Reconcile

- MCP protocol substrate is not absent. The runtime already enables completions,
  resource subscriptions, and tasks.
- The MCP server already routes `completion/complete`, paginated `tools/list`,
  resource templates, and resource subscribe/unsubscribe.
- Tool results already use `structuredContent`; the gap is declared
  `outputSchema` and consistent schema projection.
- `packages/zigars-skills-npm/` exists and has moved beyond the placeholder state
  described by older analysis.
- `zig_architecture_layer` has been removed from the public improvement surface.

## Primary Inputs

- `docs/improvement-proposals/00-synthesis.md`
- `docs/improvement-proposals/01-internal-gaps.md`
- `docs/improvement-proposals/02-mcp-peer-scan.md`
- `docs/improvement-proposals/03-zig-dev-pain.md`
- `docs/improvement-proposals/04-compound-workflows.md`
- `docs/improvement-proposals/05-agent-ergonomics.md`
- `CLAUDE_ANALYSIS.md`
- `docs/architecture.md`
- `docs/release.md`
- `docs/distribution.md`
- `docs/dogfooding.md`
- `packages/zigars-skills-npm/`

## Work Items

1. Add an implementation appendix or ADR that records the roadmap decisions:
   dependency lifecycle order, graceful protocol fallback, `_guidance` rename,
   shared session envelope, async jobs plus cursored resources, comptime tool
   split, and architecture-neutral public tooling.
2. Update stale proposal text where it would mislead implementers.
   - Protocol substrate exists; phrase work as deepening existing routes.
   - Skills package exists; verify its current release readiness.
   - Public architecture layer tool is removed.
3. Re-run release-hygiene checks from `CLAUDE_ANALYSIS.md` and record which
   findings remain valid.
4. Confirm generated/artifact hygiene before feature work starts.
5. Add a small phase status note if any roadmap assumptions must be changed
   before Phase 1 begins.

## Implementation Notes

- Keep this phase mostly in docs. Do not refactor production code unless a docs
  check exposes generated-contract drift that must be fixed.
- Prefer an ADR under the repo's existing docs structure if one exists. If not,
  use a clearly named roadmap appendix under `docs/improvement-proposals/`.
- Keep claims evidence-backed with file references and command output summaries.
- Do not edit generated files by hand except through the existing generation
  command.

## Acceptance Criteria

- Roadmap docs no longer claim missing MCP substrate that already exists.
- Roadmap docs no longer advertise `zig_architecture_layer` as a public tool.
- Release-hygiene findings are classified as still-valid, stale, or deferred.
- Phase 1 implementers can identify exact protocol files and current behavior.
- No generated docs or JSON validation drift remains.

## Validation

```sh
zig build docs-check json-check
zig build artifact-hygiene
```

If package docs are touched:

```sh
cd packages/zigars-skills-npm
npm test
npm run pack:dry
```

## Handoff For Next Phase

Record:

- ADR or appendix path.
- Stale findings corrected.
- Still-open release-hygiene findings.
- Exact validation commands run.
- Any files intentionally left for Phase 1.
