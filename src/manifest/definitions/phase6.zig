const types = @import("../types.zig");

const schema = types.schema;
const schemaWithHints = types.schemaWithHints;
const outputSchema = types.outputSchema;
const tool = types.tool;
const fieldHint = types.fieldHint;

/// CI evidence format.
const ci_ingest_plan = "Parses caller-supplied or workspace-local CI evidence into local failure facts without running commands.";
/// CI evidence format.
const release_plan = "Synthesizes observed validation, CI, API, docs, dependency, and security evidence into release guidance without claiming skipped checks passed.";
/// CI evidence format.
const api_plan = "Builds or compares public API evidence from workspace source snapshots and explicit baselines.";
/// CI evidence format.
const docs_plan = "Builds/query local documentation evidence from installed Zig docs, workspace docs, autodoc artifacts, or snippets without network access.";
/// CI evidence format.
const dependency_plan = "Inspects build.zig.zon and caller-supplied dependency evidence to plan maintenance and security checks without fetching packages.";
/// CI evidence format.
const optional_security_plan = "Ingests caller-supplied scanner reports or returns an explicit optional-backend unavailable result; zigars does not contact external services.";
/// Dependency lifecycle mutation format.
const dependency_mutation_plan = "Previews build.zig.zon dependency edits and applies them only when apply=true using patch-session preimage checks.";
/// Dependency registry provider format.
const dependency_registry_plan = "Returns deterministic dependency provider metadata; network-backed providers report structured unavailable states unless bounded backends are configured.";
/// Dependency migration format.
const dependency_migration_plan = "Builds or resumes a dependency migration session envelope over update, fetch, audit, impact, security, and validation steps.";

/// CI evidence format.
const ci_format_hint = fieldHint("format", .{ .description = "CI evidence format.", .default_string = "auto", .enum_values = &.{ "auto", "log", "annotations", "junit", "sarif" } });
/// Documentation corpus to inspect.
const docs_scope_hint = fieldHint("scope", .{ .description = "Documentation corpus to inspect.", .default_string = "workspace", .enum_values = &.{ "workspace", "docs", "src", "all" } });
/// Must be true before writing the generated artifact.
const apply_hint = fieldHint("apply", .{ .description = "Must be true before writing the generated artifact.", .default_bool = false });
/// build.zig.zon path to read or mutate.
const manifest_path_hint = fieldHint("manifest_path", .{ .description = "Workspace-relative build.zig.zon path.", .default_string = "build.zig.zon", .path_kind = "input_file" });
/// Dependency package provider.
const package_provider_hint = fieldHint("provider", .{ .description = "Dependency package provider.", .default_string = "direct", .enum_values = &.{ "direct", "zigistry" } });
/// Migration mode selector.
const migration_mode_hint = fieldHint("mode", .{ .description = "Dependency migration session mode.", .default_string = "plan", .enum_values = &.{ "plan", "inspect", "resume", "close" } });

/// Ingest CI logs, annotations, JUnit, SARIF, or raw artifacts into structured local failure evidence.
pub const zig_ci_ingest = tool(.{
    .description = "Ingest CI logs, annotations, JUnit, SARIF, or raw artifacts into structured local failure evidence.",
    .input_schema = schemaWithHints(&.{ .{ "path", "string", false }, .{ "content", "string", false }, .{ "format", "string", false }, .{ "limit", "integer", false } }, &.{ci_format_hint}),
    .read_only = true,
    .group = .ci_artifacts,
    .plan = .{ .pure_analysis = ci_ingest_plan },
});

/// Plan local commands and evidence checks from ingested CI failures without executing them.
pub const zig_ci_repro_plan = tool(.{
    .description = "Plan local commands and evidence checks from ingested CI failures without executing them.",
    .input_schema = schemaWithHints(&.{ .{ "path", "string", false }, .{ "content", "string", false }, .{ "format", "string", false }, .{ "changed_files", "string", false }, .{ "limit", "integer", false } }, &.{ci_format_hint}),
    .read_only = true,
    .group = .ci_artifacts,
    .plan = .{ .pure_analysis = ci_ingest_plan },
});

/// Group CI failure evidence by file, test, job, and parser confidence for agent triage.
pub const zig_ci_failure_map = tool(.{
    .description = "Group CI failure evidence by file, test, job, and parser confidence for agent triage.",
    .input_schema = schemaWithHints(&.{ .{ "path", "string", false }, .{ "content", "string", false }, .{ "format", "string", false }, .{ "limit", "integer", false } }, &.{ci_format_hint}),
    .read_only = true,
    .group = .ci_artifacts,
    .plan = .{ .pure_analysis = ci_ingest_plan },
});

