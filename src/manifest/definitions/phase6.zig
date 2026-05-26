const types = @import("../types.zig");

const schema = types.schema;
const schemaWithHints = types.schemaWithHints;
const tool = types.tool;
const fieldHint = types.fieldHint;

const ci_ingest_plan = "Parses caller-supplied or workspace-local CI evidence into local failure facts without running commands.";
const release_plan = "Synthesizes observed validation, CI, API, docs, dependency, and security evidence into release guidance without claiming skipped checks passed.";
const api_plan = "Builds or compares public API evidence from workspace source snapshots and explicit baselines.";
const docs_plan = "Builds/query local documentation evidence from installed Zig docs, workspace docs, autodoc artifacts, or snippets without network access.";
const dependency_plan = "Inspects build.zig.zon and caller-supplied dependency evidence to plan maintenance and security checks without fetching packages.";
const optional_security_plan = "Ingests caller-supplied scanner reports or returns an explicit optional-backend unavailable result; zigar does not contact external services.";

const ci_format_hint = fieldHint("format", .{ .description = "CI evidence format.", .default_string = "auto", .enum_values = &.{ "auto", "log", "annotations", "junit", "sarif" } });
const docs_scope_hint = fieldHint("scope", .{ .description = "Documentation corpus to inspect.", .default_string = "workspace", .enum_values = &.{ "workspace", "docs", "src", "all" } });
const apply_hint = fieldHint("apply", .{ .description = "Must be true before writing the generated artifact.", .default_bool = false });

pub const zig_ci_ingest = tool(.{
    .description = "Ingest CI logs, annotations, JUnit, SARIF, or raw artifacts into structured local failure evidence.",
    .input_schema = schemaWithHints(&.{ .{ "path", "string", false }, .{ "content", "string", false }, .{ "format", "string", false }, .{ "limit", "integer", false } }, &.{ci_format_hint}),
    .read_only = true,
    .group = .ci_artifacts,
    .plan = .{ .pure_analysis = ci_ingest_plan },
});

pub const zig_ci_repro_plan = tool(.{
    .description = "Plan local commands and evidence checks from ingested CI failures without executing them.",
    .input_schema = schemaWithHints(&.{ .{ "path", "string", false }, .{ "content", "string", false }, .{ "format", "string", false }, .{ "changed_files", "string", false }, .{ "limit", "integer", false } }, &.{ci_format_hint}),
    .read_only = true,
    .group = .ci_artifacts,
    .plan = .{ .pure_analysis = ci_ingest_plan },
});

pub const zig_ci_failure_map = tool(.{
    .description = "Group CI failure evidence by file, test, job, and parser confidence for agent triage.",
    .input_schema = schemaWithHints(&.{ .{ "path", "string", false }, .{ "content", "string", false }, .{ "format", "string", false }, .{ "limit", "integer", false } }, &.{ci_format_hint}),
    .read_only = true,
    .group = .ci_artifacts,
    .plan = .{ .pure_analysis = ci_ingest_plan },
});

pub const zig_release_plan = tool(.{
    .description = "Combine observed validation, CI, API, docs, dependency, security, changelog, and clean-tree evidence into a release plan.",
    .input_schema = schema(&.{ .{ "goal", "string", false }, .{ "validation", "string", false }, .{ "ci", "string", false }, .{ "api", "string", false }, .{ "docs", "string", false }, .{ "dependencies", "string", false }, .{ "security", "string", false }, .{ "changelog", "string", false }, .{ "changed_files", "string", false } }),
    .read_only = true,
    .group = .release_intelligence,
    .plan = .{ .pure_analysis = release_plan },
});

pub const zig_semver_suggest = tool(.{
    .description = "Suggest a conservative semver bump from API diff, changelog, and release evidence.",
    .input_schema = schema(&.{ .{ "api_diff", "string", false }, .{ "changelog", "string", false }, .{ "current_version", "string", false }, .{ "release_notes", "string", false } }),
    .read_only = true,
    .group = .release_intelligence,
    .plan = .{ .pure_analysis = release_plan },
});

pub const zig_release_notes_draft = tool(.{
    .description = "Draft structured release notes from observed changes, API diff, validation, CI, dependency, and security evidence.",
    .input_schema = schema(&.{ .{ "changes", "string", false }, .{ "api_diff", "string", false }, .{ "validation", "string", false }, .{ "ci", "string", false }, .{ "dependencies", "string", false }, .{ "security", "string", false }, .{ "version", "string", false } }),
    .read_only = true,
    .group = .release_intelligence,
    .plan = .{ .pure_analysis = release_plan },
});

pub const zig_release_evidence_pack = tool(.{
    .description = "Package release evidence pointers, skipped checks, limitations, and verification commands for release review.",
    .input_schema = schema(&.{ .{ "validation", "string", false }, .{ "ci", "string", false }, .{ "api", "string", false }, .{ "docs", "string", false }, .{ "dependencies", "string", false }, .{ "security", "string", false }, .{ "artifacts", "string", false } }),
    .read_only = true,
    .group = .release_intelligence,
    .plan = .{ .pure_analysis = release_plan },
});

