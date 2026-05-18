# Architecture Notes

Zigar is intentionally a deterministic workbench, not an advice or code-generation
server. The implementation is split around boundaries that keep that contract
auditable:

- `src/main.zig` owns CLI parsing, runtime setup, transport startup, and the
  package version surfaced from `build.zig.zon` through `src/version.zig`.
- `src/server.zig` wires MCP tools, resources, prompts, and handler dispatch.
  It should stay a dispatcher; tool behavior lives under `src/tools/`.
- `src/tools/*.zig` groups MCP tool handlers by workflow area: discovery,
  agent workflows, core Zig commands, edit/ZLS operations, docs, static
  analysis, CI, linting, profiling, and resources. `src/tools/common.zig` is a
  small compatibility facade over focused shared helper modules.
- `src/runtime.zig` owns process-local runtime state such as workspace config,
  ZLS session pointers, counters, backend probes, and heuristic analysis caches.
- `src/tool_metadata.zig` is the typed tool registry: tool ids, names,
  descriptions, argument schemas, MCP read-only annotations, and risk metadata.
- `src/tool_registry.zig` adapts typed metadata to `mcp.zig` tools and validates
  JSON arguments before handlers run.
- `src/catalog.zig` merges the static discovery catalog with registry-derived
  argument and risk metadata for public schema/capability responses.
- `src/json_result.zig` centralizes structured JSON result serialization for MCP
  tool responses and deep-clones structured content into the request allocator.
- `src/analysis.zig` contains heuristic source scanners. Every heuristic result
  should state its analysis kind and confidence.
- `src/state/documents.zig`, `src/lsp/*`, and `src/zls/*` own the ZLS session
  boundary. Document-state locks should protect state transitions only; file I/O
  and LSP sends should run outside the mutex. Unsaved document content is retained
  in process memory so ZLS restarts reopen the same buffer content clients sent.
- `tools/zigar_tools.zig` is the pure-Zig helper executable used by build steps.
  Shared helper concerns live beside it in `tools/*.zig`.

## Tool Registry Rules

When adding or changing a tool:

1. Add the `ToolId` and `ToolMeta` entry in `src/tool_metadata.zig`.
2. Add or update `riskFor` if the tool writes source, writes artifacts, mutates
   LSP state, executes project code, executes a user command, or invokes an
   external backend.
3. Add the handler in the appropriate `src/tools/*.zig` module and map it in
   `src/server.zig`.
4. Add discovery grouping/keywords in `src/tool_catalog.json`.
5. Regenerate docs with `zig build tool-index`.
6. Add focused tests for argument validation, risk metadata, and any parsing or
   workspace-safety behavior.

`read_only` is the MCP annotation. It does not mean "no side effects at all":
`zig_build`, `zig_test`, `zigar_validate_patch`, failure-triage tools, and
`zig_profile_run` can execute code or create normal build/profile artifacts.
Use `riskFor` for finer-grained trust decisions. Apply-gated tools advertise
`writes_require_apply` and `preview_by_default` so clients can distinguish
preview workflows from default mutations.

## Heuristic Analysis Rules

Heuristic scanners are useful for fast orientation, but they are not semantic
Zig analysis. Keep them isolated in `src/analysis.zig` or a dedicated analysis
module, include fixture tests, and prefer ZLS or Zig compiler-backed tools for
actions that would modify source. JSON heuristic results should include skipped
file counts when unreadable files are omitted.
