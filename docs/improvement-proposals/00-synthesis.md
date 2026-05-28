# 00 — Roadmap Synthesis

**Author:** Claude Opus 4.7 (1M context)
**Date:** 2026-05-27
**Status:** Synthesis of [01-internal-gaps.md](01-internal-gaps.md),
[02-mcp-peer-scan.md](02-mcp-peer-scan.md), [03-zig-dev-pain.md](03-zig-dev-pain.md),
[04-compound-workflows.md](04-compound-workflows.md), and
[05-agent-ergonomics.md](05-agent-ergonomics.md).
**Scope:** Single ranked roadmap. No code or existing-doc changes. Excludes
items already captured in the prior private Claude analysis note.

**Phase 0 baseline:** Current-state corrections and roadmap decisions are
recorded in [06-phase-00-baseline-reconciliation.md](06-phase-00-baseline-reconciliation.md).
Later phases should treat that appendix as the source of truth for substrate,
skills-package, and architecture-neutrality assumptions.

---

## 1. Executive Summary — Top 5 Recommendations

### 1. Dependency-management cluster (search → mutate → migrate → resync) — **4-session signal**

Four sessions independently identified Zig's dependency story as the biggest
capability gap. Zigars has rich read-only dependency tooling
(`zig_dependency_inspect`, `_impact`, `_security_report`, `_provenance`,
`_license_summary`, `_lock_audit`, `_update_plan`) but **cannot search a
registry, cannot mutate `build.zig.zon`, and cannot run the hash-mismatch
dance automatically**. Every peer ecosystem (cargo-mcp, uv-mcp,
cratesio-mcp, npm-helper-mcp) ships this surface; Zig is the outlier. Land
this cluster in order: `zig_pkg_search`/`_info`/`_versions`/`_readme` →
`zig_deps_add`/`_remove`/`_upgrade` (apply-gated through patch sessions) →
`zig_zon_dep_sync` (compresses the bogus-hash workaround) → `zig_dependency_migrate`
(end-to-end orchestrator). Total Impact 5, Effort L. Reuses existing
patch-session and artifact-registry plumbing.

### 2. MCP protocol substrate (outputSchema → resource_link → completion → elicitation → sampling)

The 2025-06-18 spec added primitives that multiply across the entire
~300-tool surface. Zigars already has the data shapes, broad
`structuredContent`, a basic `completion/complete` route, resource templates
and subscriptions, tasks, an artifact registry with SHA-256 provenance,
manifest-driven enum inputs, and a workflow contract with preview/apply
gates. The missing work is deeper contract projection and richer protocol
use, not first-time route creation. Declared `outputSchema` (P4) is the
highest-leverage start because it formalizes contracts zigars already
de-facto ships. `resource_link` blocks (P5) cut token cost on every
heavy-artifact tool. Manifest-backed `completion/complete` (P3) makes
300-tool slash-command UX usable. `elicitation/create` (P1) complements and
eventually renames zigars' `_elicit`-named *advisory* tools with real
human-in-the-loop dialogs on risky operations. `sampling/createMessage` (P2)
lets zigars ask the host's LLM for in-loop summarization without leaving the
tool call. Impact 5 each, Effort M each, no novel state — pure substrate.

### 3. Planning / review ergonomics trio — A-9 + A-7 + A-8

