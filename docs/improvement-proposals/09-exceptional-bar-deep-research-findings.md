# Exceptional Bar Deep Research Findings

Date: 2026-05-28
Status: research findings
Scope: follow-up research for
[08-exceptional-bar-action-plan.md](08-exceptional-bar-action-plan.md),
section 7.

## 1. Method

This document consolidates five read-only research subagents, one for each item
in the deep research agenda:

- 7.1 Product and positioning research.
- 7.2 Operational research.
- 7.3 Trust and supply-chain research.
- 7.4 Zig-specific capability research.
- 7.5 Platform research.

The subagents used local repository evidence and current external sources. I
also cross-checked the highest-risk external claims against primary sources:
MCP 2025-11-25, LSP 3.17, OpenTelemetry, GitHub artifact attestations, npm
provenance, SLSA, Zig 0.16.0 docs, `gopls` MCP docs, MCP Registry docs, and
MCPB docs.

This is intentionally not an implementation plan. The implementation plan should
come after the owner chooses which research findings become roadmap items.

## 2. Executive Findings

1. The strongest product opportunity is not a new feature. It is making zigars'
existing trust and evidence posture obvious in the first five minutes. Lead with
"structured Zig evidence instead of shell text", then show a short verification
walkthrough.

2. Operational work should add correlation and auditability without polluting
every tool's semantic result. Put request correlation in MCP result `_meta`,
keep per-tool facts in `structuredContent`, and keep timestamps, payload hashes,
redactions, phase timings, and percentiles in observability or audit outputs.

3. The npm installer should keep SHA-256 verification mandatory and add GitHub
attestation verification as opportunistic-but-authoritative by default. An
invalid attestation should fail closed. Missing attestation should be policy
controlled.

4. The best Zig-distinctive evidence upgrade is ABI and memory layout. Generated
compiler probes can provide target-specific `@sizeOf`, `@alignOf`,
`@offsetOf`, and `@bitOffsetOf` evidence without running target binaries. Importing
project modules still executes arbitrary comptime logic, so that mode needs a
clear risk label.

5. A thin public CLI should precede any library extraction, plugin API, or LSP
server. CI, release bots, and shell-only users need stable JSON artifacts and
exit codes more than a public Zig library API.

## 3. Priority Backlog

### Adopt Now

1. Rewrite the README opening around a first-five-minutes path:
   install, `zigars_workspace_info`, `zigars_doctor {"probe_backends":false}`,
   one read-only insight, one preview-only edit, and one trust report.

2. Add a compact "How to trust a result" block that explains command-backed,
   ZLS-backed, parser-backed, source-scan-backed, advisory, external-backend,
   curated fallback, and release-evidence labels.

3. Add request correlation in result `_meta` and stderr diagnostics using a
   reverse-DNS key such as `dev.zigars/correlation`.

4. Add opt-in audit JSONL with metadata or redacted mode as the default. Full
   raw transcript mode should require an explicit flag.

5. Prototype npm shim attestation verification with policy modes:
   `strict`, `verify-if-available`, and `checksum-only`.

6. Promote `zig_abi_layout_diff` and `zig_memory_layout` with optional
   compiler-backed target measurements.

7. Prototype a thin CLI over existing use cases for `doctor`, workspace facts,
   CI ingest, JUnit, coverage budget, docs drift, release evidence, and artifact
   index.

### Defer

- Third-party plugin registration or out-of-tree extension contracts.
- A public stable Zig library API.
- A zigars LSP server that overlaps ZLS.
- Full broad parallel dispatch before request cancellation and shared-state
  safety are proven.
- Full project comptime value inspection unless the user explicitly opts into
  project-code execution risk.

## 4. Product And Positioning Research

### Findings

Zigars already has stronger trust substance than most language MCP peers, but
that substance is buried behind install variants and a very large capability
catalog. The README already says zigars is deterministic, not an AI code
generator, and source writes require `apply=true`. The trust docs already cover
no-shell command execution, bounded output, workspace boundaries, source-write
gates, provenance, risk audit, and the important limitation that zigars is not
an OS sandbox.

