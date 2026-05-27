# Phase 6 - Protocol Feature Pilots

Source plan: `../zigars-improvement-surface-implementation.md`

## Goal

Adopt MCP elicitation and sampling where they improve existing workflows without
making zigars dependent on supporting clients.

## Standing Constraints

- Non-supporting clients retain current behavior.
- Elicitation and sampling are capability-gated.
- Elicitation must never ask for secrets.
- Existing apply gates remain the baseline safety mechanism.
- Sampling must use the host LLM only for summarization or classification of
  provided evidence, not code generation inside zigars.
- Public output must say whether protocol features were used or unavailable.

## Current Code Anchors

- Environment advisory tools currently use `_elicit` naming in manifest/docs:
  `zigars_setup_elicit`, `zigars_profile_elicit`, and `zigars_backend_elicit`.
- MCP server capability handling and routing lives in
  `src/adapters/mcp/server.zig`.
- Transactional editing tools live in
  `src/adapters/mcp/tools/transactional_editing.zig`.
- Diagnostics/profiling outputs that may benefit from sampling live in
  `src/adapters/mcp/tools/diagnostics.zig` and
  `src/adapters/mcp/tools/profiling.zig`.
- Phase 1 should have introduced elicitation/sampling helper scaffolds.

## Work Items

1. Rename advisory tools.
   - `zigars_setup_elicit` to `zigars_setup_guidance`
   - `zigars_profile_elicit` to `zigars_profile_guidance`
   - `zigars_backend_elicit` to `zigars_backend_guidance`
   - Decide whether old names are removed immediately or deprecated for one
     minor release. If aliases remain, document them as compatibility aliases,
     not protocol elicitation.
2. Pilot protocol elicitation.
   - `zigars_patch_session_apply`
   - fuzz runs that execute or allocate substantially
   - dependency mutators when applying remote package changes
   - Use fallback apply behavior when client support is missing.
3. Pilot protocol sampling.
   - `zigars_failure_fusion`
   - `zig_panic_trace_analyze`
   - zlint/samply/public API diff summaries
   - Keep raw structured output available even when a summary is produced.
4. Add client-capability fields to structured outputs.
   - `elicitation_used`
   - `elicitation_unavailable_reason`
   - `sampling_used`
   - `summary_unavailable_reason`
5. Add client fake tests for supported, unsupported, declined, malformed, and
   timeout responses.

## Key Files

- `src/adapters/mcp/tools/environment.zig`
- `src/app/usecases/environment/`
- `src/adapters/mcp/tools/transactional_editing.zig`
- `src/adapters/mcp/tools/diagnostics.zig`
- `src/adapters/mcp/tools/profiling.zig`
- `src/adapters/mcp/server.zig`
- `src/adapters/mcp/registry.zig`
- `src/manifest/definitions/environment_profiles.zig`
- `src/manifest/definitions/transactional_editing.zig`
- `src/manifest/definitions/diagnostics.zig`
- `src/manifest/definitions/profiling.zig`
- `docs/tools.md`
- `docs/tool-index.generated.md`

## Tests And Fixtures

- Manifest and docs tests for `_guidance` naming.
- Optional alias tests if old `_elicit` names are kept temporarily.
- Fake client-capability tests for elicitation request creation and response
  handling.
- Tests proving unsupported clients keep current apply behavior.
- Tests proving elicitation decline/abort prevents mutation.
- Sampling tests for summary success and unavailable fallback.
- Smoke fixtures for renamed guidance tools and at least one protocol pilot.

## Acceptance Criteria

- Non-supporting clients retain current behavior.
- Supporting-client tests cover request creation and response handling through
  fake transport.
- No elicitation request asks for secrets.
- `_elicit` naming no longer appears as the primary public tool name.
- Structured outputs expose whether elicitation/sampling was used.

## Validation

```sh
zig build test
zig build docs-check json-check
zig build smoke stdio-fixtures
```

Run release-style validation if old names are removed:

```sh
zig build release-check
```

## Handoff For Next Phase

Record:

- Rename/deprecation decision for old `_elicit` tool IDs.
- Pilot tools using elicitation.
- Pilot tools using sampling.
- Client capability fields added.
- Exact validation commands run.
