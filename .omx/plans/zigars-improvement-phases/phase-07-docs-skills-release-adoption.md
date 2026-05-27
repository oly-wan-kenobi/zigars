# Phase 7 - Docs, Skills, Release, And Adoption

Source plan: `../zigars-improvement-surface-implementation.md`

## Goal

Make the new surface discoverable, supportable, and release-ready. This phase is
where public claims are reconciled with shipped tools and validation evidence.

## Standing Constraints

- Docs must not claim tools, schemas, package behavior, or client support that
  does not exist.
- Generated docs should be regenerated, not edited by hand.
- Skills guide agents to tools; they should not duplicate the entire tool index.
- Release evidence must include exact commands run and skipped checks.
- Do not commit build outputs, caches, coverage output, `zig-out/`, or generated
  release artifacts unless the repository explicitly tracks them.

## Current Code Anchors

- Generated tool index: `docs/tool-index.generated.md`
- Tool catalog: `src/manifest/tool_catalog.json`
- Group metadata: `src/manifest/groups.zig`
- Release and contract checks: `tools/release/mcp_contracts.zig`
- NPM shim: `packages/zigars-mcp-npm/`
- Skills package: `packages/zigars-skills-npm/`

## Work Items

1. Update generated tool index after every tool batch.
   - Run `zig build tool-index`.
   - Verify generated docs match manifest and catalog metadata.
2. Update public docs as relevant.
   - `docs/tools.md`
   - `docs/agent-workflows.md`
   - `docs/agent-clients.md`
   - `docs/trust.md`
   - `docs/backends.md`
   - `docs/release.md`
3. Keep package READMEs aligned.
   - `packages/zigars-mcp-npm/README.md`
   - `packages/zigars-skills-npm/README.md`
4. Add or update skill guidance only after corresponding tools exist.
   - Route to actual tool names.
   - Avoid references to deferred tools.
   - Keep `_guidance` naming consistent after Phase 6.
5. Add smoke fixtures with representative `tools/call` for each new group.
   - HTTP fixtures for transport-sensitive changes.
   - Stdio fixtures for tool contract and result-shape changes.
6. Run release-style checks at the end of each major phase and once more before
   public release claims.
7. Maintain a release evidence note.
   - Exact commands.
   - Environment assumptions.
   - Skipped checks and reasons.
   - Known limitations or deferred tools.

## Key Files

- `docs/tool-index.generated.md`
- `docs/tools.md`
- `docs/agent-workflows.md`
- `docs/agent-clients.md`
- `docs/trust.md`
- `docs/backends.md`
- `docs/release.md`
- `packages/zigars-mcp-npm/README.md`
- `packages/zigars-skills-npm/`
- `tools/release/mcp_contracts.zig`
- `tools/integration/http/*`
- `tools/integration/stdio/*`

## Deferred Or Promotion-Gated Surface

Keep these as playbooks or later promotions unless clear adopter demand appears:

- `zig_linker_error_decode`: promote only if catalog maintenance owner exists.
- `zig_cimport_macro_wrap`: promote only for a concrete adopter with macro
  fixture coverage.
- `zig_comptime_quota_probe`: keep as playbook until repeated demand justifies
  wall-clock cost.
- `zig_target_matrix_run`: promote after two adopter projects regularly need
  matrices.
- `zig_allocator_audit`: keep as playbook unless allocation analysis moves
  beyond advisory orientation.
- `zig_pkg_docs`: promote after registry metadata and autodoc access are
  reliable.
- Public architecture-policy checking: defer unless there is demand for an
  explicit opt-in project profile.

## Tests And Fixtures

- `docs-check` and `json-check` for generated/handwritten docs.
- `tool-index` generation diff review.
- Smoke fixtures for every new tool group and protocol feature.
- NPM shim tests if package README, CLI behavior, targets, checksums, or install
  behavior changes.
- Skills package tests and dry pack if skill guidance changes.
- Release contract checks if MCP surface changed.

## Acceptance Criteria

- Docs and generated index agree.
- Tool catalog JSON passes validation.
- NPM and skills package docs do not claim unavailable tools.
- Smoke fixtures cover representative calls for each new group.
- Release evidence lists exact checks run.
- Deferred tools are clearly labeled as deferred and not advertised as shipped.

## Validation

```sh
zig build tool-index
zig build docs-check json-check
zig build smoke stdio-fixtures
```

For package changes:

```sh
cd packages/zigars-mcp-npm
npm run build
npm run test:node
bun run test:bun
```

```sh
cd packages/zigars-skills-npm
npm test
npm run pack:dry
```

Before release claims:

```sh
zig build release-check
```

## Final Handoff

Record:

- Shipped tool IDs by group.
- Deferred tool IDs and reasons.
- Docs updated.
- Package docs/tests updated.
- Exact release evidence.
- Known follow-up work.
