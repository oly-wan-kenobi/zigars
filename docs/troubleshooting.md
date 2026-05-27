# Troubleshooting

## Formatter Tool Not Found

Call `zigars_capabilities`, `zigars_tool_index`, or `zigars_schema`, then search for
`fmt`, `formatter`, `formatting`, or `zig fmt`. The formatter tools are
`zig_format` and `zig_format_check`.

## PermissionDenied Or Workspace Errors

Call `zigars_workspace_info` and confirm that `workspace` is the Zig project you
are editing. Prefer workspace-relative paths in tool arguments.

zigars realpaths existing files, existing output paths, and the nearest existing
output parent before accepting a path. Symlinks are allowed only when the real
target stays inside the workspace. Paths such as `linked-dir/new/file.zig` are
rejected when `linked-dir` is a symlink outside the workspace.

## ZLS Tools Are Unavailable

Run `zigars_doctor` and `zig_version`. Confirm `zls_path` points to a ZLS build
compatible with the configured Zig version. `zigars_doctor` also reports the
configured ZLint, zwanzig, zflame, and diff-folded backend paths for support
logs.
Command-backed tools such as `zig_check`, `zig_build`, and `zig_test` continue
to work without ZLS.

ZLS-only tools report a structured `backend_error` with `configured_path`,
`status`, `restart_attempts`, `last_failure` when available, and `resolution`.
Fallback-capable tools such as `zig_document_symbols`, diagnostics summaries,
and workspace symbols return degraded advisory output instead of failing when
the ZLS session is unavailable. `zls_unsupported_capability` means ZLS
initialized but did not advertise the requested LSP capability; upgrade or
reconfigure ZLS for that method.

For project-level version mismatches, call `zig_toolchain_resolve`. It inspects
`.zigversion`, `.tool-versions`, `mise.toml`, `build.zig.zon`, active Zig/ZLS
versions, and common managers such as mise, asdf, zvm, and zigup.

Use `zig_zls_match_check` when you need a focused compatibility result for the
configured Zig and ZLS paths. Use `zig_toolchain_pin` to preview or write
`.zigars/toolchain.json`, then `zig_toolchain_pin_check` to compare that pin with
the current environment. If ZVM is the project-approved manager,
`zigars_zvm_install_plan` and `zigars_zvm_switch_plan` return explicit commands;
they do not install or switch versions on their own.

For executable checks, call:

```json
{"probe_backends": true, "timeout_ms": 1000}
```

as arguments to `zigars_doctor`. Probe failures include a stable `backend`,
`status`, and `resolution` field for support logs.

Probe results are cached for the current zigars process. Query
`zigars_workspace_info` or `zigars_metrics` to inspect cached backend status
without executing probes again.

If ZLS requests time out, raise the dedicated timeout:

```sh
zigars --zls-timeout-ms 60000
```

Unsaved documents opened through `zig_document_open` or `zig_document_change` are
retained in process memory and replayed if zigars restarts its ZLS session. Close
documents with `zig_document_close` when a client no longer needs unsaved state.
Use `zig_document_status` for a specific file, or `zigars_metrics` for aggregate
open document count, dirty document count, retained bytes, limits, and last ZLS
replay summary.

## Command Output Is Too Large

Command-backed tools classify timeout, output-limit, executable, and permission
failures in structured results. zigars uses a `truncate_on_limit` policy: if
stdout or stderr exceeds the configured capture limit, it returns the captured
prefix and marks the affected stream with `stdout_truncated` or
`stderr_truncated`. If output limits are reached, run the underlying command
directly for complete logs or narrow the check with file-focused tools such as
`zig_check`.

## HTTP Host Is Rejected

zigars' HTTP transport is local-only by default. Use stdio for normal agent
clients, or bind HTTP to `127.0.0.1`, `localhost`, or `::1` when a local wrapper
needs an HTTP endpoint. Non-loopback hosts such as `0.0.0.0` are rejected because
zigars does not currently provide an authenticated remote HTTP mode.

## Quoted `args` Values

Tools with an `args` string support shell-like single quotes, double quotes, and
backslash escaping. Unfinished quotes or trailing escapes are rejected as invalid
arguments instead of being split ambiguously.

## Invalid Tool Arguments

zigars validates MCP tool arguments before running handlers. Invalid calls return
an `argument_error` structured result with:

- `code`: `missing_required_argument`, `invalid_type`, `unknown_argument`, or
  `invalid_arguments`
- `field`: the relevant argument name, or `null` for a non-object payload
- `expected` and `actual`: compact JSON type names

Inspect the `tools/list` `inputSchema` for required fields, enums, defaults, and
path hints. Call `zigars_schema` when you need the compact catalog view with
grouping, risk, planning, backend setup, or discovery keywords before retrying.

## Stale Package Or Cache State

Call `zig_package_cache_doctor` when fetch/build errors mention package hashes,
local cache paths, or generated artifact directories. It reports `.zig-cache`,
`zig-out`, `.zigars-cache`, `zig-pkg`, dependency hash risks, and whether cache
directories are unexpectedly tracked by git.
