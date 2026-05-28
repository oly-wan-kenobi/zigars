# 07 — The Exceptional Bar

**Date:** 2026-05-28
**Scope:** What separates *well-engineered* from *truly exceptional*.
**Method:** Four parallel deep-dives over operational quality, onboarding/DX,
reliability/safety posture, and strategic positioning. No code changes.
**Frame:** Additive to [CLAUDE_ANALYSIS.md](../../CLAUDE_ANALYSIS.md) and
[00-synthesis.md](00-synthesis.md). Those answer "what to ship next." This
answers "what would make zigars *the* canonical Zig+agent tool."

---

## 1. The Gap

CLAUDE_ANALYSIS.md established that zigars is in strong shape on the
fundamentals: hexagonal core, zero TODOs, 885 passing tests, multi-platform
CI, eight-target release pipeline, ~300 manifest-driven tools. The
improvement-proposals roadmap adds capability surface (dependency cluster,
comptime trilogy, compound sessions, MCP protocol primitives).

Both are necessary. Neither is sufficient.

Exceptional products win on dimensions that are usually invisible until
they're missing: **the wedge is named and defended; the first five minutes
feel inevitable; the trust posture is auditable end-to-end; failures
explain themselves; the architecture is an ecosystem, not a product.**
Zigars under-invests in each of those today. This proposal makes the
under-investment concrete and ranks it.

---

## 2. Five Dimensions of Exceptional

| Dimension | Today | Exceptional bar | Gap |
|---|---|---|---|
| **Wedge** | "Deterministic MCP server for Zig development" | Single, defensible, one-page claim | Diffuse |
| **Operational quality** | Bounded counters, stderr logs | Request-ID tracing, p99 budgets, structured spans | Significant |
| **Trust architecture** | Checksums + apply-gates + workspace boundary | Signed releases, WAL, request transcripts, capability disclosure on connect | Real, fixable |
| **Onboarding & narrative** | 6 install paths, 18 docs, 300 tools | One guided arc; agent flow that "just works" in 60s | Significant |
| **Platform surface** | MCP-only, closed product | Reusable library, plugin contract, multi-protocol exposure | Strategic |

Items below are evidence-based against concrete file locations. Tags use
the existing scoring rubric from 00-synthesis.md (Impact 1–5, Effort
S/M/L).

---

## 3. Dimension 1 — The Wedge

### 3.1 "Deterministic" is a brand marker, not a contract

The word "deterministic" appears in [README.md:3](../../README.md),
[docs/architecture.md](../architecture.md), [docs/maturity.md](../maturity.md),
[docs/tools.md](../tools.md), and roughly two dozen other places — but
no document defines what it means operationally. Compare to peers: cargo's
"reproducible builds" has a doc; nix's "purity" has a doc; uv's "lockfile
determinism" has a doc. Zigars' deterministic claim is asserted, never
adjudicated.

A user asking "why zigars vs. an LLM that runs zig commands?" gets no
canonical answer. Internally the answer is rich: parser-backed evidence
tier, schema-checked outputs, no LLM in the path, reproducible artifact
provenance, apply-gated mutation. Externally it's invisible.

**Action (Impact 5, Effort S).** Add `docs/determinism.md` defining the
contract:
- Zero LLM calls inside any tool.
- All outputs are deterministic functions of inputs + workspace state +
  toolchain version (recorded in artifact registry).
- Schema-validated structured content; outputSchema once shipped.
- Every parser-backed tool re-runnable on the same revision produces a
  byte-identical structured result.
- Every advisory tool is labeled and ranks below parser-backed in the
  agent-facing manifest.

Link from [README.md](../../README.md) intro and from each `_orientation`
tool description.

### 3.2 Parser-backed tier is the moat but isn't marketed

[docs/maturity.md](../maturity.md) defines a three-tier hierarchy
(`parser_backed`, `command_backed`, `advisory_orientation`). The
manifest at [src/manifest/definitions/](../../src/manifest/definitions)
applies it across ~300 tools. This tier system is the strongest defensible
distinction zigars has against generic "agent runs commands" approaches.
It is mentioned nowhere on the README and only obliquely in the generated
tool index.

**Action (Impact 4, Effort S).** A 200-word README section titled "The
Three Tiers" with the canonical mental model and one example tool at each
tier. Cross-link from `zigars_schema` and `zigars_doctor` output.

### 3.3 Zig-distinctive surface is shallower than the positioning

Zig's identity is comptime + manual memory + cross-compile + build.zig +
build.zig.zon. A grep of [src/manifest/definitions/](../../src/manifest/definitions)
shows:

