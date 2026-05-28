# 08 - Exceptional Bar Action Plan

**Date:** 2026-05-28
**Status:** Proposal and research seed.
**Scope:** Follow-up review of [07-exceptional-bar.md](07-exceptional-bar.md).
No code changes are proposed here.

---

## 1. Summary

[07-exceptional-bar.md](07-exceptional-bar.md) has the right strategic
instinct: zigars is stronger technically than it is legible operationally. The
highest-value next work is not another broad capability wave. It is making the
existing engineering visible, supportable, and easier to trust.

The proposal should not be adopted wholesale. Several assumptions are stale
against the current repository, and some strategic ideas expand the trust
surface faster than the project can safely harden it. This document turns the
useful parts into an implementation-ready sequence and frames the rest as deep
research inputs.

Recommended focus:

1. Name the wedge publicly: determinism, evidence tiers, and why zigars is more
   than an agent running shell commands.
2. Make failures forensic: request correlation, audit transcripts, startup
   phase timings, and stronger error resolutions.
3. Make trust explicit at connection time: workspace boundary, subprocess
   classes, apply gates, output limits, and release provenance.
4. Upgrade Zig-distinctive surfaces where evidence can improve: comptime,
   memory/layout, ABI, cross-target, and dependency workflows.
5. Research platform expansion before committing to plugin, LSP, or library
   APIs.

---

## 2. Current-State Corrections

These corrections should be applied before using `07` as a roadmap input.

| Claim in `07` | Correction |
|---|---|
| Dependency lifecycle tooling is still roadmap-only. | Current generated docs already list `zig_zon_dep_sync`, `zig_deps_add`, `zig_deps_remove`, `zig_deps_upgrade`, `zig_pkg_search`, `zig_pkg_info`, `zig_pkg_versions`, `zig_pkg_readme`, and `zig_dependency_migrate`. |
| Several agent-ergonomics primitives are unshipped. | Current generated docs already list `zig_import_cycles`, `zig_test_name_resolve`, `zig_test_fixture_inventory`, `zig_test_for_symbol`, `zig_module_surface`, `zig_symbol_dossier`, `zig_change_risk_audit`, and `zig_insertion_sites`. |
| Output schemas are future-only. | `outputSchema` projection exists for pilot/shared envelope tools; the remaining work is broad coverage and contract tests, not first introduction. |
| Patch sessions have no durable evidence. | Patch sessions already persist preimage artifacts and history records. The remaining gap is crash recovery across preview/apply/history transitions. |
| README presents launchers with equal weight. | README already names Bun as the preferred launcher and gives it first placement, though the page can still be reduced and made more guided. |
| `zig_format` inherits a generic description. | Its manifest description is specific: it returns preview by default and writes only with `apply=true`. A description audit is still useful, but that example is stale. |
| `examples/` includes `http-smoke.sh`. | The current examples directory contains client config examples and `tool-calls.jsonl`; no `http-smoke.sh` is present. |

---

## 3. Adopt

### 3.1 Public Wedge

Ship this first. It is low risk and high leverage.

- Add `docs/determinism.md`.
- Add `docs/why-zigars.md`, promoted from the peer-scan strengths list.
- Add a short README section explaining evidence tiers and routing decisions.
- Link these from `zigars_schema`, `zigars_tool_index`, and `zigars_doctor`
  outputs where that does not bloat normal tool responses.

The determinism contract should be precise:

- No LLM calls inside server tools.
- Tool outputs are functions of inputs, workspace state, configured toolchain,
  optional backend versions, and documented external command behavior.
- Advisory, parser-backed, compiler-backed, ZLS-backed, ZLint-backed, and
  zwanzig-backed results are labeled distinctly.
- Source writes are preview-first and require `apply=true`.
- Artifact and patch evidence includes hashes, provenance, limitations, and
  verification routes.

Avoid over-claiming byte-identical output for every tool until timestamps,
ordering, backend output, and artifact paths have been audited. For now, the
contract should say which fields are stable and which fields are intentionally
runtime-specific.