pub const zig_api_baseline_init = tool(.{
    .description = "Preview or write a public API baseline artifact from a source file, inline source, or workspace public declarations.",
    .input_schema = schemaWithHints(&.{ .{ "file", "string", false }, .{ "content", "string", false }, .{ "output", "string", false }, .{ "apply", "boolean", false }, .{ "limit", "integer", false } }, &.{apply_hint}),
    .read_only = false,
    .group = .api_lifecycle,
    .risk = .{ .writes_artifacts = true, .writes_require_apply = true, .preview_by_default = true },
    .plan = .{ .workspace_artifact = api_plan },
});

pub const zig_api_check = tool(.{
    .description = "Check current public API evidence against an explicit or workspace-local baseline and report likely breaking changes.",
    .input_schema = schema(&.{ .{ "file", "string", false }, .{ "content", "string", false }, .{ "baseline", "string", false }, .{ "baseline_path", "string", false }, .{ "limit", "integer", false } }),
    .read_only = true,
    .group = .api_lifecycle,
    .plan = .{ .pure_analysis = api_plan },
});

pub const zig_api_diff_baseline = tool(.{
    .description = "Diff a public API baseline against current source and expose added, removed, changed, and verification fields.",
    .input_schema = schema(&.{ .{ "file", "string", false }, .{ "content", "string", false }, .{ "baseline", "string", false }, .{ "baseline_path", "string", false }, .{ "limit", "integer", false } }),
    .read_only = true,
    .group = .api_lifecycle,
    .plan = .{ .pure_analysis = api_plan },
});

pub const zig_api_docs_diff = tool(.{
    .description = "Compare public API declarations with project docs/autodoc text and report undocumented or stale entries.",
    .input_schema = schema(&.{ .{ "file", "string", false }, .{ "content", "string", false }, .{ "docs_path", "string", false }, .{ "docs_content", "string", false }, .{ "limit", "integer", false } }),
    .read_only = true,
    .group = .api_lifecycle,
    .plan = .{ .pure_analysis = api_plan },
});

pub const zig_docs_index_build = tool(.{
    .description = "Build an in-memory local docs index summary with source provenance, completeness, and query guidance.",
    .input_schema = schemaWithHints(&.{ .{ "scope", "string", false }, .{ "limit", "integer", false } }, &.{docs_scope_hint}),
    .read_only = true,
    .group = .docs,
    .plan = .{ .pure_analysis = docs_plan },
});

pub const zig_docs_query = tool(.{
    .description = "Query the local docs index across workspace docs, README, source comments, stdlib, and language-reference evidence.",
    .input_schema = schemaWithHints(&.{ .{ "query", "string", true }, .{ "scope", "string", false }, .{ "limit", "integer", false } }, &.{docs_scope_hint}),
    .read_only = true,
    .group = .docs,
    .plan = .{ .pure_analysis = docs_plan },
});

pub const zig_std_signature = tool(.{
    .description = "Look up a Zig stdlib declaration signature with source-scan provenance and explicit limitations.",
    .input_schema = schema(&.{ .{ "name", "string", true }, .{ "limit", "integer", false } }),
    .read_only = true,
    .group = .docs,
    .plan = .{ .pure_analysis = docs_plan },
});

pub const zig_langref_item = tool(.{
    .description = "Look up a language reference item with source/completeness metadata and no-result guidance.",
    .input_schema = schema(&.{ .{ "query", "string", true }, .{ "limit", "integer", false } }),
    .read_only = true,
    .group = .docs,
    .plan = .{ .pure_analysis = docs_plan },
});

pub const zig_autodoc_ingest = tool(.{
    .description = "Ingest a project autodoc artifact or inline JSON/text into searchable project-doc evidence.",
    .input_schema = schema(&.{ .{ "path", "string", false }, .{ "content", "string", false }, .{ "limit", "integer", false } }),
    .read_only = true,
    .group = .docs,
    .plan = .{ .pure_analysis = docs_plan },
});

pub const zig_project_docs_query = tool(.{
    .description = "Query project README/docs/source-comment/autodoc evidence with provenance and confidence fields.",
    .input_schema = schemaWithHints(&.{ .{ "query", "string", true }, .{ "scope", "string", false }, .{ "autodoc", "string", false }, .{ "limit", "integer", false } }, &.{docs_scope_hint}),
    .read_only = true,
    .group = .docs,
    .plan = .{ .pure_analysis = docs_plan },
});

pub const zig_doc_example_check = tool(.{
    .description = "Parse Zig examples from a docs file or inline docs content and report snippet syntax status without executing project code.",
    .input_schema = schema(&.{ .{ "path", "string", false }, .{ "content", "string", false }, .{ "limit", "integer", false } }),
    .read_only = true,
    .group = .docs,
    .plan = .{ .pure_analysis = docs_plan },
});

