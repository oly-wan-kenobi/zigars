# Zigars Deep Analysis

**Analyst:** Claude Opus 4.7 (1M context)
**Date:** 2026-05-27
**Scope:** Read-only audit of source, build system, documentation, distribution packages, tests, and CI.
**Goal:** Assess current state and identify improvement areas. No code changes were made.

---

## 1. Executive Summary

Zigars is in **strong overall shape**. The Zig core is production-grade (hexagonal architecture, zero TODO/FIXME markers, comprehensive validation gates), documentation is consistent and current, and CI is multi-platform with 885 tests.

The main caveats are:

1. **v0.2.0 is only half-shipped publicly.** The GitHub release has the pre-expanded Zig tarballs + checksums, but the staged MCPB bundles are not uploaded. The npm shim has not been published to npm.
2. **The coverage gate is failing on a technicality.** 100% of measured lines are covered, but 32 files are listed as "missing" and the gate reports `ok: false`. Most of those 32 are `src/manifest/definitions/*.zig` (compile-time data tables).
3. **Original skills-package placeholder finding is stale.** Phase 0
   reconciliation found `packages/zigars-skills-npm/package.json`, a CLI,
   README, license, tests, and a concrete `zigars-development` skill. Publish
   readiness still needs package-local validation and any client skill
   validator.
4. **The npm shim is untested at the shim level.** Smoke tests cover the Zig core but never exercise the `bin/zigars-mcp.js` install/launch path.

Once the four above are addressed, the project is at a quality level above most OSS at this stage.

---

## 2. Methodology

Findings were gathered from four parallel sub-agents covering distinct areas:

- Zig source + build system (`src/`, `tools/`, `build.zig`, `build.zig.zon`, `zig-pkg/`)
- Documentation (`README.md`, `docs/`, `CONTRIBUTING.md`, `SECURITY.md`, `AGENTS.md`, `.agents/`)
- Distribution (`packages/zigars-mcp-npm`, `packages/zigars-mcpb`, `packages/zigars-skills-npm`, `.github/workflows/`, `dist/`)
- Tests, CI, coverage (`tests/`, `tools/quality/`, `tools/integration/`, `tools/coverage/`, `coverage/`, `.zigars-cache/`)

Several high-impact agent claims were re-verified by direct file inspection or `gh` calls. Corrections noted inline below.

---

## 3. Findings by Area

### 3.1 Zig Source & Build System

**Structure**
- 358 Zig files in `src/` (~88K LoC) organized as a hexagonal architecture: `adapters/`, `app/`, `bootstrap/`, `domain/`, `infra/`, each with a `root.zig` aggregator re-exported from [src/root.zig](src/root.zig).
- Process entrypoint [src/main.zig](src/main.zig) is a 15-line delegator into bootstrap composition.
- 41 Zig files in `tools/` (~7.9K LoC) implementing a 15-subcommand dispatcher at [tools/zigars_tools.zig:80-157](tools/zigars_tools.zig).
- Subsystems: MCP protocol adapters (stdio + HTTP), use-case orchestration (`app/`), runtime composition (`bootstrap/`), domain helpers (Zig models, diagnostics, profiling), and infrastructure (ZLS client, artifact mgmt, backend probing, process control, observability, toolchain mgmt).

**Build system**
- [build.zig](build.zig) — 299 lines, 20+ build steps. Unit tests embedded alongside source, integration smoke tests (HTTP + stdio), kcov coverage with per-module floors, multi-target release packaging (8 targets), and continuous validation steps (architecture-guard, public-contract, fake-backend scenarios).
- Single external dependency: `mcp` 0.0.4, locked via URL in [build.zig.zon](build.zig.zon).
- Release dist pipeline in [tools/release/dist.zig](tools/release/dist.zig) (521 lines) produces versioned multi-target tarballs with checksums.

