# Codex Setup

Use stdio transport for Codex. stdout is reserved for MCP JSON-RPC, and zigar
prints logs/help/version information to stderr.

## Pinned Workspace

Use this when one zigar server should always serve one Zig repository:

```toml
[mcp_servers.zigar]
command = "/absolute/path/to/zigar"
args = [
  "--transport", "stdio",
  "--workspace", "/absolute/path/to/your/zig/project",
  "--strict-workspace",
  "--zig-path", "/opt/homebrew/bin/zig",
  "--zls-path", "/opt/homebrew/bin/zls"
]
startup_timeout_sec = 10.0
```

## Global Current-Workspace Entry

Use this when the MCP client launches servers with the active project as the
process working directory:

```toml
[mcp_servers.zigar]
command = "/absolute/path/to/zigar"
args = ["--transport", "stdio", "--strict-workspace"]
startup_timeout_sec = 10.0
```

If a tool reports a workspace error, call `zigar_workspace_info` first. The
reported `workspace` value is the boundary used for every path read/write.

## Discovery Prompt

Put this in project instructions when the client does not naturally discover MCP
capabilities:

```md
When working on Zig code, prefer the zigar MCP tools for Zig version/env,
build, check, test, formatting, ZLS diagnostics, symbols, references, docs,
static analysis, and profiling before falling back to direct shell commands.
Source writes require apply=true. Use standard tools/list schemas for arguments;
query zigar_schema when you need grouping, risk, planning, or discovery keywords.
```

## Health Checks

Call `zigar_doctor` for configuration state. Call it with
`probe_backends=true` when you need to verify that the configured backend
executables can actually start:

```json
{"probe_backends": true, "timeout_ms": 1000}
```

The probes are short command executions in the configured workspace. Missing
optional backends should not block core Zig command tools.

Example config files are available in `examples/codex-global.toml` and
`examples/codex-pinned-workspace.toml`.
