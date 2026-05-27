# Architecture Notes

Zigars is intentionally a deterministic workbench, not an advice or code-generation
server. The implementation is split around boundaries that keep that contract
auditable:

- `src/main.zig` delegates process startup to `src/bootstrap/runtime.zig`; the
  source root contains only `src/main.zig` and `src/root.zig`. Public imports
  should go through package owners such as `src/app`, `src/domain`, `src/infra`,
  `src/manifest`, `src/adapters`, and `src/bootstrap`.
- `src/adapters/mcp/server.zig` is zigars' first-party MCP server adapter. zigars imports
  protocol types, JSON-RPC helpers, content/resource/prompt types, and transport
  primitives from the pinned upstream `mcp.zig` dependency, but zigars owns
  server-side request routing and the result-lifetime boundary for `tools/call`,
  `resources/read`, and `prompts/get`.
- `src/adapters/mcp/registration.zig`, `registry.zig`, and `handlers.zig` wire
  MCP tools from the typed manifest through bootstrap-supplied runtime ports.
- `src/adapters/mcp/tools/*.zig` groups MCP projections by workflow area.
  Application behavior belongs under `src/app/usecases/**`; root-level tool
  modules and direct root implementation aliases must stay absent.
- `src/bootstrap/runtime_state.zig` owns process composition state such as workspace config,
  counters, backend probes, and infra-owned cache/session state handles.
  Runtime job, event, subscription, and client-root rings live in
  `src/infra/runtime_ux/state.zig` and are intentionally bounded and process-local.
- `src/manifest/mod.zig` is the typed tool manifest owner. It derives ids,
  tables, and lookup helpers from focused manifest modules:
  `src/manifest/types.zig` defines the schema vocabulary,
  `src/manifest/definitions.zig` lists tool definitions, and
  `src/manifest/groups.zig` owns group keyword metadata. Together these hold
  names, descriptions, argument schemas, grouping, discovery keywords, handler
  references, planning policies, MCP read-only annotations, and risk metadata.
- `src/adapters/mcp/handlers.zig` resolves manifest handler references to functions by
  handler module namespace. It does not map individual tools.
- `src/adapters/mcp/registry.zig` adapts typed metadata to `mcp.zig` tools and validates
  JSON arguments before handlers run. `src/adapters/mcp/schema.zig` owns the
  transport-specific projection from manifest schema metadata to MCP input
  schemas.
- `src/manifest/tool_catalog_render.zig` renders the public tool catalog by
  projecting static manifest metadata, domain-owned backend setup metadata, and
  domain-owned static-analysis contracts. `src/infra/runtime_ux/catalog.zig`
  is only the concrete `ToolCatalog` port wrapper.
- `src/adapters/mcp/result.zig` centralizes structured JSON result serialization for MCP
  tool responses and deep-clones structured content into the request allocator.
- `src/app/usecases/static_analysis/source_summary.zig` contains source-text
  summaries, and `src/app/usecases/static_analysis/workspace_scans.zig`
  contains port-backed workspace scans. `src/domain/zig/static_analysis_contracts.zig`
  owns the shared confidence vocabulary, limitations, and verification guidance
  for static-analysis tools.
- `src/infra/zls/*` owns the ZLS session boundary.
  `src/infra/zls/client.zig` owns request/response correlation, pipe
  lifecycle, shutdown, and reader threads. `src/infra/zls/diagnostics_cache.zig` owns
  diagnostics retention, bounded eviction, snapshot ordering, and cache counters.
  Document-state locks should protect state transitions only; file I/O and LSP
  sends should run outside the mutex. Unsaved document content is retained in
  process memory so ZLS restarts reopen the same buffer content clients sent.
- `tools/zigars_tools.zig` is the pure-Zig helper executable used by build steps.
  Shared helper concerns are grouped under `tools/common`, `tools/coverage`,
  `tools/integration`, `tools/release`, and `tools/quality`.

The architecture guard is strict by default: its exception allowlist must remain
empty. New boundary pressure should be resolved by adding app ports, bootstrap
composition, or infra-owned state rather than by adding temporary guard
exceptions.

## Enforced Hexagonal Rules

The authoritative rule implementations are `tools/quality/architecture_guard.zig`,
`tools/quality/hex_arch_inventory.zig`, and the build wiring in `build.zig`. This
section describes the contract those tools enforce.

| Area | Rule |
|---|---|
| `src/domain/**` | Pure domain code may import only `std` and other domain modules. It must not import MCP, app, adapters, infra, bootstrap, manifest, broad runtime state, retired handler facades, or concrete effect modules. |
| `src/app/**` | App code owns typed requests, results, errors, use cases, context, and ports. It may import `std`, domain, and app modules. Effects must be expressed through app ports, not concrete process, workspace, artifact, ZLS, backend, clock, ID, or observability implementations. |
| `src/adapters/mcp/**` | MCP adapters own JSON argument mapping, schema projection, public result rendering, and structured public error mapping. Production adapter code may depend on MCP, app/domain values, manifest metadata, and adapter-local modules; it must not import infra, bootstrap, broad runtime, retired handler facades, or concrete effects. |
| `src/infra/**` | Infra implements app ports using concrete effects. It may depend on app port contracts and domain values, but not MCP, adapters, bootstrap composition, manifest dispatch, public MCP result renderers, or handler modules. |
| `src/bootstrap/**` | Bootstrap is the composition root. It may wire adapters, infra, runtime state, and registration, but reusable policy belongs in app/domain code. |
| `src/manifest/**` | Manifest code is metadata-only: tool definitions, schema vocabulary, groups, risk flags, planning metadata, and invariants. It must not import runtime `App`, handlers, adapters, infra, bootstrap, MCP `ToolResult`, or app use cases. |
| `src/testing/fakes/**` | Fakes are the sanctioned deterministic app-port implementations for use-case tests. They may import app port contracts and domain types, but not MCP, adapters, infra, runtime, retired handlers, or concrete effects. |