**Code health (verified)**
- **Zero** TODO / FIXME / HACK / XXX markers across `src/` and `tools/`.
- 35 `@panic` / `unreachable` calls, all in justified positions (protocol-frame guards, post-allocation JSON building, contract validators).
- No commented-out dead code blocks detected.
- Consistent naming (snake_case fns, PascalCase types, lowercase modules) across 358 files.

**Maturity signals**
- Active enforcement of dependency contracts via `architecture_guard.zig` (857 lines).
- Active release-gate enforcement via `release_checks.zig` (415 lines).
- Versioning discipline (v0.1.0 → v0.2.0 cycle).
- Recent commits 2026-05-27 indicate post-release maintenance still active.

**Gaps**
- No architecture decision record (ADR) — the hexagonal split is well-enforced but rationale is implicit.
- `app/errors.zig` exists but no doc layer mapping error codes to diagnostic/recovery guidance.
- No documented Zig version compatibility matrix beyond the 0.16.0 pin in `build.zig.zon`.
- `tools/integration/http/http_performance_smoke.zig` exists but has no codified thresholds — it's a smoke test in name only.

---

### 3.2 Documentation

**Scope**
- 18 documents in `docs/` plus root-level `README.md` (30KB), `AGENTS.md`, `CONTRIBUTING.md`, `SECURITY.md`, `CHANGELOG.md`, `NOTICE.md`.
- `docs/tool-index.generated.md` (71KB) is auto-generated via `zig build tool-index`.

**Consistency (verified)**
- All references use `@zigars/mcp` — **no leftover** `@oly-wan-kenobi/zigars-mcp` or `@zigars/mcp` in any source file.
- Zig 0.16.0 referenced uniformly (README.md, AGENTS.md, backends.md, CI workflows).
- Archive naming convention (`zigars-{arch}-{os}[-abi].tar.gz`) consistent across docs and release tooling.
- v0.2.0 / 2026-05-19 dating consistent across CHANGELOG and per-package READMEs.

**Coverage by audience**
- End users: [README.md](README.md), [packages/zigars-mcp-npm/README.md](packages/zigars-mcp-npm/README.md).
- Contributors: [CONTRIBUTING.md](CONTRIBUTING.md), [AGENTS.md](AGENTS.md), [docs/architecture.md](docs/architecture.md).
- Operators: [docs/distribution.md](docs/distribution.md), [docs/release.md](docs/release.md), [docs/trust.md](docs/trust.md).
- Agents: [docs/agent-clients.md](docs/agent-clients.md), [docs/agent-workflows.md](docs/agent-workflows.md), `.agents/roles/`, `.agents/workflows/`.

**Weak spots**
- README doesn't route a new user between npm vs MCPB vs source-build install paths — all three are linked but not contrasted.
- [docs/maturity.md](docs/maturity.md) is not linked from README, even though the maturity rubric is exactly what adopters look for.
- [docs/trust.md](docs/trust.md) likewise not surfaced from README or SECURITY.md.
- Some duplication between README quickstart and `packages/zigars-mcp-npm/README.md`. Tolerable for discoverability but worth designating one as the source of truth.

---

### 3.3 Distribution Packages

#### 3.3.1 `@zigars/mcp` (npm shim) — `packages/zigars-mcp-npm/`

- **Name / version:** `@zigars/mcp@0.2.0`, `mcpName: io.github.oly-wan-kenobi/zigars`, `engines: node >= 18`, `publishConfig: { access: "public" }`. All correct.
- **Entry:** [bin/zigars-mcp.js](packages/zigars-mcp-npm/bin/zigars-mcp.js) → `dist/src/cli` (built by `prepack: npm run build`).
- **Files:** `bin`, `dist/src`, `src`, `README.md`, `LICENSE`, `tsconfig.json`, `dist/package.json`.
- **Verification:** Real SHA-256 checksum verification in [src/checksums.ts](packages/zigars-mcp-npm/src/checksums.ts) + [src/releases.ts](packages/zigars-mcp-npm/src/releases.ts).
- **README:** 505 lines, npmjs-friendly, with quickstart, tool tables, requirements, platform archive naming, client setup examples (Claude Desktop / Codex / Gemini), troubleshooting.
- **Readiness:** Requires refreshed release assets before publish. The v0.2.0 GitHub release has the pre-expanded tarballs, while the current shim expects the expanded Windows GNU archive names and Windows arm64 coverage.

