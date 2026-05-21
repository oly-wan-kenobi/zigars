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
   risk metadata, and report source-write behavior through the manifest. Patch
   sessions add preimage matching and rollback records for applied multi-file
   edits.

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
9. Release notes must include a clean-tree validation evidence block before a
   public tag. This prevents maturity docs from claiming readiness without the
   exact source commit, local gate results, and real-backend validation status.

## Trust Tools

`zigar_trust_report` is the machine-readable trust summary for the current
server process. It reports the configured workspace/cache roots, path policy,
backend identities, dependency hash references from `build.zig.zon`, manifest
risk audit, and optional clean-tree evidence. By default it does not run git;
pass `include_clean_tree=true` to include the same clean-tree gate used by
`zigar_clean_tree_gate`.

`zigar_command_provenance` reports how registered tools are planned: exact Zig
argv, dynamic command, ZLS request, apply-gated mutation, workspace artifact,
pure analysis, or explicitly unsupported. `zigar_risk_audit` summarizes source
writes, artifact writes, apply gates, backend execution, project-code
execution, and arbitrary user-command execution from the typed manifest.
`zigar_clean_tree_gate` runs `git status --porcelain` with a bounded timeout and
classifies changed paths, including generated or vendored paths.
`zig_generated_file_trace`, `zigar_edit_policy_check`, and
`zigar_generated_route` expose the same generated/vendor policy for individual
edit decisions and route derived paths back to likely source inputs or
regeneration commands.

The clean-tree gate is evidence, not a repository policy engine. It reports what
git returned for the configured workspace and asks the caller to review, commit,
stash, or account for changed paths. It does not reset files, delete generated
outputs, install backends, or prove hosted branch protection. Use the full
`release-check`, release-asset smoke, and clean `Release Readiness` artifact for
public release claims.

## Feature Maturity

10. ZLS-backed tools are bounded and degraded-mode aware. Missing or unsupported
    ZLS capabilities return structured errors instead of generic MCP failures.
11. Docs lookup is provenance-first. Builtin docs are curated, stdlib lookup is
    source-scan based, and language-reference search reports whether it used
    installed or bundled data.
12. Static-analysis tools are tiered. `advisory_orientation` tools are for
    navigation; parser-backed, compiler-backed, ZLS-backed, ZLint-backed, and
    zwanzig-backed tools should be preferred for release decisions.
13. Optional backends are explicit. ZLS, ZLint, zwanzig, zflame, diff-folded,
    and platform profilers are local dependencies with documented setup, probe,
    and compatibility expectations.
14. CI artifact tools disclose parser confidence and scope. `zig_junit` is
    command-level JUnit unless Zig exposes a stable per-test event stream.
15. Agent workflow tools are deterministic advisory helpers. They expose
    included sections, omitted sections, skipped phases, and heuristic limits so
    clients can decide when stronger validation is required.
16. Transactional editing tools are bounded by preimage hashes, apply gates, and
    generated/vendor policy. Refactor helpers return diffs and limitations rather
    than claiming semantic completeness.

## Release Gates

Before a public release, run:

```sh
zig build release-check
zig build dist release-asset-smoke
```

`release-check` covers formatting, generated docs, generated JSON/catalog
fixtures, unit tests, ReleaseSafe compilation, HTTP and stdio MCP smoke tests,
kcov coverage floors, fake-backend conformance report contracts, structured
error-contract scans, least-privilege GitHub Actions permissions, security and
maturity docs, artifact hygiene, and line-budget headroom.

`release-asset-smoke` builds ReleaseSafe archives for all published targets,
checks `zigar-checksums.txt`, verifies archive shape, extracts the native
archive, and runs `zigar --version`.

## External Validation

Some quality signals cannot be forced by the local repository alone:

- GitHub branch protection and release permissions must be configured on the
  hosted repository. Repository workflows declare least-privilege token
  permissions, but hosted branch/release policy still lives outside git.
- Real ZLS, ZLint, zwanzig, zflame, diff-folded, and platform-profiler validation is
  optional because those backends are not bundled. Use the manual
  `Backend Conformance` workflow or `.github/scripts/backend-conformance.sh`
  when release notes need to claim exact real-backend validation. Every public
  release note should still state real-backend validation status explicitly,
  using `not run` when no real-backend evidence artifact exists.
- Public optional-backend claims should come from a clean-tree manual
  `Release Readiness` artifact, including the generated backend compatibility
  matrix and the `ZLS Conformance` report for real ZLS behavior. A run with
  `source_tree_clean: false` is useful for debugging but is not citable release
  evidence.
- Agent-client behavior varies by client. zigar documents Codex, Claude, Gemini,
  Hermes, and generic stdio setup, but clients still own launch environment and
  workspace selection.

When an external signal is absent, release notes should say so directly instead
of implying coverage that did not run.
