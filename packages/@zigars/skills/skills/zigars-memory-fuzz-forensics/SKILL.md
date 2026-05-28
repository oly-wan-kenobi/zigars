---
name: zigars-memory-fuzz-forensics
description: Use when investigating Zig allocator leaks, GPA leak output, heap growth, Valgrind or heaptrack findings, Callgrind evidence, fuzz crashes, AFL/libFuzzer runs, corpus health, crash minimization, or memory-safety regression evidence.
---

# Zigars Memory Fuzz Forensics

## Purpose

Use this skill for allocator, memory-diagnostic, and fuzzing evidence. Preserve
raw findings, corpus identity, and backend execution limits.

## Workflow

1. Preserve raw evidence: stderr leak text, allocator trace frames, heaptrack or
   Valgrind files, fuzzer command, corpus path, seed, timeout, crashing input
   path and hash, target, optimize mode, and toolchain.
2. Start with read-only analysis: `zig_allocations`, `zig_leak_triage`,
   `zig_safety_site_catalog`, `zig_error_sets`, and source context tools.
3. For memory backends, preview `zig_heaptrack_run`,
   `zig_valgrind_memcheck`, or `zig_callgrind_report`. Execute only through
   zigars' apply-gated path when required.
4. For fuzzing, plan first with `zig_fuzz_plan`; run `zig_afl_run` or
   `zig_libfuzzer_run` only with explicit apply-gated execution; summarize
   corpus state with `zig_fuzz_corpus_summary`.
5. Minimize and classify fuzz crashes with `zig_fuzz_crash_minimize`,
   `zig_sanitizer_fusion`, `zig_panic_trace_analyze`, and
   `zig_crash_repro_plan` when available.
6. Convert each fixed issue into a regression test, corpus artifact, or validation
   command when the project allows it.

## Claim Boundary

- A leak parser can identify likely ownership issues; it does not prove all leaks
  are fixed.
- A fuzzer run is bounded evidence for that command, timeout, corpus, and seed.
- Backend absence must be reported explicitly.

## Finish

Report raw evidence identity, likely ownership or crash site, backend status,
corpus/minimization result, validation run, and remaining memory-safety risk.
