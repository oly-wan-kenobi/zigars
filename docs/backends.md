# Optional Backends

zigar starts and serves core Zig tools with only a `zig` executable. ZLS,
ZLint, zwanzig, zflame, and diff-folded are optional local executables with
server configuration paths. Samply, Tracy, LLDB, heaptrack, Valgrind, AFL++,
LLVM binary tools, QEMU, and flash tools are optional executables configured per
tool call. Tools that need one of them return structured `backend_error` or
`tool_error` payloads when the binary is missing or the platform is unsupported,
not a generic MCP failure.

## Compatibility Rules

- Use a Zig toolchain that matches this repository's supported Zig version. The
  build and CI gates currently use Zig `0.16.0`.
- Keep ZLS on the same Zig release line as `zig`. A mismatched ZLS can start but
  fail later on syntax, builtin, or standard-library changes.
- Treat ZLint, zwanzig, zflame, diff-folded, Samply, Tracy, LLDB, heaptrack,
  Valgrind, AFL++, LLVM binary tools, QEMU, flash tools, and platform profilers
  as workspace-local tooling dependencies. Pin them in the project's package
  manager, dev shell, or CI image when reproducibility matters.
- Put backends on `PATH` or pass absolute paths with zigar's `--*-path` options.
  For Samply and Tracy capture calls, pass `samply_path` or
  `tracy_capture_path` in the tool arguments when the executable is not on
  `PATH`. Runtime diagnostic calls use per-call paths such as `lldb_path`,
  `heaptrack_path`, `valgrind_path`, `afl_path`, `objdump_path`,
  `dwarfdump_path`, `symbolizer_path`, `qemu_path`, and `flash_tool`.

## Version Pinning And Optional CI

Default CI uses fake backend fixtures so zigar can verify command shapes,
structured errors, SARIF/XML/SVG contracts, and artifact metadata without
requiring every optional executable on every runner. Projects that depend on
real ZLS, ZLint, zwanzig, zflame, diff-folded, Samply, Tracy, debugger,
memory-analysis, fuzzing, binary-tool, emulator, flash, or platform-profiler
behavior should add their own backend matrix and pin exact backend versions in
the dev shell or CI image.

Release notes should distinguish fake-backend fixture coverage from real-backend
validation. Claim real backend coverage only when the exact binary and version
were probed or exercised.

There are two supported ways to provide optional backend paths:

- User-provided paths: install backends through your project package manager,
  dev shell, CI image, or local source checkout, then pass absolute paths with
  `--zls-path`, `--zlint-path`, `--zwanzig-path`, `--zflame-path`, and
  `--diff-folded-path`.
- Repo-pinned release validation: maintainers can run the pinned setup script
  in this repository to provision the optional release-validation backends under
  `.zigar-cache/real-backends/bin`. The pins live in
  `tools/release/real_backend_pins.json` and are intended for citable zigar release
  evidence, not for normal CI.

The repo-pinned setup currently provisions zwanzig `v0.11.0` from release
assets and builds zflame plus diff-folded from zflame `v0.0.2` commit
`4bb890d891390519bf3eec0ce1d08b8175a175ab`. The zflame source build applies
`tools/release/backend-patches/zflame-pin-zbench-archive.patch`, which replaces a
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
manual release-readiness flow. Zig, ZLS, and ZLint remain explicit toolchain
inputs: set `ZIGAR_ZIG_PATH`, `ZIGAR_ZLS_PATH`, and `ZIGAR_ZLINT_PATH` to the
binaries being validated when the release intends to claim them. Normal CI must
remain optional-backend-free unless a workflow intentionally opts into this
setup.

Samply, Tracy, LLDB, heaptrack, Valgrind, AFL++, LLVM binary tools, QEMU, and
flash tools are not provisioned by the repo-pinned backend setup. Keep those
binaries in your project environment and pass the per-call path argument when
the default command name is not appropriate.

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
real ZLS, ZLint, zwanzig, zflame, and diff-folded paths, runs `zigar_doctor`
with backend probes, exercises `zig_document_symbols`, `zig_zlint_rules`,
`zig_zlint_fix` preview, `zig_lint_rules`, `zig_flamegraph`, and
`zig_flamegraph_diff`, and verifies the generated SVG artifacts. Configure
non-default paths with `ZIGAR_ZLS_PATH`,
`ZIGAR_ZLINT_PATH`, `ZIGAR_ZWANZIG_PATH`, `ZIGAR_ZFLAME_PATH`, and
`ZIGAR_DIFF_FOLDED_PATH`. It writes release-citable evidence to
`.zigar-cache/backend-conformance/` by default: `report.json`, `summary.md`,
`stdout.jsonl`, and `stderr.log`. The manual workflow uploads the same files as
the `zigar-backend-conformance` artifact. Set `ZIGAR_CONFORMANCE_REPORT_DIR` to
choose a different output directory.

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

`zigar_backend_install_plan` is the setup-oriented companion to the catalog. It
returns backend-specific commands, compatibility notes, and verify steps for a
selected backend and package manager, but it never installs packages or mutates
the developer environment. `zigar_backend_guidance` reports unresolved backend
policy questions such as which optional tools should be release-claimed and how
they will be pinned. `zigar_backend_elicit` remains available only as a
compatibility alias for older clients.

`zigar_dev_env_generate` can preview or write pinned setup artifacts for mise,
asdf, Nix, devcontainer, and GitHub Actions. Generated files are workspace
artifacts and require `apply=true`; applied artifacts are recorded in the zigar
artifact registry with provenance.

## Configuration

