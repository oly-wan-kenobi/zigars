# Release Checklist

Before publishing, run the same gate CI uses and the release-asset gate:

```sh
zig build release-check
zig build dist release-asset-smoke
```

For a public release candidate, also run the manual `Release Readiness`
workflow. That workflow creates one evidence package containing the local
release gate, release-asset smoke result, real optional-backend conformance
report, real ZLS conformance report, and generated backend compatibility
matrix. Treat this workflow as release-required when the release notes claim
support for optional backends. The package is release-citable only when
`release-readiness.json` records the exact `source_commit` being tagged and
`source_tree_clean: true`. When maintainers use repo-pinned optional backend
setup, the evidence package also includes `backend-provisioning/real_backend_pins.json`
and `backend-provisioning/checksums.sha256`.

The gate includes formatting, generated docs/JSON drift checks, `zig build
test`, ReleaseSafe compilation, release-binary coverage, HTTP and stdio MCP
fixture coverage through coverage/conformance gates, backend conformance
contract smoke, backend scenario manifest drift, artifact hygiene, architecture
guard, hex architecture inventory, and public MCP contracts. It also checks
[trust.md](trust.md) and [maturity.md](maturity.md) so release readiness cannot
drift away from the documented product boundaries. It checks that the build
imports the pinned upstream `mcp` package directly instead of routing through a
patched MCP server wrapper, and that the first-party adapter still exposes
explicit `tools/call`, `resources/read`, and `prompts/get`
post-serialization cleanup hooks.
The release drift tools provide the same contract as MCP-facing preflight
checks: `zigar_docs_drift_check` verifies public documentation markers and
generated-index coverage, `zigar_release_claim_check` scans public docs for
conservative overclaim tokens, and `zigar_tool_index_check` compares registered
tools to `docs/tool-index.generated.md`. These tools are read-only convenience
checks; the release authority remains the build targets above.
Release-intelligence tools can organize supporting evidence before the gate:
`zig_release_plan` lists observed and missing release evidence,
`zig_semver_suggest` suggests a conservative bump from supplied API/release
text, `zig_release_notes_draft` drafts editable notes, and
`zig_release_evidence_pack` packages evidence pointers and verification
commands. They do not execute release gates, tag, publish, or certify skipped
checks.
The default GitHub Actions PR/main workflow then runs
`zig build dist release-asset-smoke` in the same Zig job, so archive shape,
checksums, and native archive runtime behavior are verified before a tag workflow
can publish anything. The HTTP JSON-RPC smoke test covers `initialize`,
`tools/list`, `zigar_schema`, and `zigar_doctor` using
`tests/fixtures/http-smoke.expect.json`, including parser/preview coverage for
coverage maps, benchmark comparison, Samply profile import/summary, Tracy
planning/probe/capture preview, and performance evidence bundles. The stdio
fixture covers newline JSON transport, formatting preview/apply, zwanzig SARIF
passthrough, zflame SVG output metadata, ZLint diagnostics/SARIF/rules/fix
preview normalization, CI annotation contracts, structured profiling plans, and
diff-folded flamegraph flow with fake backend executables.

## Release Gate Topology

`build.zig` is the authoritative topology for local release gates:

| Gate | Command or owner | Purpose |
|---|---|---|
| Format and drift | `zig build fmt-check`, `zig build docs-check`, `zig build json-check` | Check Zig formatting, generated `docs/tool-index.generated.md`, and JSON fixture/catalog syntax. |
| Unit binaries | `zig build test` | Run library, executable, tools, and fuzz test binaries. |
| ReleaseSafe | `zig build release-safe` | Compile the release binary with ReleaseSafe optimization. |
| Coverage and fixtures | `zig build coverage` and the release coverage command in `release-check` | Enforce kcov floors and run HTTP/stdio fixture coverage against the built binary. |
| Backend contracts | `zig build backend-contract-scenarios`, `zig build backend-conformance-contract` | Detect scenario manifest drift and smoke-test fake backend conformance report shape. |
| Architecture | `zig build architecture-guard`, `zig build hex-architecture-inventory` | Enforce target-layer import/effect rules and root/retired-surface inventory. |
| Public contracts | `zig build public-contracts` | Check no-patch MCP behavior, advertised capabilities, public schema/result/error shape, resource/prompt fixtures, and report contracts. |
| Hygiene | `zig build artifact-hygiene` | Check generated artifact paths, line budgets, pure-Zig tree policy, stale/forbidden tokens, workflow permissions, security policy, public claims, and tool/resource/CLI error contracts. |

