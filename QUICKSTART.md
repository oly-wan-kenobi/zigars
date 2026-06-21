# zigars Quickstart

zigars is a **deterministic Zig development workbench for MCP clients** —
structured compiler diagnostics, ZLS code intelligence, parser-backed facts, and
preview-first refactors. It is **not** an AI code generator; the Zig compiler,
your tests, CI, and optional backends remain the source of truth.

## 1. Prerequisites

- Zig `0.16.0` on `PATH` (or pass `--zig-path`)
- Bun 1.3+ (preferred) or Node.js 18+ with `npx`
- An MCP client that can launch a stdio server

## 2. Run it

```sh
bunx --bun @zigars/mcp@0.2.0 --workspace /absolute/path/to/zig/project
# or
npx -y @zigars/mcp@0.2.0 --workspace /absolute/path/to/zig/project
```

Add it to an MCP client config:

```json
{
  "mcpServers": {
    "zigars": {
      "command": "bunx",
      "args": ["--bun", "@zigars/mcp@0.2.0", "--workspace", "/absolute/path/to/zig/project"]
    }
  }
}
```

## 3. First calls

From your MCP client, in order:

```text
zigars_workspace_info                       # confirm the served workspace
zigars_doctor {"probe_backends": false}     # basic health, no backend probes
zig_ast_imports {"file": "src/main.zig"}    # one parser-backed read-only fact
zig_format {"file": "src/main.zig", "apply": false}   # preview-first edit gate
```

## 4. Three things to try next

- **Diagnostics:** `zig_build` / `zig_test` for structured compiler output, or
  ZLS-backed `zig_diagnostics` when `zls 0.16.0` is installed.
- **Preview a refactor:** any source-mutating tool previews by default; pass
  `apply=true` only when you want the write.
- **Stay in scope:** every path resolves under `--workspace`; nothing outside it
  is read or written.

## Where to go from here

- Full reference: [README.md](README.md)
- Documentation map: [docs/INDEX.md](docs/INDEX.md)
- Optional backends: [docs/backends.md](docs/backends.md)
- Agent skills: [docs/skills.md](docs/skills.md)
- Trust and evidence: [docs/evidence-tiers.md](docs/evidence-tiers.md)