Planner, Reviewer, and Orchestrator roles in the SluiceDB-style workflow fall
back to grep + multi-file reads for canonical structural questions ("are there
cycles?", "what's the dossier on this symbol?", "which files in this diff need
the most attention?"). Landing `zig_import_cycles` (S, pure post-processing)
first unlocks `zig_symbol_dossier` (composite, S–M) and
`zig_change_risk_audit` (composite, M). Zigars' own hexagonal architecture
guard remains an internal quality gate rather than a default public Zig policy.
Together these public tools turn the most agent-by-vibes step in the workflow
into a structured, architecture-neutral query. Cumulative Impact 4, Effort M.

### 4. Comptime visibility trilogy (diagnose → inspect → quota-probe) — **3-session signal**

Three sessions independently identified Zig's comptime as both the
language's distinctive feature and a top friction source. **No peer has
this surface** — and zigars' parser-backed tier is the right home for it.
`zig_comptime_diagnose` (D-3) explains "unable to evaluate comptime
expression" by walking the AST around the cursor and identifying the
runtime-tainted operand. `zig_comptime_inspect` / `zig_comptime_view` (A-10
+ P-9) introspects what a comptime expression evaluates to (ship heuristic
parser-only first, compiler-eval second). `zig_comptime_quota_probe` (D-10)
finds what's eating the `@setEvalBranchQuota` budget. Together they
crystallize zigars' positioning vs. peers on the most Zig-distinctive pain
surface. Combined Impact 4, Effort L (most cost is in the
inspect/view backend; diagnose is M).

### 5. State-managed compound sessions — W-1 + W-3 + P-10

Bisect, crash repro, and revisable debug planning are the canonical
workflows where state management is the entire job, and where zigars'
existing tool surface technically suffices but is exhausting to drive by
hand. `zig_build_bisect` (W-1) compresses 10–100+ round trips into one
session with auditable per-ref outcomes and crash-identity dedupe.
`zig_crash_capture_session` (W-3) finally puts `crash_identity` to work as a
session key, so recurring crashes don't re-parse the same panic for the
third time. `zigars_debug_session_*` (P-10) adds Anthropic's
sequential-thinking primitive (revisable thoughts + branching) on top, so
the *reasoning* is recoverable, not just the evidence. Together they land
the killer-app pattern across debugging workflows. Impact 5, Effort L
(each), but they share session-shape design work.

---

## 2. Multi-Session Convergence

Proposals that surfaced in multiple investigation sessions get a stronger
signal — independent reviewers landing on the same gap is the cleanest form
of cross-validation available here.

| Theme | Sessions | Cluster members |
|---|---|---|
| Dependency lifecycle (search/add/sync/migrate) | 02, 03, 04 (4 proposals) | P-6, P-7, D-1, W-2 |
| Comptime visibility (diagnose / view / inspect / quota) | 02, 03, 05 | P-9, D-3, D-10, A-10 |
| Memory / ABI layout (parser-backed catalog → C-diff) | 01, 03 | I-7, D-4 |
| Refactor at scale (file move + symbol rename) | 01, 04 | I-5, W-5 |
| Test discovery (filter resolution + reverse coverage + fixtures) | 03, 05 | D-7, A-1, A-5 |
| Cross-target verification (intent → triple → matrix run) | 03, 04 | D-5, W-7 |
| Debug / crash reasoning state | 02, 04 | P-10, W-3 |

The dependency cluster is the strongest signal — four independent sessions
agree it is the largest capability gap. The comptime trilogy is second.

---

## 3. Full Ranked Table

**Scoring.** Impact 1–5 (5 = unlocks new agent loop or net-new capability;
1 = incremental). Effort S/M/L. Strategic fit ★–★★★ (does it reinforce
zigars' parser-backed / apply-gated / evidence-labels positioning vs.
peers?). Dependency risk Low/Med/High (external backends, novel state,
client adoption uncertainty). Group: **QW** = quick win,
**SB** = strategic bet, **FI** = fill-in, **DF** = defer.

| ID | Proposal | Origin | Impact | Effort | Fit | Dep risk | Group |
|---|---|---|---|---|---|---|---|
| **A-9** | `zig_import_cycles` | 05 | 4 | S | ★★★ | Low | **QW** |
| **D-7** | `zig_test_name_resolve` | 03 | 3 | S | ★★ | Low | **QW** |
| **D-1** | `zig_zon_dep_sync` | 03 (cluster w/ P-7, W-2) | 5 | M | ★★★ | Low | **QW** |
| **I-9** | `zig_safety_site_catalog` | 01 | 3 | S–M | ★★★ | Low | **QW** |
| **A-5** | `zig_test_fixture_inventory` | 05 | 3 | S–M | ★★ | Low | **QW** |
| **P-4** | MCP `outputSchema` + `structuredContent` | 02 | 5 | M | ★★★ | Low | **SB** |
| **P-5** | MCP `resource_link` content blocks | 02 | 5 | M | ★★★ | Low | **SB** |
| **P-3** | MCP `completion/complete` | 02 | 4 | M | ★★★ | Low | **SB** |
| **P-1** | MCP `elicitation/create` | 02 | 4 | M | ★★★ | Med (client) | **SB** |
| **P-2** | MCP `sampling/createMessage` | 02 | 4 | M | ★★ | Med (client) | **SB** |
| **P-6** | `zig_pkg_search`/`_info`/`_versions`/`_readme` | 02 (cluster) | 5 | M | ★★ | Med (registry choice) | **SB** |
| **P-7** | `zig_deps_add`/`_remove`/`_upgrade` | 02 (cluster) | 5 | M | ★★★ | Low | **SB** |
| **W-2** | `zig_dependency_migrate` | 04 (cluster) | 4 | M | ★★★ | Low | **SB** |
| **W-1** | `zig_build_bisect` | 04 | 5 | L | ★★★ | Med (new state) | **SB** |
| **W-3** | `zig_crash_capture_session` | 04 | 4 | L | ★★★ | Low | **SB** |
| **P-10** | Revisable debug-session planner | 02 | 4 | M | ★★ | Low | **SB** |
| **D-3** | `zig_comptime_diagnose` | 03 (cluster) | 4 | L | ★★★ | Low | **SB** |
| **A-10** | `zig_comptime_inspect` | 05 (cluster) | 4 | L | ★★★ | Med (compiler-eval) | **SB** |
| **P-9** | `zig_comptime_view` | 02 (cluster) | 3 | L | ★★ | Med (LLVM IR) | **SB** |
| **D-2** | `zig_io_migration_scan` | 03 | 4 | M | ★★★ | Low | **SB** (timed) |
| **P-8** | `zig_watch` (async file-system monitor) | 02 | 4 | L | ★★ | Low | **SB** |
| **W-4** | `zig_c_header_port` | 04 | 3 | S–M | ★★★ | Low | **FI** |
| **W-5** | `zig_workspace_rename` (symbol) | 04 | 3 | M | ★★★ | Low | **FI** |
| **W-6** | `zig_bench_regression_gate` | 04 | 3 | M | ★★★ | Low | **FI** |
| **A-1** | `zig_test_for_symbol` | 05 | 4 | M | ★★★ | Low | **FI** |
| **A-3** | `zig_module_surface` | 05 | 3 | M | ★★ | Low | **FI** |
| **A-7** | `zig_symbol_dossier` | 05 | 4 | S–M | ★★★ | Low (after A-1) | **FI** |
| **A-8** | `zig_change_risk_audit` | 05 | 4 | M | ★★★ | Low | **FI** |
| **A-4** | `zig_insertion_sites` | 05 | 3 | M | ★★ | Med (heuristic ranking) | **FI** |
| **A-6** | `zig_error_propagation` | 05 | 3 | M–L | ★★★ | Low | **FI** |
| **D-6** | `zig_leak_triage` | 03 | 3 | S+M | ★★★ | Low | **FI** |
| **D-5** | `zig_target_chooser` | 03 | 3 | M | ★★ | Low | **FI** |
| **I-3** | `zig_typedef_jump` | 01 | 3 | S–M | ★★ | Low | **FI** |
| **I-1** | `zig_call_hierarchy` | 01 | 3 | M | ★★ | Low | **FI** |
| **I-2** | `zig_type_hierarchy` | 01 | 3 | M | ★★ | Low | **FI** |
| **I-4** | `zig_inlay_hints` | 01 | 3 | M | ★★ | Low | **FI** |
| **I-7** | `zig_memory_layout` | 01 (cluster) | 3 | M | ★★★ | Low | **FI** |
| **D-4** | `zig_abi_layout_diff` | 03 (cluster) | 4 | L | ★★★ | Low | **SB** |
| **I-8** | `zig_unsafe_operations_audit` | 01 | 3 | M | ★★★ | Low | **FI** |
| **I-5** | `zig_workspace_file_rename` | 01 | 3 | L | ★★★ | Low | **FI** |
| **I-6** | `zig_build_script_inspect` | 01 | 3 | L | ★★★ | Low | **FI** |
| **D-8** | `zig_linker_error_decode` | 03 | 2 | M + ongoing | ★★ | Med (catalog upkeep) | **DF** |
| **D-9** | `zig_cimport_macro_wrap` | 03 | 2 | M | ★★ | Med (pathological macros) | **DF** |
| **D-10** | `zig_comptime_quota_probe` | 03 (cluster) | 2 | M | ★★ | Med (wall-clock cost) | **DF** |
| **W-7** | `zig_target_matrix_run` | 04 | 3 | L | ★★ | Low (but adoption-bound) | **DF** |
| **W-8** | `zig_allocator_audit` | 04 (playbook) | 2 | M | ★ | Low | **DF** |

---

## 4. Proposed Sequencing

Four waves. Each wave assumes the prior wave's foundations exist; within
a wave, items are independent and can be parallelized across contributors.

### Wave 1 — Foundations (≈3–4 weeks)

Pure-substrate items where each unlocks several downstream proposals
and the implementation work is bounded.

- **P-4** declared `outputSchema` for structured tool results.
  `structuredContent` already exists; this makes the output contract explicit.
  Manifest discipline already exists; this exposes it. *Unblocks*
  P-3, P-5, every new tool's output contract.
- **A-9** `zig_import_cycles` — post-processing over existing
  `zig_import_graph_json`. *Unblocks* nothing further but is a self-contained
  win.
- **D-7** `zig_test_name_resolve` — single AST pass, immediate friction kill
  for `--test-filter`.
- **D-1** `zig_zon_dep_sync` — compresses the hash-mismatch loop; sets the
  pattern for the larger P-7 mutation surface.
- **I-9** `zig_safety_site_catalog` — wraps CI counters already in
  `tools/quality/`. Smallest of the parser-backed catalog proposals.
- **A-5** `zig_test_fixture_inventory` — single AST pass; low risk.

### Wave 2 — Capability expansion (≈4–6 weeks)

Builds the registry / mutation surface that closes the largest gap vs.
peers, and turns the protocol substrate into per-tool wins.

- **P-5** `resource_link` content blocks on heavy-output tools
  (samply, tracy, sbom, fuzz, coverage, large patch previews).
- **P-3** `completion/complete` driven by the manifest. Manifest-tagged
  enum/`completion_source` callbacks supply the data.
- **P-6** `zig_pkg_search`/`_info`/`_versions`/`_readme`/`_docs` —
  registry browse cluster.
- **P-7** `zig_deps_add`/`_remove`/`_upgrade` — apply-gated `build.zig.zon`
  mutators via patch sessions.
- **A-1** `zig_test_for_symbol` — reverse coverage closure for Test
  Reviewer.
- **W-4** `zig_c_header_port` — small compound; first opportunity to
  validate the workflow-contract envelope on a fresh chain.
- **W-5** `zig_workspace_rename` — semantic rename composing patch
  sessions and ZLS refs.
- **D-6** `zig_leak_triage` — GPA stderr parser + symbolizer wiring.
- **D-2** `zig_io_migration_scan` — schedule this in Wave 2 specifically;
  the 0.15→0.16 adoption window is open *now* and the value decays over
  the next year.

### Wave 3 — Composites and orchestrators (≈6–8 weeks)

Compositions over Wave 1+2 foundations, plus the higher-risk protocol
features once client adoption is verified.

- **W-2** `zig_dependency_migrate` — orchestrator over P-7 + D-1 +
  `_lock_audit` + `_security_report` + `_impact` + `validation_run`.
- **W-6** `zig_bench_regression_gate` — pure composition over existing
  bench tools.
- **A-7** `zig_symbol_dossier` — composition over A-1, A-2, ZLS refs,
  diagnostics, lint, git history.
- **A-8** `zig_change_risk_audit` — composition over A-2, `zigars_impact`,
  `zig_test_select_semantic`, `zig_public_api_diff`.
- **A-3** `zig_module_surface` — directory aggregate over `zig_public_api`
  and `zig_semantic_refs`.
- **A-4** `zig_insertion_sites` — Planner ergonomics; uses A-2 + semantic
  index + manifest heuristics.
- **P-1** `elicitation/create` — start with `zigars_patch_session_apply`,
  `zig_libfuzzer_run`, `zig_afl_run` opt-ins; rename existing `_elicit`
  tools to advisory equivalents to free the namespace (see open question
  §5.3).
- **P-2** `sampling/createMessage` — opt-in `summarize: true` on a
  shortlist of high-volume tools (zlint, panic-trace, samply summary,
  public-API diff).

### Wave 4 — Strategic bets (≈8–12 weeks)

Items with novel state, larger backend cost, or that need a prototype
adopter to justify the generalization cost.

- **W-1** `zig_build_bisect` — first instance of a true cross-ref session
  shape.
- **W-3** `zig_crash_capture_session` — validates `crash_identity` as a
  durable session key.
- **P-10** Revisable debug-session planner — pairs with W-3, lifts
  reasoning state out of the agent's context window.
- **D-3** `zig_comptime_diagnose` — first of the comptime trilogy
  (parser-backed, no compiler-eval needed).
- **A-10** / **P-9** `zig_comptime_inspect` / `_view` — ship
  `evaluation_basis: heuristic_ast_only` first; layer
  `compiler_eval` later via a sandbox `zig build-obj` probe path.
- **A-6** `zig_error_propagation` — parser-backed flow over call graph.
- **D-4** `zig_abi_layout_diff` (after I-7 `zig_memory_layout`).
- **I-7** `zig_memory_layout` — parser-backed catalog; pairs into D-4.
- **I-8** `zig_unsafe_operations_audit` — extends I-9's catalog pattern.
- **I-1** / **I-2** / **I-3** / **I-4** — ZLS LSP wrappers (call/type
  hierarchy, typedef_jump, inlay hints). I-3 first as the cheapest
  pattern-validator.
- **I-5** `zig_workspace_file_rename` — file move + import rewrite; reuses
  W-5's patch-session pattern but with workspace filesystem mutation.
- **I-6** `zig_build_script_inspect` — promotes three advisory tools to
  parser-backed.
- **D-5** `zig_target_chooser` — intent→triple translator.
- **P-8** `zig_watch` — long-running file-system monitor; depends on P-5
  for `resources/subscribe` event push.

### Deferred or playbook-only

- **D-8** `zig_linker_error_decode` — initial catalog cost is fine; the
  *ongoing* per-release maintenance burden is the concern. Land only if
  catalog ownership has a clear home.
- **D-9** `zig_cimport_macro_wrap` — pathological macro coverage is
  open-ended. Park unless a specific adopter pushes for it.
- **D-10** `zig_comptime_quota_probe` — binary search is wall-clock
  expensive and budget attribution is heuristic. Document as a playbook
  using the existing `zig_bench_baseline` apply-gate pattern; promote to
  a tool only if recurring user demand surfaces.
- **W-7** `zig_target_matrix_run` — high value but only justified once two
  adopter projects regularly run matrices. Track adoption signal first.
- **W-8** `zig_allocator_audit` — already recommended as a playbook in 04.
  Promote only if `zig_allocations` moves up from `advisory_orientation`.

---

## 5. Open Questions for Human Decision

These need a call before implementation locks in.

### 5.1 Dependency-registry choice (blocks P-6)

The Zig package ecosystem is decentralized (URL + hash in `build.zig.zon`).
P-6 needs to wrap *something*. Candidates: [zigistry](https://zigistry.dev),
the [zig.community lists](https://zig.community), GitHub topic search
(`topic:zig-package`), or a pluggable adapter driven by
`.zigars/profile.json`. The right answer is probably pluggable with one or
two preconfigured registries — but the choice of *which* presets and the
trust model around them is a real human-call that affects the tool's
public-facing posture.

### 5.2 MCP client adoption timing for P-1 / P-2

`elicitation/create` and `sampling/createMessage` only deliver value when
the host client implements them. Claude Desktop and Claude Code adoption
is in flight per the spec discussions but not universally shipped today.
Should zigars:
- (a) implement with graceful fallback (zero cost when client lacks
  support, but no value either), or
- (b) wait until Claude Desktop/Code ship support, then implement, or
- (c) implement and *require* support, refusing risky operations on
  non-supporting clients?

The conservative answer is (a) for P-2 (summarization is opportunistic),
(c) for P-1 in apply-only paths once Claude Desktop ships support, and
maintain (a) fallback to the existing `apply=true` convention until then.

### 5.3 Naming collision: existing `_elicit` tools vs. P-1 protocol elicitation

`zigars_setup_elicit`, `zigars_profile_elicit`, `zigars_backend_elicit` are
*advisory tools that return text*. P-1 introduces real protocol
`elicitation/create`. Three options:
- Deprecate the existing tools in favor of P-1 wrappers (cleanest, but
  breaks any agent that depends on the current names).
- Rename existing tools to `_guidance` and reserve `_elicit` for protocol
  use (renaming has migration cost; doc + manifest churn).
- Keep both with clearly separated semantics (least churn; risk of
  ongoing user confusion).

A decision is needed before P-1 enters the manifest — once tools ship,
the namespace is harder to clean up.

### 5.4 Session contract uniformity

Wave 4 introduces three new session shapes (`bisect_session_id`,
`crash_session_id`, `debug_session_id`) and Wave 3 adds
`migration_session_id`. Today only `patch_session` exists. Should zigars:
- (a) define a uniform `Session` envelope (id, kind, preimage, state
  machine, persistence path, validation hooks) that all four new
  sessions extend; or
- (b) treat each as a sui-generis session with shared utility helpers but
  independent shapes?

(a) is more design work upfront but makes the manifest and the docs
simpler. (b) ships faster per session but accumulates surface area.

### 5.5 Public architecture policy (resolved for this roadmap)

The public `zig_architecture_layer` direction is removed. Zigars'
`architecture_guard.zig` remains an internal quality gate for this repository,
not a default policy tool for arbitrary Zig workspaces. Public planner and
reviewer tools may expose architecture-neutral facts such as import cycles,
module surfaces, symbol dossiers, insertion sites, and risk audits. If a
future public architecture-policy surface is needed, it must be an explicit
opt-in profile with labeled project policy, not zigars' own folder/layer rules.

### 5.6 Skills package fate

Several new tools below would benefit from skill packaging. The
`packages/@zigars/skills/` package now has package metadata, a CLI, tests,
README, and a concrete `zigars-development` skill, so P0 #3 is no longer a
"populate or remove the placeholder" decision. The remaining question is
release readiness and client validation. The Wave 3 ergonomics tools
(`zig_symbol_dossier`, `zig_change_risk_audit`, `zig_insertion_sites`) and the
Wave 4 comptime trilogy are obvious candidates for future skill updates after
the corresponding public tools exist.

### 5.7 Comptime trilogy scope

Three sub-tools (`diagnose`, `inspect`/`view`, `quota_probe`) or a unified
`zig_comptime` family with mode subselection? The roots are different —
diagnose is parser-only, inspect needs compiler-eval, quota-probe needs
the command runner. Separate tools keep capability tiers honest; a family
keeps the agent-facing surface compact. Recommend separate tools but a
shared `zigars_prompt_pack` entry that orients agents to all three.

### 5.8 Watch vs. async-job vs. resource-subscribe (P-8 ⇄ P-5)

P-8 `zig_watch` should emit durable event history through the existing
async-job cursor pattern (`zigars_run_events`) and may additionally use MCP
`resources/subscribe` as a notification layer. The Phase 0 decision is that
jobs plus cursored resources are canonical; resource subscription is optional
client push, not the only place events live.

### 5.9 Bisect mutation policy (W-1)

`zig_build_bisect` needs to check out N refs. Options:
- (a) refuse to mutate the working tree; require the user to run zigars
  inside a dedicated git worktree;
- (b) clean-tree gate + checkout (current pattern for any apply-true op);
- (c) shell out to a temp worktree internally per ref.

(c) is safest but adds disk + setup cost per session. (a) is simplest but
pushes setup onto the user. (b) matches the existing apply-gate model. The
architecture-guard probably has opinions; a decision is needed before
W-1's contract solidifies.

### 5.10 Comptime-inspect compiler-eval backend (A-10 / P-9)

The "what does this comptime expression evaluate to?" question has two
backends: synthesize a `@compileLog` probe + sandboxed `zig build` (zigars
can do this today), or wait for a future ZLS/`zig` introspection endpoint.
The probe path works now but is slow and side-effecting. ZLS's
[zigtools/zls#1872](https://github.com/zigtools/zls) tracks compile-time
evaluation requests but ship date is unclear. Recommend probe-now,
plan-for-ZLS-later, but the decision of whether to ship the probe-only
backend (knowing it will be replaced) affects the Wave 4 cost model.

---

## 6. TL;DR

The roadmap collapses to four sequenced bets:

1. **Foundations (Wave 1)** — expose structural facts (`import_cycles`,
   `safety_site_catalog`), ship the protocol `outputSchema`
   substrate, kill the smallest agent-friction items (`test_name_resolve`,
   `zon_dep_sync`, `test_fixture_inventory`). Low risk, fast wins.
2. **Close the dependency gap (Wave 2)** — registry browse + apply-gated
   `build.zig.zon` mutators. This is the largest cross-session signal and
   the most-cited deficit vs. every peer ecosystem.
3. **Land the agent-ergonomics composites (Wave 3)** — `symbol_dossier`,
   `change_risk_audit`, `dependency_migrate`, `bench_regression_gate`.
   Compresses what is today the bulk of an agent's multi-tool reasoning.
4. **Stake the strategic bets (Wave 4)** — comptime trilogy, debug-session
   state, build-bisect, abi/layout, ZLS LSP completions, file-rename,
   watcher. These are the items that define zigars' distinctive surface
   five years out.

Decisions §5.1–§5.10 should be made in roughly the order they will block
implementation — §5.3, §5.9, §5.4 first (they affect Wave 1 / Wave 2
shapes); §5.2, §5.6, §5.7 before Wave 3 starts; §5.10 before Wave 4. §5.5
and §5.8 are resolved by the Phase 0 appendix.
