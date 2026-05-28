# Exceptional Bar Implementation Tasks

Date: 2026-05-28
Status: implementation roadmap
Sources:
[08-exceptional-bar-action-plan.md](08-exceptional-bar-action-plan.md),
[09-exceptional-bar-deep-research-findings.md](09-exceptional-bar-deep-research-findings.md)

## 1. Purpose

This roadmap turns the exceptional-bar proposal and follow-up research into
ordered implementation phases. Each phase has a standalone handoff file under
[10-exceptional-bar-phases/](10-exceptional-bar-phases/) so a fresh session can
pick up exactly one phase without needing to re-plan the whole program.

The phases are intentionally smaller than the original 90-day sequence. The
goal is to keep trust, observability, installer, compiler-probe, and CLI work
from landing in one large, hard-to-review change.

## 2. Phase Order

| Phase | Handoff file | Main outcome | Depends on |
|---:|---|---|---|
| 1 | [phase-01-public-wedge-onboarding.md](10-exceptional-bar-phases/phase-01-public-wedge-onboarding.md) | Public wedge and first-five-minutes docs | none |
| 2 | [phase-02-correlation-error-forensics.md](10-exceptional-bar-phases/phase-02-correlation-error-forensics.md) | Request correlation through results, stderr, structured errors, and metrics | none |
| 3 | [phase-03-audit-cancellation-performance.md](10-exceptional-bar-phases/phase-03-audit-cancellation-performance.md) | Opt-in audit log, cancellation plumbing, startup/latency metrics | phase 2 recommended |
| 4 | [phase-04-trust-manifest-zig-preflight.md](10-exceptional-bar-phases/phase-04-trust-manifest-zig-preflight.md) | Runtime trust manifest and Zig version preflight | phase 1 recommended |
| 5 | [phase-05-npm-attestation-policy.md](10-exceptional-bar-phases/phase-05-npm-attestation-policy.md) | Policy-controlled npm shim attestation verification | public repo name decision |
| 6 | [phase-06-abi-layout-evidence.md](10-exceptional-bar-phases/phase-06-abi-layout-evidence.md) | Compiler-backed ABI/layout evidence upgrade | none |
| 7 | [phase-07-thin-cli-spike.md](10-exceptional-bar-phases/phase-07-thin-cli-spike.md) | First public thin CLI vertical slice | phase 4 recommended |

## 3. Global Implementation Rules

- Keep zigars a deterministic Zig development MCP server. Do not add AI
  generation behavior inside the server.
- Preserve workspace path policy. User-provided paths must resolve under the
  configured workspace before reads or writes.
- Source-mutating MCP tools must require `apply=true`.
- Keep stdout reserved for JSON-RPC in MCP server mode. CLI mode may use stdout
  for its documented machine output, but server startup and diagnostics still go
  to stderr.
- Prefer existing use case modules, manifest metadata, command runners, and
  test patterns over new frameworks.
- If a phase changes tool ids, schemas, grouping, risk metadata, planning
  metadata, or argument-heavy tools, sync:
  `src/manifest/tool_catalog.json`, `src/manifest/definitions.zig`,
  `src/manifest/types.zig`, `src/manifest/groups.zig`, and
  `docs/tool-index.generated.md`.
- Do not hand-edit generated tool index output. Regenerate it with
  `zig build tool-index`.
- Keep unrelated cleanup out of phase branches.

## 4. Standard Fresh-Session Handoff

Every fresh implementation session should start with:

1. Read root `AGENTS.md`.
2. Read the selected phase handoff file.
3. Read only the relevant sections of `08` and `09` linked by the phase file.
4. Run `git status --short` and preserve unrelated user changes.
5. Implement the ordered tasks in the phase file.
6. Run that phase's validation commands.
7. Summarize changed files, validation, and any skipped checks.

## 5. Default Validation Ladder

Use focused checks while working, then run the phase-specific final checks.
Most code phases should end with:

```sh
zig fmt build.zig build.zig.zon src tools
zig build test
zig build docs-check json-check
```

Docs-only phases should end with:

```sh
zig build docs-check json-check
```

Npm shim phases should also run:

```sh
cd packages/@zigars/mcp
npm run build
npm run test:node
bun run test:bun
```

If a phase changes release packaging, generated artifacts, or release evidence,
also run:

```sh
zig build artifact-hygiene
```

## 6. Deferred Items

Do not implement these as part of this roadmap unless a new phase is explicitly
approved:

- Third-party plugin APIs or out-of-tree tool registration.
- A zigars LSP server overlapping ZLS.
- Stable public Zig library extraction.
- Full broad parallel tool dispatch.
- Multi-workspace team config.
- Full project comptime value inspection without explicit project-code
  execution risk.
