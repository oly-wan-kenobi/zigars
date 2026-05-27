# Phase 1 - MCP Contract Foundations

Source plan: `../zigar-improvement-surface-implementation.md`

## Goal

Finish protocol-level foundations that later tool batches can depend on:
declared output schemas, richer completions, artifact resource links, and
capability-gated scaffolds for elicitation and sampling.

## Standing Constraints

- Keep stdout reserved for MCP JSON-RPC.
- Preserve existing clients: new protocol features must be additive and
  gracefully ignored by clients that do not support them.
- New public tool contracts are manifest-first and must have structured
  content plus useful text fallback.
- Do not make zigar depend on LLM-host features. Elicitation and sampling are
  optional helpers with structured fallback fields.
- Do not add public architecture-policy tools in this phase.

## Current Code Anchors

- `src/bootstrap/runtime.zig` already enables completions, resource
  subscriptions, and tasks.
- `src/adapters/mcp/server.zig` owns MCP routing, `tools/list`, result
  serialization, and initialization state.
- `src/adapters/mcp/server/completion.zig` already handles
  `completion/complete`, but completion sources are shallow.
- `src/adapters/mcp/resources.zig` and
  `src/adapters/mcp/server/resource_subscriptions.zig` own resource routing and
  subscriptions.
- `src/adapters/mcp/result.zig` and `src/app/result_shape.zig` are the natural
  places for reusable result helpers.
- `src/adapters/mcp/registry.zig`, `src/manifest/types.zig`,
  `src/manifest/definitions*.zig`, and `src/manifest/tooling.zig` own tool
  metadata projection.

## Work Items

1. Add output-schema support to the manifest model.
   - Extend `src/manifest/types.zig` with an optional `output_schema` field.
   - Add schema vocabulary helpers near `src/adapters/mcp/schema.zig` or an
     existing manifest schema module.
   - Update manifest tests for serialization, defaults, and generated contract
     drift.
2. Project output schemas through MCP `tools/list`.
   - Register schemas in `src/adapters/mcp/registry.zig`.
   - Serialize `outputSchema` only when present.
   - Keep pagination behavior unchanged.
3. Define shared output envelopes before bespoke schemas.
   - Error envelope.
   - Command result envelope.
   - Analysis result envelope.
   - Patch/session/artifact envelope.
   - Require output schema for all new tools after this phase.
4. Upgrade completions from static allowlists to manifest-backed sources.
   - Enum argument completions.
   - Completion source hints for test names, backend IDs, artifact IDs, profile
     names, workflows, and resource URIs.
   - Bounded results with `hasMore` behavior where applicable.
5. Add artifact resource-link support.
   - Register `zigar://artifacts/{sha}` as a resource template.
   - Add a dynamic resource handler that reads artifacts through existing app
     ports.
   - Add result helpers that emit `resource_link` content blocks for large
     artifacts while preserving compact text fallback.
6. Add helper scaffolds for protocol elicitation and sampling.
   - Store client capabilities from `initialize`.
   - Add server-to-client request helpers for `elicitation/create` and
     `sampling/createMessage`.
   - Add fake-client tests for supported and unsupported clients.
   - Do not adopt the helpers broadly until Phase 6.

## Pilot Scope

Use a small pilot set to avoid boiling the ocean:

- One static-analysis tool with an analysis envelope.
- One artifact-heavy or runtime tool with `resource_link`.
- One patch/session tool with a session envelope.
- One enum-backed argument completion and one dynamic completion source.

## Key Files

- `src/manifest/types.zig`
- `src/manifest/tooling.zig`
- `src/manifest/definitions/*.zig`
- `src/adapters/mcp/schema.zig`
- `src/adapters/mcp/registry.zig`
- `src/adapters/mcp/server.zig`
- `src/adapters/mcp/server/completion.zig`
- `src/adapters/mcp/resources.zig`
- `src/adapters/mcp/result.zig`
- `tools/integration/http/*`
- `tools/integration/stdio/*`

## Tests And Fixtures

- Manifest type tests for absent and present output schemas.
- Registry tests proving `tools/list` includes `outputSchema` for pilot tools
  and omits it for tools without one.
- Completion tests for enum and dynamic source behavior.
- Resource tests for artifact URI read success, missing artifact, and path
  policy failure.
- HTTP and stdio smoke fixtures that include representative `tools/list`,
  `completion/complete`, and resource reads.

## Acceptance Criteria

- Existing clients still work when ignoring `outputSchema`.
- `tools/list` includes `outputSchema` for pilot tools.
- `completion/complete` completes at least one enum-backed argument and one
  dynamic source.
- At least one heavy-output tool can return a `resource_link` content block.
- Elicitation and sampling helpers are capability-gated and have structured
  unsupported-client fallbacks.

## Validation

```sh
zig build docs-check json-check
zig build test
zig build smoke stdio-fixtures
```

Run broader checks before merging if server routing or transport behavior
changes:

```sh
zig build release-check
```

## Handoff For Next Phase

Record:

- Output-schema pilot tools.
- Completion sources implemented.
- Resource URI templates added.
- Any limitations in schema vocabulary.
- Exact smoke fixtures updated.
