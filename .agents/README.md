# Agent Playbooks

This directory contains reusable role and workflow playbooks for agent-assisted
work on `zigars`.

Use roles to frame review ownership. Use workflows to drive repeatable task
execution. A single task may use more than one role, but prefer the smallest set
that covers the risk.

## Roles

- [Architect](roles/architect.md): module boundaries, MCP contract shape, and
  architecture risk.
- [Tool Engineer](roles/tool-engineer.md): MCP tool schema, catalog, docs, and
  adapter changes.
- [Zig Domain Engineer](roles/zig-domain-engineer.md): parsing, diagnostics,
  static analysis, performance models, and pure domain logic.
- [QA Release](roles/qa-release.md): validation plans, release gates, smoke
  fixtures, coverage, and evidence.
- [Docs Maintainer](roles/docs-maintainer.md): user-facing docs, generated
  indexes, changelog, maturity, trust, and backend notes.
- [npm Shim Maintainer](roles/npm-shim-maintainer.md): TypeScript launcher,
  package contents, archive mapping, checksums, and Node/Bun compatibility.
- [Security Sandbox Reviewer](roles/security-sandbox-reviewer.md): path
  resolution, write gates, command boundaries, stdout/stderr separation, and
  user-controlled input handling.

## Workflows

- [Tool Change](workflows/tool-change.md): add, remove, or change an MCP tool.
- [Bugfix](workflows/bugfix.md): reproduce, patch, and verify focused defects.
- [Backend Integration](workflows/backend-integration.md): change optional
  runtime backend behavior or evidence.
- [Release Readiness](workflows/release-readiness.md): prepare a tag, archive,
  or publishable package.
- [npm Shim Change](workflows/npm-shim-change.md): change the npm launcher or
  package behavior.

## Selection Guide

- Changing a tool schema or MCP output: start with Tool Engineer and Tool
  Change.
- Touching path policy, command execution, or source writes: add Security
  Sandbox Reviewer.
- Editing parser, analyzer, coverage, profiling, or diagnostics logic: use Zig
  Domain Engineer.
- Preparing public artifacts or versioned releases: use QA Release, Docs
  Maintainer, and Release Readiness.
- Editing `packages/@zigars/mcp/`: use npm Shim Maintainer and npm Shim
  Change.