#### 3.3.2 MCPB — `packages/zigars-mcpb/`

- **Role:** Release-only build harness (`private: true`, not for npm).
- **Builder:** [src/build.ts](packages/zigars-mcpb/src/build.ts) shells to `@anthropic-ai/mcpb@2.1.2` (env-overridable), consumes `dist/assets/*.tar.gz`, produces three bundles:
  - `zigars-darwin-universal.mcpb` (x86_64 + aarch64 merged via `llvm-lipo`)
  - `zigars-linux-x64.mcpb` (arm64 users routed to npm shim)
  - `zigars-windows-x64.mcpb`
- **Manifest generation:** Auto-generated `manifest.json` (manifest_version 0.3, name `zigars-mcp`, version 0.2.0, entry `server/zigars`, user config field `workspace`).
- **Staged artifacts in `dist/assets/`:** `zigars-darwin-universal.mcpb` 3.9MB, `zigars-linux-x64.mcpb` 5.7MB, `zigars-windows-x64.mcpb` 2.2MB, `zigars-mcpb-checksums.txt` 270B (3 SHA-256 entries).
- **Readiness:** Build tooling complete, artifacts staged and checksummed. **NOT YET UPLOADED** to the v0.2.0 GitHub release.

#### 3.3.3 `packages/zigars-skills-npm/`

**Phase 0 update (2026-05-27):** The original placeholder finding is stale.
The package now contains `package.json`, `bin/zigars-skills.js`, `README.md`,
`LICENSE`, `test/cli.test.js`, and `skills/zigars-development/SKILL.md`.

- **Readiness:** Packaging exists, but publish readiness should be proven with
  `npm test`, `npm run pack:dry`, and any client-side skill validator before
  public release claims.
- **Decision needed:** No remove-vs-populate decision remains for Phase 0. The
  remaining decision is when to publish and how to validate client skill
  consumption.

#### 3.3.4 Release workflow — `.github/workflows/release.yml`

- Gates: `zig build release-check` → `zig build dist release-asset-smoke` → MCPB install + `npm run pack` → GitHub build provenance attestation → upload via `softprops/action-gh-release`.
- Uploads: `dist/assets/*.tar.gz`, `dist/assets/*.mcpb`, `dist/assets/zigars-checksums.txt`, `dist/assets/zigars-mcpb-checksums.txt`.
- Other workflows: `ci.yml` (push/PR), `release-readiness.yml` (manual), `backend-conformance.yml`, `zls-conformance.yml`.
- **Note:** The v0.2.0 release was published on 2026-05-19 but currently only carries Zig tarballs. Re-running the workflow on the existing tag, or attaching the staged MCPB bundles by hand, would close the gap.

#### 3.3.5 Direct verification of release state

```
gh release view v0.2.0 →
  title: zigars 0.2.0
  tag:   v0.2.0
  published: 2026-05-19T13:27:51Z
  assets: five pre-expanded Zig tarballs plus zigars-checksums.txt
```

**Correction:** Earlier ICM-recall context claimed all v0.2.0 asset URLs return 404. This is **stale** — the pre-expanded Zig tarballs are live. MCPB bundles are the actual remaining gap. Current release-target expectations are the eight-archive set in `docs/release.md`.

---

### 3.4 Tests, CI, Coverage

**Test inventory (from `coverage/summary.json`, verified)**
- `zigars-lib-tests`: 824 tests (min 480) ✓
- `zigars-tools-tests`: 57 tests (min 26) ✓
- `zigars-exe-tests`: 2 tests (min 1) ✓
- `zigars-fuzz-tests`: 2 tests (min 2) ✓
- **Total: 885 tests, all passing.**

