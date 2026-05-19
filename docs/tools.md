# Zigar Tools

`zigar_capabilities`, `zigar_tool_index`, and `zigar_schema` expose the same
catalog. Tool grouping, discovery keywords, argument schemas, risk metadata,
planning metadata, and handler references are generated from
the typed manifest under `src/tool_manifest/`; the public MCP tool/resource
response adds static safety notes and common intents from
`src/tool_catalog.json`.

Standard MCP discovery is the first-class path: `tools/list` publishes each
registered `inputSchema` with `properties`, `required` fields, defaults, enums,
and zigar path hints. `zigar_schema` and the `zigar://tools/schema` resource
remain compact catalog views for grouping, risk, planning, and discovery
keywords.

[tool-index.generated.md](tool-index.generated.md) is generated from
the typed manifest and static catalog notes. CI runs `zig build docs-check` so
the committed tool index cannot drift from registered groups, keywords, or
schemas.

Tool calls are validated before handler execution. Invalid arguments return a
structured `argument_error` result with a stable `code`, `field`, `expected`,
`actual`, and `resolution`.

Argument hints are scoped to the owning tool schema. Shared path/apply/timeout
semantics are reused where they mean the same thing, but enum and default
contracts live on the specific schema that owns the field. For example,
`zigar_context_pack.mode` and `zigar_validate_patch.mode` can advertise
different valid values without a global `mode` default leaking between tools.

Handlers preserve that contract after validation too. Expected user-facing
failures such as missing workspace files, unsupported planning targets, malformed
extra arguments, unavailable optional backends, failed writes, and analysis-cache
decode failures are returned as MCP error results with structured payloads. The
payload names the tool, operation, phase, machine-readable code, category,
underlying error when available, and a resolution. Bare `InvalidArguments`,
`ExecutionFailed`, and `ResourceNotFound` are treated as release-check failures in
the public tool-handler modules.

Registry-derived argument hints also include a `risk` object. The MCP
`readOnlyHint` remains useful for client UI, but zigar's risk fields are more
specific: source writes, artifact writes, apply-gated writes, preview-by-default
behavior, LSP-state mutation, backend execution, project-code execution, and
arbitrary user-command execution are tracked independently.

Planning support is also registry-derived. Use `zig_tool_plan` for the broad
answer for any registered tool: exact command, runtime-dependent backend, ZLS
request, apply-gated mutation, workspace artifact, pure analysis, or explicitly
unsupported. `zig_command_plan` is intentionally narrower: it returns exact
`argv`/`cwd`/`timeout_ms` only for command-backed tools and returns a structured
unsupported response for other known tools instead of `InvalidArguments`.

`zigar_doctor` accepts optional `probe_backends` and `timeout_ms` arguments. Use
backend probes when a client reports `PermissionDenied`, missing formatter/ZLS
tools, or unclear executable-path failures. Probe results are cached for the
server process and surfaced through `zigar_workspace_info` and `zigar_metrics`.

Docs tools are intentionally split by source, and each source reports
provenance/completeness. `zig_builtin_*` uses curated zigar data and is marked
`partial_curated`. `zig_std_search` scans local Zig standard-library `.zig`
source files and is marked `source_scan`. `zig_lang_ref_search` searches
language-reference sections, reports whether it used `installed_langref_html` or
`bundled_langref_index`, marks bundled fallback data as `partial_curated`, and
does not scan Zig autodoc implementation files.

High-signal discovery keywords include:

- `agent`, `agent client`, `mcp client`, `codex`, `claude`, `gemini`,
  `hermes`, `context pack`, `next action`, `validate patch`,
  `failure fusion`, `impact analysis`
- `fmt`, `formatter`, `formatting`, `zig fmt`
- `toolchain`, `version manager`, `mise`, `asdf`, `zvm`, `zigup`
- `doctor`, `health`, `workspace`, `PermissionDenied`
- `compile error index`, `changed files`, `dependency inspector`
- `build options`, `target matrix`, `test failure triage`, `symbol cache`
- `zls`, `lsp`, `diagnostics`, `hover`, `definition`, `references`
- `zwanzig`, `lint`, `sarif`
- `zflame`, `profile`, `flamegraph`

Source-mutating tools are preview-first and require `apply=true` to write:

- `zig_format`
- `zig_patch_preview`
- `zig_rename`
- `zig_code_action_apply`
- `zigar_project_profile`

Generated output tools such as `zig_flamegraph` and `zig_analysis_graphs` must
write to explicit workspace-local output paths. `zig_flamegraph_diff` also writes
its intermediate folded stacks under `.zigar-cache/profile/diff-<n>.folded` to
avoid clobbering another in-process diff run.
