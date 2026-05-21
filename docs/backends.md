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

## Version Pinning And Optional CI

Default CI uses fake backend fixtures so zigar can verify command shapes,
structured errors, SARIF/XML/SVG contracts, and artifact metadata without
requiring every optional executable on every runner. Projects that depend on
real ZLS, zwanzig, zflame, diff-folded, or platform-profiler behavior should add
their own backend matrix and pin exact backend versions in the dev shell or CI
image.

Release notes should distinguish fake-backend fixture coverage from real-backend
validation. Claim real backend coverage only when the exact binary and version
were probed or exercised.

There are two supported ways to provide optional backend paths:

- User-provided paths: install backends through your project package manager,
  dev shell, CI image, or local source checkout, then pass absolute paths with
  `--zls-path`, `--zwanzig-path`, `--zflame-path`, and
  `--diff-folded-path`.
- Repo-pinned release validation: maintainers can run the pinned setup script
  in this repository to provision the optional release-validation backends under
  `.zigar-cache/real-backends/bin`. The pins live in
  `tools/real_backend_pins.json` and are intended for citable zigar release
  evidence, not for normal CI.

The repo-pinned setup currently provisions zwanzig `v0.11.0` from release
assets and builds zflame plus diff-folded from zflame `v0.0.2` commit
`4bb890d891390519bf3eec0ce1d08b8175a175ab`. The zflame source build applies
`tools/backend-patches/zflame-pin-zbench-archive.patch`, which replaces a
moving zBench `main` archive URL with the `v0.13.0` tag archive that matches
the upstream-declared Zig package hash. The setup script verifies the zflame
commit and patch checksum before building, and fails if the patch no longer
applies. The Bash setup path currently supports macOS arm64 and Linux x86_64;
the manifest records other upstream assets when they exist.

Run the pinned optional backend setup with Zig `0.16.0` available:

```sh
bash .github/scripts/setup-real-backends.sh
. .zigar-cache/real-backends/env.sh
```

The script writes `env.sh`, `checksums.sha256`, and a copy of
`real_backend_pins.json` under `.zigar-cache/real-backends/`. `env.sh` exports
`ZIGAR_ZWANZIG_PATH`, `ZIGAR_ZFLAME_PATH`, and `ZIGAR_DIFF_FOLDED_PATH` for the
manual release-readiness flow. Zig and ZLS remain explicit toolchain inputs:
set `ZIGAR_ZIG_PATH` and `ZIGAR_ZLS_PATH` to the binaries being validated.
Normal CI must remain optional-backend-free unless a workflow intentionally
opts into this setup.

The preferred public-release path is the manual `Release Readiness` workflow.
It runs the normal release gate, release-asset smoke, real backend conformance,
and real ZLS conformance, then uploads a single evidence package. Its generated
backend compatibility matrix is the authority for optional-backend claims in
release notes. If a backend is not present in that matrix as passed, say
`not run` or `not claimed` instead of implying support from fake fixtures.

For release-candidate validation against actual optional backends, run the
manual `Backend Conformance` GitHub Actions workflow or execute the same script
locally:

```sh
bash .github/scripts/backend-conformance.sh
```

The script builds `zig-out/bin/zigar` when needed, starts zigar over stdio with
real ZLS, zwanzig, zflame, and diff-folded paths, runs `zigar_doctor` with
backend probes, exercises `zig_document_symbols`, `zig_lint_rules`,
`zig_flamegraph`, and `zig_flamegraph_diff`, and verifies the generated SVG
artifacts. Configure non-default paths with `ZIGAR_ZLS_PATH`,
`ZIGAR_ZWANZIG_PATH`, `ZIGAR_ZFLAME_PATH`, and `ZIGAR_DIFF_FOLDED_PATH`.
It writes release-citable evidence to `.zigar-cache/backend-conformance/` by
default: `report.json`, `summary.md`, `stdout.jsonl`, and `stderr.log`. The
manual workflow uploads the same files as the `zigar-backend-conformance`
artifact. Set `ZIGAR_CONFORMANCE_REPORT_DIR` to choose a different output
directory.

