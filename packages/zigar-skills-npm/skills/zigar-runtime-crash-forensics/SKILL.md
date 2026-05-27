---
name: zigar-runtime-crash-forensics
description: Use when a Zig program compiles but crashes, panics, produces sanitizer output, has a core dump, needs LLDB backtrace analysis, fails only on a target, or needs a stable runtime crash reproduction plan.
---

# Zigar Runtime Crash Forensics

## Purpose

Use this skill for post-compile runtime failures. Preserve raw crash evidence,
classify it with zigar, and produce the smallest trustworthy reproduction path.

## Workflow

1. Preserve the raw run context: command, cwd, target triple, optimize mode,
   toolchain, stdout/stderr, panic text, sanitizer log, binary path and hash,
   core path and hash, and input files.
2. Start with non-invasive classification:
   `zig_sanitizer_fusion`, `zig_panic_trace_analyze`,
   `zig_debug_frame_summary`, and `zig_crash_repro_plan`.
3. If debugger or core evidence is needed, preview `zig_debug_plan`,
   `zig_lldb_backtrace`, or `zig_core_inspect`. Execute backend commands only
   when the zigar tool requires and receives `apply=true`.
4. Inspect likely source context with `zig_file_owner`, references, impact
   tools, safety-site catalog, and focused tests.
5. If the failure is target-only, include `zig_target_runtime_plan`,
   `zig_cross_smoke`, binary identity, and target constraints before claiming
   reproduction.
6. Validate a fix with the smallest command that reproduces the crash, then
   broaden to tests or CI when the failure crosses API, target, or release risk.

## Claim Boundary

- Symbolized frames are helpful, but raw frames and command evidence remain part
  of the record.
- A planned debugger command is not executed evidence.
- A crash identity is not a proof of root cause.

## Finish

Report crash identity, primary evidence, suspected failing surface, repro steps,
verification run, and evidence still missing.
