---
name: zigars-dependency-steward
description: Use when adding, removing, upgrading, or auditing Zig package dependencies for provenance, license, SBOM, OSV/ZAT scanner evidence, lock state, package cache health, or dependency-related release risk. Hash mismatch repair belongs to zigars-zon-hash-sync.
---

# Zigars Dependency Steward

## Purpose

Use this skill for deliberate dependency changes and audits: adds, removes,
upgrades, provenance, license, SBOM, and security scanning. The mechanical
hash-sync loop belongs to `zigars-zon-hash-sync` and is explicitly out of
scope here.

## Workflow

1. Inspect the current dependency state with `zig_dependency_inspect`,
   `zig_package_cache_doctor`, and `zig_dependency_lock_audit` when available.
2. For candidate discovery, use `zig_pkg_search`, `zig_pkg_info`,
   `zig_pkg_versions`, or `zig_pkg_readme`. Treat registry metadata as
   discovery, not authoritative provenance.
3. Plan adds, removes, and upgrades with `zig_dependency_update_plan`,
   `zig_dependency_migrate`, `zig_deps_add`, `zig_deps_remove`, or
   `zig_deps_upgrade`. Apply only through preview-first, `apply=true` paths.
4. If the build is failing only on a hash mismatch (no other dependency
   change intended), stop and route to `zigars-zon-hash-sync` — that skill
   owns the bogus-hash dance and uses `zig_zon_dep_sync` directly.
5. Verify fetch and hash behavior with `zig_dependency_fetch_check` before
   treating a dependency as usable in the build.
6. Check downstream impact with `zig_dependency_impact`, `zig_build_graph`,
   `zig_import_resolve`, focused test selection, and `zigars-incremental-
   validation` for risk-ordered build and test evidence.
7. For security or release-facing work, gather `zig_sbom`, `zig_osv_scan`,
   `zig_zat_scan`, `zig_dependency_security_report`,
   `zig_dependency_provenance`, and `zig_dependency_license_summary`
   evidence; state explicitly when external scanner evidence is absent.

## Claim Boundary

- Do not claim a dependency is safe from package metadata alone.
- Do not claim a scanner passed when the scanner report was not supplied or
  run.
- Hash-mismatch repair is owned by `zigars-zon-hash-sync`; do not duplicate
  that loop here.
- Preserve preimage and diff evidence for dependency manifest writes.

## Finish

Report:

- dependency changes (add, remove, upgrade) and their `unified_diff`;
- provenance and license status;
- security evidence status (scanner runs, supplied reports, or stated gaps);
- downstream impact and validation run;
- rollback or preimage notes.