**Coverage status (verified)**
- `line_coverage_percent: 100.00` on 44,094 measured lines.
- `floors_ok: false` and overall `ok: false` because `missing_file_count: 32`.
- The 32 missing files are predominantly:
  - `src/manifest/definitions/*.zig` (compile-time tables: adoption, agent, ci, core, diagnostics, discovery, docs, environment_profiles, formatting, foundation, performance, phase6, profiling, runtime_ux, static_analysis, static_evidence, transactional_editing, validation_workflows, zls, zwanzig)
  - `src/manifest/{aggregate, all_definitions, definitions, groups, invariants, version}.zig`
  - `src/domain/zig/backend_catalog.zig`, `src/infra/backends/definitions.zig`
  - `tools/coverage/coverage_summary.zig`, `tools/integration/http/http_tool_contract_smoke.zig`, `tools/integration/stdio/stdio_core_fixtures.zig`, `tools/release/mcp_tool_contracts.zig`

This is a real, persistent failing gate. Either widen `exclude_path`, instrument these files, or change the gate so unmeasured files don't fail the overall check.

**CI gates (`.github/workflows/ci.yml`)**
- Ubuntu main job: `zig build release-check` (format, docs, JSON validation, backend scenarios, artifact hygiene, architecture guards, hex inventory) + `zig build dist release-asset-smoke` + bounded fuzz `--fuzz=10K`.
- **Correction:** Fuzzing IS gated in CI (the source-audit agent claimed otherwise). `fuzz` appears 2x in `ci.yml`.
- Coverage job: `zig build coverage` with artifact upload.
- Cross-platform smoke: macOS + Windows run format, unit tests, ReleaseSafe builds, HTTP smoke, stdio fixture tests.

**Cached evidence in `.zigars-cache/`**
- Directory names like `release-readiness-final-dirty`, `release-readiness-clean-final`, `release-readiness-pinned-dirty`, `backend-conformance-claimed-missing`, `backend-conformance-unclaimed`, `zls-conformance-deep`, `probe-zig-cache` indicate real, recent QA activity across multiple modes.
- These suggest the QA pipeline has been exercised through varied environmental conditions.

**Gaps**
- No automated tests for the npm shim or MCPB packages — distribution side is exercised only by the build pipeline, not by end-to-end install + invoke.
- Coverage gate's "missing file" handling should be reconciled with the actual intent (those files appear to be data tables, not executable logic).
- Backend conformance variants exist as cache directories but are not first-class `zig build` targets.
- No LLM-as-judge / semantic-quality tests for MCP tool outputs.

---

## 4. Cross-Cutting Observations

**Strengths**
- Disciplined code hygiene — zero TODOs/FIXMEs across 8K+ LoC is uncommon.
- Active enforcement of architectural boundaries via `architecture_guard.zig`.
- Multi-channel distribution (npm + MCPB + future skills) thought out at the project level.
- Single external Zig dependency (`mcp` 0.0.4) — small supply-chain surface.
- Documentation is internally consistent on names/versions, which is rare.

**Weaknesses**
- The release is publicly visible but partially populated — risk of trust erosion for early adopters who hit missing MCPB downloads.
- The coverage gate noisy-failing erodes signal — "ok: false" loses meaning when it's always false.
- The npm shim is the consumer-facing surface and has no end-to-end test guarding it.
- The skills package now has concrete package structure; publish readiness still
  needs package-local and client-skill validation.

---

## 5. Prioritized Improvements

### P0 — Ship-blocking for full v0.2.0

1. **Upload MCPB bundles + `zigars-mcpb-checksums.txt` to the v0.2.0 GitHub release.** Either re-run `release.yml` against the existing tag or attach the staged `dist/assets/*.mcpb` files manually. Closes the discrepancy between staged artifacts and what end users can download.
2. **Publish `@zigars/mcp@0.2.0` to npm.** The package is ready; nothing else blocks this.
3. **Validate `packages/zigars-skills-npm/` publish readiness.** The original
   "populate or remove" decision is stale because package metadata, CLI, tests,
   README, license, and a concrete skill now exist.