/// Combine observed validation, CI, API, docs, dependency, security, changelog, and clean-tree evidence into a release plan.
pub const zig_release_plan = tool(.{
    .description = "Combine observed validation, CI, API, docs, dependency, security, changelog, and clean-tree evidence into a release plan.",
    .input_schema = schema(&.{ .{ "goal", "string", false }, .{ "validation", "string", false }, .{ "ci", "string", false }, .{ "api", "string", false }, .{ "docs", "string", false }, .{ "dependencies", "string", false }, .{ "security", "string", false }, .{ "changelog", "string", false }, .{ "changed_files", "string", false } }),
    .read_only = true,
    .group = .release_intelligence,
    .plan = .{ .pure_analysis = release_plan },
});

/// Suggest a conservative semver bump from API diff, changelog, and release evidence.
pub const zig_semver_suggest = tool(.{
    .description = "Suggest a conservative semver bump from API diff, changelog, and release evidence.",
    .input_schema = schema(&.{ .{ "api_diff", "string", false }, .{ "changelog", "string", false }, .{ "current_version", "string", false }, .{ "release_notes", "string", false } }),
    .read_only = true,
    .group = .release_intelligence,
    .plan = .{ .pure_analysis = release_plan },
});

/// Draft structured release notes from observed changes, API diff, validation, CI, dependency, and security evidence.
pub const zig_release_notes_draft = tool(.{
    .description = "Draft structured release notes from observed changes, API diff, validation, CI, dependency, and security evidence.",
    .input_schema = schema(&.{ .{ "changes", "string", false }, .{ "api_diff", "string", false }, .{ "validation", "string", false }, .{ "ci", "string", false }, .{ "dependencies", "string", false }, .{ "security", "string", false }, .{ "version", "string", false } }),
    .read_only = true,
    .group = .release_intelligence,
    .plan = .{ .pure_analysis = release_plan },
});

/// Package release evidence pointers, skipped checks, limitations, and verification commands for release review.
pub const zig_release_evidence_pack = tool(.{
    .description = "Package release evidence pointers, skipped checks, limitations, and verification commands for release review.",
    .input_schema = schema(&.{ .{ "validation", "string", false }, .{ "ci", "string", false }, .{ "api", "string", false }, .{ "docs", "string", false }, .{ "dependencies", "string", false }, .{ "security", "string", false }, .{ "artifacts", "string", false } }),
    .read_only = true,
    .group = .release_intelligence,
    .plan = .{ .pure_analysis = release_plan },
});

/// Preview or write a public API baseline artifact from a source file, inline source, or workspace public declarations.
pub const zig_api_baseline_init = tool(.{
    .description = "Preview or write a public API baseline artifact from a source file, inline source, or workspace public declarations.",
    .input_schema = schemaWithHints(&.{ .{ "file", "string", false }, .{ "content", "string", false }, .{ "output", "string", false }, .{ "apply", "boolean", false }, .{ "limit", "integer", false } }, &.{apply_hint}),
    .read_only = false,
    .group = .api_lifecycle,
    .risk = .{ .writes_artifacts = true, .writes_require_apply = true, .preview_by_default = true },
    .plan = .{ .workspace_artifact = api_plan },
});

/// Check current public API evidence against an explicit or workspace-local baseline and report likely breaking changes.
pub const zig_api_check = tool(.{
    .description = "Check current public API evidence against an explicit or workspace-local baseline and report likely breaking changes.",
    .input_schema = schema(&.{ .{ "file", "string", false }, .{ "content", "string", false }, .{ "baseline", "string", false }, .{ "baseline_path", "string", false }, .{ "limit", "integer", false } }),
    .read_only = true,
    .group = .api_lifecycle,
    .plan = .{ .pure_analysis = api_plan },
});

/// Diff a public API baseline against current source and expose added, removed, changed, and verification fields.
pub const zig_api_diff_baseline = tool(.{
    .description = "Diff a public API baseline against current source and expose added, removed, changed, and verification fields.",
    .input_schema = schema(&.{ .{ "file", "string", false }, .{ "content", "string", false }, .{ "baseline", "string", false }, .{ "baseline_path", "string", false }, .{ "limit", "integer", false } }),
    .read_only = true,
    .group = .api_lifecycle,
    .plan = .{ .pure_analysis = api_plan },
});

