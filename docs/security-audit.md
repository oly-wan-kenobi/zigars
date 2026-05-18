# Security Readiness Audit

This checklist is for release reviews and MCP-client integration changes.

## Current Position

- zigar is a deterministic Zig workbench, not an OS sandbox.
- The configured workspace is the path boundary.
- Source writes require `apply=true`.
- stdout is reserved for MCP JSON-RPC.
- Build, test, profiler, and backend tools run with the user's privileges.

## Review Checklist

- Path inputs call `Workspace.resolve` before reading.
- Output paths call `Workspace.resolveOutput` before writing.
- Generated artifacts use explicit workspace-local output paths.
- Strict workspace mode rejects symlinked output ancestors, including nested
  outputs whose final parent directory does not exist yet.
- Mutating source tools stay preview-first and require `apply=true`.
- Preview-capable edit tools return unified diffs and source/updated hashes
  before writes.
- Free-form `args` are split by `command.splitArgs` and never passed through a shell.
- Tool arguments are validated against typed metadata before handler execution.
- Command results include timeout and output-limit metadata.
- Backend failures use structured `backend_error` payloads.
- ZLS failures preserve status, restart count, timeout, and last-failure data.
- HTTP smoke tests cover `initialize`, `tools/list`, `zigar_schema`, and `zigar_doctor`.
- Stdio fixture tests cover transport framing, formatter write gating, optional
  backend command wiring, and workspace-local generated outputs.
- Coverage summaries are generated from installed Zig test binaries, including
  the pure-Zig release helper, with required kcov line-coverage floors in CI.
- Generated docs are checked against the manifest-derived catalog.

## Known Trust Boundaries

- `zig build`, `zig test`, and build scripts can execute project code.
- ZLS, zwanzig, zflame, diff-folded, and platform profilers are local executables.
- `--strict-workspace` rejects symlink escapes through existing path ancestors,
  but it does not protect against concurrent filesystem races by untrusted local
  processes.
- MCP clients decide when to call tools and how to display structured results.

## Release Gate

Run:

```sh
zig build release-check
```

Then inspect any tool or backend changes against this checklist before tagging.