`zig build dist release-asset-smoke` is the separate package gate. It builds the
archives, verifies checksums and required archive contents, and runs the native
archive when one matches the current host.

## Public Contracts

`tools/release/public_contracts.zig` aggregates the MCP contract checks used by
`zig build public-contracts` and `zig build release-check`. The current public
contract practice is:

- no local patched MCP dependency in `build.zig` or `build.zig.zon`;
- first-party MCP server cleanup hooks for tool results, resources, and prompts;
- advertised capabilities for completions, resource subscriptions, tasks, and
  pagination;
- manifest-to-MCP schema projection, required-field counts, structured
  invalid-argument results, apply gates, and plan metadata;
- resource and prompt fixture coverage, public resource URI and prompt names,
  and resource/prompt routing contracts;
- backend conformance, release-readiness, and real-ZLS report invariants;
- backend scenario manifest drift between
  `tests/integration/backend-contract/scenarios.zig`,
  `tests/integration/backend-contract/SCENARIOS.md`,
  `.github/scripts/backend-conformance.sh`, and
  `.github/scripts/backend-conformance-contract-smoke.sh`.

Release notes must include a short validation evidence block. At minimum, record
the source commit, clean-tree status, `zig build release-check`, `zig build dist
release-asset-smoke`, fake-backend fixtures, and real-backend validation status.
For real optional backends, cite only clean-tree `Release Readiness` evidence or
say `not run`; do not claim real backend coverage from fake-backend fixtures.
The evidence block must name the backend executable paths, probe/version status,
scenario matrix status, and artifact hashes used for every optional backend
claim, or explicitly state that the backend was not claimed for that release.

When the `Release Readiness` workflow runs, use its generated
`release-readiness.md`, `backend-conformance/summary.md`, and
`zls-conformance/summary.md` files as the release-note source of truth. The
backend compatibility matrix is generated from executable paths, SHA-256 hashes,
version/probe output, platform metadata, tested capabilities, and pass/fail
status. Do not hand-write broader compatibility claims than the generated matrix
supports. If the script was run with `ZIGAR_ALLOW_DIRTY_RELEASE_READINESS=1`,
the generated summary is non-release evidence and must not be used as final
release-note validation until rerun from a clean tree.

CI also uploads a `zigar-coverage` artifact. The artifact includes
`coverage/summary.json` with the installed library, executable, and tooling test
binary results, per-suite floors, measured kcov coverage, configured coverage
floors, and floor pass/fail fields.

`release-check` includes `zig build artifact-hygiene`, which fails if known
generated directories such as `.zig-cache/`, `zig-out/`, `zig-pkg/`, `dist/`, or
`coverage/` are tracked by git.

`artifact-hygiene` is broader than generated-file detection. Its policy tables
live in `tools/release/release_rules.zig`, and its checker lives in
`tools/release/release_checks.zig`. The hygiene gate also enforces:

- line budgets and required headroom for large or trust-critical files;
- pure-Zig project-owned trees by rejecting Python files under `.github`,
  `docs`, `examples`, `scripts`, `src`, `tests`, and `tools`;
- forbidden global/runtime/logging tokens and known stale-code tokens;
- ignored-error hygiene for LSP, smoke, fixture, fake-backend, release-check,
  and CLI helper paths;
- workflow permission minima, including read-only contents for CI/conformance
  workflows and write/id-token/attestation permissions for release publishing;
- structured tool, resource, and CLI error contract scans;
- static-analysis capability tier and source-read-only/apply-gated write
  checks;
- optional-backend, command-running, agent-workflow, CI-artifact,
  docs-lookup, release-evidence, maturity, trust, foundation, adoption,
  security-policy, and public-claim documentation checks.

`zig build dist` builds all release targets with ReleaseSafe optimization and
writes archives plus `zigar-checksums.txt` under `dist/assets`.
`zig build release-asset-smoke` verifies every checksum, checks required files in
each archive, extracts the native archive for the current runner OS/architecture,
and runs `zigar --version` from it.

## Publishing

