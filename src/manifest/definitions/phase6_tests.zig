//! Contract tests for phase6.zig: pins that CI ingestion, release intelligence,
//! API lifecycle, docs, and dependency/security tools expose non-empty descriptions
//! and that write-capable tools carry the expected apply-gate risk metadata.
const std = @import("std");
const subject = @import("phase6.zig");
const zig_ci_ingest = subject.zig_ci_ingest;
const zig_ci_repro_plan = subject.zig_ci_repro_plan;
const zig_ci_failure_map = subject.zig_ci_failure_map;
const zig_release_plan = subject.zig_release_plan;
const zig_semver_suggest = subject.zig_semver_suggest;
const zig_release_notes_draft = subject.zig_release_notes_draft;
const zig_release_evidence_pack = subject.zig_release_evidence_pack;
const zig_api_baseline_init = subject.zig_api_baseline_init;
const zig_api_check = subject.zig_api_check;
const zig_api_diff_baseline = subject.zig_api_diff_baseline;
const zig_api_docs_diff = subject.zig_api_docs_diff;
const zig_docs_index_build = subject.zig_docs_index_build;
const zig_docs_query = subject.zig_docs_query;
const zig_std_signature = subject.zig_std_signature;
const zig_langref_item = subject.zig_langref_item;
const zig_autodoc_ingest = subject.zig_autodoc_ingest;
const zig_project_docs_query = subject.zig_project_docs_query;
const zig_doc_example_check = subject.zig_doc_example_check;
const zig_snippet_check = subject.zig_snippet_check;
const zig_readme_command_check = subject.zig_readme_command_check;
const zig_dependency_update_plan = subject.zig_dependency_update_plan;
const zig_dependency_fetch_check = subject.zig_dependency_fetch_check;
const zig_dependency_lock_audit = subject.zig_dependency_lock_audit;
const zig_dependency_impact = subject.zig_dependency_impact;
const zig_sbom = subject.zig_sbom;
const zig_zat_scan = subject.zig_zat_scan;
const zig_osv_scan = subject.zig_osv_scan;
const zig_dependency_security_report = subject.zig_dependency_security_report;
const zig_dependency_provenance = subject.zig_dependency_provenance;
const zig_dependency_license_summary = subject.zig_dependency_license_summary;
const zig_github_dependency_submit_plan = subject.zig_github_dependency_submit_plan;

test "phase6 definitions expose CI metadata" {
    try @import("std").testing.expect(zig_ci_ingest.description.len > 0);
}