The best public first-five-minutes pattern is `gopls mcp`: concise setup,
attached versus detached mode, clear instructions, and a security section that
states what the server may read, execute, write, download, cache, and report.
Zigars can copy that shape while being more explicit about evidence tiers.

The best "why not shell?" pattern came from TypeScript MCP tooling: shell can
run commands, but language services can return typed structural results and
preview edits across many files. For zigars, the defensible version is:
shell can run `zig build`, but zigars returns structured diagnostics, command
metadata, parser-backed facts, ZLS-backed code intelligence, preview diffs,
confidence labels, and next verification steps.

### Ranked Opportunities

1. Put the wedge above the fold:
   "zigars gives agents compiler-, ZLS-, parser-, and backend-backed Zig
   evidence instead of asking them to infer from shell text."

2. Replace the current broad first call list with a guided 60-second
   verification path. Each call should say what it proves.

3. Extract evidence tiers into a short docs page or README section, then link
   to the existing generated tool index for full catalog detail.

4. Add a trust boundary section that follows the `gopls` style: reads, writes,
   command execution, cache writes, network behavior, telemetry, and unsupported
   sandbox claims.

5. Use language-service positioning only where the evidence exists. Avoid
   claiming complete semantic refactoring unless ZLS or compiler evidence proves
   the specific operation.

### Proposed README And Docs IA

README should become:

1. What zigars is: deterministic Zig MCP workbench, no LLM inside, no AI code
   generation.
2. Why not shell: structured evidence, typed results, evidence tiers,
   preview-gated edits.
3. Quickstart: one preferred Bun path and one Node fallback.
4. First five minutes: exact calls and what each proves.
5. Trust model: workspace boundary, subprocess classes, `apply=true`, not an OS
   sandbox.
6. Capability map: grouped summary, then link to
   [tool-index.generated.md](../tool-index.generated.md).
7. Install alternatives: npm shim, MCPB, direct binary.
8. Status, versions, and support matrix.

Supporting docs worth adding or extracting:

- `docs/getting-started.md`: narrative walkthrough.
- `docs/why-zigars.md`: shell versus structured Zig evidence.
- `docs/determinism.md`: deterministic contract and explicit non-contracts.
- `docs/evidence-tiers.md`: the evidence labels currently spread across the
  README, trust docs, and tool docs.

### Claims To Use

- "No LLM calls run inside zigars server tools."
- "Source writes are preview-first and require `apply=true`."
- "Command-backed tools execute argv vectors directly, without a shell."
- "Results are labeled by evidence basis: parser, command/compiler, ZLS,
  optional backend, source scan, curated fallback, or advisory."
- "The workspace is the safety boundary; zigars is not an OS sandbox."
- "Release claims should cite clean-tree release evidence for the exact commit."

### Claims To Avoid

- "Fully deterministic" without qualifying toolchain, timestamps, backend
  versions, filesystem state, and runtime-specific fields.
- "Semantically complete refactors" unless the specific operation is backed by
  ZLS or compiler evidence.
- "Secure sandbox" or "safe to run untrusted projects."
- "Complete Zig documentation browser."
- "Verified optional backend support" without exact backend conformance
  evidence.
- "Better than shell" as a blanket claim.

### Source Basis

- Local: [README.md](../../README.md), [docs/trust.md](../trust.md),
  [docs/tools.md](../tools.md), [docs/tool-index.generated.md](../tool-index.generated.md).
