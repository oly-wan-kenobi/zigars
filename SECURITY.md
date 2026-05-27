# Security Policy

## Supported Versions

Security fixes target the current `main` branch and the latest published `0.x`
release tag when one exists. Until `1.0`, older `0.x` releases may receive
fixes at maintainer discretion when a low-risk backport is practical.

## Reporting a Vulnerability

Please report vulnerabilities privately to the maintainers rather than opening a
public issue first.

Preferred channel:

- Use GitHub private vulnerability reporting for this repository:
  <https://github.com/oly-wan-kenobi/zigars/security/advisories/new>

Fallback channel:

- If GitHub private reporting is unavailable because of repository visibility or
  account settings, email `oliver.guenthardt@digitecgalaxus.ch` with the subject
  prefix `[zigars security]`.

Include:

- Affected zigars version or commit.
- Operating system and Zig/ZLS versions.
- MCP client and server configuration.
- Minimal reproduction steps.
- Whether the issue can read or write files outside `--workspace`, execute
  unexpected commands, corrupt source files without `apply=true`, or leak data
  through stdout.

Do not include exploit details in a public issue or discussion before maintainers
have acknowledged and triaged the report.

## Response Expectations

Maintainers aim to acknowledge a private vulnerability report within 7 days and
provide an initial triage assessment within 14 days. The expected fix and
disclosure timeline depends on severity, available reproductions, and release
risk. When a fix ships, release notes should describe the impact and affected
versions without exposing unnecessary exploit detail.

## Security Boundaries

zigars' primary boundary is the configured workspace:

- User-provided paths must resolve under `--workspace`.
- Existing input paths, existing output paths, and the nearest existing output
  parent are realpathed before acceptance. Symlinks are supported only when the
  real target remains inside the workspace; symlink escapes are rejected.
- Source writes require `apply=true`.
- stdout is reserved for MCP JSON-RPC.
- Command-backed tools run in the configured workspace.
- Tool arguments are validated before handlers run, and free-form `args` values
  are split into argv vectors without shell execution.
- Optional backends such as ZLS, zwanzig, zflame, and platform profilers run as
  local tools with the user's privileges.

zigars is not a sandbox for arbitrary untrusted code. Running `zig build`,
`zig test`, profilers, or project-provided build scripts can execute local code.
