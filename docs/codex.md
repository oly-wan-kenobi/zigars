# Codex Setup

Use stdio transport for Codex. stdout is reserved for MCP JSON-RPC, and zigars
prints logs/help/version information to stderr.

For Claude, Gemini CLI, Hermes, and generic MCP client setup, see
[Agent Clients](agent-clients.md).

## Pinned Workspace

Use this when one zigars server should always serve one Zig repository:

```toml
[mcp_servers.zigars]
command = "/absolute/path/to/zigars"
args = [
  "--transport", "stdio",
  "--workspace", "/absolute/path/to/your/zig/project",
  "--zig-path", "/opt/homebrew/bin/zig",
  "--zls-path", "/opt/homebrew/bin/zls"
]
startup_timeout_sec = 10.0
```

## Global Current-Workspace Entry

Use this when the MCP client launches servers with the active project as the
process working directory:

```toml
[mcp_servers.zigars]
command = "/absolute/path/to/zigars"
args = ["--transport", "stdio"]
startup_timeout_sec = 10.0
```

If a tool reports a workspace error, call `zigars_workspace_info` first. The
reported `workspace` value is the boundary used for every path read/write.

## Discovery Prompt

Put this in project instructions when the client does not naturally discover MCP
capabilities:

```md
When working on Zig code, prefer the zigars MCP tools for Zig version/env,
build, check, test, formatting, ZLS diagnostics, symbols, references, docs,
static analysis, and profiling before falling back to direct shell commands.
Source writes require apply=true. Use standard tools/list schemas for arguments;
query zigars_schema when you need grouping, risk, planning, or discovery keywords.
```

## First Calls

After the server connects, these calls give Codex enough project context without
guessing from shell output:

```text
zigars_context_pack {"mode":"standard"}
zigars_next_action {"goal":"orient in this Zig repository"}
zigars_validate_patch {"mode":"quick"}
```

Use `zigars_context_pack` before planning work, `zigars_next_action` when the next
Zig-specific check is unclear, and `zigars_validate_patch` before handing a
source change back.

## Health Checks

Call `zigars_doctor` for configuration state. Call it with
`probe_backends=true` when you need to verify that the configured backend
executables can actually start:

```json
{"probe_backends": true, "timeout_ms": 1000}
```

The probes are short command executions in the configured workspace. Missing
optional backends should not block core Zig command tools.

Call `zigars_backend_catalog` when a project needs to install or pin optional
backends. It returns the path flags, configured paths, probe commands,
compatibility rules, and related zigars tools for Zig, ZLS, ZLint, zwanzig,
zflame, and diff-folded.

Example config files are available in `examples/codex-global.toml` and
`examples/codex-pinned-workspace.toml`.