### P1 — Quality-gate hygiene

4. **Fix the coverage `ok: false` state.** Add `src/manifest/definitions/**` and the integration-test entry points to `exclude_path`, or revise the gate so unmeasured files don't fail the overall check. Restore the principle that green-stays-green.
5. **Add end-to-end smoke tests for the npm shim.** Install from a local tarball into a scratch directory, invoke `bin/zigars-mcp.js`, assert it downloads + verifies + launches. Highest-leverage missing test.

### P2 — Documentation polish

6. **Add a "Choose your install path" block to README.md** — three sentences contrasting npm vs MCPB vs source build. Removes real friction for first-time visitors.
7. **Link [docs/maturity.md](docs/maturity.md) and [docs/trust.md](docs/trust.md) from README.md** (and SECURITY.md). Adopters look for these and currently can't find them.
8. **Document the supported Zig version matrix.** Beyond the 0.16.0 pin, state which versions are tested, which are supported, and the policy on bumps.

### P3 — Medium-term hardening

9. **Add an error catalog** mapping `app/errors.zig` codes to diagnostic + recovery guidance.
10. **Add an architecture decision log** capturing the hexagonal-layer rationale.
11. **Codify performance thresholds** in `tools/integration/http/http_performance_smoke.zig` — currently it's a smoke test in name only.
12. **Surface backend-conformance variants as `zig build` targets** (`backend-conformance-deep`, `backend-conformance-claimed-missing`, etc.) so they're discoverable instead of living in cache directory names.

### P4 — Nice-to-have

13. GPG-sign checksums on top of GitHub attestations.
14. LLM-as-judge tests for MCP tool semantic quality.
15. Document the `@anthropic-ai/mcpb@2.1.2` pin as an explicit assumption with a fallback plan.
16. Reduce or document the README ↔ `packages/zigars-mcp-npm/README.md` quickstart duplication.

---

## 6. TL;DR

Zigars' Zig core, build system, docs, and CI are at a level most projects don't reach. Two things actually hold back a full public v0.2.0: **MCPB assets aren't on the GitHub release** and **the npm publish hasn't happened**. Two things would most raise the perceived bar after that: **fixing the coverage gate so green stays green** and **adding an end-to-end shim smoke test**. The skills package finding is now a validation/publishing question, not a placeholder-package decision.

---

## 7. Corrections Made During Verification

Several agent claims were corrected against direct evidence:

| Claim | Source | Verified state |
|---|---|---|
| "v0.2.0 GitHub release returns 404 for all assets" | ICM recall context | False — pre-expanded Zig tarballs + checksums live since 2026-05-19. MCPB bundles are the actual gap for that release. |
| "Fuzz testing not integrated into CI/CD gates" | Source-audit agent | False — `ci.yml` runs `--fuzz=10K`. |
| "zigars-skills-npm SKILL.md is entirely TODO template, no content beyond boilerplate" | Distribution agent | Stale after Phase 0 reconciliation — package metadata, CLI, README, tests, and a concrete skill now exist. |
| "No TODO/FIXME markers" | Source-audit agent | Confirmed via direct grep. |
| "Coverage 100%, status fails because of 32 excluded files" | Test agent | Confirmed via `coverage/summary.json` — `floors_ok: false`, 32 `missing_files`. |

## 8. Phase 0 Reconciliation Classification

See [docs/improvement-proposals/06-phase-00-baseline-reconciliation.md](docs/improvement-proposals/06-phase-00-baseline-reconciliation.md)
for the implementation appendix. The relevant findings are classified there
as still-valid, stale, or deferred; the most important change is that
`packages/zigars-skills-npm` is no longer a placeholder, while missing MCPB
release assets and unpublished npm packages remain valid release-readiness
gaps as of 2026-05-27.
