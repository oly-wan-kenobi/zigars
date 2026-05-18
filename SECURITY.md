# Security Policy

## Supported Versions

Security fixes target the current `main` branch and the latest published `0.x`
release tag when one exists. Until `1.0`, older `0.x` releases may receive
fixes at maintainer discretion when a low-risk backport is practical.

## Reporting a Vulnerability

Please report vulnerabilities privately to the maintainers rather than opening a
public issue first.

Include:

- Affected zigar version or commit.
- Operating system and Zig/ZLS versions.
- MCP client and server configuration.
- Minimal reproduction steps.
- Whether the issue can read or write files outside `--workspace`, execute
  unexpected commands, corrupt source files without `apply=true`, or leak data
  through stdout.

## Security Boundaries

zigar's primary boundary is the configured workspace:

- User-provided paths must resolve under `--workspace`.
- `--strict-workspace` realpaths existing files and output parents before
  accepting them, which rejects symlink escapes that resolve outside the
  workspace.
- Source writes require `apply=true`.
- stdout is reserved for MCP JSON-RPC.
- Command-backed tools run in the configured workspace.
- Tool arguments are validated before handlers run, and free-form `args` values
  are split into argv vectors without shell execution.
- Optional backends such as ZLS, zwanzig, zflame, and platform profilers run as
  local tools with the user's privileges.

zigar is not a sandbox for arbitrary untrusted code. Running `zig build`,
`zig test`, profilers, or project-provided build scripts can execute local code.
