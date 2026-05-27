---
name: zigar-release-claim-auditor
description: Use when preparing or reviewing release readiness, release notes, semver claims, public support claims, optional backend claims, package artifact claims, changelog entries, or publish/tag decisions for a Zig project.
---

# Zigar Release Claim Auditor

## Purpose

Use this skill to keep public release claims no stronger than the evidence. It
organizes release, API, docs, dependency, backend, artifact, and CI evidence; it
does not publish, tag, or certify skipped checks.

## Workflow

1. Identify the public claim: version bump, breaking-change status, backend
   support, release asset readiness, security posture, docs accuracy, or CI pass.
2. Gather release evidence with `zig_release_plan`, `zig_semver_suggest`,
   `zig_release_notes_draft`, `zig_release_evidence_pack`,
   `zigar_clean_tree_gate`, `zigar_trust_report`, and
   `zigar_command_provenance` when available.
3. Check API and docs claims with `zig_public_api_diff`, `zig_api_check`,
   `zig_api_diff_baseline`, `zig_api_docs_diff`,
   `zigar_docs_drift_check`, and `zigar_release_claim_check`.
4. Check dependency and security evidence with dependency steward tools when
   package dependencies changed or public security claims are present.
5. Check optional backend claims with real conformance evidence. Do not treat
   configured backend paths, fake fixtures, or setup plans as compatibility proof.
6. Verify package artifacts with release gates, artifact identity, checksums, and
   package-local tests appropriate to the repository.

## Claim Boundary

- Release planning tools organize evidence; they do not publish or pass skipped
  gates.
- Dirty-tree evidence is useful for debugging but weak for public release claims.
- External signals such as hosted branch protection, release permissions, and
  real optional backend CI must be stated as absent when not checked.

## Finish

Return allowed claims, claims that must be softened, missing evidence, commands
or CI checks still needed, and confidence for the release decision.