### 3.2 Guided Onboarding

Add a small narrative path:

- `docs/getting-started.md`: install, configure a client, call
  `zigars_doctor`, call `zigars_workspace_info`, use `zigars_next_action`, and
  preview one source edit without applying it.
- `examples/README.md`: explain each client config and `tool-calls.jsonl`.
- README trim: keep the preferred path prominent and move alternate launchers
  into a compact subsection.

The goal is not more docs. The goal is one obvious path through the existing
docs.

### 3.3 Forensic Operation

Implement these as product features, not just logging polish:

- Request correlation IDs from inbound JSON-RPC requests through stderr logs,
  structured errors, tool result metadata, and observability counters.
- Opt-in `--audit-log <path>` JSONL transcript of inbound requests and outbound
  responses. Keep it off by default, redact nothing unless a redaction policy is
  explicit, and document the privacy implication clearly.
- Startup phase instrumentation for config parse, workspace resolution,
  manifest/tool registration, ZLS startup, and transport startup.
- `docs/perf.md` with startup and tool latency budgets once measurement exists.
- Error-resolution catalog keyed by stable error code, starting with
  bootstrap, MCP adapter, workspace path, backend probe, and ZLS startup errors.

This is the work that makes "zigars hung" or "ZLS is disabled" diagnosable
from one evidence bundle.

### 3.4 Trust Disclosure

Add a connection-time trust manifest to the `initialize` result or a clearly
linked resource if the raw initialize payload becomes too large.

Include:

- workspace root and cache root;
- path policy summary;
- source-write policy and `apply=true` requirement;
- subprocess classes: Zig, ZLS, optional lint/static-analysis/profiling
  backends, runtime diagnostic tools, and package shim downloads;
- default output and body limits;
- HTTP local-only posture;
- optional backend status or a pointer to `zigars_doctor`;
- audit-log status when enabled.

Also add Zig version preflight:

- `zigars_doctor` should compare `zig version` against `build.zig.zon`
  `minimum_zig_version`.
- Startup should fail fast or emit a structured startup warning when the Zig
  version is incompatible. The exact behavior needs compatibility policy, but
  silent mismatch should end.

### 3.5 Release Provenance

The npm shim currently verifies the selected archive against a checksum file
downloaded from the same GitHub release. Keep that behavior, but research and
prototype GitHub artifact attestation verification before making it mandatory.

Target outcome:

- Installer verifies checksum and, when public GitHub attestations are
  available, verifies provenance for the checksum subject.
- `docs/trust.md`, `docs/distribution.md`, and package README explain exactly
  what is verified and what remains trust-on-first-use.
- If attestation verification is unavailable on a host or repository, the
  installer returns an explicit warning or policy-controlled failure rather than
  pretending the guarantee exists.

---

## 4. Rewrite Before Adopting

### 4.1 Zig-Distinctive Surface

The strategic point is correct: zigars should win on Zig-specific leverage, not
only generic quality tooling. The implementation framing needs updating because
many of the named tools now exist.

Research should classify each Zig-distinctive area by evidence upgrade path:

| Area | Current direction | Research question |
|---|---|---|
| Comptime | `zig_comptime_diagnose` exists; inspect/view/quota remain design space. | Can compiler-backed temp programs expose useful comptime values without becoming code generation or unsafely executing project build scripts? |
| Memory and allocators | Leak triage, memory layout, unsafe audit, and safety-site tools exist or are listed. | Which results can move from advisory text scan to parser-backed or compiler-backed evidence? |
| ABI and layout | `zig_abi_layout_diff` is advisory-tier. | What minimal compiler probe can verify layout without requiring target execution? |
| Cross-target | `zig_targets`, `zig_target_matrix_plan`, `zig_cross_smoke`, and QEMU planning exist separately. | Is there a useful compound entry point, or should existing tools just get better routing docs? |
| Dependencies | Direct mutation and provider metadata tools exist. | Which registry/provider integrations can be deterministic, offline-aware, and honest about trust basis? |