/// Compare public API declarations with project docs/autodoc text and report undocumented or stale entries.
pub const zig_api_docs_diff = tool(.{
    .description = "Compare public API declarations with project docs/autodoc text and report undocumented or stale entries.",
    .input_schema = schema(&.{ .{ "file", "string", false }, .{ "content", "string", false }, .{ "docs_path", "string", false }, .{ "docs_content", "string", false }, .{ "limit", "integer", false } }),
    .read_only = true,
    .group = .api_lifecycle,
    .plan = .{ .pure_analysis = api_plan },
});

/// Build an in-memory local docs index summary with source provenance, completeness, and query guidance.
pub const zig_docs_index_build = tool(.{
    .description = "Build an in-memory local docs index summary with source provenance, completeness, and query guidance.",
    .input_schema = schemaWithHints(&.{ .{ "scope", "string", false }, .{ "limit", "integer", false } }, &.{docs_scope_hint}),
    .read_only = true,
    .group = .docs,
    .plan = .{ .pure_analysis = docs_plan },
});

/// Query the local docs index across workspace docs, README, source comments, stdlib, and language-reference evidence.
pub const zig_docs_query = tool(.{
    .description = "Query the local docs index across workspace docs, README, source comments, stdlib, and language-reference evidence.",
    .input_schema = schemaWithHints(&.{ .{ "query", "string", true }, .{ "scope", "string", false }, .{ "autodoc", "string", false }, .{ "limit", "integer", false } }, &.{docs_scope_hint}),
    .read_only = true,
    .group = .docs,
    .plan = .{ .pure_analysis = docs_plan },
});

/// Look up a Zig stdlib declaration signature with source-scan provenance and explicit limitations.
pub const zig_std_signature = tool(.{
    .description = "Look up a Zig stdlib declaration signature with source-scan provenance and explicit limitations.",
    .input_schema = schema(&.{ .{ "name", "string", true }, .{ "limit", "integer", false } }),
    .read_only = true,
    .group = .docs,
    .plan = .{ .pure_analysis = docs_plan },
});

/// Look up a language reference item with source/completeness metadata and no-result guidance.
pub const zig_langref_item = tool(.{
    .description = "Look up a language reference item with source/completeness metadata and no-result guidance.",
    .input_schema = schema(&.{ .{ "query", "string", true }, .{ "limit", "integer", false } }),
    .read_only = true,
    .group = .docs,
    .plan = .{ .pure_analysis = docs_plan },
});

/// Ingest a project autodoc artifact or inline JSON/text into searchable project-doc evidence.
pub const zig_autodoc_ingest = tool(.{
    .description = "Ingest a project autodoc artifact or inline JSON/text into searchable project-doc evidence.",
    .input_schema = schema(&.{ .{ "path", "string", false }, .{ "content", "string", false }, .{ "limit", "integer", false } }),
    .read_only = true,
    .group = .docs,
    .plan = .{ .pure_analysis = docs_plan },
});

/// Query project README/docs/source-comment/autodoc evidence with provenance and confidence fields.
pub const zig_project_docs_query = tool(.{
    .description = "Query project README/docs/source-comment/autodoc evidence with provenance and confidence fields.",
    .input_schema = schemaWithHints(&.{ .{ "query", "string", true }, .{ "scope", "string", false }, .{ "autodoc", "string", false }, .{ "limit", "integer", false } }, &.{docs_scope_hint}),
    .read_only = true,
    .group = .docs,
    .plan = .{ .pure_analysis = docs_plan },
});

/// Parse Zig examples from a docs file or inline docs content and report snippet syntax status without executing project code.
pub const zig_doc_example_check = tool(.{
    .description = "Parse Zig examples from a docs file or inline docs content and report snippet syntax status without executing project code.",
    .input_schema = schema(&.{ .{ "path", "string", false }, .{ "content", "string", false }, .{ "limit", "integer", false } }),
    .read_only = true,
    .group = .docs,
    .plan = .{ .pure_analysis = docs_plan },
});

/// Parse one Zig snippet and return syntax status, diagnostics count, confidence, and validation guidance.
pub const zig_snippet_check = tool(.{
    .description = "Parse one Zig snippet and return syntax status, diagnostics count, confidence, and validation guidance.",
    .input_schema = schema(&.{.{ "content", "string", true }}),
    .read_only = true,
    .group = .docs,
    .plan = .{ .pure_analysis = docs_plan },
});

