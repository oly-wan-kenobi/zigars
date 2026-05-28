---
name: zigars-handoff-resume
description: Use when wrapping a work session, when switching MCP clients or agents mid-task, when capturing decisions and project notes for later, when preparing a long-running refactor or release to resume across sessions, or when starting work that another agent left in flight.
---

# Zigars Handoff And Resume

## Purpose

Use this skill to capture or replay the smallest sufficient session context so
the next agent (or the same agent in a new session) can resume without redoing
discovery. The skill operates on observed evidence; it does not freeze the
workspace.

## Workflow

1. Snapshot the current session with `zigars_session_snapshot`: goal, changed
   files, validation status, profile state, workspace facts. Treat the snapshot
   as a hint, not a lock.
2. Summarize retained evidence with `zigars_validation_history`,
   `zig_test_flake_history`, and `zig_failure_history`. These are summaries of
   supplied or zigars-written JSONL, not a CI database.
3. Bundle the handoff with `zigars_handoff_pack` so a new client can read
   workspace facts and recommended next steps without re-running discovery.
4. Plan the resume sequence with `zigars_tool_sequence_plan` for the current
   goal; this returns an ordered tool list with execution-risk markers and a
   stop condition.
5. For decisions worth preserving, preview and apply `zigars_decision_record`
   (`apply: true` required) so the workspace-local journal captures why the
   choice was made.
6. Surface relevant existing context with `zigars_project_notes` (query and
   category filters) and `zigars_project_memory` for the built-in zigars
   policies the next agent must respect (apply gates, generated-path rules,
   workspace boundary).
7. When resuming someone else's session, start with the snapshot and bundle,
   then run `zigars_doctor` and `zigars_context_pack` independently before
   acting; never act solely on a handoff bundle.

## Claim Boundary

- A handoff bundle describes observed state; it does not freeze the workspace
  or prove unrun validation.
- Decision records are workspace-local journal entries, not a project decision
  system of record.
- A resumed session must re-derive its own evidence; the bundle is orientation,
  not authority.

## Finish

Report:

- snapshot identity and path;
- handoff bundle identity and path;
- decision record (preview or applied);
- recommended first-tool sequence for the resume, with the stop condition.