All backend path flags are optional:

```sh
zigar \
  --workspace /path/to/project \
  --zig-path "$(command -v zig)" \
  --zls-path "$(command -v zls)" \
  --zlint-path "$(command -v zlint)" \
  --zwanzig-path "$(command -v zwanzig)" \
  --zflame-path "$(command -v zflame)" \
  --diff-folded-path "$(command -v diff-folded)"
```

Use a wrapper script when a backend needs environment variables, a version
manager wrapper, or a project-local build artifact:

```sh
#!/bin/sh
exec /path/to/repo/.tools/zwanzig "$@"
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
zlint --help
zwanzig --help
printf 'main 1\n' > /tmp/zigar.folded
zflame recursive /tmp/zigar.folded >/tmp/zigar.svg
diff-folded --output=/tmp/zigar-diff.folded /tmp/zigar.folded /tmp/zigar.folded
samply --help
tracy-capture --help
lldb --version
heaptrack --help
valgrind --version
afl-fuzz -h
llvm-objdump --version
llvm-dwarfdump --version
llvm-symbolizer --version
qemu-aarch64 --version
probe-rs --help
```

If a direct shell check fails, fix the backend before debugging zigar. If the
shell check passes but zigar reports an error, compare the path in
`zigar_workspace_info` with the binary you invoked by hand.

For MCP-visible setup evidence, call `zigar_env_pack` with
`probe_backends=true` after configuring paths. Use `zigar_backend_verify` for a
bounded probe of one backend or `all`, and use
`zigar_backend_conformance` to inspect the conformance scenarios and evidence
paths expected by the script-backed release flow. `zigar_backend_evidence_pack`
reads an existing conformance report and can register a compact evidence pack,
but consumers still need to inspect scenario statuses before claiming backend
support.

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

## ZLint

ZLint-compatible executables power `zig_zlint`, `zig_zlint_sarif`,
`zig_zlint_rules`, `zig_zlint_fix`, and the ZLint-confirmed evidence path used
by `zig_semantic_refs` and `zig_semantic_callers`. Configure the executable with
`--zlint-path`. The diagnostics tools run this command shape:

```text
zlint --format json [--config <path>] [--rules <rules>] <path> [extra args]
```

`zig_zlint` accepts backend JSON shaped as a `findings`, `diagnostics`, or
`results` array and normalizes each entry into rule, severity, message,
workspace path, line, column, comparison key, and fingerprint fields.
`zig_zlint_sarif` converts the normalized findings to SARIF 2.1.0.
`zig_semantic_refs` and `zig_semantic_callers` use this command shape for
backend-confirmed symbol references when available:

```text
zlint --print-ast <file>
```

`zig_zlint_fix` previews the exact argv and only applies source changes when
`apply=true`:

```text
zlint --format json (--fix|--fix-dangerously) [--config <path>] [--rules <rules>] <path> [extra args]
```

`zig_zlint_rules` uses rule metadata from this command when the configured
binary exposes it:

```text
zlint --rules --format json
```

If the configured binary does not expose a rule-catalog flag, `zig_zlint_rules`
returns an empty rule list with capability metadata rather than failing the MCP
call. If diagnostics or fix output use an incompatible JSON dialect, zigar
returns a structured backend-output error with stdout/stderr previews instead
of treating the tool call as a generic MCP failure. Use `zig_lint_compare` to
compare normalized ZLint findings with normalized zwanzig findings, and use
`zig_lint_gate`, `zig_lint_baseline`, `zig_lint_suppressions`, and
`zig_lint_trend` for policy and adoption workflows over normalized findings.

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
`tools/release/real_backend_pins.json`.

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
zBench archive patch documented in `tools/release/real_backend_pins.json`.

`zig_flamegraph` and `zig_flamegraph_diff` return auditable artifact metadata:
input/output paths, explicit input format, backend executable path, argv shape
and argv, output byte count, output SHA-256, cached probe status when available,
unknown version when no stable version probe is available, compatibility status,
and warnings. Diff results also include intermediate folded metadata and an
intermediate folded SHA-256 for the diff-folded stage. All
zigar-generated SVG, DOT, and folded-diff outputs must use workspace-local
paths. This keeps profiler artifacts inspectable and prevents accidental writes
outside the active workspace.

## Samply And Tracy

Samply and Tracy capture workflows are explicit and preview-first. zigar does
not install either profiler, does not mutate developer setup, and does not open
viewer applications.

`zig_samply_record` builds this command shape and runs it only with
`apply=true`:

```text
samply record -o <workspace-output> -- <command argv>
```

Use `samply_path` when the executable is not named `samply`. Missing binaries,
failed probes, unsupported platforms, and profiler command failures are
structured results with the attempted argv and resolution. `zig_samply_summary`
parses supplied profile JSON without running Samply. `zig_samply_import` writes
a normalized profile artifact only when applied, and `zig_samply_artifact`
registers an existing workspace artifact with provenance only when applied.

`zig_tracy_probe` reports `not_probed` unless `probe_backend=true`; when probed,
it runs a bounded `tracy-capture --help`. `zig_tracy_capture` builds this
command shape and runs it only with `apply=true`:

```text
tracy-capture -o <workspace-output> -a <address> -p <port> -s <seconds>
```

Use `tracy_capture_path` when the executable is not named `tracy-capture`.
`zig_tracy_plan` and `zig_tracy_hints` are source-scan/advisory tools; they do
not modify source or prove instrumentation coverage. `zig_tracy_artifacts`
registers existing trace files as workspace artifacts only when applied.

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