/// Extract README shell commands and classify Zig command examples without executing them.
pub const zig_readme_command_check = tool(.{
    .description = "Extract README shell commands and classify Zig command examples without executing them.",
    .input_schema = schema(&.{ .{ "path", "string", false }, .{ "content", "string", false }, .{ "limit", "integer", false } }),
    .read_only = true,
    .group = .docs,
    .plan = .{ .pure_analysis = docs_plan },
});

/// Plan dependency updates from build.
pub const zig_dependency_update_plan = tool(.{
    .description = "Plan dependency updates from build.zig.zon with verification commands and risk notes.",
    .input_schema = schema(&.{ .{ "dependency", "string", false }, .{ "target_version", "string", false }, .{ "manifest", "string", false } }),
    .read_only = true,
    .group = .dependency_security,
    .plan = .{ .pure_analysis = dependency_plan },
});

/// Check dependency fetch readiness from manifest metadata and name the explicit fetch verification command.
pub const zig_dependency_fetch_check = tool(.{
    .description = "Check dependency fetch readiness from manifest metadata and name the explicit fetch verification command.",
    .input_schema = schema(&.{.{ "manifest", "string", false }}),
    .read_only = true,
    .group = .dependency_security,
    .plan = .{ .pure_analysis = dependency_plan },
});

/// Audit dependency manifest and lock/cache state for drift, missing hashes, and explicit verification gaps.
pub const zig_dependency_lock_audit = tool(.{
    .description = "Audit dependency manifest and lock/cache state for drift, missing hashes, and explicit verification gaps.",
    .input_schema = schema(&.{ .{ "manifest", "string", false }, .{ "lockfile", "string", false } }),
    .read_only = true,
    .group = .dependency_security,
    .plan = .{ .pure_analysis = dependency_plan },
});

/// Map dependency manifest changes to likely build, import, validation, and release impacts.
pub const zig_dependency_impact = tool(.{
    .description = "Map dependency manifest changes to likely build, import, validation, and release impacts.",
    .input_schema = schema(&.{ .{ "dependency", "string", false }, .{ "before", "string", false }, .{ "after", "string", false }, .{ "changed_files", "string", false }, .{ "limit", "integer", false } }),
    .read_only = true,
    .group = .dependency_security,
    .plan = .{ .pure_analysis = dependency_plan },
});

/// Preview or write a CycloneDX-style SBOM from Zig dependency metadata with provenance and limitations.
pub const zig_sbom = tool(.{
    .description = "Preview or write a CycloneDX-style SBOM from Zig dependency metadata with provenance and limitations.",
    .input_schema = schemaWithHints(&.{ .{ "manifest", "string", false }, .{ "output", "string", false }, .{ "apply", "boolean", false } }, &.{apply_hint}),
    .read_only = false,
    .group = .dependency_security,
    .risk = .{ .writes_artifacts = true, .writes_require_apply = true, .preview_by_default = true },
    .plan = .{ .workspace_artifact = dependency_plan },
});

/// Ingest ZAT scan evidence when supplied, or return structured optional-backend unavailable guidance.
pub const zig_zat_scan = tool(.{
    .description = "Ingest ZAT scan evidence when supplied, or return structured optional-backend unavailable guidance.",
    .input_schema = schema(&.{ .{ "path", "string", false }, .{ "content", "string", false } }),
    .read_only = true,
    .group = .dependency_security,
    .plan = .{ .pure_analysis = optional_security_plan },
});

/// Ingest OSV vulnerability evidence when supplied, or return structured external-service unavailable guidance.
pub const zig_osv_scan = tool(.{
    .description = "Ingest OSV vulnerability evidence when supplied, or return structured external-service unavailable guidance.",
    .input_schema = schema(&.{ .{ "path", "string", false }, .{ "content", "string", false } }),
    .read_only = true,
    .group = .dependency_security,
    .plan = .{ .pure_analysis = optional_security_plan },
});

/// Summarize dependency security risk from manifest, SBOM, ZAT, OSV, and local policy evidence.
pub const zig_dependency_security_report = tool(.{
    .description = "Summarize dependency security risk from manifest, SBOM, ZAT, OSV, and local policy evidence.",
    .input_schema = schema(&.{ .{ "manifest", "string", false }, .{ "sbom", "string", false }, .{ "zat", "string", false }, .{ "osv", "string", false } }),
    .read_only = true,
    .group = .dependency_security,
    .plan = .{ .pure_analysis = dependency_plan },
});

