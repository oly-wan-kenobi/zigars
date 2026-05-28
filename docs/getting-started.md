# Getting Started

This walkthrough gets an MCP client from install to a small evidence bundle in
the first five minutes. Replace `/absolute/path/to/zig/project` with the Zig
workspace you want zigars to serve.

## Start The Server

Bun is the preferred npm launcher:

```sh
bunx --bun @zigars/mcp@0.2.0 --workspace /absolute/path/to/zig/project
```

Node/npm remains the fallback:

```sh
npx -y @zigars/mcp@0.2.0 --workspace /absolute/path/to/zig/project
```

Most MCP clients need those command and argument values in their own
configuration format. The npm shim adds `--transport stdio` unless you pass a
transport yourself. Zig `0.16.0` must be available on `PATH` or passed with
`--zig-path`. If `build.zig.zon` declares `minimum_zig_version`, startup emits a
stderr warning when the configured Zig cannot be confirmed compatible.

## First Verification Calls

Run these calls from the MCP client after it starts the server. If your project
does not have `src/main.zig`, substitute an existing workspace-relative Zig
file.

```text
zigars_workspace_info
```

Proves which workspace, cache directory, Zig path, optional backend paths, and
transport settings this server process is using. Use this first when paths look
wrong.

```text
zigars_doctor {"probe_backends":false}
```

Proves basic server health without running optional backend probes. It checks
configuration and reports the setup state that can be known without spending
time on ZLS, ZLint, zwanzig, zflame, or diff-folded probes. Use
`probe_backends=true` when you want doctor to run backend probes and compare
`zig version` with `build.zig.zon` `minimum_zig_version`.

```text
zig_ast_imports {"file":"src/main.zig"}
```

Proves a read-only parser-backed source insight. zigars reads a workspace file
and parses imports with `std.zig.Ast`; it does not execute project code or claim
compiler semantic analysis.

```text
zig_format {"file":"src/main.zig","apply":false}
```

Proves the preview-first write contract. The call can report a formatting diff
or no-op without changing the file because `apply` is false.

```text
zigars_trust_report
```

Proves the process-level trust posture: workspace/cache roots, path policy,
source-write policy, connection-time trust manifest, backend identities when
known, dependency hash references, and manifest risk audit. Pass
`include_clean_tree=true` only when you want the tool to run the bounded git
clean-tree check.

```text
resources/read {"uri":"zigars://trust/manifest"}
```

Reads the connection-time trust manifest linked from the MCP `initialize`
payload. It is the compact policy disclosure clients can inspect before choosing
individual tools.

## Next Steps

After the guided path works, use [tools.md](tools.md) for tool-surface concepts
and [tool-index.generated.md](tool-index.generated.md) for the full generated
catalog. Use [evidence-tiers.md](evidence-tiers.md) and
[determinism.md](determinism.md) to decide whether a result is enough or needs a
stronger cross-check.
