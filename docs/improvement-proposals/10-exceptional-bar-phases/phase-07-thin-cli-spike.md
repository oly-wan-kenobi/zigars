# Phase 7 - Thin CLI Spike

Status: ready for implementation
Primary source sections:
[08 section 5.5](../08-exceptional-bar-action-plan.md#55-public-library-extraction),
[09 section 8](../09-exceptional-bar-deep-research-findings.md#8-platform-research)

## Objective

Add the first public non-MCP CLI vertical slice over existing use cases. The CLI
should serve CI, release bots, and shell-only users without creating a stable
public Zig library API.

## Ordered Tasks

### P7-T1 Choose A Minimal CLI Shape

Implement a minimal command shape under the existing `zigars` binary, not
`tools/zigars_tools.zig`.

Recommended first commands:

- `zigars cli workspace-info --workspace <path> --json`;
- `zigars cli doctor --workspace <path> --probe-backends=false --json`.

Acceptance criteria:

- MCP server mode remains the default existing behavior.
- CLI mode is explicit and documented.
- CLI stdout is stable machine JSON for successful command output.
- CLI diagnostics go to stderr.
- Exit codes are documented.

Likely files:

- `src/main.zig`
- `src/bootstrap/config.zig`
- `src/bootstrap/runtime.zig`
- `src/app/usecases/discovery/` or `src/app/usecases/environment/`

### P7-T2 Reuse Existing Use Cases

Wire CLI commands to existing application use cases instead of duplicating MCP
handler logic.

Acceptance criteria:

- Workspace path resolution matches MCP server behavior.
- Optional backend probing behavior matches `zigars_doctor`.
- The JSON shape is either the same as MCP `structuredContent` or explicitly
  versioned as CLI output.
- No stable public Zig library API is introduced.

### P7-T3 Define Exit Codes

Add a small documented exit-code contract.

Acceptance criteria:

- Success exits `0`.
- Invalid CLI arguments use a stable non-zero code.
- Workspace/path errors use a stable non-zero code.
- Backend or doctor findings can return success with `ok=false` JSON when the
  command itself executed correctly.
- Fatal internal errors use a distinct code.

### P7-T4 Add CLI Tests

Add focused tests for argument parsing, stdout/stderr separation, JSON shape,
workspace path handling, and exit code behavior.

Acceptance criteria:

- Tests do not require optional backends.
- Tests do not write outside temporary/workspace roots.
- Server-mode tests continue to pass.

### P7-T5 Document The CLI Spike

Update docs without overstating the surface.

Acceptance criteria:

- README and distribution docs describe the CLI as a thin reporting surface.
- Docs say MCP remains the primary agent surface.
- Docs say generated artifacts and CLI JSON are the non-MCP integration path.
- Docs say a public library API is still deferred.

### P7-T6 Prepare Follow-Up Command List

Document, but do not implement unless small and obvious, the next CLI commands:

- `ci-ingest`;
- `junit`;
- `coverage-budget`;
- `docs-drift`;
- `release-evidence-pack`;
- `artifact-index`.

Acceptance criteria:

- Each follow-up command maps to an existing use case.
- Each has a proposed JSON output contract and exit-code behavior.
- Follow-up work is separate from the first vertical slice.

## Out Of Scope

- Do not promote `tools/zigars_tools.zig` as the user CLI.
- Do not extract a public Zig library API.
- Do not add source-mutating CLI commands in the first spike.
- Do not add installers or client config writers from the CLI.

## Validation

```sh
zig fmt build.zig build.zig.zon src tools
zig build test
zig build docs-check json-check
```

If CLI command-line parsing changes release behavior, also run:

```sh
zig build -Doptimize=ReleaseSafe
```
