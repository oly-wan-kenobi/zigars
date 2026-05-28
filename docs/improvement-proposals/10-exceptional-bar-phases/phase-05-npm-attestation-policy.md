# Phase 5 - npm Shim Attestation Policy

Status: ready for implementation after repository-name decision
Primary source sections:
[08 section 3.5](../08-exceptional-bar-action-plan.md#35-release-provenance),
[09 section 6](../09-exceptional-bar-deep-research-findings.md#6-trust-and-supply-chain-research)

## Objective

Keep SHA-256 archive verification mandatory and add policy-controlled GitHub
artifact attestation verification to the npm shim.

## Precondition

Resolve the public repository identity before implementation. The local remote
currently uses `oly-wan-kenobi/zigar`, while package metadata and docs use
`oly-wan-kenobi/zigars`. This phase should not hard-code new public release
claims until that naming decision is settled.

## Ordered Tasks

### P5-T1 Add Installer Policy Options

Add a policy option for attestation verification:

- `strict`;
- `verify-if-available`;
- `checksum-only`.

Acceptance criteria:

- Default is `verify-if-available`.
- `checksum-only` is explicit and still never bypasses SHA-256.
- `strict` fails when verification cannot be completed.
- Policy can be set by CLI flag and environment variable.
- Invalid policy values fail with clear stderr diagnostics.

Likely files:

- `packages/@zigars/mcp/src/args.ts`
- `packages/@zigars/mcp/src/install.ts`
- `packages/@zigars/mcp/test/args.test.ts`
- `packages/@zigars/mcp/test/install.test.ts`

### P5-T2 Add Attestation Verification Runner

Invoke `gh attestation verify` with `shell:false` when policy allows and the
verifier is available.

Target command shape:

```sh
gh attestation verify <archive> \
  --repo <public-repo> \
  --predicate-type https://slsa.dev/provenance/v1 \
  --signer-workflow github.com/<public-repo>/.github/workflows/release.yml \
  --source-ref refs/tags/v<version> \
  --deny-self-hosted-runners \
  --format json
```

Acceptance criteria:

- Verification runs before extraction where practical.
- Invalid attestations fail closed.
- Missing `gh` warns only in `verify-if-available` or `checksum-only`.
- `strict` fails when `gh` is missing, verification fails, or attestations are
  unavailable.
- Tests mock successful, missing, invalid, and unavailable verifier outcomes.

### P5-T3 Cache Verification Metadata

Extend `install.json` with:

- archive SHA-256;
- checksum file SHA-256;
- attestation status;
- verified repository;
- workflow;
- source ref;
- source digest when available;
- predicate type;
- verifier version or unavailable reason.

Acceptance criteria:

- Cached executable reuse checks policy compatibility.
- A previous checksum-only install does not satisfy later strict policy.
- Cache metadata is documented as installer evidence, not a security proof by
  itself.

### P5-T4 Add Offline/Unavailable Behavior

Implement explicit behavior for offline and private-release scenarios.

Acceptance criteria:

- Missing checksum fails closed.
- Checksum mismatch fails closed and does not extract.
- Attestation unavailable warns in default policy and fails in strict policy.
- Private or inaccessible repository responses do not produce public
  attestation claims.
- Error messages explain `strict`, `verify-if-available`, and `checksum-only`.

### P5-T5 Update Release Workflow For MCPB Attestation Scope

If MCPB bundles are part of the release claim, add or plan a second attestation
step covering `zigars-mcpb-checksums.txt` subjects.

Acceptance criteria:

- Release archives and MCPB bundles have separate, explicit provenance status.
- Docs do not imply MCPB attestation unless the workflow actually produces it.

Likely files:

- `.github/workflows/release.yml`
- `docs/release.md`
- `docs/distribution.md`
- `docs/trust.md`

### P5-T6 Update npm And Trust Docs

Update package README and project trust/distribution docs with exact wording for
public, private, and missing-attestation releases.

Acceptance criteria:

- Docs state that SHA-256 is always checked.
- Docs state that attestations prove build provenance and artifact integrity,
  not vulnerability freedom.
- Docs state fallback behavior for unavailable attestations.
- Docs explain policy controls.

## Out Of Scope

- Do not replace `gh` with a pure JavaScript Sigstore verifier in this phase.
- Do not introduce GPG signing unless a maintainer key policy is approved.
- Do not publish or push release assets from this phase.

## Validation

```sh
cd packages/@zigars/mcp
npm run build
npm run test:node
bun run test:bun
```

Then from the repo root:

```sh
zig build docs-check json-check
```

Run `zig build artifact-hygiene` if release workflow or generated release
metadata changes.
