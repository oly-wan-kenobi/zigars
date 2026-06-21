---
name: zigars-docs-example-steward
description: Use when writing or reviewing Zig docs, README commands, fenced Zig snippets, examples, local stdlib or langref claims, autodoc evidence, migration notes, docs drift, release-claim drift, or docs that should match the active Zig toolchain.
---

# Zigars Docs Example Steward

## Purpose

Use this skill when documentation has to match the active Zig project, toolchain,
examples, and public claims. Treat docs as evidence-bearing surface, not just
prose.

## Workflow

1. Identify the docs claim: API behavior, stdlib or language rule, setup command,
   example snippet, release note, migration note, or README workflow.
2. Query local project and Zig documentation with `zig_docs_index_build`,
   `zig_docs_query`, `zig_project_docs_query`, `zig_std_search`,
   `zig_std_item`, `zig_std_signature`, `zig_lang_ref_search`,
   `zig_langref_item`, and `zig_autodoc_ingest` when available.
3. Check examples with `zig_doc_example_check` and `zig_snippet_check`. Parse
   README commands with `zig_readme_command_check`; do not execute extracted
   shell commands automatically.
4. Compare docs to code with `zig_public_api`, `zig_api_docs_diff`,
   `zigars_docs_drift_check`, and `zigars_release_claim_check` when claims are
   public or release-facing.
5. When docs changes accompany code changes, validate snippets or commands with
   the narrowest safe project check and report skipped execution.
6. Prefer version-scoped language and stdlib claims tied to the active toolchain.

## Claim Boundary

- Local docs lookup is evidence with provenance, not a guarantee of complete
  rendered documentation.
- Snippet parsing is not the same as executing a full example.
- README command extraction marks unsafe commands for human review; it does not
  imply they ran.

## Finish

Report docs claim, source evidence, snippet or command checks, drift checks,
toolchain version, and claims that remain unverified.