Do not simply move every Zig-distinctive proposal earlier. Promote only the
ones with a clear evidence basis and bounded backend cost.

### 4.2 Session Recovery

Do not describe the problem as "no WAL." Existing patch sessions already write
preimage content and append history. The remaining risk is narrower:

- crash after one or more file writes but before history append;
- crash after artifact registry update but before related artifact write, or
  vice versa;
- stale recovery record after user edits files manually;
- partially closed long-running session envelopes.

Start with a recovery audit:

1. Enumerate all multi-step workspace mutations and artifact writes.
2. Mark which already have preimage identity, history, or idempotent writes.
3. Add a recovery record only where there is an actual crash window.
4. Prefer a shared session envelope from
   [06-phase-00-baseline-reconciliation.md](06-phase-00-baseline-reconciliation.md)
   over a separate WAL design.

### 4.3 Tool Description Quality

A manifest-level quality gate is useful, but not the gate described in `07`.
Length and "has a verb" checks are weak proxies.

Use reviewable contract rules instead:

- description states the output class or user-visible result;
- description states write/apply behavior when relevant;
- plan policy states exact command, dynamic command, ZLS request,
  apply-gated mutation, workspace artifact, pure analysis, or unsupported;
- risky tools have risk metadata matching behavior;
- static-analysis tools have capability tier and verification route where
  applicable.

Back this with targeted tests over manifest metadata rather than a generic
minimum character count.

---

## 5. Defer

These may be valuable later, but they should not lead the next phase.

### 5.1 Plugin Manifest

An out-of-tree plugin contract would expand the trust boundary, determinism
contract, compatibility surface, and support burden. Defer until these exist:

- stable output schemas for core result families;
- audit-log and capability-disclosure support;
- versioned tool registration metadata;
- clear policy for third-party command execution and workspace access;
- at least one real adopter that cannot be served by core tools or skills.

### 5.2 LSP Server

Zig already has ZLS. A separate zigars LSP should be rejected unless research
finds a non-overlapping editor contract that cannot be served through ZLS,
MCP, generated artifacts, or a thin CLI.

### 5.3 Full Parallel Dispatch

Cancellation should come before broad concurrency. The server currently handles
messages sequentially, and cancelled notifications are not plumbed to in-flight
work. A safe path is:

1. cancellation tokens;
2. subprocess/ZLS cancellation where supported;
3. async job/resource model for long-running work;
4. limited concurrent read-only tools only after shared caches and ZLS document
   state are audited.

### 5.4 Multi-Workspace Team Config

`.zigars/team.json` is premature without adoption evidence. Team-shared
coverage baselines and fuzz corpora are plausible, but the first research step
is user workflow discovery, not a config format.

### 5.5 Public Library Extraction

The parser-backed catalog is a real asset, but publishing `@zigars/parser` or a
stable Zig library API too early would freeze internal seams. First research the
boundary:

- Which domain modules are already transport-free?
- Which parser-backed outputs are stable enough to version?
- Which consumers exist: CI, editors, other Zig tools, or only zigars itself?
- Would a CLI cover most non-MCP use cases with less API commitment?

---

## 6. 90-Day Sequence

### Phase 1 - Make The Product Legible

1. `docs/determinism.md`.
2. `docs/why-zigars.md`.
3. README evidence-tier and install-path pass.
4. `docs/getting-started.md`.
5. `examples/README.md`.

Validation:

```sh
zig build docs-check json-check
```

### Phase 2 - Make Failures Diagnosable

1. Request correlation ID through MCP adapter, stderr logs, tool outputs, and
   observability state.
2. Opt-in `--audit-log <path>` transcript.
3. Error-resolution catalog for bootstrap/adapters/workspace/backend errors.
4. Startup phase timings and first `docs/perf.md` budget table.

Validation should include unit tests for request-id propagation, transcript
shape, disabled transcript behavior, and stderr/stdout separation.

### Phase 3 - Make Trust Explicit

1. Initialize-time trust manifest or linked trust resource.
2. Zig version preflight in `zigars_doctor` and startup.
3. npm shim attestation verification prototype.
4. Trust docs update covering checksum, attestation, and remaining TOFU limits.