/// Report dependency origins, hashes, local paths, and provenance confidence from build.
pub const zig_dependency_provenance = tool(.{
    .description = "Report dependency origins, hashes, local paths, and provenance confidence from build.zig.zon.",
    .input_schema = schema(&.{.{ "manifest", "string", false }}),
    .read_only = true,
    .group = .dependency_security,
    .plan = .{ .pure_analysis = dependency_plan },
});

/// Summarize dependency license evidence and unknowns from manifest origins and workspace license files.
pub const zig_dependency_license_summary = tool(.{
    .description = "Summarize dependency license evidence and unknowns from manifest origins and workspace license files.",
    .input_schema = schema(&.{ .{ "manifest", "string", false }, .{ "license_text", "string", false } }),
    .read_only = true,
    .group = .dependency_security,
    .plan = .{ .pure_analysis = dependency_plan },
});

/// Build a GitHub dependency submission payload plan without submitting or requiring credentials.
pub const zig_github_dependency_submit_plan = tool(.{
    .description = "Build a GitHub dependency submission payload plan without submitting or requiring credentials.",
    .input_schema = schema(&.{ .{ "manifest", "string", false }, .{ "job", "string", false }, .{ "ref", "string", false }, .{ "sha", "string", false } }),
    .read_only = true,
    .group = .dependency_security,
    .plan = .{ .pure_analysis = dependency_plan },
});

/// Preview or apply a build.zig.zon hash replacement by running exact `zig fetch <url>` and patch-session source writes.
pub const zig_zon_dep_sync = tool(.{
    .description = "Preview or apply a build.zig.zon dependency hash sync using exact zig fetch evidence and patch-session preimages.",
    .input_schema = schemaWithHints(&.{ .{ "dependency", "string", true }, .{ "manifest_path", "string", false }, .{ "manifest", "string", false }, .{ "url", "string", false }, .{ "apply", "boolean", false }, .{ "expected_preimage_sha256", "string", false }, .{ "expected_preimage_bytes", "integer", false }, .{ "timeout_ms", "integer", false } }, &.{ manifest_path_hint, apply_hint }),
    .output_schema = outputSchema(.patch_session),
    .read_only = false,
    .group = .dependency_security,
    // `zig fetch <url>` runs the zig toolchain against a caller-supplied URL with
    // network access and package-cache writes. `executes_backend` covers running
    // zig; `executes_user_command` marks the user-URL-driven, network-effecting
    // fetch. ToolRisk has no dedicated network marker, so this is the closest
    // honest flag. Net risk level stays "high" via writes_source.
    .risk = .{ .writes_source = true, .writes_require_apply = true, .preview_by_default = true, .executes_backend = true, .executes_user_command = true },
    .plan = .{ .apply_gated_mutation = dependency_mutation_plan },
});

/// Preview or apply adding a direct URL/hash or local path dependency to build.zig.zon.
pub const zig_deps_add = tool(.{
    .description = "Preview or apply adding a direct URL/hash or local path dependency to build.zig.zon.",
    .input_schema = schemaWithHints(&.{ .{ "dependency", "string", true }, .{ "manifest_path", "string", false }, .{ "manifest", "string", false }, .{ "url", "string", false }, .{ "hash", "string", false }, .{ "path", "string", false }, .{ "apply", "boolean", false }, .{ "expected_preimage_sha256", "string", false }, .{ "expected_preimage_bytes", "integer", false } }, &.{ manifest_path_hint, apply_hint }),
    .output_schema = outputSchema(.patch_session),
    .read_only = false,
    .group = .dependency_security,
    .risk = .{ .writes_source = true, .writes_require_apply = true, .preview_by_default = true },
    .plan = .{ .apply_gated_mutation = dependency_mutation_plan },
});

/// Preview or apply removing one dependency entry from build.zig.zon.
pub const zig_deps_remove = tool(.{
    .description = "Preview or apply removing one dependency entry from build.zig.zon.",
    .input_schema = schemaWithHints(&.{ .{ "dependency", "string", true }, .{ "manifest_path", "string", false }, .{ "manifest", "string", false }, .{ "apply", "boolean", false }, .{ "expected_preimage_sha256", "string", false }, .{ "expected_preimage_bytes", "integer", false } }, &.{ manifest_path_hint, apply_hint }),
    .output_schema = outputSchema(.patch_session),
    .read_only = false,
    .group = .dependency_security,
    .risk = .{ .writes_source = true, .writes_require_apply = true, .preview_by_default = true },
    .plan = .{ .apply_gated_mutation = dependency_mutation_plan },
});

