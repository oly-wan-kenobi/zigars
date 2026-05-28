# Security Model

zigars is a deterministic development workbench, not an operating-system
sandbox.

The primary boundary is the configured workspace:

- User-provided paths must resolve under `--workspace`.
- Existing input paths, existing output paths, and the nearest existing output
  parent are realpathed. Symlinks are supported only when the real target stays
  inside the workspace; symlink escapes are rejected even when the final output
  directory does not exist yet.
- Source writes require `apply=true`.
- Patch-session writes additionally require matching preimage hashes from the
  preview. Rollback is limited to recorded session files whose current hash still
  matches the applied output.
- Generated, cache, artifact, and vendored paths are classified separately and
  should be changed through source inputs or regeneration commands.
- stdout is reserved for MCP JSON-RPC; logs go to stderr.
- Audit JSONL is off by default. When enabled with `--audit-log`, metadata mode
  records payload hashes and sizes, redacted mode masks secret-like JSON fields,
  and full mode records raw MCP payloads only with explicit
  `--audit-log-mode full` plus a stderr privacy warning.
- Tool arguments are validated against typed metadata before handlers run.
- Free-form `args` are split into argv vectors and are not passed through a
  shell.
- Command timeouts are total wall-clock deadlines, not per-read idle timers.

Command-backed tools run with the user's privileges. Running `zig build`,
`zig test`, profilers, or project build scripts can execute local code.

Optional backends such as ZLS, ZLint, zwanzig, zflame, Samply, Tracy, and
platform profilers are local processes. Configure their paths explicitly when
using zigars in sensitive workspaces. ZLint automatic fixes are delegated to the
configured binary and still require zigars' `apply=true` source-write gate.

HTTP transport is local-only by default. `--transport http` must bind a loopback
host such as `127.0.0.1`, `localhost`, or `::1`; non-loopback hosts are rejected
rather than exposed as an unauthenticated remote endpoint. HTTP remains
unauthenticated by design because its supported use is local integration; stdio
is the default transport for agent clients.

zigars uses the pinned upstream MCP package for protocol types, JSON-RPC helpers,
and transport primitives, but the server adapter is first-party code under
`src/adapters/mcp/server.zig`. There is no patched upstream MCP server in the build. That
keeps the local security boundary auditable: zigars owns request routing,
workspace/tool validation before handler execution, and post-serialization
cleanup of owned tool, resource, and prompt results.

## Threat Matrix

| Boundary | Guarantee | Remaining responsibility |
| --- | --- | --- |
| Workspace paths | Canonical path checks reject symlink escapes and writes outside `--workspace`. | Choose the intended workspace and inspect generated artifacts before trusting them. |
| Source writes | Mutating tools are preview-first and require `apply=true`; patch sessions also check preimage hashes. | Agents and users decide whether a preview is correct before applying it, and rerun previews after unrelated edits. |
| Generated/vendor paths | Policy tools classify generated, cache, artifact, and vendored paths and route them to source or regeneration steps. | Maintainers still own generator behavior, dependency policy, and review of regenerated diffs. |
| Command execution | Commands use argv vectors without shell expansion and bounded output/timeouts. | `zig build`, profilers, and user-provided commands still execute local project code. |
| MCP transport | stdio is local-process only; HTTP binds only loopback hosts. | Do not place the unauthenticated HTTP endpoint behind a remote proxy. |
| Optional backends | Backend absence and unsupported capabilities are structured results. | Pin and validate backend versions when release or CI decisions depend on them. |

See [security-audit.md](security-audit.md) for the release-review checklist.
