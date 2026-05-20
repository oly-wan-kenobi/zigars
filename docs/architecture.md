# Architecture Notes

Zigar is intentionally a deterministic workbench, not an advice or code-generation
server. The implementation is split around boundaries that keep that contract
auditable:

- `src/main.zig` owns CLI parsing, runtime setup, transport startup, and the
  package version surfaced from `build.zig.zon` through `src/version.zig`.
- `src/mcp_server.zig` is zigar's first-party MCP server adapter. zigar imports
  protocol types, JSON-RPC helpers, content/resource/prompt types, and transport
  primitives from the pinned upstream `mcp.zig` dependency, but zigar owns
  server-side request routing and the result-lifetime boundary for `tools/call`,
  `resources/read`, and `prompts/get`.
- `src/server.zig` wires MCP tools, resources, and prompts. Tool registration is
  driven by the manifest; server code should not grow per-tool switches.
- `src/tools/*.zig` groups MCP tool handlers by workflow area: discovery,
  agent workflows, core Zig commands, edit/ZLS operations, docs, static
  analysis, CI, linting, profiling, and resources. `src/tools/common.zig` is a
  small compatibility facade over focused shared helper modules.
- `src/runtime.zig` owns process-local runtime state such as workspace config,
  ZLS session pointers, counters, backend probes, and heuristic analysis caches.
- `src/tool_manifest.zig` is the typed tool manifest facade. It derives ids,
  tables, and lookup helpers from focused manifest modules:
  `src/tool_manifest/types.zig` defines the schema vocabulary,
  `src/tool_manifest/definitions.zig` lists tool definitions, and
  `src/tool_manifest/groups.zig` owns group keyword metadata. Together these hold
  names, descriptions, argument schemas, grouping, discovery keywords, handler
  references, planning policies, MCP read-only annotations, and risk metadata.
  `src/tool_metadata.zig` is a compatibility facade for consumers that still
  use the older name.
- `src/tool_handlers.zig` resolves manifest handler references to functions by
  handler module namespace. It does not map individual tools.
- `src/tool_registry.zig` adapts typed metadata to `mcp.zig` tools and validates
  JSON arguments before handlers run.
- `src/catalog.zig` merges static safety/common-intent text with manifest-derived
  groups, discovery keywords, argument hints, planning support, and risk
  metadata for public schema/capability responses.
- `src/json_result.zig` centralizes structured JSON result serialization for MCP
  tool responses and deep-clones structured content into the request allocator.
- `src/analysis.zig` contains heuristic source scanners. `src/analysis_contract.zig`
  owns the shared confidence vocabulary, limitations, and verification guidance
  for static-analysis tools.
- `src/state/documents.zig`, `src/lsp/*`, and `src/zls/*` own the ZLS session
  boundary. `src/lsp/client.zig` owns request/response correlation, pipe
  lifecycle, shutdown, and reader threads. `src/lsp/diagnostics_cache.zig` owns
  diagnostics retention, bounded eviction, snapshot ordering, and cache counters.
  Document-state locks should protect state transitions only; file I/O and LSP
  sends should run outside the mutex. Unsaved document content is retained in
  process memory so ZLS restarts reopen the same buffer content clients sent.
- `tools/zigar_tools.zig` is the pure-Zig helper executable used by build steps.
  Shared helper concerns live beside it in `tools/*.zig`.

## Tool Registry Rules

When adding or changing a tool:

1. Add or update one entry in `src/tool_manifest/definitions.zig`. That entry
   names the schema, group, handler reference, planning policy, read-only
   annotation, and risk flags. Add or update group-level discovery keywords in
   `src/tool_manifest/groups.zig` only when the tool introduces a new searchable
   intent.
2. Add the handler implementation in the appropriate `src/tools/*.zig` module.
   Only add a new namespace to `src/tool_handlers.zig` when introducing a new
   handler module, not for routine tool additions.
3. Regenerate docs with `zig build tool-index`.
4. Add focused tests for argument validation, risk metadata, and any parsing or
   workspace-safety behavior.

Argument schemas are part of the public client contract. When a field needs an
enum, default, range, path hint, or special argument note, attach that hint to the
owning schema instead of relying on a global field-name convention. A future tool
can reuse a field name such as `mode`, `command`, or `format` without inheriting
another tool's valid values.

Manifest review checklist:

- Tool names, descriptions, schemas, annotations, risk, and plan policy are
  public/client-visible contract.
- Free-form `args` fields must disclose backend, project-code, or user-command
  execution risk.
- `output` fields must disclose workspace artifact writes.
- Apply-gated mutations must advertise `writes_require_apply` and
  `preview_by_default`.
- Schema hints must target declared fields and match the field JSON type.
- Reused field names such as `before`, `after`, `mode`, and `format` need
  tool-local hints when the default meaning is not exact.

Tool handlers must not return bare expected failures. Validation, workspace-path
rejections, optional backend failures, parsing failures, write failures, and
known unsupported operations should return structured `argument_error`,
`workspace_path_error`, `backend_error`, or `tool_error` payloads through the
shared helpers. `zig build release-check` scans the public handler modules for
raw `InvalidArguments`, `ExecutionFailed`, `ResourceNotFound`, and unchecked
`splitToolArgs` propagation so new tools keep the same error contract.

`read_only` is the MCP annotation. It does not mean "no side effects at all":
`zig_build`, `zig_test`, `zigar_validate_patch`, failure-triage tools, and
`zig_profile_run` can execute code or create normal build/profile artifacts.
Use `riskFor` for finer-grained trust decisions. Apply-gated tools advertise
`writes_require_apply` and `preview_by_default` so clients can distinguish
preview workflows from default mutations.

## MCP Adapter Boundary

The build imports the pinned upstream `mcp` package directly. There is no local
patched MCP dependency in the build graph. The first-party adapter in
`src/mcp_server.zig` keeps zigar's supported MCP surface explicit:
`initialize`, `ping`, tools, resources, prompts, logging level, completion
requests, stdio transport, and loopback HTTP transport.

`tools/call`, `resources/read`, and `prompts/get` are the lifetime-sensitive
paths. zigar handlers may return owned `mcp.tools.ToolResult`,
`mcp.resources.ResourceContent`, or prompt message values whose slices and JSON
payloads must remain valid through response serialization. Registered tools,
resources, and prompts carry `ToolResultDeinit`, `ResourceContentDeinit`, or
`PromptMessagesDeinit` callbacks, and the adapter invokes those callbacks only
after the JSON-RPC response has been serialized and sent. This preserves
deterministic cleanup without carrying a patched upstream server.

The release gate scans `build.zig`, `build.zig.zon`, and the adapter contract so
future dependency updates keep using upstream `mcp` APIs directly while
retaining explicit zigar-owned cleanup hooks.

## Heuristic Analysis Rules

Heuristic scanners are useful for fast orientation, but they are not semantic
Zig analysis. Keep them isolated in `src/analysis.zig` or a dedicated analysis
module, include fixture tests, and prefer parser-backed, ZLS, Zig
compiler-backed, or optional zwanzig-backed tools for actions that would modify
source. Static-analysis results should include `analysis_kind`,
`capability_tier`, `confidence`, `confidence_class`, `source_coverage`,
`limitations`, `verify_with`, `recommended_cross_check`, and skipped-file counts
when unreadable files are omitted. The release hygiene check fails when a
static-analysis product tool is missing a tiered contract or when a
source-analysis tool stops being source-read-only.