Run the manual `ZLS Conformance` workflow when only the ZLS-backed tool surface
needs a fresh release artifact. It starts zigar with a real ZLS binary and
exercises document open, document symbols, hover, diagnostics, formatting,
rename preview, and workspace symbols against a disposable Zig workspace.

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
zflame recursive /tmp/zigar.folded >/tmp/zigar.svg
diff-folded --output=/tmp/zigar-diff.folded /tmp/zigar.folded /tmp/zigar.folded
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
ZLS-backed tools return structured backend/session errors with the configured
path, current session status, restart attempts, last failure when available, and
a resolution. Tools with static or command-backed fallbacks, including
`zig_document_symbols`, diagnostics summaries, and workspace symbols, return
degraded advisory output when the ZLS session is unavailable.

`zls_unsupported_capability` is reserved for an initialized ZLS session whose
advertised capabilities omit the requested LSP method. Treat it as a ZLS
version/configuration mismatch rather than a missing executable.

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

For zigar release validation, prefer the repo-pinned setup script above. It
uses the zwanzig `v0.11.0` release asset and verifies the archive checksum from
`tools/real_backend_pins.json`.

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

The current graph mapping is:

- `cfg`: `--dump-cfg <output-dir> <source>`
- `exploded_graph`: `--dump-exploded-graph <output-dir> <source>`
- `annotated_cfg`: `--dump-annotated-cfg <output-dir> <source>`
- `path_trace`: `--dump-path-trace <output-dir> <source>`

## zflame And diff-folded

zflame powers `zig_flamegraph`. diff-folded powers the first stage of
`zig_flamegraph_diff`. zigar treats capture and rendering separately:

1. Build the target with symbols, usually `zig build -Doptimize=ReleaseFast`.
2. Call `zig_profile_plan` for structured capture guidance. It lists external
   plans for Linux `perf`, macOS `sample`, macOS `xctrace`, DTrace, VTune, and
   already-folded recursive inputs. The plan names the external command,
   expected capture path, matching zflame format, prerequisites, limitations,
   and the next zigar rendering call.
3. Capture with the selected external profiler. zigar does not execute or define
   profiler capture semantics; permissions, sampling mode, symbols, and capture
   fidelity belong to that profiler.
4. Optionally use `zig_profile_run` for an explicit command you provide. zigar
   splits the command into argv without a shell and runs it with the workspace as
   cwd; that command can execute project code and create normal build/profile
   artifacts.
5. Render the captured data with `zig_flamegraph`.
6. For before/after comparisons, pass two folded stack files to
   `zig_flamegraph_diff`; it writes an intermediate folded diff under
   `.zigar-cache/profile/` by default, or an explicit workspace-local
   `intermediate` path, and then renders the SVG through zflame.

The zflame command shape zigar expects is explicit and does not use format
guessing:

```sh
zflame <format> [--title=<title>] [--subtitle=<text>] [--colors=<palette>] [--width=<pixels>] [--min-width=<pixels>] [--hash] <input> > flame.svg
```

Supported zflame formats are `perf`, `dtrace`, `sample`, `vtune`, `xctrace`,
and `recursive`. zigar captures zflame stdout, verifies it looks like SVG, and
writes the final artifact through its workspace file helper instead of asking
zflame to write the SVG directly.

The diff-folded command shape zigar expects writes an intermediate folded diff
file explicitly:

```sh
diff-folded --output=delta.folded before.folded after.folded
```

For zigar release validation, prefer the repo-pinned setup script. It builds
both binaries from the pinned zflame source commit after applying the guarded
zBench archive patch documented in `tools/real_backend_pins.json`.

`zig_flamegraph` and `zig_flamegraph_diff` return auditable artifact metadata:
input/output paths, explicit input format, backend executable path, argv shape
and argv, output byte count, output SHA-256, cached probe status when available,
unknown version when no stable version probe is available, compatibility status,
and warnings. Diff results also include intermediate folded metadata and an
intermediate folded SHA-256 for the diff-folded stage. All
zigar-generated SVG, DOT, and folded-diff outputs must use workspace-local
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