- Comptime: one diagnose tool (`zig_comptime_diagnose`) flagged
  `advisory_orientation`. The inspect/view/quota cluster (proposed in
  [05-agent-ergonomics.md](05-agent-ergonomics.md)) is unshipped.
- Allocators: no allocator-site catalog, no leak triage tool, no arena
  audit. The three-session signal in
  [00-synthesis.md](00-synthesis.md) §2 includes these and they're still
  deferred.
- ABI / packed structs / sentinel pointers: `zig_abi_layout_diff` exists
  but is advisory-tier.
- Cross-compilation: scattered across `zig_targets`, `zig_target_matrix_plan`,
  `zig_cross_smoke` without a single compound entry point.

A user choosing between zigars and "Claude with bash" will pick zigars for
*Zig-distinctive* leverage. The current surface gives them coverage,
fuzzing, public-API diff, transactional patches — excellent generic
quality tooling, but only adjacent to Zig's actual differentiation. The
proposals to fix this exist (Wave 4 comptime, D-6 leak triage, I-7
memory layout). The exceptional bar requires sequencing them earlier in
the roadmap, not later.

**Action (Impact 5, Effort L).** Promote the comptime trilogy from Wave 4
to Wave 2 in [00-synthesis.md](00-synthesis.md), even at the cost of
delaying one of the Wave 2 ergonomics items.

---

## 4. Dimension 2 — Operational Quality

### 4.1 No request-correlation IDs

[src/infra/observability/logging.zig:72-83](../../src/infra/observability/logging.zig)
writes stderr lines as `[zigars/component] level: message`. There is no
trace ID, no request ID, no MCP `request_id` carried through. When a user
reports "zigars hung on tool X," the operator's only forensics path is
parsing the full stderr stream and guessing which lines belong to that
call.

**Action (Impact 5, Effort M).** Add request-scoped context (request_id
from MCP envelope, propagated through every log line and every error
return). Echo the request_id in every tool's structured output so support
logs can pivot.

### 4.2 No per-phase startup instrumentation

[src/bootstrap/runtime.zig:22-102](../../src/bootstrap/runtime.zig) logs
events but does not time phases. ZLS spin-up, config parse,
workspace-realpath, manifest load, backend probe — none have measured
durations. There is no documented p50/p99 budget for cold start, warm
tool calls, or large-artifact responses.

**Action (Impact 4, Effort M).** Instrument startup phases with monotonic
durations, expose them in `zigars_doctor` output, write a `docs/perf.md`
budget table (cold start under N ms, warm tool call median under M ms,
patch-session apply p99 under K ms). Treat regressions as release gates.

### 4.3 Document/diagnostics caches grow until eviction

[src/infra/zls/diagnostics_cache.zig:19](../../src/infra/zls/diagnostics_cache.zig)
has a 16 MB cap with LRU-on-overflow. The document state cache at
[src/infra/zls/documents.zig:27](../../src/infra/zls/documents.zig) holds
up to 256 files × 10 MB each. No per-request arena resets in
[src/bootstrap/app_context.zig](../../src/bootstrap/app_context.zig).

A long agent session (hours, hundreds of files touched) trends toward the
ceiling. The behavior is bounded but never explained. For an
"exceptional" feel, the resident-set should be obvious to the operator and
to support.

**Action (Impact 3, Effort S).** Surface cache occupancy in
`zigars_doctor` and in the structured log stream. Document the expected
ceiling.

### 4.4 Error UX swallows root cause

[src/bootstrap/runtime.zig:71-76](../../src/bootstrap/runtime.zig) catches
ZLS initialization failures and logs only `@errorName(err)`, dropping the
LSP response body. AppError at
[src/app/errors.zig:23-44](../../src/app/errors.zig) has a `resolution`
field but the field is borrowed; many call sites leave it empty.

When the user sees "zls disabled" they have no surfaceable cause and no
next step. The exceptional bar is that every user-visible error answers
three questions: *what happened*, *what the user did to trigger it*, and
*what to do next*.

