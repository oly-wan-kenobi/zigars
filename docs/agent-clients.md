# Agent Clients

Zigar is client-agnostic. Any agent that can launch a local stdio MCP server can
use the same binary, schemas, workspace guard, and structured results.

Prefer stdio for local agent integrations:

```json
{
  "mcpServers": {
    "zigar": {
      "command": "/absolute/path/to/zigar",
      "args": [
        "--transport",
        "stdio",
        "--workspace",
        "/absolute/path/to/zig/project"
      ],
      "env": {}
    }
  }
}
```

Use a pinned `--workspace` for one-project configs. For current-workspace
configs, omit `--workspace` only when the client starts the MCP server with the
active project as its process working directory.

`zigar_client_config_generate` can preview client config content before you
write it. Use `apply=false` to inspect the generated MCP JSON, Codex TOML,
Claude JSON, Gemini JSON, or Markdown notes; use `apply=true` only after the
target path is correct for the active workspace. Applied configs are registered
with artifact provenance, preimage identity, and a generated content hash.

## Shared Agent Instructions

Use this instruction block for agents that do not discover MCP tools reliably:

```md
When working on Zig code, prefer zigar MCP tools for Zig version/env, build,
check, test, formatting, ZLS diagnostics, symbols, references, docs, static
analysis, and profiling before falling back to direct shell commands. Source
writes require apply=true. Use tools/list schemas for arguments; query
zigar_schema when you need grouping, risk, planning, backend setup, or discovery
keywords.
```

After connection, useful first calls are:

```text
zigar_context_pack {"mode":"standard"}
zigar_agent_guide_v2 {"client":"generic"}
zigar_next_action {"goal":"orient in this Zig repository"}
zigar_workspace_map {}
zigar_prompt_pack {}
```

`zigar_agent_guide_v2` and `zigar_client_guide` accept client labels such as
`codex`, `claude`, `gemini`, and `generic`. Clients that support completions can
use `completion/complete` for workflow names, resource URIs, command names, and
client names.

## Codex

Codex uses TOML config. Keep using the focused setup guide and examples:

- [Codex setup](codex.md)
- [examples/codex-global.toml](../examples/codex-global.toml)
- [examples/codex-pinned-workspace.toml](../examples/codex-pinned-workspace.toml)

Use:

```text
zigar_agent_guide_v2 {"client":"codex"}
zigar_client_guide {"client":"codex"}
```

## Claude Code And Claude Desktop

Claude Code can consume a project `.mcp.json` with the standard `mcpServers`
shape:

```json
{
  "mcpServers": {
    "zigar": {
      "type": "stdio",
      "command": "/absolute/path/to/zigar",
      "args": [
        "--transport",
        "stdio",
        "--workspace",
        "/absolute/path/to/zig/project"
      ],
      "env": {}
    }
  }
}
```

Template: [examples/claude-code.mcp.json](../examples/claude-code.mcp.json).

The same server object can be added with `claude mcp add-json`:

```sh
claude mcp add-json zigar '{"type":"stdio","command":"/absolute/path/to/zigar","args":["--transport","stdio","--workspace","/absolute/path/to/zig/project"],"env":{}}'
```

Claude Desktop uses the same `mcpServers` object shape in its desktop MCP config.
Use absolute executable paths when the desktop app does not inherit the shell
`PATH`.

Use:

```text
zigar_agent_guide_v2 {"client":"claude"}
zigar_client_guide {"client":"claude"}
```

## Gemini CLI

Gemini CLI reads MCP servers from `settings.json`. Keep `trust` explicit; leave
it `false` until the user understands zigar's workspace and source-write policy:

```json
{
  "mcpServers": {
    "zigar": {
      "command": "/absolute/path/to/zigar",
      "args": [
        "--transport",
        "stdio",
        "--workspace",
        "/absolute/path/to/zig/project"
      ],
      "cwd": "/absolute/path/to/zig/project",
      "timeout": 600000,
      "trust": false
    }
  }
}
```

Template: [examples/gemini-settings.json](../examples/gemini-settings.json).

Use:

```text
zigar_agent_guide_v2 {"client":"gemini"}
zigar_client_guide {"client":"gemini"}
```

## Hermes And Skill-Based Agents

Hermes distributions and skill systems vary more than Codex, Claude, and Gemini
CLI. Treat zigar as a local MCP server where Hermes exposes MCP server
configuration. If a Hermes skill wrapper is required, keep it thin: pass zigar
JSON-RPC tool results through as structured data and avoid scraping human text.

For wrappers that prefer an HTTP process, start zigar explicitly:

```sh
zigar --transport http --host 127.0.0.1 --port 8080 --workspace /absolute/path/to/zig/project
```

The HTTP transport accepts MCP JSON-RPC requests at `/`. zigar supports it as a
local loopback endpoint; non-loopback bind hosts are rejected instead of being
treated as an unauthenticated remote mode.

Use:

```text
zigar_agent_guide_v2 {"client":"generic"}
zigar_client_guide {"client":"generic"}
```

If an agent can only run shell commands and cannot speak MCP, zigar currently
does not expose individual MCP tools as CLI subcommands. Use direct Zig commands
or a small MCP bridge for that client rather than parsing zigar server stdout.

## Client Validation

Before recommending a client profile publicly, capture a short smoke transcript
for that client: startup, `tools/list`, `zigar_schema`, `zigar_workspace_info`,
one read-only Zig command, one docs/static-analysis call, and one preview-first
source-write tool without `apply=true`. The transcript should show the command
path, workspace path, and whether the client preserved structured MCP result
fields.

Use `zigar_adoption_pack` for the initial evidence bundle, then
`zigar_smoke_plan` to list client and backend smoke scenarios. If public
backend support is part of the recommendation, feed observed backend
conformance JSON into `zigar_conformance_report`; do not treat configured paths
or planning output as proof that an optional backend works.

Client launch environments differ. A profile is mature only when path handling,
workspace selection, stdio framing, refresh after tool changes, and structured
result display are verified in that client instead of inferred from another
client's behavior.

## Operational Checks

- Restart the client after changing MCP config so it refreshes `tools/list`.
- Use absolute paths for `zigar`, `zig`, `zls`, and optional backends when the
  client process does not inherit an interactive shell environment.
- Call `zigar_workspace_info` first when paths resolve unexpectedly.
- Call `zigar_doctor {"probe_backends":true,"timeout_ms":1000}` when backend
  tools are missing or executable paths are unclear.
- Use `zigar_job_start`, `zigar_job_result`, `tasks/list`, or `tasks/result`
  when the client wants retained build/test evidence instead of a one-shot tool
  response.
- Use `zigar_resource_query` or `resources/read` for `zigar://jobs`,
  `zigar://run/events`, `zigar://workspace/roots`, and dynamic
  `zigar://file/{path}/...` resources.
- Keep source writes explicit: source-mutating tools remain preview-first until
  `apply=true` is present in the tool arguments.