Import walls are normalized before checking, including `@import("zigars").<name>`
aliases. Production target-layer code must not import `src/testing/**`.
App-layer tests may use `src/testing/fakes/**`; integration scenarios do not
belong in the fake-port layer.

Effect rules are equally important as import rules. Domain code must be pure.
App use cases may orchestrate command execution, workspace access, artifact
persistence, ZLS/LSP work, backend probing, observability, time, and IDs only
through ports in app context. MCP adapters must call typed app/domain behavior
instead of reaching through `context.workspace_store`, command runners, backend
probes, artifact stores, ZLS gateways, or observability state directly. Infra may
perform concrete effects only as a named port implementation assembled by
bootstrap.

`src/root.zig` is a package-owner aggregator. The source root may contain only
`src/main.zig` and `src/root.zig`, and the public root may expose only these
package-owner aliases: `adapters`, `app`, `bootstrap`, `domain`, `infra`, and
`manifest`. New public imports should go through those owners instead of adding
root-level implementation aliases.

Retired path and surface bans keep migrated behavior from reappearing in old
locations. `architecture_guard` fails closed on retired root files, retired
prefixes such as `src/tools/**`, `src/tool_manifest/**`, `src/mcp_server/**`,
`src/lsp/**`, `src/state/**`, and public compatibility terminology in
production target-layer code. `hex-architecture-inventory` adds a narrow
inventory check for root files, retired `src/tools` imports outside the MCP
adapter transition surface, and adapter imports of retired root handler names.

The architecture guard allowlist is intentionally empty. If a future exception
is unavoidable, it must be exact-path and exact-pattern scoped, name the rule
ID, owner task, reason, retirement condition, and verification command. Broad
directory allowlists and new app/domain exceptions are not acceptable; prefer a
port, typed app boundary, bootstrap wiring, or infra wrapper instead.

Run the architecture gates directly when changing layer boundaries:

```sh
zig build architecture-guard
zig build hex-architecture-inventory
```

Both commands are part of `zig build release-check`.

## Tool Registry Rules

When adding or changing a tool:

1. Add or update one entry in `src/manifest/definitions.zig`. That entry
   names the schema, group, handler reference, planning policy, read-only
   annotation, and risk flags. Add or update group-level discovery keywords in
   `src/manifest/groups.zig` only when the tool introduces a new searchable
   intent.
2. Add application behavior under `src/app/usecases/**` and expose it through
   the appropriate `src/adapters/mcp/tools/*.zig` module.
   Only add a new namespace to `src/adapters/mcp/handlers.zig` when introducing a new
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
`zig_build`, `zig_test`, `zigars_validate_patch`, failure-triage tools, and
`zig_profile_run` can execute code or create normal build/profile artifacts.
Use `riskFor` for finer-grained trust decisions. Apply-gated tools advertise
`writes_require_apply` and `preview_by_default` so clients can distinguish
preview workflows from default mutations.

## MCP Adapter Boundary

The build imports the pinned upstream `mcp` package directly. There is no local
patched MCP dependency in the build graph. The first-party adapter in
`src/adapters/mcp/server.zig` keeps zigars' supported MCP surface explicit:
`initialize`, `ping`, tools, resources, resource subscriptions, prompts,
completion requests, tasks, logging level, stdio transport, and loopback HTTP
transport.

The task methods are backed by retained zigars runtime jobs. `tasks/list`,
`tasks/get`, `tasks/result`, and `tasks/cancel` expose the same bounded
process-local state returned by `zigars_job_start`, `zigars_run_stream`, and the
job result tools. Resource subscriptions are acknowledged at the MCP protocol
boundary and mirrored by inspectable zigars subscription tools; zigars does not
claim a filesystem watcher.

`tools/call`, `resources/read`, and `prompts/get` are the lifetime-sensitive
paths. zigars handlers may return owned `mcp.tools.ToolResult`,
`mcp.resources.ResourceContent`, or prompt message values whose slices and JSON
payloads must remain valid through response serialization. Registered tools,
resources, and prompts carry `ToolResultDeinit`, `ResourceContentDeinit`, or
`PromptMessagesDeinit` callbacks, and the adapter invokes those callbacks only
after the JSON-RPC response has been serialized and sent. This preserves
deterministic cleanup without carrying a patched upstream server.

The release gate scans `build.zig`, `build.zig.zon`, and the adapter contract so
future dependency updates keep using upstream `mcp` APIs directly while
retaining explicit zigars-owned cleanup hooks.

## Heuristic Analysis Rules

Heuristic scanners are useful for fast orientation, but they are not semantic
Zig analysis. Keep source-text heuristics isolated in static-analysis app
use cases, route workspace reads through app ports, include fixture tests, and prefer parser-backed, ZLS, Zig
compiler-backed, or optional zwanzig-backed tools for actions that would modify
source. Static-analysis results should include `analysis_kind`,
`capability_tier`, `confidence`, `confidence_class`, `source_coverage`,
`limitations`, `verify_with`, `recommended_cross_check`, and skipped-file counts
when unreadable files are omitted. The release hygiene check fails when a
static-analysis product tool is missing a tiered contract or when a
source-analysis tool stops being source-read-only.
