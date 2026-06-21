---
name: zigars-compile-error-triage
description: Use when a zig build, zig test, or zigars command fails with a compile error, when triaging a stack of compiler diagnostics, when a user reports "my build broke", or when a CI log shows compile errors that need routing to source.
---

# Zigars Compile Error Triage

## Purpose

Use this skill the moment a Zig build fails. The skill turns raw compiler output
into structured diagnostics, routes the primary failure to its location, and
keeps the apply gate intact while a fix is hypothesized and verified.

## Workflow

1. Capture the failure. If the user already supplied build text, pass it to
   `zig_build_events`; otherwise call `zigars_run_stream` or `zigars_job_start`
   for the failing command so output is retained.
2. Extract structured diagnostics with `zig_build_events` or `zig_test_events`,
   then group with `zig_compile_error_index` to see the primary error class and
   the spread across files.
3. Use `zigars_failure_fusion` to fuse compiler and test failures into a single
   primary failure, rerun command, likely scope, and recommended follow-up
   tools.
4. Route by error class:
   - comptime evaluation issues — switch to `zigars-comptime-diagnose`;
   - `build.zig.zon` hash mismatch — switch to `zigars-zon-hash-sync`;
   - undefined-symbol or linker errors — use `zig_explain_errors` when
     available, otherwise inspect via `zig_module_surface` and `build.zig`.
5. Inspect the offending source with `zig_definition`, `zig_references`, or
   `zig_symbol_dossier` before editing.
6. Apply fixes preview-first (`zig_format`, `zig_move_decl`, `zig_extract_decl`,
   or a `zigars_patch_session_*` flow). Mutation requires `apply=true`.
7. Verify with `zigars_validate_patch` in `quick` mode (touched-file format and
   `zig ast-check`); escalate to `standard` only if the fix touches tests,
   public API, or dependency surface.

## Claim Boundary

- "Fixed" requires the same failing command to succeed on rerun, not just the
  diagnostic to disappear from a parser-backed view.
- `zigars_failure_fusion` outputs are routing advice and confidence-scored; they
  are not proof of root cause.
- Skipped validation phases (broad build, full test) leave residual risk that
  must be surfaced in any handoff.

## Finish

Report:

- primary failure (file, line, error class);
- evidence captured (build events, error index entries);
- fix applied (preview vs `apply=true`);
- validation phase that confirms the fix;
- residual risks and the next phase that would reduce them.
