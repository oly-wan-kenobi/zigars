# Optional Backends

zigar starts and serves core Zig tools with only a `zig` executable. ZLS,
zwanzig, zflame, and diff-folded are optional local executables. Tools that need
one of them return structured `backend_error` or `tool_error` payloads when the
configured binary is missing, not a generic MCP failure.

## Compatibility Rules

- Use a Zig toolchain that matches this repository's supported Zig version. The
  build and CI gates currently use Zig `0.16.0`.
- Keep ZLS on the same Zig release line as `zig`. A mismatched ZLS can start but
  fail later on syntax, builtin, or standard-library changes.
- Treat zwanzig, zflame, diff-folded, and platform profilers as workspace-local
  tooling dependencies. Pin them in the project's package manager, dev shell, or
  CI image when reproducibility matters.
- Put backends on `PATH` or pass absolute paths with zigar's `--*-path` options.

## Packaged Setup Catalog

zigar ships a structured backend setup catalog in the server binary. Call
`zigar_backend_catalog` from an MCP client before configuring optional tools. It
returns every backend's path flag, default command, current configured path,
probe argv, compatibility rule, related zigar tools, and install strategy.

The same catalog is embedded in `zigar_schema` under `backend_setup`, so release
archives include a machine-readable setup contract instead of only prose setup
notes. Use it to generate project docs, dev-shell checks, or CI bootstrap output
without scraping this document.

## Configuration

All backend path flags are optional:

```sh
zigar \
  --workspace /path/to/project \
  --zig-path "$(command -v zig)" \
  --zls-path "$(command -v zls)" \
  --zwanzig-path "$(command -v zwanzig)" \
  --zflame-path "$(command -v zflame)" \
  --diff-folded-path "$(command -v diff-folded)"
```

Use a wrapper script when a backend needs environment variables, a version
manager shim, or a project-local build artifact:

```sh
#!/bin/sh
exec /path/to/project/.tools/zwanzig "$@"
```

Then pass that wrapper with `--zwanzig-path`.

## Verification

Run cheap local probes before relying on optional tools:

```json
{"probe_backends": true, "timeout_ms": 1000}
```

Send that to `zigar_doctor`. Probe results are cached for the current server
process and surfaced through `zigar_workspace_info` and `zigar_metrics`. If a
probe fails, call `zigar_backend_catalog` and compare the configured path and
probe argv with the command you run by hand.

Direct shell checks are also useful:

```sh
zig version
zls --version
zwanzig --help
printf 'main 1\n' > /tmp/zigar.folded
zflame guess /tmp/zigar.folded >/tmp/zigar.svg
diff-folded /tmp/zigar.folded /tmp/zigar.folded >/tmp/zigar-diff.folded
```

If a direct shell check fails, fix the backend before debugging zigar. If the
shell check passes but zigar reports an error, compare the path in
`zigar_workspace_info` with the binary you invoked by hand.

## ZLS

[ZLS](https://github.com/zigtools/zls) powers diagnostics, hover, definition,
references, completion, signature help, document/workspace symbols, rename, code
actions, and in-memory document sync. Configure it with `--zls-path` and tune
request waits with `--zls-timeout-ms`.

Common setup paths:

- Homebrew: `brew install zls` installs a `zls` binary and tracks the Zig
  dependency for the formula.
- mise: install Zig and ZLS separately, for example `mise use -g zig@0.16.0`
  and `mise use -g zls@0.16.0` when both are available in the mise registry.
- Source or release archive: follow the ZLS repository's release/build
  instructions, then point zigar at the resulting `zls` executable.

Recommended checks:

```sh
zig version
zls --version
zig env
```

Long-running sessions retain bounded ZLS state in process memory. In-memory
document sync keeps at most 10 MiB per document, 64 MiB of aggregate retained
document text, and 256 open documents by default. Cached publish-diagnostics
notifications are capped at 16 MiB total. Oversized diagnostics are dropped for
their URI, and aggregate overflow evicts the oldest cached diagnostics until the
new notification fits. `zig_document_status` exposes per-file document state.
The ZLS status resource and `zigar_metrics` expose aggregate document-sync
state, including open and dirty document counts, retained byte counts, replay
summary, limits, eviction count, and oversized-drop count.

When ZLS is unavailable, command-backed tools such as `zig_build`, `zig_test`,
`zig_check`, `zig_format`, docs search, and static-analysis summaries still work.
ZLS-backed tools return structured backend/session errors with a resolution.

## zwanzig

[zwanzig](https://github.com/forketyfork/zwanzig) powers `zig_lint`,
`zig_lint_sarif`, `zig_lint_rules`, and `zig_analysis_graphs`. Inputs and graph
outputs are resolved under the workspace.

Source setup:

```sh
git clone https://github.com/forketyfork/zwanzig
cd zwanzig
zig build
./zig-out/bin/zwanzig --help
```

Project-local configuration:

```sh
zigar --workspace /path/to/project --zwanzig-path /path/to/zwanzig/zig-out/bin/zwanzig
```

Use `zig_lint_rules` after configuring the path. It runs the backend help output
through zigar and is the fastest end-to-end check. For SARIF, call
`zig_lint_sarif` and upload the returned SARIF in CI if your platform supports
SARIF ingestion.

`zig_analysis_graphs` is mode-based. Use one of `cfg`, `exploded_graph`,
`annotated_cfg`, or `path_trace`; zigar maps that to zwanzig's corresponding
`--dump-*` flag, creates the requested workspace-local output directory, and
verifies that the backend wrote DOT files there. Raw graph flags are not part of
the public zigar schema.

## zflame And diff-folded

zflame powers `zig_flamegraph`. diff-folded powers the first stage of
`zig_flamegraph_diff`. zigar treats capture and rendering separately:

1. Build the target with symbols, usually `zig build -Doptimize=ReleaseFast`.
2. Capture with a platform profiler such as `perf`, `xctrace`, DTrace, VTune, or
   a sampling tool that can produce folded stacks or another zflame-supported
   input format.
3. Render the captured data with `zig_flamegraph`.
4. For before/after comparisons, pass two folded stack files to
   `zig_flamegraph_diff`; it writes an intermediate folded diff under
   `.zigar-cache/profile/` and then renders the SVG through zflame.

The zflame command shape zigar expects is:

```sh
zflame <format> [--title <title>] [--palette <palette>] [--min-width <n>] [--hash] <input> > flame.svg
```

The diff-folded command shape zigar expects is:

```sh
diff-folded before.folded after.folded > delta.folded
```

All zigar-generated SVG and DOT outputs must use explicit workspace-local output
paths. This keeps profiler artifacts inspectable and prevents accidental writes
outside the active workspace.

## Failure Triage

- `PermissionDenied`: run the backend directly, then verify executable bits and
  wrapper shebangs.
- `FileNotFound`: compare `zigar_workspace_info` backend paths with
  `command -v <tool>`.
- `RequestTimeout`: raise `--zls-timeout-ms` for ZLS operations or per-call
  `timeout_ms` for command-backed tools.
- Backend starts by hand but fails through zigar: check whether your interactive
  shell sets PATH or version-manager environment that the MCP client process does
  not inherit. Use absolute backend paths or wrapper scripts.
- Backend output is empty or malformed: run `zigar_doctor` with
  `probe_backends=true`, then run the backend command by hand with the same input
  file and compare stdout/stderr.
