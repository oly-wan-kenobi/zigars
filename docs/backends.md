# Optional Backends

## ZLS

ZLS powers diagnostics, hover, definition, references, completion, signature
help, document/workspace symbols, rename, code actions, and in-memory document
sync. Configure it with `--zls-path` and tune request waits with
`--zls-timeout-ms`.

## zwanzig

zwanzig powers `zig_lint`, `zig_lint_sarif`, `zig_lint_rules`, and
`zig_analysis_graphs`. Inputs and graph outputs are resolved under the
workspace.

## zflame

zflame powers `zig_flamegraph` and `zig_flamegraph_diff`. zigar treats capture
and rendering separately: capture with a platform profiler, then render profiler
output to SVG through zflame.

Use `zigar_doctor` with `probe_backends=true` to confirm executable paths and
basic startup behavior before relying on optional backend tools. Probe results
are cached for the current server process and exposed through
`zigar_workspace_info` and `zigar_metrics`.
