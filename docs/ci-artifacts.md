# CI Artifacts

zigar's CI artifact tools are command-backed helpers with explicit contracts.
They preserve raw command output and disclose their parsing basis instead of
claiming precision the Zig CLI does not expose.

Release fixtures cover parser contracts, XML escaping, matrix-entry status
fields, raw output retention, and failure summaries. CI deployments should still
compare zigar output against the target runner's native upload behavior because
annotation rendering, test-report retention, and SARIF/JUnit ingestion rules are
owned by the CI platform.

## Annotations

`zig_ci_annotations` runs `zig ast-check <file>` and returns
`artifact_kind: "ci_annotations"`. Each result includes `parsing_basis`,
`parser_confidence`, `limitations`, `raw_output_available`, `annotation_count`,
`parse_summary`, `annotations`, and `raw`.

Annotations are parsed from common Zig compiler diagnostic lines shaped as
`path:line:column: severity: message`. Following source and caret lines are
attached as `details`. Unlocated `error:`, `warning:`, and `note:` lines are
kept with low confidence, `located: false`, and the requested file as the
fallback path. Located annotations include an explicit start/end column range so
CI renderers can translate them without guessing. The raw stderr in `raw`
remains the audit source for CI renderers.

Example GitHub Actions usage:

```sh
zigar --transport stdio
# Call zig_ci_annotations with {"file":"src/main.zig"} from the MCP client,
# then translate annotations[] to the runner's native annotation syntax.
```

Adapter shape for GitHub Actions:

```sh
# For each located annotation from zig_ci_annotations:
printf '::%s file=%s,line=%s,col=%s,endColumn=%s::%s\n' \
  "$severity" "$path" "$line" "$column" "$end_column" "$message"
```

Keep the adapter in client or CI script code so zigar remains platform-neutral
and the raw `zig_ci_annotations.raw` output stays available for audit.

## JUnit

`zig_junit` returns `artifact_kind: "command_level_junit"` and
`junit_kind: "command_level"`. It runs either `zig build test` or
`zig test <file>` and emits one JUnit testcase for the command. The XML includes
properties for `zigar.artifact_kind`, `zigar.junit_kind`,
`zigar.raw_output_available`, `zigar.command`, `zigar.parsing_basis`, and
`zigar.limitations`.

This is intentionally not per-test JUnit. Zig output does not provide a stable
per-test event stream for every invocation, so zigar reports command success or
failure and preserves stdout/stderr in `<system-out>` and `<system-err>`.

Generic CI example:

```sh
# Call zig_junit with {"args":"--summary all"} and write junit_xml to the
# CI system's test-report upload path.
```

When CI requires per-test reporting, keep that outside `zig_junit` until Zig
exposes a stable per-test event stream. zigar's contract is command-level JUnit
with preserved stdout/stderr.

## Matrix Checks

`zig_matrix_check` runs `zig build test` once for each provided Zig executable
path. The top-level result includes `ok`, `entry_count`, `passed`, `failed`,
`parsing_basis`, `limitations`, `raw_output_available`, and `results`.

Each matrix entry exposes direct fields so CI consumers do not need to walk a
nested command object first: `ok`, `zig`, `command`, `argv`,
`failure_summary`, and `result`. Missing executables are represented as failed
entries with `error`, `error_kind`, and a structured failure summary.

Example:

```json
{
  "zig_paths": "zig /opt/zig-nightly/zig",
  "args": "--summary all",
  "timeout_ms": 120000
}
```
