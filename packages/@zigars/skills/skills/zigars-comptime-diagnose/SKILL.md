---
name: zigars-comptime-diagnose
description: Use when the Zig compiler emits "unable to evaluate comptime expression", "operation is runtime", "evaluation exceeded N backwards branches", or any compile-time evaluation error where the developer needs to know which operand or call site is runtime-tainted.
---

# Zigars Comptime Diagnose

## Purpose

Use this skill when a comptime diagnostic is unhelpful by itself, which is the
norm for Zig's comptime errors. The skill localizes the runtime-tainted operand,
explains the enclosing comptime position, and proposes targeted fixes that the
compiler can verify.

## Workflow

1. Confirm the diagnostic location (file, line, character) from the raw
   compiler output or from `zig_compile_error_index`. If the compiler note is
   missing a position, supply the cursor manually.
2. Call `zig_comptime_diagnose` with the diagnostic location and, when
   available, the `error_text` so the tool can use the compiler's existing note
   positions.
3. Read the result: `enclosing_context` (type position, array length, switch
   prong, `@call` modifier, etc.), `runtime_operands[]` with each operand's
   inferred reason, `likely_fixes[]`, `confidence`, and `limitations`.
4. For `evaluation exceeded N backwards branches`, run
   `zig_comptime_quota_probe` to find the smallest passing quota and per-call-
   site evidence on top consumers; treat the result as a search, not a
   profiler.
5. For deeper context on a flagged operand, use `zig_ast_imports`,
   `zig_ast_declarations`, `zig_symbol_dossier`, or `zls_definition`.
6. Apply the chosen fix preview-first; validate with `zigars_validate_patch` in
   `quick` mode so `zig ast-check` confirms the comptime path is now resolvable
   before any broader test run.

## Claim Boundary

- Parser-backed runtime-operand attribution is a diagnostic hint, not full
  semantic comptime evaluation; the compiler is the source of truth.
- `likely_fixes` are templated suggestions; "fixed" requires the compiler to
  accept the change.
- A quota probe finds a budget that compiles; it does not prove the underlying
  comptime work is correctly bounded.

## Finish

Report:

- the comptime diagnostic and its source location;
- inferred enclosing-context kind;
- runtime operand(s) and the reason each is runtime;
- fix applied and the compiler-backed verification that accepted it.