**Action (Impact 5, Effort M).** Audit every `catch` in
`src/bootstrap/` and `src/adapters/` for swallowed cause text. Populate
`AppError.resolution` from a small catalog keyed by `code` (per the
already-recommended `app/errors.zig` error catalog in
[CLAUDE_ANALYSIS.md](../../CLAUDE_ANALYSIS.md) §5 P3 #9).

### 4.5 Single-threaded request dispatch with no cancellation surface

The MCP adapter serves requests sequentially. A long parser-backed pass
on a 100k-LoC workspace blocks the next tool call. There is no
client-side cancellation surface (`$/cancelRequest` from JSON-RPC is not
plumbed through to in-flight subprocesses).

**Action (Impact 4, Effort L).** Wire MCP cancellation through to
in-flight commands and ZLS requests. Parallel-safe by tool category
(read-only tools can run concurrently; patch sessions remain serial).

---

## 5. Dimension 3 — Trust Architecture

### 5.1 First-download trust is TOFU

[packages/zigars-mcp-npm/src/install.ts:193-196](../../packages/zigars-mcp-npm/src/install.ts)
fetches the archive and the checksum file from the same GitHub release
URL. If the TLS chain is compromised between the user and GitHub at the
moment of first install, both files can be MITM'd as a coordinated pair.
The release workflow already calls GitHub provenance attestations
([release.yml](../../.github/workflows/release.yml)) but the npm shim
does not verify them.

**Action (Impact 4, Effort M).** Verify GitHub Build Provenance
attestations during install. Document the trust chain in
[docs/trust.md](../trust.md). Link from
[SECURITY.md](../../SECURITY.md). Optional but exceptional: GPG-sign
the checksum file as well.

### 5.2 No write-ahead-log for sessions

Patch sessions are atomic at single-file level via
[src/infra/workspace/workspace.zig:70-79](../../src/infra/workspace/workspace.zig)
(`createFileAtomic`), but multi-file session state is not journaled. If
zigars crashes mid-apply with three files pending, there is no recovery
log; the agent must re-preview and re-apply. The artifact registry
[src/infra/artifacts/registry.zig:89-96](../../src/infra/artifacts/registry.zig)
holds entries in memory with append-on-write — same exposure.

**Action (Impact 4, Effort M).** Per-session WAL in `.zigars-cache/`
covering preview→apply→commit transitions. Resume on next zigars startup
with an explicit "in-progress session N from PID M — resume or discard?"
prompt surface (or `zigars_session_recover` tool).

### 5.3 No MCP request transcript by default

After 200 tool calls, a user cannot answer "what exactly did the agent
call, with what arguments, and what came back?" Artifact registry
captures files; tool call counters track latency; but the request/response
JSON envelopes themselves are not persisted. Compare to LSP — every
respectable language server has a verbose-trace mode.

**Action (Impact 4, Effort S).** Opt-in `--audit-log <path>` flag that
writes a JSONL transcript of every MCP request/response with timestamps.
Off by default to preserve privacy; on for any user wanting forensics.

### 5.4 No Zig version pre-flight

[src/bootstrap/runtime.zig](../../src/bootstrap/runtime.zig) does not
check the resolved `zig` binary's version against the pinned
`build.zig.zon` requirement. The user discovers the mismatch when a tool
call fails midway.

**Action (Impact 3, Effort S).** Fail fast in `zigars_doctor` and during
startup with `zig version` matched against the
[build.zig.zon](../../build.zig.zon) `minimum_zig_version`.

### 5.5 Capability disclosure happens lazily

Per [docs/security-model.md](../security-model.md), zigars can read/write
inside the workspace and shell out to `zig`/`zls`/`kcov`. The first time
a user runs it, that capability set is implicit. An MCP client showing
"this server requested filesystem and subprocess access" can't say what
the bounds are.

**Action (Impact 3, Effort S).** On connect, emit a structured
`initialize` response describing capabilities: workspace path, subprocess
classes (zig/zls/coverage), max patch size, max output bytes, network
posture (none, except shim download — and even the shim is opt-in).
Document this as a *trust manifest* in [docs/trust.md](../trust.md).

---

## 6. Dimension 4 — Onboarding & Narrative

### 6.1 The first five minutes have six possible paths

[README.md:15-42](../../README.md) presents bunx, npx, yarn dlx, pnpm
dlx, MCPB bundle, and source build with equal visual weight. The
recommended path (Bun) is only inferable from order. New users hit
decision paralysis.

**Action (Impact 4, Effort S).** Single recommended install path as a
prominent block; alternative paths collapsed into a "Other launchers" or
"Install from source" subsection. Add a 60-second "first call" gif/asciicast.

### 6.2 No narrative onboarding doc

[docs/](../) has 19 reference documents (architecture, backends, codex,
distribution, dogfooding, maturity, release, release-evidence,
security-audit, security-model, testing, tool-index.generated, tools,
troubleshooting, trust, plus agent-clients and agent-workflows). There is
no narrative `docs/getting-started.md` that walks a new user through
install → first call → first useful workflow.

**Action (Impact 4, Effort S).** Add `docs/getting-started.md` with a
literal 15-minute happy path: install, point at a sample workspace, run
`zigars_doctor`, run `zigars_workspace_info`, run `zigars_next_action`,
make one patch-session edit. Link from README as the *first* doc.

### 6.3 examples/ has no README

[examples/](../../examples) holds `claude-code.mcp.json`, three Codex
TOMLs, `gemini-settings.json`, `http-smoke.sh`, `tool-calls.jsonl`. No
README explains what each is, when to use it, or how to adapt it. A new
user opening the directory has to read each file blind.

**Action (Impact 3, Effort S).** Add `examples/README.md` indexing each
file with one-line use-case descriptions.

### 6.4 Tool descriptions vary in agent-readiness

Sample reads of [docs/tool-index.generated.md](../tool-index.generated.md)
show descriptions ranging from excellent (e.g., `zigars_context_pack`
states its output contract) to too-generic (`zig_format` whose category
inherits "Deterministic Zig development MCP server"). Tool descriptions
are the prompt that the LLM sees when deciding whether to call the tool;
quality variance directly affects tool-selection accuracy.

**Action (Impact 4, Effort M).** Tool-description audit pass. Every
description should answer: *what does this tool produce*, *when should an
agent use it*, *what's the cheapest peer*. Add a manifest-level
contract gate that rejects descriptions shorter than N characters or
missing a verb.

### 6.5 No "Why zigars?" one-pager

[02-mcp-peer-scan.md](02-mcp-peer-scan.md) §5 lists ten areas where
zigars already leads peers (coverage baselines+diffs, fuzz quartet,
sanitizer fusion, public-API baseline+diff, transactional sessions,
artifact registry, etc.). This list is the de-facto positioning argument
and lives in an internal proposal that no end user will find.

**Action (Impact 5, Effort S).** Promote that list to a public
`docs/why-zigars.md` or weave it into a "What's distinctive" section of
the README. This is the one document a Zig developer comparing options
will read first.

---

## 7. Dimension 5 — Platform Surface

### 7.1 Closed product, not ecosystem

[packages/](../../packages) ships `zigars-mcp-npm`, `zigars-mcpb`, and
`zigars-skills-npm`. No `@zigars/parser`, no `@zigars/lsp`, no
`@zigars/cli`, no `@zigars/compose`. A VS Code extension wanting zigars'
import-graph would have to embed an MCP client; a CI script wanting
public-API diff would have to launch a stdio server.

The hexagonal split in [src/](../../src) is precisely the right
architecture to peel layers off into reusable components — and that
opportunity is unused.

**Action (Impact 5, Effort L).** Define an extraction roadmap. Candidates
in order of leverage: (a) the parser-backed catalog as a Zig library
consumable by other Zig tools, (b) a thin CLI exposing the same surface
without MCP, (c) an LSP server exposing the structural facts to editors.
Treat MCP as one transport, not the only one.

### 7.2 No extension contract

A user wanting `zig_my_linter_bridge` today must fork zigars. There is no
plugin manifest, no out-of-tree tool registration path. The
`@zigars/skills` package is closer to documentation packaging than to
code extension.

**Action (Impact 4, Effort L).** A plugin manifest format
(`zigars.plugin.json`) that lets third-party packages register tools the
zigars manifest discovers at startup. Apply-gated like every other write;
sandboxed to the workspace; subject to the same capability disclosure as
core tools.

### 7.3 No CI bot mode

Zigars is a stdio MCP server. There is no "run on every PR, post
zigars_change_risk_audit + zigars_public_api_diff + zigars_test_select to
the PR" mode. Each adopting team writes their own glue.

**Action (Impact 4, Effort M).** GitHub Action `zigars/zigars-action@v1`
wrapping the most common review-on-PR composition. Pairs naturally with
the planned `zig_change_risk_audit` (A-8) and `zig_bench_regression_gate`
(W-6) tools.

### 7.4 Multi-workspace / team features unaddressed

Every doc assumes a single `--workspace`. Mono-repos, multi-root projects,
and team-shared baselines (coverage, public API, fuzz corpus) are not
modeled. Coverage baselines and fuzz corpora are exactly the artifacts
that benefit from team sharing.

**Action (Impact 3, Effort M).** `.zigars/team.json` describing baseline
locations, shared corpus URLs, and team-level enforcement thresholds.
Optional; an exceptional product makes team adoption trivial without
forcing it on solos.

---

## 8. Cross-Cutting Observations

### 8.1 The exceptional bar shifts the roadmap weights, not the items

Almost every action above either:
- Exists as a P3/P4 item in CLAUDE_ANALYSIS.md (error catalog, perf
  thresholds, signed checksums), or
- Sits in Wave 3/4 of [00-synthesis.md](00-synthesis.md) (comptime
  trilogy, ZLS lifecycle, watcher), or
- Is genuinely new here (request-ID tracing, audit transcript, plugin
  manifest, CI bot mode, extraction roadmap, getting-started doc, "why
  zigars" page, examples README, capability-disclosure manifest, WAL,
  determinism contract doc, three-tier README section).

The "genuinely new" items are mostly **S-effort** doc, manifest, and
contract changes. The roadmap re-weighting is the real ask: bring the
distinctive surface (comptime, allocators, ABI) forward; bring the trust
posture (signing, WAL, audit, capability) forward; bring the narrative
(why-zigars, getting-started) forward.

### 8.2 The single biggest cheap win: name the wedge

If only one thing from this proposal lands, it should be
`docs/determinism.md` + the three-tier README section + `docs/why-zigars.md`.
Cumulative ~2 days of writing work. Cumulative effect: the project's
positioning becomes legible to first-time visitors, to potential
contributors, and to anyone comparing options. Today the moat is real
and the marketing is invisible.

### 8.3 The single biggest expensive win: become a platform

The parser-backed catalog is the genuinely defensible asset. As long as
it lives inside the MCP server, it's reachable only through MCP. As soon
as it's extractable (library + CLI + LSP), zigars stops being "an MCP
server for Zig" and starts being "the standard parser-backed Zig
intelligence layer, exposed via MCP among other transports." That's the
five-year position.

---

## 9. Prioritized 90-Day Punch List

Sorted by `Impact / Effort` ratio. Items are additive to CLAUDE_ANALYSIS
P0–P4 and to 00-synthesis Waves 1–4 — they don't displace anything;
they re-prioritize.

### Tier A — under a week, transformative

1. `docs/determinism.md` — name the wedge. **(I5/S)**
2. `docs/why-zigars.md` — promote 02 §5 to public. **(I5/S)**
3. README three-tier section. **(I4/S)**
4. `docs/getting-started.md` narrative onboarding. **(I4/S)**
5. `examples/README.md`. **(I3/S)**
6. README install-path triage (single recommendation, others collapsed). **(I4/S)**
7. Zig version pre-flight in `zigars_doctor`. **(I3/S)**
8. Capability-disclosure manifest in initialize response. **(I3/S)**

### Tier B — 1–3 weeks, exceptional in feel

9. Request-correlation IDs through logs + tool outputs. **(I5/M)**
10. AppError resolution catalog populated for every code. **(I5/M)**
11. Tool-description audit + manifest gate. **(I4/M)**
12. Per-phase startup instrumentation + `docs/perf.md` budgets. **(I4/M)**
13. Opt-in MCP audit transcript (`--audit-log`). **(I4/S)**
14. GitHub Build Provenance attestation verification in the shim. **(I4/M)**
15. Session WAL covering preview→apply→commit. **(I4/M)**

### Tier C — quarter-scale, strategic

16. Plugin manifest contract. **(I4/L)**
17. Parser-backed catalog extracted as `@zigars/parser` Zig library. **(I5/L)**
18. CLI surface (`zigars` direct, non-MCP). **(I4/M)**
19. `zigars/zigars-action@v1` GitHub Action. **(I4/M)**
20. MCP cancellation plumbed to subprocess kill. **(I4/L)**
21. Promote comptime trilogy from Wave 4 to Wave 2 of the roadmap. **(I5/L)**

---

## 10. TL;DR

Zigars has the engineering. It under-invests in the things that make
engineering visible.

- **Name the wedge** in three short docs (determinism, three tiers, why
  zigars). That's the cheapest, highest-impact lift in the project right
  now.
- **Make failure forensic** — request IDs, resolved error catalog, audit
  transcript. The exceptional bar is that every bad outcome is
  diagnosable in one read.
- **Make trust auditable** — provenance verification, session WAL,
  capability disclosure on connect. Closes the gap between "we are
  careful" (true) and "we are demonstrably careful" (not yet visible).
- **Promote the Zig-distinctive surface** — comptime, allocators, ABI —
  to the front of the roadmap. These are why a Zig developer chooses
  zigars over a generic agent.
- **Become a platform, not a server** — extract the parser-backed
  catalog as a library, ship a CLI and a GitHub Action, define a plugin
  contract. Five-year survival depends on zigars being a layer other
  tools build on, not a destination.

None of these conflict with the existing roadmap. They re-weight it.
