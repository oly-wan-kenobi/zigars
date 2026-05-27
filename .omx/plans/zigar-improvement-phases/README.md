# Zigar Improvement Phase Handoffs

Date: 2026-05-27
Source plan: `../zigar-improvement-surface-implementation.md`

This directory splits the improvement roadmap into implementation handoffs. Each
phase file is intended to stand alone for a fresh session: it includes context,
constraints, key files, concrete work items, acceptance criteria, validation, and
handoff expectations.

## Phase Order

1. `phase-00-baseline-reconciliation.md`
2. `phase-01-mcp-contract-foundations.md`
3. `phase-02-dependency-lifecycle.md`
4. `phase-03-architecture-neutral-agent-ergonomics.md`
5. `phase-04-zig-developer-pain-analyzers.md`
6. `phase-05-compound-workflows-and-session-system.md`
7. `phase-06-protocol-feature-pilots.md`
8. `phase-07-docs-skills-release-adoption.md`

## Standing Rules For Every Phase

- Use Zig 0.16.0.
- Keep the server deterministic. Do not add AI code-generation behavior inside
  zigar.
- Keep the project pure Zig. Do not add Python helpers under source, tools,
  tests, scripts, examples, docs, or CI paths.
- Keep stdout reserved for MCP JSON-RPC; diagnostics and logs go to stderr.
- Every user-provided path must resolve under the configured workspace before it
  is read or written.
- Source-mutating MCP tools must be preview-first and require `apply=true`.
- New MCP tool contracts are manifest-first: update definitions, catalog,
  groups, generated docs, schemas, tests, and smoke fixtures together.
- Public tools must not imply arbitrary Zig projects should follow zigar's
  internal hexagonal layout. Architecture policy is internal unless a future
  explicit opt-in project profile exists.
- Preserve unrelated local changes in the worktree.

## Common Validation Ladder

Use focused checks while developing, then scale with risk:

```sh
zig fmt build.zig build.zig.zon src tools
zig build test
zig build docs-check json-check
zig build smoke stdio-fixtures
```

For broader or release-facing changes:

```sh
zig build test --fuzz=10K
zig build smoke stdio-fixtures coverage
zig build release-check
```

For npm shim changes:

```sh
cd packages/zigar-mcp-npm
npm run build
npm run test:node
bun run test:bun
```

For skills package changes:

```sh
cd packages/zigar-skills-npm
npm test
npm run pack:dry
```

## Manifest And Docs Sync

When adding or changing public tool IDs, schemas, groups, risk metadata,
planning policy, or argument-heavy tools, keep these synchronized:

- `src/manifest/tool_catalog.json`
- `src/manifest/definitions.zig`
- `src/manifest/definitions/*.zig`
- `src/manifest/types.zig`
- `src/manifest/groups.zig`
- `docs/tool-index.generated.md`
- HTTP and stdio smoke fixtures where the change affects MCP registration,
  transport, schemas, or representative outputs.

Regenerate and check generated docs with:

```sh
zig build tool-index
zig build docs-check
```

## Fresh Session Start Checklist

1. Read the relevant phase file in this directory.
2. Read `AGENTS.md` and any smaller applicable `.agents/` role or workflow,
   especially `.agents/workflows/tool-change.md` for MCP tool changes.
3. Inspect current code before implementing; do not assume the plan's file list
   is exhaustive.
4. Check `git status --short` and do not revert unrelated changes.
5. Implement the phase in PR-sized slices.
6. Record exact validation commands and any skipped checks in the handoff.
