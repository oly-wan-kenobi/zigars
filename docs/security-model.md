# Security Model

zigar is a deterministic development workbench, not an operating-system
sandbox.

The primary boundary is the configured workspace:

- User-provided paths must resolve under `--workspace`.
- `--strict-workspace` additionally checks real paths for existing files and the
  nearest existing output parent, rejecting symlink escapes even when the final
  output directory does not exist yet.
- Source writes require `apply=true`.
- stdout is reserved for MCP JSON-RPC; logs go to stderr.
- Tool arguments are validated against typed metadata before handlers run.
- Free-form `args` are split into argv vectors and are not passed through a
  shell.

Command-backed tools run with the user's privileges. Running `zig build`,
`zig test`, profilers, or project build scripts can execute local code.

Optional backends such as ZLS, zwanzig, zflame, and platform profilers are local
processes. Configure their paths explicitly when using zigar in sensitive
workspaces.

See [security-audit.md](security-audit.md) for the release-review checklist.
