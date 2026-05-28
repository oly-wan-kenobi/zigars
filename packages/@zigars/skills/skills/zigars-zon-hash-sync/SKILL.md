---
name: zigars-zon-hash-sync
description: Use when build.zig.zon emits a hash mismatch, when adding, bumping, or relocating a Zig dependency, when a user is stuck in the "bogus hash, build, copy hash, rerun" loop, or when a CI build fails on dependency hash verification.
---

# Zigars Zon Hash Sync

## Purpose

Use this skill to collapse the `build.zig.zon` hash-mismatch dance into one
preview-first edit. The skill restricts itself to repairing hash entries and
routes provenance, license, and security audits to the broader dependency
steward.

## Workflow

1. Identify the dependency from the failing build text or current manifest:
   name, declared URL or path, declared hash, and the hash the compiler
   reported.
2. Confirm `build.zig.zon` is workspace-local and not on a generated or vendor
   path with `zigars_patch_guard`.
3. Call `zig_zon_dep_sync` with `apply: false` and, when narrowing, an explicit
   `dependency` or `url`. Read `current_url`, `current_hash`, `fetched_hash`,
   `match`, `replacement_zon_fragment`, `preimage_identity`, `unified_diff`,
   and any unresolved entries.
4. Cross-check the fetched URL against the intended source; if multiple
   dependencies were resolved, confirm each one was expected before applying.
5. Apply with `apply: true` only after the preview matches `expected_preimages`
   and the URL is the intended source.
6. Re-run the failing build (or `zigars_validation_run` for the dependency
   resolution phase) to confirm the new hash resolves.
7. For deeper dependency provenance, license, mirror, or security review,
   switch to `zigars-dependency-steward`.

## Claim Boundary

- Hash sync proves the manifest now matches the fetched bytes for the stored
  URL; it does not authenticate that the dependency is trustworthy or that the
  URL points to the intended publisher.
- `apply: true` mutates `build.zig.zon`; always rerun the failing command after
  apply.
- A successful fetch is not a license, provenance, or supply-chain audit.

## Finish

Report:

- dependency identity (name, URL or path, version where pinned);
- old hash and new hash;
- apply status and `unified_diff`;
- post-apply build verification.
