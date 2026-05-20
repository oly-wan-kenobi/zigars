# Public Trust Checklist

This page is the short answer to "why should a developer trust zigar in a real
Zig project?" It lists the release-facing quality guarantees, the checks that
enforce them, and the product boundaries that should stay visible.

## Runtime Correctness

1. MCP result ownership is explicit. `tools/call`, `resources/read`, and
   `prompts/get` keep zigar-owned results alive through JSON-RPC serialization
   and release those allocations immediately after the response is sent.
2. Command-backed tools execute argv vectors directly, without a shell. Command
   output is bounded, truncation is reported in structured fields, and command
   timeouts are total wall-clock deadlines.
3. Source writes are preview-first. Mutating tools require `apply=true`, expose
   risk metadata, and report source-write behavior through the manifest.

## Workspace And Security Boundaries

4. The configured workspace is the primary safety boundary. User paths are
   resolved under `--workspace`, symlink escapes are rejected, and writes use the
   workspace file helper.
5. zigar is not an OS sandbox. `zig build`, `zig test`, profilers, build
   scripts, and optional backends run with the user's local privileges.
6. HTTP transport is loopback-only and unauthenticated by design. stdio remains
   the default MCP transport for agent clients.

## Public Contract Stability

7. Tool names, schemas, grouping, discovery keywords, risk flags, planning
   metadata, and static-analysis tiers are generated from the typed manifest.
8. `tools/list`, `zigar_schema`, `zigar_tool_index`, and
   `zigar://tools/schema` expose the public contract. Compatibility-sensitive
   changes should be called out in the changelog before a tag.
9. Public-release blocker tasks must be closed before `release-check` passes.
   This prevents maturity docs from claiming readiness while blocking task
   frontmatter still says otherwise. Ready future tasks must explicitly declare
   that they are outside the current public-release scope.

## Feature Maturity

10. ZLS-backed tools are bounded and degraded-mode aware. Missing or unsupported
    ZLS capabilities return structured errors instead of generic MCP failures.
11. Docs lookup is provenance-first. Builtin docs are curated, stdlib lookup is
    source-scan based, and language-reference search reports whether it used
    installed or bundled data.
12. Static-analysis tools are tiered. `advisory_orientation` tools are for
    navigation; parser-backed, compiler-backed, ZLS-backed, and zwanzig-backed
    tools should be preferred for release decisions.
13. Optional backends are explicit. ZLS, zwanzig, zflame, diff-folded, and
    platform profilers are local dependencies with documented setup, probe, and
    compatibility expectations.
14. CI artifact tools disclose parser confidence and scope. `zig_junit` is
    command-level JUnit unless Zig exposes a stable per-test event stream.
15. Agent workflow tools are deterministic advisory helpers. They expose
    included sections, omitted sections, skipped phases, and heuristic limits so
    clients can decide when stronger validation is required.

## Release Gates

Before a public release, run:

```sh
zig build release-check
zig build dist release-asset-smoke
```

`release-check` covers formatting, generated docs, generated JSON/catalog
fixtures, unit tests, ReleaseSafe compilation, HTTP and stdio MCP smoke tests,
kcov coverage floors, fake-backend conformance report contracts, structured
error-contract scans, task frontmatter, least-privilege GitHub Actions permissions,
security/maturity docs, artifact hygiene, and line-budget headroom.

`release-asset-smoke` builds ReleaseSafe archives for all published targets,
checks `zigar-checksums.txt`, verifies archive shape, extracts the native
archive, and runs `zigar --version`.

## External Validation

Some quality signals cannot be forced by the local repository alone:

- GitHub branch protection and release permissions must be configured on the
  hosted repository. Repository workflows declare least-privilege token
  permissions, but hosted branch/release policy still lives outside git.
- Real ZLS, zwanzig, zflame, diff-folded, and platform-profiler validation is
  optional because those backends are not bundled. Use the manual
  `Backend Conformance` workflow or `.github/scripts/backend-conformance.sh`
  when release notes need to claim exact real-backend validation. Every public
  release note should still state real-backend validation status explicitly,
  using `not run` when no real-backend evidence artifact exists.
- Agent-client behavior varies by client. zigar documents Codex, Claude, Gemini,
  Hermes, and generic stdio setup, but clients still own launch environment and
  workspace selection.

When an external signal is absent, release notes should say so directly instead
of implying coverage that did not run.