/// Preview or apply upgrading a direct URL dependency in build.zig.zon.
pub const zig_deps_upgrade = tool(.{
    .description = "Preview or apply upgrading a direct URL dependency in build.zig.zon.",
    .input_schema = schemaWithHints(&.{ .{ "dependency", "string", true }, .{ "manifest_path", "string", false }, .{ "manifest", "string", false }, .{ "url", "string", true }, .{ "hash", "string", false }, .{ "apply", "boolean", false }, .{ "expected_preimage_sha256", "string", false }, .{ "expected_preimage_bytes", "integer", false } }, &.{ manifest_path_hint, apply_hint }),
    .output_schema = outputSchema(.patch_session),
    .read_only = false,
    .group = .dependency_security,
    .risk = .{ .writes_source = true, .writes_require_apply = true, .preview_by_default = true },
    .plan = .{ .apply_gated_mutation = dependency_mutation_plan },
});

/// Search dependency provider metadata with direct URL/ref support and structured provider-unavailable states.
pub const zig_pkg_search = tool(.{
    .description = "Search dependency provider metadata with direct URL/ref support and structured provider-unavailable states.",
    .input_schema = schemaWithHints(&.{ .{ "query", "string", false }, .{ "url", "string", false }, .{ "provider", "string", false }, .{ "offline", "boolean", false }, .{ "limit", "integer", false } }, &.{package_provider_hint}),
    .output_schema = outputSchema(.analysis_result),
    .read_only = true,
    .group = .dependency_security,
    .plan = .{ .pure_analysis = dependency_registry_plan },
});

/// Inspect one dependency package provider record without mutating build.zig.zon.
pub const zig_pkg_info = tool(.{
    .description = "Inspect one dependency package provider record without mutating build.zig.zon.",
    .input_schema = schemaWithHints(&.{ .{ "name", "string", false }, .{ "url", "string", false }, .{ "query", "string", false }, .{ "provider", "string", false }, .{ "offline", "boolean", false } }, &.{package_provider_hint}),
    .output_schema = outputSchema(.analysis_result),
    .read_only = true,
    .group = .dependency_security,
    .plan = .{ .pure_analysis = dependency_registry_plan },
});

/// List deterministic version/ref metadata for a dependency provider record.
pub const zig_pkg_versions = tool(.{
    .description = "List deterministic version/ref metadata for a dependency provider record.",
    .input_schema = schemaWithHints(&.{ .{ "name", "string", false }, .{ "url", "string", false }, .{ "query", "string", false }, .{ "provider", "string", false }, .{ "offline", "boolean", false } }, &.{package_provider_hint}),
    .output_schema = outputSchema(.analysis_result),
    .read_only = true,
    .group = .dependency_security,
    .plan = .{ .pure_analysis = dependency_registry_plan },
});

/// Report package README availability without unbounded network access.
pub const zig_pkg_readme = tool(.{
    .description = "Report package README availability without unbounded network access.",
    .input_schema = schemaWithHints(&.{ .{ "name", "string", false }, .{ "url", "string", false }, .{ "query", "string", false }, .{ "provider", "string", false }, .{ "offline", "boolean", false } }, &.{package_provider_hint}),
    .output_schema = outputSchema(.analysis_result),
    .read_only = true,
    .group = .dependency_security,
    .plan = .{ .pure_analysis = dependency_registry_plan },
});

/// Plan, persist, inspect, or resume a dependency migration session envelope.
pub const zig_dependency_migrate = tool(.{
    .description = "Plan, persist, inspect, or resume a dependency migration session envelope over dependency update and validation steps.",
    .input_schema = schemaWithHints(&.{ .{ "mode", "string", false }, .{ "migration_session_id", "string", false }, .{ "dependency", "string", false }, .{ "name", "string", false }, .{ "target_url", "string", false }, .{ "manifest_path", "string", false }, .{ "manifest", "string", false }, .{ "goal", "string", false }, .{ "apply", "boolean", false } }, &.{ migration_mode_hint, manifest_path_hint, apply_hint }),
    .output_schema = outputSchema(.patch_session),
    .read_only = false,
    .group = .dependency_security,
    .risk = .{ .writes_artifacts = true, .writes_require_apply = true, .preview_by_default = true },
    .plan = .{ .workspace_artifact = dependency_migration_plan },
});
