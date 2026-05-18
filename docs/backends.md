# Optional Backends

## ZLS

ZLS powers diagnostics, hover, definition, references, completion, signature
help, document/workspace symbols, rename, code actions, and in-memory document
sync. Configure it with `--zls-path` and tune request waits with
`--zls-timeout-ms`.

Long-running sessions retain bounded ZLS state in process memory. In-memory
document sync keeps at most 10 MiB per document, 64 MiB of aggregate retained
document text, and 256 open documents by default. Cached publish-diagnostics
notifications are capped at 16 MiB total; oversized diagnostics are dropped and
the cache is cleared before storing the next notification that would exceed the
aggregate budget. `zig_document_status` and the ZLS status resource expose the
current retained byte counts and limits.

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
