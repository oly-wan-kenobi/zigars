# Examples

This directory contains client configuration shapes and a small JSONL set of
tool calls. Replace absolute paths before using any config.

## Files

- `claude-code.mcp.json`: direct-binary stdio configuration using an explicit
  workspace, Zig path, and ZLS path in an MCP JSON shape suitable for
  Claude-style clients.
- `codex-global.toml`: Codex TOML configuration for a direct `zigars` binary
  where the client starts the server from the active project directory. Use this
  only when your client reliably sets the current workspace.
- `codex-pinned-workspace.toml`: Codex TOML configuration pinned to one Zig
  workspace with explicit Zig and ZLS paths. This is safer for a single project
  and should not be reused across unrelated repositories.
- `gemini-settings.json`: Gemini CLI settings shape with an explicit workspace,
  Zig path, ZLS path, working directory, timeout, and `trust: false`.
- `tool-calls.jsonl`: sample MCP `tools/call` payloads for schema inspection,
  doctor output, format preview, `zig_check`, and `zig build test`.

## First Verification Calls

Use the same first path as [getting-started.md](../docs/getting-started.md).
If your project does not have `src/main.zig`, substitute an existing
workspace-relative Zig file.

```text
zigars_workspace_info
zigars_doctor {"probe_backends":false}
zig_ast_imports {"file":"src/main.zig"}
zig_format {"file":"src/main.zig","apply":false}
zigars_trust_report
```

The sequence proves the served workspace, basic health without optional backend
probes, one parser-backed read-only insight, the preview-first source-write
gate, and the process trust posture. After that, use
[docs/tool-index.generated.md](../docs/tool-index.generated.md) for the full
tool catalog.
