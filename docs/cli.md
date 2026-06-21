# Thin CLI Mode

`zigars cli` is a narrow reporting surface under the same `zigars` binary. The
default `zigars` mode is still the MCP server, and MCP remains the primary agent
surface.

The CLI is for CI, release bots, and shell-only workflows that need stable JSON
without speaking MCP. It does not expose a public Zig library API, does not
promote `tools/zigars_tools.zig`, and does not include source-mutating commands,
installers, or MCP client config writers.

## Commands

```sh
zigars cli workspace-info --workspace /absolute/path/to/zig/project --json
zigars cli doctor --workspace /absolute/path/to/zig/project --probe-backends=false --json
```

`--workspace` uses the same workspace canonicalization and cache-root policy as
the MCP server. If it is omitted, the current directory is used.

Successful command output is minified JSON on stdout. Diagnostics, help, and
errors go to stderr. The JSON object is the same shape as the corresponding MCP
tool `structuredContent` for `zigars_workspace_info` and `zigars_doctor`.

`doctor --probe-backends=false` reports configuration and known setup state
without running optional backend probes. `--probe-backends=true` runs the same
bounded backend probes used by `zigars_doctor`. Doctor findings can report
`ok=false` inside JSON while the process still exits successfully when the
command itself ran.

## Exit Codes

| Code | Meaning |
|---:|---|
| 0 | Success. |
| 2 | Invalid CLI arguments. |
| 3 | Workspace or path resolution error. |
| 70 | Fatal internal error. |

## Follow-Up Commands

These are planned CLI candidates, not implemented in the initial CLI surface.
Each must reuse an existing use case and keep stdout as JSON.

| Command | Existing use case | Proposed JSON contract | Exit behavior |
|---|---|---|---|
| `ci-ingest` | `zig_ci_ingest` | CI parser result with format, failures, evidence basis, and limitations. | Exit 0 for parsed reports, even when failures are present; exit 2/3/70 for CLI, path, or internal errors. |
| `junit` | `zig_junit` | Command-level JUnit result with `junit_xml`, command metadata, and stdout/stderr evidence. | Exit 0 when the report was produced; test failures stay in JSON. |
| `coverage-budget` | `zig_coverage` (mode=budget) | Coverage budget result with line-rate fields, thresholds, and pass/fail booleans. | Exit 0 when evaluated; budget misses stay in JSON unless a later contract opts into gate-style exits. |
| `docs-drift` | `zigars_docs_drift_check` | Docs drift report with checked surfaces and drift findings. | Exit 0 when the report was produced; drift findings stay in JSON. |
| `release-evidence-pack` | `zig_release_evidence_pack` | Release evidence bundle summary from supplied report fragments. | Exit 0 when packaged; missing/invalid inputs use argument or workspace errors. |
| `artifact-index` | `zigars_artifact_index` | Artifact registry index with paths, kinds, provenance, and optional hashes. | Exit 0 for successful listing; missing registry paths use workspace/path errors. |
