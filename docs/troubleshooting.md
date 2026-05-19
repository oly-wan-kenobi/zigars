# Troubleshooting

## Formatter Tool Not Found

Call `zigar_capabilities`, `zigar_tool_index`, or `zigar_schema`, then search for
`fmt`, `formatter`, `formatting`, or `zig fmt`. The formatter tools are
`zig_format` and `zig_format_check`.

## PermissionDenied Or Workspace Errors

Call `zigar_workspace_info` and confirm that `workspace` is the Zig project you
are editing. Prefer workspace-relative paths in tool arguments.

For stronger symlink protection, start zigar with:

```sh
zigar --workspace /path/to/project --strict-workspace
```

Strict mode realpaths existing files and the nearest existing output parent
before accepting them. This catches output paths such as
`linked-dir/new/file.zig` when `linked-dir` is a symlink outside the workspace.

## ZLS Tools Are Unavailable

Run `zigar_doctor` and `zig_version`. Confirm `zls_path` points to a ZLS build
compatible with the configured Zig version. `zigar_doctor` also reports the
configured zwanzig, zflame, and diff-folded backend paths for support logs.
Command-backed tools such as `zig_check`, `zig_build`, and `zig_test` continue
to work without ZLS.

For project-level version mismatches, call `zig_toolchain_resolve`. It inspects
`.zigversion`, `.tool-versions`, `mise.toml`, `build.zig.zon`, active Zig/ZLS
versions, and common managers such as mise, asdf, zvm, and zigup.

For executable checks, call:

```json
{"probe_backends": true, "timeout_ms": 1000}
```

as arguments to `zigar_doctor`. Probe failures include a stable `backend`,
`status`, and `resolution` field for support logs.

Probe results are cached for the current zigar process. Query
`zigar_workspace_info` or `zigar_metrics` to inspect cached backend status
without executing probes again.

If ZLS requests time out, raise the dedicated timeout:

```sh
zigar --zls-timeout-ms 60000
```

Unsaved documents opened through `zig_document_open` or `zig_document_change` are
retained in process memory and replayed if zigar restarts its ZLS session. Close
documents with `zig_document_close` when a client no longer needs unsaved state.

## Command Output Is Too Large

Command-backed tools classify timeout, output-limit, executable, and permission
failures in structured results. zigar uses a `fail_on_limit` policy: if stdout
or stderr exceeds the configured capture limit, it fails the command instead of
returning partial output. If output limits are reached, run the underlying
command directly or narrow the check with file-focused tools such as `zig_check`.

## Quoted `args` Values

Tools with an `args` string support shell-like single quotes, double quotes, and
backslash escaping. Unfinished quotes or trailing escapes are rejected as invalid
arguments instead of being split ambiguously.

## Invalid Tool Arguments

zigar validates MCP tool arguments before running handlers. Invalid calls return
an `argument_error` structured result with:

- `code`: `missing_required_argument`, `invalid_type`, `unknown_argument`, or
  `invalid_arguments`
- `field`: the relevant argument name, or `null` for a non-object payload
- `expected` and `actual`: compact JSON type names

Inspect the `tools/list` `inputSchema` for required fields, enums, defaults, and
path hints. Call `zigar_schema` when you need the compact catalog view with
grouping, risk, planning, backend setup, or discovery keywords before retrying.

## Stale Package Or Cache State

Call `zig_package_cache_doctor` when fetch/build errors mention package hashes,
local cache paths, or generated artifact directories. It reports `.zig-cache`,
`zig-out`, `.zigar-cache`, `zig-pkg`, dependency hash risks, and whether cache
directories are unexpectedly tracked by git.