1. Publish from a standalone repository rooted at this directory.
2. Confirm `zig build version` matches the intended release version.
3. Run `zig build release-check`.
4. Run `zig build dist release-asset-smoke`.
5. Run the manual `Release Readiness` workflow with the real backend paths that
   the release intends to claim. Prefer `pinned_backend_setup: true` when the
   release should cite the repo-owned backend pins. Confirm
   `release-readiness.json` records the intended `source_commit`,
   `source_tree_clean: true`, matching subreport commits, backend pin evidence
   when used, and a passed scenario matrix for every claimed backend. If only
   ZLS is being refreshed, run the manual `ZLS Conformance` workflow and cite
   that artifact.
6. Confirm [maturity.md](maturity.md) still says every major feature area is at
   the intended public rating without hiding known limitations.
7. Confirm [trust.md](trust.md) still matches the release notes, especially any
   absent external validation for branch protection, optional backends, or
   client-specific behavior.
8. Add a validation evidence block to the release notes, including real-backend
   validation status. If the manual backend conformance script or workflow did
   not run, say `not run` instead of implying coverage.
9. Confirm the tag and GitHub release do not already exist.
10. Tag the release:

```sh
version="$(zig build version)"
git tag -a "v${version}" -m "zigar ${version}"
git push origin "v${version}"
```

The normal tag workflow reruns `zig build release-check`, runs
`zig build dist release-asset-smoke`, publishes Linux, macOS, and Windows
archives, publishes `zigar-checksums.txt` with SHA-256 checksums, and creates
GitHub provenance attestations from the checksum file when GitHub supports
attestations for the repository. User-owned private repositories cannot persist
GitHub attestations, so the workflow skips that step there and the release notes
must not claim provenance attestations. GitHub Actions are pinned to commit SHAs
in the workflow; update the adjacent tag comments when bumping an action.

A workflow-published version is public only after the tag workflow finishes and
the GitHub release contains all expected archives, `zigar-checksums.txt`, and
provenance attestations. Do not advertise archive installation for a version
until that verification is complete.

If GitHub Actions are unavailable and a manual release is unavoidable, the
release notes must say so explicitly. Include the exact source commit, the local
gates that passed, and the fact that the checksum file is the verification
record for that release. Do not claim GitHub provenance attestations for a
manual release unless they are actually attached to the release.

```sh
version="$(zig build version)"
gh release view "v${version}" --json tagName,assets
```

Release assets are named:

- `zigar-x86_64-linux-musl.tar.gz`
- `zigar-aarch64-linux-musl.tar.gz`
- `zigar-x86_64-macos.tar.gz`
- `zigar-aarch64-macos.tar.gz`
- `zigar-x86_64-windows.tar.gz`

## Package Hygiene

- `build.zig.zon` pins `mcp.zig` by archive URL and package hash; update both
  intentionally when bumping the dependency. Do not add local patches under
  `third_party` or route `mcp` through a wrapper module; if zigar needs
  server-side behavior, keep it in the first-party adapter under `src/`.
- Dependency review can use `zig_dependency_update_plan`,
  `zig_dependency_fetch_check`, `zig_dependency_lock_audit`, `zig_sbom`,
  `zig_dependency_security_report`, `zig_dependency_provenance`,
  `zig_dependency_license_summary`, and
  `zig_github_dependency_submit_plan` as local evidence helpers. Scanner tools
  ingest supplied ZAT or OSV reports but do not contact external services.
- Release targets are defined once in `tools/release/release_targets.zig`; update that
  table when adding or removing a published archive target.
- `zig-pkg/`, `.zig-cache/`, `.zigar-cache/`, and `zig-out/` are local artifacts
  and are not part of the published package.
- `coverage/` is generated by `zig build coverage` and is not part of the
  published package.
- Keep the typed manifest under `src/manifest/` as the single authority for
  tool names, schemas, grouping, discovery keywords, risk flags, planning
  metadata, and handler references when adding, renaming, or removing tools.
- Regenerate `docs/tool-index.generated.md` with `zig build tool-index` after
  manifest or static catalog note changes.
- Keep `tests/fixtures/http-smoke.expect.json` synchronized with public MCP
  discovery surfaces when changing tool names or schema fields.

## Repository Hygiene

- zigar should be published from a standalone repository rooted at this
  directory.
- Avoid committing parent-workspace changes or generated cache output.
- Before tagging, run `git status --short` from the standalone zigar repository
  root and confirm only intentional source, docs, and workflow changes are
  present.