Validation should include npm shim tests, initialize response contract tests,
and docs checks.

### Phase 4 - Upgrade Zig-Specific Evidence

Use the research in section 7 to pick one or two narrow upgrades. Prefer
promotion of existing advisory tools to stronger evidence over adding another
large tool family.

Good candidates if research validates them:

- compiler-probed ABI/layout verification;
- bounded comptime value inspection;
- better allocator/leak evidence normalization;
- a compound cross-target smoke workflow only if current tools require too many
  manual steps in real use.

---

## 7. Deep Research Agenda

Use this as the starting checklist for finding additional opportunities beyond
`07`.

### 7.1 Product And Positioning Research

- Compare zigars' public first five minutes with current MCP servers for Go,
  Rust, TypeScript, Python, and package ecosystems.
- Identify which projects explain trust, determinism, and evidence tiers best.
- Look for language-tool products that make a strong "why not just shell?"
  argument.
- Produce a short list of positioning patterns zigars should copy or avoid.

Output:

- ranked positioning opportunities;
- proposed README/doc information architecture;
- examples of claims that are defensible for zigars and claims to avoid.

### 7.2 Operational Research

- Study how language servers and MCP servers expose request logs, trace IDs,
  cancellation, startup telemetry, and performance budgets.
- Determine which fields belong in every tool result versus only observability
  and audit outputs.
- Evaluate audit-log privacy defaults and redaction options.

Output:

- request-correlation schema;
- audit transcript JSONL schema;
- cancellation design sketch;
- startup and p99 measurement plan.

### 7.3 Trust And Supply-Chain Research

- Prototype GitHub attestation verification from the npm shim on Node and Bun.
- Check whether verification can be offline, cached, or policy-controlled.
- Compare GPG-signed checksums, Sigstore, GitHub attestations, npm provenance,
  and MCPB signing for this project.
- Define exact release claims for public, private, and missing-attestation
  releases.

Output:

- installer trust matrix;
- recommended default installer policy;
- docs wording for checksum and attestation guarantees;
- fallback behavior when attestations are unavailable.

### 7.4 Zig-Specific Capability Research

- Test compiler-probe approaches for comptime inspection, layout, ABI, and
  target metadata.
- Identify which probes execute project code, build scripts, or arbitrary
  comptime logic, and classify their risk.
- Compare parser-backed, compiler-backed, and command-backed evidence for each
  proposed Zig-distinctive tool.

Output:

- candidate tools to promote from advisory to stronger evidence;
- backend risk classification;
- fixture set for tricky Zig syntax and target/layout cases;
- recommendation for the next one or two Zig-distinctive investments.

### 7.5 Platform Research

- Interview or simulate consumers: CI, editor extension, release bot, other Zig
  tool, and agent-only user.
- Determine whether they need MCP, CLI, library, generated artifacts, or skills.
- Test whether a thin CLI over existing use cases satisfies CI and shell-only
  users without creating a stable library API.

Output:

- platform demand map;
- CLI versus library decision;
- explicit reasons to defer or pursue plugin registration;
- compatibility risks for any public extension contract.

---

## 8. Decision Rules

Use these rules when turning research into roadmap items.

- Prefer making existing guarantees visible before adding new surface.
- Prefer stronger evidence for existing Zig-specific tools over new advisory
  tools.
- Do not add plugin or multi-workspace contracts without a real adopter.
- Do not make byte-identical determinism claims until volatile fields are
  cataloged.
- Do not add an LSP server unless it has a crisp non-ZLS job.
- Do not add broad concurrency until cancellation and shared-state safety are
  proven.
- Keep architecture-neutral public tooling. Do not reintroduce a default
  `zig_architecture_layer` public surface.

---

## 9. Proposed Next Step

Start with Phase 1 docs because it is cheap, unblocks contributor alignment, and
will sharpen the language used by later operational and trust work. In parallel,
run the research agenda sections on supply-chain verification and request
forensics, because those are the highest-risk implementation areas.