pub const zig_snippet_check = tool(.{
    .description = "Parse one Zig snippet and return syntax status, diagnostics count, confidence, and validation guidance.",
    .input_schema = schema(&.{.{ "content", "string", true }}),
    .read_only = true,
    .group = .docs,
    .plan = .{ .pure_analysis = docs_plan },
});

pub const zig_readme_command_check = tool(.{
    .description = "Extract README shell commands and classify Zig command examples without executing them.",
    .input_schema = schema(&.{ .{ "path", "string", false }, .{ "content", "string", false }, .{ "limit", "integer", false } }),
    .read_only = true,
    .group = .docs,
    .plan = .{ .pure_analysis = docs_plan },
});

pub const zig_dependency_update_plan = tool(.{
    .description = "Plan dependency updates from build.zig.zon with verification commands and risk notes.",
    .input_schema = schema(&.{ .{ "dependency", "string", false }, .{ "target_version", "string", false }, .{ "manifest", "string", false } }),
    .read_only = true,
    .group = .dependency_security,
    .plan = .{ .pure_analysis = dependency_plan },
});

pub const zig_dependency_fetch_check = tool(.{
    .description = "Check dependency fetch readiness from manifest metadata and name the explicit fetch verification command.",
    .input_schema = schema(&.{.{ "manifest", "string", false }}),
    .read_only = true,
    .group = .dependency_security,
    .plan = .{ .pure_analysis = dependency_plan },
});

pub const zig_dependency_lock_audit = tool(.{
    .description = "Audit dependency manifest and lock/cache state for drift, missing hashes, and explicit verification gaps.",
    .input_schema = schema(&.{ .{ "manifest", "string", false }, .{ "lockfile", "string", false } }),
    .read_only = true,
    .group = .dependency_security,
    .plan = .{ .pure_analysis = dependency_plan },
});

pub const zig_dependency_impact = tool(.{
    .description = "Map dependency manifest changes to likely build, import, validation, and release impacts.",
    .input_schema = schema(&.{ .{ "dependency", "string", false }, .{ "before", "string", false }, .{ "after", "string", false }, .{ "changed_files", "string", false }, .{ "limit", "integer", false } }),
    .read_only = true,
    .group = .dependency_security,
    .plan = .{ .pure_analysis = dependency_plan },
});

pub const zig_sbom = tool(.{
    .description = "Preview or write a CycloneDX-style SBOM from Zig dependency metadata with provenance and limitations.",
    .input_schema = schemaWithHints(&.{ .{ "manifest", "string", false }, .{ "output", "string", false }, .{ "apply", "boolean", false } }, &.{apply_hint}),
    .read_only = false,
    .group = .dependency_security,
    .risk = .{ .writes_artifacts = true, .writes_require_apply = true, .preview_by_default = true },
    .plan = .{ .workspace_artifact = dependency_plan },
});

pub const zig_zat_scan = tool(.{
    .description = "Ingest ZAT scan evidence when supplied, or return structured optional-backend unavailable guidance.",
    .input_schema = schema(&.{ .{ "path", "string", false }, .{ "content", "string", false } }),
    .read_only = true,
    .group = .dependency_security,
    .plan = .{ .pure_analysis = optional_security_plan },
});

pub const zig_osv_scan = tool(.{
    .description = "Ingest OSV vulnerability evidence when supplied, or return structured external-service unavailable guidance.",
    .input_schema = schema(&.{ .{ "path", "string", false }, .{ "content", "string", false } }),
    .read_only = true,
    .group = .dependency_security,
    .plan = .{ .pure_analysis = optional_security_plan },
});

pub const zig_dependency_security_report = tool(.{
    .description = "Summarize dependency security risk from manifest, SBOM, ZAT, OSV, and local policy evidence.",
    .input_schema = schema(&.{ .{ "manifest", "string", false }, .{ "sbom", "string", false }, .{ "zat", "string", false }, .{ "osv", "string", false } }),
    .read_only = true,
    .group = .dependency_security,
    .plan = .{ .pure_analysis = dependency_plan },
});

pub const zig_dependency_provenance = tool(.{
    .description = "Report dependency origins, hashes, local paths, and provenance confidence from build.zig.zon.",
    .input_schema = schema(&.{.{ "manifest", "string", false }}),
    .read_only = true,
    .group = .dependency_security,
    .plan = .{ .pure_analysis = dependency_plan },
});

pub const zig_dependency_license_summary = tool(.{
    .description = "Summarize dependency license evidence and unknowns from manifest origins and workspace license files.",
    .input_schema = schema(&.{ .{ "manifest", "string", false }, .{ "license_text", "string", false } }),
    .read_only = true,
    .group = .dependency_security,
    .plan = .{ .pure_analysis = dependency_plan },
});

pub const zig_github_dependency_submit_plan = tool(.{
    .description = "Build a GitHub dependency submission payload plan without submitting or requiring credentials.",
    .input_schema = schema(&.{ .{ "manifest", "string", false }, .{ "job", "string", false }, .{ "ref", "string", false }, .{ "sha", "string", false } }),
    .read_only = true,
    .group = .dependency_security,
    .plan = .{ .pure_analysis = dependency_plan },
});
