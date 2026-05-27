---
name: zigars-dependency-steward
description: Use when adding, removing, updating, auditing, or repairing Zig package dependencies, build.zig.zon hashes, zig fetch issues, package cache problems, provenance, license, SBOM, OSV/ZAT scanner evidence, or dependency-related release risk.
---

# Zigars Dependency Steward

## Purpose

Use this skill for dependency work that crosses manifest edits, fetch/hash
evidence, provenance, license, security, and validation.

## Workflow

1. Inspect the current dependency state with `zig_dependency_inspect`,
   `zig_package_cache_doctor`, and `zig_dependency_lock_audit` when available.
2. For candidate discovery, use `zig_pkg_search`, `zig_pkg_info`,
   `zig_pkg_versions`, or `zig_pkg_readme`. Treat registry metadata as discovery,
   not authoritative provenance.
3. Before changing `build.zig.zon`, plan the mutation with
   `zig_dependency_update_plan`, `zig_dependency_migrate`,
   `zig_deps_add`, `zig_deps_remove`, `zig_deps_upgrade`, or
   `zig_zon_dep_sync`. Apply only through preview-first, `apply=true` paths.
4. Verify fetch and hash behavior with `zig_dependency_fetch_check` before
   treating a dependency as usable.
5. Check impact with `zig_dependency_impact`, `zig_build_graph`,
   `zig_import_resolve`, focused test selection, and build/test evidence.
6. For security or release-facing work, gather `zig_sbom`, `zig_osv_scan`,
   `zig_zat_scan`, `zig_dependency_security_report`,
   `zig_dependency_provenance`, and `zig_dependency_license_summary` evidence
   when available or state explicitly when external scanner evidence is absent.

## Claim Boundary

- Do not claim a dependency is safe from package metadata alone.
- Do not claim a scanner passed when the scanner report was not supplied or run.
- Do not hand-edit dependency hashes when zigars can preview a hash sync.
- Preserve preimage and diff evidence for dependency manifest writes.

## Finish

Report dependency changes, fetch/hash evidence, provenance and license status,
security evidence status, validation run, and rollback or preimage notes.