- External:
  [gopls MCP](https://go.dev/gopls/features/mcp),
  [ts-mcp-server](https://github.com/andyliner13/ts-mcp-server),
  [rust-analyzer-mcp](https://github.com/zeenix/rust-analyzer-mcp),
  [mcp-pyright](https://github.com/daedalus/mcp-pyright),
  [Context7](https://github.com/upstash/context7),
  [MCP tools 2025-11-25](https://modelcontextprotocol.io/specification/2025-11-25/server/tools).

Confidence: high for doc shape and claim discipline; medium for peer ecosystem
coverage because language MCP servers are changing quickly.

## 5. Operational Research

### Findings

Zigars already returns structured JSON values and mirrors them into MCP
`structuredContent` plus text fallback. Command-backed tools already expose
useful operational fields such as `cwd`, `argv`, `timeout_ms`, `duration_ms`,
termination status, and truncation flags.

The gaps are correlation, auditability, cancellation, startup phase timing, and
real percentiles. Existing observability tracks process-local counters and
avg/max/last latency, but p50/p95/p99 require raw bounded samples or histograms.

MCP 2025-11-25 supports structured tool results and optional tool
`outputSchema`. It also defines cancellation through
`notifications/cancelled`. LSP 3.17 has the same important operational lesson:
cancellation is advisory, request IDs can be integers or strings, and tracing
should not be confused with semantic result data.

### Request Correlation Schema

Put correlation in MCP result `_meta`, not in every semantic
`structuredContent` object.

```json
{
  "_meta": {
    "dev.zigars/correlation": {
      "schema_version": 1,
      "mcp_request_id": { "type": "integer|string|null", "value": "42" },
      "mcp_method": "tools/call",
      "tool_name": "zig_build",
      "trace_id": "32 lowercase hex chars",
      "span_id": "16 lowercase hex chars",
      "parent_span_id": null,
      "tool_call_id": "zigars-tc-000000000001"
    }
  }
}
```

Use OpenTelemetry-style `trace_id` and `span_id` because logs formally support
trace context fields. Do not add timestamps or duration to every semantic result
unless that tool already owns runtime evidence.

### Audit Transcript JSONL Schema

Audit should be disabled by default and written only when explicitly enabled.
The default enabled mode should be `metadata` or `redacted`, not `full`.

```json
{
  "schema_version": 1,
  "ts_unix_ms": 1779970000000,
  "event": "request_received|response_sent|notification_received|tool_started|tool_finished|cancel_requested|startup_phase",
  "direction": "inbound|outbound|internal",
  "transport": "stdio|http",
  "mcp_method": "tools/call",
  "mcp_request_id": { "type": "string", "value": "abc" },
  "correlation": { "trace_id": "...", "span_id": "...", "tool_call_id": "..." },
  "tool_name": "zig_build",
  "duration_ms": 37,
  "ok": true,
  "is_error": false,
  "payload": { "mode": "metadata|redacted|full", "sha256": "...", "size_bytes": 1234 },
  "redactions": [{ "path": "params.arguments.env.API_TOKEN", "reason": "secret_key" }]
}
```

Privacy defaults should redact or hash source payloads, access tokens, auth
headers, cookies, session IDs, passwords, private keys, connection strings,
secret-looking environment variables, stdout/stderr bodies, and absolute
home/cache paths where possible.

### Fields In Every Result

Every tool result metadata should include:

- `dev.zigars/correlation.schema_version`
- normalized `mcp_request_id`
- `trace_id`
- `span_id`
- `tool_call_id`
- `tool_name` when applicable

Every structured error should keep the existing error contract and attach
correlation metadata rather than duplicating operational fields in the payload.

Command-backed results should keep command-specific runtime fields:
`duration_ms`, `timeout_ms`, `term`, `argv`, bounded output tails, and
truncation flags.

Audit-only or observability-only fields should include timestamps, phase
timings, p50/p95/p99, full request parameters, full response bodies, full
stdout/stderr, client info, connection details, redaction decisions, and backend
internals.

### Cancellation Design

Implement `notifications/cancelled` for normal MCP requests by normalized
JSON-RPC request ID. The internal path should be:

1. Request context owns cancellation token.
2. Long-running use cases check the token cooperatively.
3. Command-backed calls can terminate subprocesses where safe.
4. ZLS-backed calls map to LSP `$/cancelRequest` where supported.
5. Unknown, completed, or uncancellable requests are ignored but audited.

Task-augmented MCP execution should be treated separately. If zigars adopts MCP
tasks, use `tasks/cancel` for task execution rather than overloading
`notifications/cancelled`.

Write safety rule: cancellation before an `apply=true` write means no write.
Cancellation during an atomic apply should finish or fail with recovery
evidence; it should not leave partially applied source edits without a recorded
preimage and recovery path.

### Startup And P99 Measurement Plan

Instrument monotonic startup phases:

- config parse
- workspace resolution
- runtime state init
- manifest and tool registration
- resource and prompt registration
- ZLS spawn and initialize, when configured
- transport bind
- server ready
- first `initialize`

For latency percentiles, add bounded raw samples or histograms per method, tool,
and backend class. Do not publish p99 until sample counts are high enough to be
meaningful. Until then, report max, p95 if available, and sample count.

### Source Basis

- Local: [src/adapters/mcp/result.zig](../../src/adapters/mcp/result.zig),
  [src/app/usecases/usecase_support.zig](../../src/app/usecases/usecase_support.zig),
  [src/app/usecases/runtime_ux/workflows.zig](../../src/app/usecases/runtime_ux/workflows.zig),
  [docs/tools.md](../tools.md).
- External:
  [MCP tools 2025-11-25](https://modelcontextprotocol.io/specification/2025-11-25/server/tools),
  [MCP cancellation 2025-11-25](https://modelcontextprotocol.io/specification/2025-11-25/basic/utilities/cancellation),
  [MCP tasks 2025-11-25](https://modelcontextprotocol.io/specification/2025-11-25/basic/utilities/tasks),
  [LSP 3.17](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/),
  [OpenTelemetry logs](https://opentelemetry.io/docs/specs/otel/logs/data-model/),
  [OpenTelemetry metrics](https://opentelemetry.io/docs/specs/otel/metrics/data-model/),
  [OWASP logging cheat sheet](https://cheatsheetseries.owasp.org/cheatsheets/Logging_Cheat_Sheet.html).

Confidence: high for local gaps and schema direction; medium for MCP task
adoption because tasks are newer and may not match the currently pinned MCP Zig
dependency.

## 6. Trust And Supply-Chain Research

### Findings

The npm shim currently downloads `zigars-checksums.txt`, verifies the selected
archive SHA-256, extracts the binary, and records install metadata. That is a
solid baseline for integrity against accidental corruption, but it does not
authenticate release origin if an attacker controls both the archive and the
checksum asset.

The release workflow already has `id-token: write` and `attestations: write`,
and uses `actions/attest-build-provenance` with `subject-checksums:
dist/assets/zigars-checksums.txt`. Important correction: `subject-checksums`
attests the artifacts listed in the checksum file, not the checksum file itself.
Installer verification should verify the selected archive subject, then
separately verify its SHA-256 against the checksum file.

There is a naming/release-publication risk to resolve before making public
claims. The local Git remote is `https://github.com/oly-wan-kenobi/zigar.git`,
while package metadata and docs point to
`https://github.com/oly-wan-kenobi/zigars.git`. Public release and attestation
claims need the final public repository and tag names to be consistent.

The trust subagent reported a read-only prototype of invoking
`gh attestation verify` through both Node and Bun with `shell:false`. Both
runtimes can spawn the verifier. Current private release checks returned
unavailable/404-style results, consistent with missing or inaccessible
attestations.

### Trust Matrix

| Mechanism | Protects | Offline | Fit | Gaps |
|---|---|---:|---|---|
| SHA-256 checksum file | Archive integrity against listed digest | Yes, after checksum download | Mandatory baseline | Weak if release assets and checksum are both compromised |
| GPG-signed checksums | Authenticates checksum file to pinned key | Yes | Good human/manual fallback | Key distribution and rotation burden |
| GitHub artifact attestations | Binds archive digest to repo, workflow, ref, and commit | Online by default; offline with bundle/root | Best default release provenance signal | Workflow compromise can still produce valid attestations |
| Sigstore/cosign blob signing | Provider-neutral blob signature and provenance | Yes with bundle/root | Useful later if GitHub independence matters | More tooling surface than current workflow |
| npm provenance | Binds npm package tarball to source/build workflow | Registry mediated | Use for `@zigars/mcp` publication | Does not prove downloaded GitHub binary |
| MCPB signing | Signs `.mcpb` bundle | Potentially | Useful for Claude Desktop path | Public enforcement and certificate policy are less clear |
| MCP Registry `fileSha256` | Pins package file hash in metadata | Yes once metadata is trusted | Useful for MCPB registry metadata | Integrity only, not build provenance |

### Recommended Installer Policy

Default policy: checksum mandatory, attestation opportunistic-but-authoritative.

Behavior:

1. Always download `zigars-checksums.txt`.
2. Always verify selected archive SHA-256 before extraction.
3. If a verifier is available, run `gh attestation verify` against the selected
   archive, pinned repository, release workflow, tag ref, predicate type, and
   self-hosted-runner policy.
4. If verification runs and fails for an official public release, fail
   installation.
5. If `gh` is missing or attestations are unavailable, continue only under the
   default `verify-if-available` policy with a clear stderr warning and cache
   metadata recording `attestation: unavailable`.
6. Add explicit policy modes:
   - `strict`: fail if verifier, trusted root, bundle, or valid attestation is
     unavailable.
   - `verify-if-available`: default; fail invalid attestations, warn on missing
     verification.
   - `checksum-only`: explicit escape hatch; never bypass SHA-256.

Suggested command shape for strict public releases:

```sh
gh attestation verify <archive> \
  --repo oly-wan-kenobi/zigars \
  --predicate-type https://slsa.dev/provenance/v1 \
  --signer-workflow github.com/oly-wan-kenobi/zigars/.github/workflows/release.yml \
  --source-ref refs/tags/v<version> \
  --deny-self-hosted-runners \
  --format json
```

### Offline And Cache Strategy

Cache these beside `install.json`:

- archive SHA-256
- checksum file SHA-256
- attestation verification status
- verified repository, workflow, source ref, source digest, predicate type
- attestation bundle digest/path when available
- trusted root generation timestamp

Offline verification is viable only when the installer has the archive, checksum
file, attestation bundle, and trusted roots. Cached roots should be refreshed
when online and treated as stale after a policy window such as 90 days.

### Release Claim Wording

Public release with attestations:

> Release archives were built by the GitHub tag workflow from commit `<sha>`.
> Each archive SHA-256 is listed in `zigars-checksums.txt`; the archives are
> covered by GitHub artifact attestations for the `release.yml` workflow and can
> be verified with `gh attestation verify`. Attestations prove build provenance
> and artifact integrity, not that the code is vulnerability-free.

Private release:

> This release was produced from commit `<sha>` and includes SHA-256 checksums.
> GitHub public provenance attestations are not claimed for this private
> repository release. Treat the checksum file as the integrity record unless
> your organization has private GitHub attestation verification configured.

Missing-attestation/manual release:

> This release includes SHA-256 checksums but no GitHub provenance attestation.
> Verify the archive against `zigars-checksums.txt`; do not treat this release
> as workflow-provenanced.

MCPB:

> MCPB bundles include the zigars binary and are checked by
> `zigars-mcpb-checksums.txt` or registry `fileSha256`. Unless a production
> MCPB signature or GitHub attestation is explicitly listed, checksum
> verification is the only published integrity guarantee for MCPB files.

### Fallbacks

- Missing checksum: fail closed.
- Checksum mismatch: fail closed, delete temp archive, do not extract.
- Attestation invalid: fail closed.
- Attestation unavailable: warn and continue only in `verify-if-available` or
  `checksum-only`.
- Offline without cached bundle/root: strict fails; default warns and uses
  checksum only.
- Private repo: do not claim public attestations without configured private
  attestation verification.

### Source Basis

- Local:
  [packages/@zigars/mcp/src/install.ts](../../packages/@zigars/mcp/src/install.ts),
  [packages/@zigars/mcp/src/checksums.ts](../../packages/@zigars/mcp/src/checksums.ts),
  [.github/workflows/release.yml](../../.github/workflows/release.yml),
  [docs/trust.md](../trust.md),
  [docs/release.md](../release.md).
- External:
  [GitHub artifact attestations](https://docs.github.com/en/enterprise-cloud@latest/actions/concepts/security/artifact-attestations),
  [GitHub offline attestation verification](https://docs.github.com/en/actions/how-tos/secure-your-work/use-artifact-attestations/verify-attestations-offline),
  [gh attestation verify](https://cli.github.com/manual/gh_attestation_verify),
  [actions/attest](https://github.com/actions/attest),
  [npm provenance](https://docs.npmjs.com/viewing-package-provenance/),
  [npm provenance generation](https://docs.npmjs.com/generating-provenance-statements/),
  [SLSA levels](https://slsa.dev/spec/v1.0/levels),
  [Sigstore cosign verification](https://docs.sigstore.dev/cosign/verifying/verify/),
  [MCPB docs](https://claude.com/docs/connectors/building/mcpb),
  [MCP Registry package types](https://modelcontextprotocol.io/registry/package-types).

Confidence: high for checksum/attestation direction; medium for MCPB signing
semantics because ecosystem-level policy is still less settled than GitHub and
npm provenance.

## 7. Zig-Specific Capability Research

### Findings

The best candidate for promotion from advisory to stronger evidence is
ABI/layout. `zig_abi_layout_diff` and `zig_memory_layout` already exist, but
their current behavior is advisory/probe-plan oriented. Zig 0.16.0 exposes the
needed compile-time primitives for stronger evidence: `@sizeOf`, `@alignOf`,
`@offsetOf`, and `@bitOffsetOf`.

The key risk boundary is not "compiler probe" versus "no compiler probe". The
key boundary is whether the probe imports project modules or runs `build.zig`.

Direct compiler probes such as `zig build-obj <probe>.zig -target ... -fno-emit-bin`
can measure generated standalone types without running target binaries or
executing `build.zig`. If the probe imports project modules, Zig will evaluate
imported comptime logic. `zig ast-check` does not provide semantic type layout
evidence and, in the subagent probe, did not evaluate imported comptime logic.

`zig build --help` executes `build.zig` to discover project-specific options.
That makes it real evidence, but it is a higher-risk operation than source
parsing or direct compiler metadata commands.

### Candidate Tool Promotions

| Tool | Promotion | Rationale |
|---|---|---|
| `zig_abi_layout_diff` | compiler-backed, medium/high confidence | Strongest Zig-specific opportunity; target-specific layout is hard for agents to infer from source text |
| `zig_memory_layout` | parser-backed candidate catalog plus optional compiler-backed measurements | Cheap discovery first, measured size/align/offset on opt-in targets |
| `zig_targets` / target matrix tools | command-backed metadata | `zig targets` and `--show-builtin -target` provide authoritative target facts without project code |
| `zig_comptime_diagnose` | parser-only default, optional generated-snippet compiler probe | Full project imports are useful but riskier |
| `zig_build_options` / `zig_build_targets` | keep explicit risk labels | `zig build --help` executes `build.zig`; do not silently promote |

### Backend Risk Classification

| Backend approach | Evidence strength | Executes project code | Executes build script | Risk |
|---|---:|---:|---:|---|
| Source text scan | Low/medium advisory | No | No | None/low |
| `std.zig.Ast` parser-backed tools | High syntax evidence | No | No | Low |
| `zig ast-check` | High syntax/AstGen evidence | No observed comptime eval | No | Low backend |
| `zig targets`, `zig env`, `zig version` | Authoritative command metadata | No | No | Low backend |
| `zig build-exe --show-builtin -target ...` | Authoritative target builtin metadata | No project imports needed | No | Low backend |
| Generated standalone compiler probe | Strong compiler evidence | Only generated comptime | No | Low/medium |
| Compiler probe importing project modules | Strong semantic/layout evidence | Yes, arbitrary comptime/import logic | No | Medium |
| `zig test --test-no-exec` | Strong compile/test-discovery evidence | Comptime/test compilation only | No, unless invoked through build | Medium |
| `zig build --help` | Real build option/step evidence | Yes | Yes | Medium, operationally high |
| `zig build test` / `zig test` | Runtime validation | Yes | `zig build` yes | Medium/high |

### Fixture Set

Add a fixture set separate from the existing syntax fixtures:

- `layout_probe_basic.zig`: extern/packed structs, unions, enums, sentinel
  pointers, explicit alignment, field padding.
- `layout_probe_targets.json`: expected measurements for `x86_64-linux`,
  `x86-linux`, `aarch64-linux`, `powerpc-linux`, and `wasm32-freestanding`.
- `packed_bit_offsets.zig`: `@offsetOf` versus `@bitOffsetOf` for
  non-byte-aligned packed fields.
- `zig_016_layout_edges.zig`: packed pointer rejection, extern implicit backing
  rejection, zero-bit tuple and comptime-field behavior from Zig 0.16.
- `comptime_side_effect_import.zig`: imported module with compile-log side
  effect to prove comptime evaluation risk.
- `embed_file_probe.zig`: `@embedFile` under workspace policy to verify read
  boundaries.
- `build_help_executes_build_zig/`: sentinel build script proving
  `zig build --help` executes `build.zig`.
- Extended tricky syntax fixtures for `usingnamespace`, generics, escaped test
  names, malformed partial parse, nested containers, and conditional imports.

### Next Investments

1. Promote `zig_abi_layout_diff` plus `zig_memory_layout` as a paired feature:
   parser-backed candidate discovery first, then opt-in compiler-backed target
   measurements using generated probes, isolated cache dirs, explicit target
   list, no `build.zig`, and clear `executes_project_code` when importing
   project modules.

2. Add `zig_target_metadata` or strengthen `zig_targets` routing with
   `--show-builtin -target` evidence. This gives cross-target facts at lower
   risk and supports ABI/layout probes.

Defer full comptime value inspection unless constrained to generated snippets
or explicitly marked as project-code execution.

### Source Basis

- Local:
  [docs/tool-index.generated.md](../tool-index.generated.md),
  [src/app/usecases/static_analysis/developer_pain.zig](../../src/app/usecases/static_analysis/developer_pain.zig),
  [src/domain/zig/static_analysis_contracts.zig](../../src/domain/zig/static_analysis_contracts.zig),
  [docs/trust.md](../trust.md).
- External:
  [Zig 0.16.0 release notes](https://ziglang.org/download/0.16.0/release-notes.html),
  [Zig 0.16.0 language reference](https://ziglang.org/documentation/0.16.0/),
  [Zig build system docs](https://ziglang.org/learn/build-system/).

Confidence: high for ABI/layout promotion and risk classes; medium for broader
comptime inspection shape.

## 8. Platform Research

### Findings

Different consumers need different surfaces:

| Consumer | Need | Best surface |
|---|---|---|
| CI | health checks, annotations, JUnit, coverage, API/release gates, exit codes | thin CLI plus generated artifacts |
| Editor extension | setup/config, workspace facts, optional MCP tool access | MCP config plus generated artifacts; ZLS remains primary editor intelligence |
| Release bot | release readiness, docs drift, artifact checks, provenance summaries | thin CLI plus generated artifacts |
| Other Zig tool | machine-readable parser/static-analysis output | generated JSON first; public library only with adopter |
| Agent-only user | tool discovery, structured MCP results, workflow guidance | MCP plus `@zigars/skills` |

MCP remains the primary surface for agents. Generated artifacts are the best
non-MCP contract. Skills are useful for agent workflows but should remain
client-side guidance, not server behavior. A public library API has weak demand
right now and would freeze allocator, context, error, and port boundaries that
are currently internal.

The existing `tools/zigars_tools.zig` should not become the public user CLI. It
is a release and local helper dispatcher. A public CLI should expose selected
use cases through stable JSON, clear exit codes, stderr diagnostics, and the
same workspace/apply-gate posture as MCP tools.

### Demand Map

| Surface | Demand | Recommendation |
|---|---:|---|
| MCP | High | Keep primary for agents and MCP-capable editors |
| CLI | High | Add thin one-shot commands over existing use cases |
| Library | Low/uncertain | Defer until a real Zig-tool adopter cannot use CLI/artifacts |
| Generated artifacts | High | Treat JSON, SARIF, JUnit, coverage, and evidence packs as non-MCP contracts |
| Skills | High for agents, low for CI | Continue separately; do not auto-configure MCP clients |
| Plugin API | Low/unknown | Defer until there is an adopter and stable versioned contract |

### CLI Before Library

Start with read-only or reporting commands:

- `doctor`
- `workspace-info`
- `ci-ingest`
- `junit`
- `coverage-budget`
- `docs-drift`
- `release-evidence-pack`
- `artifact-index`

Design rules:

- stdout is stable machine JSON for successful command output.
- stderr is diagnostics.
- exit codes are stable.
- workspace path resolution and write gates match the MCP server.
- command schemas are generated or checked against the same manifest data where
  possible.
- no new analysis behavior is invented for the CLI; it is a transport over
  existing use cases.

### Registry, MCPB, And Plugin Stance

Pursue MCP Registry registration for the core server once public release assets,
package metadata, release claims, and namespace ownership are consistent. The
npm package already has an `mcpName`, but the repository-name mismatch must be
settled first.

Keep MCPB as a secondary Claude Desktop path. It is useful for one-click local
desktop installation, but it has platform and packaging constraints that should
not block the npm shim or core server.

Defer third-party plugin registration or a public plugin API. The minimum gates
are stable output schemas, audit/capability disclosure, versioned registration
metadata, third-party command/workspace policy, and at least one real adopter.

### Compatibility Risks

- Tool contracts are already compatibility-sensitive: names, args, enums,
  defaults, risk flags, tiers, and schema metadata.
- CLI adds public stdout format, stderr discipline, exit code, artifact path,
  and schema-version contracts.
- Library extraction would freeze internal allocator/error/context boundaries.
- Editor-extension work can overlap ZLS unless scoped to setup, evidence, and
  MCP workflows.
- MCP Registry and MCPB docs are active surfaces; do not overstate stability.

### Source Basis

- Local:
  [tools/zigars_tools.zig](../../tools/zigars_tools.zig),
  [build.zig](../../build.zig),
  [packages/@zigars/mcp/package.json](../../packages/@zigars/mcp/package.json),
  [packages/@zigars/skills/README.md](../../packages/@zigars/skills/README.md),
  [docs/distribution.md](../distribution.md),
  [docs/tools.md](../tools.md).
- External:
  [MCP Registry](https://github.com/modelcontextprotocol/registry),
  [MCP Registry package types](https://modelcontextprotocol.io/registry/package-types),
  [MCPB docs](https://claude.com/docs/connectors/building/mcpb),
  [MCP servers reference distribution](https://github.com/modelcontextprotocol/servers),
  [ZLS](https://github.com/zigtools/zls).

Confidence: high for CLI-before-library and plugin deferral; medium-high for
MCP Registry timing because public package metadata still needs validation.

## 9. Cross-Cutting Decisions

### What Makes Sense

- Make existing trust and evidence visible before adding new surface.
- Add request correlation and opt-in audit because they strengthen every
  debugging and trust story.
- Improve release provenance because the npm shim already has the right
  checksum baseline and the release workflow already uses GitHub attestation
  primitives.
- Invest in ABI/layout compiler probes because they are Zig-specific, useful,
  and can be scoped with explicit risk boundaries.
- Build a thin CLI because it satisfies CI and shell-only users without freezing
  internal Zig library APIs.

### What To Skip For Now

- Broad plugin APIs.
- A zigars LSP server.
- Stable public library extraction.
- Blanket "deterministic" or "secure sandbox" claims.
- Full project comptime introspection without explicit project-code execution
  risk.
- Audit logs that default to full raw transcripts.

### Suggested Next Spikes

1. Docs spike: rewrite README first-five-minutes and add `docs/evidence-tiers.md`.
2. Operations spike: result `_meta` correlation plus metadata-mode audit JSONL.
3. Supply-chain spike: npm shim policy flags and `gh attestation verify`
   integration.
4. Zig capability spike: standalone ABI/layout compiler probes with target
   fixtures.
5. Platform spike: one thin CLI command over an existing read-only use case,
   with stable JSON and exit-code contract.
